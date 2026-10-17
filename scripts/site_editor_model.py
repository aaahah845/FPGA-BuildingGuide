"""Lossless document model and live validation for the Chinese content editor."""
from __future__ import annotations

from copy import deepcopy
import json
import os
from pathlib import Path
import tempfile
import unicodedata

import export_site_cfg
from dynamic_text_fonts import (
    DEFAULT_LARGE_FONT, DEFAULT_NOTES_FONT, LARGE_RESERVED, NOTES_RESERVED,
    font_coverage,
)

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_TITLE = '企业会议导视'


def _check_shape(config):
    """Check editor assumptions without rejecting an overlength editable draft."""
    if not isinstance(config, dict):
        raise ValueError('配置最外层必须是对象')
    if 'title' in config and not isinstance(config['title'], str):
        raise ValueError('终端标题必须是文字')
    floors = config.get('floors')
    if not isinstance(floors, list) or not floors:
        raise ValueError('配置必须包含非空的 floors 楼层列表')
    for fi, floor in enumerate(floors):
        location = f'第 {fi+1} 层'
        if not isinstance(floor, dict) or not isinstance(floor.get('name'), str):
            raise ValueError(f'{location} 必须是对象，并包含文字类型的 name 名称')
        rooms = floor.get('rooms')
        if not isinstance(rooms, list) or not rooms:
            raise ValueError(f'{location} 必须包含非空的 rooms 房间列表')
        for ri, room in enumerate(rooms):
            location = f'第 {fi+1} 层 / 第 {ri+1} 个房间'
            if not isinstance(room, dict) or not isinstance(room.get('name'), str):
                raise ValueError(f'{location} 必须是对象，并包含文字类型的 name 名称')
            for key, label in (('description', '房间简介'), ('activity', '活动说明')):
                if key in room and not isinstance(room[key], str):
                    raise ValueError(f'{location}的{label}必须是文字')
            if 'today_activity' in room and type(room['today_activity']) is not bool:
                raise ValueError(f'{location}的 today_activity 必须为 true 或 false')


def wrap_notes(text):
    """Use exactly the exporter's 12-character wrap and explicit newline rules."""
    if not isinstance(text, str):
        raise ValueError('说明必须是文字')
    lines = []
    for paragraph in text.split('\n'):
        lines.extend([paragraph[j:j+12] for j in range(0, len(paragraph), 12)] or [''])
    return lines


def _atomic_write(path, data, *, backup=True):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f'.{path.name}.', suffix='.tmp', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if backup and path.exists():
            # Finish the backup before replacing the target; failures preserve it.
            _atomic_write(path.with_name(path.name + '.bak'), path.read_bytes(), backup=False)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return path


