from pathlib import Path
import json,hashlib,shutil,difflib
from package_overlay_candidate import parse_timing,parse_resources
b=Path(__file__).resolve().parents[1];base=b.parent/'lab_image_carousel_native_20261022'
w=b/'src/td_project/image_multiview_gui_Runs/phy_seed61';r=b/'release'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_text(encoding='utf-8'))
sources={p.relative_to(b).as_posix():sha(p) for p in (b/'src/user_source').rglob('*') if p.is_file() and p.suffix.lower() in ('.v','.vh','.sdc','.adc','.tcl')}
for stage in ['syn_1','phy_seed61']:
 d=b/'reports/cache_tailfix'/stage
 assert read(d/'build_result.json')['pass']
 assert {k.replace('\\','/'):v for k,v in read(d/'source_manifest.json').items()}==sources
for path in ['reports/carousel_native_compositor/results.json','reports/photo_overlay/compositor_sim/results.json']:
 d=read(b/path);assert d['pass']
 for name,h in d['source_hashes'].items():assert sha(b/name)==h,(name,'stale test')
fade=read(b/'reports/layout_fade/results.json');assert fade['pass'];assert fade['source_sha256']==sha(b/'src/user_source/hdl_source/site_scene_broker.v')
# Reuse earlier full-reader/control evidence only for identical source files.
for rel in ['SD/scene_frame_reader.v','SD/bilinear_span_cache.v','guide_scene_control.v','eased_motion_table.vh']:
 path=Path('src/user_source/hdl_source')/rel;assert sha(b/path)==sha(base/path)
res=parse_resources(w,b/'reports/cache_tailfix/phy_seed61/td_console.log');assert res['mslice']<=4900 and res['dsp']<=29 and res['bram9k']<=64
timing=parse_timing(w/'final_timing.rpt')
bit=r/'image_nav_carousel_native_fade_seed61_untested.bit';shutil.copy2(w/'image_multiview_gui.bit',bit)
for name in ['final_timing.rpt','image_multiview_gui_phy.area']:shutil.copy2(w/name,r/name)
manifest={'bitstream':bit.name,'sha256':sha(bit),'resources':res,'timing':timing,'source_sha256':sources,'board_test':'pending','native_rect':[80,60,640,480],'progress_rect':[80,540,640,6],'progress_exact_input_positions':512,'layout_fade':'content only, alpha 16..0..16, frame-boundary geometry handoff','synthesis':'add_map_lut_struct off, original area settings; one explicit dsp_style=yes native progress multiplier','inherited_evidence':str(base/'release/manifest.json')}
(r/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
changes=[]
for p in (b/'src/user_source').rglob('*'):
 if p.is_file() and p.suffix in ['.v','.vh']:
  rel=p.relative_to(b);old=base/rel
  if old.exists() and sha(old)!=sha(p):changes.extend(difflib.unified_diff(old.read_text(encoding='utf-8').splitlines(True),p.read_text(encoding='utf-8').splitlines(True),fromfile='previous/'+rel.as_posix(),tofile=rel.as_posix()))
(r/'source_changes.patch').write_text(''.join(changes),encoding='utf-8')
note=f"""# 布局淡化修订候选验证记录

位流：`{bit.name}`。电脑端验证通过，尚待上板确认。

## 修订

顶栏在内容背景之后绘制，避免被原尺寸模式覆盖。原尺寸进度条紧接图底，范围x=80～719、y=540～545；去掉61级跳动位置，恢复逐像素进度。用剩余的一个DSP完成精确比例换算，帧边界寄存结果。对全部512个9位输入检查均与floor(4p/3)+80一致。

SW2切换布局时，内容区按16级权重淡出到界面底色；权重为0时交接布局，再淡入。顶栏和底部页面选项保持可见。滑动进行中或详情打开时等待原操作结束。两种布局的轮播换图仍沿用30帧缓动滑动。

为减少占用，七处24像素文字的列号、字内位置和名称基址运算合并为共用路径。房间名称、标题、楼层名称及详情显示采用原配置。

## 检查

- 完整800×600原尺寸扫描及边界行检查通过：原图像素、贴图进度条、顶栏/底部页面在淡化期间逐像素保持一致。
- 512个进度位置全部通过；淡化权重16、8、0通过。
- 布局调度单元检查通过：等滑动结束才开始淡出、仅在完全透明时换布局、淡入完成和返回后释放忙状态。
- 与原合成器对照20种情形、528000像素通过：列表及地图文字、详情开关、大图混合权重0/1/8/15/16、六拍同步配套。
- 读控制器、缓存采样、按键控制和缓动表与上一候选源码相同；此前全帧读图及按键验证见上一副本reports目录。

## 实现资源

| 资源 | 使用量 |
|---|---:|
| MSlice | {res['mslice']}/4900 |
| LUT | {res['lut']}/19600 |
| REG | {res['reg']}/19600 |
| BRAM9K | {res['bram9k']}/64 |
| DSP | {res['dsp']}/29 |

Max最差余量{timing['setup_wns_ns']} ns，Min最差余量{timing['min_wns_ns']} ns。静态时序仍未全部闭合，完整路径见final_timing.rpt。未改变时钟频率和约束，也未新增时序例外。

## 上板

保持原卡与接线下载本候选。先确认原布局顶栏和详情正常，再拨SW2：顶栏/底部页面不消失，中间内容淡出后原尺寸图片淡入，进度条贴图底平滑移动。再次拨SW2检查返回，并复测自动轮播、地图、参数面板及大图淡化。TF卡无需更新。

SHA256：`{sha(bit)}`。
"""
(r/'验证记录.md').write_text(note,encoding='utf-8')
p=b/'README.md';s=p.read_text(encoding='utf-8');s=s.replace('##PLACEHOLDER##','');s+='\n候选位流：`release/'+bit.name+'`。电脑端通过，尚待上板确认。\n';p.write_text(s,encoding='utf-8')
print(json.dumps({'bit':str(bit),'resources':res,'max_wns_ns':timing['setup_wns_ns'],'min_wns_ns':timing['min_wns_ns']},ensure_ascii=False))
