"""只生成提示文字表及核验图；不生成或改写任何字库。"""
from pathlib import Path
import difflib, hashlib, json, re, struct, zlib
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT.parent/'lab_image_release_20261011'
NAV = ROOT.parent/'lab_image_nav_keys_20261011'
OUT = ROOT.parent/'竞赛学习/05_Codex后续学习与作品规划/跨AI交接_20261011_Codex回交_04/核验'
HDL = ROOT/'src/user_source/hdl_source'
REPORT = ROOT/'reports/nav_keys'
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
font_names = ['guide_font_rom.v','guide_large_font.v','room_notes_font.v',
              'site_font_id.vh','room_notes_font_id.vh','settings_font_init.vh']
assert all(sha(HDL/n)==sha(BASE/'src/user_source/hdl_source'/n) for n in font_names)
catalog = json.loads((ROOT/'config/glyph_catalog.json').read_text(encoding='utf-8'))['chars']
private = json.loads((ROOT/'config/private_ui_glyphs.json').read_text(encoding='utf-8'))
assert {k:v for k,v in private.items() if k.isdecimal()} == {'119':'地','120':'加','121':'载'}
assert len(catalog)==119 and zlib.crc32(catalog.encode())==0x43d9ad0d
chars = catalog + '地加载'
glyphs = {c:i for i,c in enumerate(chars)}
messages = {int(k):v for k,v in json.loads((ROOT/'config/lite_messages.json').read_text(encoding='utf-8')).items()}
assert sorted(messages)==list(range(16)) and max(map(len,messages.values()))<=18
assert all(c in glyphs for t in messages.values() for c in t)

lines = ['// 【说明】外接按键提示，仅使用发布版现有字形，每条最多 18 个 16 点字。',
         '// SW3 返回也可用外接 RST；SET 打开参数面板的功能保留，完整说明见 README。',
         'function [6:0] message_char;', 'input [3:0] message;', 'input [5:0] position;',
         'begin', 'message_char=0;', 'case(message)']
for n,t in sorted(messages.items()):
    lines += [f"4'd{n}: case(position) // {t}"]
    lines += [f"6'd{j}: message_char=7'd{glyphs[c]};" for j,c in enumerate(t)]
    lines += ['default: message_char=0;', 'endcase']
lines += ['default: message_char=0;', 'endcase', 'end', 'endfunction']
(HDL/'guide_messages.vh').write_text('\n'.join(lines)+'\n',encoding='utf-8')

# 沿用第三轮的完整文字表边界检查，更新这轮实际要求的提示内容。
test = ['`timescale 1ns/1ps','module tb_nav_messages;','`include "guide_messages.vh"','initial begin']
for n,t in sorted(messages.items()):
    for pos in range(64):
        g = glyphs[t[pos]] if pos<len(t) else 0
        test.append(f'if(message_char(4\'d{n},6\'d{pos})!==7\'d{g}) $fatal(1,"message {n} pos {pos}");')
test += ['$display("PASS: lite messages use existing glyphs; all 16 messages and 1024 positions including blank tails");', '$finish;', 'end', 'endmodule']
(ROOT/'sim/tb_nav_messages.v').write_text('\n'.join(test)+'\n',encoding='utf-8')

rows = {int(i):int(v,16) for i,v in re.findall(r"memory\[(\d+)\]=16'h([0-9a-fA-F]{4});",(HDL/'guide_font_rom.v').read_text(encoding='utf-8'))}
assert len(rows)==2048 and all(rows[i]==0 for i in range(122*16,127*16))
assert all(c==' ' or any(rows[glyphs[c]*16+y] for y in range(16)) for t in messages.values() for c in t)
im=Image.new('RGB',(336,32*16+16),(24,29,40)); d=ImageDraw.Draw(im)
for k,t in sorted(messages.items()):
    d.text((4,k*32+8),str(k),fill='white')
    d.rectangle((31,k*32+3,320,k*32+24),outline=(70,80,95))
    for j,c in enumerate(t):
        for y in range(16):
            v=rows[glyphs[c]*16+y]
            for x in range(16):
                if v & (1<<(15-x)): im.putpixel((32+j*16+x,k*32+6+y),(225,232,240))
im.resize((1008,im.height*3),Image.Resampling.NEAREST).save(REPORT/'message_preview.png')

cfg = bytes(int(x,16) for x in (ROOT/'sim/rooms10_cfg.hex').read_text().split())
assert len(cfg)==8192 and cfg[:4]==b'SGC1'
assert struct.unpack_from('<I',cfg,16)[0]==0x43d9ad0d
assert struct.unpack_from('<H',cfg,8190)[0]==sum(cfg[:8190])&65535
checks={'fonts_byte_identical_to_release':{n:sha(HDL/n) for n in font_names},
        'private_slots_122_through_126_blank':True,'public_font_crc32':'43d9ad0d',
        'runtime_cfg_fixture_crc_and_checksum':'PASS','max_message_characters':max(map(len,messages.values())),
        'changed_message_ids':[1,6,14], 'control_byte_identical_to_round03':True}
assert sha(HDL/'guide_scene_control.v')==sha(NAV/'src/user_source/hdl_source/guide_scene_control.v')
(REPORT/'font_checks.json').write_text(json.dumps(checks,ensure_ascii=False,indent=2),encoding='utf-8')
def snapshot(p): return {q.relative_to(p).as_posix():sha(q) for q in sorted(p.rglob('*')) if q.is_file()}
sources=snapshot(ROOT/'src/user_source')
(OUT/'source_before_build.json').write_text(json.dumps(sources,indent=2),encoding='utf-8')
changes={}
for base in (BASE,NAV):
    old=snapshot(base/'src/user_source')
    assert sources.keys()==old.keys()
    changed=[n for n in sources if sources[n]!=old[n]]
    changes[base.name]={'changed':changed,'unchanged_count':len(sources)-len(changed)}
    diff=''.join(''.join(difflib.unified_diff((base/'src/user_source'/n).read_text(encoding='utf-8').splitlines(True),
                 (ROOT/'src/user_source'/n).read_text(encoding='utf-8').splitlines(True),fromfile=base.name+'/'+n,tofile=ROOT.name+'/'+n)) for n in changed)
    (OUT/('diff_vs_'+base.name+'.patch')).write_text(diff,encoding='utf-8')
assert changes[NAV.name]['changed']==['hdl_source/guide_font_rom.v','hdl_source/guide_messages.vh']
assert changes[BASE.name]['changed']==['hdl_source/guide_messages.vh','hdl_source/guide_scene_control.v']
(OUT/'source_changes.json').write_text(json.dumps(changes,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({'checks':checks,'changes':changes},ensure_ascii=False))
