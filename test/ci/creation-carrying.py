#!/usr/bin/env python3
"""Exercise the real page checker with missing carrying evidence and prose."""

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path.cwd()
with tempfile.TemporaryDirectory(prefix="creation-carrying-") as directory:
    probe = Path(directory)
    evidence = Path("specs/745-shared-publications/evidence")
    shutil.copytree(root / evidence, probe / evidence)
    (probe / "docs").mkdir()
    page = probe / "docs/creation-cost.md"
    original_page = (root / "docs/creation-cost.md").read_text()
    page.write_text(original_page)
    path = probe / evidence / "carrying.json"
    original_receipt = path.read_bytes()

    def check(label, accepted):
        answer = subprocess.run(
            [sys.executable, str(root / "tools/creation-cost.py"), "check"],
            cwd=probe,
            capture_output=True,
            text=True,
            check=False,
        )
        if (answer.returncode == 0) != accepted:
            sys.exit(
                f"creation-carrying: checker {'refused' if accepted else 'accepted'} {label}: {answer.stderr}"
            )
        if not accepted and not any(
            word in answer.stderr.lower() for word in ("carrying", "page differs")
        ):
            sys.exit(
                "creation-carrying: another failure is not the intended control: "
                + answer.stderr
            )
        print(f"creation-carrying: {label}: {'accepted' if accepted else 'refused'}")

    check("the unaltered comparison", True)
    path.unlink()
    check("a missing carrying experiment", False)
    path.write_bytes(original_receipt)
    start = original_page.find("## Can creation carry its scripts")
    if start >= 0:
        end = original_page.index("## Matched conditions and evidence", start)
        page.write_text(original_page[:start] + original_page[end:])
    check("a page with no carrying outcomes", False)
    page.write_text(original_page)
    receipt = json.loads(original_receipt)
    receipt["forms"][0]["evaluation"] = []
    receipt["forms"][0]["fits"] = True
    path.write_text(json.dumps(receipt))
    check("a size-only fit without execution", False)
    path.write_bytes(original_receipt)
    if start >= 0:
        figure = str(receipt["forms"][1]["sizeBytes"])
        altered = original_page.replace(figure, str(int(figure) + 1), 1)
        if altered == original_page:
            sys.exit(
                "creation-carrying: the page figure control did not alter a figure"
            )
        page.write_text(altered)
        check("an altered carrying figure on the page", False)
