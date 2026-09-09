"""Stage canonical Markdown once for MkDocs; generated files are never edited."""
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
