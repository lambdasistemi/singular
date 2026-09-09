"""Exercise the real publisher with isolated git/gh doubles; never contact GitHub."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

publisher = Path(sys.argv[1]).resolve()
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
elif args[:2] == ["release", "download"]:
    dest=pathlib.Path(args[args.index("--dir")+1])
    for file in pathlib.Path(os.environ["DOCS_ARCHIVE"]).iterdir(): shutil.copy(file,dest/file.name)
    if os.environ.get("CORRUPT"): (dest/"SHA256SUMS").write_text("corrupt")
'''.replace("PYTHON", sys.executable)

cases = [
    ("wrong-tag", "v0.2.0", {}, False),
    ("wrong-commit", "v0.1.0", {"TEST_SHA": "b" * 40}, False),
    ("wrong-release-pr", "v0.1.0", {"TEST_PR_SHA": "b" * 40}, False),
    ("corrupt-upload", "v0.1.0", {"CORRUPT": "1"}, False),
    ("new-release", "v0.1.0", {}, True),
    ("already-published", "v0.1.0", {"EXISTING": "1"}, True),
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
        filename = "singular-docs-0.1.0.tar.gz"
        payload = b"publisher boundary fixture"
        (archive / filename).write_bytes(payload)
        (archive / "SHA256SUMS").write_text(hashlib.sha256(payload).hexdigest()+"  "+filename+"\n")
        (root / ".release-please-manifest.json").write_text('{".":"0.1.0"}')
        log = root / "calls.jsonl"
        env = {k: v for k, v in os.environ.items() if k not in ("GH_TOKEN", "GITHUB_TOKEN")}
        env.update(PATH=str(root / "bin")+os.pathsep+env["PATH"], TEST_SHA=sha, TEST_LOG=str(log), DOCS_ARCHIVE=str(archive), DOCS_VERSION="0.1.0")
        env.update(extra)
        result = subprocess.run(["bash", "-euo", "pipefail", str(publisher), tag, sha], cwd=root, env=env, capture_output=True, text=True)
        calls = [json.loads(x) for x in log.read_text().splitlines()] if log.exists() else []
        assert (result.returncode == 0) == success, (name, result.stderr)
        labels = [x for x in calls if x[:2] == ["pr", "edit"]]
        assert bool(labels) == success, (name, "relabel happened before verification")
        if name.startswith("wrong"):
            assert not any(x[:2] in (["release", "create"], ["release", "upload"]) for x in calls), name
        if name == "already-published":
            assert not any(x[:2] == ["release", "create"] for x in calls)
        results.append({"case": name, "exit": result.returncode, "relabel": bool(labels)})
print(json.dumps({"publisherBoundaryChecks": results, "externalCalls": False}))
