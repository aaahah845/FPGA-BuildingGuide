"""只改变布局随机种子；各运行独立输出，复用已验证综合数据库。"""
from pathlib import Path
import re, shutil, sys
ROOT=Path(__file__).resolve().parents[1]
runs=ROOT/'src/td_project/image_multiview_gui_Runs'
for seed in map(int,sys.argv[1:]):
    target=runs/f'phy_seed{seed}'
    assert not target.exists(), target
    target.mkdir()
    for p in (runs/'phy_1').iterdir():
        if p.is_file() and p.name in ['image_multiview_gui.prj','settings.cfg','image_multiview_gui.tcl','run.bat']:
            s=p.read_text(encoding='utf-8')
            if p.suffix=='.prj':
                s,n=re.subn(r'<seed>\d+</seed>',f'<seed>{seed}</seed>',s)
                assert n==1
            (target/p.name).write_text(s,encoding='utf-8')
    print(f'prepared {target.name}')
