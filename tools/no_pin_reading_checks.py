#!/usr/bin/env python3
"""Judge packaged reader outputs against the journey's independent chain views.

This is development-network command evidence, separate from model comparison.
Each accepted observation is also corrupted and must be rejected by its judge.
"""

import copy
import json
from pathlib import Path
import re
import sys


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def load(path):
    return json.loads(path.read_text())


def chain_data(value):
    """Preserve data exactly across the two JSON spellings of a Plutus map."""
    if isinstance(value, list):
        return [chain_data(item) for item in value]
    if isinstance(value, dict):
        if set(value) == {"map"}:
            return {
                "map": [
                    [chain_data(pair["k"]), chain_data(pair["v"])]
                    if isinstance(pair, dict)
                    else chain_data(pair)
                    for pair in value["map"]
                ]
            }
        return {key: chain_data(item) for key, item in value.items()}
    return value


def reader_outputs(work):
    outputs = {}
    for path in (work / "receipts").glob("*.json"):
        try:
            document = load(path)
        except (ValueError, OSError):
            continue
        if document.get("command") in ("registry inspect", "inspect"):
            outputs[path.stem] = document
    require(outputs, "the job produced no packaged reader answers")
    return outputs


def altered_rejected(judge, document, field, value):
    changed = copy.deepcopy(document)
    changed[field] = value
    require(changed != document, f"control did not change {field}")
    try:
        judge(changed)
    except (AssertionError, KeyError, TypeError, ValueError):
        return
    raise AssertionError(f"the judge accepted altered {field}")


def identity_judge(document, command, registry, key, policy, application):
    require(document["command"] == command, "wrong reader command")
    require(document["registry"] == registry, "wrong registry address")
    require(document["keyHex"] == key, "wrong key")
    identity = document["application"]
    require(identity["state-policy"] == policy, "wrong state policy")
    require(identity["application-policy"] == application, "wrong application policy")
    require(identity["application-script"] == application, "wrong application script")


def journey(work):
    outputs = reader_outputs(work)
    creation = load(work / "receipts/create-first.json")
    policy, state_name = creation["stateToken"].split(".")
    blueprint = load(work / "release/plutus.json")
    application = next(
        v["hash"]
        for v in blueprint["validators"]
        if v["title"] == "open_datum_requests.open_datum_requests.spend"
    )
    fold = load(work / "chain/fold.tx.json")
    holding = next(
        o
        for o in fold["outputs"]
        if any(a["policy"] == policy and a["name"] != state_name for a in o["assets"])
    )
    control = holding["datum"]["fields"][0]["fields"]
    key = control[2]["bytes"]
    never_key = "journey-never-registered".encode().hex()
    pending = load(work / "receipts/terminate.json")["pending"]
    state_snapshot = load(work / "chain/after-termination-fold.unspent.json")
    state = next(
        o
        for o in state_snapshot["outputs"]
        if any(a["policy"] == policy and a["name"] == state_name for a in o["assets"])
    )
    cases = [
        ("read-neutral-live", "registry inspect", "active", key, holding["ref"]),
        ("read-app-live", "inspect", "live", key, holding["ref"]),
        ("read-app-pending", "inspect", "pending-termination", key, pending),
        ("read-neutral-terminal", "registry inspect", "terminal", key, None),
        ("read-app-terminal", "inspect", "terminal", key, None),
        ("read-neutral-never", "registry inspect", "never-registered", never_key, None),
        ("read-app-never", "inspect", "never-registered", never_key, None),
    ]
    results = []
    for name, command, answer, wanted_key, reference in cases:
        require(name in outputs, f"missing reader execution: {name}")
        document = outputs[name]

        def judge(value):
            identity_judge(
                value, command, creation["registry"], wanted_key, policy, application
            )
            require(value["answer"] == answer, f"{name}: wrong answer")
            if reference:
                require(
                    value["outputRef"] == reference, f"{name}: wrong custody output"
                )
            else:
                require(
                    value["stateOutput"] == state["ref"],
                    f"{name}: wrong authenticated state",
                )
                require(
                    value["root"] == state["datum"]["fields"][0]["bytes"],
                    f"{name}: wrong root",
                )
            if answer == "live":
                require(value["deposit"] == control[4]["int"], "wrong deposit")
                require(
                    value["control"]["controller"] == control[3]["bytes"],
                    "wrong controller",
                )
                require(value["control"]["keyHex"] == key, "wrong control key")
                require(
                    value["control"]["registry"] == creation["stateToken"],
                    "wrong control registry",
                )
                require(
                    chain_data(value["datum"]) == holding["datum"], "wrong live datum"
                )
                require(
                    value["payload"] == load(work / "actors/alice/cwd/payload.json"),
                    "wrong decoded payload",
                )
            elif answer == "pending-termination":
                require(
                    value["datumKind"] == "none" and value["datum"] is None,
                    "pending datum is not empty",
                )
            elif answer == "active":
                require(
                    chain_data(value["datum"]) == holding["datum"], "wrong raw datum"
                )

        judge(document)
        require(
            (work / f"receipts/{name}.status").read_text().strip() == "0",
            f"{name}: nonzero exit",
        )
        for field, wrong in [
            ("answer", "unavailable"),
            ("registry", "another registry"),
            ("keyHex", "00"),
        ]:
            altered_rejected(judge, document, field, wrong)
        altered_rejected(
            judge, document, "outputRef" if reference else "root", "altered"
        )
        if answer in ("active", "live"):
            altered_rejected(judge, document, "datum", {"constructor": 2, "fields": []})
        if answer == "live":
            altered_rejected(judge, document, "deposit", value=document["deposit"] + 1)
            altered_rejected(judge, document, "payload", {"name": "altered"})
        results.append(
            {
                "command": command,
                "keyHex": wanted_key,
                "answer": document["answer"],
                "registry": document["registry"],
                "controlsRejected": True,
            }
        )
    return {
        "readings": results,
        "boundary": "packaged commands on a development network; no model comparison",
    }


