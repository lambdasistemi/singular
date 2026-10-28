# Tool, not a guarantee: replay the frozen investigation; no hosted job runs it.
"""Compile definition and premise mutations under the same four named roots."""

import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
MODULES = [
    "Core",
    "Application",
    "Client",
    "History",
    "HistoryClaims",
    "HistoryProofAudit",
]
NS = "NoPin.HistoryClosureControl"


def check():
    sources = {
        name: (ROOT / "lean/NoPin/ApplicationRequests" / (name + ".lean")).read_text()
        for name in MODULES
    }
    sources["HistoryClaims"], count = re.subn(
        r":= by.*?(?=\n/--|\nend HistoryStatements)",
        ":= by sorry\n",
        sources["HistoryClaims"],
        flags=re.S,
    )
    if count != 4:
        raise ValueError(
            "history closure controls did not isolate all four statement types"
        )
    closures = {}
    labels = [
        "positive",
        "weakened-leaf-guard",
        "dropped-collision-premise",
        "extra-theorem",
        "path-module",
    ]
    with tempfile.TemporaryDirectory(
        prefix="history-proof-control-", dir=ROOT / ".lake"
    ) as temp:
        path = Path(temp) / "Control.lean"
        for label in labels:
            current = dict(sources)
            if label in {"weakened-leaf-guard", "dropped-collision-premise"}:
                module, needle, replacement = (
                    (
                        "Core",
                        "applyGuard mutation .changeLeaf (trieGet trie key == .unknown)",
                        "applyGuard mutation .changeLeaf true",
                    )
                    if label == "weakened-leaf-guard"
                    else (
                        "HistoryClaims",
                        "FiniteCollisionFree h c (historyDomain world registry key)",
                        "True",
                    )
                )
                if current[module].count(needle) != 1:
                    raise ValueError("history closure mutation is not unique: " + label)
                current[module] = current[module].replace(needle, replacement)
                if needle in current[module]:
                    raise ValueError("history closure mutation did not apply: " + label)
            text = "import NoPin.ApplicationRequests.HistoryProofAudit\n"
            for name in MODULES:
                text += (
                    "\n"
                    + re.sub(r"^import .*$", "", current[name], flags=re.M).replace(
                        "NoPin.ApplicationRequests", NS
                    )
                    + "\n"
                )
            text = text.replace(
                "ProofAudit.closure", "NoPin.ApplicationRequests.ProofAudit.closure"
            )
            if label == "extra-theorem":
                text += f"\nnamespace {NS}.HistoryStatements\ntheorem unrelated : True := by trivial\nend {NS}.HistoryStatements\n"
            if label == "path-module":
                path = Path(temp) / "PathCompiled.lean"
            path.write_text(text + "\n#history_proof_closure\n")
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
                text=True,
                capture_output=True,
            )
            log = result.stdout + result.stderr
            (ROOT / ".lake" / ("history-proof-control-" + label + ".log")).write_text(
                log
            )
            if result.returncode:
                raise ValueError(
                    "history closure control setup failed: "
                    + label
                    + "\n"
                    + log[-4000:]
                )
            closures[label] = next(
                json.loads(line)["historyProofClosure"]
                for line in result.stdout.splitlines()
                if line.startswith("{")
            )
    before = {r["name"]: r for r in closures["positive"]}
    if len(before) < 500:
        raise ValueError("truncated history closure control")
    for label in ["weakened-leaf-guard", "dropped-collision-premise", "path-module"]:
        after = {r["name"]: r for r in closures[label]}
        if before == after:
            raise ValueError("history closure mutation survived: " + label)
    if closures["positive"] != closures["extra-theorem"]:
        raise ValueError("unrelated theorem changed the history closure")
    return {
        "controls": labels,
        "constants": len(before),
        "directSubprocesses": len(labels),
    }
