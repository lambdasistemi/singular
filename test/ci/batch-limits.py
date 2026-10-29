#!/usr/bin/env python3
"""Exercise the published receipt consumer, including deliberate drift."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    marker = "<!-- batch-limits:start -->"
    pages = [p for p in (root / "docs").rglob("*.md") if marker in p.read_text()]
    assert len(pages) == 1, (
        "published documentation must contain exactly one receipt-generated batch limits block; "
        f"found {len(pages)}"
    )
    page = pages[0]
    receipt = root / "test/fixtures/batch-measurement/receipt.json"
    tool = root / "tools/batch_limits.py"

    def check(page_path, receipt_path):
        return subprocess.run(
            [
                sys.executable,
                str(tool),
                "--check",
                "--page",
                str(page_path),
                "--receipt",
                str(receipt_path),
            ],
            cwd=root,
            text=True,
            capture_output=True,
            check=False,
        )

    result = check(page, receipt)
    assert result.returncode == 0, result.stdout + result.stderr
    data = json.loads(receipt.read_text())
    controls = 0
    # Every displayed metric of every measured kind is changed independently.
    # The expected values come from the actual committed producer output.
    with tempfile.TemporaryDirectory(prefix="batch-limits-control-") as scratch:
        scratch = Path(scratch)
        for kind, workload in data["claim"]["workloads"].items():
            accepted = workload["samples"][workload["largestAccepted"] - 1]
            for metric in ("memory", "steps", "serializedBytes", "fee"):
                actual = str(accepted["measurement"][metric])
                assert actual in page.read_text(), f"{kind} {metric} is not published"
                changed_page = scratch / "page.md"
                changed_page.write_text(
                    page.read_text().replace(actual, str(int(actual) + 1), 1)
                )
                result = check(changed_page, receipt)
                assert result.returncode != 0 and "differs" in result.stderr, (
                    f"altered page accepted or refused for another reason: {result}"
                )
                changed = json.loads(receipt.read_text())
                changed["claim"]["workloads"][kind]["samples"][
                    workload["largestAccepted"] - 1
                ]["measurement"][metric] += 1
                changed_receipt = scratch / "receipt.json"
                changed_receipt.write_text(json.dumps(changed))
                result = check(page, changed_receipt)
                assert result.returncode != 0 and "differs" in result.stderr, (
                    f"altered receipt accepted or refused for another reason: {result}"
                )
                controls += 2
    print(
        f"batch limits: committed page matches the receipt; {controls} altered figures refused"
    )


if __name__ == "__main__":
    main()
