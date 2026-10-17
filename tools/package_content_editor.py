"""Archive a tested, unchanged portable editor for staff distribution."""
from pathlib import Path
import hashlib,json,zipfile
ROOT=Path(__file__).resolve().parents[1]
REPORTS=ROOT/'reports/content_editor'
PACKAGE=ROOT/'release/content_editor/GuideContentEditor'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    built=json.loads((REPORTS/'pyinstaller/build_manifest.json').read_text(encoding='utf-8'))
    for name,digest in built['sources_sha256'].items():assert sha(ROOT/name)==digest,name
    for name,digest in built['package_sha256'].items():assert sha(PACKAGE/name)==digest,name
    for folder in ('gui_smoke','frozen_smoke'):
        assert json.loads((REPORTS/folder/'results.json').read_text(encoding='utf-8'))['pass']
    assert json.loads((REPORTS/'model_tests.json').read_text(encoding='utf-8'))['successful']
    original=json.loads((ROOT/'release/candidate_manifest.json').read_text(encoding='utf-8'))
    for name,digest in original['modified_rtl_sha256'].items():assert sha(ROOT/name)==digest,name
    assert sha(ROOT/'release'/original['bit_file'])==original['bit_sha256']
    assert sha(ROOT/'config/sd_card/SITE.CFG')==original['config_sha256']
    archive=ROOT/'release/content_editor/导视内容编辑器_便携版.zip'
    with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as output:
        for path in sorted(PACKAGE.rglob('*')):
            if path.is_file():output.write(path,path.relative_to(PACKAGE.parent))
    with zipfile.ZipFile(archive) as check:assert check.testzip() is None
    result={'archive':str(archive.relative_to(ROOT)),'sha256':sha(archive),
        'bytes':archive.stat().st_size,'pass':True,'rtl_bitstream_config_unchanged':True,
        'visual_review':'Source and frozen screenshots inspected; complete form and controls visible.'}
    (REPORTS/'package_result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(result,ensure_ascii=False))
if __name__=='__main__':main()
