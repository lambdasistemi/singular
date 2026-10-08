#!/usr/bin/env python3
"""Run the actual Lean corpus guards against isolated definition mutants.

Requires pinned Lean 4.25.0 on PATH. No candidate source is edited. A compile
failure is not a kill: Model and Driver must compile, and DriverMain must fail
specifically at an executable guard, without an unrelated elaboration error.
"""

import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
MUTATIONS = {
    "missing-evidence": ('| none => some "reject-evidence-missing"', '| none => none'),
    "compatible-request": (
        'else if (transition r.edge leaf).isSome then some "reject-compatible"',
        'else if false then some "reject-compatible"',
    ),
    "reclaim-window": (
        "r.submittedAt + s.config.processTime + s.config.retractTime <= w.validFrom",
        "r.submittedAt + s.config.processTime <= w.validFrom",
    ),
    "intermediate-state": (
        "let later ← processActions first.state validFrom validTo rest",
        "let later ← processActions s validFrom validTo rest",
    ),
    "registry-binding": (
        "w.evidence.registryId != s.config.registryId || r.registryId != s.config.registryId ||\n"
        "        decide (w.evidence.registry ≠ s.config) || s.config.root != rootOf s.trie",
        "false",
    ),
    "request-registry-binding": (
        "r.registryId != s.config.registryId ||", "false ||",
    ),
    "booked-retraction-time": (
        "inPhase2 c r w then", "inPhase2 c { r with submittedAt := w.submittedAt } w then",
    ),
    "mixed-mint-claim": (
        'if !assetSame (claimedMint folds) result.mint then throw "net-mint-mismatch"',
        'if false then throw "net-mint-mismatch"',
    ),
}


def run():
    lean = shutil.which("lean")
    assert lean, "Lean unavailable"
    version = subprocess.check_output([lean, "--version"], text=True).strip()
    assert "version 4.25.0" in version, version
    paths = [ROOT / "lean/Singular/Model.lean", ROOT / "lean/Singular/Driver.lean",
             ROOT / "lean/DriverMain.lean"]
    sources = [p.read_text() for p in paths]
    report = {"lean": version, "sources": {str(p.relative_to(ROOT)):
              hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}, "runs": []}
    for name, replacement in [("baseline", None), *MUTATIONS.items()]:
        model = sources[0]
        if replacement:
            old, new = replacement
            assert model.count(old) == 1, f"mutant {name} no longer matches exactly once"
            model = model.replace(old, new)
        with tempfile.TemporaryDirectory(prefix="singular-rejection-") as directory:
            tmp = Path(directory)
            (tmp / "Singular").mkdir()
            for relative, text in zip(
                    ["Singular/Model.lean", "Singular/Driver.lean", "DriverMain.lean"],
                    [model, sources[1], sources[2]]):
                (tmp / relative).write_text(text)
            import os
            env = {**os.environ, "LEAN_PATH": str(tmp)}
            for module in ["Model", "Driver"]:
                build = subprocess.run([lean, "-o", f"Singular/{module}.olean",
                                        f"Singular/{module}.lean"],
                                       cwd=tmp, env=env, capture_output=True, text=True)
                assert build.returncode == 0, f"SETUP FAILURE {name}: {build.stdout}{build.stderr}"
            check = subprocess.run([lean, "DriverMain.lean"], cwd=tmp, env=env,
                                   capture_output=True, text=True)
            output = check.stdout + check.stderr
            errors = [line for line in output.splitlines() if "error:" in line]
            if replacement:
                assert check.returncode != 0 and errors, f"SURVIVED {name}"
                assert (all(e.endswith("error: Expression") for e in errors)
                        and output.count("did not evaluate to `true`") == len(errors)), (
                    f"NOT A BEHAVIORAL KILL {name}: {output}"
                )
            else:
                assert check.returncode == 0, output
            report["runs"].append({"name": name, "exit": check.returncode,
                                   "guardFailures": errors})
            print(f"{name}: {'KILLED' if replacement else 'PASS'}", flush=True)
    target = ROOT / "specs/494-protected-rejection/mutation-receipt.json"
    target.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    run()
