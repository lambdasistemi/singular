"""Execute application-source substitutions against independent refund-lifecycle evidence."""

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
    "RefundLifecycleConditions",
    "RefundLifecycle",
    "Conditions",
    "Role",
    "Effects",
    "Proofs",
    "DeliveryProofs",
    "MintedProofs",
    "Statements",
    "Evidence",
    "RefundLifecycleClaims",
    "RefundLifecycleStatements",
    "RefundLifecycleFixtures",
    "RefundLifecycleEvidence",
]


def main():
    sources = {name: (BASE / (name + ".lean")).read_text() for name in MODULES}
    changes = [
        (
            "reclaim-one-tick-early",
            "data.processDeadline ≤ interval.lower",
            "data.processDeadline ≤ interval.lower + 1",
            "early_reclaim_lifecycle",
        ),
        (
            "cleanup-whole-value",
            "| .expiredCleanup .. => return (data.refundAddress, data.deposit)",
            "| .expiredCleanup .. => return (data.refundAddress, input.lovelace)",
            "additive_payments_positive",
        ),
        (
            "registration-overdeposit",
            "holding.lovelace == data.deposit",
            "data.deposit ≤ holding.lovelace",
            "overdeposit_lifecycle",
        ),
    ]
    results = []
    with tempfile.TemporaryDirectory(
        prefix="refund-lifecycle-controls-", dir=ROOT / ".lake"
    ) as tmp:
        for label, needle, replacement, obligation in [
            ("positive", None, None, None)
        ] + changes:
            current = dict(sources)
            if needle:
                if current["Application"].count(needle) != 1:
                    raise ValueError("mutation application not unique: " + label)
                current["Application"] = current["Application"].replace(
                    needle, replacement, 1
                )
                if (
                    current["Application"] == sources["Application"]
                    or current["Application"].count(replacement) != 1
                ):
                    raise ValueError("mutation did not apply: " + label)
            text = "import NoPin.ApplicationRequests.RefundLifecycleEvidence\n"
            for name in MODULES:
                text += (
                    "\n"
                    + re.sub(r"^import .*$", "", current[name], flags=re.M).replace(
                        "NoPin.ApplicationRequests", "NoPin.RefundLifecycleControl"
                    )
                    + "\n"
                )
            path = Path(tmp) / (label + ".lean")
            path.write_text(text)
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
            output = result.stdout + result.stderr
            logfile = ROOT / ".lake" / ("refund-lifecycle-control-" + label + ".log")
            logfile.write_text(output)
            failed = set()
            lines = text.splitlines()
            for match in re.finditer(r":(\d+):\d+: error: Tactic .decide.", output):
                names = re.findall(
                    r"^theorem (\w+)", "\n".join(lines[: int(match[1])]), re.M
                )
                if names:
                    failed.add(names[-1])
            if needle and (result.returncode != 1 or obligation not in failed):
                raise ValueError(
                    "mutation missed independent obligation: "
                    + label
                    + " "
                    + str(failed)
                    + "\n"
                    + output[-3000:]
                )
            if not needle and result.returncode:
                raise ValueError(
                    "positive refund-lifecycle control failed: " + output[-3000:]
                )
            results.append(
                {
                    "control": label,
                    "exit": result.returncode,
                    "failedObligations": sorted(failed),
                    "sourceSha256": hashlib.sha256(
                        sources["Application"].encode()
                    ).hexdigest(),
                    "mutatedSha256": hashlib.sha256(
                        current["Application"].encode()
                    ).hexdigest(),
                    "logSha256": hashlib.sha256(output.encode()).hexdigest(),
                }
            )
    print(
        json.dumps(
            {
                "status": "FINITE-APPLICATION-EFFECT-INDEPENDENCE",
                "controls": results,
                "directSubprocesses": len(results),
            }
        )
    )


if __name__ == "__main__":
    main()
