"""Export SITE.CFG V6 with all configured text and its boot-loadable glyphs."""
import argparse,json,struct,re,zlib
from pathlib import Path
from dynamic_text_fonts import (make_maps, build_payload, DEFAULT_LARGE_FONT,
                                DEFAULT_NOTES_FONT, LARGE_RESERVED, NOTES_RESERVED)
ROOT=Path(__file__).resolve().parents[1]
def export(config, glyphs=None, notes_glyphs=None, *,
           large_font=DEFAULT_LARGE_FONT, notes_font=DEFAULT_NOTES_FONT):
    if glyphs is None:
        glyphs=json.loads((ROOT/'config/glyph_catalog.json').read_text(encoding='utf-8'))['chars']
    # The renderer stores each name glyph in seven bits; ID zero is padding.
    if not isinstance(glyphs,str) or not 1<=len(glyphs)<=128:
        raise ValueError('glyph_catalog.json chars must contain 1..128 characters (7-bit glyph IDs)')
    if glyphs[0]!=' ':
        raise ValueError('glyph_catalog.json glyph ID 0 must be a space for title/name padding')
    if notes_glyphs is None:
        notes_glyphs=json.loads((ROOT/'config/notes_glyph_catalog.json').read_text(encoding='utf-8'))['chars']
    large_map,notes_map=make_maps(config,glyphs,notes_glyphs)
    wide_ids=True
    point_mode=wide_ids or any('point_photo_image' in room for floor in config['floors'] for room in floor['rooms'])
    out=bytearray(27648);out[:4]=b'SGC1';out[4]=6
    out[26]=1
    if point_mode:
        for i in range(30):out[321+16*i]=0x80
    struct.pack_into('<I',out,16,zlib.crc32(glyphs.encode('utf-8')))
    struct.pack_into('<I',out,20,zlib.crc32(notes_glyphs.encode('utf-8')))
    def integer(x,low,high):
        if type(x) is not int or not low<=x<=high:raise ValueError(f'value {x!r} outside {low}..{high}')
        return x
    def short_name(name):
        if not isinstance(name,str) or not re.fullmatch(r'[A-Za-z0-9_]{1,8}\.BMP',name,re.I):raise ValueError(f'8.3 BMP filename required: {name}')
        a,b=name.upper().split('.');return (a.ljust(8)+b).encode('ascii')
    resources=config['images'];integer(len(resources),1,128)
    filenames=[short_name(s) for s in resources]
    if len(set(filenames))!=len(filenames):raise ValueError('duplicate image filenames')
    floors=config['floors'];integer(len(floors),1,3)
    playlist=config['slideshow'];integer(len(playlist),1,16)
    resource=lambda n:integer(n,0,len(resources)-1)
    def name(addr,text):
        if not isinstance(text,str) or not 1<=len(text)<=8:raise ValueError('name must have 1..8 characters')
        for j,c in enumerate(text):
            out[addr+j]=large_map[c]
    # Keep the V5 name layout and optional-title fallback; V6 carries fonts too.
    if 'title' in config:
        title=config['title']
        if not isinstance(title,str) or not 1<=len(title)<=8 or not title.strip():
            raise ValueError('title 必须为 1..8 个字符的字符串，且不能全部为空白')
        name(1288,title)
        out[1296]=0x54
    out[8:12]=bytes([len(floors),len(resources),len(playlist),integer(config.get('period_select',0),0,3)])
    for j,key in enumerate(['show_points','selected_only','default_zoom']):
        v=config.get(key,key=='show_points')
        if type(v) is not bool:raise ValueError(f'{key} must be boolean')
        out[12+j]=int(v)
    # V5 keeps all 128 filename records in a separate 1536-byte region.
    for i,f in enumerate(filenames):
        a=6144+12*i
        out[a:a+11]=f
    for f,floor in enumerate(floors):
        rooms=floor['rooms'];integer(len(rooms),1,10)
        out[256+16*f]=len(rooms);out[257+16*f]=resource(floor['map_image'])
        name(1264+8*f,floor['name'])
        for k,room in enumerate(rooms):
            i=f*10+k;a=320+16*i
            out[a]=resource(room['photo_image'])
            if point_mode:
                if room.get('point_photo_image') is None:
                    raise ValueError(f'{floor["name"]}/{room["name"]}: 请填写独立的 point_photo_image 图片编号')
                point=resource(room['point_photo_image'])
                if point==out[a]:raise ValueError(f'{room["name"]}: 观察点照片不能与对应房间照片共用图片')
                if point in {resource(f['map_image']) for f in floors}:raise ValueError(f'{room["name"]}: 观察点需要场景照片，不能使用本层平面地图')
                out[a+1]=0x80|point
            x,y=room['point'];struct.pack_into('<HH',out,a+2,integer(x,0,1023),integer(y,0,599))
            name(1024+8*i,room['name'])
            active=room.get('today_activity',False)
            if type(active) is not bool:raise ValueError('today_activity must be boolean')
            out[a+6]=int(active)
            if active and not room.get('activity','').strip():raise ValueError('今日有活动时必须填写 activity')
            for block,key in enumerate(('description','activity')):
                text=room.get(key,'')
                if not isinstance(text,str):raise ValueError(f'{key} must be text')
                lines=[]
                for paragraph in text.split('\n'):
                    lines.extend([paragraph[j:j+12] for j in range(0,len(paragraph),12)] or [''])
                if len(lines)>4:raise ValueError(f'{room["name"]} {key} 超出四行，每行最多12字')
                for row,line in enumerate(lines):
                    for col,ch in enumerate(line):
                        out[2048+i*128+block*64+row*16+col]=notes_map[ch]
    for i,image in enumerate(playlist):out[832+i]=resource(image)
    payload=build_payload(large_map,notes_map,glyphs,notes_glyphs,large_font,notes_font)
    out[8192:]=payload
    struct.pack_into('<H',out,24,sum(payload)&65535)
    struct.pack_into('<H',out,8190,sum(out[:8190])&65535)
    return bytes(out)
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('config',nargs='?',type=Path,default=ROOT/'config/runtime_site.json')
    p.add_argument('-o','--output',type=Path,default=ROOT/'config/sd_card/SITE.CFG')
    p.add_argument('--large-font',type=Path,default=DEFAULT_LARGE_FONT,help='标题/名称 24 像素字体 TTF/OTF/TTC（TTC 使用第 0 张字体）')
    p.add_argument('--notes-font',type=Path,default=DEFAULT_NOTES_FONT,help='说明/活动 16 像素字体 TTF/OTF/TTC')
    args=p.parse_args();cfg=json.loads(args.config.read_text(encoding='utf-8-sig'))
    glyphs=json.loads((ROOT/'config/glyph_catalog.json').read_text(encoding='utf8'))['chars']
    notes_glyphs=json.loads((ROOT/'config/notes_glyph_catalog.json').read_text(encoding='utf8'))['chars']
    try:
        data=export(cfg,glyphs,notes_glyphs,large_font=args.large_font,notes_font=args.notes_font)
    except (ValueError,KeyError,TypeError) as error:
        p.error(str(error))
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_bytes(data)
    large_map,notes_map=make_maps(cfg,glyphs,notes_glyphs)
    print(f'Exported {args.output}: {len(data)} bytes; SITE.CFG V6 with embedded glyphs.')
    print(f'Dynamic glyphs: names {len(large_map)-len(LARGE_RESERVED)}/121; notes {len(notes_map)-len(NOTES_RESERVED)}/85.')
    print('First install the matching dynamic-text bitstream. Then copy SITE.CFG and listed BMP files to SD root, and restart. Legacy V5 files/bitstreams are incompatible.')
