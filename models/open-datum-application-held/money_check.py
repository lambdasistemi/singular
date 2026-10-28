"""Check the frozen money statements and their constructor/projection closures."""

import json
from check import PROJECT, STANDARD, digest, require


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def compact(record):
    return {
        key: digest(record[key].encode()) if record[key] is not None else None
        for key in ("type", "value", "alphaType", "alphaValue")
    } | {"members": sorted(record["members"])}


def closure(records):
    require(records, "empty money definition closure")
    result = {record["name"]: compact(record) for record in records}
    require(len(result) == len(records), "money inverse namespace map is not injective")
    return result


def classification(before, after):
    changed = sorted(
        name
        for name in before.keys() | after.keys()
        if name not in before
        or name not in after
        or not (
            all(
                before[name][key] == after[name][key]
                for key in ("type", "value", "members")
            )
            or all(
                before[name][key] == after[name][key]
                for key in ("alphaType", "alphaValue", "members")
            )
        )
    )
    return ("restated" if changed else "verbatim"), changed


def preflight():
    record = json.loads((PROJECT / "money-correspondence.json").read_text())
    ledger_bytes = (PROJECT / "investigation-money-statements.json").read_bytes()
    require(
        digest(ledger_bytes) == record["ledgerSha256"],
        "money investigation ledger changed",
    )
    ledger = {
        row["theorem"]: row
        for row in json.loads(ledger_bytes)["statements"]
        if row["status"] == "PROVED"
    }
    rows = record["statements"]
    require(len(rows) == len(ledger) == 12, "expected twelve money statements")
    require(
        {row["investigationName"] for row in rows} == set(ledger),
        "money source extent differs",
    )
    require(len({row["name"] for row in rows}) == 12, "duplicate money statement")
    for row in rows:
        names = row["investigationClosure"]
        require(
            names and len(names) == len(set(names)),
            "empty or duplicate money source closure",
        )
        require(
            set(names) <= record["investigationConstants"].keys(),
            "missing money source constant",
        )
        row["investigationClosure"] = {
            name: record["investigationConstants"][name] for name in names
        }
        require(
            row["name"]
            == row["investigationName"].replace(
                "NoPin.ApplicationRequests.", "OpenDatumApplicationHeld.", 1
            ),
            "wrong money rename",
        )
        require(
            row["statementSha256"]
            == ledger[row["investigationName"]]["statementSha256"],
            "money ledger digest differs",
        )
        require(
            digest(row["investigationType"].encode()) == row["statementSha256"],
            "money recorded type digest differs",
        )
        require(
            digest(canonical(row["investigationClosure"]))
            == row["investigationClosureSha256"],
            "money source closure digest differs",
        )
    return rows


def compiled(records, statement_stage=False):
    rows = preflight()
    observed = {
        record["moneyStatement"]: record
        for record in records
        if "moneyStatement" in record
    }
    require(
        len(observed) == len([r for r in records if "moneyStatement" in r]) == 12,
        "compiled money extent differs",
    )
    require(
        set(observed) == {row["name"] for row in rows}, "compiled money names differ"
    )
    for row in rows:
        actual = observed[row["name"]]
        require(
            actual["type"] == row["investigationType"],
            "compiled money statement differs: " + row["name"],
        )
        require(
            digest(actual["compiledType"].encode()) == row["compiledTypeSha256"],
            "frozen money type changed: " + row["name"],
        )
        current = closure(actual["closure"])
        require(
            digest(canonical(current)) == row["walkedClosureSha256"],
            "frozen money closure changed: " + row["name"],
        )
        label, changed = classification(row["investigationClosure"], current)
        require(
            label == row["classification"] and changed == row["changedConstants"],
            "money closure classification differs: " + row["name"],
        )
        permitted = STANDARD | ({"sorryAx"} if statement_stage else set())
        require(
            set(actual["axioms"]) <= permitted, "untrusted money axioms: " + row["name"]
        )
    print(
        f"PASS twelve frozen money types and walked closures; stage={'statements (proof debt retained)' if statement_stage else 'proofs'}"
    )


def evidence(report):
    records = [
        json.loads(line)
        for line in report.read_text().splitlines()
        if line.startswith("{")
    ]
    rows = preflight()
    require(
        len(records) == 12
        and {r["moneyEvidence"] for r in records} == {r["name"] for r in rows},
        "money certificate extent differs",
    )
    for row in records:
        certificates = row["certificates"]
        require(len(certificates) == 3, "incomplete money certificate triple")
        require(
            {c["name"] for c in certificates}
            == {
                row["moneyEvidence"].replace(".Statements.", ".Evidence.") + suffix
                for suffix in ("_antecedent", "_positive", "_mutant")
            },
            "money certificate names differ",
        )
        for certificate in certificates:
            require(
                set(certificate["axioms"]) <= STANDARD,
                "untrusted money certificate: " + certificate["name"],
            )
    print(
        "PASS twelve compiled complete-antecedent, positive and single-site mutant certificate triples"
    )
