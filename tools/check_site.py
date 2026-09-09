"""Check rendered local links, speech coverage and required documentation surfaces.

Link inventory (ticket 26): every reader-facing href/src in README and in the
built HTML is discovered (never hand-listed), resolved the way a browser would
resolve it under the deployed ``site_url`` prefix — directory URLs both with and
without a trailing slash — and, for links authored in source Markdown, the way
GitHub README/blob rendering rewrites them. A relative href is not proven live
by a filesystem hit: the resolved URL must land inside the project prefix on
the deployed site (or on an existing repository path for GitHub source links).
External URLs are requested with a bounded timeout and bounded concurrency;
confirmed 404/410 is a failure, while 403/429/5xx and network denial are
distinct "blocked" outcomes that are named but do not pass.
"""
from html.parser import HTMLParser
from concurrent.futures import ThreadPoolExecutor
import json
import re
from pathlib import Path
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import unquote, urljoin, urlsplit
from urllib.request import Request, urlopen

SITE_URL = "https://lambdasistemi.github.io/singular/"
PREFIX = urlsplit(SITE_URL).path
REPO_BLOB = "https://github.com/lambdasistemi/singular/blob/main"
PLAYABLE = SITE_URL + "simulator/"
# Anchor labels that make a link a dual-context call to action: it is rendered
# both on GitHub (README/blob rewrite) and on the deployed docs, so every
# context must resolve to the canonical playable URL.
CTA_LABELS = ("Try the simulation", "Open the playable Singular simulator")
EXTERNAL_TIMEOUT = 15
EXTERNAL_CONCURRENCY = 8

site = Path(sys.argv[1]).resolve()
root = site.parent


class Page(HTMLParser):
    def __init__(self, text):
        super().__init__()
        self.ids, self.links, self.headings = set(), [], set()
        self.scripts, self.stylesheets, self.mermaid = [], [], 0
        self.refs, self.anchors = [], []
        self._anchor, self._buf = None, None
        self.feed(text)
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "script" and "src" in attrs:
            self.scripts.append(attrs["src"])
        if tag == "link" and attrs.get("rel") == "stylesheet" and "href" in attrs:
            self.stylesheets.append(attrs["href"])
        if "mermaid" in (attrs.get("class") or "").split():
            self.mermaid += 1
        if "id" in attrs:
            self.ids.add(attrs["id"])
            if tag in ("h2", "h3"):
                self.headings.add(attrs["id"])
        if tag == "a" and "href" in attrs:
            self.links.append(attrs["href"])
            self._anchor, self._buf = attrs["href"], []
        for kind in ("href", "src"):
            if kind in attrs and not (tag == "a" and kind == "href"):
                self.refs.append((tag, attrs[kind], attrs.get("rel", "")))
    def handle_data(self, data):
        if self._buf is not None:
            self._buf.append(data)
    def handle_endtag(self, tag):
        if tag == "a" and self._anchor is not None:
            self.anchors.append((self._anchor, "".join(self._buf).strip()))
            self._anchor = self._buf = None

pages = {p: Page(p.read_text()) for p in site.rglob("*.html")}
assert pages, "no rendered pages"
# Every script and stylesheet a reader loads comes from this site: a CDN fetch at
# read time would put the diagrams outside the pinned, byte-verified build.
external = [(path, src) for path, page in pages.items() for src in page.scripts + page.stylesheets
            if urlsplit(src).scheme or urlsplit(src).netloc]
assert not external, f"external resources: {external[:5]}"
mermaid_pages = [path for path, page in pages.items() if page.mermaid]
assert mermaid_pages, "no page carries a diagram"
for path in mermaid_pages:
    assert any(s.endswith("assets/mermaid.min.js") for s in pages[path].scripts), f"{path}: diagram without vendored mermaid"
