#!/usr/bin/env python3
"""Restore the unconditional destination row in isolated Lean builds (#304).

Run from the repository's Nix development shell with an evidence directory.
Only temporary copies are mutated. The driver binary depends on the model
alone, so it is built and run first: a fold that delivers nothing must show a
destination row by value under the mutant and none at baseline. Then the
statements module is elaborated, and the mutant must fail inside
`destination_output_iff_delivers`, the statement that forbids the fabrication.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
MODEL = Path("lean/Singular/Model.lean")
STATEMENTS = Path("lean/Singular/Statements.lean")
STATEMENT = "theorem destination_output_iff_delivers"
MUTANTS = {
    "unconditional-row": (
        "  if assets.isEmpty then []\n  else [{ role := .destination",
        "  [{ role := .destination",
    ),
}
# Folds that deliver nothing, and the one that delivers, in the driver corpus.
NON_DELIVERING = ("DR01-register-absent", "DR03-retire-registered")
DELIVERING = "DR02-register-active"


def run(command, cwd, log):
    with log.open("w") as out:
        result = subprocess.run(command, cwd=cwd, stdout=out, stderr=subprocess.STDOUT)
    return result.returncode


def destination_rows(driver_output):
    scenarios = json.loads(driver_output)["scenarios"]
    return {
        s["id"]: sum(
            1 for o in s["observations"]["tx"]["outputs"] if o["role"] == "destination"
        )
        for s in scenarios
        if (s.get("observations") or {}).get("tx") is not None
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    args = parser.parse_args()
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    original = (ROOT / MODEL).read_text()
    statements = (ROOT / STATEMENTS).read_text()
    start = statements.index(STATEMENT)
    end = statements.index("\ntheorem ", start + len(STATEMENT))
    first_line = statements[:start].count("\n") + 1
    last_line = statements[:end].count("\n")
    receipts = []
    for name, (before, after) in {"baseline": ("", ""), **MUTANTS}.items():
        with tempfile.TemporaryDirectory(prefix="singular-destination-") as tmp:
            tree = Path(tmp)
            shutil.copytree(ROOT / "lean", tree / "lean")
            for filename in ("lakefile.toml", "lean-toolchain", "lake-manifest.json"):
                shutil.copy2(ROOT / filename, tree / filename)
            mutated = original
            if name != "baseline":
                assert original.count(before) == 1, (name, "mutation site changed")
                mutated = original.replace(before, after)
                (tree / MODEL).write_text(mutated)
                assert (tree / MODEL).read_text() != original, (
                    name,
                    "mutation not applied",
                )
            (evidence / f"{name}-Model.lean").write_text(mutated)
            binary_status = run(
                ["lake", "build", "singular-driver"],
                tree,
                evidence / f"{name}-driver-build.log",
            )
            assert binary_status == 0, f"{name}: setup/driver compilation failure"
            driver_status = run(
                [str(tree / ".lake/build/bin/singular-driver")],
                tree,
                evidence / f"{name}-driver.json",
            )
            assert driver_status == 0, f"{name}: driver run failed"
            rows = destination_rows((evidence / f"{name}-driver.json").read_text())
            proof_status = run(
                ["lake", "build", "Singular.Statements"],
                tree,
                evidence / f"{name}-proof.log",
            )
            proof_text = (evidence / f"{name}-proof.log").read_text()
            errors = [
                int(n)
                for n in re.findall(
                    r"error: lean/Singular/Statements.lean:(\d+):", proof_text
                )
            ]
            assert rows[DELIVERING] == 1, (name, "the delivering control lost its row")
            if name == "baseline":
                assert proof_status == 0, "baseline statements failed"
                assert all(rows[i] == 0 for i in NON_DELIVERING), (
                    "baseline describes a destination row on a fold delivering nothing"
                )
            else:
                assert all(rows[i] == 1 for i in NON_DELIVERING), (
                    name,
                    "mutant did not fabricate the row: the observation cannot see it",
                )
                assert proof_status != 0 and any(
                    first_line <= n <= last_line for n in errors
                ), (name, "the seven-edge statement did not fail")
            receipt = {
                "mutation": name,
                "before": before,
                "after": after,
                "driverBuildExit": binary_status,
                "driverExit": driver_status,
                "destinationRows": {i: rows[i] for i in (*NON_DELIVERING, DELIVERING)},
                "proofExit": proof_status,
                "statementErrorLines": sorted(set(errors)),
                "modelSha256": hashlib.sha256(mutated.encode()).hexdigest(),
                "statementsSha256": hashlib.sha256(statements.encode()).hexdigest(),
            }
            receipts.append(receipt)
            print(json.dumps(receipt), flush=True)
    (evidence / "receipts.json").write_text(json.dumps(receipts, indent=2) + "\n")


if __name__ == "__main__":
    main()
