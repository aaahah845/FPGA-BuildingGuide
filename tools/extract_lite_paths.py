"""提取已完成实验的最差内部建立路径，供 Claude 后续定位；不改设计。"""
from pathlib import Path
import json,re
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT.parent/'竞赛学习/05_Codex后续学习与作品规划/跨AI交接_20261011_Codex回交_04/核验'
REPORT=ROOT/'reports/nav_keys';RUNS=ROOT/'src/td_project/image_multiview_gui_Runs'
manifest=ROOT/'release/candidate_manifest.json'
records=json.loads(manifest.read_text(encoding='utf-8'))['run_artifacts'] if manifest.exists() else {
    str(s):{'directory':'phy_1' if s==23 else f'phy_seed{s}'} for s in [23,11,7,1,42,31,19,53,3,17,29,61]}
all_paths=[];all_hold=[]
for seed,record in records.items():
    path=RUNS/record['directory']/'final_timing.rpt'
    if not path.exists():continue
    text=path.read_text(errors='replace');paths=[];hold=[]
    for part in text.split('Path Group')[1:]:
        name=re.match(r'\s*:\s*([^\r\n]+)',part)[1].strip()
        if 'Min Paths' in part:
            for chunk in re.split(r'(?m)(?=^Slack\s+:)',part.split('Min Paths',1)[1]):
                slack=re.match(r'Slack\s*:\s*([\-\d.]+)ns',chunk)
                if not slack or float(slack[1])>=0:continue
                item={'group':name,'slack_ns':float(slack[1])}
                for field in ['Begin Point','End Point','Check Type','Budget','Data Path Delay','Logic Level','Clock Uncertainty']:
                    match=re.search(r'^\s*'+re.escape(field)+r'\s*:\s*([^\r\n]+)',chunk,re.M)
                    assert match,(seed,name,field)
                    item[field]=match[1].strip()
                hold.append(item)
        if name not in [f'{x} -> {x}' for x in ['video_clk','ext_mem_clk','sd_card_clk']]:continue
        data={'group':name}
        for field in ['Slack','Begin Point','End Point','Budget','Data Path Delay','Logic Level']:
            match=re.search(r'^\s*'+re.escape(field)+r'\s*:\s*([^\r\n]+)',part,re.M)
            assert match,(seed,name,field)
            data[field]=match[1].strip()
        paths.append(data)
    assert len(paths)==3
    all_paths.append({'seed':int(seed),'report':str(path),'worst_internal_paths':paths})
    all_hold.append({'seed':int(seed),'report':str(path),'note':'Report lists at most 10 endpoints per path group; these are reported negative min paths, not a replacement for global endpoint counts.','negative_min_paths':hold})
(OUT/'worst_internal_paths.json').write_text(json.dumps(all_paths,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
(OUT/'negative_min_paths.json').write_text(json.dumps(all_hold,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
for r in all_paths:
    worst=min(r['worst_internal_paths'],key=lambda p:float(p['Slack'].removesuffix('ns')))
    print(json.dumps({'seed':r['seed'],'worst_path':worst},ensure_ascii=False))
