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

sys.path.insert(0, str(Path(__file__).resolve().parent))
from stage_release import read_all_forward

root, archive = map(Path, sys.argv[1:])
version = (root / "version.txt").read_text().strip()
assert re.fullmatch(r"\d+\.\d+\.\d+", version), "invalid documentation version"
manifest = json.loads((root / ".release-please-manifest.json").read_text())
config = json.loads((root / "release-please-config.json").read_text())
assert manifest == ({".": version} if version != "0.0.0" else {}), (
    "manifest/version drift"
)
assert config["release-type"] == "simple" and config["initial-version"] == "0.1.0"
workflows = {
    p.name: yaml.load(p.read_text(), Loader=yaml.BaseLoader)
    for p in (root / ".github/workflows").glob("*.yml")
}
assert "workflow_dispatch" in workflows["ci.yml"]["on"], "CI recovery trigger missing"
planner = workflows["release.yml"]["jobs"]["release-pr"]
action = next(
    s
    for s in planner["steps"]
    if s.get("uses", "").startswith("googleapis/release-please-action@")
)
assert action["with"]["skip-github-release"] == "true", (
    "release-please would post release comments"
)
assert planner["needs"] == "build-gate", "release planning bypasses build gate"
# #695: the publisher merges the platform bundles only when told where they
# are, so the tag run must wait for the bundle builds and always name the
# directory it downloaded them into.
publisher = workflows["release.yml"]["jobs"]["publish"]
assert "bundles" in publisher["needs"], "publication does not wait for the bundles"
assert any("BUNDLES_DIR" in step.get("env", {}) for step in publisher["steps"]), (
    "publication does not name the bundle directory"
)
assert (
    workflows["release.yml"]["jobs"]["bundles"]["uses"]
    == "./.github/workflows/release-bundles.yml"
), "the tag run does not call the bundle workflow"
docs_name = f"singular-docs-{version}.tar.gz"
onchain_name = f"singular-onchain-{version}.tar.gz"
docs_digest = hashlib.sha256((archive / docs_name).read_bytes()).hexdigest()
onchain_path = archive / onchain_name
onchain_present = onchain_path.exists()
onchain_digest = (
    hashlib.sha256(onchain_path.read_bytes()).hexdigest() if onchain_present else None
)
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
        "artifacts/review/REPRODUCE.md",
        "artifacts/review/.specify/memory/constitution.md",
        "artifacts/review/docs/theorems.md",
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
        "artifacts/review/simulator/lifecycle.mjs",
        "artifacts/review/simulator/naming.mjs",
        "artifacts/review/simulator/core.mjs",
        "artifacts/review/simulator/mirror-check.mjs",
        "artifacts/review/tools/axioms.lean",
        "artifacts/review/tools/check_model.py",
        "artifacts/SHA256SUMS",
    )
    for required in required_artifacts:
        assert required in names, f"release archive misses {required}"
    # The review root README is the repository README the model check
    # verifies, not the reproduction instructions: each file must carry
    # its own content, so a swapped copy fails here rather than late in
    # the archived check.
    reproduce = (
        bundle.extractfile(members["artifacts/review/REPRODUCE.md"]).read().decode()
    )
    assert "sha256sum --check artifacts/SHA256SUMS" in reproduce, (
        "review reproduction instructions state no checksum command"
    )
    assert "./artifacts/review#check" in reproduce, (
        "review reproduction instructions state no archive check command"
    )
    shipped_readme = (
        bundle.extractfile(members["artifacts/review/README.md"]).read().decode()
    )
    assert "proved declarations" in shipped_readme, (
        "review root README carries no declaration counts for the model check"
    )
    recorded = bundle.extractfile("./artifacts/SHA256SUMS").read().decode().splitlines()
    expected_paths = {
        name
        for name, member in members.items()
        if name.startswith("artifacts/")
        and name != "artifacts/SHA256SUMS"
        and member.isfile()
    }
    expected_paths.update(
        {
            "model/corpus.json",
            "model/naming-corpus.json",
            "model/lifecycle-corpus.json",
            "model/theorem-debt.json",
            "model/naming-theorem-debt.json",
            "model/lifecycle-theorem-debt.json",
            "model/wire-theorem-debt.json",
            "simulator/identity.json",
        }
    )
    expected_lines = []
    payloads = read_all_forward(bundle, expected_paths)
    assert set(payloads) == expected_paths, "artifact payloads unreadable"
    for path in sorted(expected_paths):
        expected_lines.append(f"{hashlib.sha256(payloads[path]).hexdigest()}  {path}")
    assert recorded == expected_lines, "artifact identity manifest drift"
    assert all(
        not m.name.startswith("/")
        and ".." not in Path(m.name).parts
        and not m.issym()
        and not m.islnk()
        for m in bundle.getmembers()
    )

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
        version_member = "onchain/version.txt"
        if version_member not in names:
            assert False, "onchain/version.txt is missing"
        staged_version = (
            bundle.extractfile(members[version_member]).read().decode().strip()
        )
        file_version = onchain_path.name.removeprefix("singular-onchain-").removesuffix(
            ".tar.gz"
        )
        if staged_version != version or staged_version != file_version:
            assert False, "onchain/version.txt differs from the release version"
        inner_lines = (
            bundle.extractfile(members["SHA256SUMS"]).read().decode().splitlines()
        )
        inner_names = {line.split("  ", 1)[1] for line in inner_lines}
        if version_member not in inner_names:
            assert False, "onchain/version.txt is not covered by the archive checksums"
        for required in (
            "README.md",
            "RELEASE.md",
            "RELEASE-COMMIT",
            # #326: the application model revision the release maps to.
            "MODEL-REVISION",
            "SHA256SUMS",
            "verify-identities.sh",
            # #299: the ordinary commands' entry point. Required, so the
            # archive cannot ship `singular registry` without its source.
            "offchain/cli/Main.hs",
            # #528 slice 4: the release ships both executables. Required, so
            # the archive cannot ship `singular` without `open-datum`, nor
            # either without its flake and entry point.
            "applications/open-datum/offchain/flake.nix",
            "applications/open-datum/offchain/flake.lock",
            "applications/open-datum/offchain/open-datum.cabal",
            "applications/open-datum/offchain/app/Main.hs",
            # #695: the commit `open-datum --version` states in a build of
            # this archive, the same one the archive's root states.
            "applications/open-datum/offchain/RELEASE-COMMIT",
            # #300: the refusal controls and the indexer readback replay from
            # the archive: the runner, its take, the readback, the statement
            # ledger and specification it binds, and the flake inputs it reads.
            "conformance/app-cli/Main.hs",
            "conformance/flake.nix",
            "tools/demo1_cli_attach.sh",
            "tools/demo1_readback.sh",
            "tools/demo1_mock_indexer.py",
            "tools/demo1_readback_tamper.sh",
            "applications/open-datum/ledgers.json",
            "specs/299-singular-cli/spec.md",
            "lean-toolchain",
            "flake.lock",
            "onchain/plutus.json",
            "onchain/version.txt",
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
            "offchain/naming/src/Naming/Wire/Vectors.hs",
            "fixtures/Naming-Wire-Vectors.hs",
            "fixtures/README.md",
        ):
            assert required in names, f"on-chain release archive misses {required}"
        root_commit = bundle.extractfile(members["RELEASE-COMMIT"]).read()
        assert (
            bundle.extractfile(
                members["applications/open-datum/offchain/RELEASE-COMMIT"]
            ).read()
            == root_commit
        ), "the application's release commit differs from the archive's"
        assert all(
            not m.name.startswith("/")
            and ".." not in Path(m.name).parts
            and not m.issym()
            and not m.islnk()
            for m in bundle.getmembers()
        )
        fixtures_copy = bundle.extractfile(
            members["fixtures/Naming-Wire-Vectors.hs"]
        ).read()
        canonical = bundle.extractfile(
            members["offchain/naming/src/Naming/Wire/Vectors.hs"]
        ).read()
        assert fixtures_copy == canonical, (
            "vendored fixture copy drifted from the offchain module"
        )
        covered = {}
        for line in (
            bundle.extractfile(members["SHA256SUMS"]).read().decode().splitlines()
        ):
            digest, name = line.split("  ", 1)
            covered[name] = digest
        expected = {
            name: hashlib.sha256(payload).hexdigest()
            for name, payload in read_all_forward(
                bundle, names - {"SHA256SUMS"}
            ).items()
        }
        assert covered == expected, "on-chain archive internal checksum manifest drift"
        # #326: the model revision the archive states is the one the
        # conformance evidence is compiled against: one file, read by both.
        stated = bundle.extractfile(members["MODEL-REVISION"]).read().decode()
        named = (root / "conformance/model-revision").read_text()
        assert re.fullmatch(r"[0-9a-f]{40}\n", stated), (
            f"archive model revision is not one commit: {stated!r}"
        )
        assert stated == named, (
            f"archive model revision {stated.strip()} differs from the "
            f"conformance evidence's {named.strip()}"
        )
        release_text = bundle.extractfile(members["RELEASE.md"]).read().decode()
        assert release_text == (root / "onchain-release/RELEASE.md").read_text(), (
            "archive release instructions differ from source"
        )
        for phrase in ("epic", "E18", "obligation", "milestone artifact"):
            assert phrase.casefold() not in release_text.casefold(), (
                f"release text contains forbidden wording: {phrase}"
            )
        readme_text = bundle.extractfile(members["README.md"]).read().decode()
        # The corrected availability promise (operator ruling 2026-09-25):
        # the archive README presents the verified connected journey as the
        # runnable lifecycle command, and binds EVERY retained declaration
        # to its unavailable status and owning issue in one bounded
        # availability table — the seven commands earlier releases
        # advertised plus repair-rows and connected-verifier which it never
        # advertised — and states that future corrections cannot rewrite
        # already published archives. Each row is checked as a unit
        # (name, unavailable status, issue together); duplicates, rows
        # lacking their status or issue, and rows claiming availability are
        # all refusals. Identity and fixture assertions are unchanged.
        for phrase in (
            "verify-identities.sh",
            "plutus.json",
            "script-identity.json",
            "nix run .#journey",
            "run-suite.sh",
            "SHA256SUMS",
        ):
            assert phrase in readme_text, f"artifact README does not document: {phrase}"
        retained = (
            ("nix run .#li01", "#172"),
            ("nix run .#li-refusals", "#172"),
            ("nix run .#naming-rows", "#172"),
            ("nix run .#register-rows", "#283"),
            ("nix run .#recovery-rows", "#172"),
            ("nix run .#retirement-rows", "#172"),
            ("nix run .#retirement-verify", "#172"),
            ("repair-rows", "#172"),
            ("connected-verifier", "#282"),
        )
        lines = readme_text.splitlines()
        table_start = next(
            (
                i
                for i, line in enumerate(lines)
                if "retained command" in line and line.lstrip().startswith("|")
            ),
            None,
        )
        rows = []
        if table_start is not None:
            for line in lines[table_start + 1 :]:
                if not line.lstrip().startswith("|"):
                    break
                if set(line) <= set("|-: "):
                    continue
                rows.append(line)
        missing, duplicated, unbound, contradictory = [], [], [], []
        for name, issue in retained:
            matching = [row for row in rows if name in row]
            if not matching:
                missing.append(name)
                continue
            if len(matching) > 1:
                duplicated.append(name)
                continue
            row = matching[0]
            if re.search(r"(?<!un)available", row):
                contradictory.append(name)
                continue
            if "unavailable" not in row or issue not in row:
                unbound.append(name)
        assert not missing, (
            "artifact README does not disclose retained legacy commands: "
            + ", ".join(missing)
        )
        assert not duplicated, (
            "artifact README has more than one availability row for: "
            + ", ".join(duplicated)
        )
        assert not contradictory, (
            "artifact README availability row contradicts the retained status for: "
            + ", ".join(contradictory)
        )
        assert not unbound, (
            "artifact README availability row lacks its unavailable status or owning issue for: "
            + ", ".join(unbound)
        )
        assert "not currently buildable or verified" in readme_text, (
            "artifact README does not state that retained commands are not currently buildable or verified"
        )
        assert "already published archives are never rewritten" in readme_text, (
            "artifact README does not state the published-archive limit"
        )
        # The identities CI enforces, verified from the downloaded artifact itself:
        # the archive's own checker runs against the carried compiled blueprints.
        with tempfile.TemporaryDirectory() as extract_dir:
            bundle.extractall(extract_dir, filter="data")
            result = subprocess.run(
                ["bash", "verify-identities.sh"],
                cwd=extract_dir,
                capture_output=True,
                text=True,
            )
            assert result.returncode == 0, (
                "identity verification from the artifact failed:\n"
                + result.stdout
                + result.stderr
            )
    identity_from_artifact = "PASS"
print(
    json.dumps(
        {
            "version": version,
            "unreleasedBaseline": not manifest,
            "archive": filename,
            "onchainArchive": onchain_checked,
            "versionAgreement": "PASS",
            "artifactAndWorkflowChecks": "PASS",
            "identityFromArtifact": identity_from_artifact,
        }
    )
)
