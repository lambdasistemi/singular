# Tool, not a guarantee: replay the frozen investigation; no hosted job runs it.
"""A compiled signer mutation must alter the refund-rooted kernel closure."""

import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
MODULES = [
    "Core",
    "Application",
    "RefundApplication",
    "Client",
    "History",
    "Fixtures",
    "Oracle",
    "RefundLifecycleConditions",
    "RefundLifecycle",
    "RefundLifecycleClaims",
    "RefundLifecycleStatements",
    "RefundProofAudit",
]


def check():
    sources = {
        n: (ROOT / "lean/NoPin/ApplicationRequests" / (n + ".lean")).read_text()
        for n in MODULES
    }
    sources["RefundLifecycleStatements"] = re.sub(
        r":= by.*?(?=\n/--|\nend NoPin.ApplicationRequests.RefundLifecycle.Statements)",
        ":= by sorry\n",
        sources["RefundLifecycleStatements"],
        flags=re.S,
    )
    closures = {}
    with tempfile.TemporaryDirectory(
        prefix="refund-proof-control-", dir=ROOT / ".lake"
    ) as temp:
        for label in ["positive", "controller-reclaim-signer"]:
            current = dict(sources)
            needle = "observation.signers.contains data.refundAddress"
            if current["RefundApplication"].count(needle) != 1:
                raise ValueError("refund signer mutation is not unique")
            if label != "positive":
                current["RefundApplication"] = current["RefundApplication"].replace(
                    needle, "observation.signers.contains data.controller"
                )
                if needle in current["RefundApplication"]:
                    raise ValueError("refund signer mutation did not apply")
            text = "import NoPin.ApplicationRequests.RefundProofAudit\n"
            for name in MODULES:
                text += (
                    "\n"
                    + re.sub(r"^import .*$", "", current[name], flags=re.M).replace(
                        "NoPin.ApplicationRequests", "NoPin.RefundProofControl"
                    )
                    + "\n"
                )
            text = text.replace(
                "toJson (ProofAudit.closure",
                "toJson (NoPin.ApplicationRequests.ProofAudit.closure",
            )
            path = Path(temp) / "Control.lean"
            path.write_text(text + "\n#refund_proof_closure\n")
            result = subprocess.run(
                [
                    "timeout",
                    "180",
                    "lake",
                    "-d",
                    str(ROOT),
                    "--keep-toolchain",
                    "env",
                    "lean",
                    str(path),
                ],
                capture_output=True,
                text=True,
            )
            log = result.stdout + result.stderr
            (ROOT / ".lake" / ("refund-proof-control-" + label + ".log")).write_text(
                log
            )
            if result.returncode:
                raise ValueError(
                    "refund closure control setup failed: " + label + "\n" + log[-3000:]
                )
            closure = next(
                json.loads(line)["refundProofClosure"]
                for line in result.stdout.splitlines()
                if line.startswith("{")
            )
            closures[label] = {r["name"]: r for r in closure}
    name = "NoPin.RefundProofControl.RefundApplication.registrationSpend"
    before, after = closures["positive"], closures["controller-reclaim-signer"]
    if len(before) < 1000 or set(before) != set(after) or before[name] == after[name]:
        raise ValueError("refund closure did not detect changed reclaim signer")
    return {
        "control": "controller-reclaim-signer",
        "detected": True,
        "constants": len(before),
        "directSubprocesses": 2,
    }
