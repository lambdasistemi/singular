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
        self.feed(text)
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.add(attrs["id"])
            if tag in ("h2", "h3"):
                self.headings.add(attrs["id"])
        if tag == "a" and "href" in attrs:
            self.links.append(attrs["href"])

pages = {p: Page(p.read_text()) for p in site.rglob("*.html")}
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
    if path.name == "404.html":
        continue
    speech = path.parent.with_suffix(".speech.json") if path.parent != site else site / "index.speech.json"
    assert speech.exists(), f"missing speech: {speech}"
    data = json.loads(speech.read_text())
    assert page.headings <= data.keys(), f"missing spoken sections: {path}: {page.headings - data.keys()}"
    for key, segments in data.items():
        assert key in page.ids and segments, f"invalid speech heading: {path}: {key}"
        assert all(isinstance(x.get("text"), str) and x["text"] for x in segments)
for required in ("docs/naming-demo/index.html", "specs/protocol/spec/index.html", "docs/prior-art/index.html"):
    assert (site / required).exists(), required
home = (site / "index.html").read_text()
assert 'data-md-color-scheme="default"' in home and 'data-md-color-scheme="slate"' in home
assert 'assets/read-aloud.js' in home and 'rel="speech"' in home
print(json.dumps({"renderedPages": len(pages), "localLinksAndAnchors": links, "speechCoverage": "PASS", "productTests": False}))
