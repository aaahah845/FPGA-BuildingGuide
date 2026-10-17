"""Check reset distribution and HDMI capture without claiming routed timing closure."""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'src/user_source/hdl_source'
OUT = ROOT / 'reports/reset_release'
OUT.mkdir(parents=True, exist_ok=True)
source_paths = [SRC / name for name in
                ('cdc_sync.v', 'hdmi_phy_wrapper.v', 'lane_lvds_10_1.v')]
top_path = SRC / 'top_tf_hdmi_audio.v'
top_text = top_path.read_text(encoding='utf-8')
start = top_text.index('wire [6:0] video_reset_leaf;')
end = top_text.index('assign rst_video=video_reset_leaf[0];', start)
leaf_source = top_text[start:end]
assert 'reset_release_leaf #(.WIDTH(7))' in leaf_source
wrapper = OUT / 'video_reset_leaves_from_top.v'
wrapper.write_text('module video_reset_leaves_from_top(input video_clk,rst_video_root,output [6:0] leaves);\n'
                   + leaf_source + '\nassign leaves=video_reset_leaf;\nendmodule\n', encoding='utf-8')
lane_text = source_paths[-1].read_text(encoding='utf-8')
assert len(re.findall(r'\.rst\s*\(\s*I_rst\s*\)', lane_text)) == 8
vendor_path = Path('D:/anlu/sim_release/eg4/eg_logic_io.v')
vendor_text = vendor_path.read_text(encoding='utf-8')
match = re.search(r'module EG_LOGIC_ODDR \(.*?\nendmodule', vendor_text, re.S)
assert match
oddr_model = OUT / 'official_eg_logic_oddr.v'
oddr_model.write_text('`timescale 1ns/1ps\n' + match.group(0) + '\n', encoding='utf-8')
files = source_paths + [wrapper, oddr_model, ROOT / 'sim/tb_reset_release_hdmi.v']
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
before = {str(path.relative_to(ROOT)): sha(path) for path in source_paths + [top_path]}
do_path = OUT / 'reset_release.do'
do_path.write_text('\n'.join([
    'onerror {quit -code 1 -f}', 'onbreak {quit -code 1 -f}',
    'cd {' + OUT.as_posix() + '}',
    'if {![file exists work_reset_release]} {vlib work_reset_release}',
    'vlog -sv -work work_reset_release ' + ' '.join('{' + path.as_posix() + '}' for path in files),
    'vsim -c -voptargs=+acc work_reset_release.tb_reset_release_hdmi work_reset_release.glbl',
    'run -all', 'quit -f',
]) + '\n', encoding='utf-8')
started = time.time()
log_path = OUT / 'simulation.log'
with log_path.open('wb') as log:
    run = subprocess.run(['C:/altera/14.1/modelsim_ase/win32aloem/vsim.exe', '-c', '-do', str(do_path)],
                         cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                         timeout=180, creationflags=subprocess.CREATE_NO_WINDOW)
text = log_path.read_text(encoding='utf-8', errors='replace')
unchanged = all(sha(ROOT / name) == value for name, value in before.items())
passed = run.returncode == 0 and unchanged and 'PASS: falling-edge reset leaves' in text
passed = passed and not re.search(r'\*\*\s+(?:Error|Fatal):', text)
result = {
    'passed': passed, 'exit_code': run.returncode, 'seconds': round(time.time() - started, 2),
    'source_sha256': before, 'sources_unchanged': unchanged,
    'vendor_model_source': str(vendor_path), 'vendor_model_sha256': sha(vendor_path),
    'video_leaf_source': leaf_source,
    'scope': 'Real reset_sync, falling-edge leaves and four-lane HDMI wrapper; '
             'official EG_LOGIC_ODDR behavioral model. Six pixel/serial phases, '
             '16 video reset pulses and 24 HDMI reset pulses, including sub-cycle assertions. '
             'Checks parallel capture, both serialized output edges and half-cycle reset release. '
             'RTL simulation does not prove routed recovery/removal or board electrical timing.',
    'evidence': [line for line in text.splitlines()
                 if 'PASS' in line or '** Error' in line or '** Fatal' in line],
}
(OUT / 'results.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps(result, ensure_ascii=False, indent=2))
if not passed:
    print('\n'.join(text.splitlines()[-70:]))
raise SystemExit(0 if passed else 1)