class ContentDocument:
    def __init__(self, config: dict, path: Path | None = None):
        _check_shape(config)
        self.data = deepcopy(config)
        self.path = Path(path) if path is not None else None
        self.saved_snapshot = deepcopy(self.data)

    @classmethod
    def load(cls, path):
        path = Path(path)
        return cls(json.loads(path.read_text(encoding='utf-8-sig')), path)

    @property
    def dirty(self):
        return self.data != self.saved_snapshot

    def update_title(self, text: str):
        if not isinstance(text, str):
            raise ValueError('终端标题必须是文字')
        if 'title' in self.data or text != DEFAULT_TITLE:
            self.data['title'] = text

    def update_floor(self, floor_index, name):
        if not isinstance(name, str):
            raise ValueError('楼层名称必须是文字')
        self.data['floors'][floor_index]['name'] = name

    def update_room(self, fi, ri, *, name, description, activity, today_activity):
        if not all(isinstance(value, str) for value in (name, description, activity)):
            raise ValueError('房间名称、简介和活动说明必须是文字')
        if type(today_activity) is not bool:
            raise ValueError('今日是否有活动必须为布尔值')
        room = self.data['floors'][fi]['rooms'][ri]
        for key, value, default in (
            ('name', name, ''), ('description', description, ''),
            ('activity', activity, ''), ('today_activity', today_activity, False),
        ):
            if key in room or value != default:
                room[key] = value

    def save(self, path):
        path = Path(path)
        payload = (json.dumps(self.data, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
        _atomic_write(path, payload)
        self.path = path
        self.saved_snapshot = deepcopy(self.data)
        return path

    def export_cfg(self, path):
        status = content_status(self.data)
        if status['issues']:
            raise ValueError('\n'.join(status['issues']))
        # Render/validate everything first. An invalid draft cannot replace a CFG.
        payload = export_site_cfg.export(self.data)
        return _atomic_write(path, payload)


def content_status(config):
    """Return all text issues and global counts without rendering glyph bitmaps."""
    result = {'names_used': 0, 'names_limit': 121,
              'notes_used': 0, 'notes_limit': 85, 'issues': []}
    issues = result['issues']
    try:
        _check_shape(config)
    except ValueError as error:
        issues.append(str(error))
        return result

    try:
        names_catalog = json.loads((ROOT/'config/glyph_catalog.json').read_text(encoding='utf-8'))['chars']
        notes_catalog = json.loads((ROOT/'config/notes_glyph_catalog.json').read_text(encoding='utf-8'))['chars']
        names_fixed = {names_catalog[i] for i in LARGE_RESERVED}
        notes_fixed = {notes_catalog[i] for i in NOTES_RESERVED}
    except (OSError, ValueError, KeyError, IndexError, TypeError) as error:
        issues.append(f'无法读取固定字库配置：{error}')
        return result

    names_fields, notes_fields = [], []
    if 'title' in config:
        names_fields.append(('终端标题', config['title']))
        if not config['title'].strip():
            issues.append('终端标题不能全部为空白')
    if len(config['floors']) > 3:
        issues.append('最多支持 3 个楼层')
    for fi, floor in enumerate(config['floors']):
        floor_location = f'第 {fi+1} 层（{floor["name"]}）'
        names_fields.append((floor_location + ' / 楼层名称', floor['name']))
        if len(floor['rooms']) > 10:
            issues.append(f'{floor_location}最多支持 10 个房间')
        for ri, room in enumerate(floor['rooms']):
            location = f'{floor_location} / 第 {ri+1} 个房间（{room["name"]}）'
            names_fields.append((location + ' / 房间名称', room['name']))
            for key, label in (('description', '房间简介'), ('activity', '活动说明')):
                text = room.get(key, '')
                notes_fields.append((location + ' / ' + label, text))
                lines = wrap_notes(text)
                if len(lines) > 4:
                    issues.append(f'{location} / {label}折行后为 {len(lines)} 行；最多 4 行，每行 12 字')
            if room.get('today_activity', False) and not room.get('activity', '').strip():
                issues.append(f'{location} / 已勾选今日有活动，请填写活动说明')
    for location, text in names_fields:
        if not 1 <= len(text) <= 8:
            issues.append(f'{location}为 {len(text)} 字；必须为 1～8 字')

    names_chars = set(''.join(text for _, text in names_fields))
    notes_chars = set(''.join(text for _, text in notes_fields)) - {'\n'}
    result['names_used'] = len(names_chars - names_fixed)
    result['notes_used'] = len(notes_chars - notes_fixed)
    for key, label in (('names', '标题、楼层与房间名称'), ('notes', '全部房间的简介与活动说明')):
        if result[f'{key}_used'] > result[f'{key}_limit']:
            issues.append(f'{label}共用字模已用 {result[f"{key}_used"]} 种不同字符，最多 {result[f"{key}_limit"]} 种；重复字只计一次')

    for fields, fixed, font_path, allow_newline, label in (
        (names_fields, names_fixed, DEFAULT_LARGE_FONT, False, '名称字体'),
        (notes_fields, notes_fixed, DEFAULT_NOTES_FONT, True, '说明字体'),
    ):
        try:
            coverage = font_coverage(str(font_path))
        except (OSError, ValueError) as error:
            issues.append(f'{label}不可用：{error}')
            coverage = None
        for location, text in fields:
            for char in sorted(set(text), key=ord):
                if allow_newline and char == '\n':
                    continue
                if unicodedata.category(char).startswith('C') or unicodedata.combining(char):
                    issues.append(f'{location}不支持字符 {char!r}（U+{ord(char):04X}，控制字符或组合字符）')
                elif char not in fixed and coverage is not None and ord(char) not in coverage:
                    issues.append(f'{location}中的 {char!r}（U+{ord(char):04X}）在当前字体中没有字形')
    return result
