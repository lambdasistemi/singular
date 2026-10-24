"""Reconcile compiled journey allocations, accepted dependencies and differences."""

import copy
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
PREFIX = "NoPin.ApplicationRequests.Money.Statements."
EVIDENCE = "NoPin.ApplicationRequests.Money.Evidence."
STANDARD = {"propext", "Classical.choice", "Quot.sound"}


def require(condition, message):
    if not condition:
        raise ValueError("money evidence: " + message)


def reconcile(records, ledger):
    observed = [r for r in records if r.get("family") == "money"]
    inventories = [r for r in observed if "journeys" in r]
    require(len(inventories) == 1, "missing or duplicate source inventory")
    inventory = inventories[0]
    declarations = {r["name"]: r for r in observed if "name" in r}
    require(
        len(declarations) == sum("name" in r for r in observed), "duplicate declaration"
    )
    statements = {n: d for n, d in declarations.items() if n.startswith(PREFIX)}
    rows = ledger["statements"]
    require(
        len(rows) > 1 and len({r["theorem"] for r in rows}) == len(rows),
        "empty or duplicate rows",
    )
    require(
        {r["theorem"] for r in rows} == set(statements), "statement extent mismatch"
    )
    bindings = [r for r in observed if "binding" in r]
    require(len(bindings) == len(rows), "missing or duplicate binding")
    bindings = {r["binding"]: r for r in bindings}
    for row in rows:
        name = row["theorem"]
        declaration = statements[name]
        axioms = set(declaration["axioms"])
        proof_status = "STATED" if "sorryAx" in axioms else "PROVED"
        require(axioms <= STANDARD | {"sorryAx"}, "untrusted proof axiom")
        require(row.get("proofStatus") == proof_status, "wrong compiled proof status")
        require(row["status"] in {proof_status, "REFUTED"}, "wrong proof status")
        if row["status"] == "REFUTED":
            refutation = declaration.get("refutation") or {}
            require(
                refutation.get("name") == row.get("refutation")
                and refutation.get("exact") is True,
                "refutation is not the exact negation",
            )
            require(
                set(refutation.get("axioms", ["missing"])) <= STANDARD,
                "unproved refutation",
            )
        require(
            "Hypothesis" in declaration["doc"]
            and ("Status: " + row["status"] + ".") in declaration["doc"],
            "unmarked statement",
        )
        require(
            row["statementSha256"]
            == hashlib.sha256(declaration["type"].encode()).hexdigest(),
            "statement digest mismatch",
        )
        for field in ["witness", "positive", "mutant"]:
            require(
                row[field] == bindings[name][field] and row[field] in declarations,
                "wrong certificate binding",
            )
        selector = row["selector"]
        require(len(selector) == 1, "selector changes multiple layers")
        if "allocation" in selector:
            require(
                selector["allocation"] in inventory["sites"],
                "unknown allocation selector",
            )
        elif "holdingPayment" in selector:
            require(
                selector["holdingPayment"] in inventory["holdingPaymentGuards"],
                "unknown holding payment selector",
            )
        else:
            require(
                selector.get("application") in ledger["applicationGuards"],
                "unknown application selector",
            )
    for name, declaration in declarations.items():
        if name not in statements:
            require(
                set(declaration["axioms"]) <= STANDARD,
                "unproved finite certificate: " + name,
            )
    require(
        EVIDENCE + "complete_grid" in declarations, "missing complete grid certificate"
    )
    guards = ledger["allocationSites"]
    require(
        len(guards) == len(inventory["sites"])
        and len({r["site"] for r in guards}) == len(guards),
        "missing or duplicate allocation site",
    )
    require(
        {r["site"] for r in guards} == set(inventory["sites"]),
        "allocation extent mismatch",
    )
    for row in guards:
        require(row["siteCount"] == 1, "non-atomic allocation selector")
        require(
            row["positive"] == EVIDENCE + "site_" + row["site"] + "_positive"
            and row["positive"] in declarations,
            "unbound allocation positive",
        )
        require(
            row["mutant"] == EVIDENCE + "site_" + row["site"] + "_mutant"
            and row["mutant"] in declarations,
            "unbound allocation falsification",
        )
    actual_grid = [r for r in observed if "party" in r]
    grid = ledger["differences"]
    extent = {(j, p) for j in inventory["journeys"] for p in inventory["parties"]}
    require(
        len(grid) == len(extent)
        and len({(r["journey"], r["party"]) for r in grid}) == len(grid),
        "missing or duplicate party/journey cell",
    )
    require(
        {(r["journey"], r["party"]) for r in grid} == extent,
        "party/journey extent mismatch",
    )
    require(grid == actual_grid, "amount or ruling differs from the compiled grid")
    require(
        all(r["ruling"] is not None or r["old"] == r["new"] for r in grid),
        "untagged difference",
    )
    constructors = [r for r in observed if "acceptedConstructor" in r]
    require(
        len(constructors) == len(inventory["acceptedApplicationConstructors"]),
        "accepted constructor missing a disposition",
    )
    require(
        {r["acceptedConstructor"] for r in constructors}
        == set(inventory["acceptedApplicationConstructors"]),
        "accepted constructor extent mismatch",
    )
    require(
        ledger["acceptedJourneys"] == constructors,
        "accepted journey classification drift",
    )
    require(
        all(r["replacementJourneys"] for r in constructors), "empty journey replacement"
    )
    require(
        all(
            j in inventory["journeys"]
            for r in constructors
            for j in r["replacementJourneys"]
        ),
        "unknown replacement journey",
    )
    dependencies = {
        r["producer"]: set(r["references"]) for r in observed if "producer" in r
    }
    require(
        {
            "Singular.foldObligations",
            "Singular.refundAmount",
            "Singular.registrationDeclaredLovelace",
            "Singular.terminationDeclaredLovelace",
        }
        <= dependencies["oldAllocation"],
        "old money is not read through accepted definitions",
    )
    require(
        "OpenDatumApplication.updateStep" in dependencies["oldUpdate"],
        "old update is not the accepted consumer",
    )
    require(
        "Singular.retractionAccepted" in dependencies["oldReclaim"],
        "old reclaim is not the accepted judgement",
    )
    require(
        "Singular.rejectionAccepted" in dependencies["oldRejection"],
        "old rejection is not the accepted judgement",
    )
    require(
        "Singular.Reachable.initial" in dependencies["acceptedGenesisWitness"],
        "old genesis is not accepted reachability",
    )


