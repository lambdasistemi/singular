# Tool, not a guarantee: replay the frozen investigation; no hosted job runs it.
"""Frozen refund statement and definition identities, including hostile controls."""

import copy
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent
BASE = "56db38c7e244b075f713b6028afb5ff9bcc50d32"


def require(condition, message):
    if not condition:
        raise ValueError("refund proof evidence: " + message)


def closure_digest(closure):
    return {
        r["name"]: hashlib.sha256(
            json.dumps(
                r, ensure_ascii=False, separators=(",", ":"), sort_keys=True
            ).encode()
        ).hexdigest()
        for r in closure
    }


def check(records, ledger):
    frozen = json.loads(
        subprocess.check_output(
            [
                "git",
                "show",
                BASE + ":investigations/741-no-pin/refund-lifecycle-statements.json",
            ],
            cwd=ROOT,
            text=True,
        )
    )
    require(
        [(r["theorem"], r["statementSha256"]) for r in ledger["statements"]]
        == [(r["theorem"], r["statementSha256"]) for r in frozen["statements"]],
        "frozen statement identities changed",
    )
    closures = [r["refundProofClosure"] for r in records if "refundProofClosure" in r]
    require(len(closures) == 1, "missing or duplicate refund definition closure")
    current = closure_digest(closures[0])
    baseline = json.loads((ROOT / "refund-proof-definition-baseline.json").read_text())
    require(
        baseline["base"] == BASE and current == baseline["constants"],
        "refund kernel definition closure changed",
    )
    require(len(current) == len(closures[0]), "duplicate closure constant")
    import refund_lifecycle_check

    target = ledger["statements"][0]["theorem"]
    controls = []
    changed = copy.deepcopy(records)
    next(r for r in changed if r.get("name") == target)["axioms"] = ["sorryAx"]
    proposed = copy.deepcopy(ledger)
    proposed["statements"][0]["status"] = "PROVED"
    try:
        refund_lifecycle_check.reconcile(changed, proposed)
    except ValueError:
        controls.append("refund-proved-with-sorry-refused")
    else:
        raise ValueError("PROVED refund with sorry survived")
    for family in ["lifecycle", "history"]:
        module = __import__(family + "_check")
        proposed = json.loads((ROOT / (family + "-statements.json")).read_text())
        proposed["statements"][0]["status"] = "PROVED"
        if family == "history":
            proposed["statements"][0]["theorem"] = target
        try:
            module.reconcile(records, proposed)
        except ValueError:
            controls.append(family + "-out-of-scope-proof-refused")
        else:
            raise ValueError("out-of-scope status survived: " + family)
    changed = copy.deepcopy(records)
    next(r["refundProofClosure"] for r in changed if "refundProofClosure" in r)[0][
        "value"
    ] = "weakened"
    changed_closure = next(
        r["refundProofClosure"] for r in changed if "refundProofClosure" in r
    )
    require(changed_closure != closures[0], "closure control did not apply")
    require(
        closure_digest(changed_closure) != baseline["constants"],
        "changed definition passed the closure comparator",
    )
    controls.append("changed-kernel-definition-refused")
    import refund_proof_controls

    kernel = refund_proof_controls.check()
    return {
        "base": BASE,
        "definitionConstants": len(current),
        "statusControls": controls,
        "kernelControls": kernel,
    }
