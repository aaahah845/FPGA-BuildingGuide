"""Check mixed/full overlays under encrypted SDRAM timing, writes and refresh."""
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'reports/vendor_crossfade'
OUT.mkdir(parents=True, exist_ok=True)
first, last = (map(int, sys.argv[1:3]) if len(sys.argv) == 3 else (3, 4))
assert 0 <= first < last <= 18
env = dict(os.environ, FIRST_FRAME=str(first), LAST_FRAME=str(last))
env.pop('COMPILE_ONLY', None)
reader = ROOT / 'src/user_source/hdl_source/SD/scene_frame_reader.v'
source_hash = hashlib.sha256(reader.read_bytes()).hexdigest()
checked_files = [reader, reader.with_name('bilinear_span_cache.v'), ROOT / 'sim/tb_vendor_crossfade.v']
input_hashes = {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in checked_files}
start = time.time()
with (OUT / 'simulation.log').open('wb') as log:
    run = subprocess.run([
        'C:/altera/14.1/modelsim_ase/win32aloem/vsim.exe', '-c', '-do', 'sim/vendor_crossfade.do'
    ], cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
       stdin=subprocess.DEVNULL, timeout=1800,
       creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
log_text = (OUT / 'simulation.log').read_text(encoding='utf-8', errors='replace')
keys = ('MIXED_VENDOR_FRAME', 'PASS:', 'DIRECT_READ_EQUIVALENCE', 'FILTER_SAMPLE_EQUIVALENCE', '** Error', '** Fatal')
evidence = [line for line in log_text.splitlines() if any(key in line for key in keys)]
inputs_unchanged = all(input_hashes[p.relative_to(ROOT).as_posix()] == hashlib.sha256(p.read_bytes()).hexdigest() for p in checked_files)
passed = inputs_unchanged and run.returncode == 0 and 'PASS:' in log_text and not re.search(r'\*\*\s+(Error|Fatal):', log_text)
result = {'test': 'vendor_crossfade', 'passed': passed, 'exit_code': run.returncode,
          'first_frame': first, 'last_frame_exclusive': last,
          'seconds': round(time.time()-start, 2), 'reader_sha256': source_hash,
          'reader_unchanged_during_test': source_hash == hashlib.sha256(reader.read_bytes()).hexdigest(),
          'inputs_unchanged_during_test': inputs_unchanged, 'input_sha256': input_hashes,
          'coverage': ['native_photo_rectangle', 'retained_rgb888_bilinear_border',
                       'photo_and_base_slot_protection', 'concurrent_writer_and_refresh',
                       'fifo_no_overflow_or_underflow'],
          'evidence': evidence}
(OUT / 'results.json').write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
(OUT / f'case{first}_{last}_results.json').write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
print(json.dumps(result, ensure_ascii=False, indent=2), flush=True)
if not passed:
    print('\n'.join(log_text.splitlines()[-45:]), flush=True)
sys.exit(0 if passed else 1)
