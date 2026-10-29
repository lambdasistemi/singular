"""Attach retained model sources and their checksums to the rendered site."""

import hashlib
from pathlib import Path
import shutil
import sys

root = Path(__file__).resolve().parent.parent
site = Path(sys.argv[1]).resolve()
artifacts = site / "artifacts"
artifacts.mkdir()
shutil.copytree(
    root / "lean",
    artifacts / "lean",
    ignore=shutil.ignore_patterns(
        ".lake", "__pycache__", "*.olean", "*.ilean", "*.c", "*.o"
    ),
)
manifest = {
    str(path.relative_to(site)): hashlib.sha256(path.read_bytes()).hexdigest()
    for path in sorted(artifacts.rglob("*"))
    if path.is_file()
}
(artifacts / "SHA256SUMS").write_text(
    "\n".join(f"{manifest[path]}  {path}" for path in sorted(manifest)) + "\n"
)
