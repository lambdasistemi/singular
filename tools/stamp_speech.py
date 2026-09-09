#!/usr/bin/env python3
"""Bind a curated speech companion to the exact page it was written from.

Usage: stamp_speech.py PAGE.md [PAGE.md ...]   (a directory stamps every .md under it)

Writes `_source: {sha256, file}` into PAGE.speech.json. Run it only after the
speech has been redone for the page's current text: the stamp is the author's
statement that the two match, and check_presentation.py rejects any page whose
hash no longer equals its stamp.
"""
import hashlib
import json
import sys
from pathlib import Path

paths = []
for a in sys.argv[1:]:
    p = Path(a)
    paths.extend(sorted(p.rglob("*.md")) if p.is_dir() else [p])
if not paths:
    sys.exit(__doc__)
for md in paths:
    speech = md.with_suffix(".speech.json")
    if not speech.exists():
        sys.exit(f"{speech}: missing — write the speech first, then stamp")
    data = json.loads(speech.read_text(encoding="utf-8"))
    data["_source"] = {"file": md.name, "sha256": hashlib.sha256(md.read_bytes()).hexdigest()}
    speech.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"stamped {speech} <- {md.name} {data['_source']['sha256'][:12]}")
