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
import os
import re
import subprocess
from pathlib import Path
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import unquote, urljoin, urlsplit
from urllib.request import Request, urlopen

SITE_URL = "https://lambdasistemi.github.io/singular/"
PREFIX = urlsplit(SITE_URL).path
REPO_BLOB = "https://github.com/lambdasistemi/singular/blob"
PLAYABLE = SITE_URL + "simulator/"
# Anchor labels that make a link a dual-context call to action: it is rendered
# both on GitHub (README/blob rewrite) and on the deployed docs, so every
# context must resolve to the canonical playable URL.
CTA_LABELS = ("Try the simulation", "Open the playable Singular simulator")
EXTERNAL_TIMEOUT = 15
EXTERNAL_CONCURRENCY = 8
CANDIDATE_REF_ERROR = (
    "candidate git ref unavailable: SINGULAR_CANDIDATE_REF is empty and "
    "git rev-parse HEAD failed or git is unavailable; relative GitHub links cannot be bound"
)

site = Path(sys.argv[1]).resolve()
root = Path(__file__).resolve().parent.parent


def candidate_git_context():
    """Return the explicit packaged ref, or derive the checked-out Git ref."""
    explicit_ref = os.environ.get("SINGULAR_CANDIDATE_REF", "").strip()
    if explicit_ref:
        return explicit_ref, explicit_ref
    try:
        sha = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"],
                             capture_output=True, text=True, timeout=60)
    except OSError:
        return None, None
    if sha.returncode != 0:
        return None, None
    try:
        branch_out = subprocess.run(["git", "-C", str(root), "rev-parse", "--abbrev-ref", "HEAD"],
                                    capture_output=True, text=True, timeout=60)
    except OSError:
        return sha.stdout.strip(), sha.stdout.strip()
    branch = branch_out.stdout.strip()
    ref = branch if branch_out.returncode == 0 and branch and branch != "HEAD" else sha.stdout.strip()
    return ref, sha.stdout.strip()


CANDIDATE_REF, CANDIDATE_SHA = candidate_git_context()

# Optional served-route surfaces: --served NAME=BASE (repeatable) verifies the
# discovered internal routes against what a server actually answers, judged
# from the final URL after redirects. Surface identity is deployment-bound
# evidence only: --served-marker NAME=URL fetches a served identity token
# (the candidate.txt pattern the preview publisher established), and
# --served-ref NAME=SHA accepts a deployment ref derived from the publisher's
# record. A token equal to this candidate marks the surface candidate; a
# different verified commit marks it a prior deployment; anything else is
# UNKNOWN and is reported as such — never inferred from branch state,
# ancestry, HTTP 404s or path absence. --served-routes NAME=FILE supplies a
# deployed deployment's own rendered route inventory (extracted with
# --routes-only from a build of that identity) for fail-closed regression
# classification. --routes-only prints the discovered internal route
# inventory of a site tree and exits.
served_bases, served_markers, served_refs, served_deployed_routes = [], {}, {}, {}
served_strict_candidate = set()
routes_only = False
_args = sys.argv[2:]
_i = 0
while _i < len(_args):
    if _args[_i] == "--served" and _i + 1 < len(_args):
        _name, _, _base = _args[_i + 1].partition("=")
        served_bases.append((_name, _base))
    elif _args[_i] == "--served-marker" and _i + 1 < len(_args):
        _name, _, _url = _args[_i + 1].partition("=")
        served_markers[_name] = _url
    elif _args[_i] == "--served-ref" and _i + 1 < len(_args):
        _name, _, _sha = _args[_i + 1].partition("=")
        served_refs[_name] = _sha
    elif _args[_i] == "--served-routes" and _i + 1 < len(_args):
        _name, _, _file = _args[_i + 1].partition("=")
        served_deployed_routes[_name] = _file
    elif _args[_i] == "--served-strict-candidate" and _i + 1 < len(_args):
        served_strict_candidate.add(_args[_i + 1])
    elif _args[_i] == "--routes-only":
        routes_only = True
        _i += 1
        continue
    else:
        sys.exit(f"unrecognized check_site argument: {_args[_i]}")
    _i += 2


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

