"""独立运行交互仿真，成功必须同时有 PASS 标志且无工具/断言错误。"""
from pathlib import Path
import subprocess, sys, json, time, re
ROOT=Path(__file__).resolve().parents[1]
SIM=ROOT/'sim'
OUT=ROOT/'reports/nav_keys/simulation'
OUT.mkdir(parents=True,exist_ok=True)
names=sys.argv[1:] or ['nav_control','navigation10','direction_control','filter_control','shared_input_timing','nav_left_long','nav_messages']
results=[]
for name in names:
    baseline=name=='direction_control_legacy_baseline'
    top='tb_direction_control' if baseline else 'tb_'+name
    lib='work_'+name
    src=((ROOT.parent/'lab_image_release_20261011') if baseline else ROOT)/'src/user_source/hdl_source'
    tb=OUT/'tb_direction_control_legacy.v' if baseline else SIM/(top+'.v')
    sources=[] if name=='nav_messages' else [src/'map_navigation.v'] if name=='navigation10' else [src/'guide_key_control.v', src/('direction_key_event.v' if name=='shared_input_timing' else 'guide_scene_control.v')]
    files=' '.join('{'+p.as_posix()+'}' for p in sources+[tb])
    script=OUT/(name+'.do')
    script.write_text('\n'.join(['onerror {quit -code 1 -f}','onbreak {quit -code 1 -f}',
       f'cd {{{SIM.as_posix()}}}',f'if {{![file exists {lib}]}} {{vlib {lib}}}',
       f'vlog -sv -work {lib} +incdir+{src.as_posix()} {files}',
       f'vsim -c {lib}.{top}','run -all','quit -f'])+'\n',encoding='utf-8')
    start=time.time()
    with (OUT/(name+'.log')).open('wb') as log:
        proc=subprocess.run(['C:/altera/14.1/modelsim_ase/win32aloem/vsim.exe','-c','-do',script.as_posix()],
             cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,stdin=subprocess.DEVNULL,timeout=180,creationflags=subprocess.CREATE_NO_WINDOW)
    text=(OUT/(name+'.log')).read_text(encoding='utf-8',errors='replace')
    passed=proc.returncode==0 and 'PASS:' in text and not re.search(r'\*\*\s+(Error|Fatal):',text)
    item={'test':name,'exit_code':proc.returncode,'pass':passed,'seconds':round(time.time()-start,2),
          'evidence':[l for l in text.splitlines() if 'PASS:' in l or '** Error' in l or '** Fatal' in l]}
    results.append(item)
    print(json.dumps(item,ensure_ascii=False),flush=True)
    if not passed and not baseline:
        print('\n'.join(text.splitlines()[-25:]),flush=True)
(OUT/('legacy_baseline.json' if len(names)==1 and names[0]=='direction_control_legacy_baseline' else 'results.json')).write_text(json.dumps(results,ensure_ascii=False,indent=2),encoding='utf-8')
sys.exit(0 if all(x['pass'] or x['test']=='direction_control_legacy_baseline' for x in results) else 1)
