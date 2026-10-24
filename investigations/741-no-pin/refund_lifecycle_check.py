"""Reconcile compiled application statements, effects and source-derived extents."""

import copy
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
STANDARD = {"propext", "Classical.choice", "Quot.sound"}
PREFIX = "NoPin.ApplicationRequests.RefundLifecycle.Statements."
EVIDENCE = "NoPin.ApplicationRequests.RefundLifecycle.Evidence."


def require(condition, message):
    if not condition:
        raise ValueError("refund lifecycle evidence: " + message)


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def reconcile(records, ledger):
    observed = [r for r in records if r.get("family") == "refund-lifecycle"]
    inventories = [r for r in observed if "constructors" in r]
    require(len(inventories) == 1, "missing or duplicate inventory")
    inventory = inventories[0]
    require(
        len(inventory["constructors"]) > 1 and len(inventory["guards"]) > 1,
        "empty extent",
    )
    declarations = {r["name"]: r for r in observed if "name" in r}
    require(
        len(declarations) == sum("name" in r for r in observed), "duplicate declaration"
    )
    source = {n: d for n, d in declarations.items() if n.startswith(PREFIX)}
    rows = ledger["statements"]
    require(
        len(rows) > 1 and len({r["theorem"] for r in rows}) == len(rows),
        "empty or duplicate row",
    )
    require({r["theorem"] for r in rows} == set(source), "statement extent mismatch")
    bindings = [r for r in observed if "binding" in r]
    require(len(bindings) == len(rows), "missing or duplicate binding")
    bindings = {r["binding"]: r for r in bindings}
    for row in rows:
        name = row["theorem"]
        require(
            row["status"] in {"STATED", "PROVED"}
            and set(source[name]["axioms"]) <= STANDARD | {"sorryAx"}
            and row["status"]
            == ("STATED" if "sorryAx" in source[name]["axioms"] else "PROVED"),
            "wrong proof status",
        )
        require(
            "Hypothesis" in source[name]["doc"]
            and ("Status: " + row["status"] + ".") in source[name]["doc"],
            "unmarked statement",
        )
        require(
            row["statementSha256"] == digest(source[name]["type"]),
            "statement digest mismatch",
        )
        require(name in bindings, "unbound statement")
        for field in ["witness", "positive", "mutant"]:
            require(
                row[field] == bindings[name][field] and row[field] in declarations,
                "wrong certificate binding",
            )
        require(row["selector"] in inventory["guards"], "missing or unknown selector")
    for name, declaration in declarations.items():
        if name not in source:
            require(
                set(declaration["axioms"]) <= STANDARD,
                "unproved finite certificate: " + name,
            )
    inversions = ledger["inversions"]
    require(
        len(inversions) == len(inventory["constructors"])
        and len({r["constructor"] for r in inversions}) == len(inversions),
        "missing or duplicate inversion",
    )
    require(
        {r["constructor"] for r in inversions} == set(inventory["constructors"]),
        "inversion extent mismatch",
    )
    cases = [r for r in observed if "constructor" in r]
    require(
        len(cases) == len(inversions)
        and {r["constructor"] for r in cases} == set(inventory["constructors"]),
        "unwitnessed constructor",
    )
    for row in inversions:
        require(
            row["inversion"] == PREFIX + row["constructor"] + "_inversion"
            and row["inversion"] in source,
            "wrong inversion binding",
        )
    selectors = ledger["guards"]
    require(
        len(selectors) == len(inventory["guards"])
        and len({r["selector"] for r in selectors}) == len(selectors),
        "missing or duplicate guard",
    )
    require(
        {r["selector"] for r in selectors} == set(inventory["guards"]),
        "guard extent mismatch",
    )
    used = {g for row in cases for g in row["selectors"]}
    require(used == set(inventory["guards"]), "unexercised production guard")
    for row in selectors:
        require(row["siteCount"] == 1, "non-atomic selector")
        require(
            row["positive"] == EVIDENCE + "guard_" + row["selector"] + "_positive"
            and row["positive"] in declarations,
            "unbound guard positive",
        )
        require(
            row["mutant"] == EVIDENCE + "guard_" + row["selector"] + "_mutant"
            and row["mutant"] in declarations,
            "unbound guard falsification",
        )


