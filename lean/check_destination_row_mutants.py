#!/usr/bin/env python3
"""Restore what #304 removed from the destination output, in isolated Lean builds.

Run from the repository's Nix development shell with an evidence directory.
Only temporary copies are mutated. Each mutant brings back one fabrication: a
destination row on every fold, an inline datum on every delivered output, or an
inline datum on every spent witness.
The driver binary depends on the model alone, so it is built and run first, and
the fabrication must be visible by value in its output while the baseline shows
none. Then the statements module is elaborated, and the mutant must fail inside
the statement that forbids that fabrication.
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
# Folds that deliver nothing, and the one that delivers, in the driver corpus.
NON_DELIVERING = ("DR01-register-absent", "DR03-retire-registered")
DELIVERING = "DR02-register-active"
MUTANTS = {
    "unconditional-row": {
        "before": "  if assets.isEmpty then []\n  else [{ role := .destination",
        "after": "  [{ role := .destination",
        "statement": "theorem destination_output_iff_delivers",
    },
    "unconditional-inline": {
        "before": "def deliveredDatum (r : Request) : DatumForm :=\n  if r.namesDatum then .inline else .none",
        "after": "def deliveredDatum (r : Request) : DatumForm :=\n  .inline",
        "statement": "theorem delivered_datum_follows_request",
    },
    "unconditional-inline-witness": {
        "before": "  | .requestOutput => heldDatum s asset.2 asset.1",
        "after": "  | .requestOutput => registryDatumForm",
        "statement": "theorem witness_input_datum_is_held",
    },
}
DELIVERING_EDGES = ("insertActive", "updateActive", "witnessTerminal")


def run(command, cwd, log):
    with log.open("w") as out:
        result = subprocess.run(command, cwd=cwd, stdout=out, stderr=subprocess.STDOUT)
    return result.returncode


def destination_outputs(driver_output):
    """Each fold scenario's destination outputs, and whether its request names a datum."""
    scenarios = json.loads(driver_output)["scenarios"]
    return {
        s["id"]: {
            "namesDatum": bool(s["request"].get("namesDatum")),
            "datums": [
                o["datum"]
                for o in s["observations"]["tx"]["outputs"]
                if o["role"] == "destination"
            ],
            "witnesses": [
                i["datum"]
                for i in s["observations"]["tx"]["inputs"]
                if i["role"] == "witness"
            ],
            "witnessDelivered": delivered_form(s),
        }
        for s in scenarios
        if (s.get("observations") or {}).get("tx") is not None
    }


def delivered_form(scenario):
    """The datum form the fold that delivered this key's witness gave it, if any."""
    forms = [
        "inline" if step["request"].get("namesDatum") else "none"
        for step in scenario.get("setup") or []
        if step.get("accepted")
        and step["request"]["key"] == scenario["request"]["key"]
        and step["request"]["edge"] in DELIVERING_EDGES
    ]
    return forms[-1] if forms else None


def lines_of(statements, header):
    start = statements.index(header)
    end = statements.index("\ntheorem ", start + len(header))
    return statements[:start].count("\n") + 1, statements[:end].count("\n")


def fabrications(rows):
    """What the model describes that the ruling forbids, by value."""
    found = []
    for i in NON_DELIVERING:
        if rows[i]["datums"]:
            found.append(f"{i}: destination row on a fold delivering nothing")
    for i, row in rows.items():
        want = "inline" if row["namesDatum"] else "none"
        for datum in row["datums"]:
            if datum != want:
                found.append(f"{i}: delivered datum {datum}, request names {want}")
        for datum in row["witnesses"]:
            if row["witnessDelivered"] and datum != row["witnessDelivered"]:
                found.append(
                    f"{i}: witness datum {datum}, delivered as {row['witnessDelivered']}"
                )
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    args = parser.parse_args()
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    original = (ROOT / MODEL).read_text()
    statements = (ROOT / STATEMENTS).read_text()
    receipts = []
    for name, mutant in {"baseline": None, **MUTANTS}.items():
        with tempfile.TemporaryDirectory(prefix="singular-destination-") as tmp:
            tree = Path(tmp)
            shutil.copytree(ROOT / "lean", tree / "lean")
            for filename in ("lakefile.toml", "lean-toolchain", "lake-manifest.json"):
                shutil.copy2(ROOT / filename, tree / filename)
            mutated = original
            if mutant:
                assert original.count(mutant["before"]) == 1, (
                    name,
                    "mutation site changed",
                )
                mutated = original.replace(mutant["before"], mutant["after"])
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
            rows = destination_outputs((evidence / f"{name}-driver.json").read_text())
            found = fabrications(rows)
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
            assert len(rows[DELIVERING]["datums"]) == 1, (
                name,
                "the delivering control lost its row",
            )
            if not mutant:
                assert proof_status == 0, "baseline statements failed"
                assert not found, ("baseline fabricates", found)
            else:
                assert found, (
                    name,
                    "mutant fabricated nothing the observation can see",
                )
                first, last = lines_of(statements, mutant["statement"])
                assert proof_status != 0 and any(first <= n <= last for n in errors), (
                    name,
                    "the statement forbidding it did not fail",
                )
            receipt = {
                "mutation": name,
                "before": mutant["before"] if mutant else "",
                "after": mutant["after"] if mutant else "",
                "driverBuildExit": binary_status,
                "driverExit": driver_status,
                "destinationOutputs": {
                    i: rows[i] for i in (*NON_DELIVERING, DELIVERING)
                },
                "fabrications": found,
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
