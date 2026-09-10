"""Stage canonical Markdown once for MkDocs; generated files are never edited."""
import hashlib
import os
from pathlib import Path
import re
import shutil

root = Path(__file__).resolve().parent.parent
stage = root / ".docs-source"
if stage.exists():
    shutil.rmtree(stage)
stage.mkdir()
for directory in ("docs", "specs"):
    shutil.copytree(root / directory, stage / directory)


def restage_lean_hrefs(stage: Path) -> int:
    """Point staged evidence hrefs at the shipped model/ copy.

    Repository sources reference lean/ relatively so GitHub blob rendering
    follows the current ref; the staged pages the site is built from must
    resolve on-host — preview, Pages and a served archive — against the
    model/ bytes this build ships. Same relative depth, lean/ → model/,
    hrefs only.
    """
    rewritten = 0
    pages = sorted(stage.glob("docs/**/*.md")) + sorted(stage.glob("specs/**/*.md"))
    for md in pages:
        text = md.read_text(encoding="utf-8")
        # Markdown evidence links become raw anchors: the built page lives one
        # directory deeper than the source (docs/x.md -> docs/x/), MkDocs does
        # not recompute links to non-page files, and a markdown ../../ escape
        # would fail strict docs_dir validation — raw anchors are exempt and
        # already the established form for prefix-crossing links.
        new = re.sub(
            r'\[([^\]]+)\]\(((?:\.\./)*)((?:[\w.-]+/)*)lean/([^)]*)\)',
            lambda m: f'<a href="../../model/{m.group(4)}">{m.group(1)}</a>',
            text,
        )
        # Raw HTML anchors likewise gain the one level.
        new = re.sub(
            r'(href=")((?:\.\./)*)((?:[\w.-]+/)*)lean/',
            lambda m: m.group(1) + "../../" + m.group(3) + "model/",
            new,
        )
        if new != text:
            md.write_text(new, encoding="utf-8")
            rewritten += 1
    if rewritten == 0:
        raise RuntimeError("no lean/ evidence hrefs rewritten for staging: the shipped model/ mechanism found nothing")
    return rewritten


restage_lean_hrefs(stage)
# Ship the actual candidate sources and static simulator with the same site.
# Generated build trees never become part of the publication.
model = root / "lean"
if model.is_dir():
    shutil.copytree(model, stage / "model", ignore=shutil.ignore_patterns(
        ".lake", "node_modules", "__pycache__", "*.olean", "*.ilean", "*.c", "*.o"
    ))
# The simulator is self-contained. Its development snapshots and test evidence
# stay in Git; publishing another copy of the formal corpus also creates archive
# hardlinks after Nix store deduplication.
simulator = root / "simulator"
if (simulator / "index.html").is_file():
    (stage / "simulator").mkdir()
    for name in ("index.html", "identity.json"):
        shutil.copyfile(simulator / name, stage / "simulator" / name)

# The release archive is also a reproducible review kit. Keep the raw contract,
# scenarios, replay sources, pinned toolchain inputs, and identity ledgers beside
# the rendered site, with one byte-exact manifest over the complete surface.
artifact_sources = {
    "contracts/naming-lifecycle-contract.txt": root / "docs/naming-lifecycle.md",
    "scenarios/stories.json": root / "simulator/stories.json",
    "replay/README.txt": root / "simulator/README.md",
    "replay/actions.mjs": root / "simulator/actions.mjs",
    "replay/core.mjs": root / "simulator/core.mjs",
    "replay/naming.mjs": root / "simulator/naming.mjs",
    "tooling/flake.lock": root / "flake.lock",
    "tooling/lean-toolchain": root / "lean-toolchain",
}
artifacts = stage / "artifacts"
manifest = {}
for relative, source in sorted(artifact_sources.items()):
    destination = artifacts / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    manifest[f"artifacts/{relative}"] = hashlib.sha256(destination.read_bytes()).hexdigest()
for relative in (
    "model/corpus.json",
    "model/naming-corpus.json",
    "model/theorem-debt.json",
    "model/naming-theorem-debt.json",
    "simulator/identity.json",
):
    manifest[relative] = hashlib.sha256((stage / relative).read_bytes()).hexdigest()
(artifacts / "SHA256SUMS").write_text(
    "\n".join(f"{manifest[path]}  {path}" for path in sorted(manifest)) + "\n",
    encoding="utf-8",
)
shutil.copyfile(root / "README.md", stage / "index.md")
shutil.copyfile(root / "README.speech.json", stage / "index.speech.json")
# The shared reader assumes a root deployment when locating home-page speech.
# An explicit page link also works under GitHub Pages and PR-preview prefixes.
shared = Path(os.environ["DOCS_SHARED_SOURCE"])
reader = (shared / "docs/js/read-aloud.js").read_text()
reader, replacements = re.subn(
    r'  var pagePath = window.location.pathname.*?\n  fetch\(speechUrl\)',
    '  var speechUrl = document.querySelector(\'link[rel="speech"]\').href;\n\n  fetch(speechUrl)',
    reader,
    flags=re.S,
)
if replacements != 1:
    raise RuntimeError("Pinned shared reader changed its speech URL logic")
assets = stage / "assets"
assets.mkdir()
(assets / "read-aloud.js").write_text(reader)
# Pinned Mermaid: served from the site so no page loads a script from a CDN.
shutil.copyfile(os.environ["MERMAID_JS"], assets / "mermaid.min.js")
