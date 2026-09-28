"""The generated Aiken reference for the registry validators (onchain/).

The pinned ``aiken docs`` (onchain flake package ``aiken-reference``) writes
one page per module that declares a public definition. This tool publishes
that output under ``SITE/api/onchain`` and checks it:

* ``publish SITE REFERENCE ONCHAIN_ROOT REF`` (site build time): copy the
  generated tree, remove the scripts it loads from a CDN (the site serves no
  third-party script), bind every "view source" link to ``REF`` and the
  ``onchain/`` directory — ``aiken docs`` addresses links as
  ``blob/<package version>/<path>`` relative to the Aiken project — and
  write a manifest binding each page to the digest of the source it was
  generated from.
* ``check SITE ONCHAIN_ROOT REF`` (docs check time): presence, freshness and
  link correspondence against the candidate's own ``onchain/`` tree.
* ``controls SITE ONCHAIN_ROOT REF``: plant each fault the check exists to
  catch into a scratch copy and require the check to refuse it for that
  reason; the unmodified copy must pass.

Module extent is discovered from the source: every ``.ak`` file under
``validators/`` that is not a test (``*.tests.ak``) or property
(``*.props.ak``) module. A module with a top-level ``pub`` declaration must
have a page; a module without one (a bare validator module or a vector
table) has none, and is reached through its source link instead.
"""
import hashlib
import json
import re
import shutil
import stat
import sys
import tempfile
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

MANIFEST_NAME = "manifest.json"
API_DIR = ("api", "onchain")
REPOSITORY = "https://github.com/lambdasistemi/singular"
# The navigation page that must link the reference's index and every page.
INDEX_PAGE = "docs/onchain-api-reference/index.html"
EXTERNAL_SCRIPT = re.compile(r'<script\b[^>]*src="https?://[^"]*"[^>]*>\s*</script>\s*', re.I)
EXTERNAL_STYLESHEET = re.compile(r'<link\b[^>]*href="https?://[^"]*"[^>]*/?>', re.I)
PUBLIC_DECLARATION = re.compile(r"^pub\s", re.M)
SOURCE_LINK = re.compile(
    re.escape(REPOSITORY) + r"/blob/(?P<ref>[^/\"]+)/onchain/(?P<path>[^\"#]+)(?:#L(?P<a>\d+)(?:-L(?P<b>\d+))?)?$"
)


class RefusedReference(Exception):
    """A named reason the published reference is refused."""

    def __init__(self, code: str, detail: str):
        super().__init__(f"{code} {detail}")
        self.code = code


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def package_version(onchain_root: Path) -> str:
    match = re.search(r'^version\s*=\s*"([^"]+)"', (onchain_root / "aiken.toml").read_text(), re.M)
    if not match:
        raise SystemExit("aiken_reference: aiken.toml declares no package version")
    return match.group(1)


def source_modules(onchain_root: Path) -> dict[str, Path]:
    """Every non-test module under validators/, by Aiken module name."""
    validators = onchain_root / "validators"
    modules = {}
    for path in sorted(validators.rglob("*.ak")):
        if path.name.endswith((".tests.ak", ".props.ak")):
            continue
        modules[path.relative_to(validators).as_posix()[: -len(".ak")]] = path
    if not modules:
        raise SystemExit(f"aiken_reference: no source modules under {validators}")
    return modules


def documented_modules(onchain_root: Path) -> dict[str, Path]:
    return {
        module: path
        for module, path in source_modules(onchain_root).items()
        if PUBLIC_DECLARATION.search(path.read_text(encoding="utf-8"))
    }


def expected_ref(candidate_ref: str) -> str:
    """Source links name the candidate commit when there is a clean one."""
    return candidate_ref if re.fullmatch(r"[0-9a-f]{40}", candidate_ref or "") else "main"


