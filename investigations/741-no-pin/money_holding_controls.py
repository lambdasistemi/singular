# Tool, not a guarantee: replay the frozen investigation; no hosted job runs it.
"""Compile the holding-payment guard and ledger-root isolation controls."""

import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
LEAN = ROOT / "lean/NoPin/ApplicationRequests"


def check(checkpoint):
    import money_proof_check

    source = (LEAN / "MoneyHoldingClaims.lean").read_text()
    needle = "quantity output active == 0"
    if source.count(needle) != 1:
        raise ValueError("holding guard mutation is not unique")
    results = {}
    old_results = {}
    with tempfile.TemporaryDirectory(
        prefix="holding-control-", dir=ROOT / ".lake"
    ) as directory:
        for label in ["positive", "weakened", "extra-statement"]:
            text = "import NoPin.ApplicationRequests.MoneyProofAudit\n"
            if label == "extra-statement":
                text += "theorem NoPin.ApplicationRequests.Money.Statements.notInLedger : True := by trivial\n"
            else:
                current = (
                    source.replace(needle, "true") if label == "weakened" else source
                )
                if label == "weakened" and (current == source or needle in current):
                    raise ValueError("holding guard mutation did not apply")
                current = re.sub(r"^import .*\n", "", current, flags=re.M)
                current = current.replace(
                    "NoPin.ApplicationRequests.Money",
                    "NoPin.ApplicationRequests.Money.HoldingControl",
                )
                text += current + "\n"
                text += """
namespace NoPin.ApplicationRequests.Money.HoldingControl
theorem candidate (h : Hash) (c : Codec) (t : TrieCommit)
    (decode : DecodeApplication) (release : PublishedRelease) (q : Input)
    (_premises : NewPremise h c t decode release .registrationFold q) :
    HoldingSeparatedClaim .none h c t decode release q := by sorry
end NoPin.ApplicationRequests.Money.HoldingControl
open Lean Elab Command
elab "#holding_control_closure" : command => do
  let env ← getEnv
  let info ← getConstInfo `NoPin.ApplicationRequests.Money.HoldingControl.candidate
  IO.println (Json.mkObj [("holdingControlClosure", toJson
    (NoPin.ApplicationRequests.ProofAudit.closure env info.type.getUsedConstants))]).compress
#holding_control_closure
"""
            text += "\n#money_proof_closure\n"
            path = Path(directory) / "Control.lean"
            path.write_text(text)
            log_path = ROOT / ".lake" / ("holding-control-" + label + ".log")
            with log_path.open("w") as log:
                result = subprocess.run(
                    [
                        "timeout",
                        "240",
                        "lake",
                        "-d",
                        str(ROOT),
                        "--keep-toolchain",
                        "env",
                        "lean",
                        str(path),
                    ],
                    stdout=log,
                    stderr=subprocess.STDOUT,
                )
            if result.returncode:
                errors = [
                    line
                    for line in log_path.read_text().splitlines()
                    if not line.startswith("{")
                ]
                raise ValueError(
                    "holding closure control setup failed: "
                    + label
                    + "\n"
                    + "\n".join(errors)[-4000:]
                )
            with log_path.open() as log:
                for line in log:
                    if not line.startswith("{"):
                        continue
                    row = json.loads(line)
                    if "holdingControlClosure" in row:
                        results[label] = money_proof_check.digest(
                            row["holdingControlClosure"]
                        )
                    if "moneyProofClosure" in row:
                        old_results[label] = money_proof_check.digest(
                            row["moneyProofClosure"]
                        )
                    if "moneyHoldingProofClosure" in row:
                        if (
                            money_proof_check.digest(row["moneyHoldingProofClosure"])
                            != checkpoint["constants"]
                        ):
                            raise ValueError(
                                "unrelated control changed actual corrected closure"
                            )
    baseline = json.loads((ROOT / "money-proof-definition-baseline.json").read_text())[
        "constants"
    ]
    if set(old_results) != {"positive", "weakened", "extra-statement"} or any(
        value != baseline for value in old_results.values()
    ):
        raise ValueError("ledger-root isolation control failed")
    if (
        set(results) != {"positive", "weakened"}
        or not results["positive"]
        or results["positive"] == results["weakened"]
    ):
        raise ValueError("weakening the corrected payment guard survived")
    return {
        "extraNamespaceTheoremLeavesOldClosureUnchanged": True,
        "weakeningChangesOnlyControlClosure": True,
        "directSubprocesses": 3,
    }
