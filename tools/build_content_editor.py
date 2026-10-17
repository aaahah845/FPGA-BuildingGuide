"""Build the offline Windows editor; never touch a removable drive or FPGA RTL."""
from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "release" / "content_editor"
REPORTS = ROOT / "reports" / "content_editor" / "pyinstaller"
NAME = "GuideContentEditor"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build() -> Path:
    if sys.platform != "win32":
        raise RuntimeError("请在 Windows 上构建 Windows 便携程序。")
    for output in (DIST / NAME, REPORTS):
        # PyInstaller may replace its previous generated output directory.
        # Reject redirected/symlinked destinations outside this project.
        output.resolve().relative_to(ROOT.resolve())
    entry = ROOT / "scripts" / "site_content_editor.py"
    assets = [
        (ROOT / "config" / "glyph_catalog.json", "config"),
        (ROOT / "config" / "notes_glyph_catalog.json", "config"),
        (ROOT / "config" / "runtime_site.json", "config"),
        (ROOT / "config" / "base_fonts", "config/base_fonts"),
    ]
    for source in [entry, ROOT / "scripts" / "site_editor_smoke.py", *(source for source, _ in assets)]:
        if not source.exists():
            raise FileNotFoundError(source)
    version = importlib.metadata.version("pyinstaller")
    REPORTS.mkdir(parents=True, exist_ok=True)
    DIST.mkdir(parents=True, exist_ok=True)
    command = [
        sys.executable, "-m", "PyInstaller", "--noconfirm", "--clean",
        "--onedir", "--windowed", "--name", NAME,
        "--distpath", str(DIST),
        "--workpath", str(REPORTS / "work"),
        "--specpath", str(REPORTS),
        "--paths", str(ROOT / "scripts"),
        "--hidden-import", "PIL._imagingft",
        "--hidden-import", "fontTools.ttLib",
        "--hidden-import", "site_editor_smoke",
        # TTFont chooses table readers through dynamic imports at runtime.
        "--collect-submodules", "fontTools.ttLib.tables",
    ]
    for source, destination in assets:
        command.extend(["--add-data", f"{source};{destination}"])
    command.append(str(entry))
    log_path = REPORTS / "build.log"
    print(f"正在构建，完整日志：{log_path}", flush=True)
    with log_path.open("w", encoding="utf-8") as log:
        environment = dict(os.environ, PYTHONUTF8="1", PYTHONIOENCODING="utf-8")
        result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, env=environment)
    if result.returncode:
        raise RuntimeError(f"PyInstaller 失败（{result.returncode}），请查看 {log_path}")

    package = DIST / NAME
    executable = package / f"{NAME}.exe"
    if not executable.is_file():
        raise RuntimeError("打包完成但未找到主程序。")
    guide = ROOT / "docs" / "content_editor.md"
    if guide.exists():
        (package / "使用说明.txt").write_text(guide.read_text(encoding="utf-8"), encoding="utf-8-sig")
    files = sorted(path for path in package.rglob("*") if path.is_file())
    source_files = sorted((ROOT / "scripts").glob("*.py"))
    for source, _ in assets:
        source_files.extend([source] if source.is_file() else sorted(p for p in source.rglob("*") if p.is_file()))
    manifest = {
        "built_utc": datetime.now(timezone.utc).isoformat(),
        "python_version": sys.version,
        "pyinstaller_version": version,
        "command": command,
        "executable": str(executable.relative_to(ROOT)),
        "executable_sha256": sha256(executable),
        "package_file_count": len(files),
        "package_size_bytes": sum(p.stat().st_size for p in files),
        "sources_sha256": {str(p.relative_to(ROOT)): sha256(p) for p in source_files},
        "package_sha256": {str(p.relative_to(package)): sha256(p) for p in files},
        "validation_note": "This manifest records packaging only; it is not evidence of GUI or board validation.",
    }
    (REPORTS / "build_manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"程序：{executable}")
    print(f"目录大小：{manifest['package_size_bytes'] / 1024 / 1024:.1f} MiB；共 {len(files)} 个文件")
    print("分发时请复制整个 GuideContentEditor 文件夹，不能只复制 EXE。")
    return executable


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="构建导视内容编辑器 Windows 便携版")
    parser.parse_args()
    build()
