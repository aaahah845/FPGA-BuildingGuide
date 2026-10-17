"""Verify the actual top-level boot gate with the real RGB-to-AXIS module."""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'src/user_source/hdl_source'
OUT = ROOT / 'reports/dynamic_text/startup_gate'
OUT.mkdir(parents=True, exist_ok=True)
top_path = SRC / 'top_tf_hdmi_audio.v'
top_bytes = top_path.read_bytes()
top = top_bytes.decode('utf-8').replace('\r\n', '\n')
start = top.index('reg config_display_ready;')
stop = top.index('video_rgb_to_axis u_video_rgb_to_axis(', start)
gate = top[start:stop]
assert gate.count('always') == 1 and 'posedge video_clk' in gate
inst_end = top.index('\n);', stop)
axis_instance = top[stop:inst_end]
rgb_expression = re.search(r'\.I_rgb\s*\(([^\n]+)\),', axis_instance).group(1)
# This wrapper incorporates the source text under review, rather than a
# manually rewritten copy of the readiness state machine or RGB expression.
wrapper = '''module startup_gate_from_top(
 input video_clk,rst_video_output,adjusted_vs,site_ready,
 input [23:0] adjusted_rgb,
 output [23:0] gated_rgb,output gate_ready
);
''' + gate + '\nassign gated_rgb=' + rgb_expression + ';\n' + \
    'assign gate_ready=config_display_ready;\nendmodule\n'
(OUT / 'startup_gate_from_top.v').write_text(wrapper, encoding='utf-8')
files = [SRC / 'video_rgb_to_axis.v', OUT / 'startup_gate_from_top.v', ROOT / 'sim/tb_startup_gate.v']
do = OUT / 'startup_gate.do'
do.write_text('\n'.join([
    'onerror {quit -code 1 -f}', 'onbreak {quit -code 1 -f}',
    f'cd {{{OUT.as_posix()}}}',
    'if {![file exists work_startup_gate]} {vlib work_startup_gate}',
    'vlog -sv -work work_startup_gate ' + ' '.join('{' + p.as_posix() + '}' for p in files),
    'vsim -c work_startup_gate.tb_startup_gate', 'run -all', 'quit -f',
]) + '\n', encoding='utf-8')
started = time.time()
with (OUT / 'startup_gate.log').open('wb') as log:
    process = subprocess.run(
        ['C:/altera/14.1/modelsim_ase/win32aloem/vsim.exe', '-c', '-do', str(do)],
        cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
        timeout=120, creationflags=subprocess.CREATE_NO_WINDOW)
log = (OUT / 'startup_gate.log').read_text(encoding='utf-8', errors='replace')
passed = process.returncode == 0 and 'PASS: startup gate suite' in log and not re.search(r'\*\*\s+(Error|Fatal):', log)
passed = passed and top_path.read_bytes() == top_bytes
result = {
    'pass': passed, 'exit_code': process.returncode,
    'seconds': round(time.time() - started, 2),
    'top_sha256': hashlib.sha256(top_bytes).hexdigest(),
    'axis_sha256': hashlib.sha256((SRC / 'video_rgb_to_axis.v').read_bytes()).hexdigest(),
    'gate_source': gate, 'rgb_expression': rgb_expression,
    'evidence': [s for s in log.splitlines() if 'PASS:' in s or '** Error' in s or '** Fatal' in s],
    'scope': 'Actual extracted startup gate plus real video_rgb_to_axis at H_ACTIVE=800; comparison to ungated reference; not a board or HDMI PHY test.',
}
(OUT / 'results.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps(result, ensure_ascii=False, indent=2))
if not passed:
    print('\n'.join(log.splitlines()[-50:]))
raise SystemExit(0 if passed else 1)
