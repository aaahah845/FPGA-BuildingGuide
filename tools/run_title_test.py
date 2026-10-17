"""Pixel-level title regression against the original seed61 compositor."""
from pathlib import Path
import hashlib,json,re,subprocess,time

ROOT=Path(__file__).resolve().parents[1]
SRC=ROOT/'src/user_source/hdl_source'
OUT=ROOT/'reports/title_config/simulation'
OUT.mkdir(parents=True,exist_ok=True)
golden=json.loads((OUT/'golden_sources.json').read_text(encoding='utf-8-sig'))
for filename,expected in golden['files'].items():
    actual=hashlib.sha256((OUT/filename).read_bytes()).hexdigest()
    if actual!=expected: raise RuntimeError(f'Golden snapshot hash mismatch: {filename}')
original=(OUT/'golden_compositor_seed61.v').read_text(encoding='utf-8')
# Dependencies are compiled by the candidate's top-level includes. Preserve
# baseline module body and its private .vh includes verbatim.
baseline=original[original.index('module guide_scene_compositor #'):].replace(
    'module guide_scene_compositor #','module guide_scene_compositor_baseline #',1)
(OUT/'guide_scene_compositor_baseline.v').write_text(baseline,encoding='utf-8')

# Reconstruct reference 24x24 glyphs directly from the original packed ROM,
# independent of the candidate's request/coordinate/pipeline RTL.
font=(OUT/'golden_large_font_seed61.v').read_text(encoding='utf-8')
banks={kind:{int(a):int(v,16) for a,v in re.findall(
    rf'{kind}_words\[(\d+)\]=18\'h([0-9a-fA-F]+);',font)} for kind in ('even','odd')}
rows=[]
for glyph in range(128):
    bitstream=0
    for word in range(32):
        value=banks['odd' if word%2 else 'even'][glyph*16+word//2]
        bitstream|=value<<(18*word)
    rows.extend((bitstream>>(24*row))&0xffffff for row in range(24))
(OUT/'font24_expected.hex').write_text(''.join(f'{r:06x}\n' for r in rows),encoding='ascii')

files=[SRC/'guide_scene_compositor.v',OUT/'guide_scene_compositor_baseline.v',ROOT/'sim/tb_runtime_title.v']
script='\n'.join([
 'onerror {quit -code 1 -f}','onbreak {quit -code 1 -f}',
 f'cd {{{OUT.as_posix()}}}',
 'if {![file exists work_title]} {vlib work_title}',
 f'vlog -sv -work work_title +incdir+{SRC.as_posix()} '+' '.join('{'+p.as_posix()+'}' for p in files),
 'vsim -c work_title.tb_runtime_title','run -all','quit -f'])+'\n'
(OUT/'runtime_title.do').write_text(script,encoding='utf-8')
start=time.time()
with (OUT/'runtime_title.log').open('wb') as log:
    proc=subprocess.run(['C:/altera/14.1/modelsim_ase/win32aloem/vsim.exe','-c','-do',str(OUT/'runtime_title.do')],
        cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,stdin=subprocess.DEVNULL,timeout=600,
        creationflags=subprocess.CREATE_NO_WINDOW)
log=(OUT/'runtime_title.log').read_text(encoding='utf-8',errors='replace')
passed=proc.returncode==0 and 'PASS: runtime title suite' in log and not re.search(r'\*\*\s+(Error|Fatal):',log)
result={'pass':passed,'exit_code':proc.returncode,'seconds':round(time.time()-start,2),
        'baseline_source':str(OUT/'golden_compositor_seed61.v'),
        'baseline_sha256':golden['files']['golden_compositor_seed61.v'],
        'candidate_sha256':hashlib.sha256((SRC/'guide_scene_compositor.v').read_bytes()).hexdigest(),
        'evidence':[s for s in log.splitlines() if 'PASS:' in s or '** Error' in s or '** Fatal' in s],
        'scope':'Compositor canonical config and real glyph output; no SD filesystem, parser or board test.'}
(OUT/'results.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(result,ensure_ascii=False,indent=2))
if not passed: print('\n'.join(log.splitlines()[-45:]))
raise SystemExit(0 if passed else 1)
