#!/usr/bin/env python3
"""Check the user guide's rendered reading route and command examples."""

from html.parser import HTMLParser
from pathlib import Path
import re

import markdown


class Guide(HTMLParser):
    def __init__(self):
        super().__init__()
        self.code = []
        self.current = None

    def handle_starttag(self, tag, attrs):
        if tag == "code":
            self.current = []

    def handle_data(self, data):
        if self.current is not None:
            self.current.append(data)

    def handle_endtag(self, tag):
        if tag == "code" and self.current is not None:
            self.code.append("".join(self.current))
            self.current = None


def check(page, navigation):
    rendered = Guide()
    rendered.feed(markdown.markdown(page, extensions=["fenced_code", "tables"]))
    diagrams = [block for block in rendered.code if "flowchart" in block]
    assert diagrams, "the published guide does not show the folder's flow"
    assert "docs/folding-requests.md" in navigation, (
        "the guide is absent from navigation"
    )
    commands = [block for block in rendered.code if block.startswith("open-datum fold")]
    assert any(
        "--pending" not in block and "--limit" not in block for block in commands
    ), "no discovering fold example"
    assert any("--limit" in block and "--pending" not in block for block in commands), (
        "no capped discovery example"
    )
    assert any(block.count("--pending") > 1 for block in commands), (
        "no explicit named-batch example"
    )
    # Prose review remains necessary: these checks establish a reading route,
    # actual rendered command blocks and the presence of named accounting.
    for field in ("folded", "skipped", "left"):
        assert re.search(r"`" + field + r"`", page), f"missing receipt field {field}"


def main():
    page = Path("docs/folding-requests.md").read_text()
    navigation = Path("mkdocs.yml").read_text()
    check(page, navigation)
    print(
        "batch user guide: rendered flow, navigation, commands and receipt accounting present"
    )


if __name__ == "__main__":
    main()