def publish(site: Path, reference: Path, onchain_root: Path, candidate_ref: str) -> dict:
    ref = expected_ref(candidate_ref)
    api_root = site.joinpath(*API_DIR)
    if api_root.exists():
        shutil.rmtree(api_root)
    shutil.copytree(reference, api_root)
    for path in [api_root, *api_root.rglob("*")]:
        path.chmod(path.stat().st_mode | stat.S_IWUSR)
    version = package_version(onchain_root)
    generated_prefix = f"{REPOSITORY}/blob/{version}/"
    removed_assets = rewritten = 0
    for page in sorted(api_root.rglob("*.html")):
        text = page.read_text(encoding="utf-8")
        text, n_js = EXTERNAL_SCRIPT.subn("", text)
        text, n_css = EXTERNAL_STYLESHEET.subn("", text)
        removed_assets += n_js + n_css
        rewritten += text.count(f'href="{generated_prefix}')
        text = text.replace(f'href="{generated_prefix}', f'href="{REPOSITORY}/blob/{ref}/onchain/')
        page.write_text(text, encoding="utf-8")
    if rewritten == 0:
        raise SystemExit(
            f"aiken_reference: no source link under {generated_prefix} found: "
            "the repository named in onchain/aiken.toml is not this one"
        )
    modules = []
    for module, source in documented_modules(onchain_root).items():
        page = api_root / f"{module}.html"
        if not page.is_file():
            raise SystemExit(f"aiken_reference: no generated page for {module}")
        modules.append({
            "module": module,
            "source": source.relative_to(onchain_root).as_posix(),
            "source_sha256": sha256_file(source),
            "page": page.relative_to(api_root).as_posix(),
            "page_sha256": sha256_file(page),
        })
    manifest = {
        "generator": "tools/aiken_reference.py",
        "source_ref": ref,
        "package_version": version,
        "modules": modules,
        "undocumented": sorted(set(source_modules(onchain_root)) - set(documented_modules(onchain_root))),
        "index_sha256": sha256_file(api_root / "index.html"),
        "source_links": rewritten,
        "external_assets_removed": removed_assets,
    }
    (api_root / MANIFEST_NAME).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


class _Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.hrefs, self.assets, self.ids = [], [], set()

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.add(attrs["id"])
        if tag == "a" and attrs.get("href"):
            self.hrefs.append(attrs["href"])
        elif tag == "script" and attrs.get("src"):
            self.assets.append(attrs["src"])
        elif tag == "link" and attrs.get("href"):
            self.assets.append(attrs["href"])


def _parse(page: Path) -> _Links:
    parsed = _Links()
    parsed.feed(page.read_text(encoding="utf-8", errors="replace"))
    return parsed


