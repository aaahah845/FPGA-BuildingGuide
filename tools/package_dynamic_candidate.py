"""Package only the verified dynamic-font build; never promote as board-tested."""
from pathlib import Path
import difflib,hashlib,json,re,shutil
ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT.parent/'lab_image_title_config_20261012'
EV=ROOT/'reports/dynamic_text'
RUN=ROOT/'src/td_project/image_multiview_gui_Runs/phy_1'
def read(p): return p.read_text(encoding='utf-8-sig',errors='replace')
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def timing(p):
    s=read(p);groups=[]
    sections=list(re.finditer(r'^Path Group\s*:\s*([^\r\n]+)',s,re.M))
    for i,m in enumerate(sections):
        part=s[m.end():sections[i+1].start() if i+1<len(sections) else len(s)]
        row={'name':m[1].strip()}
        for key,label in (('setup','Max'),('min','Min')):
            stat=re.search(rf'^{label}\s*:\s*[SH]WNS\s*([-\d.]+)ns,\s*[SH]TNS\s*([-\d.]+)ns,\s*(\d+) Viol Endpoints',part,re.M)
            if stat: row[key]={'wns_ns':float(stat[1]),'tns_ns':float(stat[2]),'violated_endpoints':int(stat[3])}
        groups.append(row)
    return {'report_sha256':sha(p),'groups':groups,
        'global_setup_ns':float(re.search(r'SWNS:\s*([-\d.]+)ns',s)[1]),
        'global_min_ns':float(re.search(r'HWNS:\s*([-\d.]+)ns',s)[1]),
        'setup_violated_endpoints':sum(g.get('setup',{}).get('violated_endpoints',0) for g in groups),
        'min_violated_endpoints':sum(g.get('min',{}).get('violated_endpoints',0) for g in groups),
        'internal_setup_ns':{c:next(g['setup']['wns_ns'] for g in groups if g['name']==f'{c} -> {c}') for c in ('video_clk','sd_card_clk','ext_mem_clk')}}
