#!/usr/bin/env python3
"""Execute independent-effect witnesses against isolated production mutations."""

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
]


def main():
    sources = {
        name: (ROOT / "lean/NoPin/ApplicationRequests" / (name + ".lean")).read_text()
        for name in MODULES
    }
    mutations = [
        (
            "unrelated-leaf",
            "Core",
            "return trieSet trie key (.known .active)",
            "return trieSet (trieSet trie 999 (.known .active)) key (.known .active)",
            {
                "registration_effects_candidate",
                "mixed_frame",
                "batch_effects_candidate",
            },
        ),
        (
            "registration-leaf",
            "Core",
            "return trieSet trie key (.known .active)",
            "return trieSet trie key (.known .terminal)",
            {"registration_effects_candidate", "batch_effects_candidate"},
        ),
        (
            "termination-leaf",
            "Core",
            "return trieSet trie key (.known .terminal)",
            "return trieSet trie key (.unknown)",
            {"termination_effects_candidate", "batch_effects_candidate"},
        ),
        (
            "successor-root",
            "Client",
            "let nextState := { state with datum := .root (commit afterTrie) }",
            "let nextState := { state with datum := .root (commit registry.trie) }",
            {"mixed_singular", "batch_effects_candidate"},
        ),
        (
            "mint-delta",
            "Core",
            "match change with | .register .. => 1 | .terminate .. => -1",
            "match change with | .register .. => 2 | .terminate .. => -1",
            {"mixed_singular"},
        ),
        (
            "continuation-datum",
            "Core",
            "after.state.datum == .root (commit after.trie)",
            "after.state.datum == .root (commit before.trie)",
            {"mixed_singular"},
        ),
        (
            "shared-carrier",
            "Core",
            "separateHolding observation action.reference index && oneNewToken hash code observation output",
            "true",
            {"shared_registration_refused", "registration_separate_holdings_candidate"},
        ),
        (
            "recognizable-fold-mint",
            "Core",
            "(wholePolicyDelta hash code observation)",
            "true",
            {"fold_minted_outputs_candidate"},
        ),
    ]
    results = []
    with tempfile.TemporaryDirectory(
        prefix="effect-controls-", dir=ROOT / ".lake"
    ) as tmp:
        tmp = Path(tmp)
        for label, module, needle, replacement, expected in [
            ("positive", None, None, None, set())
        ] + mutations:
            current = dict(sources)
            if module:
                if current[module].count(needle) != 1:
                    raise ValueError("mutation application not unique: " + label)
                current[module] = current[module].replace(needle, replacement, 1)
                if needle in current[module] or replacement not in current[module]:
                    raise ValueError("mutation did not apply: " + label)
            text = "import NoPin.ApplicationRequests.Evidence\n"
            for name in MODULES:
                text += (
                    "\n"
                    + re.sub(r"^import .*$", "", current[name], flags=re.M).replace(
                        "NoPin.ApplicationRequests", "NoPin.EffectControl"
                    )
                    + "\n"
                )
            target = tmp / (label + ".lean")
            target.write_text(text)
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
                    str(target),
                ],
                capture_output=True,
                text=True,
            )
            output = result.stdout + result.stderr
            logfile = ROOT / ".lake" / ("effect-control-" + label + ".log")
            logfile.write_text(output)
            if not module:
                if result.returncode != 0:
                    raise ValueError(
                        "positive effect-control setup failed: " + output[-4000:]
                    )
                results.append({"control": label, "exit": 0})
                continue
            lines = text.splitlines()
            failed = set()
            for match in re.finditer(r":(\d+):\d+: error: Tactic .decide.", output):
                at = int(match.group(1))
                declarations = re.findall(
                    r"^theorem (\w+)", "\n".join(lines[:at]), re.M
                )
                if declarations:
                    failed.add(declarations[-1])
            if result.returncode != 1 or not (failed & expected):
                raise ValueError(
                    "control did not fail at independent obligation: "
                    + label
                    + " failed="
                    + str(failed)
                    + "\n"
                    + output[-4000:]
                )
            results.append(
                {
                    "control": label,
                    "exit": result.returncode,
                    "detected": True,
                    "failedObligations": sorted(failed),
                    "log": str(logfile),
                }
            )
    print(
        json.dumps(
            {
                "status": "FINITE-EFFECT-INDEPENDENCE",
                "controls": results,
                "directSubprocesses": len(results),
            }
        )
    )


if __name__ == "__main__":
    main()
