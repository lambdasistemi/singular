#!/usr/bin/env python3
"""Check the compiled #741 hypothesis evidence; this is not acceptance of a law."""

import hashlib
import json
import re
import sys
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent
STANDARD = {"propext", "Classical.choice", "Quot.sound"}


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def load_report(path):
    records = []
    for line in Path(path).read_text().splitlines():
        if line.startswith("{"):
            records.append(json.loads(line))
    require(records, "empty compiled report")
    return records


def check_family(records, namespace, prefix, family):
    names = [r["name"] for r in records if "name" in r]
    require(len(names) == len(set(names)), "duplicate compiled declaration")
    declarations = {r["name"]: r for r in records if "name" in r}
    inventory = [r for r in records if "cases" in r]
    require(len(inventory) == 1, "missing or duplicate compiled inventory")
    inventory = inventory[0]
    cases, guards = inventory["cases"], inventory["guards"]
    require(set(inventory["roles"]) <= set(cases), "role without public classification")
    require(len(cases) > 1 and len(guards) > 1, "empty/truncated inventory")
    require(len(set(cases)) == len(cases), "duplicate case")
    case_guards = {r["case"]: r["guards"] for r in records if "case" in r}
    require(set(case_guards) == set(cases), "public case missing from execution")
    used = [g for group in case_guards.values() for g in group]
    if family == "application-requests":
        require(set(used) == set(guards), "source guard not exercised")
    else:
        require(sorted(used) == sorted(guards), "guard coverage not one-to-one")
    corpus = [r for r in records if "scenario" in r]
    require(corpus, "no executable oracle corpus")
    require(
        corpus == json.loads((ROOT / (prefix + "corpus.json")).read_text()),
        "oracle corpus drift",
    )
    replay = subprocess.run(
        [str(ROOT / ".lake/build/bin/no-pin-oracle")],
        input="".join(
            json.dumps({**r["scenario"], **({"family": family} if family else {})})
            + "\n"
            for r in corpus
        ),
        text=True,
        capture_output=True,
        check=True,
    )
    require(
        [json.loads(line) for line in replay.stdout.splitlines()]
        == [r["result"] for r in corpus],
        "oracle replay mismatch",
    )
    ledger = json.loads((ROOT / (prefix + "statements.json")).read_text())
    rows = ledger["statements"]
    mutants = json.loads((ROOT / (prefix + "mutants.json")).read_text())["mutants"]
    discovered = {n for n in declarations if n.startswith(namespace + ".Statements.")}
    names = [r["theorem"] for r in rows]
    require(len(names) == len(set(names)), "duplicate statement row")
    require(set(names) == discovered, "missing or extra theorem in ledger")
    require(len(rows) > 1, "empty/truncated statement ledger")
    for file, expected in ledger["definitions"].items():
        require(
            digest((ROOT / file).read_text()) == expected, f"definition digest: {file}"
        )
    for name, proof in declarations.items():
        if not name.startswith(namespace + ".Statements."):
            require(set(proof["axioms"]) <= STANDARD, f"unproved example: {name}")
    inversions = {}
    selector_owners = set()
    positive_count = negative_count = 0
    for row in rows:
        name = row["theorem"]
        declaration = declarations[name]
        require(declaration["kind"] == "theorem", f"not a theorem: {name}")
        require(
            set(declaration["axioms"]) - STANDARD == {"sorryAx"},
            f"not STATED debt: {name}",
        )
        require(
            digest(declaration["type"]) == row["statementSha256"],
            f"statement digest: {name}",
        )
        require(
            row["status"]
            in {
                "STATED",
                "REJECTED-READING-STATED",
                "REJECTED-READING-STATED-EXPECTED-REFUTABLE",
                "HYPOTHETICAL-READING-STATED-EXPECTED-REFUTABLE",
            },
            f"unknown status: {name}",
        )
        proof_status = "STATED" if "sorryAx" in declaration["axioms"] else "PROVED"
        require(row["proofStatus"] == proof_status == "STATED", f"proof status: {name}")
        marker = re.search(r"Status: ([A-Z-]+)\.", declaration["doc"])
        require(marker and marker.group(1) == row["status"], f"reading status: {name}")
        require(row["witnesses"], f"no witness: {name}")
        require(row["selectors"], f"no selector: {name}")
        for witness in row["witnesses"]:
            require(witness in declarations, f"missing witness: {witness}")
            proof = declarations[witness]
            require(set(proof["axioms"]) <= STANDARD, f"unproved witness: {witness}")
            require(
                f"{name.split('.')[-1]}_premise" in proof["type"],
                f"wrong premise: {witness}",
            )
            positive_count += 1
        owned = [m for m in mutants if m["theorem"] == name]
        require(
            {m["selector"] for m in owned} == set(row["selectors"]),
            f"selector ownership: {name}",
        )
        for mutation in owned:
            selector = mutation["selector"]
            require(selector in guards, f"unrelated mutant selector: {selector}")
            selector_owners.add(selector)
            positive = declarations.get(mutation["positive"])
            negative = declarations.get(mutation["negative"])
            require(positive and negative, f"unrelated/missing mutant proof: {name}")
            for proof in [positive, negative]:
                require(
                    set(proof["axioms"]) <= STANDARD,
                    f"unproved control: {proof['name']}",
                )
                require(
                    proof["kind"] == "theorem", "control is not an elaborated proof"
                )
            require(
                namespace + ".Mutation.none" in positive["type"],
                "candidate is not none",
            )
            require(
                namespace + ".Mutation.flip" in negative["type"],
                "mutant does not use selector",
            )
            require(f"{namespace}.Guard.{selector}" in negative["type"], "wrong guard")
            require(
                negative["candidateType"] == positive["type"],
                "candidate/mutant instance mismatch",
            )
            positive_count += 1
            negative_count += 1
        if row.get("inversion"):
            case = row["inversion"]
            if family:
                require(
                    declaration["inversion"] == case,
                    f"compiled inversion binding: {name}",
                )
            require(case not in inversions, f"duplicate inversion: {case}")
            inversions[case] = row
            require(
                set(row["selectors"]) == set(case_guards.get(case, [])),
                f"wrong inversion case: {case}",
            )
    require(set(inversions) == set(cases), "case without inversion")
    require(selector_owners == set(guards), "selector without executed owning theorem")
    require({m["theorem"] for m in mutants} == set(names), "mutant has unknown theorem")
    print(
        json.dumps(
            {
                "status": "CANDIDATE-STATEMENTS-ONLY",
                "statements": len(rows),
                "sorryAx": len(rows),
                "publicCases": len(cases),
                "atomicGuards": len(guards),
                "positiveProofs": positive_count,
                "negativeProofs": negative_count,
                "oracleReplays": len(corpus),
                "acceptedLaw": False,
                "family": family or "identity",
            },
            sort_keys=True,
        )
    )


