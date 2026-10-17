"""Package a completed build of the allocator-only fix, with source checks."""
from pathlib import Path
import datetime, difflib, hashlib, json, re, shutil, sys
from package_overlay_candidate import parse_timing, parse_resources, prepare_project

ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT.parent/'lab_image_photo_overlay_20261015'
SEED=int(sys.argv[1]) if len(sys.argv)>1 else 23
RUN=f'phy_seed{SEED}'
WORK=ROOT/'src/td_project/image_multiview_gui_Runs'/RUN
OUT=ROOT/'reports/cache_tailfix'
REL=ROOT/'release'

def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def read(path): return json.loads(path.read_text(encoding='utf-8-sig'))
def norm(data): return {k.replace('\\','/'):v for k,v in data.items()}
def dump(path,data): path.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')

baseline=read(ROOT/'baseline/source_manifest.json')
all_sources={p.relative_to(ROOT).as_posix():sha(p) for p in (ROOT/'src/user_source').rglob('*') if p.is_file()}
changed=[k for k in sorted(set(baseline)|set(all_sources)) if baseline.get(k)!=all_sources.get(k)]
only='src/user_source/hdl_source/SD/sd_site_assets.v'
assert changed==[only],changed
assert all(sha(BASE/k)==value for k,value in baseline.items()),'baseline modified since copy'
sources={k:v for k,v in all_sources.items() if Path(k).suffix.lower() in ('.v','.vh','.sdc','.adc','.tcl')}
builds={}
for stage in ('syn_1',RUN):
    builds[stage]=read(OUT/stage/'build_result.json')
    assert builds[stage]['pass'] and builds[stage]['sources_unchanged'] and builds[stage]['artifact_new'],stage
    assert sources==norm(read(OUT/stage/'source_manifest.json')),stage
test=read(OUT/'simulation/results.json')
assert test['pass'] and test['results'][1]['rtl_sha256']==all_sources[only]
assert test['results'][1]['test_sha256']==sha(ROOT/'sim/tb_cache_tailfix.v')
cfg=read(ROOT/'reports/dynamic_text/config_simulation/results.json')
assert cfg['pass'] and cfg['rtl_sha256']==all_sources[only]
started=read(OUT/RUN/'process.json')['started_epoch']
for name in ('image_multiview_gui.bit','final_timing.rpt','image_multiview_gui_phy.area'):
    assert (WORK/name).stat().st_mtime>=started,('stale artifact',name)
res=parse_resources(WORK,OUT/RUN/'td_console.log')
limits={'mslice':4900,'lut':19600,'reg':19600,'bram9k':64,'dsp':29}
assert all(res[k]<=v for k,v in limits.items()),res
timing=parse_timing(WORK/'final_timing.rpt')
old_timing=parse_timing(BASE/'release/overlay_seed23_timing.rpt')
old_res=read(BASE/'release/manifest.json')['resources']
comparisons=[]
for folder in sorted(OUT.glob('phy_seed*')):
    if not (folder/'build_result.json').exists(): continue
    build=read(folder/'build_result.json')
    if not build.get('pass'): continue
    assert sources==norm(read(folder/'source_manifest.json'))
    run_dir=ROOT/'src/td_project/image_multiview_gui_Runs'/folder.name
    comparisons.append({'run':folder.name,'selected':folder.name==RUN,
       'resources':parse_resources(run_dir,folder/'td_console.log'),
       'timing':parse_timing(run_dir/'final_timing.rpt')})
project_text=prepare_project(SEED)
candidate=REL/f'image_nav_cache_tailfix_seed{SEED}_untested.bit'
assert sha(ROOT/'baseline/image_nav_baseline_20261015.bit')==sha(BASE/'release/image_nav_final_20261015.bit')
shutil.copy2(WORK/'image_multiview_gui.bit',candidate)
shutil.copy2(WORK/'final_timing.rpt',REL/f'tailfix_seed{SEED}_timing.rpt')
shutil.copy2(WORK/'image_multiview_gui_phy.area',REL/f'tailfix_seed{SEED}_area.rpt')
patch=''.join(difflib.unified_diff((BASE/only).read_text(encoding='utf-8-sig').splitlines(keepends=True),
  (ROOT/only).read_text(encoding='utf-8-sig').splitlines(keepends=True),fromfile='baseline/'+only,tofile='tailfix/'+only))
(REL/'source_changes.patch').write_text(patch,encoding='utf-8')
manifest={'date':'2026-10-16','base_project':str(BASE),'project':str(ROOT/'src/td_project/image_multiview_gui.al'),
 'physical_run':RUN,'candidate':candidate.name,'candidate_sha256':sha(candidate),'board_test':'pending',
 'modified_sources':changed,'source_manifest':sources,'builds':builds,'allocator_simulation':test,
 'config_simulation':cfg,'resources':res,'resource_limits':limits,'baseline_resources':old_res,
 'timing':timing,'baseline_timing':old_timing,'implementation_comparison':comparisons,
 'prefetch_order_changed':False,'cancellation_changed':False,
 'constraints_changed':False,'site_cfg_changed':False,'baseline_bitstream_sha256':sha(ROOT/'baseline/image_nav_baseline_20261015.bit')}
dump(REL/'manifest.json',manifest)
dump(OUT/'implementation_comparison.json',comparisons)
(ROOT/'src/td_project/image_multiview_gui.al').write_text(
    '<?xml version="1.0" encoding="UTF-8"?>\n'+project_text.replace(
      'Photo overlay retaining detail background; board test pending',
      'Cache tail ownership fix only; board test pending')+'\n',encoding='utf-8')
