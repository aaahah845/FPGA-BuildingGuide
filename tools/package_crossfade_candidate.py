"""Publish the tested source/build pair, leaving board validation pending."""
from pathlib import Path
import datetime, difflib, hashlib, json, re, shutil

ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT.parent/'lab_image_photo_fade_20261014'
RUN=ROOT/'src/td_project/image_multiview_gui_Runs/phy_seed23'
RELEASE=ROOT/'release'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def readj(p):return json.loads((ROOT/p).read_text(encoding='utf-8'))
checks={
 'synthesis':'reports/photo_crossfade/syn_1/build_result.json',
 'physical':'reports/photo_crossfade/phy_seed23/build_result.json',
 'control':'reports/nav_keys/simulation/results.json',
 'broker':'reports/photo_fade/simulation/broker_photo_fade_results.json',
 'reader':'reports/photo_full_reader/results.json',
 'compositor':'reports/photo_fade/compositor_sim/results.json',
 'existing_bilinear':'reports/direct_read_lockstep/results.json',
 'vendor_contention':'reports/vendor_crossfade/results.json',
}
results={k:readj(v) for k,v in checks.items()}
for k,d in results.items():
    assert all(x.get('pass',x.get('passed',False)) for x in (d if isinstance(d,list) else [d])),(k,d)
for stage in ('syn_1','phy_seed23'):
    for p,h in readj(f'reports/photo_crossfade/{stage}/source_manifest.json').items():
        assert sha(ROOT/p)==h,('source changed after build',stage,p)
reader_hash=sha(ROOT/'src/user_source/hdl_source/SD/scene_frame_reader.v')
for k in ('reader','existing_bilinear','vendor_contention'):
    assert results[k]['reader_sha256']==reader_hash
    assert results[k]['reader_unchanged_during_test']
for p in ('pin.adc','timing.sdc'):
    rel=Path('src/user_source/constraints_source')/p
    assert (ROOT/rel).read_bytes()==(BASE/rel).read_bytes()
assert (RELEASE/'SITE.CFG').read_bytes()==(BASE/'release/SITE.CFG').read_bytes()
assert (RUN/'image_multiview_gui.bit').stat().st_mtime>=readj('reports/photo_crossfade/phy_seed23/process.json')['started_epoch']
report=(RUN/'final_timing.rpt').read_text(encoding='utf-8')
groups=[]
for part in report.split('Path Group     :')[1:]:
    name=part.splitlines()[0].strip()
    entry={'group':name}
    for label in ('Max','Min'):
        m=re.search(r'^'+label+r'\s*: [SH]WNS\s+(-?[\d.]+)ns, [SH]TNS\s+(-?[\d.]+)ns,\s+(\d+) Viol Endpoints',part,re.M)
        if m:entry[label]={'wns_ns':float(m[1]),'tns_ns':float(m[2]),'negative_endpoints':int(m[3])}
    if 'Max' in entry or 'Min' in entry:groups.append(entry)
area=(RUN/'image_multiview_gui_phy.area').read_text(encoding='utf-8')
physical_log=(ROOT/'reports/photo_crossfade/phy_seed23/td_console.log').read_text(encoding='utf-8',errors='replace')
resource={}
for k in ('lut','reg','bram9k','dsp'):
    m=re.search(r'^\s*#'+k+r'\s+(\d+)(?:\s+out of\s+(\d+))?',area,re.M)
    resource[k]=int(m[1])
