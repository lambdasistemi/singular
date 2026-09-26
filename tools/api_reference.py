"""Cabal-derived generated API reference: extent, digests, manifest, archive parity.

One helper for the generated off-chain Haddock reference:

* ``manifest SITE HADDOCK_OUT OFFCHAIN_ROOT`` (site build time): copy the
  Haddock HTML tree into ``SITE/api/offchain`` and write a per-module
  manifest whose source digests are computed from ``OFFCHAIN_ROOT`` — the
  same off-chain flake input Haddock documented — and whose page digests
  are the actual generated pages' bytes.
* ``archive-check ARCHIVE_DIR SITE`` (release-check time): the staged docs
  archive must carry the candidate site's generated API pages,
  member-for-member and byte-for-byte.

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

API_DIR = ("api", "offchain")
MANIFEST_NAME = "manifest.json"
STANZA_HEADERS = ("library", "common")
# Non-module autolinks the A-006 repair may neutralize to visible text when
# no local target exists; everything else unresolvable stays a library
# reference and must resolve or fail.
ENUMERATED_AUTOLINKS = ("one", "schema", "HEX.html")
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


def _parse(cabal_file: Path) -> dict:
    """Parse the library stanza's extent once; loud on an unusable shape."""
    lines = cabal_file.read_text(encoding="utf-8").splitlines()
    extent = {"exposed": [], "other": [], "hs_source_dirs": []}
    stanza = None
    field = None
    for raw in lines:
        if not raw.strip() or raw.lstrip().startswith("--"):
            continue
        if raw[:1] not in (" ", "\t"):
            # A column-zero line: a stanza header word opens a stanza, and
            # any other top-level line (other stanza header or field)
            # closes the previous one. List items are always indented.
            head = raw.split()[0].rstrip(":")
            stanza = head if head in STANZA_HEADERS else None
            field = None
            continue
        item = raw.strip()
        m = re.match(r"^([\w-]+):\s*(.*)$", item)
        if m:
            field, value = m.group(1).lower(), m.group(2).strip()
        else:
            value = item
        if stanza != "library" or not value:
            continue
        if field == "exposed-modules":
            extent["exposed"].append(value)
        elif field == "other-modules":
            extent["other"].append(value)
        elif field == "hs-source-dirs":
            extent["hs_source_dirs"].extend(value.split())
    if not extent["exposed"]:
        raise SystemExit(f"api_reference: library stanza exposes no modules: {cabal_file}")
    if not extent["hs_source_dirs"]:
        raise SystemExit(f"api_reference: library stanza declares no hs-source-dirs: {cabal_file}")
    return extent


_EXTENT_CACHE: dict[str, dict] = {}


def parse_cabal_library(offchain_root: Path) -> dict:
    key = str(offchain_root.resolve())
    if key not in _EXTENT_CACHE:
        _EXTENT_CACHE[key] = _parse(offchain_root / "singular-registry.cabal")
    return _EXTENT_CACHE[key]


def library_modules(offchain_root: Path) -> list[str]:
    """Sorted complete library module extent (exposed plus other)."""
    extent = parse_cabal_library(offchain_root)
    modules = sorted(set(extent["exposed"]) | set(extent["other"]))
    if not modules:
        raise SystemExit("api_reference: empty library extent")
    return modules


def module_source(offchain_root: Path, module: str) -> Path:
    """Resolve one module through every declared hs-source-dir (exactly one)."""
    extent = parse_cabal_library(offchain_root)
    rel = Path(*module.split(".")).with_suffix(".hs")
    hits = [d / rel for d in extent["hs_source_dirs"] if (offchain_root / d / rel).is_file()]
    if len(hits) != 1:
        raise SystemExit(
            f"api_reference: module {module} resolves to {len(hits)} source files "
            f"({[str(h) for h in hits]}) under {extent['hs_source_dirs']}"
        )
    return offchain_root / hits[0]


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


def parse_package_db(config_files: Path) -> set[str]:
    """Positive dependency module ownership from this build's package db.

    Every *.conf under the Haddock build's package.conf.d declares its
    package's exposed and hidden modules. Membership in that inventory is
    the existence-independent evidence a missing generated link is a
    dependency reference: no href target is ever consulted.
    """
    dbs = sorted(config_files.glob("lib/ghc-*/lib/package.conf.d"))
    if len(dbs) != 1:
        raise SystemExit(
            f"api_reference: expected one package.conf.d under {config_files}, found {dbs}"
        )
    modules: set[str] = set()
    field = None
    for conf in sorted(dbs[0].glob("*.conf")):
        for raw in conf.read_text(errors="replace").splitlines():
            if not raw.strip():
                field = None
                continue
            m = re.match(r"^(exposed-modules|hidden-modules):\s*(.*)$", raw)
            if m:
                field, value = m.group(1), m.group(2).strip()
            elif raw.startswith(" ") or raw.startswith("\t"):
                value = raw.strip()
            else:
                field = None
                continue
            if field:
                modules.update(value.replace(",", " ").split())
    if not modules:
        raise SystemExit("api_reference: package db inventory is empty")
    return modules


