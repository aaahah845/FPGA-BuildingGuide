"""Exercise the real Tk form without changing the project's or card's content."""
from __future__ import annotations

from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import time
import traceback
import tkinter as tk
from unittest.mock import patch

from PIL import ImageGrab

import export_site_cfg


def _sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _non_text(config):
    result = deepcopy(config)
    result.pop('title', None)
    for floor in result['floors']:
        floor.pop('name', None)
        for room in floor['rooms']:
            for key in ('name', 'description', 'activity', 'today_activity'):
                room.pop(key, None)
    return result


def run_self_test(output: Path, EditorClass, resources: Path) -> int:
    output, resources = Path(output).resolve(), Path(resources).resolve()
    output.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    report = {
        'created_utc': datetime.now(timezone.utc).isoformat(),
        'pass': False,
        'runtime': {'frozen': bool(getattr(sys, 'frozen', False)),
                    'executable': sys.executable, 'python': sys.version.split()[0]},
        'checks': [],
        'evidence': {'resources': str(resources), 'screenshots': [],
                     'visual_review': 'pending human or root-agent inspection'},
    }
    gui_module = sys.modules[EditorClass.__module__]
    source_paths = [resources/'config/runtime_site.json',
                    resources/'config/glyph_catalog.json',
                    resources/'config/notes_glyph_catalog.json',
                    resources/'config/base_fonts/fixed_ui_base.bin',
                    resources/'scripts/site_content_editor.py',
                    resources/'scripts/site_editor_model.py',
                    resources/'scripts/site_editor_smoke.py']
    hashes_before = {str(path.relative_to(resources)): _sha(path)
                     for path in source_paths if path.is_file()}
    report['evidence']['resource_sha256_before'] = hashes_before
    report['evidence']['sources_embedded_as_python_files'] = (resources/'scripts/site_content_editor.py').is_file()
    root = None
    dialogs = []

    def record(name, condition, detail=None):
        report['checks'].append({'name': name, 'pass': bool(condition), 'detail': detail})
        if not condition:
            raise AssertionError(name + (': ' + str(detail) if detail else ''))

    def capture_dialog(kind):
        def capture(*args, **kwargs):
            dialogs.append({'kind': kind, 'title': str(args[0]) if args else '',
                            'message': str(args[1]) if len(args) > 1 else ''})
            return True
        return capture

    try:
        # The source JSON is only read. Use a temporary editable copy for every step.
        original = json.loads((resources/'config/runtime_site.json').read_text(encoding='utf-8-sig'))
        fixture = deepcopy(original)
        for floor in fixture['floors']:
            for room in floor['rooms']:
                room.update(description='', activity='', today_activity=False)
        fixture['_editor_test_unknown'] = {'keep': ['图片编号', 17, True]}
        original_non_text = _non_text(fixture)
        record('fixture_has_two_floors_and_rooms', len(fixture['floors']) >= 2
               and all(floor['rooms'] for floor in fixture['floors']))
        with tempfile.TemporaryDirectory(prefix='site_editor_smoke_') as directory:
            work = Path(directory)
            draft = work/'隔离草稿.json'
            draft.write_text(json.dumps(fixture, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
            initial_bytes = draft.read_bytes()
            root = tk.Tk()
            with patch.object(gui_module.messagebox, 'showinfo', side_effect=capture_dialog('info')), \
                 patch.object(gui_module.messagebox, 'showerror', side_effect=capture_dialog('error')), \
                 patch.object(gui_module.messagebox, 'askyesnocancel', return_value=False):
                app = EditorClass(root, draft)
                root.update_idletasks()
                root.update()
                record('real_tk_editor_initialized', app.document is not None and root.winfo_exists())
                record('opening_keeps_document_identical', app.document.data == fixture and not app.document.dirty)
                record('unmodified_save_returns_success', app.save())
                record('unmodified_save_keeps_json_semantics', json.loads(draft.read_text(encoding='utf-8')) == fixture)
                record('unmodified_save_keeps_original_backup', draft.with_name(draft.name+'.bak').read_bytes() == initial_bytes)

                def select(item):
                    app.tree.selection_set(item)
                    app.tree.focus(item)
                    app.tree.see(item)
                    root.update_idletasks()
                    root.update()
                    parts = item.split(':')
                    expected_room = int(parts[1]) if len(parts) == 2 else None
                    record('tree_navigation_' + item.replace(':', '_'),
                           app.floor_index == int(parts[0]) and app.room_index == expected_room)

                def text(widget, value):
                    widget.configure(state='normal')
                    widget.delete('1.0', 'end')
                    widget.insert('1.0', value)

                # Deliberately navigate before the 180 ms debounce, testing _commit.
                app.title_var.set('校园导览终端')
                app.floor_var.set('教学一层')
                app.room_var.set('物理实验室')
                text(app.description, '开展物理实验。\n课前做好准备。')
                text(app.activity, '14:00-15:00\n物理实验课')
                app.activity_var.set(True)
                select('1:0')
                app.floor_var.set('教学二层')
                app.room_var.set('数学教室')
                text(app.description, '数学课程与讨论。')
                select('0:0')
                record('first_room_values_survive_navigation',
                       app.title_var.get() == '校园导览终端'
                       and app.floor_var.get() == '教学一层'
                       and app.room_var.get() == '物理实验室'
                       and app.description.get('1.0', 'end-1c') == '开展物理实验。\n课前做好准备。'
                       and app.activity.get('1.0', 'end-1c') == '14:00-15:00\n物理实验课'
                       and app.activity_var.get())
                record('other_floor_edits_survive_navigation',
                       app.document.data['floors'][1]['name'] == '教学二层'
                       and app.document.data['floors'][1]['rooms'][0]['name'] == '数学教室'
                       and app.document.data['floors'][1]['rooms'][0]['description'] == '数学课程与讨论。')

                app.activity_var.set(False)
                select('1:0')
                select('0:0')
                record('activity_off_preserves_text', not app.activity_var.get()
                       and app.activity.get('1.0', 'end-1c') == '14:00-15:00\n物理实验课')

                # Save As is invoked while the current text has not been navigated away.
                current_text = '开展物理实验。\n按课程安排使用。'
                text(app.description, current_text)
                saved = work/'另存草稿.json'
                with patch.object(gui_module.filedialog, 'asksaveasfilename', return_value=str(saved)):
                    record('save_as_current_form_success', app.save(save_as=True))
                saved_data = json.loads(saved.read_text(encoding='utf-8'))
                record('save_as_commits_unflushed_current_text',
                       saved_data['floors'][0]['rooms'][0]['description'] == current_text
                       and app.document.path == saved and not app.document.dirty)

                target = work/'SITE.CFG'
                target.write_bytes(b'KEEP EXISTING CFG ON VALIDATION FAILURE')
                invalid = '物'*49
                text(app.description, invalid)
                errors_before = sum(dialog['kind'] == 'error' for dialog in dialogs)
                with patch.object(gui_module.filedialog, 'asksaveasfilename', return_value=str(target)):
                    app.export_dialog()
                record('overlength_export_keeps_existing_file',
                       target.read_bytes() == b'KEEP EXISTING CFG ON VALIDATION FAILURE')
                record('overlength_export_reports_error_and_keeps_draft',
                       sum(dialog['kind'] == 'error' for dialog in dialogs) == errors_before+1
                       and app.document.data['floors'][0]['rooms'][0]['description'] == invalid
                       and bool(app.current_issues))

                # Correct the form and immediately export, without waiting for refresh.
                final_text = '开展物理实验。\n按课程安排使用。'
                text(app.description, final_text)
                app.activity_var.set(True)
                success_before = sum(dialog['title'] == '导出成功' for dialog in dialogs)
                with patch.object(gui_module.filedialog, 'asksaveasfilename', return_value=str(target)):
                    app.export_dialog()
                data = target.read_bytes()
                record('real_export_success_dialog',
                       sum(dialog['title'] == '导出成功' for dialog in dialogs) == success_before+1)
                record('real_export_commits_current_form',
                       app.document.data['floors'][0]['rooms'][0]['description'] == final_text
                       and app.document.data['floors'][0]['rooms'][0]['today_activity'] is True)
                record('real_export_matches_v6_exporter', len(data) == 27648 and data[:5] == b'SGC1\x06'
                       and data == export_site_cfg.export(app.document.data))
                record('export_keeps_unsaved_draft_dirty', app.document.dirty)
                record('all_nontext_configuration_preserved', _non_text(app.document.data) == original_non_text)

                # Save sample evidence outside the temporary directory for repeatable review.
                (output/'exported_SITE.CFG').write_bytes(data)
                (output/'edited_fixture.json').write_text(
                    json.dumps(app.document.data, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
                report['evidence']['exported_cfg_sha256'] = hashlib.sha256(data).hexdigest()
                report['evidence']['dialogs'] = dialogs
                app.refresh()
                root.update_idletasks()
                root.update()
                report['evidence']['window'] = {
                    'viewable': bool(root.winfo_viewable()), 'width': root.winfo_width(),
                    'height': root.winfo_height(), 'x': root.winfo_rootx(), 'y': root.winfo_rooty(),
                }
                # Screen capture is evidence only; pixel capture does not assert visual quality.
                try:
                    if not root.winfo_viewable() or root.winfo_width() < 100 or root.winfo_height() < 100:
                        raise RuntimeError('编辑器窗口不可见，未生成视觉证据')
                    root.lift()
                    root.update_idletasks()
                    root.update()
                    bounds = (root.winfo_rootx(), root.winfo_rooty(),
                              root.winfo_rootx()+root.winfo_width(), root.winfo_rooty()+root.winfo_height())
                    screenshot = ImageGrab.grab(bbox=bounds, all_screens=True)
                    screenshot.save(output/'editor.png')
                    report['evidence']['screenshots'].append({
                        'path': str(output/'editor.png'), 'size': list(screenshot.size),
                        'sha256': _sha(output/'editor.png'),
                        'capture_only_not_visual_approval': True,
                    })
                except Exception as error:
                    report['evidence']['screenshot_error'] = str(error)
                    report['evidence']['visual_review'] = 'not possible: screenshot unavailable'
                if app.pending:
                    root.after_cancel(app.pending)
                    app.pending = None

        hashes_after = {str(path.relative_to(resources)): _sha(path)
                        for path in source_paths if path.is_file()}
        record('original_resources_unchanged', hashes_before == hashes_after)
        report['evidence']['resource_sha256_after'] = hashes_after
        report['pass'] = True
    except Exception as error:
        report['error'] = str(error)
        report['traceback'] = traceback.format_exc()
        report['evidence']['dialogs'] = dialogs
    finally:
        if root is not None:
            try:
                root.destroy()
            except tk.TclError:
                pass
        report['elapsed_seconds'] = round(time.monotonic()-started, 3)
        (output/'results.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print(json.dumps({'pass': report['pass'], 'checks': len(report['checks']),
                      'report': str(output/'results.json')}, ensure_ascii=False))
    return 0 if report['pass'] else 1
