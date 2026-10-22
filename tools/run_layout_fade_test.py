from pathlib import Path
import subprocess,json,hashlib
b=Path(__file__).resolve().parents[1];r=b/'reports/layout_fade'
with (r/'simulation.log').open('wb') as log:p=subprocess.run(['C:/altera/14.1/modelsim_ase/win32aloem/vsim.exe','-c','-do',(r/'run.do').resolve().as_posix()],stdout=log,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
t=(r/'simulation.log').read_text(errors='replace');ok=p.returncode==0 and 'PASS:' in t and '** Error' not in t and '** Fatal' not in t
result={'pass':ok,'source_sha256':hashlib.sha256((b/'src/user_source/hdl_source/site_scene_broker.v').read_bytes()).hexdigest(),'evidence':[x for x in t.splitlines() if 'PASS:' in x or '** Error' in x or '** Fatal' in x]}
(r/'results.json').write_text(json.dumps(result,indent=2),encoding='utf-8');print(json.dumps(result));assert ok
