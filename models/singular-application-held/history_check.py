"""Check the frozen history statements and their constructor/projection closures."""

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
    require(records, "empty history definition closure")
    result = {record["name"]: compact(record) for record in records}
    require(
        len(result) == len(records), "history inverse namespace map is not injective"
    )
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
    record = json.loads((PROJECT / "correspondence.json").read_text())
    ledger_bytes = (PROJECT / "investigation-history-statements.json").read_bytes()
    require(
        digest(ledger_bytes) == record["historyLedgerSha256"],
        "history investigation ledger changed",
    )
    ledger = {
        row["theorem"]: row
        for row in json.loads(ledger_bytes)["statements"]
        if row["status"] == "PROVED"
    }
    rows = [row for row in record["statements"] if ".HistoryStatements." in row["name"]]
    require(len(rows) == len(ledger) == 4, "expected four history statements")
    require(
        {row["investigationName"] for row in rows} == set(ledger),
        "history source extent differs",
    )
    require(len({row["name"] for row in rows}) == 4, "duplicate history statement")
    for row in rows:
        names = row["investigationClosure"]
        require(
            names and len(names) == len(set(names)),
            "empty or duplicate history source closure",
        )
        require(
            set(names) <= record["historyInvestigationConstants"].keys(),
            "missing history source constant",
        )
        row["investigationClosure"] = {
            name: record["historyInvestigationConstants"][name] for name in names
        }
        require(
            row["name"]
            == row["investigationName"].replace(
                "NoPin.ApplicationRequests.", "SingularApplicationHeld.", 1
            ),
            "wrong history rename",
        )
        require(
            row["statementSha256"]
            == ledger[row["investigationName"]]["statementSha256"],
            "history ledger digest differs",
        )
        require(
            digest(row["investigationType"].encode()) == row["statementSha256"],
            "history recorded type digest differs",
        )
        require(
            digest(canonical(row["investigationClosure"]))
            == row["investigationClosureSha256"],
            "history source closure digest differs",
        )
    return rows


def compiled(records, statement_stage=False):
    rows = preflight()
    observed = {
        record["historyStatement"]: record
        for record in records
        if "historyStatement" in record
    }
    require(
        len(observed) == len([r for r in records if "historyStatement" in r]) == 4,
        "compiled history extent differs",
    )
    require(
        set(observed) == {row["name"] for row in rows}, "compiled history names differ"
    )
    for row in rows:
        actual = observed[row["name"]]
        require(
            actual["type"] == row["investigationType"],
            "compiled history statement differs: " + row["name"],
        )
        require(
            digest(actual["compiledType"].encode()) == row["compiledTypeSha256"],
            "frozen history type changed: " + row["name"],
        )
        current = closure(actual["closure"])
        require(
            digest(canonical(current)) == row["walkedClosureSha256"],
            "frozen history closure changed: " + row["name"],
        )
        label, changed = classification(row["investigationClosure"], current)
        require(
            label == row["classification"] and changed == row["changedConstants"],
            "history closure classification differs: " + row["name"],
        )
        permitted = STANDARD | ({"sorryAx"} if statement_stage else set())
        require(
            set(actual["axioms"]) <= permitted,
            "untrusted history axioms: " + row["name"],
        )
    print(
        f"PASS four frozen history types and walked closures; stage={'statements (proof debt retained)' if statement_stage else 'proofs'}"
    )
