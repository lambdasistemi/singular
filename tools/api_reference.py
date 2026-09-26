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
import re
import shutil
import sys
import tarfile
from pathlib import Path

API_DIR = ("api", "offchain")
MANIFEST_NAME = "manifest.json"
STANZA_HEADERS = ("library", "common")


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


def copy_reference(site: Path, haddock_out: Path, offchain_root: Path) -> dict:
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
                "module_page_sha256": sha256_file(module_page),
                "source_page": source_page.relative_to(api_root).as_posix(),
                "source_page_sha256": sha256_file(source_page),
            }
        )
    manifest = {
        "package": "singular-registry",
        "generator": "tools/api_reference.py",
        "other_modules": extent["other"],
        "modules": records,
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
    archive = sub.add_parser("archive-check", help="compare the staged archive's API pages with the site")
    archive.add_argument("archive_dir")
    archive.add_argument("site")
    args = parser.parse_args(argv)
    if args.mode == "manifest":
        built = copy_reference(Path(args.site), Path(args.haddock_out), Path(args.offchain_root))
        print(
            f"api-reference modules={len(built['modules'])} "
            f"other-modules={len(built['other_modules'])}"
        )
    else:
        archive_check(Path(args.archive_dir), Path(args.site))


if __name__ == "__main__":
    main(sys.argv[1:])
