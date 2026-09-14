"""Exercise the real publisher with isolated git/gh doubles; never contact GitHub."""
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile

publisher = Path(sys.argv[1]).resolve()
source = publisher.parent.parent
version = json.loads((source / ".release-please-manifest.json").read_text())["."]
changelog = (source / "CHANGELOG.md").read_text()
section = re.search(
    rf"^## \[{re.escape(version)}\](?:[^\n]*)\n(.*?)(?=^## |\Z)",
    changelog, re.MULTILINE | re.DOTALL,
)
assert section and section.group(1).strip(), f"missing or empty changelog section for {version}"
stable = (source / "onchain-release/RELEASE.md").read_text()
for phrase in ("epic", "E18", "obligation", "milestone artifact"):
    assert phrase.casefold() not in stable.casefold(), f"release text contains forbidden wording: {phrase}"
sha = "a" * 40
mock = '''#!PYTHON
import json, os, pathlib, shutil, sys
args=sys.argv[1:]
if pathlib.Path(sys.argv[0]).name == "git":
    if args[0] == "rev-parse": print(os.environ["TEST_SHA"])
    sys.exit(0)
log=pathlib.Path(os.environ["TEST_LOG"])
with log.open("a") as f: f.write(json.dumps(args)+"\\n")
if args[:2] == ["pr", "list"]:
    assert args[args.index("--base")+1] == "main"
    print(json.dumps([{"number":42,"mergeCommit":{"oid":os.environ.get("TEST_PR_SHA",os.environ["TEST_SHA"])},"headRefName":"release-please--branches--main","labels":[{"name":"autorelease: tagged" if os.environ.get("EXISTING") else "autorelease: pending"}]}]))
elif args[:2] == ["release", "view"]:
    sys.exit(0 if os.environ.get("EXISTING") else 1)
elif args[:2] == ["release", "create"]:
    notes=pathlib.Path(args[args.index("--notes-file")+1]).read_text()
    pathlib.Path(os.environ["TEST_NOTES"]).write_text(notes)
elif args[:2] == ["release", "download"]:
    dest=pathlib.Path(args[args.index("--dir")+1])
    for file in pathlib.Path(os.environ["DOCS_ARCHIVE"]).iterdir(): shutil.copy(file,dest/file.name)
    if os.environ.get("CORRUPT"): (dest/"SHA256SUMS").write_text("corrupt")
'''.replace("PYTHON", sys.executable)

cases = [
    ("wrong-tag", "v999.0.0", {}, False),
    ("wrong-commit", f"v{version}", {"TEST_SHA": "b" * 40}, False),
    ("wrong-release-pr", f"v{version}", {"TEST_PR_SHA": "b" * 40}, False),
    ("corrupt-upload", f"v{version}", {"CORRUPT": "1"}, False),
    ("missing-section", f"v{version}", {}, False),
    ("empty-section", f"v{version}", {}, False),
    ("missing-changelog", f"v{version}", {}, False),
    ("section-at-eof", f"v{version}", {}, True),
    ("notes-override", f"v{version}", {}, True),
    ("new-release", f"v{version}", {}, True),
    ("already-published", f"v{version}", {"EXISTING": "1"}, True),
]
results = []
for name, tag, extra, success in cases:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "bin").mkdir()
        for tool in ("git", "gh"):
            file = root / "bin" / tool
            file.write_text(mock)
            file.chmod(0o755)
        archive = root / "archive"
        archive.mkdir()
        filename = f"singular-docs-{version}.tar.gz"
        payload = b"publisher boundary fixture"
        (archive / filename).write_bytes(payload)
        (archive / "SHA256SUMS").write_text(hashlib.sha256(payload).hexdigest()+"  "+filename+"\n")
        (root / ".release-please-manifest.json").write_text(json.dumps({".": version}))
        fixture_section = f"## [{version}](https://example.org/compare) (2026-09-14)\n\n### Fixes\n\n* Keep this version's changes.\n"
        fixture = "# Changelog\n\n## [999.0.0]\n\n* Newer release.\n\n" + fixture_section + "\n## [0.0.0]\n\n* Older release.\n"
        expected_section = fixture_section
        if name == "new-release":
            fixture, expected_section = changelog, section.group(0)
        elif name == "missing-section":
            fixture = fixture.replace(f"## [{version}]", f"## [{version}0]")
        elif name == "empty-section":
            fixture = f"## [{version}]\n\n## [0.0.0]\n\n* Older release.\n"
        elif name == "section-at-eof":
            fixture = fixture_section.rstrip("\n")
        if name != "missing-changelog":
            (root / "CHANGELOG.md").write_text(fixture)
        (root / "onchain-release").mkdir()
        (root / "onchain-release/RELEASE.md").write_text(stable)
        log = root / "calls.jsonl"
        env = {k: v for k, v in os.environ.items() if k not in ("GH_TOKEN", "GITHUB_TOKEN", "RELEASE_NOTES", "EXISTING", "CORRUPT", "TEST_PR_SHA")}
        env.update(PATH=str(root / "bin")+os.pathsep+env["PATH"], TEST_SHA=sha, TEST_LOG=str(log), DOCS_ARCHIVE=str(archive), DOCS_VERSION=version, TEST_NOTES=str(root / "notes.md"))
        if name == "notes-override":
            override = root / "override.md"
            override.write_text("Stable notes from the packaged source.\n")
            env["RELEASE_NOTES"] = str(override)
        env.update(extra)
        result = subprocess.run(["bash", "-euo", "pipefail", str(publisher), tag, sha], cwd=root, env=env, capture_output=True, text=True)
        calls = [json.loads(x) for x in log.read_text().splitlines()] if log.exists() else []
        assert (result.returncode == 0) == success, (name, result.stderr)
        labels = [x for x in calls if x[:2] == ["pr", "edit"]]
        assert bool(labels) == success, (name, "relabel happened before verification")
        if name.startswith(("wrong", "missing", "empty")):
            assert not any(x[:2] in (["release", "create"], ["release", "upload"]) for x in calls), name
        if name == "already-published":
            assert not any(x[:2] == ["release", "create"] for x in calls)
        if name in ("missing-section", "empty-section"):
            assert f"missing or empty CHANGELOG.md section for {version}" in result.stderr, (name, result.stderr)
        if success and name != "already-published":
            expected_stable = override.read_text() if name == "notes-override" else stable
            assert (root / "notes.md").read_text().rstrip() == (expected_section.rstrip() + "\n\n" + expected_stable).rstrip(), (name, "release body differs from version changes followed by stable notes")
        results.append({"case": name, "exit": result.returncode, "relabel": bool(labels)})
print(json.dumps({"publisherBoundaryChecks": results, "externalCalls": False}))