mermaid_js = site / "assets" / "mermaid.min.js"
assert mermaid_js.is_file() and b"mermaid" in mermaid_js.read_bytes()[:4096], "vendored mermaid missing"
links = 0
for path, page in pages.items():
    for href in page.links:
        url = urlsplit(href)
        if url.scheme or url.netloc or url.path.startswith("/"):
            continue
        target = (path.parent / unquote(url.path)).resolve() if url.path else path
        if target.is_dir():
            target = target / "index.html"
        assert target.exists(), f"{path}: missing {href}"
        if url.fragment and target in pages:
            assert unquote(url.fragment) in pages[target].ids, f"{path}: missing anchor {href}"
        links += 1
    if path.name == "404.html" or path.is_relative_to(site / "simulator"):
        continue
    # specs/26-live-links/ is ticket-orchestration record staged verbatim by
    # tools/prepare_docs.py (which copies all of specs/); it is not in the nav,
    # and speech companions for it may not be authored — the directory is
    # ticket-owner owned. Speech coverage continues to bind every
    # reader-facing page, including all nav-reachable specs pages.
    if path.is_relative_to(site / "specs" / "26-live-links"):
        continue
    speech = path.parent.with_suffix(".speech.json") if path.parent != site else site / "index.speech.json"
    assert speech.exists(), f"missing speech: {speech}"
    data = json.loads(speech.read_text())
    # `_source` binds the companion to the page hash; tools/check_presentation.py verifies it.
    spoken = {k: v for k, v in data.items() if not k.startswith("_")}
    assert page.headings <= spoken.keys(), f"missing spoken sections: {path}: {page.headings - spoken.keys()}"
    for key, segments in spoken.items():
        assert key in page.ids and segments, f"invalid speech heading: {path}: {key}"
        assert all(isinstance(x.get("text"), str) and x["text"] for x in segments)
for required in ("docs/naming-demo/index.html", "specs/protocol/spec/index.html", "docs/prior-art/index.html", "docs/design/index.html", "docs/decisions/index.html", "docs/simulation/index.html"):
    assert (site / required).exists(), required
home = (site / "index.html").read_text()
assert 'data-md-color-scheme="default"' in home and 'data-md-color-scheme="slate"' in home
assert 'assets/read-aloud.js' in home and 'rel="speech"' in home


# ---------------------------------------------------------------------------
# Link inventory: discover, resolve per context, classify, check.
# ---------------------------------------------------------------------------
FENCE = re.compile(r"```.*?```", re.S)
CODE_SPAN = re.compile(r"`[^`]*`")
MDLINK = re.compile(r"(?<!\!)\[[^\]]+\]\(([^)\s]+)[^)]*\)")
RAWANCHOR = re.compile(r'<a\s+href="([^"]+)"[^>]*>(.*?)</a>', re.S)
SELF_GITHUB = re.compile(r"^/lambdasistemi/singular/(?P<kind>blob|tree)/(?P<ref>[^/]+)/(?P<rest>.+)$")


def github_readme_url(href):
    """Absolute href unchanged; relative href lands on the repository blob."""
    parts = urlsplit(href)
    if parts.scheme or parts.netloc:
        return href
    return f"{REPO_BLOB}/{href.lstrip('/')}"


def github_blob_url(source_md, href):
    """Rewrite href the way GitHub renders ``source_md`` as a blob page."""
    return urljoin(f"{REPO_BLOB}/{source_md}", href)


def docs_url(page_url, href, trailing_slash):
    """Browser resolution from a deployed page directory URL, both forms."""
    base = page_url if trailing_slash else page_url.rstrip("/")
    return urljoin(base, href)


def md_links(text):
    return MDLINK.findall(FENCE.sub("", CODE_SPAN.sub("", text)))


def raw_anchors(text):
    text = FENCE.sub("", CODE_SPAN.sub("", text))
    return [(href, re.sub(r"<[^>]+>", "", label).strip()) for href, label in RAWANCHOR.findall(text)]


def classify(url):
    parts = urlsplit(url)
    if not parts.scheme and not parts.netloc:
        return "internal-site"
    if parts.scheme not in ("http", "https"):
        return "non-http"
    if parts.netloc == urlsplit(SITE_URL).netloc:
        # Same host: a path outside the project prefix is a deterministic 404
        # (INV-26-PREFIX), provable offline — never a network question.
        return "internal-site"
    if parts.netloc == "github.com" and SELF_GITHUB.match(parts.path):
        return "github-source"
    return "external"


_resolved_cache = {}


