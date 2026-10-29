"""Verify the published candidate and meaningful bytes against the local build."""

from pathlib import Path
import hashlib
import json
import sys
from urllib.request import urlopen

base, source, expected = sys.argv[1:]
source = Path(source)
revision = urlopen(base + "candidate.txt").read().decode().strip()
assert revision == expected, (revision, expected)
verified = {}
names = [
    "index.html",
    "specs/protocol/spec/index.html",
    "docs/building/index.html",
    "docs/building.speech.json",
    "assets/mermaid.min.js",
    "docs/decisions/index.html",
    "docs/first-demo/index.html",
    "css/asciinema-player.css",
    "js/asciinema-player.min.js",
    "artifacts/SHA256SUMS",
]
for directory in ("model", "artifacts/lean"):
    names.extend(
        str(path.relative_to(source))
        for path in sorted((source / directory).rglob("*"))
        if path.is_file()
        and path.suffix in {".lean", ".json", ".js", ".mjs", ".css", ".html"}
    )
assert any(name.endswith("Model.lean") for name in names), "no published Lean source"
for name in names:
    local = (source / name).read_bytes()
    remote = urlopen(base + name).read()
    assert local == remote, f"published bytes differ: {name}"
    verified[name] = hashlib.sha256(remote).hexdigest()
print(json.dumps({"candidate": revision, "url": base, "sha256": verified}, indent=2))