def check(site: Path, onchain_root: Path, candidate_ref: str) -> dict:
    api_root = site.joinpath(*API_DIR)
    manifest_path = api_root / MANIFEST_NAME
    if not manifest_path.is_file():
        raise RefusedReference("AIKEN_REFERENCE_MISSING", str(manifest_path))
    manifest = json.loads(manifest_path.read_text())
    ref = expected_ref(candidate_ref)
    if manifest.get("source_ref") != ref:
        raise RefusedReference(
            "AIKEN_SOURCE_REF", f"manifest binds {manifest.get('source_ref')}, candidate is {ref}"
        )
    documented = documented_modules(onchain_root)
    recorded = {record["module"]: record for record in manifest["modules"]}
    if set(recorded) != set(documented):
        raise RefusedReference(
            "AIKEN_EXTENT_MISMATCH",
            f"manifest-only={sorted(set(recorded) - set(documented))} "
            f"source-only={sorted(set(documented) - set(recorded))}",
        )
    undocumented = set(source_modules(onchain_root)) - set(documented)
    for module in sorted(undocumented):
        if (api_root / f"{module}.html").exists():
            raise RefusedReference("AIKEN_EXTENT_MISMATCH", f"page for a module with no public declaration: {module}")
    for module, record in sorted(recorded.items()):
        source = onchain_root / record["source"]
        if not source.is_file() or sha256_file(source) != record["source_sha256"]:
            raise RefusedReference("AIKEN_SOURCE_STALE", f"module={module} leg=source-digest")
        page = api_root / record["page"]
        if not page.is_file() or sha256_file(page) != record["page_sha256"]:
            raise RefusedReference("AIKEN_SOURCE_STALE", f"module={module} leg=page-digest")
    index = api_root / "index.html"
    if not index.is_file() or sha256_file(index) != manifest.get("index_sha256"):
        raise RefusedReference("AIKEN_SOURCE_STALE", "leg=index-digest")
    index_links = set(_parse(index).hrefs)
    for record in recorded.values():
        if f"./{record['page']}" not in index_links:
            raise RefusedReference("AIKEN_NAVIGABLE", f"reference index does not link {record['page']}")
    ids = {page.resolve(): _parse(page).ids for page in api_root.rglob("*.html")}
    source_lines = {
        path.relative_to(onchain_root).as_posix(): len(path.read_text(encoding="utf-8").splitlines())
        for path in source_modules(onchain_root).values()
    }
    source_links = local_links = external_links = 0
    for page in sorted(api_root.rglob("*.html")):
        parsed = _parse(page)
        for asset in parsed.assets:
            parts = urlsplit(asset)
            if parts.scheme or parts.netloc:
                raise RefusedReference("AIKEN_EXTERNAL_ASSET", f"{page.relative_to(site)} {asset}")
            if not (page.parent / unquote(parts.path)).resolve().is_file():
                raise RefusedReference("AIKEN_LINK_MISSING", f"{page.relative_to(site)} {asset}")
        for href in parsed.hrefs:
            parts = urlsplit(href)
            if parts.scheme in ("http", "https"):
                if parts.netloc == "github.com" and href.startswith(f"{REPOSITORY}/blob/"):
                    match = SOURCE_LINK.match(href)
                    if not match or match.group("ref") != ref:
                        raise RefusedReference("AIKEN_SOURCE_LINK", f"{page.relative_to(site)} {href}")
                    lines = source_lines.get(match.group("path"))
                    last = int(match.group("b") or match.group("a") or 1)
                    if lines is None or last > lines:
                        raise RefusedReference("AIKEN_SOURCE_LINK", f"{page.relative_to(site)} {href}")
                    source_links += 1
                elif parts.netloc == "github.com" and href.rstrip("/") != REPOSITORY:
                    raise RefusedReference("AIKEN_SOURCE_LINK", f"{page.relative_to(site)} {href}")
                else:
                    external_links += 1
                continue
            if parts.scheme:
                continue
            target = (page.parent / unquote(parts.path)).resolve() if parts.path else page.resolve()
            if target.is_dir():
                target = target / "index.html"
            if not target.is_file():
                raise RefusedReference("AIKEN_LINK_MISSING", f"{page.relative_to(site)} {href}")
            # A browser matches the raw fragment first, then its decoding.
            if parts.fragment and target in ids and not {parts.fragment, unquote(parts.fragment)} & ids[target]:
                raise RefusedReference("AIKEN_LINK_MISSING", f"{page.relative_to(site)} {href}")
            local_links += 1
    if source_links == 0:
        raise RefusedReference("AIKEN_SOURCE_LINK", "no source link bound to this repository")
    guide = site / INDEX_PAGE
    guide_links = set(_parse(guide).hrefs) if guide.is_file() else set()
    for page in ["index.html"] + sorted(record["page"] for record in recorded.values()):
        if f"../../api/onchain/{page}" not in guide_links:
            raise RefusedReference("AIKEN_NAVIGABLE", f"{INDEX_PAGE} does not link {page}")
    return {
        "modules": len(recorded),
        "undocumented": sorted(undocumented),
        "sourceLinks": source_links,
        "localLinks": local_links,
        "externalAnchors": external_links,
        "sourceRef": ref,
    }


def _rebind(api_root: Path, page: Path) -> None:
    """Re-record a planted page's digest, so only the targeted leg can refuse it."""
    manifest_path = api_root / MANIFEST_NAME
    manifest = json.loads(manifest_path.read_text())
    rel = page.relative_to(api_root).as_posix()
    for record in manifest["modules"]:
        if record["page"] == rel:
            record["page_sha256"] = sha256_file(page)
    if rel == "index.html":
        manifest["index_sha256"] = sha256_file(page)
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")


