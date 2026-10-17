from pathlib import Path
import subprocess, json, re, time, hashlib
ROOT=Path(__file__).resolve().parents[1]
SRC=ROOT/'src/user_source/hdl_source'
OUT=ROOT/'reports/photo_overlay/compositor_sim'
OUT.mkdir(parents=True,exist_ok=True)
packet=(ROOT/'release/SITE.CFG').read_bytes()
assert len(packet)==27648 and packet[4]==6
(OUT/'config.hex').write_text(''.join(f'{b:02x}\n' for b in packet[:8192]),encoding='ascii')
words=[int.from_bytes(packet[i:i+4],'little') for i in range(8192,24576,4)]
words += [int.from_bytes(packet[i:i+2],'little') for i in range(24576,27648,2)]
(OUT/'fonts.hex').write_text(''.join(f'{v:05x}\n' for v in words),encoding='ascii')
baseline=ROOT.parent/'lab_image_dynamic_text_20261012/src/user_source/hdl_source/guide_scene_compositor.v'
ref=OUT/'guide_scene_compositor_baseline.v'
ref.write_text(baseline.read_text(encoding='utf-8').replace('module guide_scene_compositor #','module guide_scene_compositor_baseline #'),encoding='utf-8')
script=OUT/'run.do'
files=[SRC/'guide_scene_compositor.v',ref,ROOT/'sim/tb_photo_compositor.v']
script.write_text('\n'.join([
 'onerror {quit -code 1 -f}','onbreak {quit -code 1 -f}',f'cd {{{OUT.as_posix()}}}',
 'if {![file exists work]} {vlib work}',
 f'vlog -sv -work work +incdir+{SRC.as_posix()} '+' '.join('{'+p.as_posix()+'}' for p in files),
 'vsim -c work.tb_photo_compositor','run -all','quit -f'])+'\n',encoding='utf-8')
start=time.time()
source_hashes={p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in [SRC/'guide_scene_compositor.v',ROOT/'sim/tb_photo_compositor.v']}
with (OUT/'test.log').open('wb') as log:
 p=subprocess.run(['C:/altera/14.1/modelsim_ase/win32aloem/vsim.exe','-c','-do',script.as_posix()],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,stdin=subprocess.DEVNULL,timeout=1200,creationflags=subprocess.CREATE_NO_WINDOW)
log=(OUT/'test.log').read_text(encoding='utf-8',errors='replace')
unchanged=all(hashlib.sha256((ROOT/f).read_bytes()).hexdigest()==digest for f,digest in source_hashes.items())
result={'pass':p.returncode==0 and 'PASS:' in log and not re.search(r'\*\*\s+(Error|Fatal):',log) and unchanged,'seconds':round(time.time()-start,1),'source_hashes':source_hashes,'sources_unchanged_during_test':unchanged,'coverage':'4 full 800x600 rasters (index/map alpha8/16), 14 boundary-row cases, alpha0/1/8/15/16 open and return; independent old compositor reference with full disabled; outside RGB888 retained','evidence':[l for l in log.splitlines() if 'PASS:' in l or '** Error' in l or '** Fatal' in l]}
(OUT/'results.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(result,ensure_ascii=False))
if not result['pass']: print('\n'.join(log.splitlines()[-35:]))
raise SystemExit(0 if result['pass'] else 1)
