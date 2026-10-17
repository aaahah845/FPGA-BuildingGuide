"""Package this candidate only after build and targeted regressions pass."""
from pathlib import Path
import difflib, hashlib, json, re, shutil

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT.parent/'lab_image_nav_keys_lite_20261011'
EV = ROOT/'reports/title_config'
RUN = ROOT/'src/td_project/image_multiview_gui_Runs/phy_1'

def read(path):
    return path.read_text(encoding='utf-8-sig', errors='replace')

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def timing(path):
    text = read(path)
    groups = []
    sections = list(re.finditer(r'^Path Group\s*:\s*([^\r\n]+)', text, re.M))
    for i, match in enumerate(sections):
        part = text[match.end():sections[i+1].start() if i+1<len(sections) else len(text)]
        row = {'name':match[1].strip()}
        for key, label in (('setup','Max'), ('min','Min')):
            stat = re.search(rf'^{label}\s*:\s*[SH]WNS\s*([-\d.]+)ns,\s*[SH]TNS\s*([-\d.]+)ns,\s*(\d+) Viol Endpoints',part,re.M)
            if stat:
                row[key] = {'wns_ns':float(stat[1]),'tns_ns':float(stat[2]),'violated_endpoints':int(stat[3])}
        groups.append(row)
    return {'report_sha256':sha(path), 'groups':groups,
            'setup_violated_endpoints':sum(g.get('setup',{}).get('violated_endpoints',0) for g in groups),
            'min_violated_endpoints':sum(g.get('min',{}).get('violated_endpoints',0) for g in groups),
            'global_setup_ns':float(re.search(r'SWNS:\s*([-\d.]+)ns',text)[1]),
            'global_min_ns':float(re.search(r'HWNS:\s*([-\d.]+)ns',text)[1]),
            'internal_setup_ns':{clock:next(g['setup']['wns_ns'] for g in groups if g['name']==f'{clock} -> {clock}') for clock in ('video_clk','sd_card_clk','ext_mem_clk')}}

tests = {name:json.loads(read(path)) for name,path in {
    'export':EV/'export_tests.json', 'pixels':EV/'simulation/results.json'}.items()}
assert all(test['pass'] for test in tests.values()), tests
assert tests['pixels']['candidate_sha256']==sha(ROOT/'src/user_source/hdl_source/guide_scene_compositor.v')
for name, artifact in (('syn_1','image_multiview_gui_gate.db'),('phy_1','image_multiview_gui.bit')):
    logs = ROOT/'reports/nav_keys'/name
    result = json.loads(read(logs/'build_result.json'))
    process = json.loads(read(logs/'process.json'))
    assert result['pass'], result
    assert (RUN.parent/name/artifact).stat().st_mtime >= process['started_epoch']

before = json.loads(read(EV/'baseline_sha256.json'))
assert all(sha(SOURCE/name)==digest for name,digest in before.items()), 'Original project changed'
changed = [name for name,digest in before.items() if name.startswith('src/user_source/') and sha(ROOT/name)!=digest]
assert set(changed)=={'src/user_source/hdl_source/guide_scene_compositor.v','src/user_source/hdl_source/SD/sd_site_assets.v'}, changed
diff = ''.join(''.join(difflib.unified_diff(read(SOURCE/name).splitlines(True),read(ROOT/name).splitlines(True),fromfile='baseline/'+name,tofile='candidate/'+name)) for name in changed)
(EV/'rtl_changes.diff').write_text(diff,encoding='utf-8')

new = timing(RUN/'final_timing.rpt')
baseline = timing(EV/'baseline_seed61/final_timing.rpt')
area = read(RUN/'image_multiview_gui_phy.area')
resources = {k:int(re.search(r'^\s*#'+k+r'\s+(\d+)\b',area,re.M)[1]) for k in ('lut','reg','bram9k','bram32k','dsp')}
physical_log = read(ROOT/'reports/nav_keys/phy_1/td_console.log')
resources['mslices'] = int(re.findall(r': (\d+) mslices, (\d+) lslices',physical_log)[-1][0])
assert resources['mslices']<=4900 and resources['bram9k']<=64

