# Tool, not a guarantee: replay the frozen investigation; no hosted job runs it.
"""Execute source substitutions against independent compiled money obligations."""

import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
BASE = ROOT / "lean/NoPin/ApplicationRequests"
MODULES = [
    "Core",
    "Application",
    "RefundApplication",
    "Client",
    "History",
    "Fixtures",
    "Oracle",
    "Conditions",
    "Role",
    "Effects",
    "Proofs",
    "DeliveryProofs",
    "MintedProofs",
    "PublicProofs",
    "Statements",
    "Evidence",
    "RefundLifecycleConditions",
    "RefundLifecycle",
    "RefundLifecycleClaims",
    "RefundLifecycleProofs",
    "RefundLifecycleStatements",
    "RefundLifecycleFixtures",
    "RefundLifecycleEvidence",
    "Money",
    "MoneyClaims",
    "MoneyStatements",
    "MoneyFixtures",
    "MoneyEvidence",
]


def main():
    sources = {name: (BASE / (name + ".lean")).read_text() for name in MODULES}
    sources["MoneyStatements"] = re.sub(
        r":= by.*?(?=\n/--|\nend NoPin.ApplicationRequests.Money.Statements)",
        ":= by sorry\n",
        sources["MoneyStatements"],
        flags=re.S,
    )
    changes = [
        (
            "carrier-counted-as-old-tip",
            "Money",
            "amountAt m .oldRegistrationTip obligations.tips",
            "amountAt m .oldRegistrationTip obligations.carriers",
            "accepted_economic_allocations_positive",
        ),
        (
            "cost-counted-as-old-deposit",
            "Money",
            "amountAt m .oldRegistrationCarrier obligations.carriers",
            "amountAt m .oldRegistrationCarrier obligations.donation",
            "accepted_economic_allocations_positive",
        ),
        (
            "folder-takes-protected-deposit",
            "Money",
            "amountAt m .registrationResidual q.registration.bid",
            "amountAt m .registrationResidual q.registration.output.lovelace",
            "registration_fold_journey_positive",
        ),
        (
            "booking-omits-treasury-deposit",
            "Application",
            "return control.deposit",
            "return 0",
            "termination_booking_journey_positive",
        ),
        (
            "registration-drops-exact-deposit",
            "Application",
            "holding.lovelace == data.deposit",
            "data.deposit ≤ holding.lovelace",
            "overdeposit_lifecycle",
        ),
        (
            "controller-reclaims-instead-of-refund-address",
            "RefundApplication",
            "observation.signers.contains data.refundAddress",
            "observation.signers.contains data.controller",
            "reclaim_journey_positive",
        ),
    ]
    results = []
    with tempfile.TemporaryDirectory(
        prefix="money-controls-", dir=ROOT / ".lake"
    ) as tmp:
        for label, module, needle, replacement, obligation in [
            ("positive", None, None, None, None)
        ] + changes:
            current = dict(sources)
            if needle:
                if current[module].count(needle) != 1:
                    raise ValueError("mutation application not unique: " + label)
                current[module] = current[module].replace(needle, replacement, 1)
                if (
                    current[module] == sources[module]
                    or current[module].count(replacement) != 1
                ):
                    raise ValueError("mutation did not apply: " + label)
            text = "import NoPin.ApplicationRequests.MoneyEvidence\nimport NoPin.ApplicationRequests.RefundLifecycleEvidence\n"
            for name in MODULES:
                text += (
                    "\n"
                    + re.sub(r"^import .*$", "", current[name], flags=re.M).replace(
                        "NoPin.ApplicationRequests", "NoPin.MoneyControl"
                    )
                    + "\n"
                )
            file = Path(tmp) / (label + ".lean")
            file.write_text(text)
            run = subprocess.run(
                [
                    "timeout",
                    "180",
                    "lake",
                    "-d",
                    str(ROOT),
                    "--keep-toolchain",
                    "env",
                    "lean",
                    str(file),
                ],
                capture_output=True,
                text=True,
            )
            output = run.stdout + run.stderr
            log = ROOT / ".lake" / ("money-control-" + label + ".log")
            log.write_text(output)
            failed = set()
            lines = text.splitlines()
            for match in re.finditer(r":(\d+):\d+: error: Tactic .decide.", output):
                declarations = re.findall(
                    r"^theorem (\w+)", "\n".join(lines[: int(match[1])]), re.M
                )
                if declarations:
                    failed.add(declarations[-1])
            if not needle and run.returncode:
                raise ValueError("positive money control failed: " + output[-5000:])
            if needle and (run.returncode != 1 or obligation not in failed):
                raise ValueError(
                    "mutation missed independent obligation: "
                    + label
                    + " "
                    + str(failed)
                    + "\n"
                    + output[-5000:]
                )
            results.append(
                {
                    "control": label,
                    "exit": run.returncode,
                    "obligation": obligation,
                    "failedDeclarations": sorted(failed),
                    "sourceSha256": hashlib.sha256(text.encode()).hexdigest(),
                    "log": str(log),
                    "logSha256": hashlib.sha256(output.encode()).hexdigest(),
                }
            )
    print(json.dumps({"controls": results, "directSubprocesses": len(results)}))


if __name__ == "__main__":
    main()
