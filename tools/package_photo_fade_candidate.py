"""Package only a successfully built, simulated candidate; board status stays pending."""
from pathlib import Path
import hashlib, json, shutil, difflib, datetime, sys, re

ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT.parent/'lab_image_dynamic_text_20261012'
RELEASE=ROOT/'release'
run_name=sys.argv[1] if len(sys.argv)>1 else 'phy_1'
assert run_name=='phy_1' or re.fullmatch(r'phy_seed\d+',run_name)
RUN=ROOT/'src/td_project/image_multiview_gui_Runs'/run_name
seed=int(re.search(r'<seed>(\d+)</seed>',(RUN/'image_multiview_gui.prj').read_text(encoding='utf-8')).group(1))
checks={
 'synthesis':'reports/photo_fade/syn_1/build_result.json',
 'physical':f'reports/photo_fade/{run_name}/build_result.json',
 'control':'reports/nav_keys/simulation/results.json',
 'broker':'reports/photo_fade/simulation/broker_photo_fade_results.json',
 'reader':'reports/photo_full_reader/results.json',
 'compositor':'reports/photo_fade/compositor_sim/results.json',
}
results={}
for name,relative in checks.items():
 data=json.loads((ROOT/relative).read_text(encoding='utf-8'))
 passed=all(x['pass'] for x in data) if isinstance(data,list) else data.get('pass',data.get('passed',False))
 assert passed, (name,data)
 results[name]=data
reader=ROOT/'src/user_source/hdl_source/SD/scene_frame_reader.v'
assert results['reader']['reader_sha256']==hashlib.sha256(reader.read_bytes()).hexdigest(), 'Reader changed after verification'
supplement=json.loads((ROOT/'reports/direct_read_lockstep/case2_results.json').read_text(encoding='utf-8'))
assert supplement['case2_passed'] and supplement['reader_sha256']==results['reader']['reader_sha256']
bit=RUN/'image_multiview_gui.bit'
build_start=json.loads((ROOT/f'reports/photo_fade/{run_name}/process.json').read_text())['started_epoch']
assert bit.stat().st_mtime>=build_start
for name in ['pin.adc','timing.sdc']:
 rel=Path('src/user_source/constraints_source')/name
 assert (ROOT/rel).read_bytes()==(BASE/rel).read_bytes(), f'Unexpected constraint edit: {name}'
assert (RELEASE/'SITE.CFG').read_bytes()==(BASE/'release/SITE.CFG').read_bytes()
candidate=RELEASE/f'image_nav_photo_fade_seed{seed}_untested.bit'
shutil.copy2(bit,candidate)
for source,target in [(RUN/'final_timing.rpt',f'photo_fade_seed{seed}_timing.rpt'),
                      (RUN/'image_multiview_gui_phy.area',f'photo_fade_seed{seed}_area.rpt')]:
 shutil.copy2(source,RELEASE/target)
modified=[]
patch=[]
for p in sorted((ROOT/'src/user_source').rglob('*')):
 if not p.is_file():continue
 rel=p.relative_to(ROOT)
 old=BASE/rel
 if not old.exists() or p.read_bytes()!=old.read_bytes():
  modified.append({'file':rel.as_posix(),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
  if p.suffix in ('.v','.vh','.sdc','.adc'):
   before=old.read_text(encoding='utf-8').splitlines(keepends=True) if old.exists() else []
   patch.extend(difflib.unified_diff(before,p.read_text(encoding='utf-8').splitlines(keepends=True),fromfile='base/'+rel.as_posix(),tofile='photo_fade/'+rel.as_posix()))
(RELEASE/'source_changes.patch').write_text(''.join(patch),encoding='utf-8')
manifest={'packaged_at':datetime.datetime.now().astimezone().isoformat(),
 'baseline':str(BASE),'project':str(ROOT/'src/td_project/image_multiview_gui.al'),
 'candidate':candidate.name,'candidate_sha256':hashlib.sha256(candidate.read_bytes()).hexdigest(),
 'board_test':'pending','seed':seed,'physical_run':run_name,'constraints_unchanged':True,'site_cfg_unchanged':True,
 'modified_sources':modified,'verification':results,'supplemental_completed_case':supplement,
 'timing_note':'See included report. Build success does not mean all timing constraints are met.'}
(RELEASE/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({k:manifest[k] for k in ['candidate','candidate_sha256','board_test','modified_sources']},ensure_ascii=False,indent=2))
