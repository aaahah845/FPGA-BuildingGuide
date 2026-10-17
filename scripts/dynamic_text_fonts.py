"""Build the V6 boot-loadable glyph payload without changing fixed UI glyphs."""
from functools import lru_cache
import hashlib
import json
from pathlib import Path
import struct
import unicodedata

ROOT = Path(__file__).resolve().parents[1]
LARGE_RESERVED = (0, 29, 30, 56, 57, 58, 59)
NOTES_RESERVED = (0, *range(19, 29))
DEFAULT_LARGE_FONT = Path('C:/Windows/Fonts/msyhbd.ttc')
DEFAULT_NOTES_FONT = Path('C:/Windows/Fonts/msyh.ttc')
PAYLOAD_SIZE = 19456


def allocate_glyphs(texts, original_chars, reserved, capacity, label):
    """Allocate deterministic IDs, retaining the fixed-UI ABI and blank ID zero."""
    result = {original_chars[index]: index for index in reserved}
    slots = iter(index for index in range(capacity) if index not in reserved)
    for text in texts:
        if not isinstance(text, str):
            raise ValueError(f'{label} 必须是字符串')
        for char in text:
            if char == '\n' and label == '说明/活动':
                continue
            if unicodedata.category(char).startswith('C') or unicodedata.combining(char):
                raise ValueError(f'{label} 不支持控制字符或组合字符 {char!r} (U+{ord(char):04X})')
            if char not in result:
                index = next(slots, None)
                if index is None:
                    raise ValueError(f'{label} 不同字符过多：除保留字符外最多 {capacity-len(reserved)} 个；重复字不重复占用')
                result[char] = index
    return result


def make_maps(config, original_chars, original_notes_chars):
    names = [config['title']] if 'title' in config else []
    notes = []
    for floor in config['floors']:
        names.append(floor['name'])
        for room in floor['rooms']:
            names.append(room['name'])
            notes.extend((room.get('description', ''), room.get('activity', '')))
    return (
        allocate_glyphs(names, original_chars, LARGE_RESERVED, 128, '标题/楼层/房间名称'),
        allocate_glyphs(notes, original_notes_chars, NOTES_RESERVED, 96, '说明/活动'),
    )


@lru_cache(maxsize=8)
def font_coverage(font_path):
    """Read a real Unicode cmap; never infer support from a rendered tofu box."""
    try:
        from fontTools.ttLib import TTFont
    except ImportError as error:
        raise ValueError('缺少 fonttools，请先运行 python -m pip install -r scripts/requirements_dynamic_text.txt') from error
    if not Path(font_path).is_file():
        raise ValueError(f'字体文件不存在：{font_path}')
    try:
        with TTFont(font_path, fontNumber=0) as font:
            return frozenset(codepoint for table in font['cmap'].tables if table.isUnicode()
                             for codepoint, glyph in table.cmap.items() if glyph != '.notdef')
    except Exception as error:
        raise ValueError(f'无法读取字体 Unicode 字符表：{font_path}: {error}') from error


@lru_cache(maxsize=8)
def load_font(font_path, size):
    try:
        from PIL import ImageFont
    except ImportError as error:
        raise ValueError('缺少 Pillow，请先运行 python -m pip install -r scripts/requirements_dynamic_text.txt') from error
    return ImageFont.truetype(font_path, size, index=0)


@lru_cache(maxsize=2048)
def render_rows(char, size, font_path):
    if ord(char) not in font_coverage(font_path):
        raise ValueError(f'字体 {Path(font_path).name} 不含字符 {char!r} (U+{ord(char):04X})；请换字体或改字')
    from PIL import Image, ImageDraw
    image = Image.new('L', (size, size))
    draw = ImageDraw.Draw(image)
    font = load_font(font_path, size)
    x0, y0, x1, y1 = draw.textbbox((0, 0), char, font=font)
    draw.text(((size - (x1-x0)) // 2 - x0, (size - (y1-y0)) // 2 - y0),
              char, fill=255, font=font)
    return tuple(sum(1 << (size-1-x) for x in range(size) if image.getpixel((x, y)) >= 110)
                 for y in range(size))


def pack_large_rows(rows):
    if len(rows) != 24 or any(not 0 <= row < (1 << 24) for row in rows):
        raise ValueError('large glyph requires 24 rows of 24 bits')
    bits = sum(row << (24 * index) for index, row in enumerate(rows))
    return [(bits >> (18 * index)) & 0x3FFFF for index in range(32)]


def unpack_large_rows(even, odd, glyph):
    words = [bank[glyph*16 + index//2] for index in range(32)
             for bank in [odd if index & 1 else even]]
    bits = sum(word << (18*index) for index, word in enumerate(words))
    return tuple((bits >> (24*row)) & 0xFFFFFF for row in range(24))


def load_baseline():
    directory = ROOT / 'config/base_fonts'
    manifest = json.loads((directory / 'manifest.json').read_text(encoding='utf-8'))
    data = (directory / 'fixed_ui_base.bin').read_bytes()
    if len(data) != PAYLOAD_SIZE or hashlib.sha256(data).hexdigest() != manifest['sha256']:
        raise ValueError('固定 UI 字模基准文件校验失败，请恢复 config/base_fonts')
    return data, manifest


def build_payload(large_map, notes_map, original_chars, original_notes_chars,
                  large_font=DEFAULT_LARGE_FONT, notes_font=DEFAULT_NOTES_FONT):
    baseline, manifest = load_baseline()
    if original_chars != manifest['large_chars'] or original_notes_chars != manifest['notes_chars']:
        raise ValueError('请勿修改 glyph_catalog.json / notes_glyph_catalog.json：它们定义固定界面 ABI，不是可输入字符白名单')
    baseline_large = struct.unpack_from('<4096I', baseline)
    baseline_notes = struct.unpack_from('<1536H', baseline, 16384)
    even, odd, notes = [0]*2048, [0]*2048, [0]*1536
    for index in LARGE_RESERVED:
        even[index*16:index*16+16] = baseline_large[index*16:index*16+16]
        odd[index*16:index*16+16] = baseline_large[2048+index*16:2048+index*16+16]
    for index in NOTES_RESERVED:
        notes[index*16:index*16+16] = baseline_notes[index*16:index*16+16]
    for char, index in large_map.items():
        if index not in LARGE_RESERVED:
            words = pack_large_rows(render_rows(char, 24, str(large_font)))
            even[index*16:index*16+16] = words[0::2]
            odd[index*16:index*16+16] = words[1::2]
    for char, index in notes_map.items():
        if index not in NOTES_RESERVED:
            notes[index*16:index*16+16] = render_rows(char, 16, str(notes_font))
    return struct.pack('<4096I', *(even+odd)) + struct.pack('<1536H', *notes)
