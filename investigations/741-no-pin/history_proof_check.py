# Tool, not a guarantee: replay the frozen investigation; no hosted job runs it.
"""Bind hypothetical history proof status and reached definitions to the base."""

import copy
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent
BASE = "2d84c4b8f35d2b0fd5e6d8e1419e3b921570d150"


def require(condition, message):
    if not condition:
        raise ValueError("history proof evidence: " + message)


def closure_digest(closure):
    return {
        row["name"]: hashlib.sha256(
            json.dumps(
                row, ensure_ascii=False, separators=(",", ":"), sort_keys=True
            ).encode()
        ).hexdigest()
        for row in closure
    }


def check(records, ledger):
    import history_check

    frozen = json.loads(
        subprocess.check_output(
            [
                "git",
                "show",
                BASE + ":investigations/741-no-pin/history-statements.json",
            ],
            cwd=ROOT,
            text=True,
        )
    )
    require(
        [{k: v for k, v in r.items() if k != "status"} for r in ledger["statements"]]
        == [
            {k: v for k, v in r.items() if k != "status"} for r in frozen["statements"]
        ],
        "frozen history statement rows changed",
    )
    closures = [r["historyProofClosure"] for r in records if "historyProofClosure" in r]
    require(len(closures) == 1, "missing or duplicate history closure")
    current = closure_digest(closures[0])
    baseline = json.loads((ROOT / "history-proof-definition-baseline.json").read_text())
    require(baseline["base"] == BASE, "wrong history baseline base")
    require(
        current == baseline["constants"], "history kernel definition closure changed"
    )
    require(len(current) == len(closures[0]), "duplicate closure constant")
    controls = []
    for family, file in [
        ("refund", "refund-lifecycle-statements.json"),
        ("money", "money-statements.json"),
        ("singular", "application-requests-statements.json"),
    ]:
        proposed = copy.deepcopy(ledger)
        foreign = json.loads((ROOT / file).read_text())["statements"][0]["theorem"]
        proposed["statements"][0].update(theorem=foreign, status="PROVED")
        try:
            history_check.reconcile(records, proposed)
        except ValueError:
            controls.append(family + "-as-history-proof-refused")
        else:
            raise ValueError(
                "foreign family survived history reconciliation: " + family
            )
    observed = copy.deepcopy(records)
    proposed = copy.deepcopy(ledger)
    target = proposed["statements"][0]["theorem"]
    next(r for r in observed if r.get("name") == target)["axioms"] = ["sorryAx"]
    proposed["statements"][0]["status"] = "PROVED"
    try:
        history_check.reconcile(observed, proposed)
    except ValueError:
        controls.append("history-proved-with-sorry-refused")
    else:
        raise ValueError("PROVED history with sorry survived")
    import history_proof_controls

    return {
        "base": BASE,
        "definitionConstants": len(current),
        "statusControls": controls,
        "kernelControls": history_proof_controls.check(),
    }
