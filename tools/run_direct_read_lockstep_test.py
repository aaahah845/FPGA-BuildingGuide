"""Check direct_read decoding against legacy logic and existing reader reference."""
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'reports/direct_read_lockstep'
OUT.mkdir(parents=True, exist_ok=True)
first, last = (map(int, sys.argv[1:3]) if len(sys.argv) == 3 else (2, 3))
assert 0 <= first < last <= 18
env = dict(os.environ, FIRST_FRAME=str(first), LAST_FRAME=str(last))
env.pop('COMPILE_ONLY', None)
reader = ROOT / 'src/user_source/hdl_source/SD/scene_frame_reader.v'
source_hash = hashlib.sha256(reader.read_bytes()).hexdigest()
start = time.time()
with (OUT / 'simulation.log').open('wb') as log:
    run = subprocess.run([
        'C:/altera/14.1/modelsim_ase/win32aloem/vsim.exe', '-c', '-do', 'sim/reader_lockstep.do'
    ], cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT,
       stdin=subprocess.DEVNULL, timeout=1800,
       creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
log_text = (OUT / 'simulation.log').read_text(encoding='utf-8', errors='replace')
keys = ('LOCKSTEP FRAME', 'PASS:', 'DIRECT_READ_EQUIVALENCE', 'FILTER_SAMPLE_EQUIVALENCE', '** Error', '** Fatal')
evidence = [line for line in log_text.splitlines() if any(key in line for key in keys)]
passed = run.returncode == 0 and 'PASS:' in log_text and not re.search(r'\*\*\s+(Error|Fatal):', log_text)
result = {'test': 'direct_read_lockstep', 'passed': passed, 'exit_code': run.returncode,
          'first_frame': first, 'last_frame_exclusive': last,
          'seconds': round(time.time()-start, 2), 'reader_sha256': source_hash,
          'reader_unchanged_during_test': source_hash == hashlib.sha256(reader.read_bytes()).hexdigest(),
          'evidence': evidence}
(OUT / 'results.json').write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
if first == 2 and last == 3:
    case_result = dict(result, case2_passed=passed, full_requested_suite_completed=passed,
                       completed_cases=[2] if passed else [], requested_cases=[2])
    (OUT / 'case2_results.json').write_text(json.dumps(case_result, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
print(json.dumps(result, ensure_ascii=False, indent=2), flush=True)
if not passed:
    print('\n'.join(log_text.splitlines()[-45:]), flush=True)
sys.exit(0 if passed else 1)
