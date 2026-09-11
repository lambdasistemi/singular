"""Validate version agreement, release guards and the actual release archives."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
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
docs_name = f"singular-docs-{version}.tar.gz"
onchain_name = f"singular-onchain-{version}.tar.gz"
docs_digest = hashlib.sha256((archive / docs_name).read_bytes()).hexdigest()
onchain_path = archive / onchain_name
onchain_present = onchain_path.exists()
onchain_digest = hashlib.sha256(onchain_path.read_bytes()).hexdigest() if onchain_present else None
sums = {}
for line in (archive / "SHA256SUMS").read_text().splitlines():
    digest, name = line.split("  ", 1)
    sums[name] = digest
expected_sums = {docs_name: docs_digest}
if onchain_present:
    expected_sums[onchain_name] = onchain_digest
assert sums == expected_sums, "release checksum manifest drift"
filename = docs_name
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

# The on-chain release archive, when it is present in the checked release
# directory: the compiled scripts and both pinned identity layers, the runnable
# journey and row runners, the contract fixtures, and checksum manifests —
# checked from the archive, the way a downloader would. It is assembled where
# a checkout and the two built blueprints coexist (ci.yml's release-artifacts
# job, and the publish path before upload); the flake's own docs-archive check
# runs without it, and its absence is surfaced in the JSON below rather than
# silently skipped.
onchain_checked = None
identity_from_artifact = "ABSENT"
if onchain_present:
    onchain_checked = onchain_name
    with tarfile.open(onchain_path) as bundle:
        members = {m.name.removeprefix("./"): m for m in bundle.getmembers()}
        names = set(members)
        for required in (
        "README.md",
        "RELEASE.md",
        "SHA256SUMS",
        "verify-identities.sh",
        "onchain/plutus.json",
        "onchain/script-identity.json",
        "onchain/aiken.toml",
        "onchain/aiken.lock",
        "onchain/flake.nix",
        "onchain/flake.lock",
        "naming-onchain/plutus.json",
        "naming-onchain/script-identity.json",
        "naming-onchain/aiken.toml",
        "naming-onchain/aiken.lock",
        "naming-onchain/flake.nix",
        "naming-onchain/flake.lock",
        "offchain/flake.nix",
        "offchain/flake.lock",
        "offchain/journey/README.md",
        "offchain/journey/Main.hs",
        "offchain/journey/li01/Main.hs",
        "offchain/journey/li-refusals/Main.hs",
        "offchain/journey/lmlc/Main.hs",
        "offchain/naming/src/Naming/Wire/Vectors.hs",
        "fixtures/Naming-Wire-Vectors.hs",
        "fixtures/README.md",
    ):
            assert required in names, f"on-chain release archive misses {required}"
        assert all(not m.name.startswith("/") and ".." not in Path(m.name).parts and not m.issym() and not m.islnk() for m in bundle.getmembers())
        fixtures_copy = bundle.extractfile(members["fixtures/Naming-Wire-Vectors.hs"]).read()
        canonical = bundle.extractfile(members["offchain/naming/src/Naming/Wire/Vectors.hs"]).read()
        assert fixtures_copy == canonical, "vendored fixture copy drifted from the offchain module"
        covered = {}
        for line in bundle.extractfile(members["SHA256SUMS"]).read().decode().splitlines():
            digest, name = line.split("  ", 1)
            covered[name] = digest
        expected = {
            name: hashlib.sha256(bundle.extractfile(members[name]).read()).hexdigest()
            for name in names - {"SHA256SUMS"} if members[name].isfile()
        }
        assert covered == expected, "on-chain archive internal checksum manifest drift"
        release_text = bundle.extractfile(members["RELEASE.md"]).read().decode()
        for phrase in (
            "epic-scoped",
            "epic 17",
            "recovery",
            "retirement",
            "finite fixture execution",
            "not a statement about arbitrary transactions",
        ):
            assert phrase in release_text, f"release text does not state: {phrase}"
        readme_text = bundle.extractfile(members["README.md"]).read().decode()
        for phrase in (
            "verify-identities.sh",
            "plutus.json",
            "script-identity.json",
            "#journey",
            "#li01",
            "#li-refusals",
            "#naming-rows",
            "run-suite.sh",
            "SHA256SUMS",
        ):
            assert phrase in readme_text, f"artifact README does not document: {phrase}"
        # The identities CI enforces, verified from the downloaded artifact itself:
        # the archive's own checker runs against the carried compiled blueprints.
        with tempfile.TemporaryDirectory() as extract_dir:
            bundle.extractall(extract_dir, filter="data")
            result = subprocess.run(
                ["bash", "verify-identities.sh"], cwd=extract_dir, capture_output=True, text=True
            )
            assert result.returncode == 0, (
                "identity verification from the artifact failed:\n"
                + result.stdout + result.stderr
            )
    identity_from_artifact = "PASS"
print(json.dumps({
    "version": version,
    "unreleasedBaseline": not manifest,
    "archive": filename,
    "onchainArchive": onchain_checked,
    "versionAgreement": "PASS",
    "artifactAndWorkflowChecks": "PASS",
    "identityFromArtifact": identity_from_artifact,
}))