def controls(site: Path, onchain_root: Path, candidate_ref: str) -> None:
    ref = expected_ref(candidate_ref)

    def plant(name, expected, mutate):
        with tempfile.TemporaryDirectory() as tmp:
            scratch_site, scratch_root = Path(tmp) / "site", Path(tmp) / "onchain"
            (scratch_site / "docs").mkdir(parents=True)
            shutil.copytree(site / Path(INDEX_PAGE).parent, scratch_site / Path(INDEX_PAGE).parent)
            shutil.copytree(site.joinpath(*API_DIR), scratch_site.joinpath(*API_DIR))
            shutil.copytree(onchain_root / "validators", scratch_root / "validators")
            shutil.copyfile(onchain_root / "aiken.toml", scratch_root / "aiken.toml")
            for path in Path(tmp).rglob("*"):
                path.chmod(path.stat().st_mode | stat.S_IWUSR)
            api_root = scratch_site.joinpath(*API_DIR)
            if mutate is not None:
                mutate(scratch_site, api_root, scratch_root)
            try:
                check(scratch_site, scratch_root, candidate_ref)
            except RefusedReference as refused:
                if expected is None or refused.code != expected:
                    raise SystemExit(f"aiken reference control {name}: refused with {refused}, expected {expected}")
                print(f"aiken-reference control {name}: refused {refused.code}")
                return
            if expected is not None:
                raise SystemExit(f"aiken reference control {name}: accepted, expected {expected}")
            print(f"aiken-reference control {name}: accepted")

    def state_page(api_root):
        return api_root / "state.html"

    def missing_manifest(_s, api_root, _r):
        (api_root / MANIFEST_NAME).unlink()

    def edited_source(_s, _a, root):
        with (root / "validators" / "state.ak").open("a") as handle:
            handle.write("\n// planted\n")

    def edited_page(_s, api_root, _r):
        page = state_page(api_root)
        page.write_text(page.read_text() + "\n")

    def foreign_link(_s, api_root, _r):
        page = state_page(api_root)
        page.write_text(page.read_text().replace(
            f"{REPOSITORY}/blob/{ref}/onchain/", "https://github.com/hal/MPF/blob/0.0.0/", 1))
        _rebind(api_root, page)

    def line_past_end(_s, api_root, _r):
        page = state_page(api_root)
        page.write_text(re.sub(r'(/onchain/validators/state\.ak)#L\d+-L\d+', r'\1#L1-L999999', page.read_text(), count=1))
        _rebind(api_root, page)

    def dropped_module(_s, api_root, _r):
        (api_root / "registry" / "fold.html").unlink()
        manifest = json.loads((api_root / MANIFEST_NAME).read_text())
        manifest["modules"] = [r for r in manifest["modules"] if r["module"] != "registry/fold"]
        (api_root / MANIFEST_NAME).write_text(json.dumps(manifest))

    def cdn_script(_s, api_root, _r):
        page = state_page(api_root)
        page.write_text(page.read_text().replace(
            "</head>", '<script src="https://unpkg.com/tippy.js@6"></script></head>', 1))
        _rebind(api_root, page)

    def unlinked_guide(scratch_site, _a, _r):
        guide = scratch_site / INDEX_PAGE
        guide.write_text(guide.read_text().replace('href="../../api/onchain/registry/fold.html"', 'href="../../api/onchain/"'))

    def other_revision(_s, api_root, _r):
        manifest = json.loads((api_root / MANIFEST_NAME).read_text())
        manifest["source_ref"] = "0" * 40 if manifest["source_ref"] != "0" * 40 else "main"
        (api_root / MANIFEST_NAME).write_text(json.dumps(manifest))

    plant("unmodified", None, None)
    plant("other-revision", "AIKEN_SOURCE_REF", other_revision)
    plant("missing-manifest", "AIKEN_REFERENCE_MISSING", missing_manifest)
    plant("edited-source", "AIKEN_SOURCE_STALE", edited_source)
    plant("edited-page", "AIKEN_SOURCE_STALE", edited_page)
    plant("foreign-source-link", "AIKEN_SOURCE_LINK", foreign_link)
    plant("line-past-end", "AIKEN_SOURCE_LINK", line_past_end)
    plant("dropped-module", "AIKEN_EXTENT_MISMATCH", dropped_module)
    plant("cdn-script", "AIKEN_EXTERNAL_ASSET", cdn_script)
    plant("unlinked-guide", "AIKEN_NAVIGABLE", unlinked_guide)


def main(argv: list[str]) -> None:
    if len(argv) == 5 and argv[0] == "publish":
        manifest = publish(Path(argv[1]), Path(argv[2]), Path(argv[3]), argv[4])
        print(f"aiken-reference published modules={len(manifest['modules'])} source-links={manifest['source_links']} ref={manifest['source_ref']}")
    elif len(argv) == 4 and argv[0] in ("check", "controls"):
        site, onchain_root, candidate_ref = Path(argv[1]), Path(argv[2]), argv[3]
        if argv[0] == "controls":
            controls(site, onchain_root, candidate_ref)
            return
        try:
            print("aiken-reference " + json.dumps(check(site, onchain_root, candidate_ref), sort_keys=True))
        except RefusedReference as refused:
            print(str(refused), file=sys.stderr)
            sys.exit(1)
    else:
        raise SystemExit(
            "usage: aiken_reference.py publish SITE REFERENCE ONCHAIN_ROOT REF\n"
            "       aiken_reference.py {check,controls} SITE ONCHAIN_ROOT REF"
        )


if __name__ == "__main__":
    main(sys.argv[1:])
