"""Freeze the money types and their kernel definition closure; bind outcomes."""

import copy
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent
BASE = "5cc33b11953f69be06b3ce26226c87ebf0978917"


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
    if [(r["theorem"], r["statementSha256"]) for r in ledger["statements"]] != [
        (r["theorem"], r["statementSha256"]) for r in frozen["statements"]
    ]:
        raise ValueError("frozen money statement identities changed")
    closures = [r["moneyProofClosure"] for r in records if "moneyProofClosure" in r]
    if len(closures) != 1:
        raise ValueError("missing or duplicate money definition closure")
    baseline = json.loads((ROOT / "money-proof-definition-baseline.json").read_text())
    current = digest(closures[0])
    if (
        baseline["base"] != BASE
        or current != baseline["constants"]
        or len(current) != len(closures[0])
    ):
        raise ValueError("money kernel definition closure changed")
    import money_check

    target = next(r for r in ledger["statements"] if r["status"] == "PROVED")["theorem"]
    controls = []
    proposed = copy.deepcopy(ledger)
    changed = copy.deepcopy([r for r in records if r.get("family") == "money"])
    next(r for r in changed if r.get("name") == target)["axioms"] = ["sorryAx"]
    try:
        money_check.reconcile(changed, proposed)
    except ValueError:
        controls.append("money-proved-with-sorry-refused")
    else:
        raise ValueError("money PROVED row with sorry survived")
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

    return {
        "base": BASE,
        "definitionConstants": len(current),
        "statusControls": controls,
        "kernelControls": money_proof_controls.check(),
    }
