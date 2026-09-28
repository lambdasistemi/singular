"""Cabal-derived generated API reference: extent, digests, manifest, archive parity.

One helper for every Cabal library whose generated Haddock reference this
site ships (currently the off-chain registry library and the Conformance
library):

* ``manifest [--library NAME] SITE HADDOCK_OUT LIBRARY_ROOT CONFIG_FILES
  [REEXPORT_HADDOCK_OUT]`` (site build time): copy that library's Haddock
  HTML tree into ``SITE/api/<name>`` and write a per-module manifest whose
  source digests are computed from ``LIBRARY_ROOT`` — the same source the
  Haddock run documented — and whose page digests are the actual generated
  pages' bytes.
* ``archive-check ARCHIVE_DIR SITE`` (release-check time): the staged docs
  archive must carry the candidate site's generated API pages for every
  library, member-for-member and byte-for-byte.

The library part (extent parsing, module resolution, page naming) is
imported by ``tools/prepare_docs.py`` (staging links) and
``tools/check_site.py`` (independent checking), so every consumer derives
the same extent from the same Cabal stanza instead of keeping a list.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import sys
import tarfile
from pathlib import Path
from typing import NamedTuple

MANIFEST_NAME = "manifest.json"
STANZA_HEADERS = ("library", "common")
# Stable anchors in the rendered Node ownership guide (docs/offchain-node-
# ownership.md) for the package-private node owners. Existence of each
# rendered anchor is verified against the built site at manifest time, so
# a drifting heading id fails the build instead of publishing a dead link.
PRIVATE_OWNER_GUIDE_ANCHORS = {
    "Singular.Registry.Node.Options": "options-owner",
    "Singular.Registry.Node.Wallet": "wallet-owner",
    "Singular.Registry.Node.Indexer": "indexer-owner",
    "Singular.Registry.Node.Session": "session-owner",
    "Singular.Registry.Node.Confirmation": "confirmation-owner",
    "Singular.Registry.Node.Funding": "funding-owner",
}
# The immutable revision the guide's owner permalinks point at (A-013).
# The six source files are byte-identical between that ancestor and the
# candidate while the frozen digests below match; a changed source refuses
# the build instead of silently repointing a permalink.
PRIVATE_OWNER_PERMALINK_REV = "9a74eae15a3fe75abf7bbdf4969c2d11d7d8e69d"
PRIVATE_OWNER_PERMALINK_URL = (
    "https://github.com/lambdasistemi/singular/blob/"
    + PRIVATE_OWNER_PERMALINK_REV
    + "/offchain/node-internal/Singular/Registry/Node/{owner}.hs"
)
PRIVATE_OWNER_SOURCE_SHA256 = {
    "Singular.Registry.Node.Options": "93a2dbe505b3c48c161b90666341ded8ea79a2c30afdace68156ae725d1ea9ca",
    "Singular.Registry.Node.Wallet": "86e041492d80fd9eafeb7257796bfff483aabd892f07a86a2937ab6b5a0cc165",
    "Singular.Registry.Node.Session": "f0b06d739b99cae43b7891af33f4a580bb1eb2292261843a77f69bac1c810c24",
    "Singular.Registry.Node.Indexer": "b30ba54a390550fb681bdd62e2c1d9a3939c6334e0207355096a4c8a0470a0a4",
    "Singular.Registry.Node.Confirmation": "7cbb8c68723b3788b92db002bbb204f95bc35f63cd835b1a077bc02a9564f9a4",
    "Singular.Registry.Node.Funding": "f6a70bcc695f0762aa2ea73909e73b88d5a7da4815aedb7f541d2069661bb768",
}
class ReferenceLibrary(NamedTuple):
    """One Cabal library whose generated Haddock reference this site ships.

    ``sublibrary`` names the package-private sublibrary that owns the
    implementations behind the public facade's re-exports, when there is
    one; the re-export and private-owner provenance machinery runs only
    for libraries that declare it. ``guide_anchors``, ``permalink_url``
    and ``permalink_source_sha256`` carry that machinery's frozen data.
    """

    name: str
    repo_dir: str
    cabal_file: str
    api_dir: tuple[str, ...]
    index_page: str
    sublibrary: str | None = None
    guide_anchors: dict[str, str] | None = None
    permalink_url: str | None = None
    permalink_source_sha256: dict[str, str] | None = None
    autolinks: tuple[str, ...] = ()


OFFCHAIN = ReferenceLibrary(
    name="singular-registry",
    repo_dir="offchain",
    cabal_file="singular-registry.cabal",
    api_dir=("api", "offchain"),
    index_page="docs/offchain-api-reference",
    sublibrary="node-internal",
    guide_anchors=PRIVATE_OWNER_GUIDE_ANCHORS,
    permalink_url=PRIVATE_OWNER_PERMALINK_URL,
    permalink_source_sha256=PRIVATE_OWNER_SOURCE_SHA256,
    # Prose autolinks Haddock emitted into the generated pages whose target
    # pages do not exist: the "one" multiplicity word, the blueprint
    # "schema" reference and the HEX encoding name.
    autolinks=("one", "schema", "HEX.html"),
)
CONFORMANCE = ReferenceLibrary(
    name="conformance",
    repo_dir="conformance",
    cabal_file="conformance.cabal",
    api_dir=("api", "conformance"),
    index_page="docs/conformance-api-reference",
    # The receipt documentation's "receipt-ROW.json" placeholder: Haddock
    # autolinks the word ROW to a page that does not exist. The text stays
    # visible and only the dead anchor is removed, exactly as the off-chain
    # reference treats its own prose autolinks.
    autolinks=("ROW",),
)
LIBRARIES = {"offchain": OFFCHAIN, "conformance": CONFORMANCE}

# Non-module autolinks may be neutralized to visible text when no local
# target exists; everything else unresolvable stays a library reference and
# must resolve or fail. Which autolinks those are is per library (see
# ReferenceLibrary.autolinks): each entry names a generator-emitted prose
# autolink in that library's pages whose target page does not exist.
DEP_SPAN = '<span class="api-dep">{}</span>'
AUTOLINK_SPAN = '<span class="api-autolink">{}</span>'
# The epic-ruled structural class: a generator-emitted same-page method
# anchor inside an instance Methods list whose target id Haddock never
# emitted. Rendered as visible plain text, counted separately from
# dependency labels and autolinks; any missing fragment outside this
# exact structure stays a library link and fails the check.
INSTANCE_METHOD_SPAN = '<span class="api-instmethod">{}</span>'
METHODS_DIV = '<div class="subs methods">'
EXTERNAL_STYLESHEET = re.compile(r'<link\b[^>]*href="https?://[^"]*"[^>]*/?>', re.I)
EXTERNAL_SCRIPT = re.compile(r'<script\b[^>]*src="https?://[^"]*"[^>]*>\s*</script>', re.I)
MATHJAX_CONFIG = re.compile(r'<script type="text/x-mathjax-config">.*?</script>', re.S)
ANCHOR = re.compile(r'<a\b[^>]*href="([^"]+)"[^>]*>(.*?)</a>', re.S)
ID_ATTR = re.compile(r'id="([^"]+)"')


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _module_name(item: str) -> str:
    """One cabal list entry as a module name (leading comma forms included)."""
    return item.strip().lstrip(",").strip()


def _parse(cabal_file: Path) -> dict:
    """Parse the public library stanza's extent once; loud on an unusable shape.

    The unnamed ``library`` stanza is the public library whose generated
    reference this tool ships. A named ``library <name>`` stanza is a
    package-private sublibrary: it never contributes modules to the extent,
    but its ``hs-source-dirs`` join the resolution roots so a module the
    public library re-exports — whose implementation file may live inside
    the sublibrary — still resolves to exactly one source file.
    """
    lines = cabal_file.read_text(encoding="utf-8").splitlines()
    extent = {"exposed": [], "other": [], "reexported": [], "hs_source_dirs": []}
    stanza = None
    field = None
    for raw in lines:
        if not raw.strip() or raw.lstrip().startswith("--"):
            continue
        if raw[:1] not in (" ", "\t"):
            # A column-zero line: a stanza header word opens a stanza, and
            # any other top-level line (other stanza header or field)
            # closes the previous one. List items are always indented.
            words = raw.split()
            head = words[0].rstrip(":")
            if head == "library" and len(words) == 1:
                stanza = "library"
            elif head == "library":
                stanza = "sublibrary"
            else:
                stanza = head if head in STANZA_HEADERS else None
            field = None
            continue
        item = raw.strip()
        m = re.match(r"^([\w-]+):\s*(.*)$", item)
        if m:
            field, value = m.group(1).lower(), m.group(2).strip()
        else:
            value = item
        if stanza == "sublibrary":
            if field == "hs-source-dirs" and value:
                extent["hs_source_dirs"].extend(value.split())
            continue
        if stanza != "library" or not value:
            continue
        if field == "exposed-modules":
            extent["exposed"].append(_module_name(value))
        elif field == "other-modules":
            extent["other"].append(_module_name(value))
        elif field == "reexported-modules":
            # A re-export keeps a module importable from the public
            # library, so it stays part of the documented surface even
            # though its implementation moved into a sublibrary. Comma
            # list entries may rename (`Orig as Public`); the name a
            # reader imports and compiles against is the extent's name.
            for entry in value.split(","):
                entry = entry.strip()
                if entry:
                    public_name = _module_name(entry.split(" as ")[-1].strip())
                    extent["exposed"].append(public_name)
                    extent["reexported"].append(public_name)
        elif field == "hs-source-dirs":
            extent["hs_source_dirs"].extend(value.split())
    if not extent["exposed"]:
        raise SystemExit(f"api_reference: library stanza exposes no modules: {cabal_file}")
    if not extent["hs_source_dirs"]:
        raise SystemExit(f"api_reference: library stanza declares no hs-source-dirs: {cabal_file}")
    return extent


_EXTENT_CACHE: dict[str, dict] = {}


def parse_cabal_library(library: ReferenceLibrary, root: Path) -> dict:
    key = f"{library.name}:{root.resolve()}"
    if key not in _EXTENT_CACHE:
        _EXTENT_CACHE[key] = _parse(root / library.cabal_file)
    return _EXTENT_CACHE[key]


def library_modules(library: ReferenceLibrary, root: Path) -> list[str]:
    """Sorted complete library module extent (exposed, other, re-exported)."""
    extent = parse_cabal_library(library, root)
    modules = sorted(set(extent["exposed"]) | set(extent["other"]))
    if not modules:
        raise SystemExit("api_reference: empty library extent")
    return modules


def module_source(library: ReferenceLibrary, root: Path, module: str) -> Path:
    """Resolve one module through every declared hs-source-dir (exactly one)."""
    extent = parse_cabal_library(library, root)
    rel = Path(*module.split(".")).with_suffix(".hs")
    hits = [d / rel for d in extent["hs_source_dirs"] if (root / d / rel).is_file()]
    if len(hits) != 1:
        raise SystemExit(
            f"api_reference: module {module} resolves to {len(hits)} source files "
            f"({[str(h) for h in hits]}) under {extent['hs_source_dirs']}"
        )
    return root / hits[0]


def module_page_name(module: str) -> str:
    """Haddock module page: dots become dashes (verified against the tree)."""
    return module.replace(".", "-") + ".html"


def source_page_name(module: str) -> str:
    """Hyperlinked source page under src/: dots are kept."""
    return module + ".html"


def find_haddock_root(haddock_out: Path, extent: list[str]) -> Path:
    """Locate the Haddock HTML root by a known module page, not convention.

    Exactly one candidate must exist; zero or many is a loud failure, so a
    changed Haddock layout cannot silently pass an empty or ambiguous
    reference through.
    """
    probe = module_page_name(extent[0])
    hits = sorted({p.parent for p in haddock_out.rglob(probe) if p.is_file()})
    if len(hits) != 1:
        raise SystemExit(
            f"api_reference: expected exactly one Haddock html root carrying {probe}, "
            f"found {hits} under {haddock_out}"
        )
    return hits[0]


def parse_package_db(config_files: Path) -> list[dict]:
    """Positive, typed module ownership from this build's package db.

    Every ``*.conf`` under the Haddock build's package.conf.d declares a
    package's exposed and hidden modules, and — for sublibrary records —
    the owning package and library through the typed fields
    ``package-name`` and ``lib-name``. Each record is returned with its
    typed identity and its module set; membership in a record is the
    existence-independent evidence for ownership, and no target href is
    ever consulted. Callers decide dependency-ness from the record's
    identity, never by subtracting names from one flat set.
    """
    dbs = sorted(config_files.glob("lib/ghc-*/lib/package.conf.d"))
    if len(dbs) != 1:
        raise SystemExit(
            f"api_reference: expected one package.conf.d under {config_files}, found {dbs}"
        )
    records: list[dict] = []
    for conf in sorted(dbs[0].glob("*.conf")):
        record: dict = {"package": None, "lib": None, "modules": set(), "conf": conf.name}
        field = None
        for raw in conf.read_text(errors="replace").splitlines():
            if not raw.strip():
                field = None
                continue
            m = re.match(r"^(package-name|lib-name|exposed-modules|hidden-modules):\s*(.*)$", raw)
            if m:
                field, value = m.group(1), m.group(2).strip()
            elif raw.startswith(" ") or raw.startswith("\t"):
                value = raw.strip()
            else:
                field = None
                continue
            if field == "package-name" and value:
                record["package"] = value
            elif field == "lib-name" and value:
                record["lib"] = value
            elif field in ("exposed-modules", "hidden-modules") and value:
                record["modules"].update(value.replace(",", " ").split())
        if record["modules"]:
            records.append(record)
    if not records:
        raise SystemExit("api_reference: package db inventory is empty")
    return records


def _module_of_page(filename: str) -> str:
    return re.sub(r"\.html$", "", filename).replace("-", ".")


def transform_tree(
    api_root: Path,
    extent: list[str],
    dep_modules: set[str],
    library_root: Path,
    private_owners: dict[str, dict] | None = None,
    enumerated_autolinks: tuple[str, ...] = (),
) -> dict:
    """Repair same-library links, neutralize proven dependency links, and
    strip external assets from the copied generated tree.

    Classification is decided before any target lookup: a title in the
    dependency inventory is a dependency label, a title naming this
    library's modules is a library reference to repair (alias, qualified
    name, or fragment), and only the enumerated non-module autolinks may
    become visible unlinked text. Anything else is a malformed library
    reference and fails the build loudly.
    """
    library_pages = {p.name: p for p in api_root.glob("*.html")}
    extent_pages = {module_page_name(m) for m in extent}
    # Fragment anchors live on module pages and hyperlinked source pages;
    # index pages carry their own entry ids and never own a referenced
    # fragment, so they are excluded from the map and from owner search.
    page_ids = {
        p.relative_to(api_root).as_posix(): set(ID_ATTR.findall(p.read_text(errors="replace")))
        for p in [*api_root.glob("*.html"), *api_root.glob("src/*.html")]
        if p.name in extent_pages or p.parent.name == "src"
    }
    page_of_module = {m: module_page_name(m) for m in extent}

    def resolve_library(title: str, frag: str | None) -> tuple[str, str | None] | None:
        """Resolve an aliased or qualified same-library reference.

        Returns (page, fragment-or-None) for the real target, or None when
        the title names no module of this library. Raises loudly on an
        ambiguous alias. A qualified name whose last component completes
        exactly one module is a module reference: its bogus identifier
        fragment is dropped, because the docstring named a module.
        """
        alias = title.replace("-", ".")
        candidates = {
            m for m in extent if m == alias or m.endswith("." + alias) or m.startswith(alias + ".")
        }
        if frag:
            component = frag.split(":", 1)[1] if ":" in frag else frag
            qualified = alias + "." + component
            if qualified in page_of_module:
                return page_of_module[qualified], None
            carrying = {
                m for m in candidates if page_of_module[m] in page_ids
                and frag in page_ids[page_of_module[m]]
            }
            if len(carrying) == 1:
                return page_of_module[carrying.pop()], frag
            if len(candidates) == 1:
                page = page_of_module[next(iter(candidates))]
                if page in page_ids and frag in page_ids[page]:
                    return page, frag
                return None
            if len(candidates) > 1:
                raise SystemExit(
                    f"api_reference: ambiguous same-library reference {title}#{frag}: "
                    f"candidates {sorted(candidates)}"
                )
            return None
        if len(candidates) == 1:
            return page_of_module[next(iter(candidates))], None
        if len(candidates) > 1:
            raise SystemExit(
                f"api_reference: ambiguous same-library reference {title}: {sorted(candidates)}"
            )
        return None

    stats = {
        "dependency": 0,
        "autolink": 0,
        "external_assets": 0,
        "library_repairs": [],
        "instance_method": 0,
        "private_owner": {m: 0 for m in (private_owners or {})},
    }

    def instance_details_intervals(page_text: str) -> list[tuple[int, int]]:
        """Balanced (open, close) spans of every instance details block.

        A first-close search would mistake a nested associated-type details'
        closing tag for the enclosing instance's; matching opens and closes
        with a stack gives each ``details[id^="i:"]`` block its true span,
        nested ``i:if:`` blocks included.
        """
        events = []
        for m in re.finditer(r"<details\b[^>]*>|</details>", page_text):
            events.append((m.start(), m.end(), m.group(0).startswith("<details")))
        stack, spans = [], []
        for start, endp, is_open in events:
            if is_open:
                stack.append((start, endp))
            elif stack:
                open_start, open_end = stack.pop()
                if 'id="i:' in page_text[open_start:open_end]:
                    spans.append((open_start, endp))
        return spans

    def inside_instance_methods(page_text: str, pos: int, intervals: list[tuple[int, int]]) -> bool:
        """Positively inside an instance Methods list.

        The epic ruling covers an anchor only when a ``div.subs.methods``
        contains it (nested div counting) AND an instance details block —
        balanced over nested details — either still contains the position,
        or truly closed immediately before the Methods list with only
        enclosing closing tags between: Haddock's immediate-sibling
        rendering of an instance's Methods. Anything else is not covered.
        """
        div = page_text.rfind(METHODS_DIV, 0, pos)
        if div < 0:
            return False
        depth = 1
        i = div + len(METHODS_DIV)
        while i < pos:
            nxt_open = page_text.find("<div", i + 1, pos)
            nxt_close = page_text.find("</div>", i + 1, pos)
            if nxt_open >= 0 and (nxt_close < 0 or nxt_open < nxt_close):
                depth += 1
                i = nxt_open
            elif nxt_close >= 0:
                depth -= 1
                if depth == 0:
                    return False
                i = nxt_close
            else:
                break
        if depth <= 0:
            return False
        for open_start, close in intervals:
            if open_start < pos < close:
                return True
        prior = max((close for _, close in intervals if close <= div), default=-1)
        if prior < 0:
            return False
        between = page_text[prior:div]
        return bool(
            re.fullmatch(r"(?:\s|</td>|</tr>|</table>|</div>|</summary>|</p>|</details>)*", between)
        )

    def classify_missing_fragment(page_name: str, href: str, frag: str, plain: str, original: str, page_text: str = "", match_start: int = 0):
        """A fragment absent from the page that should carry it, with no
        positively proven class.

        Every authorized disposition happens before this point: the
        balanced instance-method structural class, the F1 alias and
        qualified-name resolver, the doc-index module-cell repair, and the
        dependency-module/store-href inventory classes. A generic
        unique-owner redirect and dependency-class fallbacks were removed
        (A-010): they silently transformed outside-class broken fragments.
        Everything reaching here fails staging loudly.
        """
        raise SystemExit(
            f"API_LINK_MISSING scope=library staging {page_name}: {href}"
        )

    def rewrite(match: re.Match, page_name: str, page_text: str, intervals: list[tuple[int, int]]) -> str:
        href, label = match.group(1), match.group(2)
        plain = re.sub(r"<[^>]+>", "", label).strip() or href
        original = match.group(0)
        if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", href) and not href.startswith("file://"):
            return original
        if href.startswith("file://"):
            module = _module_of_page(href.partition("#")[0].rsplit("/", 1)[-1])
            if module in dep_modules:
                stats["dependency"] += 1
                return DEP_SPAN.format(plain)
            if module in set(extent):
                raise SystemExit(
                    f"api_reference: store href to this library's own doc in {page_name}: {href}"
                )
            raise SystemExit(
                f"api_reference: store href with unproven ownership in {page_name}: {href}"
            )
        path, _, frag = href.partition("#")
        if not path:
            # A same-page reference: its fragment is checked against this
            # page's own ids, never skipped. The epic-ruled structural class
            # — a generator-emitted #v: method anchor inside an instance
            # Methods list whose id was never emitted — becomes visible
            # plain text, counted separately; everything else keeps the full
            # classification discipline.
            if not frag or frag in page_ids.get(page_name, ()):
                return original
            if (
                frag.startswith("v:")
                and inside_instance_methods(page_text, match.start(), intervals)
            ):
                stats["instance_method"] += 1
                return INSTANCE_METHOD_SPAN.format(plain)
            return classify_missing_fragment(
                page_name, href, frag, plain, original, page_text, match.start()
            )
        target_rel = (Path(page_name).parent / path).as_posix()
        named = re.sub(r"\.html$", "", path.rsplit("/", 1)[-1]).replace("-", ".")
        if named in (private_owners or {}):
            # A generated link naming a package-private owner. Only the
            # plain module-page shape may name one; anything else — a
            # source-page path, a nested directory, an alias, or any
            # fragment, which the guide's owner anchor cannot preserve
            # the meaning of — is an unexpected shape and fails loudly
            # rather than being repaired or neutralized. The visible
            # label is preserved and the destination becomes the owner's
            # checked guide anchor.
            if target_rel != module_page_name(named) or frag:
                raise SystemExit(
                    f"api_reference: unexpected private-owner link shape in "
                    f"{page_name}: {href}"
                )
            stats["private_owner"][named] += 1
            return original.replace(href, private_owners[named]["href"], 1)
        target = api_root / target_rel
        if target.exists():
            if frag and frag not in page_ids.get(target_rel, ()):
                # The generated doc-index module cell: the identifier is
                # plain text and the anchor is the module label, whose title
                # names a library module and whose target is that module's
                # page. Positively recognized, the link is repaired to the
                # bundled module page without the bogus identifier fragment
                # and stays a clickable module link — never a neutralization.
                titled = original
                title_m = re.search(r'title="([^"]+)"', titled)
                named_module = (title_m.group(1) if title_m else "").strip()
                cell = page_text.rfind('<td class="module">', 0, match.start())
                cell_close = page_text.find("</td>", match.start())
                if (
                    title_m
                    and named_module in page_of_module
                    and page_of_module[named_module] == path
                    and cell >= 0
                    and cell < match.start()
                    and (cell_close < 0 or cell_close > match.start())
                ):
                    stats["library_repairs"].append(
                        {"page": page_name, "from": href, "to": path}
                    )
                    return original.replace(href, path, 1)
                return classify_missing_fragment(
                    page_name, href, frag, plain, original, page_text, match.start()
                )
            return original
        title = re.sub(r"\.html$", "", path.rsplit("/", 1)[-1])
        module = title.replace("-", ".")
        if module in dep_modules and module not in set(extent):
            stats["dependency"] += 1
            return DEP_SPAN.format(plain)
        resolved = resolve_library(title, frag or None)
        if resolved is not None:
            page, new_frag = resolved
            replacement = page + (("#" + new_frag) if new_frag else "")
            stats["library_repairs"].append(
                {"page": page_name, "from": href, "to": replacement}
            )
            return original.replace(href, replacement, 1)
        if path in enumerated_autolinks or title in enumerated_autolinks:
            stats["autolink"] += 1
            return AUTOLINK_SPAN.format(plain)
        raise SystemExit(
            f"api_reference: unresolvable same-library link in {page_name}: {href}"
        )

    for page in sorted(api_root.rglob("*.html")):
        text = page.read_text(errors="replace")
        text, n_config = MATHJAX_CONFIG.subn("", text)
        text, n_css = EXTERNAL_STYLESHEET.subn("", text)
        text, n_js = EXTERNAL_SCRIPT.subn("", text)
        stats["external_assets"] += n_config + n_css + n_js
        rel = page.relative_to(api_root).as_posix()
        intervals = instance_details_intervals(text)
        text = ANCHOR.sub(lambda m: rewrite(m, rel, text, intervals), text)
        page.write_text(text)
    return stats


def _private_owner_links(
    library: ReferenceLibrary,
    site: Path,
    db_records: list[dict],
    reexported: list[str],
    library_root: Path,
) -> dict[str, dict]:
    """Package-private owners of a library that declares a sublibrary.

    Modules of the one candidate-owned sublibrary the public library does
    not re-export. Each must have exactly one candidate-owned record and no
    other owner, a rendered guide anchor, and a real source file with the
    frozen digest, all verified here — the guide destination is checked,
    never assumed. Each expected permalink is bound to its own rendered
    owner entry: the span between this owner's anchor and the next rendered
    owner anchor must carry exactly that owner's source link — no other
    owner's URL — so a swapped or duplicated link is refused even though
    every URL occurs somewhere on the page. Anchors are ordered by their
    rendered position, so the guide's authored entry order is free.
    """
    candidate_lib = library.name
    candidate_sublib = library.sublibrary

    def is_candidate_sublib(record: dict) -> bool:
        return (
            record["package"] == candidate_lib
            and record["lib"] == candidate_sublib
        )

    sublib_records = [r for r in db_records if is_candidate_sublib(r)]
    if len(sublib_records) != 1:
        raise SystemExit(
            "api_reference: expected exactly one candidate-owned "
            f"{candidate_lib}/{candidate_sublib} package-db record, found "
            f"{len(sublib_records)}"
        )
    private_modules = sorted(set(sublib_records[0]["modules"]) - set(reexported))
    private_owners: dict[str, dict] = {}
    guide_page_rel = "docs/offchain-node-ownership/index.html"
    guide_page = site / guide_page_rel
    guide_text = ""
    if private_modules:
        if not guide_page.is_file():
            raise SystemExit(
                f"api_reference: rendered owner guide page missing for private "
                f"owners: {guide_page}"
            )
        guide_text = guide_page.read_text(errors="replace")
    for module in private_modules:
        anchor = (library.guide_anchors or {}).get(module)
        if anchor is None:
            raise SystemExit(
                f"api_reference: no guide anchor mapping for private owner {module}"
            )
        owners = [r for r in db_records if module in r["modules"]]
        same = [r for r in owners if is_candidate_sublib(r)]
        others = [r for r in owners if not is_candidate_sublib(r)]
        if len(same) != 1 or others:
            raise SystemExit(
                f"api_reference: private owner {module} requires exactly one "
                f"candidate-owned {candidate_lib}/{candidate_sublib} record and "
                f"no other owner; owners: "
                f"{[(r['package'], r['lib'], r['conf']) for r in owners]}"
            )
        if f'id="{anchor}"' not in guide_text:
            raise SystemExit(
                f"api_reference: rendered guide anchor missing for private "
                f"owner {module}: #{anchor} on {guide_page_rel}"
            )
        owner = module.rsplit(".", 1)[-1]
        expected_url = (library.permalink_url or "").format(owner=owner)
        private_owners[module] = {
            "href": "../../" + guide_page_rel + "#" + anchor,
            "anchor": anchor,
            "source": None,
            "source_sha256": None,
            "permalink": expected_url,
        }
    located = []
    for module in private_modules:
        anchor = private_owners[module]["anchor"]
        anchor_token = f'id="{anchor}"'
        occurrences = guide_text.count(anchor_token)
        if occurrences < 1:
            raise SystemExit(
                f"api_reference: rendered guide anchor missing for private "
                f"owner {module}: #{anchor} on {guide_page_rel}"
            )
        if occurrences > 1:
            raise SystemExit(
                f"api_reference: ambiguous rendered guide anchor for private "
                f"owner {module}: #{anchor} occurs {occurrences} times on "
                f"{guide_page_rel}"
            )
        located.append((guide_text.find(anchor_token), module, anchor, private_owners[module]["permalink"]))
    located.sort()
    for i, (pos, module, anchor, url) in enumerate(located):
        end = located[i + 1][0] if i + 1 < len(located) else len(guide_text)
        entry = guide_text[pos:end]
        url_token = f'href="{url}"'
        if entry.count(url_token) != 1:
            raise SystemExit(
                f"api_reference: owner permalink missing, wrong or duplicated "
                f"for private owner {module}: expected exactly one {url} "
                f"bound to entry #{anchor} on {guide_page_rel}"
            )
        for _, other_module, _, other_url in located:
            if other_module != module and f'href="{other_url}"' in entry:
                raise SystemExit(
                    f"api_reference: ambiguous owner entry #{anchor} on "
                    f"{guide_page_rel}: another owner's permalink is bound to "
                    f"{module}'s entry"
                )
        source = module_source(library, library_root, module)
        digest = sha256_file(source)
        frozen = (library.permalink_source_sha256 or {}).get(module)
        if frozen is None or digest != frozen:
            raise SystemExit(
                f"api_reference: private owner source digest mismatch for "
                f"{module}: {source} sha256={digest} expected={frozen}"
            )
        private_owners[module]["source"] = source.relative_to(library_root).as_posix()
        private_owners[module]["source_sha256"] = digest
    return private_owners


def copy_reference(
    library: ReferenceLibrary,
    site: Path,
    haddock_out: Path,
    library_root: Path,
    config_files: Path,
    reexport_haddock_out: Path | None = None,
) -> dict:
    """Copy one library's generated tree into the site and build the manifest.

    When the public library re-exports modules whose implementations live
    in a package-private sublibrary, those re-exports' generated pages come
    from the sublibrary's own Haddock tree: ``reexport_haddock_out``. Only
    the re-exported modules' page pairs are taken from it — nothing else —
    and each must exist there; a missing page fails the build rather than
    publishing a silent gap. The private owners that are not re-exported
    never enter the public reference. Both mechanisms run only for a
    library that declares a sublibrary; the Conformance library has none,
    so its manifest is the plain extent-and-digest binding.
    """
    extent = parse_cabal_library(library, library_root)
    modules = sorted(set(extent["exposed"]) | set(extent["other"]))
    reexported = sorted(set(extent["reexported"]) & set(modules))
    html_root = find_haddock_root(haddock_out, modules)
    api_root = site.joinpath(*library.api_dir)
    if api_root.exists():
        raise SystemExit(f"api_reference: {api_root} already exists; refusing to mix trees")
    api_root.mkdir(parents=True)
    for entry in sorted(html_root.iterdir()):
        target = api_root / entry.name
        if entry.is_dir():
            shutil.copytree(entry, target)
        else:
            shutil.copyfile(entry, target)
    # Haddock store outputs are read-only; the tree below is ours to repair.
    for path in (api_root, *api_root.rglob("*")):
        os.chmod(path, path.stat().st_mode | stat.S_IWUSR)
    if reexported:
        if reexport_haddock_out is None:
            raise SystemExit(
                f"api_reference: the public library re-exports {reexported} "
                "but no re-export Haddock tree was given"
            )
        sub_html_root = find_haddock_root(reexport_haddock_out, [reexported[0]])
        for module in reexported:
            for page in (module_page_name(module), "src/" + source_page_name(module)):
                origin = sub_html_root / page
                if not origin.is_file():
                    raise SystemExit(
                        f"api_reference: re-export page missing from the sublibrary "
                        f"Haddock tree for {module}: {origin}"
                    )
                target = api_root / page
                if target.exists():
                    raise SystemExit(
                        f"api_reference: refusing to mix trees at {page}: the public "
                        "library tree already provides it"
                    )
                shutil.copyfile(origin, target)
    records = []
    for module in modules:
        source = module_source(library, library_root, module)
        module_page = api_root / module_page_name(module)
        source_page = api_root / "src" / source_page_name(module)
        for page in (module_page, source_page):
            if not page.is_file():
                raise SystemExit(f"api_reference: generated page missing for {module}: {page}")
        records.append(
            {
                "module": module,
                "source": source.relative_to(library_root).as_posix(),
                "source_sha256": sha256_file(source),
                "module_page": module_page.relative_to(api_root).as_posix(),
                "source_page": source_page.relative_to(api_root).as_posix(),
            }
        )
    db_records = parse_package_db(config_files)
    candidate_lib = library.name
    candidate_sublib = library.sublibrary

    def is_candidate_sublib(record: dict) -> bool:
        return (
            library.sublibrary is not None
            and record["package"] == candidate_lib
            and record["lib"] == candidate_sublib
        )

    # Each re-exported module is a same-package public re-export only when
    # the public stanza names it (the extent's ``reexported``), exactly one
    # candidate-owned sublibrary record owns it, and no other record —
    # candidate or external — claims it. Anything else is a missing,
    # ambiguous or externally owned re-export and fails loudly.
    for module in reexported:
        owners = [r for r in db_records if module in r["modules"]]
        same = [r for r in owners if is_candidate_sublib(r)]
        others = [r for r in owners if not is_candidate_sublib(r)]
        if len(same) != 1 or others:
            raise SystemExit(
                f"api_reference: re-exported module {module} requires exactly one "
                f"candidate-owned {candidate_lib}/{candidate_sublib} record and no "
                f"other owner; owners: "
                f"{[(r['package'], r['lib'], r['conf']) for r in owners]}"
            )

    # Dependency modules are decided per record, from each record's typed
    # identity: a candidate-owned sublibrary record is the same package,
    # not a dependency; every other record contributes all of its modules.
    # No name is subtracted from a flat set and no candidate-wide exemption
    # exists. A library without a sublibrary owns no record, so every
    # record is a dependency.
    dep_modules: set[str] = set()
    for record in db_records:
        if is_candidate_sublib(record):
            continue
        dep_modules |= record["modules"]
    overlap = sorted(set(modules) & dep_modules)
    if overlap:
        raise SystemExit(
            f"api_reference: package db claims library modules as dependencies: {overlap[:5]}"
        )

    private_owners: dict[str, dict] = {}
    if library.sublibrary is not None:
        private_owners = _private_owner_links(
            library, site, db_records, reexported, library_root
        )
    transform = transform_tree(
        api_root, modules, dep_modules, library_root, private_owners, library.autolinks
    )
    for record in records:
        record["module_page_sha256"] = sha256_file(api_root / record["module_page"])
        record["source_page_sha256"] = sha256_file(api_root / record["source_page"])
    manifest = {
        "package": library.name,
        "generator": "tools/api_reference.py",
        "other_modules": extent["other"],
        "modules": records,
        "package_inventory": {
            "source": "library-haddock configFiles package.conf.d",
            "package_db_records": len(db_records),
            "dependency_module_count": len(dep_modules),
            "dependency_modules": sorted(dep_modules),
        },
        "neutralization": {
            "dependency": transform["dependency"],
            "instance_method": transform["instance_method"],
            "autolink": transform["autolink"],
            "external_assets": transform["external_assets"],
            "library_repairs": transform["library_repairs"],
        },
        "private_owner_links": {
            module: {
                "guide_page": "docs/offchain-node-ownership/index.html",
                "anchor": info["anchor"],
                "source": info["source"],
                "source_sha256": info["source_sha256"],
                "permalink": info["permalink"],
                "rewrites": transform["private_owner"][module],
            }
            for module, info in private_owners.items()
        },
    }
    (api_root / MANIFEST_NAME).write_text(
        json.dumps(manifest, indent=2, sort_keys=False) + "\n", encoding="utf-8"
    )
    return manifest


def api_file_inventory(root: Path) -> dict[str, str]:
    """Every file under an api root: relative posix path to its sha256."""
    return {
        path.relative_to(root).as_posix(): sha256_file(path)
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


def archive_check(archive_dir: Path, site: Path) -> None:
    """The staged docs archive carries every library's API pages, exactly."""
    bundles = sorted(archive_dir.glob("singular-docs-*.tar.gz"))
    if len(bundles) != 1:
        raise SystemExit(f"api_reference: expected one docs archive, found {bundles}")
    archived_by_library: dict[str, dict[str, str]] = {name: {} for name in LIBRARIES}
    with tarfile.open(bundles[0]) as bundle:
        for member in bundle.getmembers():
            name = member.name.removeprefix("./")
            for key, library in LIBRARIES.items():
                prefix = "/".join(library.api_dir) + "/"
                if name.startswith(prefix) and member.isfile():
                    extracted = bundle.extractfile(member)
                    assert extracted is not None, f"unreadable archive member: {name}"
                    archived_by_library[key][name[len(prefix):]] = hashlib.sha256(
                        extracted.read()
                    ).hexdigest()
    members = 0
    for key, library in LIBRARIES.items():
        site_files = api_file_inventory(site.joinpath(*library.api_dir))
        if not site_files:
            raise SystemExit(
                f"api_reference: candidate site carries no generated API pages "
                f"for {library.name}"
            )
        archived = archived_by_library[key]
        missing = sorted(set(site_files) - set(archived))
        if missing:
            detail = f"{missing[0]} (and {len(missing) - 1} more)" if len(missing) > 1 else missing[0]
            print(f"API_ARCHIVE_MISSING library={library.name} {detail}", file=sys.stderr)
            raise SystemExit(1)
        extra = sorted(set(archived) - set(site_files))
        if extra:
            print(f"API_ARCHIVE_EXTRA library={library.name} {extra[0]}", file=sys.stderr)
            raise SystemExit(1)
        drifted = sorted(name for name in site_files if archived[name] != site_files[name])
        if drifted:
            print(f"API_ARCHIVE_BYTES library={library.name} {drifted[0]}", file=sys.stderr)
            raise SystemExit(1)
        members += len(archived)
    print(f"api-archive-check libraries={len(LIBRARIES)} members={members}")


