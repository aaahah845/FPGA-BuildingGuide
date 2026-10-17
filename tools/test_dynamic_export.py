"""Behavior and binary-contract tests for the SITE.CFG V6 exporter."""
import copy
from datetime import datetime, timezone
import hashlib
from importlib.metadata import version
import json
from pathlib import Path
import random
import struct
import sys
import tempfile
import time
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'scripts'))
import export_site_cfg as exporter
from dynamic_text_fonts import (
    LARGE_RESERVED, NOTES_RESERVED, DEFAULT_LARGE_FONT, DEFAULT_NOTES_FONT,
    allocate_glyphs, build_payload, font_coverage, load_baseline, make_maps,
    pack_large_rows, render_rows, unpack_large_rows,
)


class DynamicExportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = json.loads((ROOT/'config/runtime_site.json').read_text(encoding='utf-8'))
        cls.school = json.loads((ROOT/'config/examples/runtime_school.json').read_text(encoding='utf-8'))
        cls.large_chars = json.loads((ROOT/'config/glyph_catalog.json').read_text(encoding='utf-8'))['chars']
        cls.notes_chars = json.loads((ROOT/'config/notes_glyph_catalog.json').read_text(encoding='utf-8'))['chars']
        cls.default_data = exporter.export(cls.config)
        cls.school_data = exporter.export(cls.school)

    def test_version_size_and_two_checksums(self):
        data = self.default_data
        self.assertEqual(len(data), 27648)
        self.assertEqual(data[:5], b'SGC1\x06')
        self.assertEqual(data[26], 1)
        self.assertEqual(struct.unpack_from('<H', data, 8190)[0], sum(data[:8190]) & 65535)
        self.assertEqual(struct.unpack_from('<H', data, 24)[0], sum(data[8192:]) & 65535)
        self.assertEqual(struct.unpack_from('<I', data, 16)[0], zlib.crc32(self.large_chars.encode()))
        self.assertEqual(struct.unpack_from('<I', data, 20)[0], zlib.crc32(self.notes_chars.encode()))

    def test_school_uses_new_characters_without_rebuilding_rtl(self):
        large_map, notes_map = make_maps(self.school, self.large_chars, self.notes_chars)
        self.assertNotIn('校', self.large_chars)
        self.assertNotIn('实', self.notes_chars)
        self.assertEqual(self.school_data[1288], large_map['校'])
        self.assertEqual(self.school_data[1024], large_map['物'])
        text = self.school['floors'][0]['rooms'][0]['description']
        self.assertEqual(list(self.school_data[2048:2048+len(text)]), [notes_map[c] for c in text])
        self.assertEqual(self.school_data[1296], 0x54)

    def test_large_pixel_rows_match_payload_and_read_algorithm(self):
        mapping, _ = make_maps(self.school, self.large_chars, self.notes_chars)
        words = struct.unpack_from('<4096I', self.school_data, 8192)
        for char in '校园物理化学':
            glyph = mapping[char]
            rows = render_rows(char, 24, str(DEFAULT_LARGE_FONT))
            self.assertEqual(unpack_large_rows(words[:2048], words[2048:], glyph), rows)
            for row in range(24):
                word_number = row+row//3
                even = words[glyph*16+word_number//2+(word_number & 1)]
                odd = words[2048+glyph*16+word_number//2]
                pair = (even << 18 | odd) if word_number & 1 else (odd << 18 | even)
                self.assertEqual((pair >> (6*(row % 3))) & 0xFFFFFF, rows[row])
        self.assertTrue(all(word < 1 << 18 for word in words))

    def test_notes_bank_packing_and_pixels(self):
        _, mapping = make_maps(self.school, self.large_chars, self.notes_chars)
        words = struct.unpack_from('<1536H', self.school_data, 24576)
        for char, glyph in mapping.items():
            if glyph not in NOTES_RESERVED:
                self.assertEqual(tuple(words[glyph*16:glyph*16+16]),
                                 render_rows(char, 16, str(DEFAULT_NOTES_FONT)))

    def test_fixed_ui_words_are_bit_exact(self):
        baseline, _ = load_baseline()
        before = struct.unpack_from('<4096I', baseline)
        after = struct.unpack_from('<4096I', self.school_data, 8192)
        for glyph in LARGE_RESERVED:
            for offset in (0, 2048):
                start = offset+glyph*16
                self.assertEqual(after[start:start+16], before[start:start+16])
        before = struct.unpack_from('<1536H', baseline, 16384)
        after = struct.unpack_from('<1536H', self.school_data, 24576)
        for glyph in NOTES_RESERVED:
            self.assertEqual(after[glyph*16:glyph*16+16], before[glyph*16:glyph*16+16])

    def test_unused_glyph_slots_are_blank(self):
        large_map, notes_map = make_maps(self.school, self.large_chars, self.notes_chars)
        words = struct.unpack_from('<4096I', self.school_data, 8192)
        for glyph in set(range(128))-set(large_map.values()):
            self.assertEqual(words[glyph*16:glyph*16+16], (0,)*16)
            self.assertEqual(words[2048+glyph*16:2048+glyph*16+16], (0,)*16)
        words = struct.unpack_from('<1536H', self.school_data, 24576)
        for glyph in set(range(96))-set(notes_map.values()):
            self.assertEqual(words[glyph*16:glyph*16+16], (0,)*16)

    def test_name_length_limits_and_padding(self):
        config = copy.deepcopy(self.school)
        config['title'] = '校园综合信息导览'
        self.assertEqual(len(config['title']), 8)
        exporter.export(config)
        config['title'] += '屏'
        with self.assertRaisesRegex(ValueError, '1..8'):
            exporter.export(config)
        config['title'] = '学校'
        data = exporter.export(config)
        self.assertEqual(data[1290:1296], bytes(6))
        config['title'] = '        '
        with self.assertRaisesRegex(ValueError, '不能全部为空白'):
            exporter.export(config)

    def test_room_name_length_limit(self):
        config = copy.deepcopy(self.school)
        config['floors'][0]['rooms'][0]['name'] = '物理化学生物实验室'
        with self.assertRaisesRegex(ValueError, '1..8'):
            exporter.export(config)

    def test_optional_title_uses_fixed_default(self):
        config = copy.deepcopy(self.school)
        del config['title']
        self.assertEqual(exporter.export(config)[1288:1297], bytes(9))

    def test_notes_wrapping_and_explicit_line_limit(self):
        config = copy.deepcopy(self.school)
        room = config['floors'][0]['rooms'][0]
        room['description'] = '学'*48
        exporter.export(config)
        room['description'] += '学'
        with self.assertRaisesRegex(ValueError, '超出四行'):
            exporter.export(config)
        room['description'] = '学\n校\n实\n验'
        exporter.export(config)
        room['description'] += '\n室'
        with self.assertRaisesRegex(ValueError, '超出四行'):
            exporter.export(config)

    def test_large_unique_character_capacity(self):
        chars = ''.join(chr(code) for code in range(0x4E00, 0x5000)
                        if chr(code) not in {self.large_chars[i] for i in LARGE_RESERVED})
        mapping = allocate_glyphs([chars[:121]], self.large_chars, LARGE_RESERVED, 128, '名称')
        self.assertEqual(len(mapping), 128)
        self.assertEqual(len(allocate_glyphs([chars[:121]*2], self.large_chars, LARGE_RESERVED, 128, '名称')), 128)
        with self.assertRaisesRegex(ValueError, '最多 121'):
            allocate_glyphs([chars[:122]], self.large_chars, LARGE_RESERVED, 128, '名称')

    def test_notes_unique_character_capacity(self):
        chars = ''.join(chr(code) for code in range(0x4E00, 0x5000)
                        if chr(code) not in {self.notes_chars[i] for i in NOTES_RESERVED})
        self.assertEqual(len(allocate_glyphs([chars[:85]], self.notes_chars, NOTES_RESERVED, 96, '说明/活动')), 96)
        with self.assertRaisesRegex(ValueError, '最多 85'):
            allocate_glyphs([chars[:86]], self.notes_chars, NOTES_RESERVED, 96, '说明/活动')

    def test_missing_font_character_reports_unicode_codepoint(self):
        coverage = font_coverage(str(DEFAULT_LARGE_FONT))
        char = next(chr(code) for code in range(0x20000, 0x2A6E0) if code not in coverage)
        config = copy.deepcopy(self.school)
        config['title'] = char
        with self.assertRaisesRegex(ValueError, f'U\\+{ord(char):04X}'):
            exporter.export(config)

    def test_control_and_combining_characters_rejected(self):
        for text in ('学\t校', 'e\u0301'):
            config = copy.deepcopy(self.school)
            config['title'] = text
            with self.assertRaisesRegex(ValueError, '控制字符或组合字符'):
                exporter.export(config)

    def test_missing_font_file_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, '字体文件不存在'):
                exporter.export(self.school, large_font=Path(directory)/'missing.ttf')

    def test_glyph_catalog_is_fixed_abi_not_user_whitelist(self):
        with self.assertRaisesRegex(ValueError, '固定界面 ABI'):
            exporter.export(self.school, glyphs=self.large_chars+'校')

    def test_round_trip_large_bit_packing(self):
        rng = random.Random(61)
        for _ in range(32):
            rows = tuple(rng.randrange(1 << 24) for _ in range(24))
            words = pack_large_rows(rows)
            self.assertEqual(unpack_large_rows(words[0::2], words[1::2], 0), rows)

    def test_repeated_exports_deterministic(self):
        self.assertEqual(self.default_data, exporter.export(copy.deepcopy(self.config)))

    def test_all_generated_config_examples_are_v6(self):
        paths = sorted((ROOT/'config').rglob('*.CFG'))
        self.assertGreaterEqual(len(paths), 3)
        for path in paths:
            with self.subTest(config=str(path.relative_to(ROOT))):
                data = path.read_bytes()
                self.assertEqual(len(data), 27648)
                self.assertEqual(data[:5], b'SGC1\x06')
                self.assertEqual(data[26], 1)
                self.assertEqual(struct.unpack_from('<H', data, 8190)[0], sum(data[:8190]) & 65535)
                self.assertEqual(struct.unpack_from('<H', data, 24)[0], sum(data[8192:]) & 65535)


if __name__ == '__main__':
    started = time.perf_counter()
    program = unittest.main(verbosity=2, exit=False)
    result = program.result
    def sha(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()
    tool_paths = [Path(__file__).resolve(), ROOT/'scripts/export_site_cfg.py',
                  ROOT/'scripts/dynamic_text_fonts.py', ROOT/'scripts/requirements_dynamic_text.txt']
    config_paths = sorted(path for path in (ROOT/'config').rglob('*')
                          if path.is_file() and path.suffix.lower() in ('.cfg', '.json', '.bin'))
    report = {
        'pass': result.wasSuccessful() and result.testsRun > 0,
        'tests': result.testsRun,
        'seconds': round(time.perf_counter()-started, 6),
        'finished_utc': datetime.now(timezone.utc).isoformat(),
        'failures': [{'test': str(test), 'traceback': trace} for test, trace in result.failures],
        'errors': [{'test': str(test), 'traceback': trace} for test, trace in result.errors],
        'skipped': [{'test': str(test), 'reason': reason} for test, reason in result.skipped],
        'tools': {'python': sys.version, 'Pillow': version('Pillow'), 'fonttools': version('fonttools')},
        'tool_sha256': {str(path.relative_to(ROOT)).replace('\\', '/'): sha(path) for path in tool_paths},
        'config_sha256': {str(path.relative_to(ROOT)).replace('\\', '/'): sha(path) for path in config_paths},
        'font_sha256': {str(path): sha(path) for path in (DEFAULT_LARGE_FONT, DEFAULT_NOTES_FONT)},
    }
    destination = ROOT/'reports/dynamic_text/export_tests.json'
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print(f'Wrote test evidence: {destination}')
    raise SystemExit(0 if report['pass'] else 1)
