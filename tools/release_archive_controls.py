"""Exercise release archive checks against isolated copies of assembled artifacts."""

import hashlib
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile


root, archive = (Path(value).resolve() for value in sys.argv[1:])
version = (root / "version.txt").read_text().strip()
docs_name = f"singular-docs-{version}.tar.gz"
chain_name = f"singular-onchain-{version}.tar.gz"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check(directory):
    return subprocess.run(
        [
            sys.executable,
            str(root / "tools/check_release.py"),
            str(root),
            str(directory),
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )


baseline = check(archive)
assert baseline.returncode == 0, baseline.stdout


def missing_journey(tree):
    p = tree / "README.md"
    before = p.read_text()
    after = before.replace("tools/no_pin_registration_journey.sh", "removed-journey")
    assert before != after
    p.write_text(after)


def moved_release_text(tree):
    p = tree / "RELEASE.md"
    p.write_text(p.read_text() + "\nChanged release text.\n")


def missing_version(tree):
    (tree / "onchain/version.txt").unlink()


def moved_version(tree):
    (tree / "onchain/version.txt").write_text("999.0.0\n")


def moved_identity(tree):
    import json

    p = tree / "onchain/plutus.json"
    bp = json.loads(p.read_text())
    before = bp["validators"][0]["hash"]
    bp["validators"][0]["hash"] = ("0" if before[0] != "0" else "1") + before[1:]
    assert bp["validators"][0]["hash"] != before
    p.write_text(json.dumps(bp) + "\n")


def missing_command(tree):
    (tree / "offchain/cli/Main.hs").unlink()


variants = (
    ("journey instructions", missing_journey, "artifact README does not document"),
    ("release text", moved_release_text, "archive release instructions differ"),
    ("missing version", missing_version, "onchain/version.txt is missing"),
    ("moved version", moved_version, "onchain/version.txt differs"),
    (
        "moved identity",
        moved_identity,
        "identity verification from the artifact failed",
    ),
    ("missing command source", missing_command, "offchain/cli/Main.hs"),
)
with tempfile.TemporaryDirectory(prefix="release-archive-controls-") as temporary:
    work = Path(temporary)
    for index, (name, mutate, reason) in enumerate(variants):
        tree = work / str(index) / "tree"
        output = work / str(index) / "output"
        tree.mkdir(parents=True)
        output.mkdir()
        with tarfile.open(archive / chain_name) as source:
            source.extractall(tree, filter="data")
        mutate(tree)
        files = sorted(
            p for p in tree.rglob("*") if p.is_file() and p.name != "SHA256SUMS"
        )
        (tree / "SHA256SUMS").write_text(
            "".join(f"{digest(p)}  {p.relative_to(tree)}\n" for p in files)
        )
        with tarfile.open(output / chain_name, "w:gz") as target:
            target.add(tree, arcname=".")
        (output / docs_name).symlink_to(archive / docs_name)
        (output / "SHA256SUMS").write_text(
            f"{digest(output / docs_name)}  {docs_name}\n"
            f"{digest(output / chain_name)}  {chain_name}\n"
        )
        result = check(output)
        assert result.returncode != 0, f"control missed: {name}"
        assert reason in result.stdout, f"{name}: wrong refusal:\n{result.stdout}"
        print(f"release archive control refused: {name}")
print(f"release archive controls: PASS ({len(variants)} refusals)")
