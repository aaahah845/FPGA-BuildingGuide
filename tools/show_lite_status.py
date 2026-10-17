"""只读查看已结束种子；不覆盖正式汇总。"""
from pathlib import Path
import json,re
ROOT=Path(__file__).resolve().parents[1]
SEEDS=[23,11,7,1,42,31,19,53,3,17,29,61]
for seed in SEEDS:
    name='phy_1' if seed==23 else f'phy_seed{seed}'
    out=ROOT/'reports/nav_keys'/name;d=ROOT/'src/td_project/image_multiview_gui_Runs'/name
    if not (out/'build_result.json').is_file():continue
    build=json.loads((out/'build_result.json').read_text())
    if not build['pass']:
        print(json.dumps({'seed':seed,'build':build}));continue
    text=(d/'final_timing.rpt').read_text(errors='replace')
    groups={}
    for group in text.split('Path Group')[1:]:
        header=group.split('Max Paths')[0]
        n=re.match(r'\s*:\s*([^\r\n]+)',header)[1].strip()
        match=re.search(r'Max\s*:\s*SWNS\s*([\-\d.]+)ns',header)
        if match:groups[n]=float(match[1])
    internal={c:groups[f'{c} -> {c}'] for c in ['video_clk','ext_mem_clk','sd_card_clk']}
    qor=(d/'route.qor').read_text();hold=int(re.search(r'Num of violated H-EP\s*\|\s*(\d+)',qor)[1])
    matches=re.findall(r': (\d+) mslices, (\d+) lslices',(out/'td_console.log').read_text(errors='replace'))
    ms=int(matches[-1][0])
    print(json.dumps({'seed':seed,'internal_ns':internal,'mslices':ms,'hold_endpoints':hold,
                      'accept':min(internal.values())>=0 and ms<=4900 and hold<=3}))
