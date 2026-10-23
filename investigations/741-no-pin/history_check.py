"""Reconcile compiled history statements and constructor inversions."""
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
STANDARD = {"propext", "Classical.choice", "Quot.sound"}
PREFIX = "NoPin.ApplicationRequests.HistoryStatements."


def require(condition, message):
    if not condition:
        raise ValueError("history evidence: " + message)


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def reconcile(records, ledger):
    records = [r for r in records if r.get("family") == "history"]
    declarations = {r["name"]: r for r in records if "name" in r}
    require(len(declarations) == sum("name" in r for r in records), "duplicate declaration")
    source = {name: r for name, r in declarations.items() if name.startswith(PREFIX)}
    rows = ledger["statements"]
    require(len(rows) >= 4 and len({r["theorem"] for r in rows}) == len(rows), "empty or duplicate statements")
    require({r["theorem"] for r in rows} == set(source), "statement extent mismatch")
    bindings = [r for r in records if "binding" in r]
    require(len(bindings) == len(rows) and {r["binding"] for r in bindings} == set(source), "unbound statement")
    bindings = {r["binding"]: r for r in bindings}
    for name, declaration in declarations.items():
        if name not in source:
            require(set(declaration["axioms"]) <= STANDARD, "unproved history certificate: " + name)
    for row in rows:
        declaration = source[row["theorem"]]
        require(row["status"] == "STATED" and set(declaration["axioms"]) - STANDARD == {"sorryAx"}, "unexpected proof status")
        require("Status: STATED." in declaration["doc"], "unmarked hypothesis")
        require(row["statementSha256"] == digest(declaration["type"]), "changed statement")
        binding = bindings[row["theorem"]]
        require(row["witness"] == binding["witness"] and row["positive"] == binding["positive"], "wrong certificate binding")
        require(binding["witness"] in declarations and binding["positive"] in declarations, "missing certificate")
        require(row["selectors"], "missing history mutant")
    inventories = [r["constructors"] for r in records if "constructors" in r]
    require(len(inventories) == 1 and len(inventories[0]) > 1, "empty constructor inventory")
    constructors = inventories[0]
    require(len(set(constructors)) == len(constructors), "duplicate source constructor")
    observed = [r for r in records if "constructor" in r]
    inversions = ledger["inversions"]
    require(len(inversions) == len(constructors) == len(observed), "constructor without inversion")
    require(len({r["constructor"] for r in inversions}) == len(inversions), "duplicate inversion")
    observed = {r["constructor"]: r for r in observed}
    require(set(observed) == {r["constructor"] for r in inversions} == set(constructors), "inversion extent mismatch")
    for row in inversions:
        compiled = observed[row["constructor"]]
        require(row["inversion"] == compiled["inversion"], "wrong inversion binding")
        require(row["certificate"] == compiled["certificate"] and row["certificate"] in declarations,
                "missing complete inversion certificate")
        for field in ["sourceType", "inversionType", "inversionValue"]:
            require(row[field + "Sha256"] == digest(compiled[field]), "changed constructor premise or inversion")


def check(records):
    ledger = json.loads((ROOT / "history-statements.json").read_text())
    require(ledger["acceptedLaw"] is False, "candidate promoted to law")
    for file, expected in ledger["definitions"].items():
        require(digest((ROOT / file).read_text()) == expected, "definition digest: " + file)
    for file, expected in ledger["preservedBaseArtifacts"].items():
        require(hashlib.sha256((ROOT / file).read_bytes()).hexdigest() == expected, "earlier artifact changed: " + file)
    reconcile(records, ledger)
    corpus = [r for r in records if r.get("family") == "history" and ("scenario" in r or "history" in r)]
    require(corpus == json.loads((ROOT / "history-corpus.json").read_text()), "history corpus drift")
    scenarios = [r for r in corpus if "scenario" in r]
    require(len(scenarios) > 1 and sum("history" in r for r in corpus) == 1, "empty history replay")
    trace = next(r for r in corpus if "history" in r)
    require(len(trace["history"]) > 1 and len(trace["otherProjection"]) > 1, "missing history projection")
    replay = subprocess.run([str(ROOT / ".lake/build/bin/no-pin-oracle")],
        input="".join(json.dumps({"family": "application-requests", **r["scenario"]}) + "\n" for r in scenarios),
        text=True, capture_output=True, check=True)
    require([json.loads(line) for line in replay.stdout.splitlines()] == [r["result"] for r in scenarios], "history boundary replay mismatch")
    controls = []
    for label, mutate in [
        ("missing-constructor", lambda data: data["inversions"].pop()),
        ("duplicate-constructor", lambda data: data["inversions"].append(copy.deepcopy(data["inversions"][0]))),
        ("wrong-constructor-binding", lambda data: data["inversions"][0].update(inversion=data["inversions"][1]["inversion"])),
        ("missing-statement", lambda data: data["statements"].pop()),
        ("wrong-statement-digest", lambda data: data["statements"][0].update(statementSha256="0" * 64)),
        ("unproved-certificate", None),
    ]:
        data = copy.deepcopy(ledger)
        observed = copy.deepcopy(records)
        if mutate:
            mutate(data)
        else:
            witness = data["statements"][0]["witness"]
            next(r for r in observed if r.get("name") == witness)["axioms"] = ["sorryAx"]
        try:
            reconcile(observed, data)
        except ValueError:
            controls.append(label)
        else:
            raise ValueError("history checker accepted negative control: " + label)
    run = subprocess.run([sys.executable, str(ROOT / "history_controls.py")], text=True, capture_output=True)
    require(run.returncode == 0, "history control execution failed: " + run.stdout[-1000:] + run.stderr[-7000:])
    raw = json.loads(run.stdout)
    (ROOT / ".lake/history-controls-report.json").write_text(run.stdout)
    expected = json.loads((ROOT / "history-mutants.json").read_text())["mutants"]
    stable = ["control", "selector", "siteCount", "sourceModule", "needle", "replacement", "sourceSha256", "mutatedSha256", "failedObligations"]
    require([{k: r[k] for k in stable} for r in raw["controls"]] == expected, "source-mutant ledger drift")
    require(all(r["certificateExit"] == 0 and r["rejectedClaimExit"] == 1 for r in raw["controls"]), "counterexample not certified")
    require({s for row in ledger["statements"] for s in row["selectors"]} <= {r["selector"] for r in expected}, "unexecuted selector")
    print(json.dumps({"status": "CANDIDATE-STATEMENTS-ONLY", "family": "history", "acceptedLaw": False,
        "statements": len(ledger["statements"]), "sorryAx": len(ledger["statements"]),
        "constructorInversions": len(ledger["inversions"]), "checkerNegativeControls": controls,
        "historyMutants": len(expected), "oracleReplays": len(scenarios),
        "directSubprocesses": raw["directSubprocesses"] + 2}))


if __name__ == "__main__":
    records = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines() if line.startswith("{")]
    check(records)
