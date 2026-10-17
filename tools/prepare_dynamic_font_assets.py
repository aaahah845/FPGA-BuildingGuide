"""Developer-only: snapshot fixed font literals and create a school configuration."""
import hashlib
import json
from pathlib import Path
import re
import struct

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / 'src/user_source/hdl_source'


def words(path, bank, count, bits):
    result = [None] * count
    for index, value in re.findall(rf'{bank}\[(\d+)\]\s*=\s*{bits}\'h([0-9a-fA-F]+)', path.read_text(encoding='utf-8')):
        result[int(index)] = int(value, 16)
    if any(value is None for value in result):
        raise ValueError(f'{path.name}: incomplete {bank}')
    return result


large = RTL / 'guide_large_font.v'
notes = RTL / 'room_notes_font.v'
payload = struct.pack('<4096I', *(words(large, 'even_words', 2048, 18)+words(large, 'odd_words', 2048, 18)))
payload += struct.pack('<1536H', *(words(notes, 'bank0', 512, 16)+words(notes, 'bank1', 512, 16)+words(notes, 'bank2', 512, 16)))
directory = ROOT / 'config/base_fonts'
directory.mkdir(exist_ok=True)
(directory / 'fixed_ui_base.bin').write_bytes(payload)
manifest = {
    'format': 'V6 payload: 4096 little-endian uint32 large words, 1536 uint16 notes words',
    'sha256': hashlib.sha256(payload).hexdigest(),
    'source_sha256': {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in (large, notes)},
    'large_chars': json.loads((ROOT/'config/glyph_catalog.json').read_text(encoding='utf-8'))['chars'],
    'notes_chars': json.loads((ROOT/'config/notes_glyph_catalog.json').read_text(encoding='utf-8'))['chars'],
    'preserve_large_ids': [0, 29, 30, 56, 57, 58, 59],
    'preserve_notes_ids': [0, *range(19, 29)],
}
(directory / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
config = json.loads((ROOT/'config/runtime_site.json').read_text(encoding='utf-8'))
config['title'] = '校园导览终端'
names = ['物理实验室', '化学实验室', '数学教研室', '计算机教室', '图书阅览室',
         '生物实验室', '音乐教室', '美术教室', '教师办公室', '学生服务室']
for index, floor in enumerate(config['floors'], 1):
    floor['name'] = f'{index}层教学楼'
    for room_index, room in enumerate(floor['rooms']):
        room['name'] = names[room_index]
        room['description'] = '用于日常教学与学生实践。'
        room['today_activity'] = room_index == 0
        room['activity'] = '实验课程，请按时到场。' if room_index == 0 else ''
example = ROOT / 'config/examples/runtime_school.json'
example.parent.mkdir(exist_ok=True)
example.write_text(json.dumps(config, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
print(f'Prepared {len(payload)} font bytes and {example}')