resource['mslice']=int(re.findall(r'(\d+) mslices',physical_log)[-1])
timing={
 'setup_wns_ns':float(re.search(r'SWNS:\s*(-?[\d.]+)ns',report)[1]),
 'min_wns_ns':float(re.search(r'HWNS:\s*(-?[\d.]+)ns',report)[1]),
 'groups':groups,
}
candidate=RELEASE/'image_nav_photo_crossfade_seed23_untested.bit'
shutil.copy2(RUN/'image_multiview_gui.bit',candidate)
shutil.copy2(RUN/'final_timing.rpt',RELEASE/'crossfade_seed23_timing.rpt')
shutil.copy2(RUN/'image_multiview_gui_phy.area',RELEASE/'crossfade_seed23_area.rpt')
modified=[];patch=[]
for p in sorted((ROOT/'src/user_source').rglob('*')):
    if not p.is_file():continue
    rel=p.relative_to(ROOT);old=BASE/rel
    if old.exists() and p.read_bytes()==old.read_bytes():continue
    modified.append({'file':rel.as_posix(),'sha256':sha(p)})
    if p.suffix in ('.v','.vh','.sdc','.adc'):
        before=old.read_text(encoding='utf-8').splitlines(keepends=True) if old.exists() else []
        patch.extend(difflib.unified_diff(before,p.read_text(encoding='utf-8').splitlines(keepends=True),fromfile='black_transition/'+rel.as_posix(),tofile='direct_crossfade/'+rel.as_posix()))
(RELEASE/'source_changes.patch').write_text(''.join(patch),encoding='utf-8')
manifest={'packaged_at':datetime.datetime.now().astimezone().isoformat(),
 'base_copy':str(BASE),'project':str(ROOT/'src/td_project/image_multiview_gui.al'),
 'candidate':candidate.name,'candidate_sha256':sha(candidate),'board_test':'pending',
 'constraints_unchanged':True,'site_cfg_unchanged':True,'resources':resource,'timing':timing,
 'modified_sources':modified,'verification':results,
 'transition_format':'Two RGB565 pixels per existing 32-bit FIFO word; nearest detail sampling during mixed frames; stable views retain RGB888 and selected filter.',
 'startup_note':'The earlier black-transition copy intermittently started black and recovered after power cycling or card reinsertion. No established cause; this copy has not been tested on hardware.'}
