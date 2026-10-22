"""Portable entry points for package checks, TD builds and allocator simulation."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import time
import wave
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'src/user_source/hdl_source'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def work_dir(name):
    path = ROOT / '.repro_work' / (name + '_' + time.strftime('%Y%m%d_%H%M%S'))
    path.mkdir(parents=True, exist_ok=False)
    return path


def command(args, cwd, log, timeout=3600):
    started = time.time()
    with log.open('wb') as stream:
        result = subprocess.run(args, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT,
                                stdin=subprocess.DEVNULL, timeout=timeout,
                                creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
    output = log.read_text(encoding='utf-8', errors='replace')
    if result.returncode:
        print(output[-6000:])
        raise RuntimeError(f'Command failed ({result.returncode}); log: {log}')
    return output, round(time.time() - started, 2)


def check():
    manifest = ROOT / 'SHA256SUMS.txt'
    if not manifest.is_file():
        raise RuntimeError('SHA256SUMS.txt is missing; use the complete distribution.')
    hashes = {}
    for line in manifest.read_text(encoding='utf-8-sig').splitlines():
        digest, relative = line.split('  ', 1)
        path = ROOT / relative
        if not path.is_file() or sha(path) != digest:
            raise RuntimeError(f'Missing or changed file: {relative}')
        hashes[relative] = digest
    project = ROOT / 'src/td_project/image_multiview_gui.al'
    xml = ET.fromstring(project.read_text(encoding='utf-8').replace('P&R', 'P&amp;R'))
    references = [node.attrib['Path'] for node in xml.findall('.//File')]
    for relative in references:
        if not (project.parent / relative).is_file():
            raise RuntimeError(f'Missing TD reference: {relative}')
    includes = 0
    for source in (ROOT / 'src/user_source').rglob('*'):
        if source.is_file() and source.suffix.lower() in ('.v', '.vh', '.sv') and not source.name.endswith('.enc.v'):
            for name in re.findall(r'^\s*`include\s+"([^"]+)"', source.read_text(encoding='utf-8-sig', errors='replace'), re.M):
                if not any(p.is_file() for p in (source.parent/name, project.parent/name, SRC/name, SRC/'SD'/name)):
                    raise RuntimeError(f'Missing include: {source.name}: {name}')
                includes += 1
    cfg = (ROOT / 'TF_CARD/SITE.CFG').read_bytes()
    if len(cfg) != 27648 or cfg[:5] != b'SGC1\x06':
        raise RuntimeError('SITE.CFG must be a 27648-byte V6 file.')
    if struct.unpack_from('<H', cfg, 8190)[0] != sum(cfg[:8190]) & 65535:
        raise RuntimeError('SITE.CFG header checksum failed.')
    if struct.unpack_from('<H', cfg, 24)[0] != sum(cfg[8192:]) & 65535:
        raise RuntimeError('SITE.CFG font checksum failed.')
    if cfg != (ROOT / 'config/sd_card/SITE.CFG').read_bytes():
        raise RuntimeError('TF card and project SITE.CFG differ.')
    config = json.loads((ROOT / 'config/runtime_site.json').read_text(encoding='utf-8-sig'))
    if cfg[9] != len(config['images']) or cfg[8] != len(config['floors']):
        raise RuntimeError('Configuration resource/floor counts differ.')
    sizes = {}
    for index, name in enumerate(config['images']):
        record = cfg[6144+12*index:6144+12*index+11]
        short = record[:8].decode('ascii').rstrip() + '.' + record[8:].decode('ascii')
        if short != name.upper():
            raise RuntimeError(f'Image index mismatch: {index}')
        path = ROOT / 'TF_CARD' / name.upper()
        data = path.read_bytes()
        if data[:2] != b'BM' or struct.unpack_from('<H',data,28)[0] != 24 or struct.unpack_from('<I',data,30)[0] != 0:
            raise RuntimeError(f'Expected uncompressed 24-bit BMP: {name}')
        width, height = struct.unpack_from('<ii', data, 18)
        offset = struct.unpack_from('<I', data, 10)[0]
        if width <= 0 or height == 0 or len(data) < offset + ((width*3+3)&~3)*abs(height):
            raise RuntimeError(f'Invalid BMP geometry/payload: {name}')
        sizes[index] = (width, abs(height))
    for floor in config['floors']:
        width, height = sizes[floor['map_image']]
        for room in floor['rooms']:
            x, y = room['point']
            if not (0 <= x < width and 0 <= y < height):
                raise RuntimeError(f'Observation point outside its map: {room["name"]}')
            for field in ('photo_image','point_photo_image'):
                if sizes[room[field]] != (640,480):
                    raise RuntimeError(f'Photo geometry mismatch: {room["name"]}/{field}')
    audio = sorted((ROOT/'TF_CARD').glob('*.WAV'))
    for path in audio:
        data = path.read_bytes()
        if data[:4] != b'RIFF' or data[8:12] != b'WAVE' or data[12:16] != b'fmt ' or data[36:40] != b'data':
            raise RuntimeError(f'WAV must use the canonical 44-byte header: {path.name}')
        if struct.unpack_from('<IHHI', data, 16) != (16,1,1,48000):
            raise RuntimeError(f'WAV format mismatch: {path.name}')
        with wave.open(str(path), 'rb') as stream:
            if (stream.getnchannels(),stream.getsampwidth(),stream.getframerate()) != (1,2,48000):
                raise RuntimeError(f'WAV sample format mismatch: {path.name}')
    return {'pass': True, 'hashed_files': len(hashes), 'project_references': len(references),
            'include_references': includes, 'bmp_files': len(sizes), 'wav_files': len(audio),
            'site_cfg_version': 6, 'point_coordinates_in_maps': True}


def export_check():
    sys.path.insert(0, str(ROOT/'scripts'))
    import export_site_cfg
    config = json.loads((ROOT/'config/runtime_site.json').read_text(encoding='utf-8-sig'))
    data = export_site_cfg.export(config)
    work = work_dir('export')
    destination = work/'SITE.CFG'
    destination.write_bytes(data)
    equal = data == (ROOT/'TF_CARD/SITE.CFG').read_bytes()
    if not equal:
        raise RuntimeError(f'Re-export differs (check font and package versions): {destination}')
    return {'pass': True, 'cfg_reexport_byte_identical': True, 'output': str(destination)}


def td_operation(root, build):
    executable = Path(root).resolve()/'bin/td_commands_prompt.exe'
    if not executable.is_file():
        raise RuntimeError(f'TD executable not found: {executable}')
    work = work_dir('build' if build else 'td_check')
    shutil.copytree(ROOT/'src', work/'src')
    script = work/'run.tcl'
    body = ['set work [file dirname [file normalize [info script]]]',
            'cd [file join $work src td_project]',
            'if {[catch {', '    open_project image_multiview_gui.al -noanalyze']
    if build:
        # Export the selected project's own strategies. Running these scripts
        # directly avoids TD 6.2.1 CLI launch_runs generating a doubled exe name.
        body += ['    import_device eagle_s20.db -package EG4S20BG256',
                 '    export_flow_script -run syn_1 -file flow_syn.tcl',
                 '    export_flow_script -run phy_seed61 -file flow_phy.tcl']
    body += ['} message]} { puts "REPRO_TD_FAILED: $message"; exit 1 }',
             'puts "REPRO_TD_OK"', 'exit 0']
    script.write_text('\n'.join(body)+'\n', encoding='utf-8')
    print(f'TD log: {work / "td.log"}', flush=True)
    output, seconds = command([str(executable),script.as_posix()], work, work/'td.log')
    if 'REPRO_TD_OK' not in output or 'REPRO_TD_FAILED' in output:
        print(output[-6000:])
        raise RuntimeError('TD did not report completion.')
    result = {'pass': True, 'operation': 'build' if build else 'td_check', 'seconds': seconds,
              'log': str(work/'td.log')}
    if build:
        project_dir = work/'src/td_project'
        for stage in ('syn','phy'):
            flow = project_dir/f'flow_{stage}.tcl'
            if not flow.is_file():
                raise RuntimeError(f'TD did not export {flow.name}')
            if stage == 'phy':
                # Both exported flows execute in the copied project directory.
                # The gate database is there, rather than in a GUI *_Runs tree.
                content = flow.read_text(encoding='utf-8')
                content, count = re.subn(r'(?m)^set parent .*$', 'set parent .', content)
                if count != 1:
                    raise RuntimeError('Unexpected exported physical-flow layout.')
                content, count = re.subn(r'(?m)^set start_step .*$', 'set start_step opt_place', content)
                if count != 1:
                    raise RuntimeError('Missing physical start step.')
                flow.write_text(content, encoding='utf-8')
            runner = project_dir/f'run_{stage}.tcl'
            runner.write_text('if {[catch {source flow_' + stage + '.tcl} message]} {\n'
                              '    puts "REPRO_STAGE_FAILED: $message"; exit 1\n}\n'
                              'puts "REPRO_STAGE_OK"\nexit 0\n',encoding='utf-8')
            print(f'TD {stage} log: {work / (stage + ".log")}', flush=True)
            output, elapsed = command([str(executable),runner.as_posix()],project_dir,work/(stage+'.log'))
            if 'REPRO_STAGE_OK' not in output or 'REPRO_STAGE_FAILED' in output:
                print(output[-6000:])
                raise RuntimeError(f'TD {stage} flow failed.')
            result[stage+'_seconds'] = elapsed
            result['seconds'] = round(result['seconds'] + elapsed, 2)
        bit = project_dir/'image_multiview_gui.bit'
        if not bit.is_file():
            raise RuntimeError('Build finished without a bitstream.')
        result.update(bitstream=str(bit), sha256=sha(bit))
    (work/'result.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    return result


def cache_test(vsim):
    executable = Path(vsim).resolve() if vsim else shutil.which('vsim')
    if not executable or not Path(executable).is_file():
        raise RuntimeError('Specify --vsim with the ModelSim/Questa vsim executable.')
    work = work_dir('cache_test')
    sources = work/'hdl_source'
    shutil.copytree(SRC, sources)
    shutil.copy2(ROOT/'sim/tb_cache_tailfix.v',work/'tb_cache_tailfix.v')
    # Relative paths keep spaces and non-ASCII checkout locations out of +incdir.
    script = '\n'.join(['onerror {quit -code 1 -f}', 'onbreak {quit -code 1 -f}',
        'vlib work_cache', 'vlog -sv -work work_cache +incdir+hdl_source+hdl_source/SD hdl_source/SD/sd_site_assets.v tb_cache_tailfix.v',
        'vsim -c -onfinish stop -voptargs=+acc work_cache.tb_cache_tailfix', 'run 2 ms',
        'if {[examine /tb_cache_tailfix/finished] != 1} {quit -code 1 -f}', 'quit -code 0 -f'])
    (work/'run.do').write_text(script+'\n',encoding='utf-8')
    output, seconds = command([str(executable),'-c','-do','run.do'],work,work/'simulation.log',180)
    marker = re.search(r'PASS: cache tail ownership suite cases=(\d+) checks=(\d+)', output)
    if not marker or re.search(r'\*\*\s+(Error|Fatal):',output):
        print(output[-6000:])
        raise RuntimeError(f'Cache regression failed: {work}')
    return {'pass': True, 'cases': int(marker[1]), 'checks': int(marker[2]),
            'seconds': seconds, 'log': str(work/'simulation.log')}


def layout_test(vsim):
    executable = Path(vsim).resolve() if vsim else shutil.which('vsim')
    if not executable or not Path(executable).is_file():
        raise RuntimeError('Specify --vsim with the simulator executable.')
    work = work_dir('layout_test')
    shutil.copytree(SRC,work/'hdl_source')
    shutil.copy2(ROOT/'sim/tb_layout_fade.v',work/'tb_layout_fade.v')
    script = '\n'.join(['onerror {quit -code 1 -f}','onbreak {quit -code 1 -f}',
        'vlib work_layout','vlog -sv -work work_layout +incdir+hdl_source hdl_source/site_scene_broker.v tb_layout_fade.v',
        'vsim -c -onfinish exit work_layout.tb_layout_fade','run -all','quit -code 0 -f'])
    (work/'run.do').write_text(script+'\n',encoding='utf-8')
    output, seconds = command([str(executable),'-c','-do','run.do'],work,work/'simulation.log',180)
    if 'PASS: layout waits' not in output or re.search(r'\*\*\s+(Error|Fatal):',output):
        raise RuntimeError(f'Layout regression failed: {work}')
    return {'pass':True,'seconds':seconds,'log':str(work/'simulation.log')}


def native_test(vsim):
    executable = Path(vsim).resolve() if vsim else shutil.which('vsim')
    if not executable or not Path(executable).is_file():
        raise RuntimeError('Specify --vsim with the simulator executable.')
    work = work_dir('native_test')
    shutil.copytree(SRC,work/'hdl_source')
    shutil.copy2(ROOT/'sim/tb_carousel_native_compositor.v',work/'tb_carousel_native_compositor.v')
    packet=(ROOT/'TF_CARD/SITE.CFG').read_bytes()
    (work/'config.hex').write_text(''.join(f'{b:02x}\n' for b in packet[:8192]),encoding='ascii')
    words=[int.from_bytes(packet[i:i+4],'little') for i in range(8192,24576,4)]
    words += [int.from_bytes(packet[i:i+2],'little') for i in range(24576,27648,2)]
    (work/'fonts.hex').write_text(''.join(f'{v:05x}\n' for v in words),encoding='ascii')
    script='\n'.join(['onerror {quit -code 1 -f}','onbreak {quit -code 1 -f}',
        'vlib work_native','vlog -sv -work work_native +incdir+hdl_source hdl_source/guide_scene_compositor.v tb_carousel_native_compositor.v',
        'vsim -c -onfinish exit work_native.tb_carousel_native_compositor','run -all','quit -code 0 -f'])
    (work/'run.do').write_text(script+'\n',encoding='utf-8')
    output,seconds=command([str(executable),'-c','-do','run.do'],work,work/'simulation.log',300)
    if 'PASS: header/footer remain visible' not in output or re.search(r'\*\*\s+(Error|Fatal):',output):
        raise RuntimeError(f'Native compositor regression failed: {work}')
    return {'pass':True,'seconds':seconds,'log':str(work/'simulation.log')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=['check','export-check','td-check','build','cache-test','layout-test','native-test'])
    parser.add_argument('--td-root',type=Path,help='Tang Dynasty installation directory')
    parser.add_argument('--vsim',type=Path,help='ModelSim/Questa vsim executable')
    args = parser.parse_args()
    if args.action in ('build','td-check') and args.td_root is None:
        parser.error('--td-root is required for TD operations')
    if args.action == 'check': result = check()
    elif args.action == 'export-check': result = export_check()
    elif args.action == 'cache-test': result = cache_test(args.vsim)
    elif args.action == 'layout-test': result = layout_test(args.vsim)
    elif args.action == 'native-test': result = native_test(args.vsim)
    else: result = td_operation(args.td_root, args.action == 'build')
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError,OSError,ValueError,subprocess.TimeoutExpired) as error:
        print(f'FAILED: {error}', file=sys.stderr)
        raise SystemExit(1)
