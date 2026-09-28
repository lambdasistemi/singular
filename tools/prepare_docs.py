"""Stage canonical Markdown once for MkDocs; generated files are never edited."""
import os
from pathlib import Path
import re
import shutil

import api_reference

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


def restage_api_hrefs(stage: Path) -> int:
    """Point staged source anchors at each library's generated API reference.

    Authored pages link the repository's own Haskell sources, so GitHub blob
    rendering follows the current ref; the built site instead serves the
    generated Haddock pages for this candidate, addressed one level up the
    same way the shipped model/ copy is. The ``data-api`` attribute names
    which generated page the anchor becomes: ``module`` or ``source`` for a
    module's two pages — the anchor must name a module of that library's
    Cabal extent, so a link to a non-library file cannot silently pass
    through — or ``index``/``symbols`` for the reference's full-page index
    and symbol index, whose anchor names the library's source root, the
    closest honest GitHub landing for a page that only exists generated.
    Every library with a generated reference must be reached by at least
    one anchor, or the staging fails: an unreachable reference is a
    navigation bug, not a silent pass.
    """
    rewritten_total = 0
    for library in api_reference.LIBRARIES.values():
        extent = set(api_reference.library_modules(library, root / library.repo_dir))

        def module_of(rel_path: str) -> str:
            for source_dir in api_reference.parse_cabal_library(
                library, root / library.repo_dir
            )["hs_source_dirs"]:
                prefix = source_dir.strip("/") + "/"
                if rel_path.startswith(prefix):
                    module = rel_path[len(prefix):-len(".hs")].replace("/", ".")
                    if module not in extent:
                        raise RuntimeError(
                            f"api anchor targets a file outside the {library.name} "
                            f"Cabal library extent: {rel_path}"
                        )
                    return module
            raise RuntimeError(f"api anchor is not under a declared hs-source-dir: {rel_path}")

        pattern = re.compile(
            rf'<a href="\.\./{library.repo_dir}/([^"]*)" data-api="(module|source|index|symbols)">'
        )
        api_prefix = "/".join(library.api_dir)

        def replace(match: re.Match) -> str:
            kind, rel = match.group(2), match.group(1)
            if kind in ("index", "symbols"):
                if rel:
                    raise RuntimeError(
                        f"api {kind} anchor must name the {library.name} source root, "
                        f"not {rel}"
                    )
                page = "doc-index.html" if kind == "index" else "doc-index-All.html"
            else:
                module = module_of(rel)
                page = (
                    api_reference.module_page_name(module)
                    if kind == "module"
                    else "src/" + api_reference.source_page_name(module)
                )
            return f'<a href="../../{api_prefix}/{page}">'

        rewritten = 0
        pages = sorted(stage.glob("docs/**/*.md"))
        for md in pages:
            text = md.read_text(encoding="utf-8")
            new = pattern.sub(replace, text)
            if new != text:
                md.write_text(new, encoding="utf-8")
                rewritten += 1
        if rewritten == 0:
            raise RuntimeError(
                f"no {library.name} source anchors rewritten for staging: the "
                f"generated API reference is unreachable"
            )
        rewritten_total += rewritten
    return rewritten_total


restage_lean_hrefs(stage)
restage_api_hrefs(stage)
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
    # The page embeds its engines and corpora; only it and its identity ship.
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
