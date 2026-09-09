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
for name in ("index.html", "docs/naming-demo/index.html", "specs/protocol/spec/index.html", "docs/naming-demo.speech.json", "docs/building/index.html", "docs/building.speech.json", "assets/mermaid.min.js"):
    local = (source / name).read_bytes()
    remote = urlopen(base + name).read()
    assert local == remote, f"published bytes differ: {name}"
    verified[name] = hashlib.sha256(remote).hexdigest()
print(json.dumps({"candidate": revision, "url": base, "sha256": verified}, indent=2))
