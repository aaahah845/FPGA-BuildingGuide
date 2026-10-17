"""Package one verified overlay implementation. Usage: python tools/package_overlay_candidate.py 61.

All evidence is checked before publishing. This script does not run TD, change
RTL/constraints/run settings, download a bitstream, or shut down the computer.
"""
from pathlib import Path
import argparse
import copy
import datetime
import difflib
import hashlib
import json
import re
import shutil
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT.parent / 'lab_image_photo_crossfade_20261015'
PROJECT = ROOT / 'src/td_project/image_multiview_gui.al'
RUNS = PROJECT.parent / 'image_multiview_gui_Runs'
RELEASE = ROOT / 'release'
LIMITS = {'mslice': 4900, 'lut': 19600, 'reg': 19600, 'bram9k': 64, 'dsp': 29}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def readj(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def dumpj(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def normalized_manifest(data):
    return {name.replace('\\', '/'): value.lower() for name, value in data.items()}


def current_sources():
    return {p.relative_to(ROOT).as_posix(): sha(p)
            for p in (ROOT / 'src/user_source').rglob('*')
            if p.is_file() and p.suffix.lower() in ('.v', '.vh', '.sdc', '.adc', '.tcl')}


def verify_hashes(data, label):
    """Support the hash field names used by the independent test runners."""
    for field in ('input_sha256', 'source_hashes', 'source_sha256'):
        for name, expected in data.get(field, {}).items():
            path = ROOT / name.replace('\\', '/')
            assert path.is_file() and sha(path) == expected.lower(), (label, 'stale test source', name)
    for field in ('sources_unchanged', 'sources_unchanged_during_test',
                  'inputs_unchanged_during_test', 'reader_unchanged_during_test'):
        if field in data:
            assert data[field] is True, (label, field)


def load_test(relative, label):
    value = readj(ROOT / relative)
    for entry in value if isinstance(value, list) else [value]:
        assert entry.get('pass', entry.get('passed', False)) is True, (label, 'not passed', entry)
        verify_hashes(entry, label)
    return value


def parse_timing(path):
    report = path.read_text(encoding='utf-8', errors='replace')
    result = {'setup_wns_ns': float(re.search(r'SWNS:\s*(-?[\d.]+)ns', report)[1]),
              'setup_tns_ns': float(re.search(r'STNS:\s*(-?[\d.]+)ns', report)[1]),
              'min_wns_ns': float(re.search(r'HWNS:\s*(-?[\d.]+)ns', report)[1]),
              'min_tns_ns': float(re.search(r'HTNS:\s*(-?[\d.]+)ns', report)[1]),
              'groups': [], 'negative_paths_reported': []}
    for part in re.split(r'^Path Group\s*:', report, flags=re.M)[1:]:
        name = part.splitlines()[0].strip()
        group = {'group': name}
        for label in ('Max', 'Min'):
            match = re.search(r'^' + label + r'\s*:\s*[SH]WNS\s+(-?[\d.]+)ns,\s*'
                              r'[SH]TNS\s+(-?[\d.]+)ns,\s*(\d+) Viol Endpoints', part, re.M)
            if match:
                group[label] = {'wns_ns': float(match[1]), 'tns_ns': float(match[2]),
                                'negative_endpoints': int(match[3])}
        if 'Max' not in group and 'Min' not in group:
            continue
        group['sdram_interface'] = ('ext_mem_clk' in name and 'sys_pll_m0/pll_inst.clkc[2]' in name)
        result['groups'].append(group)
        for match in re.finditer(r'^Slack\s*:\s*(-[\d.]+)ns\s*\nBegin Point\s*:\s*([^\n]+)'
                                 r'\nEnd Point\s*:\s*([^\n]+)\nCheck Type\s*:\s*(\w+)', part, re.M):
            result['negative_paths_reported'].append({'group': name, 'slack_ns': float(match[1]),
                                                       'begin': match[2].strip(), 'end': match[3].strip(),
                                                       'type': match[4].lower()})
    for label in ('Max', 'Min'):
        result[label.lower() + '_negative_endpoints'] = sum(
            group.get(label, {}).get('negative_endpoints', 0) for group in result['groups'])
    result['sdram_max_negative_endpoints'] = sum(group.get('Max', {}).get('negative_endpoints', 0)
                                                for group in result['groups'] if group['sdram_interface'])
    result['other_max_negative_endpoints'] = result['max_negative_endpoints'] - result['sdram_max_negative_endpoints']
    min_paths = [p for p in result['negative_paths_reported'] if p['type'] in ('hold', 'removal')]
    result['min_types_reported'] = {}
    for kind in ('hold', 'removal'):
        paths = [p for p in min_paths if p['type'] == kind]
        unique = {(p['group'], p['end']) for p in paths}
        result['min_types_reported'][kind] = {'negative_endpoints_reported': len(unique),
                                             'worst_slack_ns': min((p['slack_ns'] for p in paths), default=None)}
    result['min_type_breakdown_complete'] = sum(v['negative_endpoints_reported'] for v in result['min_types_reported'].values()) == result['min_negative_endpoints']
    result['report_limit_note'] = 'Detailed paths are limited by the report scheme; group endpoint statistics remain authoritative.'
    return result


def parse_resources(run, console=None):
    area = (run / 'image_multiview_gui_phy.area').read_text(encoding='utf-8')
    resources = {}
    for name in ('lut', 'reg', 'bram9k', 'dsp'):
        match = re.search(r'^\s*#' + name + r'\s+(\d+)', area, re.M)
        assert match, ('missing resource', name, run)
        resources[name] = int(match[1])
    logs = [console] if console and console.exists() else sorted(run.glob('td_*.log'), key=lambda p: p.stat().st_mtime, reverse=True)
    matches = []
    for log in logs:
        matches = re.findall(r'(\d+) mslices', log.read_text(encoding='utf-8', errors='replace'))
        if matches:
            break
    assert matches, ('missing physical MSlice result', run)
    resources['mslice'] = int(matches[-1])
    return resources


def summarize_run(run, source_manifest):
    out = ROOT / 'reports/photo_crossfade' / run.name
    result = {'run': run.name, 'complete': False, 'selected': False}
    if not (run / 'final_timing.rpt').exists() or not (out / 'build_result.json').exists():
        return result
    build = readj(out / 'build_result.json')
    result['build_pass'] = build.get('pass', False)
    manifest_path = out / 'source_manifest.json'
    result['current_source_match'] = manifest_path.exists() and normalized_manifest(readj(manifest_path)) == source_manifest
    result.update(complete=bool(build.get('pass') and result['current_source_match']),
                  resources=parse_resources(run, out / 'td_console.log'), timing=parse_timing(run / 'final_timing.rpt'))
    return result


def prepare_project(seed):
    """Change only GUI metadata; preserve the actual selected run's build inputs."""
    def parse_td_xml(path):
        # TD emits attributes such as Name="UsedInP&R" with literal '&'.
        # Escape only bare ampersands for the standards-compliant parser; leave
        # actual entities untouched and restore TD's attribute convention below.
        source = path.read_text(encoding='utf-8-sig')
        source = re.sub(r'&(?!#\d+;|#x[0-9a-fA-F]+;|[A-Za-z][A-Za-z0-9]*;)', '&amp;', source)
        return ET.ElementTree(ET.fromstring(source))

    tree = parse_td_xml(PROJECT)
    root = tree.getroot()
    root.set('Path', PROJECT.parent.as_posix())
    runs = root.find('Runs')
    assert runs is not None
    syn = next((item for item in runs if item.get('Name') == 'syn_1'), None)
    chosen_name = f'phy_seed{seed}'
    chosen = next((item for item in runs if item.get('Name') == chosen_name), None)
    if chosen is None:
        template = next((item for item in runs if item.get('Type') == 'PhysicalDesign'), None)
        assert template is not None and syn is not None
        chosen = copy.deepcopy(template)
    else:
        chosen = copy.deepcopy(chosen)
    chosen.set('Name', chosen_name)
    chosen.set('Active', 'true')
    chosen.set('SynRun', 'syn_1')
    chosen.set('Description', 'Photo overlay retaining detail background; board test pending')
    strategy = chosen.find('Strategy')
    assert strategy is not None
    actual_prj = parse_td_xml(RUNS / chosen_name / 'image_multiview_gui.prj').getroot()
    actual_properties = actual_prj.find('Property')
    assert actual_properties is not None
    for prop in actual_properties:
        old = strategy.find(prop.tag)
        if old is not None:
            strategy.remove(old)
        strategy.append(copy.deepcopy(prop))
    assert strategy.findtext('PlaceProperty/seed') == str(seed), 'chosen .prj seed does not match requested seed'
    params = chosen.find('UserParams')
    assert params is not None
    found_seed = False
    for param in params:
        if re.match(r'\s*set_param\s+place\s+seed\s+', param.text or ''):
            param.text = f'set_param place seed {seed}'
            found_seed = True
    if not found_seed:
        ET.SubElement(params, 'param').text = f'set_param place seed {seed}'
    assert syn is not None
    syn = copy.deepcopy(syn)
    syn.set('Active', 'true')
    for item in list(runs):
        runs.remove(item)
    runs.extend([syn, chosen])
    ET.indent(tree, space='    ')
    return ET.tostring(root, encoding='unicode', xml_declaration=False).replace('UsedInP&amp;R', 'UsedInP&R')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('seed', type=int)
    args = parser.parse_args()
    assert 0 <= args.seed <= 2147483647
    seed = args.seed
    run_name = f'phy_seed{seed}'
    run = RUNS / run_name
    build_dir = ROOT / 'reports/photo_crossfade' / run_name
    sources = current_sources()
    checks = {
        'synthesis': 'reports/photo_crossfade/syn_1/build_result.json',
        'physical': f'reports/photo_crossfade/{run_name}/build_result.json',
        'control': 'reports/nav_keys/simulation/results.json',
        'broker': 'reports/photo_fade/simulation/broker_photo_fade_results.json',
        'reader': 'reports/photo_full_reader/results.json',
        'compositor': 'reports/photo_overlay/compositor_sim/results.json',
        'reset_release': 'reports/reset_release/results.json',
        'existing_bilinear': 'reports/direct_read_lockstep/results.json',
        'vendor_mixed': 'reports/vendor_crossfade/case3_4_results.json',
        'vendor_full': 'reports/vendor_crossfade/case6_7_results.json',
    }
    results = {key: load_test(relative, key) for key, relative in checks.items()}
    syn_sources = normalized_manifest(readj(ROOT / 'reports/photo_crossfade/syn_1/source_manifest.json'))
    phy_sources = normalized_manifest(readj(build_dir / 'source_manifest.json'))
    assert sources == syn_sources == phy_sources, 'current, synthesis and physical source manifests differ'
    for stage in ('synthesis', 'physical'):
        assert results[stage].get('sources_unchanged') and results[stage].get('artifact_new'), stage
    reader = ROOT / 'src/user_source/hdl_source/SD/scene_frame_reader.v'
    cache = reader.with_name('bilinear_span_cache.v')
    reader_hash, cache_hash = sha(reader), sha(cache)
    for key in ('reader', 'existing_bilinear', 'vendor_mixed', 'vendor_full'):
        assert results[key]['reader_sha256'] == reader_hash and results[key]['reader_unchanged_during_test'], key
    for key in ('reader', 'vendor_mixed', 'vendor_full'):
        assert normalized_manifest(results[key]['input_sha256'])['src/user_source/hdl_source/SD/bilinear_span_cache.v'] == cache_hash, key
    assert (ROOT / checks['existing_bilinear']).stat().st_mtime >= cache.stat().st_mtime, 'lockstep result predates current cache'
    assert results['reader']['expected_frames'] == 6 and results['reader']['expected_pixels'] == 2880000
    assert (results['vendor_mixed']['first_frame'], results['vendor_mixed']['last_frame_exclusive']) == (3, 4)
    assert (results['vendor_full']['first_frame'], results['vendor_full']['last_frame_exclusive']) == (6, 7)
    # These two legacy runners have no per-file hash payload. Require their
    # unchanged baseline RTL and results newer than the actual source files.
    for key, names in {'control': ('guide_scene_control.v', 'key_remove_shakes.v'),
                       'broker': ('site_scene_broker.v',)}.items():
        for name in names:
            relative = Path('src/user_source/hdl_source') / name
            assert sha(ROOT / relative) == sha(BASE / relative), (key, 'baseline source changed without hashed regression', name)
            assert (ROOT / checks[key]).stat().st_mtime >= (ROOT / relative).stat().st_mtime, (key, 'stale result')
    for name in ('pin.adc', 'timing.sdc'):
        relative = Path('src/user_source/constraints_source') / name
        assert (ROOT / relative).read_bytes() == (BASE / relative).read_bytes(), ('constraints changed', name)
    assert (RELEASE / 'SITE.CFG').read_bytes() == (BASE / 'release/SITE.CFG').read_bytes(), 'SITE.CFG differs'
    started = readj(build_dir / 'process.json')['started_epoch']
    for artifact in ('image_multiview_gui.bit', 'final_timing.rpt', 'image_multiview_gui_phy.area'):
        assert (run / artifact).stat().st_mtime >= started, ('stale build artifact', artifact)
    resources = parse_resources(run, build_dir / 'td_console.log')
    timing = parse_timing(run / 'final_timing.rpt')
    baseline_manifest = readj(BASE / 'release/manifest.json')
    baseline_resources = baseline_manifest['resources']
    baseline_timing = parse_timing(BASE / 'release/crossfade_seed23_timing.rpt')
    for key, limit in LIMITS.items():
        assert resources[key] <= limit, ('device capacity exceeded', key, resources[key], limit)
    assert resources['bram9k'] <= baseline_resources['bram9k'] and resources['dsp'] <= baseline_resources['dsp'], 'BRAM/DSP increased'
    project_text = prepare_project(seed)
    candidate = RELEASE / f'image_nav_photo_overlay_seed{seed}_untested.bit'
    candidate_hash = sha(run / 'image_multiview_gui.bit')
    comparisons = [summarize_run(path, sources) for path in sorted(RUNS.glob('phy_seed*'))]
    for entry in comparisons:
        entry['selected'] = entry['run'] == run_name
    assert any(entry['selected'] and entry['complete'] for entry in comparisons)
    modified, patch = [], []
    for path in sorted((ROOT / 'src/user_source').rglob('*')):
        if not path.is_file():
            continue
        relative = path.relative_to(ROOT)
        old = BASE / relative
        if old.exists() and path.read_bytes() == old.read_bytes():
            continue
        modified.append({'file': relative.as_posix(), 'sha256': sha(path)})
        if path.suffix.lower() in ('.v', '.vh', '.sdc', '.adc', '.tcl'):
            before = old.read_text(encoding='utf-8-sig').splitlines(keepends=True) if old.exists() else []
            after = path.read_text(encoding='utf-8-sig').splitlines(keepends=True)
            patch.extend(difflib.unified_diff(before, after, fromfile='crossfade/' + relative.as_posix(),
                                             tofile='overlay/' + relative.as_posix()))
    resource_delta = {key: resources[key] - baseline_resources[key] for key in LIMITS}
    manifest = {
        'packaged_at': datetime.datetime.now().astimezone().isoformat(), 'base_copy': str(BASE),
        'project': str(PROJECT), 'physical_run': run_name, 'candidate': candidate.name,
        'candidate_sha256': candidate_hash, 'board_test': 'pending',
        'constraints_unchanged': True, 'site_cfg_unchanged': True, 'resources': resources,
        'resource_limits': LIMITS, 'resource_delta_from_crossfade_seed23': resource_delta,
        'timing': timing, 'baseline_resources': baseline_resources, 'baseline_timing': baseline_timing,
        'modified_sources': modified, 'source_manifest': sources, 'verification': results,
        'verification_files': checks, 'timing_comparison': comparisons,
        'transition_format': 'Only the 640x480 photo rectangle carries paired RGB565 pixels and nearest backdrop samples during mixed frames. Exterior pixels retain RGB888 and the user-selected sampler throughout; settled full photos retain the exterior detail page.',
        'startup_note': 'An earlier candidate intermittently started black and recovered after power cycling or TF-card reinsertion. The cause remains unconfirmed; no startup fix or hardware validation is claimed for this candidate.',
    }
    resource_rows = '\n'.join(f"| {key.upper()} | {baseline_resources[key]} | {resources[key]} / {limit} | {resource_delta[key]:+d} |" for key, limit in LIMITS.items())
    group_rows = []
    for group in timing['groups']:
        mx, mn = group.get('Max', {}), group.get('Min', {})
        group_rows.append(f"| `{group['group'] or '(未命名组)'}` | {mx.get('wns_ns', '—')} | {mx.get('negative_endpoints', '—')} | {mn.get('wns_ns', '—')} | {mn.get('negative_endpoints', '—')} |")
    type_rows = '\n'.join(f"| {kind} | {value['negative_endpoints_reported']} | {value['worst_slack_ns'] if value['worst_slack_ns'] is not None else '—'} |" for kind, value in timing['min_types_reported'].items())
    sdram_count = timing['sdram_max_negative_endpoints']
    if sdram_count:
        sdram_note = f"SDRAM 接口时钟组仍有 {sdram_count} 个 Max 负端点，需要继续核实 IP 接口时序模型、PLL 相位关系和板级时序要求；不能由功能仿真通过推导为无影响。"
    else:
        sdram_note = '所选实现的 SDRAM 接口时钟组未报告 Max 负端点，仍须以完整报告和板级验证共同判断接口工作状态。'
    type_note = ('详细负路径能够覆盖本报告全部 Min 负端点，可区分 hold 与 removal。'
                 if timing['min_type_breakdown_complete'] else
                 '下表仅统计报告列出的 Min 负端点类型；详细路径数量受报告上限限制，不把未列出的端点推断为 hold。')
    readme = f'''# 保留详情背景的大图淡化副本

基于 `lab_image_photo_crossfade_20261015` 建立。640×480 照片在800×600画面中央淡入，照片矩形外始终保留原详情界面；返回时照片淡出，不产生白边或黑场。完整过渡16帧，在60 Hz下约0.27秒。

- 候选位流：`release/{candidate.name}`，尚未上板验证。
- TD工程：`src/td_project/image_multiview_gui.al`，活动实现为 `{run_name}`。
- 详情页再次按 MID / SW4 打开大图，按 RST / SW3 返回；中途返回从当前透明度反向变化。
- 图片和V6 `SITE.CFG`无需修改，现有自定义文字保持兼容。
- 只有照片矩形内的过渡像素临时采用RGB565和最近邻底图采样；矩形外全程保持RGB888及用户选择的采样方式，稳定大图同样保留外围界面。
- 复用现有缓存与混合器，没有增加BRAM或DSP；原轮播、地图切换仍为原有滑动动画。

仿真、综合及布局布线记录见 `release/验证记录.md`。资源为MSlice {resources['mslice']}/4900、BRAM9K {resources['bram9k']}/64、DSP {resources['dsp']}/29；Max最差余量 {timing['setup_wns_ns']} ns，Min最差余量 {timing['min_wns_ns']} ns。当前版本未声称时序全部收敛或已通过上板验证。

之前版本曾出现启动黑屏，随后重新上电或插拔TF卡后恢复，原因未确定；本次显示效果和时序修改不作为该问题已修复的证据。源码差异、文件哈希及完整测试结果见 `release/source_changes.patch` 和 `release/manifest.json`。
'''
    validation = f'''# 保留详情背景的大图淡化：验证记录

候选 `{candidate.name}`；所选实现 `{run_name}`。已完成以下电脑端验证，板级测试待完成。

## 显示行为与实现

照片矩形为 x=80～719、y=60～539；在原详情画面上直接淡入淡出，完整过渡16帧、约0.27秒。过渡与稳定大图的外围均保留原界面。混合仅在照片矩形内进行，内部以两组RGB565像素共用一个32位FIFO字，并临时采用最近邻底图采样；外围继续RGB888和用户选择的采样方式。稳定画面恢复普通RGB888像素格式。已有局部缓存承担背景暂存，不增加整帧缓存、BRAM或DSP。

读控制器的缓存写入与区域边界判断已拆分时序路径，复位释放和HDMI数据捕获的修改有独立回归。是否满足静态时序以本次实际实现报告为准。

## 功能与供图验证

- 读控制器独立模型：6个完整800×600光栅，共288万像素；普通详情、索引混合、索引大图、地图混合、地图详情及地图大图均通过。每个覆盖帧检查307200个照片位置、172800个外围位置和5584个边界位置；包含双线性外围、槽保护、帧中目标变化、SDRAM返回间断及FIFO连续消费。
- 安路加密SDRAM控制器时序：混合地图与稳定大图各48万像素，包含1024×600跨槽地图、后台写入和刷新。该测试采用控制器命令/返回时序配合已知地址纹理，不等同于板级SDRAM电气验证。
- 原双线性路径：48万像素、1644368周期与参考模型逐拍一致。
- 合成器：{results['compositor'].get('coverage', '详见对应结果文件')}。
- 按键和调度器：打开、返回、中途反向、等待详情加载、轮播暂停及原有交互回归通过。
- 复位与HDMI回归：{results['reset_release'].get('scope', '详见对应结果文件')}。
- 综合与物理实现使用同一份当前源码；读控制器、缓存、合成器及复位测试均核对源码哈希，结果见manifest。

## 资源变化

比较基线为上一版直接交叉淡化seed23。

| 资源 | 上一版已用 | 本版已用 / 容量 | 差值 |
|---|---:|---:|---:|
{resource_rows}

## 静态时序

| 指标 | 上一版seed23 | 本版seed{seed} |
|---|---:|---:|
| Max最差余量/ns | {baseline_timing['setup_wns_ns']} | {timing['setup_wns_ns']} |
| Max负端点 | {baseline_timing['max_negative_endpoints']} | {timing['max_negative_endpoints']} |
| SDRAM接口Max负端点 | {baseline_timing['sdram_max_negative_endpoints']} | {sdram_count} |
| 其他Max负端点 | {baseline_timing['other_max_negative_endpoints']} | {timing['other_max_negative_endpoints']} |
| Min最差余量/ns | {baseline_timing['min_wns_ns']} | {timing['min_wns_ns']} |
| Min负端点 | {baseline_timing['min_negative_endpoints']} | {timing['min_negative_endpoints']} |

{sdram_note} 引脚与时钟约束保持不变，没有新增false path或multicycle来隐藏违例。

| 路径组 | Max最差/ns | Max负端点 | Min最差/ns | Min负端点 |
|---|---:|---:|---:|---:|
{chr(10).join(group_rows)}

Min包含保持时间hold和复位撤销removal，不能统称为保持违例。{type_note}

| 报告中的检查类型 | 负端点数 | 最差余量/ns |
|---|---:|---:|
{type_rows}

各实现的真实结果汇总在 `reports/timing_comparison.json`，其中只有构建完成且源码匹配当前版本的实现标记为complete。功能仿真通过不等于时序违例无影响；仍需要实际硬件验证。

## 文件与后续验证

- 位流SHA-256：`{candidate_hash}`
- 读控制器SHA-256：`{reader_hash}`
- 局部缓存SHA-256：`{cache_hash}`
- 完整时序：`release/overlay_seed{seed}_timing.rpt`
- 资源报告：`release/overlay_seed{seed}_area.rpt`
- 相对上一版源码差异：`release/source_changes.patch`
- 全部证据、哈希和测试来源：`release/manifest.json`

待上板确认索引/地图详情打开大图、淡入淡出及中途返回，四周保留界面，正常缩放与轮播，以及多次冷启动。此前启动黑屏的根因未确认，本次不宣称修复。TF卡图片及配置无需改写。
'''
    # Publication starts only after all checks and document generation succeed.
    RELEASE.mkdir(parents=True, exist_ok=True)
    shutil.copy2(run / 'image_multiview_gui.bit', candidate)
    shutil.copy2(run / 'final_timing.rpt', RELEASE / f'overlay_seed{seed}_timing.rpt')
    shutil.copy2(run / 'image_multiview_gui_phy.area', RELEASE / f'overlay_seed{seed}_area.rpt')
    (RELEASE / 'source_changes.patch').write_text(''.join(patch), encoding='utf-8')
    dumpj(RELEASE / 'manifest.json', manifest)
    dumpj(ROOT / 'reports/timing_comparison.json', comparisons)
    (ROOT / 'README.md').write_text(readme, encoding='utf-8')
    (RELEASE / '验证记录.md').write_text(validation, encoding='utf-8')
    PROJECT.write_text('<?xml version="1.0" encoding="UTF-8"?>\n' + project_text + '\n', encoding='utf-8')
    assert sha(candidate) == candidate_hash
    print(json.dumps({'candidate': str(candidate), 'sha256': candidate_hash, 'physical_run': run_name,
                      'resources': resources, 'max_wns_ns': timing['setup_wns_ns'],
                      'min_wns_ns': timing['min_wns_ns'], 'board_test': 'pending'}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
