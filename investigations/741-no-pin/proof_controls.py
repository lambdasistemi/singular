"""Execute kernel controls for the hypothetical proof evidence instrument."""

import json
import hashlib
import os
import shutil
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
STANDARD = {"propext", "Classical.choice", "Quot.sound"}
BASE = "47275241c6b8aa2ca5f64cc42e52629dd3804dde"


def base_closure(directory):
    """Recompile frozen base definitions, avoiding candidate proof imports."""
    source_root, library = directory / "base-source", directory / "base-lib"
    environment = dict(os.environ)
    paths = subprocess.check_output(
        ["lake", "-d", str(ROOT), "--keep-toolchain", "env", "printenv", "LEAN_PATH"],
        text=True,
    ).strip()
    environment["LEAN_PATH"] = str(library) + ":" + paths
    shutil.copytree(ROOT / ".lake/build/lib/lean/NoPin", library / "NoPin")
    modules = [
        "Core",
        "Application",
        "Client",
        "History",
        "Oracle",
        "Conditions",
        "Role",
        "Effects",
        "Statements",
    ]
    for module in modules:
        relative = "NoPin/ApplicationRequests/" + module + ".lean"
        source = subprocess.check_output(
            ["git", "show", BASE + ":investigations/741-no-pin/lean/" + relative],
            cwd=ROOT,
            text=True,
        )
        target = source_root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(source)
        output = library / relative.replace(".lean", ".olean")
        output.parent.mkdir(parents=True, exist_ok=True)
        result = subprocess.run(
            [
                "timeout",
                "180",
                "lean",
                "-R",
                str(source_root),
                "-o",
                str(output),
                str(target),
            ],
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        log = result.stdout + result.stderr
        (ROOT / ".lake" / ("proof-control-base-" + module + ".log")).write_text(log)
        if result.returncode:
            raise ValueError(
                "base closure setup failed: " + module + "\n" + log[-5000:]
            )
    audit = source_root / "Audit.lean"
    audit.write_text(
        (ROOT / "lean/NoPin/ApplicationRequests/ProofAudit.lean").read_text()
        + "\n#singular_proof_closure\n"
    )
    result = subprocess.run(
        ["timeout", "180", "lean", "-R", str(source_root), str(audit)],
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )
    log = result.stdout + result.stderr
    (ROOT / ".lake/proof-control-base-closure.log").write_text(log)
    if result.returncode:
        raise ValueError("base closure report failed: " + log[-5000:])
    closure = next(
        json.loads(line)["proofClosure"]
        for line in log.splitlines()
        if line.startswith("{")
    )
    observed = {
        row["name"]: hashlib.sha256(
            json.dumps(
                row, ensure_ascii=False, separators=(",", ":"), sort_keys=True
            ).encode()
        ).hexdigest()
        for row in closure
    }
    expected = json.loads((ROOT / "proof-definition-baseline.json").read_text())
    if expected["base"] != BASE or observed != expected["constants"]:
        raise ValueError("fresh base kernel closure differs from frozen baseline")
    return {
        "control": "fresh-base-definition-compilation",
        "base": BASE,
        "constants": len(observed),
        "modules": len(modules),
    }


def run(target, source):
    target.write_text(source)
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
        text=True,
        capture_output=True,
        check=False,
    )
    log = result.stdout + result.stderr
    (ROOT / ".lake" / ("proof-control-" + target.stem + ".log")).write_text(log)
    if result.returncode != 0:
        raise ValueError(
            "proof control setup failed: " + target.stem + "\n" + log[-5000:]
        )
    return log