pages = {
    path: Page(path.read_text())
    for path in site.rglob("*.html")
    if not path.is_relative_to(site / "artifacts")
}
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
    # specs/26-live-links/ and specs/29-docs-links-recut/ are ticket-
    # orchestration records staged verbatim by tools/prepare_docs.py (which
    # copies all of specs/); they are not in the nav, and speech companions
    # for them may not be authored — the directories are ticket-owner owned.
    # Speech coverage continues to bind every reader-facing page, including
    # all nav-reachable specs pages.
    if path.is_relative_to(site / "specs" / "26-live-links") or path.is_relative_to(site / "specs" / "29-docs-links-recut"):
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
for required in ("docs/naming-demo/index.html", "docs/naming-lifecycle/index.html", "specs/protocol/spec/index.html", "docs/prior-art/index.html", "docs/design/index.html", "docs/decisions/index.html", "docs/simulation/index.html"):
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
    """Absolute href unchanged; relative href lands on the repository blob at
    the ref a reader of this tree is viewing — the candidate's own ref,
    derived from git, never a hardcoded branch."""
    parts = urlsplit(href)
    if parts.scheme or parts.netloc:
        return href
    assert CANDIDATE_REF, CANDIDATE_REF_ERROR
    return f"{REPO_BLOB}/{CANDIDATE_REF}/{href.lstrip('/')}"


def github_blob_url(source_md, href):
    """Rewrite href the way GitHub renders ``source_md`` as a blob page at the
    ref the reader is viewing (the candidate ref), so relative source links
    follow the viewed ref instead of a moving alias."""
    assert CANDIDATE_REF, CANDIDATE_REF_ERROR
    return urljoin(f"{REPO_BLOB}/{CANDIDATE_REF}/{source_md}", href)


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
        # Refs may contain slashes (feature branches like docs/live-links), so
        # the derived candidate ref is matched as an exact path prefix first;
        # only foreign refs go through the simple-label parse.
        m = re.match(r"^/lambdasistemi/singular/(?P<kind>blob|tree)/(?P<remainder>.+)$", parts.path)
        kind_name, remainder = m.group("kind"), m.group("remainder")
        if CANDIDATE_REF and remainder.startswith(f"{CANDIDATE_REF}/"):
            rel = unquote(remainder[len(CANDIDATE_REF) + 1:]).split("#")[0].rstrip("/")
            if not (root / rel).exists():
                result = ("fail", f"GitHub {kind_name}/{CANDIDATE_REF} 404: {rel} is not in the repository")
            else:
                # Candidate model evidence reaches the shipped lean/ sources
                # only through the inspected candidate's own ref; navigation
                # under that ref is existence-checked, while identity comes
                # from the ref binding plus the staged model/ byte comparison
                # — never from the path existing.
                result = ("pass", f"GitHub {kind_name}/{CANDIDATE_REF}:{rel}")
        else:
            simple = re.match(r"^(?P<ref>[^/]+)/(?P<rest>.+)$", remainder)
            ref = simple.group("ref") if simple else remainder
            rest = simple.group("rest") if simple else ""
            # Candidate model evidence bound to a foreign ref is the moving
            # alias class: it claims a version this candidate did not inspect
            # and fails for that reason — never an existence pass.
            model_evidence = kind_name == "blob" and re.search(r"(?:^|/)lean/", remainder) is not None
            if model_evidence:
                rel = unquote(remainder).split("#")[0].rstrip("/")
                result = ("fail", f"moving alias rejected: GitHub {kind_name}/{ref} is not bound to inspected candidate ref {CANDIDATE_REF}: {rel}")
            elif ref == "main":
                rel = unquote(rest).split("#")[0].rstrip("/")
                if not (root / rel).exists():
                    result = ("fail", f"GitHub {kind_name}/main 404: {rel} is not in the repository")
                else:
                    result = ("pass", f"GitHub {kind_name}/main:{rel}")
            else:
                result = ("blocked", f"self-repo pinned ref {ref} not verifiable offline")
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


def served_get(url):
    """GET with redirects followed. Returns (final_url, status, body, error):
    the final URL and status are what the server actually served after any
    redirects — observed, never assumed."""
    try:
        req = Request(url, headers={"User-Agent": "singular-docs-links-inventory"})
        with urlopen(req, timeout=EXTERNAL_TIMEOUT) as resp:
            return resp.url, resp.status, resp.read(), None
    except HTTPError as err:
        return getattr(err, "url", None) or url, err.code, b"", None
    except (URLError, TimeoutError, OSError) as err:
        return url, None, b"", f"network {type(err).__name__}: {err}"


