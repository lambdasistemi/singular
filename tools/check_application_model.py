#!/usr/bin/env python3
"""Cross-check the open-datum theorem ledger against a saved compiled axiom report.

The application executable is the only writer of `applications/open-datum/ledgers.json`:
it derives each row's proof status and header hash from the statements the compiled
environment declares. This bridge is a second, independent reading, in the manner of
`tools/check_model.py` for the root model. It never writes anything. From

* the saved output of `lake env lean applications/open-datum/lean/AuditReport.lean`
  (one `AXIOMS <name> [<axioms>]` line per public theorem, collected afresh),
* the source of `OpenDatumApplication/Statements.lean`, and
* the committed ledger,

it requires the three statement extents to be equal, each row's axioms to be the
reported ones, its status to be `PROVED` exactly on the standard axioms and `STATED`
exactly on `sorryAx` without a custom axiom, and its `statementSha256` to be the SHA-256
of the declaration header as written (`theorem` through the first ` := by`). Its own
controls then show that each of those checks refuses a tampered input.

Usage: check_application_model.py --axioms-report REPORT [--root DIR]
"""

import argparse
import copy
import hashlib
import json
from pathlib import Path
import re
import sys

STANDARD = {"propext", "Classical.choice", "Quot.sound"}
PREFIX = "OpenDatumApplication.Statements."
STATEMENTS = "applications/open-datum/lean/OpenDatumApplication/Statements.lean"
LEDGERS = "applications/open-datum/ledgers.json"


class Refused(Exception):
    pass


def parse_report(text):
    """The report's statements and their axioms; refuse a duplicate or malformed line."""
    report = {}
    for line in text.splitlines():
        if not line.startswith("AXIOMS "):
            continue
        match = re.fullmatch(r"AXIOMS (\S+) \[(.*)\]", line)
        if not match:
            raise Refused(f"malformed report line: {line!r}")
        name, axioms = match[1], [a.strip() for a in match[2].split(",") if a.strip()]
        if name in report:
            raise Refused(f"duplicate report line for {name}")
        report[name] = axioms
    if not report:
        raise Refused("empty or truncated report: no AXIOMS line")
    return report


def headers(source):
    """Every public theorem's header as written, keyed by qualified name."""
    found = {}
    for match in re.finditer(r"(?m)^theorem (\w+) ([\s\S]*?) := by", source):
        name = PREFIX + match[1]
        if name in found:
            raise Refused(f"theorem {name} declared twice")
        found[name] = f"theorem {match[1]} {match[2]} := by"
    return found


def status_of(name, axioms):
    extra = set(axioms) - STANDARD
    if not extra:
        return "PROVED"
    if extra == {"sorryAx"}:
        return "STATED"
    raise Refused(f"{name} depends on custom axioms {sorted(extra - {'sorryAx'})}")


def check(report, declared, ledger):
    """Refuse unless ledger, report and source agree on every statement."""
    rows = ledger["theorems"]
    names = [row["statement"] for row in rows]
    if len(set(names)) != len(names):
        raise Refused("ledger lists a statement twice")
    for label, extent in (("report", set(report)), ("source", set(declared))):
        if extent != set(names):
            raise Refused(
                f"{label} extent differs from the ledger: "
                f"missing {sorted(set(names) - extent)}, extra {sorted(extent - set(names))}"
            )
    for row in rows:
        name = row["statement"]
        if sorted(row["axioms"]) != sorted(report[name]):
            raise Refused(
                f"{name}: ledger axioms {row['axioms']} are not the reported {report[name]}"
            )
        expected = status_of(name, report[name])
        if row["status"] != expected:
            raise Refused(
                f"{name}: ledger status {row['status']} but the report establishes {expected}"
            )
        digest = hashlib.sha256(declared[name].encode()).hexdigest()
        if row["statementSha256"] != digest:
            raise Refused(
                f"{name}: ledger statementSha256 is not the hash of its header as written"
            )
    return sum(row["status"] == "PROVED" for row in rows), len(rows)


def refuses(label, expected, report, declared, ledger):
    """A control passes only when the check refuses for the reason it targets."""
    try:
        check(report, declared, ledger)
    except Refused as reason:
        if expected in str(reason):
            print(f"PASS control: {label} ({reason})")
            return 0
        print(f"FAIL control: {label} was refused for another reason ({reason})")
        return 1
    print(f"FAIL control: {label} was accepted")
    return 1


def with_axioms(ledger, name, axioms):
    """The ledger with one row's axioms replaced, its status left as it was."""
    altered = copy.deepcopy(ledger)
    for row in altered["theorems"]:
        if row["statement"] == name:
            row["axioms"] = axioms
    return altered


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--axioms-report", required=True, type=Path)
    parser.add_argument("--root", default=".", type=Path)
    args = parser.parse_args()
    try:
        report = parse_report(args.axioms_report.read_text())
        declared = headers((args.root / STATEMENTS).read_text())
        ledger = json.loads((args.root / LEDGERS).read_text())
        proved, total = check(report, declared, ledger)
    except (Refused, OSError, KeyError, json.JSONDecodeError) as reason:
        print(f"FAIL {reason}")
        return 1
    print(f"PASS ledger, compiled report and source agree: {proved}/{total} PROVED")

    failed = 0
    first = ledger["theorems"][0]["statement"]
    flipped = copy.deepcopy(ledger)
    flipped["theorems"][0]["status"] = (
        "STATED" if flipped["theorems"][0]["status"] == "PROVED" else "PROVED"
    )
    failed += refuses(
        "a flipped ledger status",
        "but the report establishes",
        report,
        declared,
        flipped,
    )
    failed += refuses(
        "a report missing one statement",
        "report extent differs",
        {k: v for k, v in report.items() if k != first},
        declared,
        ledger,
    )
    failed += refuses(
        "a report naming an extra statement",
        "report extent differs",
        {**report, PREFIX + "not_a_statement": ["propext"]},
        declared,
        ledger,
    )
    custom = report[first] + ["OpenDatumApplication.customAxiom"]
    failed += refuses(
        "a statement depending on a custom axiom",
        "custom axioms",
        {**report, first: custom},
        declared,
        with_axioms(ledger, first, custom),
    )
    sorried = report[first] + ["sorryAx"]
    failed += refuses(
        "a report of sorryAx for a row the ledger calls proved",
        "but the report establishes STATED",
        {**report, first: sorried},
        declared,
        with_axioms(ledger, first, sorried),
    )
    failed += refuses(
        "a header changed by one byte",
        "not the hash of its header",
        report,
        {**declared, first: declared[first] + " "},
        ledger,
    )
    failed += refuses(
        "a ledger row whose axioms are not the reported ones",
        "are not the reported",
        report,
        declared,
        with_axioms(ledger, first, ["propext"]),
    )
    for label, text in (
        ("a truncated report", ""),
        ("a duplicated report line", "AXIOMS a [propext]\nAXIOMS a [propext]\n"),
    ):
        try:
            parse_report(text)
            print(f"FAIL control: {label} was accepted")
            failed += 1
        except Refused as reason:
            print(f"PASS control: {label} ({reason})")
    print(f"application ledger bridge: {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
