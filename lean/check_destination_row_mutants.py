#!/usr/bin/env python3
"""Restore what #304 and #419 removed from the destination output, in isolated Lean builds.

Run from the repository's Nix development shell with an evidence directory.
Only temporary copies are mutated. Each mutant brings back one fabrication: a
destination row on every fold, an inline datum on every delivered output, a
delivered output that drops the request's datum value, an inline datum on every
spent witness, a destination paid whatever datum value it carries, or a delivery
judged by its floor alone, settled with no carrier.
The driver binary depends on the model alone, so it is built and run first, and
the fabrication must be visible by value in its output while the baseline shows
none, or, for a mutant the driver's own guard over its judged rows refuses, the
driver build must fail at that guard. Then the statements module is elaborated,
and the mutant must fail inside the statement that forbids that fabrication.
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
# Folds that deliver nothing, and the ones that deliver, in the driver corpus:
# under a request carrying no datum, and under one carrying a datum.
NON_DELIVERING = ("DR01-register-absent", "DR03-retire-registered")
DELIVERING = "DR02-register-active"
DELIVERING_DATUM = "DR15-register-active-carrying-datum"
MUTANTS = {
    "unconditional-row": {
        "before": "  if assets.isEmpty then []\n  else [{ role := .destination",
        "after": "  [{ role := .destination",
        "statement": "theorem destination_output_iff_delivers",
    },
    "unconditional-inline": {
        "before": "def deliveredDatum (r : Request) : DatumForm := datumFormOf r.datum",
        "after": "def deliveredDatum (r : Request) : DatumForm := .inline",
        "statement": "theorem delivered_datum_is_request_datum",
    },
    "dropped-datum-value": {
        "before": ", assets := assets, datumValue := r.datum }]",
        "after": ", assets := assets, datumValue := none }]",
        "statement": "theorem delivered_datum_is_request_datum",
    },
    "unconditional-inline-witness": {
        "before": "  | .requestOutput => heldDatum s asset.2 asset.1",
        "after": "  | .requestOutput => registryDatumForm",
        "statement": "theorem witness_input_datum_is_held",
    },
    "floor-only-delivery": {
        "before": "    if requiresCarrier recipient && paying.isEmpty then some (unpaidReason recipient paying)\n    else if",
        "after": "    if",
        "statement": "theorem fold_refuses_foreign_datum",
        # The driver's own guard over the judged rows refuses this build, before
        # any row can be exported.
        "guarded": True,
    },
    "any-datum-value-pays": {
        "before": "  | some v => output.datum == .inline && output.datumValue == some v",
        "after": "  | some v => output.datum == .inline",
        "statement": "theorem fold_refuses_foreign_datum",
        "guarded": True,
    },
}
DELIVERING_EDGES = ("insertActive", "updateActive", "witnessTerminal")


def run(command, cwd, log):
    with log.open("w") as out:
        result = subprocess.run(command, cwd=cwd, stdout=out, stderr=subprocess.STDOUT)
    return result.returncode


def form_of(datum):
    """The form an output carrying this datum value presents."""
    return "none" if datum is None else "inline"


def destination_outputs(driver_output):
    """Each fold scenario's destination outputs, and the datum its request carries."""
    scenarios = json.loads(driver_output)["scenarios"]
    return {
        s["id"]: {
            "datum": s["request"].get("datum"),
            "datums": [
                [o["datum"], o.get("datumValue")]
                for o in s["observations"]["tx"]["outputs"]
                if o["role"] == "destination"
            ],
            "witnesses": [
                [i["datum"], i.get("datumValue")]
                for i in s["observations"]["tx"]["inputs"]
                if i["role"] == "witness"
            ],
            "witnessDelivered": delivered_form(s),
            "unreachedSettled": unreached_destination_settled(s),
        }
        for s in scenarios
        if (s.get("observations") or {}).get("tx") is not None
    }


def unreached_destination_settled(scenario):
    """A judged delivery settled although no observed output carries the token to
    the request's own output with the request's own datum."""
    if "outputs" not in scenario or scenario["settle"] is not None:
        return False
    if scenario["operation"] not in DELIVERING_EDGES:
        return False
    request = scenario["request"]
    want = [form_of(request.get("datum")), request.get("datum")]
    return not any(
        o["role"] == "destination"
        and o["address"] == request["output"]
        and [o["datum"], o.get("datumValue")] == want
        for o in scenario["outputs"]
    )


def delivered_form(scenario):
    """The datum the fold that delivered this key's witness gave it, if any."""
    forms = [
        [form_of(step["request"].get("datum")), step["request"].get("datum")]
        for step in scenario.get("setup") or []
        if step.get("accepted")
        and step["request"]["key"] == scenario["request"]["key"]
        and step["request"]["edge"] in DELIVERING_EDGES
    ]
    return forms[-1] if forms else None


def lines_of(statements, header):
    start = statements.index(header)
    following = statements.find("\ntheorem ", start + len(header))
    end = following if following != -1 else statements.index("\nend Statements")
    return statements[:start].count("\n") + 1, statements[:end].count("\n")


def fabrications(rows):
    """What the model describes that the ruling forbids, by value."""
    found = []
    for i in NON_DELIVERING:
        if rows[i]["datums"]:
            found.append(f"{i}: destination row on a fold delivering nothing")
    for i, row in rows.items():
        if row["unreachedSettled"]:
            found.append(f"{i}: a delivery no carrier reaches was settled")
        want = [form_of(row["datum"]), row["datum"]]
        for datum in row["datums"]:
            if datum != want:
                found.append(f"{i}: delivered datum {datum}, request carries {want}")
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
            if mutant and mutant.get("guarded"):
                build_text = (evidence / f"{name}-driver-build.log").read_text()
                assert (
                    binary_status != 0
                    and "lean/DriverMain.lean" in build_text
                    and "did not evaluate to `true`" in build_text
                ), (name, "the driver's guard did not refuse it")
                driver_status, rows = None, None
                found = ["the driver's guard over the judged rows refused the build"]
            else:
                assert binary_status == 0, f"{name}: setup/driver compilation failure"
                driver_status = run(
                    [str(tree / ".lake/build/bin/singular-driver")],
                    tree,
                    evidence / f"{name}-driver.json",
                )
                assert driver_status == 0, f"{name}: driver run failed"
                rows = destination_outputs(
                    (evidence / f"{name}-driver.json").read_text()
                )
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
            for control in (DELIVERING, DELIVERING_DATUM) if rows else ():
                assert len(rows[control]["datums"]) == 1, (
                    name,
                    "a delivering control lost its row",
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
                    i: rows[i] for i in (*NON_DELIVERING, DELIVERING, DELIVERING_DATUM)
                }
                if rows
                else None,
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
