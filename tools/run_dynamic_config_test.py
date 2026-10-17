"""Exercise the real V6 configuration/font loader at its file-reader boundary."""
from pathlib import Path
import hashlib
import json
import re
import struct
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'src/user_source/hdl_source'
OUT = ROOT / 'reports/dynamic_text/config_simulation'
OUT.mkdir(parents=True, exist_ok=True)
source = ROOT / 'config/sd_card/SITE.CFG'
original = bytearray(source.read_bytes())
if len(original) != 27648 or original[4] != 6:
    raise SystemExit('Generate config/sd_card/SITE.CFG with the V6 exporter first.')


def checksum(packet):
    struct.pack_into('<H', packet, 24, sum(packet[8192:]) & 0xffff)
    struct.pack_into('<H', packet, 8190, sum(packet[:8190]) & 0xffff)


def write_hex(name, packet):
    (OUT / f'package_{name}.hex').write_text(
        ''.join(f'{value:02x}\n' for value in packet), encoding='ascii')


assert int.from_bytes(original[24:26], 'little') == sum(original[8192:]) & 0xffff
assert int.from_bytes(original[8190:8192], 'little') == sum(original[:8190]) & 0xffff
write_hex('real', original)
warm = original.copy()
# Every valid word changes, including unused glyph slots. This detects stale
# storage across warm reset and tests all 18 data bits of the large-font path.
for word in range(4096):
    offset = 8192 + word * 4
    struct.pack_into('<I', warm, offset,
                     int.from_bytes(original[offset:offset + 4], 'little') ^ 0x3ffff)
for word in range(1536):
    offset = 24576 + word * 2
    struct.pack_into('<H', warm, offset,
                     int.from_bytes(original[offset:offset + 2], 'little') ^ 0xffff)
checksum(warm)
write_hex('warm', warm)

bad = original.copy()
bad[8192 + 53 * 4] ^= 1
write_hex('bad_payload_sum', bad)
bad = original.copy()
bad[8192 + 61 * 4 + 2] |= 0x80
checksum(bad)  # Deliberately valid checksums: only padding validation catches it.
write_hex('bad_padding', bad)
bad = original.copy()
bad[4] = 5
checksum(bad)
write_hex('old_version', bad)
bad = original.copy()
bad[2048] = 96
checksum(bad)
write_hex('bad_notes_id', bad)
bad = original.copy()
bad[8190] ^= 1
write_hex('bad_header_sum', bad)
bad = original.copy()
bad[26] = 2
checksum(bad)
write_hex('bad_format', bad)

files = [SRC / 'SD' / filename for filename in (
    'spi_master.v', 'sd_card_cmd.v', 'sd_card_sec_read_write.v',
    'sd_card_top.v', 'sd_site_assets.v')]
files.append(ROOT / 'sim/tb_dynamic_config.v')
script = '\n'.join([
    'onerror {quit -code 1 -f}', 'onbreak {quit -code 1 -f}',
    f'cd {{{OUT.as_posix()}}}',
    'if {![file exists work_cfg]} {vlib work_cfg}',
    'vlog -sv -work work_cfg '
    f'+incdir+{SRC.as_posix()}+{(SRC / "SD").as_posix()} '
    + ' '.join('{' + path.as_posix() + '}' for path in files),
    'vsim -c work_cfg.tb_dynamic_config', 'run -all', 'quit -f',
]) + '\n'
(OUT / 'dynamic_config.do').write_text(script, encoding='utf-8')
start = time.time()
with (OUT / 'dynamic_config.log').open('wb') as log:
    proc = subprocess.run(
        ['C:/altera/14.1/modelsim_ase/win32aloem/vsim.exe', '-c', '-do',
         str(OUT / 'dynamic_config.do')], cwd=ROOT,
        stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
        timeout=300, creationflags=subprocess.CREATE_NO_WINDOW)
log = (OUT / 'dynamic_config.log').read_text(encoding='utf-8', errors='replace')
passed = (proc.returncode == 0 and 'PASS: dynamic config suite;' in log
          and not re.search(r'\*\*\s+(Error|Fatal):', log))
result = {
    'pass': passed, 'exit_code': proc.returncode,
    'seconds': round(time.time() - start, 2),
    'source_cfg_sha256': hashlib.sha256(original).hexdigest(),
    'rtl_sha256': hashlib.sha256((SRC / 'SD/sd_site_assets.v').read_bytes()).hexdigest(),
    'evidence': [line for line in log.splitlines()
                 if 'PASS:' in line or '** Error' in line or '** Fatal' in line],
    'scope': 'Real sd_site_assets FSM and config RAM; forced filesystem outputs. '
             'Checks all 5632 font words, 54 sectors, intermittent valid, all 8192 '
             'config video-read bytes, warm reset, invalid packages, and mid-read '
             'filesystem error without file_end. '
             'Does not simulate FAT/SPI electrical behavior or physical board.'}
(OUT / 'results.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps(result, ensure_ascii=False, indent=2))
if not passed:
    print('\n'.join(log.splitlines()[-70:]))
raise SystemExit(0 if passed else 1)
