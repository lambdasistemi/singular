"""Assemble and checksum the on-chain release archive from a checkout.

The release is staged by the same machinery as the documentation
archive — stage_release.py materializes a regular tree, a
deterministic tar is checksummed — but the compiled blueprints are
passed in as store paths built by their own flakes (each partition
evaluates against its own lock; the
pipeline builds each blueprint as its own step and hands the store
path to staging, which is pure, rather than any eval-time crossing of
flake boundaries).

Usage:
    assemble_release.py <repo-root> <docs-dir> <onchain-bp> <out-dir>

Produces in <out-dir>:
    singular-onchain-<version>.tar.gz   the on-chain release archive
    singular-docs-<version>.tar.gz      copied from <docs-dir>
    SHA256SUMS                          checksums of both archives
"""

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from stage_release import assert_regular_tree, stage_release


def copy_tracked_partitions(
    root: Path, farm: Path, partitions: tuple[str, ...]
) -> None:
    """Copy exactly the git-tracked source of each partition (issue: ignored
    local build state — dist-newstyle/, build/ — must never change release
    membership at the same candidate). `git ls-files` enumerates declared
    source; built blueprints and vendored fixtures ride explicit copyfile
    calls below, never a live partition copy. Modes preserved via copy2 so
    staging materializes identical permissions either way."""
    listed = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", *partitions],
        stdout=subprocess.PIPE,
        check=True,
    )
    shipped = 0
    for relative in listed.stdout.split(b"\0"):
        if not relative:
            continue
        source = root / relative.decode()
        target = farm / relative.decode()
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        shipped += 1
    if shipped == 0:
        raise ValueError("no tracked source enumerated; refusing an empty farm")


