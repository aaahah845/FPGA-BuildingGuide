"""Independent row/latency/write-port regression for startup-loaded fonts.

The frozen .hex fixtures were extracted from the unmodified title-config
project. This test treats each large glyph as a 576-bit stream, independently
of the DUT's row/phase address equations, and checks the compositor routing.
"""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'src/user_source/hdl_source'
FIX = ROOT / 'sim/fixtures/dynamic_fonts'
OUT = ROOT / 'reports/dynamic_text/font_sim'
OUT.mkdir(parents=True, exist_ok=True)

manifest = json.loads((FIX / 'manifest.json').read_text(encoding='utf-8'))
for filename, expected in manifest['fixtures'].items():
    if hashlib.sha256((FIX / filename).read_bytes()).hexdigest() != expected:
        raise RuntimeError('Frozen font fixture changed: ' + filename)
large = [int(v, 16) for v in (FIX / 'large_words.hex').read_text().split()]
notes = [int(v, 16) for v in (FIX / 'notes_words.hex').read_text().split()]
assert len(large) == 4096 and len(notes) == 1536


def write_hex(name, values, width):
    (OUT / name).write_text(''.join(f'{v:0{width}x}\n' for v in values), encoding='ascii')


def rows24(words):
    rows = []
    for glyph in range(128):
        bitstream = 0
        for word in range(32):
            address = glyph * 16 + word // 2 + (2048 if word & 1 else 0)
            bitstream |= words[address] << (18 * word)
        rows.extend([(bitstream >> (24 * row)) & 0xffffff for row in range(24)] + [0] * 8)
    return rows


def rows16(words):
    return words + [0] * (4096 - len(words))


write_hex('initial24.hex', rows24(large), 6)
write_hex('initial16.hex', rows16(notes), 4)
fixed24 = {0, 29, 30, 56, 57, 58, 59}
fixed16 = {0, *range(19, 29)}
# A nonuniform deterministic pattern exercises all 18 bits and row crossings.
loaded_large = [v if ((i % 2048) // 16) in fixed24 else
                ((i * 0x19661) ^ (i << 7) ^ 0x2ac93) & 0x3ffff
                for i, v in enumerate(large)]
loaded_notes = [v if i // 16 in fixed16 else
                ((i * 0x9563) ^ (i << 5) ^ 0xa35c) & 0xffff
                for i, v in enumerate(notes)]
write_hex('load24.hex', loaded_large, 5)
write_hex('load16.hex', loaded_notes, 4)
write_hex('loaded24.hex', rows24(loaded_large), 6)
write_hex('loaded16.hex', rows16(loaded_notes), 4)

tb = ROOT / 'sim/tb_dynamic_fonts.v'
do = OUT / 'dynamic_fonts.do'
do.write_text('\n'.join([
    'onerror {quit -code 1 -f}',
    'onbreak {quit -code 1 -f}',
    f'cd {{{OUT.as_posix()}}}',
    'if {![file exists work_fonts]} {vlib work_fonts}',
    f'vlog -sv -work work_fonts +incdir+{SRC.as_posix()} '
    f'{{{(SRC / "guide_scene_compositor.v").as_posix()}}} {{{tb.as_posix()}}}',
    'vsim -c work_fonts.tb_dynamic_fonts',
    'run -all',
    'quit -f',
]) + '\n', encoding='utf-8')
start = time.time()
with (OUT / 'dynamic_fonts.log').open('wb') as log:
    process = subprocess.run(
        ['C:/altera/14.1/modelsim_ase/win32aloem/vsim.exe', '-c', '-do', str(do)],
        cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
        timeout=300, creationflags=subprocess.CREATE_NO_WINDOW)
log = (OUT / 'dynamic_fonts.log').read_text(encoding='utf-8', errors='replace')
passed = process.returncode == 0 and 'PASS: dynamic font suite' in log and not re.search(r'\*\*\s+(Error|Fatal):', log)
result = {
    'pass': passed, 'exit_code': process.returncode,
    'seconds': round(time.time() - start, 2),
    'candidate_sha256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in [SRC / 'guide_large_font.v', SRC / 'room_notes_font.v', SRC / 'guide_scene_compositor.v']},
    'evidence': [line for line in log.splitlines() if 'PASS:' in line or '** Error' in line or '** Fatal' in line],
    'scope': 'Independent dual-clock font RAM and actual compositor write routing; no SD loader, synthesis or board test.',
}
(OUT / 'results.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps(result, ensure_ascii=False, indent=2))
if not passed:
    print('\n'.join(log.splitlines()[-60:]))
raise SystemExit(0 if passed else 1)