def check(records):
    ledger = json.loads((ROOT / "money-statements.json").read_text())
    require(ledger["acceptedLaw"] is False, "candidate promoted to law")
    for file, expected in ledger["definitions"].items():
        require(
            hashlib.sha256((ROOT / file).read_bytes()).hexdigest() == expected,
            "definition digest: " + file,
        )
    for file, expected in ledger["preservedStatementRows"].items():
        rows = json.loads((ROOT / file).read_text())["statements"]
        encoded = json.dumps(rows, ensure_ascii=False, separators=(",", ":"))
        require(
            hashlib.sha256(encoded.encode()).hexdigest() == expected,
            "earlier statement rows changed: " + file,
        )
    reconcile(records, ledger)
    mutants = json.loads((ROOT / "money-mutants.json").read_text())
    require(
        mutants
        == {
            "acceptedLaw": False,
            "allocationSites": ledger["allocationSites"],
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
    observed = [r for r in records if r.get("family") == "money"]
    corpus = [r for r in observed if "scenario" in r]
    require(
        corpus == json.loads((ROOT / "money-corpus.json").read_text()), "corpus drift"
    )
    require(len(corpus) > len(ledger["statements"]), "empty corpus")
    replay = subprocess.run(
        [str(ROOT / ".lake/build/bin/no-pin-oracle")],
        input="".join(
            json.dumps({"family": "money", **r["scenario"]}) + "\n" for r in corpus
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
    authorities = [r for r in corpus if "authorityRole" in r]
    require(len(authorities) == 4, "missing authority controls")
    require(len({r["signer"] for r in authorities}) == 2, "trivial authority witness")
    for role, expected in [("controller", False), ("refundAddress", True)]:
        selected = [r for r in authorities if r["authorityRole"] == role]
        require(
            len(selected) == 2
            and {r["scenario"]["surface"] for r in selected}
            == {"applicationStep", "oldReclaim"},
            "authority layer missing",
        )
        require(
            all(r["result"] is expected for r in selected),
            "reclaim authority differs from accepted economics",
        )
    mismatch = [r for r in corpus if r.get("oldMismatchControl")]
    require(
        len(mismatch) == 1 and mismatch[0]["result"] is True,
        "old mismatch rejection not executed",
    )
    for journey in ["earlyRejection", "unsupportedBooking", "liveWithdrawal"]:
        selected = [
            r
            for r in corpus
            if r["scenario"]["journey"] == journey
            and r["scenario"]["surface"] == "applicationStep"
        ]
        require(
            len(selected) == 1 and selected[0]["result"] is False,
            "negative journey accepted: " + journey,
        )
    sites = re.findall(
        r"amountAt m \.(\w+)",
        (ROOT / "lean/NoPin/ApplicationRequests/Money.lean").read_text(),
    )
    require(
        len(sites) == len(set(sites)) == len(ledger["allocationSites"]),
        "allocation source denominator mismatch",
    )
    require(
        set(sites) == {r["site"] for r in ledger["allocationSites"]},
        "uncertified allocation site",
    )
    controls = []
    changes = [
        ("missing-row", lambda d: d["statements"].pop()),
        ("wrong-digest", lambda d: d["statements"][0].update(statementSha256="0" * 64)),
        (
            "wrong-witness",
            lambda d: d["statements"][0].update(witness=d["statements"][1]["witness"]),
        ),
        (
            "two-layer-selector",
            lambda d: d["statements"][0]["selector"].update(allocation="oldRefund"),
        ),
        ("two-site-selector", lambda d: d["allocationSites"][0].update(siteCount=2)),
        ("missing-allocation-site", lambda d: d["allocationSites"].pop()),
        (
            "journey-without-row",
            lambda d: d.update(
                differences=[r for r in d["differences"] if r["journey"] != "create"]
            ),
        ),
        (
            "untagged-difference",
            lambda d: next(r for r in d["differences"] if r["old"] != r["new"]).update(
                ruling=None
            ),
        ),
        (
            "wrong-ruling",
            lambda d: next(r for r in d["differences"] if r["old"] != r["new"]).update(
                ruling="threePhases"
            ),
        ),
        (
            "equal-cell-moved",
            lambda d: next(r for r in d["differences"] if r["ruling"] is None).update(
                new=1
            ),
        ),
        ("accepted-constructor-without-row", lambda d: d["acceptedJourneys"].pop()),
    ]
    for label, mutate in changes:
        candidate = copy.deepcopy(ledger)
        mutate(candidate)
        try:
            reconcile(records, candidate)
        except ValueError:
            controls.append(label)
        else:
            raise ValueError("money checker accepted negative control: " + label)
    run = subprocess.run(
        [sys.executable, str(ROOT / "money_controls.py")],
        capture_output=True,
        text=True,
    )
    require(
        run.returncode == 0,
        "independence execution failed: " + run.stdout[-1000:] + run.stderr[-5000:],
    )
    (ROOT / ".lake/money-controls-report.json").write_text(run.stdout)
    independence = json.loads(run.stdout)
    import money_proof_check

    proof_evidence = money_proof_check.check(records, ledger)
    print(
        json.dumps(
            {
                "family": "money",
                "status": "HYPOTHETICAL-PROOF-CANDIDATE",
                "acceptedLaw": False,
                "statements": len(ledger["statements"]),
                "proved": sum(r["status"] == "PROVED" for r in ledger["statements"]),
                "refuted": sum(r["status"] == "REFUTED" for r in ledger["statements"]),
                "open": sum(r["status"] == "STATED" for r in ledger["statements"]),
                "sorryAx": sum(
                    r["proofStatus"] == "STATED" for r in ledger["statements"]
                ),
                "proofEvidence": proof_evidence,
                "partyJourneyCells": len(ledger["differences"]),
                "oracleReplays": len(corpus),
                "authorityControls": len(authorities),
                "checkerNegativeControls": controls,
                "independenceControls": len(independence["controls"]) - 1,
                "directSubprocesses": independence["directSubprocesses"] + 2,
            }
        )
    )
