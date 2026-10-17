"""Check content preservation, draft recovery, and real dynamic-font exporting."""
from copy import deepcopy
from datetime import datetime, timezone
import json
from pathlib import Path
import struct
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'scripts'))
import site_editor_model as model
import export_site_cfg
from dynamic_text_fonts import DEFAULT_LARGE_FONT, font_coverage


class ContentEditorModelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base = json.loads((ROOT/'config/runtime_site.json').read_text(encoding='utf-8'))
        cls.school = json.loads((ROOT/'config/examples/runtime_school.json').read_text(encoding='utf-8'))

    def config(self):
        return deepcopy(self.base)

    @staticmethod
    def update_room(document, fi, ri, **changes):
        room = document.data['floors'][fi]['rooms'][ri]
        values = {key: room.get(key, False if key == 'today_activity' else '')
                  for key in ('name', 'description', 'activity', 'today_activity')}
        values.update(changes)
        document.update_room(fi, ri, **values)

    def test_deep_copy_dirty_and_revert(self):
        original = self.config()
        document = model.ContentDocument(original)
        self.assertFalse(document.dirty)
        document.update_title('校园导览')
        self.assertTrue(document.dirty)
        self.assertEqual(original, self.base)
        document.update_title(original['title'])
        self.assertFalse(document.dirty)
        original['floors'][0]['rooms'][0]['point'][0] = 900
        self.assertNotEqual(document.data['floors'][0]['rooms'][0]['point'][0], 900)

    def test_noop_preserves_missing_defaults_and_unknown_fields(self):
        original = self.config()
        del original['title']
        room = original['floors'][0]['rooms'][0]
        for key in ('description', 'activity', 'today_activity'):
            room.pop(key, None)
        original['custom_future_settings'] = {'enabled': True, 'opaque': [7, '中文']}
        room['custom_room_data'] = {'foo': 'bar'}
        document = model.ContentDocument(original)
        document.update_title(model.DEFAULT_TITLE)
        document.update_floor(0, original['floors'][0]['name'])
        self.update_room(document, 0, 0)
        self.assertEqual(document.data, original)
        self.assertFalse(document.dirty)
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)/'草稿.json'
            document.save(target)
            self.assertEqual(model.ContentDocument.load(target).data, original)

    def test_edit_multiple_rooms_preserves_resource_mapping_and_activity(self):
        document = model.ContentDocument(self.base)
        self.update_room(document, 0, 1, name='数学教室', description='数学课程。')
        self.update_room(document, 2, 0, name='物理教室', description='物理课程。')
        activity = document.data['floors'][0]['rooms'][1]['activity']
        self.update_room(document, 0, 1, today_activity=False)
        self.assertEqual(document.data['floors'][0]['rooms'][1]['activity'], activity)
        for fi, floor in enumerate(self.base['floors']):
            self.assertEqual(document.data['floors'][fi]['map_image'], floor['map_image'])
            for ri, room in enumerate(floor['rooms']):
                for key in ('point', 'photo_image', 'point_photo_image', 'placeholder'):
                    self.assertEqual(document.data['floors'][fi]['rooms'][ri].get(key), room.get(key))
        for key in ('images', 'slideshow', 'period_select', 'show_points', 'selected_only', 'default_zoom', '_notes'):
            self.assertEqual(document.data[key], self.base[key])
        self.assertEqual(document.data['floors'][0]['rooms'][1]['description'], '数学课程。')
        self.assertEqual(document.data['floors'][2]['rooms'][0]['description'], '物理课程。')

    def test_save_atomic_backup_and_updated_snapshot(self):
        document = model.ContentDocument(self.base)
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)/'内容.json'
            previous = b'previous file bytes\n'
            target.write_bytes(previous)
            document.update_title('学校')
            self.assertEqual(document.save(target), target)
            self.assertEqual(target.with_name(target.name+'.bak').read_bytes(), previous)
            self.assertEqual(json.loads(target.read_text(encoding='utf-8')), document.data)
            self.assertEqual(document.path, target)
            self.assertFalse(document.dirty)
            self.assertEqual(list(Path(directory).glob('*.tmp')), [])

    def test_replace_failure_preserves_file_and_unsaved_draft(self):
        document = model.ContentDocument(self.base)
        document.update_title('学校')
        old_snapshot = deepcopy(document.saved_snapshot)
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)/'内容.json'
            target.write_bytes(b'untouched')
            actual_replace = model.os.replace

            def fail_target(source, destination):
                if Path(destination) == target:
                    raise PermissionError('模拟目标文件占用')
                return actual_replace(source, destination)

            with patch.object(model.os, 'replace', side_effect=fail_target):
                with self.assertRaises(PermissionError):
                    document.save(target)
            self.assertEqual(target.read_bytes(), b'untouched')
            self.assertEqual(document.saved_snapshot, old_snapshot)
            self.assertIsNone(document.path)
            self.assertTrue(document.dirty)
            self.assertEqual(document.data['title'], '学校')
            self.assertEqual(list(Path(directory).glob('*.tmp')), [])

    def test_failed_export_does_not_overwrite_old_cfg_or_backup(self):
        document = model.ContentDocument(self.base)
        self.update_room(document, 1, 1, description='学'*49)
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)/'SITE.CFG'
            backup = target.with_name('SITE.CFG.bak')
            target.write_bytes(b'old valid candidate')
            backup.write_bytes(b'old backup')
            with self.assertRaisesRegex(ValueError, '第 2 层.*房间简介.*5 行'):
                document.export_cfg(target)
            self.assertEqual(target.read_bytes(), b'old valid candidate')
            self.assertEqual(backup.read_bytes(), b'old backup')
            self.assertEqual(document.data['floors'][1]['rooms'][1]['description'], '学'*49)
            self.assertTrue(document.dirty)

    def test_full_real_export_contains_new_glyph_payload_and_keeps_draft_dirty(self):
        document = model.ContentDocument(self.school)
        document.update_title('学校')
        expected = export_site_cfg.export(document.data)
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)/'SITE.CFG'
            document.export_cfg(target)
            data = target.read_bytes()
            self.assertEqual(data, expected)
            self.assertEqual(len(data), 27648)
            self.assertEqual(data[:5], b'SGC1\x06')
            self.assertEqual(sum(data[8192:]) & 65535, struct.unpack_from('<H', data, 24)[0])
            self.assertNotEqual(data[8192:], bytes(19456))
            self.assertTrue(document.dirty)
            self.assertIsNone(document.path)

    def test_structural_export_error_preserves_target(self):
        document = model.ContentDocument(self.school)
        document.data['floors'][0]['rooms'][0]['point_photo_image'] = 999
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)/'SITE.CFG'
            target.write_bytes(b'old')
            with self.assertRaises(ValueError):
                document.export_cfg(target)
            self.assertEqual(target.read_bytes(), b'old')

    def test_wrap_matches_exporter_and_keeps_explicit_empty_lines(self):
        self.assertEqual(model.wrap_notes(''), [''])
        self.assertEqual(model.wrap_notes('甲'*13), ['甲'*12, '甲'])
        self.assertEqual(model.wrap_notes('甲\n\n乙\n'), ['甲', '', '乙', ''])
        self.assertEqual(model.wrap_notes('甲'*48), ['甲'*12]*4)
        self.assertEqual(len(model.wrap_notes('甲'*48+'\n')), 5)

    def test_global_counts_include_other_floors_and_disabled_activities(self):
        config = self.config()
        config.pop('title')
        for floor in config['floors']:
            floor['name'] = '企'
            for room in floor['rooms']:
                room.update(name='企', description='', activity='', today_activity=False)
        config['floors'][0]['rooms'][0]['name'] = '甲'
        config['floors'][2]['rooms'][9]['name'] = '甲乙'
        config['floors'][0]['rooms'][0]['description'] = '物\n物'
        config['floors'][2]['rooms'][9]['activity'] = '理物'
        status = model.content_status(config)
        self.assertEqual(status['names_used'], 2)
        self.assertEqual(status['notes_used'], 2)
        self.assertEqual(status['issues'], [])

    def test_overcapacity_reports_counts_instead_of_raising(self):
        config = self.config()
        # A deliberately invalid editable draft still yields counts and locations.
        config['title'] = ''.join(chr(i) for i in range(0x4E00, 0x4E00+150))
        config['floors'][2]['rooms'][9]['description'] = ''.join(chr(i) for i in range(0x5000, 0x5000+100))
        document = model.ContentDocument(config)
        status = model.content_status(document.data)
        self.assertGreater(status['names_used'], 121)
        self.assertGreater(status['notes_used'], 85)
        self.assertTrue(any('终端标题' in issue and '1～8' in issue for issue in status['issues']))
        self.assertTrue(any('第 3 层' in issue and '房间简介' in issue for issue in status['issues']))
        self.assertTrue(any('最多 85' in issue for issue in status['issues']))

    def test_active_empty_activity_and_unsupported_characters_have_context(self):
        config = self.config()
        room = config['floors'][1]['rooms'][3]
        room.update(today_activity=True, activity='  ', description='学\t校e\u0301')
        status = model.content_status(config)
        self.assertTrue(any('第 2 层' in issue and '今日有活动' in issue for issue in status['issues']))
        self.assertTrue(any('第 4 个房间' in issue and 'U+0009' in issue for issue in status['issues']))
        self.assertTrue(any('U+0301' in issue for issue in status['issues']))

    def test_missing_font_glyph_is_reported_without_rendering(self):
        config = self.config()
        coverage = font_coverage(str(DEFAULT_LARGE_FONT))
        missing = next(chr(i) for i in range(0x20000, 0x2A6E0) if i not in coverage)
        config['title'] = missing
        with patch.object(export_site_cfg, 'export', side_effect=AssertionError('live status must not export')):
            status = model.content_status(config)
        self.assertTrue(any('终端标题' in issue and f'U+{ord(missing):04X}' in issue
                            for issue in status['issues']))

    def test_load_bom_draft_and_reject_bad_shapes_cleanly(self):
        config = self.config()
        config['title'] = '过长但仍能打开修改的标题'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'草稿.json'
            path.write_text(json.dumps(config, ensure_ascii=False), encoding='utf-8-sig')
            loaded = model.ContentDocument.load(path)
            self.assertEqual(loaded.data, config)
            self.assertFalse(loaded.dirty)
        bad_shapes = [[], {}, {'floors': []}, {'floors': [None]},
                      {'floors': [{'name': '楼', 'rooms': ['wrong']}]},
                      {'floors': [{'name': '楼', 'rooms': [{'name': '室', 'activity': None}]}]}]
        for config in bad_shapes:
            with self.subTest(config=config):
                with self.assertRaises(ValueError):
                    model.ContentDocument(config)
                self.assertTrue(model.content_status(config)['issues'])

    def test_default_and_school_examples_have_no_live_validation_issues(self):
        self.assertEqual(model.content_status(self.base)['issues'], [])
        self.assertEqual(model.content_status(self.school)['issues'], [])


if __name__ == '__main__':
    started = time.monotonic()
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ContentEditorModelTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    report = {
        'created_utc': datetime.now(timezone.utc).isoformat(),
        'tests_run': result.testsRun,
        'successful': result.wasSuccessful(),
        'elapsed_seconds': round(time.monotonic()-started, 3),
        'failures': [{'test': str(test), 'detail': detail} for test, detail in result.failures],
        'errors': [{'test': str(test), 'detail': detail} for test, detail in result.errors],
    }
    output = ROOT/'reports/content_editor/model_tests.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    sys.exit(0 if result.wasSuccessful() else 1)
