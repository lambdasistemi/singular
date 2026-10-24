"""Bind hypothetical proof outcomes to unchanged kernel statements and definitions."""

import copy
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent
BASE = "47275241c6b8aa2ca5f64cc42e52629dd3804dde"
STANDARD = {"propext", "Classical.choice", "Quot.sound"}


def require(condition, message):
    if not condition:
        raise ValueError("Singular proof evidence: " + message)


def baseline_rows():
    return json.loads(
        subprocess.check_output(
            [
                "git",
                "show",
                BASE
                + ":investigations/741-no-pin/application-requests-statements.json",
            ],
            cwd=ROOT,
            text=True,
        )
    )["statements"]


def reconcile(records, ledger, baseline):
    statements = {
        record["name"]: record
        for record in records
        if record.get("family") == "application-requests" and "name" in record
    }
    require(
        len(ledger["statements"]) == len(baseline) == 16, "statement extent changed"
    )
    for row, frozen in zip(ledger["statements"], baseline, strict=True):
        require(
            row["theorem"] == frozen["theorem"], "statement order or identity changed"
        )
        require(
            row["statementSha256"] == frozen["statementSha256"], "statement changed"
        )
        declaration = statements[row["theorem"]]
        require(
            hashlib.sha256(declaration["type"].encode()).hexdigest()
            == frozen["statementSha256"],
            "compiled statement changed",
        )
        axioms = set(declaration["axioms"])
        require(axioms <= STANDARD | {"sorryAx"}, "custom or compiler-trust axiom")
        status = "STATED" if "sorryAx" in axioms else "PROVED"
        require(
            row["proofStatus"] == status and row["status"] in {status, "REFUTED"},
            "status does not match axioms",
        )
        if row["status"] == "REFUTED":
            refutation = declaration.get("refutation") or {}
            require(
                refutation.get("name") == row.get("refutation")
                and refutation.get("exact") is True,
                "refutation is not the exact negation",
            )
            require(
                set(refutation.get("axioms", ["missing"])) <= STANDARD,
                "unproved refutation",
            )
    closures = [
        record["proofClosure"] for record in records if "proofClosure" in record
    ]
    require(len(closures) == 1, "missing or duplicate definition closure")
    closure = closures[0]
    current = {
        record["name"]: hashlib.sha256(
            json.dumps(
                record, ensure_ascii=False, separators=(",", ":"), sort_keys=True
            ).encode()
        ).hexdigest()
        for record in closure
    }
    require(len(current) == len(closure), "duplicate closure constant")
    frozen = json.loads((ROOT / "proof-definition-baseline.json").read_text())
    require(frozen["base"] == BASE, "wrong definition baseline")
    require(current == frozen["constants"], "kernel definition closure changed")
    return {
        "status": "HYPOTHETICAL-PROOF-CANDIDATE",
        "acceptedLaw": False,
        "statements": len(baseline),
        "proved": sum(row["proofStatus"] == "PROVED" for row in ledger["statements"]),
        "open": sum(row["status"] == "STATED" for row in ledger["statements"]),
        "refuted": sum(row["status"] == "REFUTED" for row in ledger["statements"]),
        "definitionConstants": len(current),
    }


def check(records):
    ledger = json.loads((ROOT / "application-requests-statements.json").read_text())
    baseline = baseline_rows()
    result = reconcile(records, ledger, baseline)
    controls = []
    for label in [
        "statement-change",
        "proved-sorry",
        "custom-axiom",
        "native-decide",
        "definition-change",
    ]:
        changed = copy.deepcopy(records)
        target = next(
            record
            for record in changed
            if record.get("name") == ledger["statements"][0]["theorem"]
        )
        changed_ledger = copy.deepcopy(ledger)
        if label == "statement-change":
            target["type"] += " altered"
        elif label == "proved-sorry":
            target["axioms"] = ["sorryAx"]
            changed_ledger["statements"][0]["status"] = "PROVED"
            changed_ledger["statements"][0]["proofStatus"] = "PROVED"
        elif label in {"custom-axiom", "native-decide"}:
            target["axioms"] = [
                "Control.untrusted" if label == "custom-axiom" else "Lean.ofReduceBool"
            ]
        else:
            next(
                record["proofClosure"] for record in changed if "proofClosure" in record
            )[0]["value"] = "weakened"
        try:
            reconcile(changed, changed_ledger, baseline)
        except ValueError as error:
            controls.append({"control": label, "refused": str(error)})
        else:
            raise ValueError("proof control survived: " + label)
    print(json.dumps({**result, "reportControls": controls}, sort_keys=True))
    import proof_controls

    proof_controls.check()