def deployed_url(path):
    rel = path.relative_to(site).as_posix()
    if rel == "index.html":
        return SITE_URL
    if rel.endswith("/index.html"):
        return SITE_URL + rel[:-len("index.html")]
    return SITE_URL + rel


def authored_production_alias(href):
    """An absolute link into this site's production model/ tree: the moving
    production alias. Candidate model identity is proven from staged,
    candidate-relative artifacts (or the candidate ref on GitHub); an
    absolute production URL resolves to whatever main currently deploys, so
    it cannot carry a candidate's identity."""
    parts = urlsplit(href)
    return bool(parts.scheme) and parts.netloc == urlsplit(SITE_URL).netloc and parts.path.startswith(PREFIX + "model/")


production_alias_rows = []


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
    if authored_production_alias(href):
        production_alias_rows.append(("README.md", href))
for href in md_links(readme_text):
    plan_row("README.md (markdown)", href, [github_readme_url(href)])
    if authored_production_alias(href):
        production_alias_rows.append(("README.md (markdown)", href))

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
        if authored_production_alias(href):
            production_alias_rows.append((f"docs/{md.name}", href))
    for href in md_links(text):
        plan_row(f"docs/{md.name} (markdown)", href, [github_blob_url(f"docs/{md.name}", href)])
        if authored_production_alias(href):
            production_alias_rows.append((f"docs/{md.name} (markdown)", href))

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
    return (path.name == "404.html" or path.is_relative_to(site / "simulator")
            or path.is_relative_to(site / "specs" / "26-live-links")
            or path.is_relative_to(site / "specs" / "29-docs-links-recut"))

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

if routes_only:
    # Route-inventory extraction for a (possibly historical) site tree: the
    # same discovery pass as the full check, printed as evidence for
    # deployment-identity comparisons. No verdicts, no assertions. The route
    # set uses exactly the served path's flatten/filter logic so the extracted
    # inventory and the served verification agree on what an internal route is.
    print(json.dumps({
        "renderedPages": len(pages),
        "routes": sorted({u for _, _, resolved, _ in plans for u in resolved if classify(u) == "internal-site"}),
    }))
    sys.exit(0)

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
assert not production_alias_rows, f"production model alias is not candidate identity evidence (moving alias): {production_alias_rows}"

