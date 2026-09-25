"""Build a release ZIP from the tracked ETB-HostKit files.

The ZIP has a flat root so users can extract it and run 一键安装.bat directly.
"""

from pathlib import Path
from datetime import datetime, timezone
import re
import subprocess
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo


ROOT = Path(__file__).resolve().parents[1]
EXCLUDE = {".gitattributes", ".gitignore"}
EXCLUDE_PREFIXES = ("tests/", "tools/")


def version_in(path: Path, pattern: str) -> str:
    match = re.search(pattern, path.read_text(encoding="utf-8-sig"))
    if not match:
        raise ValueError(f"Missing version in {path}")
    return match.group(1)


def main() -> None:
    panel_version = version_in(
        ROOT / "HostPanel.ps1", r'\$script:PanelVersion\s*=\s*"(\d+\.\d+\.\d+)"'
    )
    mod_version = version_in(
        ROOT / "mods/ETB_HostKit/Scripts/main.lua", r'local MOD_VERSION\s*=\s*"(\d+\.\d+\.\d+)"'
    )
    if panel_version != mod_version:
        raise ValueError(f"Version mismatch: panel {panel_version}, mod {mod_version}")

    paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode("utf-8").split("\0")
    paths = sorted(
        path for path in paths
        if path and path not in EXCLUDE and not path.startswith(EXCLUDE_PREFIXES)
    )
    commit_time = int(subprocess.check_output(["git", "log", "-1", "--format=%ct"], cwd=ROOT))
    zip_time = datetime.fromtimestamp(commit_time, timezone.utc).timetuple()[:6]
    output = ROOT / "dist" / f"ETB-HostKit-{panel_version}.zip"
    output.parent.mkdir(exist_ok=True)
    with ZipFile(output, "w", compression=ZIP_DEFLATED, compresslevel=9) as archive:
        for name in paths:
            source = ROOT / name
            if not source.is_file():
                raise FileNotFoundError(source)
            data = source.read_bytes()
            if name.endswith(".ps1") and not data.startswith(b"\xef\xbb\xbf"):
                raise ValueError(f"PowerShell 5.1 requires UTF-8 BOM: {name}")
            if name.endswith(".bat") and not data.isascii():
                raise ValueError(f"Batch file must be ASCII: {name}")
            info = ZipInfo(name, date_time=zip_time)
            info.compress_type = ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, data, compress_type=ZIP_DEFLATED, compresslevel=9)

    with ZipFile(output) as archive:
        for info in archive.infolist():
            if any(ord(char) > 127 for char in info.filename) and not info.flag_bits & 0x800:
                raise ValueError(f"Filename lacks UTF-8 flag: {info.filename}")
            if archive.read(info) != (ROOT / info.filename).read_bytes():
                raise ValueError(f"Archive verification failed: {info.filename}")
    print(f"{output} ({len(paths)} files, {output.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