(RELEASE/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
rows=[]
for g in groups:
    if any(g.get(k,{}).get('negative_endpoints',0) for k in ('Max','Min')) or g['group'] in ('video_clk -> video_clk','sd_card_clk -> sd_card_clk','ext_mem_clk -> ext_mem_clk','hdmi_5x_clk -> hdmi_5x_clk'):
        mx=g.get('Max',{});mn=g.get('Min',{})
        rows.append(f"| `{g['group']}` | {mx.get('wns_ns','—')} | {mx.get('negative_endpoints','—')} | {mn.get('wns_ns','—')} | {mn.get('negative_endpoints','—')} |")
validation=f'''# 直接交叉淡化：验证记录（2026-10-15）

当前候选 `{candidate.name}` 已完成仿真、综合和布局布线，尚未上板。构建成功不等于全部静态时序满足。

## 功能与连续供图

- 调度器：打开、返回、中途反向、等待详情加载、轮播暂停及复位通过。
- 控制器：大图操作和原按键交互回归通过。
- 独立像素模型：详情 → 索引混合 → 全图 → 地图混合 → 详情，5 帧共 240 万像素；包含 SDRAM 返回间断、FIFO 连续消费、跨帧描述锁存和槽保护掩码检查。
- 安路加密 SDRAM 控制器时序模型：1024×600 跨槽地图混合帧 48 万像素，后台写入和刷新同时运行，通过像素与供图检查。该测试使用控制器实际返回时序配合地址生成的测试纹理，不是板级 SDRAM 电气测试。
- 原双线性路径：一帧 48 万像素、1644368 个时钟周期与参考读控制器逐拍一致。
- 合成器：586400 个像素，覆盖权重 0、1、8、15、16、两种详情、原尺寸边界和六拍像素/同步对齐。其中仅原尺寸照片用完整光栅，其余为重点行采样。
- 早期短读段方案在压力仿真中出现供图不足，已更换为混合帧 128 像素段，并使地图底图采样与 SDRAM 返回重叠；未发布早期方案。

## 资源

MSlice {resource['mslice']}/4900；LUT {resource['lut']}/19600；REG {resource['reg']}/19600；BRAM9K {resource['bram9k']}/64；DSP {resource['dsp']}/29。没有增加 BRAM、DSP 或整帧缓存，资源余量仍很小。

## 时序

全局 Max 最差 {timing['setup_wns_ns']} ns，Min 最差 {timing['min_wns_ns']} ns。Min 包含 hold/removal 等检查，具体类型须看路径详情。

| 路径组 | Max 最差/ns | Max 负端点 | Min 最差/ns | Min 负端点 |
|---|---:|---:|---:|---:|
{chr(10).join(rows)}

引脚与时钟约束和上一版完全相同，没有新增 false path 或 multicycle。剩余负余量不能因仿真通过而忽略；本版需要上板验证。

## 文件对应

- 位流 SHA-256：`{sha(candidate)}`
- 读控制器 SHA-256：`{reader_hash}`
- 实现目录：`src/td_project/image_multiview_gui_Runs/phy_seed23/`
- 完整结果、源码校验值与测试结果：`release/manifest.json`
- 相对旧黑场版的代码差异：`release/source_changes.patch`
'''
(RELEASE/'验证记录.md').write_text(validation,encoding='utf-8')
readme=f'''# 详情照片直接淡入淡出副本（2026-10-15）

基于 `lab_image_photo_fade_20261014` 建立，旧工程和旧位流保留。本版改为两幅画面直接交叉淡化：打开时，大图逐渐覆盖详情；返回时，详情逐渐显现。没有中间的黑屏或黑场等待。

## 下载与操作

- 位流：`release/{candidate.name}`，尚未上板。
- TD 工程：`src/td_project/image_multiview_gui.al`，活动物理实现为 `phy_seed23`。
- 详情打开后再次按 MID / SW4 确认，显示居中的完整 640×480 照片；按 RST / SW3 返回详情。
- 每帧改变 1/16 混合权重，一次完整过渡约 16 帧（60 Hz 下约 0.27 秒）。中途返回从当前透明度反向变化。
- 全图与过渡期间保留房间选择和详情，暂停新轮播，阻止导航/占用手势；参数面板仍可使用。
- TF 卡图片及 V6 SITE.CFG 不需要修改，保留现有自定义文字。

## 实现说明

1. 调度器在帧边界更新大图的覆盖比例；0 为详情，16 为全图，1～15 为混合帧。
2. 读控制器按段取得底图像素，将其暂存在双线性缓存既有的空闲地址区，再读取同一屏幕位置的大图像素。地图底图采样与内存返回重叠，保持连续供图。
3. 混合帧把两组 RGB565 像素装入原有 32 位读 FIFO；正常详情和稳定全图保留原来的 RGB888 数据。
4. 合成器先绘制详情的文字、标记和面板，再用原有混合器叠入大图及留白。六拍流水延迟不变。
5. 混合期间底图临时采用最近邻采样；结束后恢复用户选择的采样方式。双线性设置本身不改变。过渡帧的颜色精度为 RGB565，稳定画面的颜色精度不变。

关键源码：`site_scene_broker.v`、`SD/scene_frame_reader.v`、`SD/bilinear_span_cache.v`、`SD/frame_read_write.v`、`guide_scene_compositor.v`、`top_tf_hdmi_audio.v`，均在 `src/user_source/hdl_source/` 下。相对黑场版本的详细变化见 `release/source_changes.patch`。

## 验证状态

像素、调度、按键、并发读写/刷新及原双线性回归通过；实际资源与时序见 `release/验证记录.md`。MSlice 为 {resource['mslice']}/4900，BRAM9K 为 {resource['bram9k']}/64，DSP 为 {resource['dsp']}/29。

本版还需验证索引和地图详情的开图/返回、动画中途返回，以及正常缩放。之前黑场版本曾出现启动全黑，随后经重新上电或插拔 TF 卡恢复；原因未确定，不能将本次动画修改视为该启动问题已修复。
'''
(ROOT/'README.md').write_text(readme,encoding='utf-8')
p=ROOT/'src/td_project/image_multiview_gui.al'
s=p.read_text(encoding='utf-8').replace('Photo fade candidate; board test pending','Direct photo crossfade candidate; board test pending')
p.write_text(s,encoding='utf-8')
print(json.dumps({'candidate':str(candidate),'sha256':sha(candidate),'resources':resource,'timing':timing,'modified_sources':modified},ensure_ascii=False,indent=2))
