"""Compile the real scene broker and test frame-synchronous photo transitions."""
from pathlib import Path
import json
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'src/user_source/hdl_source'
OUT = ROOT / 'reports/photo_fade/simulation'
OUT.mkdir(parents=True, exist_ok=True)
LIB = OUT / 'work_broker_photo_fade'
SCRIPT = OUT / 'broker_photo_fade.do'
LOG = OUT / 'broker_photo_fade.log'
SCRIPT.write_text('\n'.join([
    'onerror {quit -code 1 -f}', 'onbreak {quit -code 1 -f}',
    'if {![file exists {' + LIB.as_posix() + '}]} {vlib {' + LIB.as_posix() + '}}',
    f'vlog -sv -work {{{LIB.as_posix()}}} +incdir+{SRC.as_posix()} '
    f'{{{(SRC / "site_scene_broker.v").as_posix()}}} '
    f'{{{(ROOT / "sim/tb_broker_photo_fade.v").as_posix()}}}',
    f'vsim -c -voptargs=+acc -lib {{{LIB.as_posix()}}} tb_broker_photo_fade',
    'run -all', 'quit -f',
]) + '\n', encoding='utf-8')
started = time.time()
with LOG.open('wb') as log:
    proc = subprocess.run([
        'C:/altera/14.1/modelsim_ase/win32aloem/vsim.exe', '-c', '-do', SCRIPT.as_posix()
    ], cwd=ROOT, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
        timeout=180, creationflags=subprocess.CREATE_NO_WINDOW)
content = LOG.read_text(encoding='utf-8', errors='replace')
passed = proc.returncode == 0 and 'PASS: broker photo fade assertions=' in content and not re.search(r'\*\*\s+(?:Error|Fatal):', content)
result = {
    'test': 'broker_photo_fade', 'pass': passed, 'exit_code': proc.returncode,
    'seconds': round(time.time()-started, 2),
    'evidence': [line for line in content.splitlines() if 'PASS:' in line or '** Error' in line or '** Fatal' in line],
}
(OUT / 'broker_photo_fade_results.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps(result, ensure_ascii=False, indent=2))
if not passed:
    print('\n'.join(content.splitlines()[-35:]))
raise SystemExit(0 if passed else 1)
