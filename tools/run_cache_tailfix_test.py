from pathlib import Path
import hashlib, json, re, subprocess, time

ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT.parent/'lab_image_photo_overlay_20261015'
OUT=ROOT/'reports/cache_tailfix/simulation'
OUT.mkdir(parents=True,exist_ok=True)
tb=ROOT/'sim/tb_cache_tailfix.v'
results=[]
for name,project in [('baseline',BASE),('fixed',ROOT)]:
    src=project/'src/user_source/hdl_source'
    rtl=src/'SD/sd_site_assets.v'
    digest=hashlib.sha256(rtl.read_bytes()).hexdigest()
    work=OUT/name
    work.mkdir(exist_ok=True)
    commands=['onerror {quit -code 1 -f}', 'onbreak {quit -code 1 -f}',
        'if {![file exists work_cache]} {vlib work_cache}',
        f'vlog -sv -work work_cache +incdir+{src.as_posix()}+{(src/"SD").as_posix()} {{{rtl.as_posix()}}} {{{tb.as_posix()}}}',
        'vsim -c -onfinish stop -voptargs=+acc work_cache.tb_cache_tailfix',
        'run 2 ms',
        'if {[examine /tb_cache_tailfix/finished] != 1} {quit -code 1 -f}',
        'quit -code 0 -f']
    (work/'run.do').write_text('\n'.join(commands)+'\n',encoding='utf-8')
    started=time.time()
    with (work/'simulation.log').open('wb') as log:
        p=subprocess.run(['C:/altera/14.1/modelsim_ase/win32aloem/vsim.exe','-c','-do','run.do'],
            cwd=work,stdout=log,stderr=subprocess.STDOUT,stdin=subprocess.DEVNULL,
            timeout=180,creationflags=subprocess.CREATE_NO_WINDOW)
    text=(work/'simulation.log').read_text(encoding='utf-8',errors='replace')
    marker=re.search(r'PASS: cache tail ownership suite cases=(\d+) checks=(\d+)',text)
    if name=='baseline':
        passed=p.returncode!=0 and 'wrong eviction case=1' in text
    else:
        passed=p.returncode==0 and bool(marker) and not re.search(r'\*\* (Error|Fatal):',text)
    result={'run':name,'pass':bool(passed),'expected_to_fail':name=='baseline',
       'exit_code':p.returncode,'seconds':round(time.time()-started,2),'rtl_sha256':digest,
       'sources_unchanged':digest==hashlib.sha256(rtl.read_bytes()).hexdigest(),
       'test_sha256':hashlib.sha256(tb.read_bytes()).hexdigest(),
       'evidence':[line for line in text.splitlines() if 'PASS' in line or '** Fatal:' in line or '** Error:' in line]}
    if marker: result.update(cases=int(marker[1]),checks=int(marker[2]))
    results.append(result)
    print(json.dumps(result,ensure_ascii=False),flush=True)
    if not passed:
        print('\n'.join(text.splitlines()[-40:]))
        break
summary={'pass':len(results)==2 and all(r['pass'] and r['sources_unchanged'] for r in results),
         'scope':'Real allocator with seeded cache metadata; no SD payload or board timing modeled.',
         'results':results}
(OUT/'results.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8')
raise SystemExit(0 if summary['pass'] else 1)