release = ROOT/'release'
release.mkdir(exist_ok=True)
bit = release/'image_nav_title_config_seed61_untested.bit'
for origin, dest in (('image_multiview_gui.bit',bit.name),('final_timing.rpt','final_timing.rpt'),('image_multiview_gui_phy.area','resource.rpt'),('route.qor','route.qor')):
    shutil.copy2(RUN/origin,release/dest)
cfg = ROOT/'config/sd_card/SITE.CFG'
manifest = {'date':'2026-10-12','baseline':SOURCE.name,'seed':61,
    'bit_file':bit.name,'bit_sha256':sha(bit),'board_test_status':'not_tested',
    'modified_existing_rtl':changed,'original_files_verified_unchanged':len(before),
    'constraints_and_clocks_unchanged':True,'default_title':'企业会议导视',
    'maximum_title_characters':8,'requires_existing_glyphs':True,
    'config_file':'../config/sd_card/SITE.CFG','config_sha256':sha(cfg),
    'tests':tests,'resources':resources,'timing':new,'baseline_timing':baseline,
    'timing_closed':new['setup_violated_endpoints']==0 and new['min_violated_endpoints']==0,
    'internal_setup_closed':all(value>=0 for value in new['internal_setup_ns'].values()),
    'promoted_over_board_tested_version':False}
(release/'candidate_manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
summary = f'''# 构建与验证结果

本次完成综合、布局布线和位流生成，尚未上板；原种子61的上板结果不能替代本副本验证。

- 位流：`{bit.name}`
- SHA-256：`{manifest['bit_sha256']}`
- 资源：MSlice {resources['mslices']}/4900，LUT {resources['lut']}，REG {resources['reg']}，BRAM9K {resources['bram9k']}/64，DSP {resources['dsp']}/29。
- 配置导出8项检查与标题真实字模像素仿真均通过，具体结果见 `candidate_manifest.json` 和 `../reports/title_config`。
- 原工程 {len(before)} 个源码、约束、工程及发布文件的SHA-256保持不变。

| 指标 | 原种子61 | 本副本种子61 |
|---|---:|---:|
| video内部setup/ns | {baseline['internal_setup_ns']['video_clk']:+.3f} | {new['internal_setup_ns']['video_clk']:+.3f} |
| SD内部setup/ns | {baseline['internal_setup_ns']['sd_card_clk']:+.3f} | {new['internal_setup_ns']['sd_card_clk']:+.3f} |
| memory内部setup/ns | {baseline['internal_setup_ns']['ext_mem_clk']:+.3f} | {new['internal_setup_ns']['ext_mem_clk']:+.3f} |
| 全局setup/ns | {baseline['global_setup_ns']:+.3f} | {new['global_setup_ns']:+.3f} |
| setup违例端点 | {baseline['setup_violated_endpoints']} | {new['setup_violated_endpoints']} |
| 全局Min/ns | {baseline['global_min_ns']:+.3f} | {new['global_min_ns']:+.3f} |
| Min违例端点 | {baseline['min_violated_endpoints']} | {new['min_violated_endpoints']} |

Min汇总包含hold/removal等最小延迟检查，不能全部称为普通保持违例。完整路径以 `final_timing.rpt` 为准。生成位流不等于时序完全收敛，仍需上板核对标题、页面切换和原有功能。
'''
(release/'README.md').write_text(summary,encoding='utf-8')
print(json.dumps({'bit':str(bit),'resources':resources,'internal_setup_ns':new['internal_setup_ns'],'min_wns_ns':new['global_min_ns'],'min_violations':new['min_violated_endpoints']},ensure_ascii=False))
