"""Assemble and checksum the on-chain release archive from a checkout.

The release is staged by the same machinery as the documentation
archive — stage_release.py materializes a regular tree, a
deterministic tar is checksummed — but the compiled blueprints are
passed in as store paths built by their own flakes (NOTE-001,
t57-release: each partition evaluates against its own lock; the
pipeline builds each blueprint as its own step and hands the store
path to staging, which is pure, rather than any eval-time crossing of
flake boundaries).

Usage:
    assemble_onchain_release.py <repo-root> <docs-dir> <onchain-bp> <naming-bp> <out-dir>

Produces in <out-dir>:
    singular-onchain-<version>.tar.gz   the on-chain release archive
    singular-docs-<version>.tar.gz      copied from <docs-dir>
    SHA256SUMS                          checksums of both archives
"""
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from stage_release import assert_regular_tree, stage_release


def copy_tracked_partitions(root: Path, farm: Path, partitions: tuple[str, ...]) -> None:
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


def assemble(root: Path, docs_dir: Path, onchain_bp: Path, naming_bp: Path, out: Path) -> None:
    version = (root / "version.txt").read_text().strip()
    docs_name = f"singular-docs-{version}.tar.gz"
    onchain_name = f"singular-onchain-{version}.tar.gz"

    docs_digest = hashlib.sha256((docs_dir / docs_name).read_bytes()).hexdigest()
    docs_sums = (docs_dir / "SHA256SUMS").read_text().splitlines()
    assert docs_sums == [f"{docs_digest}  {docs_name}"], "unexpected documentation checksum manifest"

    work = Path(tempfile.mkdtemp(prefix="onchain-release-"))
    farm = work / "farm"
    farm.mkdir()
    copy_tracked_partitions(root, farm, ("onchain", "naming-onchain", "offchain"))
    for relative in ("README.md", "RELEASE.md", "verify-identities.sh"):
        shutil.copyfile(root / "onchain-release" / relative, farm / relative)
    (farm / "fixtures").mkdir()
    shutil.copyfile(root / "onchain-release" / "fixtures" / "README.md", farm / "fixtures" / "README.md")
    shutil.copyfile(
        root / "offchain/naming/src/Naming/Wire/Vectors.hs",
        farm / "fixtures" / "Naming-Wire-Vectors.hs",
    )
    shutil.copyfile(onchain_bp, farm / "onchain" / "plutus.json")
    shutil.copyfile(naming_bp, farm / "naming-onchain" / "plutus.json")

    staging = work / "staging"
    stage_release(farm, staging)
    assert_regular_tree(staging)

    sums = "\n".join(
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.relative_to(staging)}"
        for path in sorted(staging.rglob("*"))
        if path.is_file() and path.name != "SHA256SUMS"
    ) + "\n"
    (staging / "SHA256SUMS").write_text(sums, encoding="utf-8")

    out.mkdir(parents=True, exist_ok=True)
    tar_proc = subprocess.Popen(
        [
            "tar", "--sort=name", "--mtime=@1", "--owner=0", "--group=0",
            "--numeric-owner", "-C", str(staging), "-cf", "-", ".",
        ],
        stdout=subprocess.PIPE,
    )
    with open(out / onchain_name, "wb") as archive_file:
        subprocess.run(["gzip", "-n"], stdin=tar_proc.stdout, stdout=archive_file, check=True)
    if tar_proc.wait() != 0:
        raise subprocess.CalledProcessError(tar_proc.returncode, "tar")
    shutil.copyfile(docs_dir / docs_name, out / docs_name)
    onchain_digest = hashlib.sha256((out / onchain_name).read_bytes()).hexdigest()
    (out / "SHA256SUMS").write_text(
        docs_sums[0] + "\n" + f"{onchain_digest}  {onchain_name}\n", encoding="utf-8"
    )
    print(f"on-chain release assembly: PASS ({out / onchain_name})")


def main() -> None:
    root, docs_dir, onchain_bp, naming_bp, out = map(Path, sys.argv[1:6])
    assemble(root, docs_dir, onchain_bp, naming_bp, out)


if __name__ == "__main__":
    main()
