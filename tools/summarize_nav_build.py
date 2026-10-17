"""按各时钟路径组核验，不能把全局负余量误当内部同域结果。"""
from pathlib import Path
import re, json, sys, math
ROOT=Path(__file__).resolve().parents[1]
runs=ROOT/'src/td_project/image_multiview_gui_Runs'
summary=[]
for name in sys.argv[1:] or ['phy_1']:
    d=runs/name
    timing=d/'final_timing.rpt'
    if not timing.exists():
        summary.append({'run':name,'status':'not_finished'});continue
    s=timing.read_text(errors='replace')
    groups={}
    for part in s.split('Path Group')[1:]:
        header=part[:part.find('Max Paths')] if 'Max Paths' in part else part[:2000]
        group=re.match(r'\s*:\s*([^\r\n]+)',header).group(1).strip()
        a=re.search(r'Max\s*:\s*SWNS\s*([\-\d.]+)ns.*?(\d+) Viol Endpoints',header)
        b=re.search(r'Min\s*:\s*HWNS\s*([\-\d.]+)ns.*?(\d+) Viol Endpoints',header)
        if a and b: groups[group]={'setup_ns':float(a[1]),'setup_endpoints':int(a[2]),'hold_ns':float(b[1]),'hold_endpoints':int(b[2])}
    qor=(d/'route.qor').read_text(errors='replace')
    n_hold=int(re.search(r'Num of violated H-EP\s*\|\s*(\d+)',qor)[1])
    slices=int(re.search(r'#slices\s*\|\s*(\d+)',qor)[1])
    area=(d/'image_multiview_gui_phy.area').read_text(errors='replace')
    def resource(n):
        match=re.search(r'^#'+n+r'\s+(\d+)\b',area,re.M)
        return int(match[1]) if match else None
    internal={clock:groups[f'{clock} -> {clock}']['setup_ns'] for clock in ['video_clk','ext_mem_clk','sd_card_clk']}
    log=(ROOT/'reports/nav_keys'/name/'td_console.log').read_text(errors='replace')
    physical=re.findall(r': (\d+) mslices, (\d+) lslices',log)
    assert physical and sum(map(int,physical[-1]))==slices
    result={'run':name,'seed':int(re.search(r'<seed>(\d+)</seed>',(d/'image_multiview_gui.prj').read_text())[1]),
            'internal_setup_ns':internal,'global_hold_ns':float(re.search(r'HWNS:\s*([\-\d.]+)ns',s)[1]),
            'hold_endpoints':n_hold,'slices':slices,'mslices':int(physical[-1][0]),'lslices':int(physical[-1][1]),
            'lut':resource('lut'),'reg':resource('reg'),'bram':resource('bram'),'dsp':resource('dsp'),
            'path_groups':groups,'bit_exists':(d/'image_multiview_gui.bit').exists()}
    result['accept']=all(v>=0 for v in internal.values()) and result['mslices']<=4900 and n_hold<=3 and result['bit_exists']
    summary.append(result)
target=ROOT/'reports/nav_keys/timing_summary.json'
target.write_text(json.dumps(summary,indent=2),encoding='utf-8')
for x in summary:print(json.dumps({k:v for k,v in x.items() if k!='path_groups'},ensure_ascii=False))