def measurement(work):
    outputs = reader_outputs(work)
    require(
        "read-neutral-measured" in outputs,
        "no known-key reader execution with other registries' holdings",
    )
    document = outputs["read-neutral-measured"]
    creation = load(work / "receipts/create-first.json")
    later = load(work / "receipts/create-later.json")
    require(
        creation["stateToken"] != later["stateToken"],
        "the second registry is not distinct",
    )
    snapshot = load(work / "chain/reading-with-other-holdings.unspent.json")
    own_policy, own_name = creation["stateToken"].split(".")
    other_policy, other_name = later["stateToken"].split(".")
    registries = [
        [{"bytes": own_policy}, {"bytes": own_name}],
        [{"bytes": other_policy}, {"bytes": other_name}],
    ]
    live = [
        o
        for o in snapshot["outputs"]
        if o["datum"] and o["datum"].get("constructor") == 2
    ]
    own = [
        o
        for o in live
        if o["datum"]["fields"][0]["fields"][0]["fields"] == registries[0]
    ]
    others = [
        o
        for o in live
        if o["datum"]["fields"][0]["fields"][0]["fields"] == registries[1]
    ]
    require(
        len(own) == 1 and len(others) > 0,
        "the two registries have no coexisting live holdings",
    )
    require(
        all(o["credential"] == own[0]["credential"] for o in others),
        "the other holdings are not at the same application address",
    )

    def judge(value):
        require(
            value["answer"] == "active" and value["registry"] == creation["registry"],
            "wrong measured answer",
        )
        require(value["outputRef"] == own[0]["ref"], "wrong measured holding")
        require(
            value["keyHex"] == own[0]["datum"]["fields"][0]["fields"][2]["bytes"],
            "wrong measured key",
        )
        reads = value["queryWork"]["reads"]
        require(
            set(reads) == {"genesis", "asset_utxos"},
            "the live lookup performed additional reads",
        )
        require(
            reads["asset_utxos"]["calls"] == 1 and reads["asset_utxos"]["rows"] == 1,
            "the lookup was not one asset query returning one row",
        )
        require(
            all(
                r["bytes"] > 0 and r["rows"] > 0 and r["calls"] > 0
                for r in reads.values()
            ),
            "unmeasured read",
        )
        require(
            value["queryWork"]["total"]
            == {
                k: sum(r[k] for r in reads.values()) for k in ("calls", "rows", "bytes")
            },
            "inaccurate totals",
        )

    judge(document)
    bad = copy.deepcopy(document["queryWork"])
    bad["reads"]["asset_utxos"]["calls"] += 1
    altered_rejected(judge, document, "queryWork", bad)
    altered_rejected(judge, document, "outputRef", others[0]["ref"])
    return {
        "registry": document["registry"],
        "keyHex": document["keyHex"],
        "otherRegistry": later["registry"],
        "otherHoldingsAtSameAddress": len(others),
        "queryWork": document["queryWork"],
        "controlsRejected": True,
    }


def refusals(work):
    outputs = reader_outputs(work)
    results = []
    for name, answer, reason, status in [
        ("wrong-network", "refused", "wrong-network", "2"),
        ("unknown-policy", "refused", "unknown-state-policy", "2"),
        ("provider-failure", "unavailable", "network", "1"),
    ]:
        attempt = outputs[f"read-{name}"]
        control = outputs[f"read-{name}-control"]

        def judge(value):
            require(value["answer"] == answer, f"{name}: wrong answer")
            require(
                value["refusal" if answer == "refused" else "read"] == reason,
                f"{name}: wrong named reason",
            )
            require(bool(value["reason"]), f"{name}: missing diagnostic")
            if name == "wrong-network":
                require(
                    re.search(
                        r"registry network 1, provider serves network 42\b",
                        value["reason"],
                    )
                    is not None,
                    "missing network identities",
                )

        judge(attempt)
        require(
            control["answer"] == "never-registered",
            f"{name}: restored control did not answer",
        )
        require(
            (work / f"receipts/read-{name}.status").read_text().strip() == status,
            f"{name}: wrong exit",
        )
        require(
            (work / f"receipts/read-{name}-control.status").read_text().strip() == "0",
            f"{name}: control failed",
        )
        altered_rejected(judge, attempt, "answer", control["answer"])
        altered_rejected(
            judge, attempt, "refusal" if answer == "refused" else "read", "altered"
        )
        results.append(
            {"attempt": attempt, "control": control, "controlsRejected": True}
        )
    return {
        "refusals": results,
        "boundary": "packaged reading commands on a development network; no model comparison",
    }


if __name__ == "__main__":
    try:
        mode, directory = sys.argv[1:]
        result = {"journey": journey, "measurement": measurement, "refusals": refusals}[
            mode
        ](Path(directory))
        print(json.dumps(result, indent=2))
    except (AssertionError, KeyError, ValueError, OSError, TypeError) as failure:
        print(f"reading evidence does not hold: {failure}", file=sys.stderr)
        sys.exit(1)
