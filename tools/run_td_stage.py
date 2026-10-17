"""运行本副本的 TD 阶段；沿用发布版参数，不额外插入保持修复或改约束。"""
from pathlib import Path
import subprocess, sys, json, time, hashlib
ROOT=Path(__file__).resolve().parents[1]
run=sys.argv[1]
assert run=='syn_1' or run=='phy_1' or (run.startswith('phy_seed') and run[8:].isdigit())
work=ROOT/'src/td_project/image_multiview_gui_Runs'/run
assert work.is_dir()
wrapper=work/'codex_batch.tcl'
commands=['if {[catch {source {D:/anlu/doc/scripts/DefaultFlow.tcl}} err]} {',
          '    puts "NAV_FLOW_ERROR: $err"', '    exit 1', '}']
if run!='syn_1': commands += ['report_timing_summary -file final_timing.rpt']
commands+=['puts "NAV_FLOW_OK"','exit 0']
wrapper.write_text('\n'.join(commands)+'\n',encoding='utf-8')
out=ROOT/'reports/cache_tailfix'/run
out.mkdir(parents=True,exist_ok=True)
start=time.time()
def sources():
    return {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
            for p in (ROOT/'src/user_source').rglob('*')
            if p.is_file() and p.suffix.lower() in ('.v','.vh','.sdc','.adc','.tcl')}
source_before=sources()
(out/'source_manifest.json').write_text(json.dumps(source_before,indent=2),encoding='utf-8')
with (out/'td_console.log').open('wb') as log:
    proc=subprocess.Popen(['D:/anlu/bin/td_commands_prompt.exe',wrapper.as_posix()],cwd=work,
            stdout=log,stderr=subprocess.STDOUT,stdin=subprocess.DEVNULL,creationflags=subprocess.CREATE_NO_WINDOW)
    (out/'process.json').write_text(json.dumps({'pid':proc.pid,'run':run,'started_epoch':start},indent=2),encoding='utf-8')
    print(f'START {run} pid={proc.pid}',flush=True)
    code=proc.wait()
text=(out/'td_console.log').read_text(encoding='utf-8',errors='replace')
artifact=work/('image_multiview_gui_gate.db' if run=='syn_1' else 'image_multiview_gui.bit')
result={'run':run,'exit_code':code,'seconds':round(time.time()-start,1),'flow_marker':'NAV_FLOW_OK' in text,
        'artifact_exists':artifact.is_file()}
result['sources_unchanged']=source_before==sources()
result['artifact_new']=artifact.is_file() and artifact.stat().st_mtime>=start
result['pass']=code==0 and result['flow_marker'] and result['artifact_new'] and result['sources_unchanged'] and 'ERROR:' not in text
(out/'build_result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
print(json.dumps(result),flush=True)
if not result['pass']:
    print('\n'.join(text.splitlines()[-60:]),flush=True)
    sys.exit(1)