# ---------------------------------------------------------------------------
# Served routes (INV-29-PREFIX): what a server actually answers, for every
# distinct internal route the inventory discovered — judged from the final
# URL after redirects, per surface, with no-slash behavior observed rather
# than relabeled.
# ---------------------------------------------------------------------------
served_report, served_failures, served_blocked = {}, [], []
if served_bases and not failures:
    routes = sorted({u for _, _, resolved, _ in plans for u in resolved if classify(u) == "internal-site"})
    assert routes, "served-route check found no internal routes: the inventory discovered nothing"
    route_sources = {}
    for source, href, resolved, _ in plans:
        for u in resolved:
            if classify(u) == "internal-site":
                route_sources.setdefault(u, set()).add(source)

    def commit_exists(sha):
        return subprocess.run(["git", "-C", str(root), "cat-file", "-e", f"{sha}^{{commit}}"],
                              capture_output=True).returncode == 0

    surface_meta, surface_outcomes, surface_probes = {}, {}, {}
    for name, base in served_bases:
        if not base.endswith("/"):
            base += "/"
        github_io = urlsplit(base).netloc.endswith("github.io")
        identity, identity_evidence = "UNKNOWN", "no marker or ref provided"
        marker_url = served_markers.get(name)
        if marker_url:
            _, marker_status, marker_body, marker_err = served_get(marker_url)
            token = marker_body.decode("utf-8", "replace").strip() if marker_status == 200 and marker_err is None else None
            if token == CANDIDATE_SHA:
                identity, identity_evidence = "candidate", f"marker {marker_url} == this candidate"
            elif token and re.fullmatch(r"[0-9a-f]{40}", token) and commit_exists(token):
                identity, identity_evidence = f"prior:{token}", f"marker {marker_url} -> verified commit {token}"
            else:
                identity_evidence = f"marker {marker_url} -> {token!r} (not a verified commit)"
        elif served_refs.get(name):
            token = served_refs[name]
            if re.fullmatch(r"[0-9a-f]{40}", token) and commit_exists(token):
                identity = "candidate" if token == CANDIDATE_SHA else f"prior:{token}"
                identity_evidence = f"explicit deployment ref {token} (publisher record)"
            else:
                identity_evidence = f"explicit ref {token!r} not a verified commit"

        def mapped_url(route):
            """Remap a discovered internal route (absolute URL under the
            deployed prefix) onto this surface's base by slicing the URL's
            PATH component — never the raw URL string."""
            parts = urlsplit(route)
            assert parts.path.startswith(PREFIX), route
            mapped = base + parts.path[len(PREFIX):]
            if parts.query:
                mapped += "?" + parts.query
            if parts.fragment:
                mapped += "#" + parts.fragment
            return mapped

        mapped = {route: mapped_url(route) for route in routes}

        def check_route(route):
            parts = urlsplit(mapped[route])
            target = mapped[route].split("#")[0]
            final, status, body, err = served_get(target)
            if err is not None:
                return ("blocked", route, target, final, status, err)
            if status in (404, 410):
                return ("notfound", route, target, final, status, f"HTTP {status}")
            if status >= 400:
                return ("blocked", route, target, final, status, f"HTTP {status}")
            if urlsplit(final).path.rstrip("/") != parts.path.rstrip("/"):
                return ("fail", route, target, final, status, f"redirect landed at {final}, not the requested document {target}")
            if parts.fragment:
                ids = Page(body.decode("utf-8", "replace")).ids if body else set()
                if unquote(parts.fragment) not in ids:
                    return ("fail", route, target, final, status, f"missing anchor #{parts.fragment}")
            return ("pass", route, target, final, status, "redirected" if urlsplit(final).path != parts.path else "direct")

        def probe_no_slash(route):
            target = mapped[route][:-1]
            final, status, _, err = served_get(target)
            if err is not None:
                return "blocked"
            if status in (404, 410):
                return "notFound"
            if status == 200:
                final_path = urlsplit(final).path.rstrip("/")
                if final_path == urlsplit(mapped[route]).path.rstrip("/"):
                    return "redirectedToCanonical"
                if final_path == urlsplit(target).path.rstrip("/"):
                    return "servedUnredirected"
            return f"HTTP{status}"

        directory_routes = [r for r in routes if r.endswith("/")]
        with ThreadPoolExecutor(max_workers=EXTERNAL_CONCURRENCY) as pool:
            outcomes = list(pool.map(check_route, routes))
            probes = dict(zip(directory_routes, pool.map(probe_no_slash, directory_routes)))
        surface_meta[name] = {"base": base, "identity": identity, "identityEvidence": identity_evidence, "githubIo": github_io}
        surface_outcomes[name] = outcomes
        surface_probes[name] = probes

    # Which routes are proven served by candidate-identified surfaces — the
    # exact-candidate evidence a pending-publication claim requires.
    candidate_verified = {}
    for name, outcomes in surface_outcomes.items():
        if surface_meta[name]["identity"] == "candidate":
            for kind, route, *_ in outcomes:
                if kind == "pass":
                    candidate_verified.setdefault(route, set()).add(name)

    # absentUntilRelease is only provable when the route resolves on every
    # candidate-identity evidence surface in this run — the exact-candidate
    # preview AND the supported archive server (A-001's three-condition
    # proof). While the preview is a prior deployment, the class cannot fire
    # and rows stay pendingVerification instead.
    required_candidate_surfaces = {n for n in surface_meta if n in ("archive", "preview")}

    for name, outcomes in surface_outcomes.items():
        meta = surface_meta[name]
        identity, base = meta["identity"], meta["base"]
        probes = surface_probes[name]
        deployed_file = served_deployed_routes.get(name)
        deployed_routes = None
        if deployed_file is not None:
            deployed_routes = set(json.loads(Path(deployed_file).read_text())["routes"])
        # A surface declared to verify the candidate archive/current preview is
        # strict: it must carry EXACT candidate identity and complete route
        # success. Unknown or mismatched identity is an attributable nonzero
        # verification failure — never an accepted candidate-surface result —
        # and a strict surface can never emit acceptable pending rows.
        strict_candidate = name in served_strict_candidate
        strict_failures = []
        if strict_candidate and identity != "candidate":
            strict_failures.append(f"strict candidate verification cannot succeed: surface identity {identity} (evidence: {meta['identityEvidence']})")

        def row_for(route, target, final, status, detail):
            return {"route": route, "source": sorted(route_sources.get(route, [])),
                    "requested": target, "final": final, "http": status,
                    "candidateIdentity": CANDIDATE_SHA, "deploymentIdentity": identity,
                    "identityEvidence": meta["identityEvidence"], "detail": detail}

        pending_until_release, pending_verification, classified_fails = [], [], []
        canonical_kind = {}
        for kind, route, target, final, status, detail in outcomes:
            canonical_kind[route] = kind
            if kind != "notfound":
                if kind == "fail":
                    classified_fails.append(row_for(route, target, final, status, detail))
                continue
            # Fail-closed 404 ladder (deployment-bound, never inferred):
            #   candidate-identified surface -> must serve every route: fail.
            #   route in the deployment's own rendered route inventory ->
            #     regression on that deployment: fail.
            #   route proven candidate-new (resolves on candidate-identified
            #     surfaces) and the surface is a verified older deployment ->
            #     absentUntilRelease: not yet published; listed, never passed.
            #   anything unverifiable -> pendingVerification: deferred with
            #     its reason named, owned by the post-publication check.
            row = row_for(route, target, final, status, detail)
            if identity == "candidate":
                row.update(classification="fail", reason="candidate-identified surface must serve every discovered route")
                classified_fails.append(row)
            elif deployed_routes is not None and route in deployed_routes:
                row.update(classification="fail", reason=f"route is in the rendered route inventory of deployment {identity}: regression, not pending publication")
                classified_fails.append(row)
            elif identity.startswith("prior:") and required_candidate_surfaces and required_candidate_surfaces <= candidate_verified.get(route, set()):
                row.update(classification="absentUntilRelease", reason=f"not yet published: absent from deployment {identity}; proven served by candidate-identified surfaces {sorted(candidate_verified[route])}")
                pending_until_release.append(row)
            else:
                missing = []
                if not identity.startswith("prior:"):
                    missing.append(f"surface identity {identity} (evidence: {meta['identityEvidence']})")
                if not candidate_verified.get(route):
                    missing.append("route not yet proven on candidate-identified surfaces (exact-candidate preview pending push)")
                row.update(classification="pendingVerification", reason="deferred to the post-publication check: " + "; ".join(missing))
                pending_verification.append(row)
        no_slash_counts = {}
        for outcome in probes.values():
            no_slash_counts[outcome] = no_slash_counts.get(outcome, 0) + 1
        # GitHub Pages must redirect the no-slash form of a served directory
        # URL to the canonical document; judged only where the canonical route
        # itself resolved, so pending pages are counted once, not twice.
        no_slash_violations = [f"{route}: {outcome}" for route, outcome in probes.items()
                               if meta["githubIo"] and canonical_kind.get(route) == "pass" and outcome != "redirectedToCanonical"]
        if strict_candidate and (pending_until_release or pending_verification):
            strict_failures.append("strict candidate surface emitted pending rows: candidate evidence must be complete, not pending")
        pass_routes = [t for t in outcomes if t[0] == "pass"]
        block_routes = [t for t in outcomes if t[0] == "blocked"]
        served_report[name] = {
            "base": base,
            "identity": identity,
            "identityEvidence": meta["identityEvidence"],
            "strictCandidate": strict_candidate,
            "routes": len(routes),
            "pass": len(pass_routes),
            "fail": len(classified_fails),
            "pendingUntilRelease": len(pending_until_release),
            "pendingVerification": len(pending_verification),
            "blocked": len(block_routes),
            "redirected": sum(1 for t in pass_routes if t[5] == "redirected"),
            "noSlashProbes": {"probes": len(probes), **no_slash_counts},
            "failures": classified_fails,
            "pendingUntilReleaseRows": pending_until_release,
            "pendingVerificationRows": pending_verification,
            "noSlashViolations": no_slash_violations,
            "strictFailures": strict_failures,
        }
        served_failures += [(name, json.dumps(row, sort_keys=True)) for row in classified_fails]
        served_failures += [(name, e) for e in strict_failures]
        served_failures += [(name, f"no-slash not redirected on GitHub Pages surface: {v}") for v in no_slash_violations]
        served_blocked += [(name, t[5]) for t in outcomes if t[0] == "blocked"]

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
    "servedRoutes": served_report,
}))
assert not failures, f"link inventory failures: {json.dumps(failures, indent=2)}"
assert not served_failures, f"served-route failures: {json.dumps(served_failures, indent=2)}"
assert not served_blocked, f"served-route blocked: {json.dumps(served_blocked, indent=2)}"
