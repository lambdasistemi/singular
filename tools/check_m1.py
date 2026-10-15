#!/usr/bin/env python3
"""Bind the permanent contract's executed receipts to sources and audited proofs.

The active corpus governs M1. M1 receipts name their own law and retain
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
    module_text,
    model_constants,
    model_fold_admission,
    fold_admission_reason,
    model_transitions,
    root_of,
    statement_inventory,
)


def check(corpus, root):
    source = module_text(root / "lean/Singular/Model.lean")
    body = source.split("def allowed ", 1)[1].split("\ndef delta ", 1)[0]
    allowed = set(re.findall(r"e == \.(\w+)", body))
    assert allowed == {"insertActive", "updateTerminal"}, "permanent admission moved"
    assert len(corpus["scenarios"]) == 10 and len(corpus["batches"]) == 5
    exclusions = set()
    admission = model_fold_admission(root)
    for row in corpus["scenarios"]:
        operation = row["operation"]
        if row["kind"] != "unsupported" and operation not in {"reject", "retract"}:
            why = fold_admission_reason(
                [row["request"]], row["start"]["config"], row["foldWitness"], admission
            )
            if why is not None:
                assert (row["outcome"], row["reason"]) == ("refused", why)
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
        why = fold_admission_reason(
            row["requests"],
            corpus["scenarios"][0]["start"]["config"],
            row["foldWitness"],
            admission,
        )
        if why is not None:
            assert (row["outcome"], row["reason"]) == ("refused", why)
        admitted_edges = row["requests"] and all(
            r["edge"] in allowed for r in row["requests"]
        )
        created = set()
        consumes_created = False
        for request in row["requests"]:
            if request["edge"] == "updateTerminal" and request["key"] in created:
                consumes_created = True
            if request["edge"] == "insertActive":
                created.add(request["key"])
        admitted = admitted_edges and not consumes_created
        assert (row["outcome"] == "accepted") == bool(admitted)
        if not admitted:
            assert row["observations"] is None
            assert row["reason"] == (
                "empty-fold"
                if not row["requests"]
                else "edge-inadmissible"
                if not admitted_edges
                else "token-missing"
            )
        else:
            state = row["observations"]["state"]
            keys = [request["key"] for request in row["requests"]]
            assert len(keys) == len(set(keys)) == 2
            assert sorted(state["trie"], key=lambda leaf: leaf["key"]) == [
                {"key": key, "leaf": "active"} for key in sorted(keys)
            ]
            assert sorted(h["key"] for h in state["held"]) == sorted(keys)
            assert all(h["kind"] == "active" for h in state["held"])
            assert not state["custody"]
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
        "retained observation and unobservable vocabulary",
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
        f"Permanent M1: {len(corpus['scenarios'])} scenarios, {len(corpus['batches'])} batches, "
        f"{derived} derived observations; 2 fault controls detected"
    )


if __name__ == "__main__":
    main()
