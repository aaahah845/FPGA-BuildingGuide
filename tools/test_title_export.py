"""Check optional title encoding without modifying the physical SD card."""
import copy
import hashlib
import importlib.util
import json
import struct
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load_exporter(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.export


class TitleExportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.exporter = staticmethod(load_exporter(ROOT / 'scripts/export_site_cfg.py', 'title_export'))
        cls.legacy_fixture = (ROOT / 'sim/fixtures/SITE_legacy_without_title.CFG').read_bytes()
        cls.legacy_metadata = json.loads((ROOT / 'sim/fixtures/SITE_legacy_without_title.json').read_text(encoding='utf-8'))
        cls.config = json.loads((ROOT / 'config/runtime_site.json').read_text(encoding='utf-8-sig'))
        cls.glyphs = json.loads((ROOT / 'config/glyph_catalog.json').read_text(encoding='utf-8'))['chars']
        cls.notes = json.loads((ROOT / 'config/notes_glyph_catalog.json').read_text(encoding='utf-8'))['chars']

    def render(self, config=None, glyphs=None):
        return self.exporter(self.config if config is None else config,
                             self.glyphs if glyphs is None else glyphs, self.notes)

    def test_default_title_and_checksum(self):
        data = self.render()
        self.assertEqual(len(data), 8192)
        self.assertEqual(data[:5], b'SGC1\x05')
        self.assertEqual(data[1288:1296], bytes(self.glyphs.index(c) for c in '企业会议导视') + b'\0\0')
        self.assertEqual(data[1296], 0x54)
        self.assertEqual(struct.unpack_from('<H', data, 8190)[0], sum(data[:8190]) & 65535)

    def test_missing_title_is_byte_exact_legacy(self):
        config = copy.deepcopy(self.config)
        config.pop('title')
        data = self.render(config)
        self.assertEqual(data[1288:1297], bytes(9))
        self.assertEqual(hashlib.sha256(self.legacy_fixture).hexdigest(), self.legacy_metadata['fixture_sha256'])
        self.assertEqual(data, self.legacy_fixture)

    def test_only_reserved_bytes_and_checksum_change(self):
        config = copy.deepcopy(self.config)
        config.pop('title')
        legacy = self.render(config)
        data = self.render()
        changed = {i for i, (a, b) in enumerate(zip(legacy, data)) if a != b}
        self.assertTrue(changed)
        self.assertTrue(changed <= set(range(1288, 1297)) | {8190, 8191})
        self.assertEqual(data[16:24], legacy[16:24])

    def test_valid_short_full_width_and_spaces(self):
        for title in ('楼', '楼层导视', '企业会议导视楼层', '楼 层'):
            with self.subTest(title=title):
                config = copy.deepcopy(self.config)
                config['title'] = title
                data = self.render(config)
                expected = bytes(self.glyphs.index(c) for c in title).ljust(8, b'\0')
                self.assertEqual(data[1288:1296], expected)
                self.assertEqual(data[1296], 0x54)

    def test_bad_title_values(self):
        for title in ('', ' ', '        ', '\t', '楼层导视楼层导视楼', None, 123, True, ['楼']):
            with self.subTest(title=title):
                config = copy.deepcopy(self.config)
                config['title'] = title
                with self.assertRaisesRegex(ValueError, 'title'):
                    self.render(config)

    def test_missing_glyph_is_rejected(self):
        config = copy.deepcopy(self.config)
        config['title'] = '测试𠮷'
        with self.assertRaisesRegex(ValueError, '字库暂无字符'):
            self.render(config)

    def test_catalog_width_and_padding_validation(self):
        for glyphs in ('', None, [' '], ' ' + ''.join(chr(0x4e00 + i) for i in range(128))):
            with self.subTest(glyphs=repr(glyphs)):
                with self.assertRaisesRegex(ValueError, '1..128'):
                    self.exporter(self.config, glyphs, self.notes)
        with self.assertRaisesRegex(ValueError, 'ID 0 must be a space'):
            self.render(glyphs='X' + self.glyphs[1:])

    def test_floor_example_is_current_and_exported(self):
        example = json.loads((ROOT / 'config/examples/runtime_site_title_floor.json').read_text(encoding='utf-8'))
        self.assertEqual(example['title'], '楼层导视')
        expected = copy.deepcopy(self.config)
        expected['title'] = '楼层导视'
        self.assertEqual(example, expected)
        self.assertEqual((ROOT / 'config/examples/SITE_floor_title.CFG').read_bytes(), self.render(example))
        self.assertEqual((ROOT / 'config/sd_card/SITE.CFG').read_bytes(), self.render())


if __name__ == '__main__':
    unittest.main(verbosity=2)
