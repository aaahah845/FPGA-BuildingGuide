"""Check native-photo overlays, retained borders and frame snapshots independently."""
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'src/user_source/hdl_source'
OUT = ROOT / 'reports/photo_full_reader'
OUT.mkdir(parents=True, exist_ok=True)
reader = SRC / 'SD/scene_frame_reader.v'
source_hash = hashlib.sha256(reader.read_bytes()).hexdigest()
checked_files = [reader, SRC / 'SD/bilinear_span_cache.v', ROOT / 'sim/tb_photo_full_reader.v']
input_hashes = {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in checked_files}
text = reader.read_text(encoding='utf-8')
has_full = bool(re.search(r'output\s+(?:wire\s+|reg\s+)?applied_full\b', text))
define = '+define+READER_HAS_APPLIED_FULL' if has_full else ''
lib = OUT / 'work'
script = OUT / 'run.do'
script.write_text('\n'.join([
    'onerror {quit -code 1 -f}',
    'onbreak {quit -code 1 -f}',
    f'if {{![file exists {{{lib.as_posix()}}}]}} {{vlib {{{lib.as_posix()}}}}}',
    f'vlog -sv -work {{{lib.as_posix()}}} {define} +incdir+{SRC.as_posix()} +incdir+{(SRC / "SD").as_posix()} {{{reader.as_posix()}}} {{{(ROOT / "sim/tb_photo_full_reader.v").as_posix()}}}',
    f'vsim -c {{{lib.as_posix()}.tb_photo_full_reader}}',
    'run -all',
    'quit -f',
]) + '\n', encoding='utf-8')
start = time.time()
with (OUT / 'simulation.log').open('wb') as log:
    run = subprocess.run([
        'C:/altera/14.1/modelsim_ase/win32aloem/vsim.exe', '-c', '-do', script.as_posix()
    ], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
       timeout=600, creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
log_text = (OUT / 'simulation.log').read_text(encoding='utf-8', errors='replace')
evidence = [line for line in log_text.splitlines() if any(key in line for key in ('FRAME_PASS', 'PASS:', 'APPLIED_FULL_PORT', 'DIRECT_READ_EQUIVALENCE', 'FILTER_SAMPLE_EQUIVALENCE', '** Error', '** Fatal'))]
inputs_unchanged = all(input_hashes[p.relative_to(ROOT).as_posix()] == hashlib.sha256(p.read_bytes()).hexdigest() for p in checked_files)
passed = inputs_unchanged and run.returncode == 0 and 'PASS:' in log_text and not re.search(r'\*\*\s+(Error|Fatal):', log_text)
result = {'test': 'photo_full_reader', 'passed': passed, 'exit_code': run.returncode,
          'seconds': round(time.time()-start, 2), 'applied_full_port_checked': has_full,
          'reader_sha256': source_hash,
          'reader_unchanged_during_test': source_hash == hashlib.sha256(reader.read_bytes()).hexdigest(),
          'inputs_unchanged_during_test': inputs_unchanged, 'input_sha256': input_hashes,
          'expected_frames': 6, 'expected_pixels': 2880000,
          'coverage': ['native_photo_rectangle', 'retained_rgb888_border', 'retained_bilinear_border',
                       'mixed_and_full_index', 'mixed_and_full_map', 'photo_and_base_slot_protection',
                       'midframe_descriptor_changes', 'variable_sdram_valid_gaps', 'fifo_no_overflow_or_underflow'],
          'evidence': evidence}
(OUT / 'results.json').write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
print(json.dumps(result, ensure_ascii=False, indent=2), flush=True)
if not passed:
    print('\n'.join(log_text.splitlines()[-45:]), flush=True)
sys.exit(0 if passed else 1)