def main():
    records = load_report(sys.argv[1])
    base = "5b1497d4daeb4b8f5f54ff89512fb45b1c22151f"
    for name in [
        "statements.json",
        "mutants.json",
        "corpus.json",
        "lean/NoPin/Statements.lean",
        "lean/NoPin/Identity.lean",
        "lean/NoPin/Witnesses.lean",
        "lean/NoPin/Mutants.lean",
        "lean/NoPin/Oracle.lean",
    ]:
        original = subprocess.run(
            ["git", "show", base + ":investigations/741-no-pin/" + name],
            capture_output=True,
            check=True,
        ).stdout
        require(
            (ROOT / name).read_bytes() == original, "slice-2 identity changed: " + name
        )
    require(
        all(
            r.get("family")
            in {None, "held", "application-requests", "history", "lifecycle"}
            for r in records
        ),
        "unknown evidence family",
    )
    check_family([r for r in records if not r.get("family")], "NoPin", "", None)
    check_family(
        [r for r in records if r.get("family") == "held"], "NoPin.Held", "held-", "held"
    )

    historical_base = "3f1fe718774c7e4069911fb28a0dab8a68714443"
    paths = subprocess.run(
        [
            "git",
            "ls-tree",
            "-r",
            "--name-only",
            historical_base,
            "--",
            "investigations/741-no-pin/lean/NoPin/Held",
            "investigations/741-no-pin/held-statements.json",
            "investigations/741-no-pin/held-mutants.json",
            "investigations/741-no-pin/held-corpus.json",
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.splitlines()
    require(len(paths) > 3, "historical held extent empty")
    for path in paths:
        original = subprocess.run(
            ["git", "show", historical_base + ":" + path],
            capture_output=True,
            check=True,
        ).stdout
        relative = path.removeprefix("investigations/741-no-pin/")
        require(
            (ROOT / relative).read_bytes() == original,
            "historical held row changed: " + path,
        )
    repair_base = "37d90cf0385fbc31fb996099fe117c2acc355ff9"

    def original_json(name):
        return json.loads(
            subprocess.run(
                ["git", "show", repair_base + ":investigations/741-no-pin/" + name],
                capture_output=True,
                check=True,
                text=True,
            ).stdout
        )

    current_ledger = json.loads(
        (ROOT / "application-requests-statements.json").read_text()
    )
    original_rows = original_json("application-requests-statements.json")["statements"]
    current_rows = {row["theorem"]: row for row in current_ledger["statements"]}
    for row in original_rows:
        require(
            current_rows.get(row["theorem"]) == row,
            "earlier application-request row changed: " + row["theorem"],
        )
    old_mutants = original_json("application-requests-mutants.json")["mutants"]
    current_mutants = json.loads(
        (ROOT / "application-requests-mutants.json").read_text()
    )["mutants"]
    require(
        all(row in current_mutants for row in old_mutants),
        "earlier application-request mutant changed",
    )
    old_corpus = original_json("application-requests-corpus.json")
    current_corpus = json.loads((ROOT / "application-requests-corpus.json").read_text())
    require(
        current_corpus[: len(old_corpus)] == old_corpus,
        "earlier application-request replay changed",
    )
    supersessions = current_ledger.get("supersessions", [])
    require(len(supersessions) > 0, "missing explicit supersession map")
    for row in supersessions:
        require(
            row["prior"] in {r["theorem"] for r in original_rows}
            and row["replacement"] in current_rows,
            "unbound supersession",
        )
    subprocess.run([sys.executable, str(ROOT / "effect_controls.py")], check=True)
    source_cases = [r["sourceChanges"] for r in records if "sourceChanges" in r]
    require(
        source_cases == [["register", "terminate"]],
        "uncovered source change constructor",
    )
    check_family(
        [r for r in records if r.get("family") == "application-requests"],
        "NoPin.ApplicationRequests",
        "application-requests-",
        "application-requests",
    )
    import history_check

    history_check.check(records)
    import lifecycle_check

    lifecycle_check.check(records)


if __name__ == "__main__":
    try:
        main()
    except (
        ValueError,
        KeyError,
        TypeError,
        OSError,
        json.JSONDecodeError,
        subprocess.SubprocessError,
    ) as error:
        sys.exit(f"no-pin evidence: {error}")