def main(argv: list[str]) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)
    manifest = sub.add_parser("manifest", help="copy the Haddock tree and write the manifest")
    manifest.add_argument(
        "--library",
        choices=sorted(LIBRARIES),
        default="offchain",
        help="which Cabal library's reference to stage",
    )
    manifest.add_argument("site")
    manifest.add_argument("haddock_out")
    manifest.add_argument("library_root")
    manifest.add_argument("config_files")
    manifest.add_argument(
        "reexport_haddock_out",
        nargs="?",
        default=None,
        help="Haddock tree of the sublibrary owning the re-exported implementations",
    )
    archive = sub.add_parser("archive-check", help="compare the staged archive's API pages with the site")
    archive.add_argument("archive_dir")
    archive.add_argument("site")
    args = parser.parse_args(argv)
    if args.mode == "manifest":
        built = copy_reference(
            LIBRARIES[args.library],
            Path(args.site),
            Path(args.haddock_out),
            Path(args.library_root),
            Path(args.config_files),
            Path(args.reexport_haddock_out) if args.reexport_haddock_out else None,
        )
        neutral = built["neutralization"]
        print(
            f"api-reference library={args.library} modules={len(built['modules'])} "
            f"other-modules={len(built['other_modules'])} "
            f"dependency-modules={built['package_inventory']['dependency_module_count']} "
            f"neutralized-dependency={neutral['dependency']} "
            f"neutralized-instance-method={neutral['instance_method']} "
            f"neutralized-autolink={neutral['autolink']} "
            f"library-repairs={len(neutral['library_repairs'])} "
            f"external-assets-stripped={neutral['external_assets']}"
        )
    else:
        archive_check(Path(args.archive_dir), Path(args.site))


if __name__ == "__main__":
    main(sys.argv[1:])