def check(records):
    ledger = json.loads((ROOT / "refund-lifecycle-statements.json").read_text())
    require(ledger["acceptedLaw"] is False, "candidate promoted to law")
    for file, expected in ledger["definitions"].items():
        require(
            digest((ROOT / file).read_text()) == expected, "definition digest: " + file
        )
    for file, expected in ledger["preservedBaseArtifacts"].items():
        require(
            hashlib.sha256((ROOT / file).read_bytes()).hexdigest() == expected,
            "prior artifact changed: " + file,
        )
    reconcile(records, ledger)
    mutants = json.loads((ROOT / "refund-lifecycle-mutants.json").read_text())
    require(
        mutants
        == {
            "acceptedLaw": False,
            "guards": ledger["guards"],
            "statements": [
                {
                    "theorem": r["theorem"],
                    "selector": r["selector"],
                    "mutant": r["mutant"],
                }
                for r in ledger["statements"]
            ],
        },
        "mutant ledger drift",
    )
    source = (ROOT / "lean/NoPin/ApplicationRequests/Application.lean").read_text()
    # The earlier owner-reclaim branch and aggregate are historical; the new
    # handler owns those sites and delegates its other branches unchanged.
    source = re.sub(
        r"  \| \.ownerReclaim _ =>.*?(?=\n  \| \.expiredCleanup)",
        "",
        source,
        flags=re.S,
    )
    source = re.sub(
        r"\ndef applicationStep\b.*?(?=\nend NoPin.ApplicationRequests)",
        "",
        source,
        flags=re.S,
    )
    source += (
        ROOT / "lean/NoPin/ApplicationRequests/RefundApplication.lean"
    ).read_text()
    sites = re.findall(r"appGuard mutation \.(\w+)", source)
    require(
        len(sites) >= len(set(sites)) == len(ledger["guards"]),
        "source guard site denominator mismatch",
    )
    require(
        all(
            sites.count(r["selector"]) == r["sourceOccurrences"]
            for r in ledger["guards"]
        ),
        "source guard occurrence drift",
    )
    require(
        set(sites) == {r["selector"] for r in ledger["guards"]},
        "source guard not certified",
    )
    corpus = [
        r for r in records if r.get("family") == "refund-lifecycle" and "scenario" in r
    ]
    require(len(corpus) > len(ledger["inversions"]), "empty corpus")
    require(
        corpus == json.loads((ROOT / "refund-lifecycle-corpus.json").read_text()),
        "corpus drift",
    )
    replay = subprocess.run(
        [str(ROOT / ".lake/build/bin/no-pin-oracle")],
        input="".join(
            json.dumps({"family": "refund-lifecycle", **r["scenario"]}) + "\n"
            for r in corpus
        ),
        capture_output=True,
        text=True,
        check=True,
    )
    require(
        [json.loads(line) for line in replay.stdout.splitlines()]
        == [r["result"] for r in corpus],
        "oracle replay disagreement",
    )
    controls = []
    mutations = [
        ("missing-row", lambda d: d["statements"].pop()),
        (
            "duplicate-row",
            lambda d: d["statements"].append(copy.deepcopy(d["statements"][0])),
        ),
        ("wrong-digest", lambda d: d["statements"][0].update(statementSha256="0" * 64)),
        (
            "wrong-witness",
            lambda d: d["statements"][0].update(witness=d["statements"][1]["witness"]),
        ),
        ("missing-inversion", lambda d: d["inversions"].pop()),
        (
            "duplicate-inversion",
            lambda d: d["inversions"].append(copy.deepcopy(d["inversions"][0])),
        ),
        (
            "wrong-inversion",
            lambda d: d["inversions"][0].update(
                inversion=d["inversions"][1]["inversion"]
            ),
        ),
        ("missing-guard", lambda d: d["guards"].pop()),
        (
            "duplicate-guard",
            lambda d: d["guards"].append(copy.deepcopy(d["guards"][0])),
        ),
        ("two-site-selector", lambda d: d["guards"][0].update(siteCount=2)),
        ("unrelated-selector", lambda d: d["guards"][0].update(selector="unrelated")),
        ("empty-extent", lambda d: d.update(statements=[], inversions=[], guards=[])),
    ]
    for label, mutate in mutations:
        data = copy.deepcopy(ledger)
        mutate(data)
        try:
            reconcile(records, data)
        except ValueError:
            controls.append(label)
        else:
            raise ValueError("lifecycle checker accepted negative control: " + label)
    run = subprocess.run(
        [sys.executable, str(ROOT / "refund_lifecycle_controls.py")],
        capture_output=True,
        text=True,
    )
    require(
        run.returncode == 0,
        "independence execution failed: " + run.stdout[-1000:] + run.stderr[-4000:],
    )
    (ROOT / ".lake/refund-lifecycle-controls-report.json").write_text(run.stdout)
    independence = json.loads(run.stdout)
    import refund_proof_check

    proofs = refund_proof_check.check(records, ledger)
    print(
        json.dumps(
            {
                "status": "HYPOTHETICAL-PROOF-CANDIDATE",
                "proofEvidence": proofs,
                "proved": sum(r["status"] == "PROVED" for r in ledger["statements"]),
                "family": "refund-lifecycle",
                "acceptedLaw": False,
                "statements": len(ledger["statements"]),
                "sorryAx": sum(r["status"] == "STATED" for r in ledger["statements"]),
                "inversions": len(ledger["inversions"]),
                "guards": len(ledger["guards"]),
                "oracleReplays": len(corpus),
                "checkerNegativeControls": controls,
                "independenceControls": len(independence["controls"]) - 1,
                "directSubprocesses": independence["directSubprocesses"] + 2,
            }
        )
    )
