"""12 个种子共用一次综合数据库，最多四路并行，每路独立工作目录。"""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib, json, subprocess, sys, time

ROOT=Path(__file__).resolve().parents[1]
REPORT=ROOT/'reports/nav_keys'
RUNS=ROOT/'src/td_project/image_multiview_gui_Runs'
SEEDS=[23,11,7,1,42,31,19,53,3,17,29,61]
JOBS=4
assert json.loads((REPORT/'syn_1/build_result.json').read_text())['pass']
assert not (REPORT/'seed_sweep.json').exists(), 'refuse to overwrite a prior sweep'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
gate=RUNS/'syn_1/image_multiview_gui_gate.db'
gate_sha=sha(gate)
subprocess.run([sys.executable,str(ROOT/'tools/prepare_nav_seeds.py'),*map(str,SEEDS[1:])],check=True)
start=time.time()
config={'seeds':SEEDS,'max_parallel_jobs':JOBS,'started_epoch':start,
        'gate_db_sha256_before':gate_sha,'source_changes_during_sweep':False}
(REPORT/'seed_sweep.json').write_text(json.dumps(config,indent=2),encoding='utf-8')
def run(seed):
    name='phy_1' if seed==23 else f'phy_seed{seed}'
    t=time.time()
    print(f'SEED_START seed={seed}',flush=True)
    p=subprocess.run([sys.executable,str(ROOT/'tools/run_td_stage.py'),name],cwd=ROOT,
                     capture_output=True,text=True,encoding='utf-8',errors='replace',creationflags=subprocess.CREATE_NO_WINDOW)
    (REPORT/name/'runner.log').write_text(p.stdout+p.stderr,encoding='utf-8')
    result=json.loads((REPORT/name/'build_result.json').read_text()) if (REPORT/name/'build_result.json').exists() else {'pass':False}
    result.update({'seed':seed,'started_epoch':t,'finished_epoch':time.time(),'runner_exit_code':p.returncode})
    print('SEED_END '+json.dumps(result),flush=True)
    return result
results=[]
with ThreadPoolExecutor(max_workers=JOBS) as pool:
    futures=[pool.submit(run,s) for s in SEEDS]
    for future in as_completed(futures):
        results.append(future.result())
        config['completed']=results
        (REPORT/'seed_sweep.json').write_text(json.dumps(config,indent=2),encoding='utf-8')
assert sha(gate)==gate_sha, 'shared synthesis database changed'
config.update({'gate_db_sha256_after':sha(gate),'seconds':round(time.time()-start,1),
               'builds_completed':len(results),'all_flows_succeeded':all(x['pass'] for x in results)})
(REPORT/'seed_sweep.json').write_text(json.dumps(config,indent=2),encoding='utf-8')
names=['phy_1' if s==23 else f'phy_seed{s}' for s in SEEDS]
subprocess.run([sys.executable,str(ROOT/'tools/summarize_nav_build.py'),*names],check=True)
print('SWEEP_FINISHED '+json.dumps({k:v for k,v in config.items() if k!='completed'}),flush=True)
sys.exit(0 if config['all_flows_succeeded'] else 1)
