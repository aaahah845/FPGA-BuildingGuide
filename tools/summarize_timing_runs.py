from pathlib import Path
import json, re

ROOT = Path(__file__).resolve().parents[1]

def summarize(run):
    p = run / 'final_timing.rpt'
    if not p.exists():
        return {'run': run.name, 'complete': False}
    report = p.read_text(encoding='utf-8')
    groups = []
    for part in report.split('Path Group     :')[1:]:
        name = part.splitlines()[0].strip()
        entry = {'group': name}
        for label in ('Max', 'Min'):
            m = re.search(r'^' + label + r'\s*: [SH]WNS\s+(-?[\d.]+)ns, [SH]TNS\s+(-?[\d.]+)ns,\s+(\d+) Viol Endpoints', part, re.M)
            if m:
                entry[label] = {'wns_ns': float(m[1]), 'tns_ns': float(m[2]), 'negative_endpoints': int(m[3])}
        groups.append(entry)
    negatives = []
    for m in re.finditer(r'Slack\s*:\s*(-[\d.]+)ns\s*\nBegin Point\s*:\s*([^\n]+)\nEnd Point\s*:\s*([^\n]+)\nCheck Type\s*:\s*(\w+)', report):
        negatives.append({'slack_ns': float(m[1]), 'begin': m[2], 'end': m[3], 'type': m[4]})
    area = (run / 'image_multiview_gui_phy.area').read_text(encoding='utf-8')
    resources = {}
    for name in ('lut', 'reg', 'bram9k', 'dsp'):
        m = re.search(r'^\s*#' + name + r'\s+(\d+)', area, re.M)
        resources[name] = int(m[1])
    logs = sorted(run.glob('td_*.log'), key=lambda p: p.stat().st_mtime)
    if logs:
        matches = re.findall(r'(\d+) mslices', logs[-1].read_text(encoding='utf-8', errors='replace'))
        if matches:
            resources['mslice'] = int(matches[-1])
    return {'run': run.name, 'complete': True, 'resources': resources, 'groups': groups, 'negative_paths_reported': negatives}

if __name__ == '__main__':
    runs = [summarize(p) for p in sorted((ROOT / 'src/td_project/image_multiview_gui_Runs').glob('phy_seed*'))]
    out = ROOT / 'reports/timing_comparison.json'
    out.write_text(json.dumps(runs, ensure_ascii=False, indent=2), encoding='utf-8')
    for item in runs:
        print(json.dumps({k: v for k, v in item.items() if k != 'negative_paths_reported'}, ensure_ascii=False))