def _module_of_page(filename: str) -> str:
    return re.sub(r"\.html$", "", filename).replace("-", ".")


def transform_tree(api_root: Path, extent: list[str], dep_modules: set[str], offchain_root: Path) -> dict:
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

    stats = {"dependency": 0, "autolink": 0, "external_assets": 0, "library_repairs": [], "instance_method": 0}

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
        if path in ENUMERATED_AUTOLINKS or title in ENUMERATED_AUTOLINKS:
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


def copy_reference(site: Path, haddock_out: Path, offchain_root: Path, config_files: Path) -> dict:
    """Copy the generated tree into the site and build the manifest."""
    extent = parse_cabal_library(offchain_root)
    modules = sorted(set(extent["exposed"]) | set(extent["other"]))
    html_root = find_haddock_root(haddock_out, modules)
    api_root = site.joinpath(*API_DIR)
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
    records = []
    for module in modules:
        source = module_source(offchain_root, module)
        module_page = api_root / module_page_name(module)
        source_page = api_root / "src" / source_page_name(module)
        for page in (module_page, source_page):
            if not page.is_file():
                raise SystemExit(f"api_reference: generated page missing for {module}: {page}")
        records.append(
            {
                "module": module,
                "source": source.relative_to(offchain_root).as_posix(),
                "source_sha256": sha256_file(source),
                "module_page": module_page.relative_to(api_root).as_posix(),
                "source_page": source_page.relative_to(api_root).as_posix(),
            }
        )
    dep_modules = parse_package_db(config_files)
    overlap = sorted(set(modules) & dep_modules)
    if overlap:
        raise SystemExit(
            f"api_reference: package db claims library modules as dependencies: {overlap[:5]}"
        )
    transform = transform_tree(api_root, modules, dep_modules, offchain_root)
    for record in records:
        record["module_page_sha256"] = sha256_file(api_root / record["module_page"])
        record["source_page_sha256"] = sha256_file(api_root / record["source_page"])
    manifest = {
        "package": "singular-registry",
        "generator": "tools/api_reference.py",
        "other_modules": extent["other"],
        "modules": records,
        "package_inventory": {
            "source": "library-haddock configFiles package.conf.d",
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
    """The staged docs archive carries the candidate API pages, exactly."""
    bundles = sorted(archive_dir.glob("singular-docs-*.tar.gz"))
    if len(bundles) != 1:
        raise SystemExit(f"api_reference: expected one docs archive, found {bundles}")
    site_files = api_file_inventory(site.joinpath(*API_DIR))
    if not site_files:
        raise SystemExit("api_reference: candidate site carries no generated API pages")
    archived: dict[str, str] = {}
    with tarfile.open(bundles[0]) as bundle:
        for member in bundle.getmembers():
            name = member.name.removeprefix("./")
            prefix = "/".join(API_DIR) + "/"
            if name.startswith(prefix) and member.isfile():
                extracted = bundle.extractfile(member)
                assert extracted is not None, f"unreadable archive member: {name}"
                archived[name[len(prefix):]] = hashlib.sha256(extracted.read()).hexdigest()
    missing = sorted(set(site_files) - set(archived))
    if missing:
        detail = f"{missing[0]} (and {len(missing) - 1} more)" if len(missing) > 1 else missing[0]
        print(f"API_ARCHIVE_MISSING {detail}", file=sys.stderr)
        raise SystemExit(1)
    extra = sorted(set(archived) - set(site_files))
    if extra:
        print(f"API_ARCHIVE_EXTRA {extra[0]}", file=sys.stderr)
        raise SystemExit(1)
    drifted = sorted(name for name in site_files if archived[name] != site_files[name])
    if drifted:
        print(f"API_ARCHIVE_BYTES {drifted[0]}", file=sys.stderr)
        raise SystemExit(1)
    print(f"api-archive-check members={len(archived)}")


def main(argv: list[str]) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)
    manifest = sub.add_parser("manifest", help="copy the Haddock tree and write the manifest")
    manifest.add_argument("site")
    manifest.add_argument("haddock_out")
    manifest.add_argument("offchain_root")
    manifest.add_argument("config_files")
    archive = sub.add_parser("archive-check", help="compare the staged archive's API pages with the site")
    archive.add_argument("archive_dir")
    archive.add_argument("site")
    args = parser.parse_args(argv)
    if args.mode == "manifest":
        built = copy_reference(
            Path(args.site), Path(args.haddock_out), Path(args.offchain_root), Path(args.config_files)
        )
        neutral = built["neutralization"]
        print(
            f"api-reference modules={len(built['modules'])} "
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