def assemble(root: Path, docs_dir: Path, onchain_bp: Path, out: Path) -> None:
    version = (root / "version.txt").read_text().strip()
    docs_name = f"singular-docs-{version}.tar.gz"
    onchain_name = f"singular-onchain-{version}.tar.gz"

    docs_digest = hashlib.sha256((docs_dir / docs_name).read_bytes()).hexdigest()
    docs_sums = (docs_dir / "SHA256SUMS").read_text().splitlines()
    assert docs_sums == [f"{docs_digest}  {docs_name}"], (
        "unexpected documentation checksum manifest"
    )

    work = Path(tempfile.mkdtemp(prefix="release-assembly-"))
    farm = work / "farm"
    farm.mkdir()
    copy_tracked_partitions(
        root,
        farm,
        (
            "onchain",
            "offchain",
            # #300: the demonstration's refusal controls and indexer readback
            # replay from the archive alone. The controls runner is a flake that
            # reads the model, the tools and the root lock beside it, and binds
            # the command-line specification, so it ships too.
            "conformance",
            "lean",
            "tools",
            "lakefile.toml",
            "lake-manifest.json",
            "lean-toolchain",
            "flake.lock",
            "fourmolu.yaml",
            "applications/open-datum/offchain",
            "specs/299-singular-cli/spec.md",
        ),
    )
    shutil.copyfile(root / "release/README.md", farm / "README.md")
    shutil.copyfile(root / "RELEASE.md", farm / "RELEASE.md")
    shutil.copyfile(
        root / "release/verify-identities.sh", farm / "verify-identities.sh"
    )
    shutil.copyfile(onchain_bp, farm / "onchain/plutus.json")
    # The release label the page reads from the extracted archive: the
    # repository version file beside the blueprint it describes.
    shutil.copyfile(root / "version.txt", farm / "onchain" / "version.txt")
    # S5.2: the archive's onchain/plutus.json is the merged deployment
    # document, so its script-identity.json is the merged
    # manifest (union of the two committed manifests, same schema/compiler).
    # The farm already carries the registry manifest via tracked partitions;
    # overwrite it with the union so verify-identities.sh passes from the
    # artifact alone. No second copy of any registry module is introduced.
    import json as _json

    _reg_man = _json.loads((root / "onchain" / "script-identity.json").read_text())
    _app_man = _json.loads(
        (
            root / "applications" / "open-datum" / "onchain" / "script-identity.json"
        ).read_text()
    )
    assert _reg_man["schema"] == _app_man["schema"] == 1, "manifest schema moved"
    assert _reg_man["compiler"] == _app_man["compiler"], "manifest compiler moved"
    assert _reg_man["upstream"] == _app_man["upstream"], "manifest upstream moved"
    _titles = [v["title"] for v in _reg_man["validators"]] + [
        v["title"] for v in _app_man["validators"]
    ]
    assert len(_titles) == len(set(_titles)), "duplicate validator titles in manifests"
    _merged_validators = sorted(
        _reg_man["validators"] + _app_man["validators"],
        key=lambda v: v["title"],
    )
    _deployed = len(_json.loads(onchain_bp.read_text())["validators"])
    _pinned = len(_reg_man["validators"]) + len(_app_man["validators"])
    assert _deployed == _pinned, (
        f"deployment blueprint has {_deployed} validators, "
        f"the two manifests pin {_pinned}"
    )
    (farm / "onchain" / "script-identity.json").write_text(
        _json.dumps(
            {
                "schema": 1,
                "upstream": _reg_man["upstream"],
                "compiler": _reg_man["compiler"],
                "validators": _merged_validators,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    # Issue #91: the archive is not a git checkout, so the commit it
    # publishes rides at its root as RELEASE-COMMIT — the row runners
    # resolve their candidate by walking up from their working
    # directory. The assembler shell sets RELEASE_COMMIT from the
    # pipeline's TAG_COMMIT or the flake revision; a direct invocation
    # without either stays honest instead of inventing a commit.
    release_commit = os.environ.get("RELEASE_COMMIT", "").strip() or "unknown-dirty"
    (farm / "RELEASE-COMMIT").write_text(release_commit + "\n", encoding="utf-8")
    # #695: the application's flake reads the same commit from its own
    # directory (a file there is outside the source its executable is built
    # from, so a build of the archive still finds the cached build), for
    # `open-datum --version`.
    (farm / "applications" / "open-datum" / "offchain" / "RELEASE-COMMIT").write_text(
        release_commit + "\n", encoding="utf-8"
    )
    # #326: the application model revision the release maps to, from the one
    # file the conformance evidence is compiled against.
    shutil.copyfile(root / "conformance" / "model-revision", farm / "MODEL-REVISION")

    staging = work / "staging"
    stage_release(farm, staging)
    assert_regular_tree(staging)

    sums = (
        "\n".join(
            f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.relative_to(staging)}"
            for path in sorted(staging.rglob("*"))
            if path.is_file() and path.name != "SHA256SUMS"
        )
        + "\n"
    )
    (staging / "SHA256SUMS").write_text(sums, encoding="utf-8")

    out.mkdir(parents=True, exist_ok=True)
    tar_proc = subprocess.Popen(
        [
            "tar",
            "--sort=name",
            "--mtime=@1",
            "--owner=0",
            "--group=0",
            "--numeric-owner",
            "-C",
            str(staging),
            "-cf",
            "-",
            ".",
        ],
        stdout=subprocess.PIPE,
    )
    with open(out / onchain_name, "wb") as archive_file:
        subprocess.run(
            ["gzip", "-n"], stdin=tar_proc.stdout, stdout=archive_file, check=True
        )
    if tar_proc.wait() != 0:
        raise subprocess.CalledProcessError(tar_proc.returncode, "tar")
    shutil.copyfile(docs_dir / docs_name, out / docs_name)
    onchain_digest = hashlib.sha256((out / onchain_name).read_bytes()).hexdigest()
    (out / "SHA256SUMS").write_text(
        docs_sums[0] + "\n" + f"{onchain_digest}  {onchain_name}\n", encoding="utf-8"
    )
    print(f"on-chain release assembly: PASS ({out / onchain_name})")


def main() -> None:
    root, docs_dir, onchain_bp, out = map(Path, sys.argv[1:5])
    assemble(root, docs_dir, onchain_bp, out)


if __name__ == "__main__":
    main()