def check():
    results = []
    with tempfile.TemporaryDirectory(
        prefix="proof-controls-", dir=ROOT / ".lake"
    ) as directory:
        directory = Path(directory)
        results.append(base_closure(directory))
        for label, source in {
            "custom-axiom": "axiom untrusted (p : Prop) : p\ntheorem hostile : True := untrusted True\n",
            "native-decide": "theorem hostile : True := by native_decide\n",
        }.items():
            log = run(
                directory / (label + ".lean"),
                "import Lean\n" + source + "#print axioms hostile\n",
            )
            match = re.search(r"depends on axioms: \[([^\]]*)\]", log)
            if match is None:
                raise ValueError("missing compiled control axioms: " + label)
            axioms = {name.strip() for name in match[1].split(",") if name.strip()}
            if not axioms - STANDARD:
                raise ValueError("untrusted proof control survived: " + label)
            results.append(
                {
                    "control": label,
                    "compiled": True,
                    "rejectedAxioms": sorted(axioms - STANDARD),
                }
            )
        negation = run(
            directory / "negation.lean",
            """import NoPin.ApplicationRequests.ProofAudit
open Lean Elab Command
namespace RefutationControl
theorem target : False ∧ True := by sorry
theorem exactProof : ¬ (False ∧ True) := by simp
theorem weakerProof : ¬ False := by simp
elab "#negation_control" : command => do
  let correct ← liftTermElabM <| NoPin.ApplicationRequests.ProofAudit.exactNegation
    "RefutationControl.target".toName "RefutationControl.exactProof".toName
  let weaker ← liftTermElabM <| NoPin.ApplicationRequests.ProofAudit.exactNegation
    "RefutationControl.target".toName "RefutationControl.weakerProof".toName
  unless correct && !weaker do throwError "negation control survived"
  IO.println (Json.mkObj [("exactNegationControl", toJson correct), ("weakerRejected", toJson (!weaker))]).compress
#negation_control
end RefutationControl
""",
        )
        observed = [
            json.loads(line) for line in negation.splitlines() if line.startswith("{")
        ]
        if observed != [{"exactNegationControl": True, "weakerRejected": True}]:
            raise ValueError("missing negation control result")
        results.append({"control": "exact-versus-weaker-negation", "detected": True})
        modules = [
            "Core",
            "Application",
            "Client",
            "History",
            "Oracle",
            "Conditions",
            "Role",
            "Effects",
            "Statements",
            "ProofAudit",
        ]
        sources = {
            name: (
                ROOT / "lean/NoPin/ApplicationRequests" / (name + ".lean")
            ).read_text()
            for name in modules
        }
        sources["Statements"] = re.sub(
            r":= by.*?(?=\n/--|\nend NoPin.ApplicationRequests.Statements)",
            ":= by sorry\n",
            sources["Statements"],
            flags=re.S,
        )
        closures = {}
        for label in ["positive-closure", "weakened-core-guard"]:
            current = dict(sources)
            needle = "applyGuard mutation .foldAddress (after.state.credential == before.state.credential)"
            if current["Core"].count(needle) != 1:
                raise ValueError("core guard mutation not uniquely applicable")
            if label == "weakened-core-guard":
                current["Core"] = current["Core"].replace(
                    needle, "applyGuard mutation .foldAddress true"
                )
                if needle in current["Core"]:
                    raise ValueError("core guard mutation did not apply")
            text = "import NoPin.ApplicationRequests.Evidence\n"
            for name in modules:
                text += (
                    "\n"
                    + re.sub(r"^import .*$", "", current[name], flags=re.M).replace(
                        "NoPin.ApplicationRequests", "NoPin.ProofClosureControl"
                    )
                    + "\n"
                )
            log = run(
                directory / (label + ".lean"), text + "\n#singular_proof_closure\n"
            )
            records = [
                json.loads(line) for line in log.splitlines() if line.startswith("{")
            ]
            closure = next(
                record["proofClosure"] for record in records if "proofClosure" in record
            )
            closures[label] = {record["name"]: record for record in closure}
        before, after = closures["positive-closure"], closures["weakened-core-guard"]
        name = "NoPin.ProofClosureControl.fold"
        if (
            len(before) < 1000
            or set(before) != set(after)
            or before[name] == after[name]
        ):
            raise ValueError("kernel closure did not detect weakened Core fold guard")
        results.append(
            {
                "control": "weakened-core-guard",
                "constant": name,
                "positiveConstants": len(before),
                "detected": True,
            }
        )
    print(
        json.dumps(
            {"kernelProofControls": results, "directSubprocesses": 25}, sort_keys=True
        )
    )


if __name__ == "__main__":
    check()
