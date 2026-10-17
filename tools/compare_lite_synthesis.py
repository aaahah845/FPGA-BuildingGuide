"""使用同一综合阶段的 area 报告比较，不与布局后资源数字混用。"""
from pathlib import Path
import hashlib, json, re
ROOT=Path(__file__).resolve().parents[1]
names=['lab_image_release_20261011','lab_image_nav_keys_20261011',ROOT.name]
table=[]
for name in names:
    path=ROOT.parent/name/'src/td_project/image_multiview_gui_Runs/syn_1/image_multiview_gui_gate.area'
    text=path.read_text(errors='replace')
    def count(k):return int(re.search(r'^#'+k+r'\s+(\d+)\b',text,re.M)[1])
    hierarchy=[]
    for line in text.splitlines():
        if not line.startswith('|') or 'Instance' in line:continue
        cells=[x.strip() for x in line.strip('|').split('|')]
        if len(cells)==7 and cells[2].isdigit():
            hierarchy.append(dict(zip(['instance','module','lut','ripple','seq','bram','dsp'],cells)))
    table.append({'project':name,'lut':count('lut'),'reg':count('reg'),'bram':count('bram'),
                  'dsp':count('dsp'),'report':str(path),'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
                  'hierarchy':hierarchy})
out=ROOT/'reports/nav_keys/synthesis_comparison.json'
out.write_text(json.dumps(table,ensure_ascii=False,indent=2),encoding='utf-8')
for row in table: print(json.dumps({k:v for k,v in row.items() if k!='hierarchy'},ensure_ascii=False))
