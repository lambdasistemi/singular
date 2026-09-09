"""Check rendered local links, speech coverage and required documentation surfaces."""
from html.parser import HTMLParser
import json
from pathlib import Path
import sys
from urllib.parse import unquote, urlsplit

site = Path(sys.argv[1]).resolve()
class Page(HTMLParser):
    def __init__(self, text):
        super().__init__()
        self.ids, self.links, self.headings = set(), [], set()
        self.scripts, self.stylesheets, self.mermaid = [], [], 0
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
print(json.dumps({"renderedPages": len(pages), "localLinksAndAnchors": links, "speechCoverage": "PASS", "externalResources": 0, "diagramPages": len(mermaid_pages), "diagrams": sum(p.mermaid for p in pages.values()), "scope": "rendered documentation; model and simulator checked separately"}))