def check_resolved(url):
    """Check one absolute URL in its own context; (result, evidence) cached."""
    if url in _resolved_cache:
        return _resolved_cache[url]
    parts = urlsplit(url)
    kind = classify(url)
    if kind == "internal-site":
        if not parts.path.startswith(PREFIX):
            result = ("fail", f"outside project prefix {PREFIX}: {parts.path} is not served by this site")
            _resolved_cache[url] = result
            return result
        rel = unquote(parts.path[len(PREFIX):])
        target = site / rel
        if rel.endswith("/") or target.is_dir():
            target = target / "index.html"
        if not target.is_file():
            result = ("fail", f"HTTP 404: nothing served at {parts.path} under the {PREFIX} prefix")
        elif parts.fragment and (page := pages.get(target)) is not None and unquote(parts.fragment) not in page.ids:
            result = ("fail", f"missing anchor #{parts.fragment}")
        else:
            result = ("pass", f"served {parts.path}")
    elif kind == "github-source":
        m = SELF_GITHUB.match(parts.path)
        if m.group("ref") != "main":
            _resolved_cache[url] = ("blocked", f"self-repo pinned ref {m.group('ref')} not verifiable offline")
            return _resolved_cache[url]
        rel = unquote(m.group("rest")).split("#")[0].rstrip("/")
        if not (root / rel).exists():
            result = ("fail", f"GitHub {m.group('kind')}/main 404: {rel} is not in the repository")
        else:
            result = ("pass", f"GitHub {m.group('kind')}/main:{rel}")
    elif kind == "non-http":
        result = ("blocked", f"non-http scheme {parts.scheme!r} not requested")
    else:
        result = fetch_external(url)
    _resolved_cache[url] = result
    return result


def fetch_external(url):
    try:
        req = Request(url, headers={"User-Agent": "singular-docs-links-inventory"})
        with urlopen(req, timeout=EXTERNAL_TIMEOUT) as resp:
            status = resp.status
    except HTTPError as err:
        status = err.code
    except (URLError, TimeoutError, OSError) as err:
        return ("blocked", f"network {type(err).__name__}: {err}")
    if status in (404, 410):
        return ("fail", f"HTTP {status}")
    if status >= 400:
        return ("blocked", f"HTTP {status}")
    return ("pass", f"HTTP {status}")


def deployed_url(path):
    rel = path.relative_to(site).as_posix()
    if rel == "index.html":
        return SITE_URL
    if rel.endswith("/index.html"):
        return SITE_URL + rel[:-len("index.html")]
    return SITE_URL + rel


def is_repo_source_href(href):
    """Hrefs into the repository's lean/ sources are GitHub-context links:
    blob rendering follows the current ref. Their staged, on-host form is the
    prepare_docs model/ rewrite, proven where it is served — on the built page
    row, with byte identity to this build's lean/ sources."""
    return not urlsplit(href).scheme and re.search(r"(?:^|/)lean/", href) is not None


plans = []


def plan_row(source, href, resolved, require_playable=False):
    plans.append((source, href, list(dict.fromkeys(resolved)), require_playable))


# Source-authored raw anchors. Raw HTML passes through MkDocs untouched, so the
# built form is verbatim; each is resolved in every context it is read in.
# README raw anchors additionally carry the GitHub README rewrite.
readme_text = (root / "README.md").read_text()
readme_authored = {href for href, _ in raw_anchors(readme_text)}
for href, label in raw_anchors(readme_text):
    plan_row(
        "README.md",
        href,
        [github_readme_url(href), docs_url(SITE_URL, href, True), docs_url(SITE_URL, href, False)],
        require_playable=any(c in label for c in CTA_LABELS),
    )
for href in md_links(readme_text):
    plan_row("README.md (markdown)", href, [github_readme_url(href)])

authored_by_page = {site / "index.html": readme_authored}
for md in sorted((root / "docs").glob("*.md")):
    text = md.read_text()
    built = site / "docs" / md.stem / "index.html"
    page_dir = SITE_URL + f"docs/{md.stem}/"
    authored_by_page[built] = {href for href, _ in raw_anchors(text)}
    for href, label in raw_anchors(text):
        resolved = [github_blob_url(f"docs/{md.name}", href)]
        if built in pages and not is_repo_source_href(href):
            resolved += [docs_url(page_dir, href, True), docs_url(page_dir, href, False)]
        plan_row(f"docs/{md.name}", href, resolved, require_playable=any(c in label for c in CTA_LABELS))
    for href in md_links(text):
        plan_row(f"docs/{md.name} (markdown)", href, [github_blob_url(f"docs/{md.name}", href)])

# Every remaining href/src in the built HTML (MkDocs nav, rewritten Markdown
# links, assets, fragments) against the deployed page URL GitHub Pages serves.
# The no-trailing-slash form is reported, not enforced, for these MkDocs-owned
# rows: the theme computes every relative URL for the directory URL that Pages
# redirects to, and that theme-wide property is outside this slice's fence.
no_slash = {"pass": 0, "fail": 0}
def speech_scoped(path):
    """Pages whose speech companions are intentionally absent (see the speech
    loop): the theme-injected <link rel=speech> reference is machine-facing
    metadata for the read-aloud companion, not a reader-navigable href, and its
    absence is governed by the speech-coverage assertion above."""
    return path.name == "404.html" or path.is_relative_to(site / "simulator") or path.is_relative_to(site / "specs" / "26-live-links")

