"""Attach the raw, runnable review workspace after MkDocs renders the site."""
import hashlib
from pathlib import Path
import shutil
import sys

root = Path(__file__).resolve().parent.parent
site = Path(sys.argv[1]).resolve()
artifacts = site / "artifacts"

contract = artifacts / "contracts/naming-lifecycle-contract.txt"
contract.parent.mkdir(parents=True)
shutil.copyfile(root / "docs/naming-lifecycle.md", contract)

# A reviewer starts from the extracted archive, never the source checkout.
# Development evidence and generated build trees stay out of this copy.
review = artifacts / "review"
shutil.copytree(root / "release-review", review)
shutil.copytree(root / "lean", review / "lean", ignore=shutil.ignore_patterns(
    ".lake", "__pycache__", "*.olean", "*.ilean", "*.c", "*.o"
))
shutil.copytree(root / "simulator", review / "simulator", ignore=shutil.ignore_patterns(
    "evidence", "node_modules", "__pycache__"
))
(review / "tools").mkdir()
for name in ("axioms.lean", "check_model.py"):
    shutil.copyfile(root / "tools" / name, review / "tools" / name)
for name in ("lakefile.toml", "lean-toolchain"):
    shutil.copyfile(root / name, review / name)

manifest = {
    str(path.relative_to(site)): hashlib.sha256(path.read_bytes()).hexdigest()
    for path in sorted(artifacts.rglob("*")) if path.is_file()
}
for relative in (
    "model/corpus.json",
    "model/naming-corpus.json",
    "model/theorem-debt.json",
    "model/naming-theorem-debt.json",
    "simulator/identity.json",
):
    manifest[relative] = hashlib.sha256((site / relative).read_bytes()).hexdigest()
(artifacts / "SHA256SUMS").write_text(
    "\n".join(f"{manifest[path]}  {path}" for path in sorted(manifest)) + "\n",
    encoding="utf-8",
)
