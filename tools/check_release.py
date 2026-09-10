"""Validate version agreement, release guards and the actual documentation archive."""
import hashlib
import json
from pathlib import Path
import re
import sys
import tarfile
import yaml

root, archive = map(Path, sys.argv[1:])
version = (root / "version.txt").read_text().strip()
assert re.fullmatch(r"\d+\.\d+\.\d+", version), "invalid documentation version"
manifest = json.loads((root / ".release-please-manifest.json").read_text())
config = json.loads((root / "release-please-config.json").read_text())
assert manifest == ({".": version} if version != "0.0.0" else {}), "manifest/version drift"
assert config["release-type"] == "simple" and config["initial-version"] == "0.1.0"
workflows = {p.name: yaml.load(p.read_text(), Loader=yaml.BaseLoader) for p in (root / ".github/workflows").glob("*.yml")}
assert "workflow_dispatch" in workflows["ci.yml"]["on"], "CI recovery trigger missing"
planner = workflows["release.yml"]["jobs"]["release-pr"]
action = next(s for s in planner["steps"] if s.get("uses", "").startswith("googleapis/release-please-action@"))
assert action["with"]["skip-github-release"] == "true", "release-please would post release comments"
assert planner["needs"] == "build-gate", "release planning bypasses build gate"
for name, workflow in workflows.items():
    for job in workflow["jobs"].values():
        assert job["runs-on"] == "nixos", name
        assert all("dev-assets/setup-nix" not in s.get("uses", "") for s in job["steps"])
filename = f"singular-docs-{version}.tar.gz"
assert (archive / "SHA256SUMS").read_text() == hashlib.sha256((archive / filename).read_bytes()).hexdigest() + "  " + filename + "\n"
with tarfile.open(archive / filename) as bundle:
    members = {m.name.removeprefix("./"): m for m in bundle.getmembers()}
    names = set(members)
    for required in (
        "index.html",
        "docs/naming-demo/index.html",
        "docs/naming-demo.speech.json",
        "docs/naming-lifecycle/index.html",
        "docs/naming-lifecycle.speech.json",
        "specs/protocol/spec/index.html",
        "index.speech.json",
    ):
        assert required in names, f"release archive misses {required}"
    required_artifacts = (
        "artifacts/contracts/naming-lifecycle-contract.txt",
        "artifacts/review/README.md",
        "artifacts/review/flake.nix",
        "artifacts/review/flake.lock",
        "artifacts/review/lakefile.toml",
        "artifacts/review/lean-toolchain",
        "artifacts/review/lean/Main.lean",
        "artifacts/review/lean/NamingMain.lean",
        "artifacts/review/lean/LifecycleMain.lean",
        "artifacts/review/lean/corpus.json",
        "artifacts/review/lean/naming-corpus.json",
        "artifacts/review/lean/lifecycle-corpus.json",
        "artifacts/review/lean/lifecycle-theorem-debt.json",
        "artifacts/review/lean/wire-theorem-debt.json",
        "artifacts/review/simulator/build.mjs",
        "artifacts/review/simulator/gate.mjs",
        "artifacts/review/simulator/index.html",
        "artifacts/review/simulator/lifecycle-view.html",
        "artifacts/review/simulator/lifecycle-journeys.mjs",
        "artifacts/review/simulator/lifecycle.mjs",
        "artifacts/review/simulator/naming-wire.mjs",
        "artifacts/review/simulator/lifecycle-corpus.json",
        "artifacts/review/tools/axioms.lean",
        "artifacts/review/tools/check_model.py",
        "artifacts/SHA256SUMS",
    )
    for required in required_artifacts:
        assert required in names, f"release archive misses {required}"
    recorded = bundle.extractfile("./artifacts/SHA256SUMS").read().decode().splitlines()
    expected_paths = {
        name for name, member in members.items()
        if name.startswith("artifacts/") and name != "artifacts/SHA256SUMS"
        and member.isfile()
    }
    expected_paths.update({
        "model/corpus.json",
        "model/naming-corpus.json",
        "model/lifecycle-corpus.json",
        "model/theorem-debt.json",
        "model/naming-theorem-debt.json",
        "model/lifecycle-theorem-debt.json",
        "model/wire-theorem-debt.json",
        "simulator/identity.json",
        "simulator/lifecycle-corpus.json",
    })
    expected_lines = []
    for path in sorted(expected_paths):
        payload = bundle.extractfile(members[path]).read()
        expected_lines.append(f"{hashlib.sha256(payload).hexdigest()}  {path}")
    assert recorded == expected_lines, "artifact identity manifest drift"
    assert all(not m.name.startswith("/") and ".." not in Path(m.name).parts and not m.issym() and not m.islnk() for m in bundle.getmembers())
print(json.dumps({"version": version, "unreleasedBaseline": not manifest, "archive": filename, "versionAgreement": "PASS", "artifactAndWorkflowChecks": "PASS"}))
