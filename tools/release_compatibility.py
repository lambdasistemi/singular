"""Check that the release notes follow the compatibility record and name no version.

Obligation: check_release.py calls check(), and the release check runs the controls
with --selftest. The notes are uploaded unchanged with every release, so they carry no
version number, no tag and no bare issue or pull request number. A section links the
compatibility record and states what the commands do for each kind of answer the record
gives; the check reads the record and refuses notes that do not state one of its kinds,
so the notes cannot drift from the page. A missing pointer, statement, version or number
is named in the failure.
"""

import json
import re
import sys
import tempfile
from pathlib import Path

NOTES = "RELEASE.md"
HEADING = "## Registries made by an earlier release"
POINTER = "https://lambdasistemi.github.io/singular/docs/compatibility/"
RECORD = "docs/compatibility.rows.json"
# What the notes say of each kind of answer the record gives, keyed by the kind the
# record uses. A kind the record gives that is not here, or a statement the notes lack,
# is refused.
STATEMENTS = {
    "this-release": "are served by these commands, with no guidance and no refusal",
    "earlier-release": (
        "these commands name that release, and a command that would change such a "
        "registry refuses before anything is built"
    ),
    "no-release": (
        "these commands say that no release is known, and a command that would "
        "change such a registry refuses before anything is built"
    ),
}
ANSWER_ALIKE = "The commands `singular` and `open-datum` answer the same way."
# A dotted version, a tag, or a bare number sign followed by digits. The
# placeholder <version> that names the files of a release is not one of them.
VERSION = re.compile(r"(?<![\w.])v?\d+\.\d+(?:\.\d+)?(?![\w])|(?<![\w])v\d+(?![\w])")
BARE_NUMBER = re.compile(r"(?<![\w&])#\d+")


def normalise(text):
    return " ".join(text.split())


def section(text):
    """The notes' section on registries of earlier releases, or None."""
    match = re.search(rf"^{re.escape(HEADING)}\n(.*?)(?=^## |\Z)", text, re.M | re.S)
    return match[1] if match else None


def kinds_of(record):
    """The kinds of answer the compatibility record gives, wherever it gives one."""
    return {
        row["served-by"]["kind"]
        for key in ("releases", "contracts-without-release", "applications")
        for row in record[key]
    }


def problems_in(text, record):
    problems = []
    for kind in sorted(kinds_of(record) - set(STATEMENTS)):
        problems.append(
            f"the compatibility record gives the answer {kind} that the release notes "
            "do not state"
        )
    stated = section(text)
    if stated is None:
        problems.append(
            "the release notes lack the section compatibility-record-pointed-at"
        )
    else:
        if f"]({POINTER})" not in stated:
            problems.append(
                "the release notes lack the compatibility-record-pointed-at link "
                f"to {POINTER} in their section on registries of earlier releases"
            )
        spoken = normalise(stated)
        for sentence in (ANSWER_ALIKE, *STATEMENTS.values()):
            if sentence not in spoken:
                problems.append(
                    f"the section on registries of earlier releases lacks the statement: {sentence}"
                )
    if VERSION.search(text):
        problems.append(
            "the release notes name a version where none belongs: "
            + VERSION.search(text)[0]
            + " (release-notes-name-no-version)"
        )
    if BARE_NUMBER.search(text):
        problems.append(
            "the release notes name a bare issue or pull request number: "
            + BARE_NUMBER.search(text)[0]
            + " (release-notes-name-no-issue-number)"
        )
    return problems


def read_record(root):
    path = Path(root) / RECORD
    assert path.is_file(), f"the compatibility record is missing: {RECORD}"
    return json.loads(path.read_text())


def check(root):
    problems = problems_in((Path(root) / NOTES).read_text(), read_record(root))
    assert not problems, "; ".join(problems)


def selftest(root):
    root = Path(root)
    check(root)
    original = (root / NOTES).read_text()
    stated = section(original)
    assert stated is not None and POINTER in stated, "the real notes lack the pointer"
    record_text = (root / RECORD).read_text()
    refused = 0

    def refuses(text, *expected, record=record_text):
        nonlocal refused
        assert text != original or record != record_text, (
            "a control that changes nothing proves nothing"
        )
        with tempfile.TemporaryDirectory(
            prefix="release-compatibility-control-"
        ) as directory:
            (Path(directory) / NOTES).write_text(text)
            if record is not None:
                (Path(directory) / RECORD).parent.mkdir(parents=True, exist_ok=True)
                (Path(directory) / RECORD).write_text(record)
            try:
                check(directory)
            except AssertionError as error:
                for fragment in expected:
                    assert fragment in str(error), (
                        f"refused for another reason: {error}"
                    )
            else:
                raise AssertionError("the check accepted: " + " ".join(expected))
        refused += 1

    # The pointer: removed, aimed at another page, and moved out of its section.
    refuses(original.replace(POINTER, ""), "compatibility-record-pointed-at link")
    refuses(
        original.replace(
            POINTER, "https://lambdasistemi.github.io/singular/docs/install/"
        ),
        "compatibility-record-pointed-at link",
    )
    refuses(
        original.replace(
            stated, stated.replace(POINTER, "https://example.invalid/")
        ).rstrip("\n")
        + f"\n\nElsewhere: [record]({POINTER})\n",
        "compatibility-record-pointed-at link",
    )
    # The section itself, and each of its two statements.
    refuses(
        original.replace(HEADING, "## Elsewhere"),
        "section compatibility-record-pointed-at",
    )
    for sentence in (ANSWER_ALIKE, *STATEMENTS.values()):
        spread = r"\s+".join(map(re.escape, sentence.split()))
        removed, count = re.subn(spread, "X", original)
        assert count == 1, f"{sentence} is not stated once in the notes"
        refuses(removed, sentence)
    # The notes follow the record: a kind of answer the record gives that the notes do
    # not state, and a record that is missing, are each refused.
    changed = json.loads(record_text)
    changed["releases"][0]["served-by"] = {"kind": "served-by-application"}
    refuses(
        original,
        "gives the answer served-by-application that the release notes do not state",
        record=json.dumps(changed),
    )
    refuses(original, "the compatibility record is missing", record=None)
    # A version, a tag and a bare number are each named.
    for added, name in (
        ("This is release 1.0.0.", "release-notes-name-no-version"),
        ("Download v1.0.0 now.", "release-notes-name-no-version"),
        ("See the 1.0 line.", "release-notes-name-no-version"),
        ("Tracked as #123.", "release-notes-name-no-issue-number"),
    ):
        refuses(original.rstrip("\n") + "\n\n" + added + "\n", name)
    print(
        "release compatibility: the notes point at the compatibility record and name no "
        f"version; {refused} removals and additions refused"
    )


if __name__ == "__main__":
    if sys.argv[1] == "--selftest":
        selftest(sys.argv[2])
    else:
        check(sys.argv[1])
        print("release compatibility: the notes point at the compatibility record")
