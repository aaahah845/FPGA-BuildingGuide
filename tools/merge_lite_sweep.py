"""合并追加种子；未完成/中止项独立列出，不伪造时序结果。"""
from pathlib import Path
import hashlib,json,shutil,subprocess,sys,time
ROOT=Path(__file__).resolve().parents[1]
REPORT=ROOT/'reports/nav_keys';RUNS=ROOT/'src/td_project/image_multiview_gui_Runs'
seeds=[23,11,7,1,42,31,19,53,3,17,29,61,73]
read=lambda p:json.loads(p.read_text(encoding='utf-8'))
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
original=REPORT/'seed_sweep_initial_12.json'
assert not original.exists()
initial=read(REPORT/'seed_sweep.json')
assert initial['builds_completed']==12,'initial driver is still running'
assert sha(RUNS/'syn_1/image_multiview_gui_gate.db')==initial['gate_db_sha256_before']==initial['gate_db_sha256_after']
shutil.copy2(REPORT/'seed_sweep.json',original)
completed=[];excluded=[]
for s in seeds:
    name='phy_1' if s==23 else f'phy_seed{s}'
    result=read(REPORT/name/'build_result.json')
    process=read(REPORT/name/'process.json')
    result.update({'seed':s,'started_epoch':process['started_epoch'],
                   'finished_epoch':process['started_epoch']+result['seconds']})
    if result['pass'] and (RUNS/name/'final_timing.rpt').exists():completed.append(result)
    else:
        stop=REPORT/name/'manual_stop.json'
        result['reason']='manually stopped after at least 12 other complete runs; routing had not converged' if stop.exists() else 'flow did not finish successfully'
        result['timing_evaluated']=False
        if stop.exists():result['stop_record']=read(stop)
        excluded.append(result)
assert len(completed)>=12
record={'seeds':[r['seed'] for r in completed],'attempted_seeds':seeds,'attempted_count':len(seeds),
        'max_parallel_jobs':4,'started_epoch':initial['started_epoch'],
        'completed':completed,'excluded_attempts':excluded,'builds_completed':len(completed),
        'all_flows_succeeded':all(r['pass'] for r in completed),'all_attempts_succeeded':not excluded,
        'gate_db_sha256_before':initial['gate_db_sha256_before'],'gate_db_sha256_after':sha(RUNS/'syn_1/image_multiview_gui_gate.db'),
        'source_changes_during_sweep':False,'seconds':round(time.time()-initial['started_epoch'],1),
        'supplement_reason':'seed7 remained in routing for over half an hour; seed73 added to obtain at least 12 complete results; no RTL or strategy change'}
(REPORT/'seed_sweep.json').write_text(json.dumps(record,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
subprocess.run([sys.executable,str(ROOT/'tools/summarize_nav_build.py'),*[r['run'] for r in completed]],check=True)
print(json.dumps({'completed_seeds':record['seeds'],'excluded_seeds':[r['seed'] for r in excluded]},ensure_ascii=False))