rows='\n'.join(f'| {k} | {old_res[k]} | {res[k]} |' for k in limits)
hold=timing['min_types_reported']['hold']
removal=timing['min_types_reported']['removal']
comparison_rows='\n'.join(f"| {x['run']} | {x['resources']['mslice']} | {x['timing']['other_max_negative_endpoints']} | {x['timing']['min_wns_ns']} | {'选用' if x['selected'] else '未选用'} |" for x in comparisons)
validation=f'''# 尾槽占用修复验证记录

2026-10-16。候选：`{candidate.name}`。上板验证待完成。

## 改动范围

只有 `src/user_source/hdl_source/SD/sd_site_assets.v` 改变。其余109个源文件均与原版字节一致；引脚、时钟约束、调度器、预加载顺序、取消策略、读控制器和显示逻辑保持原样。TF卡图片及SITE.CFG无需更新。

原分配器把 `valid=0` 当作物理槽空闲，但大地图尾槽的valid也是0。本版根据有效图片的footprint识别实际占用，尾槽使用所属图片的age参与替换。真正空槽仍优先使用；较旧且未保护的地图仍允许淘汰。跨两个不连续槽的分配及原保护规则继续有效。

## 验证

- 同一套回归在原版第一项复现误占尾槽，在修复版通过{test['results'][1]['cases']}组分配场景、{test['results'][1]['checks']}项检查。
- 覆盖尾槽先于根槽、非连续两槽、旧地图正常淘汰、空槽、失效footprint、正在显示/事务持有/主图固定/预加载保护，以及空间不足时完整保留旧缓存。
- 资源管理器V6配置回归12项通过，检查50818次字模写入，含温复位、格式错误和文件读取异常。
- 上述分配仿真预置缓存元数据，验证真实资源管理器状态机；不代替TF卡、SDRAM电气和上板交互测试。
- 综合及布局布线完成，新位流与全部构建记录的源码哈希一致。

## 资源与时序

| 资源 | 原版seed23 | 本版seed{SEED} |
|---|---:|---:|
{rows}

| 时序指标 | 原版seed23 | 本版seed{SEED} |
|---|---:|---:|
| Max最差余量/ns | {old_timing['setup_wns_ns']} | {timing['setup_wns_ns']} |
| Max负端点 | {old_timing['max_negative_endpoints']} | {timing['max_negative_endpoints']} |
| SDRAM接口Max负端点 | {old_timing['sdram_max_negative_endpoints']} | {timing['sdram_max_negative_endpoints']} |
| 其他Max负端点 | {old_timing['other_max_negative_endpoints']} | {timing['other_max_negative_endpoints']} |
| Min最差余量/ns | {old_timing['min_wns_ns']} | {timing['min_wns_ns']} |
| Min负端点 | {old_timing['min_negative_endpoints']} | {timing['min_negative_endpoints']} |

本次没有改变时钟/引脚约束，也没有添加时序例外。完整分组和路径记录见时序报告与manifest。

Min负端点分为hold（保持时间）{hold['negative_endpoints_reported']}个、最差{hold['worst_slack_ns']} ns，以及removal（复位撤销）{removal['negative_endpoints_reported']}个、最差{removal['worst_slack_ns']} ns。当前仍未完全收敛，尚未上板验证。

三次物理实现使用同一份综合结果和约束，仅改变布局种子。选择额外内部Max违例为0的实现。

| 实现 | MSlice | SDRAM接口以外Max负端点 | Min最差/ns | 状态 |
|---|---:|---:|---:|---|
{comparison_rows}

## 上板对照

保持相同TF卡、配置和操作：先运行 `baseline/image_nav_baseline_20261015.bit`，再运行本候选。重点观察1/3楼地图缓存完成后连续进入房间详情是否减少地图重读，同时复测2楼、轮播、地图切换、缩放和大图淡化。建议记录每次“地图加载中”出现的时机；提示消失可能是取消，也可能是加载完成。

本版只消除尾槽误判引起的淘汰；预加载未完成时被前台请求中止、真实缓存未命中及单槽地图正常淘汰仍按原策略处理。

位流SHA256：`{sha(candidate)}`。
'''
(REL/'验证记录.md').write_text(validation,encoding='utf-8')
(ROOT/'README.md').write_text(f'''# 六槽缓存尾槽占用修复副本

基于 `lab_image_photo_overlay_20261015` 报告定稿工程，仅修改资源管理器的物理槽占用和候选年龄判断。

- TD工程：`src/td_project/image_multiview_gui.al`，活动实现`{RUN}`。
- 候选位流：`release/{candidate.name}`，尚未上板验证。
- 对照原版：`baseline/image_nav_baseline_20261015.bit`。
- TF卡图片和SITE.CFG无需更新。预加载顺序、取消策略、按键和显示效果保持原样。
- 测试、资源、时序：`release/验证记录.md`；源码差异：`release/source_changes.patch`。

大地图尾槽继承所属图片的占用和age，避免将其当作空槽优先覆盖。地图仍可在真正符合淘汰条件时被替换。

本轮分配回归{test['results'][1]['cases']}组、配置回归12项通过；MSlice {res['mslice']}/4900，BRAM9K {res['bram9k']}/64，DSP {res['dsp']}/29。Max最差余量{timing['setup_wns_ns']} ns，Min最差余量{timing['min_wns_ns']} ns。最终效果待板上对照确认。
''',encoding='utf-8')
print(json.dumps({'candidate':str(candidate),'sha256':sha(candidate),'resources':res,
 'max_wns_ns':timing['setup_wns_ns'],'min_wns_ns':timing['min_wns_ns'],
 'other_max_negative_endpoints':timing['other_max_negative_endpoints'],'board_test':'pending'},ensure_ascii=False,indent=2))