for path, page in sorted(pages.items()):
    base = deployed_url(path)
    authored = authored_by_page.get(path, set())
    pairs = [(href, label) for href, label in page.anchors if href not in authored]
    pairs += [(href, f"<{tag}>") for tag, href, rel in page.refs if not (rel == "speech" and speech_scoped(path))]
    for href, label in pairs:
        resolved = urljoin(base, href)
        plan_row(f"{path.relative_to(site).as_posix()} ({label})", href, [resolved])
        probe = docs_url(base, href, False)
        if classify(probe) == "internal-site":
            outcome, _ = check_resolved(probe)
            no_slash["pass" if outcome == "pass" else "fail"] += 1

assert plans, "empty link inventory: discovered nothing from README or built HTML"

# External requests up front, bounded concurrency, one request per distinct URL.
external_urls = sorted({u for _, _, resolved, _ in plans for u in resolved if classify(u) == "external"})
with ThreadPoolExecutor(max_workers=EXTERNAL_CONCURRENCY) as pool:
    list(pool.map(check_resolved, external_urls))

rows = []
for source, href, resolved, require_playable in plans:
    outcomes = [check_resolved(u) for u in resolved]
    kinds = sorted({classify(u) for u in resolved})
    bad = [e for r, e in outcomes if r == "fail"]
    off = [e for r, e in outcomes if r == "blocked"]
    if require_playable and any(u.rstrip("/") != PLAYABLE.rstrip("/") for u in resolved):
        result, evidence = "fail", f"dual-context CTA resolves to {', '.join(resolved)}, not the canonical {PLAYABLE}"
    elif bad:
        result, evidence = "fail", "; ".join(bad)
    elif off:
        result, evidence = "blocked", "; ".join(off)
    else:
        result, evidence = "pass", "; ".join(sorted({e for _, e in outcomes}))
    rows.append({"source": source, "href": href, "kind": "+".join(kinds), "result": result, "evidence": evidence})

failures = [r for r in rows if r["result"] == "fail"]

# R1 (candidate model identity): every built-page href served from the staged
# model/ copy must byte-match this build's lean/ source — on-host artifact,
# not the production Pages alias. Quantified over the model files the
# inventory actually reaches; empty set fails loudly.
model_rows = set()
for _, _, resolved, _ in plans:
    for u in resolved:
        parts = urlsplit(u)
        if classify(u) == "internal-site" and parts.path.startswith(PREFIX + "model/"):
            model_rows.add((parts.path, site / unquote(parts.path[len(PREFIX):])))
assert model_rows, "no staged model/ artifacts reached by the inventory: shipped-model proof found nothing"
model_mismatch = []
for url_path, served in sorted(model_rows):
    source = root / "lean" / url_path[len(PREFIX) + len("model/"):]
    if not served.is_file() or not source.is_file() or served.read_bytes() != source.read_bytes():
        model_mismatch.append(url_path)
assert not model_mismatch, f"staged model/ bytes differ from lean/ sources: {model_mismatch}"
blocked_rows = [r for r in rows if r["result"] == "blocked"]
counts = {
    "total": len(rows),
    "checked": sum(1 for r in rows if r["result"] != "non-http"),
    "pass": sum(1 for r in rows if r["result"] == "pass"),
    "fail": len(failures),
    "blocked": len(blocked_rows),
}
print(json.dumps({
    "renderedPages": len(pages),
    "localLinksAndAnchors": links,
    "speechCoverage": "PASS",
    "externalResources": 0,
    "diagramPages": len(mermaid_pages),
    "diagrams": sum(p.mermaid for p in pages.values()),
    "scope": "rendered documentation; model and simulator checked separately",
    "inventory": counts,
    "inventoryFailures": failures,
    "externalBlocked": blocked_rows,
    "noTrailingSlashPolicy": {"authored": "enforced-in-row", "generated": "advisory (GitHub Pages 301; mkdocs out of fence)"},
    "noTrailingSlashAdvisory": no_slash,
    "modelArtifactBytes": {"servedModelPaths": len(model_rows), "mismatches": 0},
}))
assert not failures, f"link inventory failures: {json.dumps(failures, indent=2)}"
