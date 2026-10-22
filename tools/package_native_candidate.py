from pathlib import Path
import sys,json,hashlib,shutil,difflib
from package_overlay_candidate import parse_timing,parse_resources
b=Path(__file__).resolve().parents[1]
w=b/'src/td_project/image_multiview_gui_Runs/phy_seed61'
r=b/'release'
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_text(encoding='utf-8'))
sources={p.relative_to(b).as_posix():sha(p) for p in (b/'src/user_source').rglob('*') if p.is_file() and p.suffix.lower() in ('.v','.vh','.sdc','.adc','.tcl')}
for stage in ['syn_1','phy_seed61']:
 d=b/'reports/cache_tailfix'/stage
 assert read(d/'build_result.json')['pass']
 assert {k.replace('\\','/'):v for k,v in read(d/'source_manifest.json').items()}==sources
for path in ['reports/carousel_native_reader/results.json','reports/photo_full_reader/results.json','reports/carousel_native_compositor/results.json']:
 d=read(b/path);assert d.get('pass',d.get('passed'))
 for name,h in d.get('input_sha256',d.get('source_hashes',{})).items():assert sha(b/name)==h,(name,'stale test')
assert all(v['pass'] for v in read(b/'reports/nav_keys/simulation/results.json'))
res=parse_resources(w,b/'reports/cache_tailfix/phy_seed61/td_console.log')
assert res['mslice']<=4900 and res['bram9k']<=64 and res['dsp']<=29
timing=parse_timing(w/'final_timing.rpt')
bit=r/'image_nav_carousel_native_seed61_untested.bit'
shutil.copy2(w/'image_multiview_gui.bit',bit)
for f in ['final_timing.rpt','image_multiview_gui_phy.area']:shutil.copy2(w/f,r/f)
manifest={'bitstream':bit.name,'sha256':sha(bit),'resources':res,'timing':timing,'board_test':'pending','source_sha256':sources,'switch':'SW2 level 1=native,0=ordinary','native_rect':[80,60,640,480],'progress_rect':[80,564,640,4]}
(r/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
chunks=[]
base=b.parent/'lab_image_cache_tailfix_20261016'
for p in (b/'src/user_source').rglob('*'):
 if p.is_file() and p.suffix in ['.v','.vh']:
  rel=p.relative_to(b);old=base/rel
  if old.exists() and old.read_bytes()!=p.read_bytes():chunks.extend(difflib.unified_diff(old.read_text(encoding='utf-8').splitlines(True),p.read_text(encoding='utf-8').splitlines(True),fromfile='baseline/'+rel.as_posix(),tofile=rel.as_posix()))
(r/'source_changes.patch').write_text(''.join(chunks),encoding='utf-8')
note=f"""# 居中轮播候选验证记录

位流：`{bit.name}`。尚待上板验证。

## 功能检查

- 读控制器：7个完整800×600扫描帧，336万像素逐点比对；覆盖普通／原尺寸布局往返，缓动第0、7、15、29帧，SDRAM有效信号间断、FIFO背压及40MHz视频消耗。帧中改变布局请求不影响当前帧，滑动时旧、新图片槽均受保护。
- 合成器：完整扫描验证307200个照片像素原样输出、列表隐藏、640像素宽进度条；补查半进度／满进度及六拍同步配套。
- 交互：SW2消抖电平切换，关闭隐藏房间选择，短左下一张，长左轮播和地图平移，恢复普通房间选择。
- 回归：6帧普通详情、混合淡化、完整照片和地图背景检查通过，含双线性与SDRAM有效信号间断。
- 电脑端验证依据及源码哈希见reports目录；板上结果尚未填写。

## 编译结果

| 资源 | 使用量 |
|---|---:|
| MSlice | {res['mslice']}/4900 |
| LUT | {res['lut']}/19600 |
| 寄存器 | {res['reg']}/19600 |
| BRAM9K | {res['bram9k']}/64 |
| DSP | {res['dsp']}/29 |

Max最差余量：{timing['setup_wns_ns']} ns；Min最差余量：{timing['min_wns_ns']} ns。静态时序尚未全部闭合。约束沿用基线，没有新增时序例外。完整路径见final_timing.rpt。

原尺寸图片无需插值。原尺寸模式的进度条使用61级位置查找表，以控制资源占用；普通轮播进度和两种布局的图片滑动曲线保持原样。

## 上板步骤

保持原TF卡和接线，下载本候选。SW2=1观察640×480原图、顶栏和底部页面按钮；短左下一张，长左开启／关闭轮播。切回SW2=0复测列表、房间详情、大图淡化，再进入地图复测缩放和平移。也应在切图过程中拨动SW2，确认动画完成后才改变布局。

SHA256：`{sha(bit)}`。
"""
(r/'验证记录.md').write_text(note,encoding='utf-8')
p=b/'README.md';s=p.read_text(encoding='utf-8');s=s.replace('## 下载与操作','候选位流：`release/'+bit.name+'`（电脑端检查通过，尚待上板验证）。\n\n## 下载与操作');p.write_text(s,encoding='utf-8')
print(json.dumps({'bit':str(bit),'resources':res,'setup_wns_ns':timing['setup_wns_ns'],'min_wns_ns':timing['min_wns_ns']},ensure_ascii=False))
