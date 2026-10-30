"""Check that the release notes and the documentation state what the release assumes.

Obligation: check_release.py calls check(), and the release check runs the controls
with --selftest. Four statements must stand in the release notes and on the
documentation page, each as its own sentence; a missing one is named in the failure.
"""

import re
import sys
import tempfile
from pathlib import Path

NOTES = "RELEASE.md"
PAGE = "docs/release-assumptions.md"
HEADING = "## What this release assumes and does not establish"
CONFORMANCE = "https://lambdasistemi.github.io/singular/docs/conformance-evidence/"
LIMITS = (
    (
        "trie-library-proofs-assumed-sound",
        "The trie library's proofs are assumed sound.",
        "The trie library's proofs are assumed sound.",
    ),
    (
        "script-execution-rule-assumed",
        "The statements about the chain's history assume Cardano's rule for how "
        "scripts run, and that rule is not proved here.",
        "The statements about the chain's history assume Cardano's rule for how "
        "scripts run, and that rule is not proved here.",
    ),
    (
        "development-node-cannot-run-the-public-network-version",
        "The packaged development node cannot run the public test network's "
        "(preprod's) current protocol version, so the batch limits are evaluated "
        "under recorded protocol parameters and corroborated by the node, and are "
        "not submitted to that network.",
        "The packaged development node cannot run the public test network's "
        "(preprod's) current protocol version, so the batch limits are evaluated "
        "under recorded protocol parameters and corroborated by the node, and are "
        "not submitted to that network.",
    ),
    (
        "uncovered-conformance-rows-published",
        "The conformance rows that remain uncovered are published on the "
        f"[conformance evidence page]({CONFORMANCE}), whose count and rows are "
        "computed from the receipts.",
        "The conformance rows that remain uncovered are published on the "
        "[conformance evidence page](conformance-evidence.md), whose count and rows "
        "are computed from the receipts.",
    ),
)
PLACES = (("the release notes", NOTES, 1), ("the documentation page", PAGE, 2))


def normalise(text):
    return " ".join(text.split())


def section(text):
    """The notes' section on what the release assumes, or None."""
    match = re.search(rf"^{re.escape(HEADING)}\n(.*?)(?=^## |\Z)", text, re.M | re.S)
    return match[1] if match else None


def check(root):
    problems = []
    for place, name, column in PLACES:
        text = normalise((Path(root) / name).read_text())
        for limit in LIMITS:
            if normalise(limit[column]) not in text:
                problems.append(f"{place} lacks the stated limit {limit[0]}")
    stated = section((Path(root) / NOTES).read_text())
    if stated is None:
        problems.append("the release notes have no section on what the release assumes")
    elif re.search(r"\d", stated):
        problems.append(
            "the release notes type a number where the evidence page computes it"
        )
    assert not problems, "; ".join(problems)


def selftest(root):
    root = Path(root)
    check(root)
    refused = 0

    def refuses(directory, *expected):
        nonlocal refused
        try:
            check(directory)
        except AssertionError as error:
            for fragment in expected:
                assert fragment in str(error), f"refused for another reason: {error}"
        else:
            raise AssertionError("the check accepted: " + " ".join(expected))
        refused += 1

    with tempfile.TemporaryDirectory(prefix="release-limits-control-") as directory:
        scratch = Path(directory)
        (scratch / "docs").mkdir()
        for _, name, _ in PLACES:
            (scratch / name).write_text((root / name).read_text())
        for place, name, column in PLACES:
            original = (root / name).read_text()
            for limit in LIMITS:
                spread = r"\s+".join(map(re.escape, limit[column].split()))
                removed, count = re.subn(spread, "", original)
                assert count == 1, f"{limit[0]} is not stated once in {name}"
                (scratch / name).write_text(removed)
                refuses(scratch, f"{place} lacks the stated limit {limit[0]}")
            (scratch / name).write_text(original)
        notes = (root / NOTES).read_text()
        (scratch / NOTES).write_text(notes.replace(HEADING, "## Elsewhere"))
        refuses(scratch, "no section on what the release assumes")
        stated = section(notes)
        (scratch / NOTES).write_text(
            notes.replace(stated, stated + "\nThere are 22 rows.\n")
        )
        refuses(scratch, "type a number")
    print(
        f"release limits: the four statements stand in both places; {refused} removals refused"
    )


if __name__ == "__main__":
    if sys.argv[1] == "--selftest":
        selftest(sys.argv[2])
    else:
        check(sys.argv[1])
        print(
            "release limits: the four statements stand in the release notes and the page"
        )