def main():
    tests={name:json.loads(read(EV/path)) for name,path in {
        'export':'export_tests.json','fonts':'font_sim/results.json',
        'loader':'config_simulation/results.json','startup_gate':'startup_gate/results.json'}.items()}
    assert all(t['pass'] for t in tests.values()),tests
    for name,digest in tests['export']['tool_sha256'].items(): assert sha(ROOT/name)==digest,name
    for name,digest in tests['export']['config_sha256'].items(): assert sha(ROOT/name)==digest,name
    hdl=ROOT/'src/user_source/hdl_source'
    for name,digest in tests['fonts']['candidate_sha256'].items(): assert sha(hdl/name)==digest,name
    assert sha(hdl/'SD/sd_site_assets.v')==tests['loader']['rtl_sha256']
    assert sha(hdl/'top_tf_hdmi_audio.v')==tests['startup_gate']['top_sha256']
    assert sha(hdl/'video_rgb_to_axis.v')==tests['startup_gate']['axis_sha256']
    cfg=ROOT/'config/sd_card/SITE.CFG'
    assert sha(cfg)==tests['loader']['source_cfg_sha256']
    for name,artifact in (('syn_1','image_multiview_gui_gate.db'),('phy_1','image_multiview_gui.bit')):
        result=json.loads(read(EV/name/'build_result.json'))
        process=json.loads(read(EV/name/'process.json'))
        assert result['pass'],result
        assert (RUN.parent/name/artifact).stat().st_mtime>=process['started_epoch']
        assert all(p.stat().st_mtime<=process['started_epoch'] for p in hdl.rglob('*') if p.is_file()),'Source modified after build began'
    before=json.loads(read(EV/'baseline_sha256.json'))
    assert all(sha(SOURCE/name)==digest for name,digest in before.items()),'Original project changed'
    changed=[name for name,digest in before.items() if name.startswith('src/user_source/') and sha(ROOT/name)!=digest]
    assert all('/constraints_source/' not in name for name in changed)
    diff=''.join(''.join(difflib.unified_diff(read(SOURCE/n).splitlines(True),read(ROOT/n).splitlines(True),fromfile='baseline/'+n,tofile='candidate/'+n)) for n in changed)
    (EV/'rtl_changes.diff').write_text(diff,encoding='utf-8')
    new=timing(RUN/'final_timing.rpt'); baseline=timing(SOURCE/'release/final_timing.rpt')
    area=read(RUN/'image_multiview_gui_phy.area')
    resources={k:int(re.search(r'^\s*#'+k+r'\s+(\d+)\b',area,re.M)[1]) for k in ('lut','reg','bram9k','bram32k','dsp')}
    resources['mslices']=int(re.findall(r': (\d+) mslices, (\d+) lslices',read(EV/'phy_1/td_console.log'))[-1][0])
    assert resources['mslices']<=4900 and resources['bram9k']<=64
    release=ROOT/'release';release.mkdir(exist_ok=True)
    bit=release/'image_nav_dynamic_text_seed61_untested.bit'
    for origin,dest in (('image_multiview_gui.bit',bit.name),('final_timing.rpt','final_timing.rpt'),('image_multiview_gui_phy.area','resource.rpt'),('route.qor','route.qor')):
        shutil.copy2(RUN/origin,release/dest)
    shutil.copy2(cfg,release/'SITE.CFG')
    manifest={'date':'2026-10-12','baseline':SOURCE.name,'seed':61,'bit_file':bit.name,'bit_sha256':sha(bit),
        'board_test_status':'not_tested','modified_existing_rtl':changed,'original_files_verified_unchanged':len(before),
        'modified_rtl_sha256':{name:sha(ROOT/name) for name in changed},
        'constraints_and_clocks_unchanged':True,'config_version':6,'config_bytes':27648,'config_sha256':sha(cfg),
        'dynamic_name_slots':121,'dynamic_notes_slots':85,'max_name_characters':8,'font_coverage_checked':True,
        'tests':tests,'resources':resources,'timing':new,'baseline_timing':baseline,
        'timing_closed':new['setup_violated_endpoints']==0 and new['min_violated_endpoints']==0,
        'promoted_over_board_tested_version':False}
    (release/'candidate_manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    summary=f'''# 动态文字候选构建结果

已生成位流并完成电脑端测试，尚未上板。原种子 61 的演示结果不能替代本副本上板验证。

- 位流：`{bit.name}`，配套本目录 `SITE.CFG`（v6，27648 字节）。
- SHA-256：`{sha(bit)}`。
- MSlice {resources['mslices']}/4900，LUT {resources['lut']}/19600，REG {resources['reg']}，BRAM9K {resources['bram9k']}/64，DSP {resources['dsp']}/29。
- 导出器、双时钟字模 RAM、配置加载及失败分支仿真通过，证据见 `candidate_manifest.json`。
- 原工程 {len(before)} 个文件哈希未变，现有图片读取、预加载流程和引脚/时钟约束未改变。

| 时序指标 | 标题配置副本 | 动态文字副本 |
|---|---:|---:|
| video 内部 setup/ns | {baseline['internal_setup_ns']['video_clk']:+.3f} | {new['internal_setup_ns']['video_clk']:+.3f} |
| SD 内部 setup/ns | {baseline['internal_setup_ns']['sd_card_clk']:+.3f} | {new['internal_setup_ns']['sd_card_clk']:+.3f} |
| memory 内部 setup/ns | {baseline['internal_setup_ns']['ext_mem_clk']:+.3f} | {new['internal_setup_ns']['ext_mem_clk']:+.3f} |
| 全局 setup/ns | {baseline['global_setup_ns']:+.3f} | {new['global_setup_ns']:+.3f} |
| setup 违例端点 | {baseline['setup_violated_endpoints']} | {new['setup_violated_endpoints']} |
| 全局 Min/ns | {baseline['global_min_ns']:+.3f} | {new['global_min_ns']:+.3f} |
| Min 违例端点 | {baseline['min_violated_endpoints']} | {new['min_violated_endpoints']} |

Min 汇总可能包含 hold/removal 等检查。完整路径见 `final_timing.rpt`；生成位流不代表全部时序收敛。

首次上板请使用新位流和新配置这一对文件，核对默认标题、校园示例的新字、房间/楼层/观察点切换、简介活动、音频、参数面板与轮播。修改配置后重新启动；运行中不热更新字体。保留原位流及其旧 SITE.CFG，回退时成对恢复。
'''
    (release/'README.md').write_text(summary,encoding='utf-8')
    print(json.dumps({'bit':str(bit),'resources':resources,'timing':{k:v for k,v in new.items() if k!='groups'}},ensure_ascii=False))
if __name__=='__main__':main()
