"""Freeze the money types and their kernel definition closure; bind outcomes."""

import copy
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent
BASE = "4126a9513582c85ea32634456740b590836678ec"
DEFINITION_BASE = "5cc33b11953f69be06b3ce26226c87ebf0978917"
NEW = "NoPin.ApplicationRequests.Money.Statements.registration_fold_journey_holding_separated"
OLD = "NoPin.ApplicationRequests.Money.Statements.registration_fold_journey"


def frozen_rows(ledger, frozen, checkpoint):
    rows = ledger["statements"]
    names = [row["theorem"] for row in rows]
    expected = [row["theorem"] for row in frozen["statements"]]
    if len(rows) != 13 or names != expected + [NEW]:
        raise ValueError("money supersession extent changed")
    for original, current in zip(frozen["statements"], rows[:12], strict=True):
        current = copy.deepcopy(current)
        if original["theorem"] == OLD:
            if current.pop("supersededBy", None) != NEW:
                raise ValueError("wrong money supersededBy")
        if current != original:
            raise ValueError("frozen money row changed: " + original["theorem"])
    if rows[-1].get("supersedes") != "registration_fold_journey":
        raise ValueError("money supersedes must name the refuted registration fold")
    if rows[-1]["statementSha256"] != checkpoint["statementSha256"]:
        raise ValueError("corrected money statement differs from checkpoint")


def digest(closure):
    return {
        row["name"]: hashlib.sha256(
            json.dumps(
                row, ensure_ascii=False, separators=(",", ":"), sort_keys=True
            ).encode()
        ).hexdigest()
        for row in closure
    }


def check(records, ledger):
    frozen = json.loads(
        subprocess.check_output(
            ["git", "show", BASE + ":investigations/741-no-pin/money-statements.json"],
            cwd=ROOT,
            text=True,
        )
    )
    checkpoint = json.loads(
        (ROOT / "money-holding-definition-baseline.json").read_text()
    )
    frozen_rows(ledger, frozen, checkpoint)
    closures = [r["moneyProofClosure"] for r in records if "moneyProofClosure" in r]
    if len(closures) != 1:
        raise ValueError("missing or duplicate money definition closure")
    baseline = json.loads((ROOT / "money-proof-definition-baseline.json").read_text())
    current = digest(closures[0])
    if (
        baseline["base"] != DEFINITION_BASE
        or current != baseline["constants"]
        or len(current) != len(closures[0])
    ):
        raise ValueError("money kernel definition closure changed")
    corrected = [
        r["moneyHoldingProofClosure"]
        for r in records
        if "moneyHoldingProofClosure" in r
    ]
    if len(corrected) != 1 or digest(corrected[0]) != checkpoint["constants"]:
        raise ValueError("corrected money definition closure changed")
    roots = [r for r in records if "moneyProofRoots" in r]
    if roots != [
        {
            "moneyProofRoots": [r["theorem"] for r in frozen["statements"]],
            "moneyHoldingProofRoot": NEW,
        }
    ]:
        raise ValueError("money closure roots differ from ledger names")
    import money_check

    target = next(r for r in ledger["statements"] if r["status"] == "PROVED")["theorem"]
    controls = []
    for index in range(12):
        proposed = copy.deepcopy(ledger)
        proposed["statements"][index]["description"] += " changed"
        try:
            frozen_rows(proposed, frozen, checkpoint)
        except ValueError:
            controls.append("frozen-row-" + str(index) + "-edit-refused")
        else:
            raise ValueError("edited frozen money row survived")
    for label, field, value in [
        ("supersedes-proved-row", "supersedes", "create_journey"),
        ("thirteenth-digest", "statementSha256", "0" * 64),
    ]:
        proposed = copy.deepcopy(ledger)
        proposed["statements"][-1][field] = value
        try:
            frozen_rows(proposed, frozen, checkpoint)
        except ValueError:
            controls.append(label + "-refused")
        else:
            raise ValueError("money supersession control survived: " + label)
    proposed = copy.deepcopy(ledger)
    changed = copy.deepcopy([r for r in records if r.get("family") == "money"])
    next(r for r in changed if r.get("name") == target)["axioms"] = ["sorryAx"]
    try:
        money_check.reconcile(changed, proposed)
    except ValueError:
        controls.append("money-proved-with-sorry-refused")
    else:
        raise ValueError("money PROVED row with sorry survived")
    proposed = copy.deepcopy(ledger)
    proposed["statements"][-1].update(status="PROVED", proofStatus="PROVED")
    changed = copy.deepcopy([r for r in records if r.get("family") == "money"])
    next(r for r in changed if r.get("name") == NEW)["axioms"] = ["sorryAx"]
    try:
        money_check.reconcile(changed, proposed)
    except ValueError:
        controls.append("corrected-money-proved-with-sorry-refused")
    else:
        raise ValueError("corrected money PROVED row with sorry survived")
    refuted = next(r for r in ledger["statements"] if r["status"] == "REFUTED")
    for field, value in [
        ("exact", False),
        ("name", "Neighbouring.negation"),
        ("axioms", ["sorryAx"]),
    ]:
        changed = copy.deepcopy([r for r in records if r.get("family") == "money"])
        next(r for r in changed if r.get("name") == refuted["theorem"])["refutation"][
            field
        ] = value
        try:
            money_check.reconcile(changed, ledger)
        except ValueError:
            controls.append("wrong-refutation-" + field + "-refused")
        else:
            raise ValueError("wrong money refutation survived: " + field)
    for family in ["history", "lifecycle"]:
        module = __import__(family + "_check")
        proposed = json.loads((ROOT / (family + "-statements.json")).read_text())
        module.reconcile(records, proposed)
        proposed["statements"][0]["status"] = "PROVED"
        try:
            module.reconcile(records, proposed)
        except ValueError:
            controls.append(family + "-out-of-scope-proof-refused")
        else:
            raise ValueError("out-of-scope proof survived: " + family)
    exact = [r for r in records if "moneyRefutationControl" in r]
    if exact != [{"moneyRefutationControl": True, "neighbouringRejected": True}]:
        raise ValueError("missing compiled money exact-negation control")
    import money_proof_controls
    import money_holding_controls

    return {
        "base": BASE,
        "definitionConstants": len(current),
        "holdingDefinitionConstants": len(checkpoint["constants"]),
        "statusControls": controls,
        "kernelControls": money_proof_controls.check(),
        "holdingControls": money_holding_controls.check(checkpoint),
    }
