#!/usr/bin/env python3
"""Bind the permanent contract's executed receipts to sources and audited proofs.

The broader corpus remains unchanged. M1 receipts name their own law and retain
the broader driver's observation vocabulary and its independently derived state
and mint checks. Controlled alterations must be noticed before publication.
"""

import argparse
import copy
import json
from pathlib import Path
import re
import subprocess

from check_model import (
    audit_sources,
    axiom_report,
    check_derived,
    check_records,
    check_or_compare,
    digest,
    model_constants,
    model_transitions,
    root_of,
    statement_inventory,
)


def check(corpus, root):
    source = (root / "lean/Singular/M1.lean").read_text()
    body = source.split("def allowed ", 1)[1].split("\ndef step ", 1)[0]
    allowed = set(re.findall(r"edge == \.(\w+)", body))
    assert allowed == {"insertActive", "updateTerminal"}, "permanent admission moved"
    assert len(corpus["scenarios"]) == 10 and len(corpus["batches"]) == 4
    exclusions = set()
    for row in corpus["scenarios"]:
        operation = row["operation"]
        if row["kind"] == "unsupported":
            assert row["outcome"] == "unsupported" and row["reason"] == "setup-refused"
        elif operation in allowed or operation in {"reject", "retract"}:
            assert row["outcome"] == "accepted" and row["observations"] is not None
        else:
            exclusions.add(operation)
            assert row["outcome"] == "refused" and row["reason"] == "edge-inadmissible"
        assert (row["outcome"] == "accepted") == (row["observations"] is not None)
    assert len(exclusions) == 5, "missing excluded edge"
    leaf_bytes, deltas = model_constants(root)
    derived = check_derived(corpus, leaf_bytes, deltas, model_transitions(root))
    for row in corpus["batches"]:
        admitted = row["requests"] and all(
            r["edge"] in allowed for r in row["requests"]
        )
        assert (row["outcome"] == "accepted") == bool(admitted)
        if not admitted:
            assert row["observations"] is None
            assert row["reason"] == (
                "edge-inadmissible" if row["requests"] else "empty-fold"
            )
        else:
            state = row["observations"]["state"]
            assert state["trie"] == [{"key": 5, "leaf": "terminal"}]
            assert not state["held"] and not state["custody"]
            assert state["config"]["root"] == root_of(state["trie"], leaf_bytes)
    return derived


def controls(corpus, root):
    for defect in ("excluded-admitted", "wrong-allowed-effect"):
        altered = copy.deepcopy(corpus)
        if defect == "excluded-admitted":
            row = next(
                r for r in altered["scenarios"] if r["reason"] == "edge-inadmissible"
            )
            row["outcome"] = "accepted"
        else:
            row = next(
                r for r in altered["scenarios"] if r["operation"] == "insertActive"
            )
            row["observations"]["leaf"] = "terminal"
        try:
            check(altered, root)
        except AssertionError:
            continue
        raise AssertionError(f"control was undetected: {defect}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root", type=Path, default=Path(__file__).resolve().parent.parent
    )
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--axioms-report", type=Path)
    parser.add_argument("--export", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    audit_sources(root)
    records = statement_inventory(
        root / "lean/Singular/M1.lean", "Singular.M1.Statements."
    )
    report = args.axioms_report
    if report is None:
        output = subprocess.check_output(
            ["lake", "env", "lean", "tools/m1_axioms.lean"], cwd=root
        )
        report = root / ".lake/m1-axioms-report.txt"
        report.write_bytes(output)
    axioms = axiom_report(root, report)
    assert set(axioms) == {r["name"] for r in records}
    check_records(records, axioms, "permanent contract")
    check_or_compare(
        root / "lean/m1-theorem-debt.json",
        json.dumps(records, indent=2) + "\n",
        args.export,
        "permanent theorem manifest",
    )
    binary = args.binary or root / ".lake/build/bin/singular-m1"
    corpus = json.loads(subprocess.check_output([str(binary)]))
    bindings = {r["name"]: r["statementSha256"] for r in records}
    for row in corpus["scenarios"]:
        # Attach the digest read from the independently audited declaration;
        # the executable carries no handwritten assertion of proof identity.
        row["statementSha256"] = bindings[row["theorem"]]
    derived = check(corpus, root)
    controls(corpus, root)
    corpus["sourceHashes"] = {
        str(p.relative_to(root)): digest(p.read_bytes())
        for p in sorted((root / "lean").rglob("*.lean"))
    }
    corpus["theoremManifestSha256"] = digest(
        (root / "lean/m1-theorem-debt.json").read_bytes()
    )
    corpus["limits"] = [
        "abstract model execution, not ledger acceptance",
        "unchanged broader observation and unobservable vocabulary",
        "excluded setup is unsupported, not an executed refusal",
    ]
    corpus["payloadSha256"] = digest(
        json.dumps(corpus, sort_keys=True, separators=(",", ":")).encode()
    )
    check_or_compare(
        root / "lean/m1-corpus.json",
        json.dumps(corpus, indent=2, sort_keys=True) + "\n",
        args.export,
        "permanent corpus",
    )
    print(
        f"Permanent M1: 10 scenarios, 4 batches, {derived} derived observations; 2 fault controls detected"
    )


if __name__ == "__main__":
    main()
