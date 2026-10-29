#!/usr/bin/env python3
"""Observe registration in the independent creator's registry from chain data.

This is packaged-command development-network evidence, not a Lean comparison.
The creation receipt selects the registry; amounts, datums and token movements
are read from included transactions. Controls alter those real observations.
"""

import copy
import json
import sys
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def one(items, message):
    require(len(items) == 1, message)
    return items[0]


def observe(transactions, creation, registry):
    policy, name = registry.split(".")
    identity = {"constructor": 0, "fields": [{"bytes": policy}, {"bytes": name}]}
    state_asset = {"policy": policy, "name": name, "quantity": 1}
    state = one(
        [o for o in creation["outputs"] if state_asset in o["assets"]],
        "creation has no unique state output for this registry",
    )
    require(state_asset in creation["mint"], "creation did not mint its state token")
    pending_pairs = [
        (tx, o)
        for tx in transactions
        for o in tx["outputs"]
        if isinstance(o["datum"], dict)
        and o["datum"].get("constructor") == 1
        and o["datum"]["fields"][0]["fields"][0] == identity
    ]
    booking, pending = one(
        pending_pairs, "this registry has no unique booked registration"
    )
    fields = pending["datum"]["fields"][0]["fields"]
    key, controller, initial, deposit = (
        fields[1],
        fields[2]["bytes"],
        fields[5],
        fields[6]["int"],
    )
    require(deposit > 0, "registration declares no positive deposit")
    require(booking["signers"] == [controller], "the controller did not book alone")
    approval = one(pending["assets"], "booking has no unique approval")
    require(
        approval["quantity"] == 1 and booking["mint"] == [approval],
        "booking did not mint its approval",
    )
    fold = one(
        [
            tx
            for tx in transactions
            if any(i["ref"] == pending["ref"] for i in tx["inputs"])
        ],
        "the booked registration has no unique fold",
    )
    require(
        len(fold["signers"]) == 1
        and not set(fold["signers"]) & set(booking["signers"] + creation["signers"]),
        "the folder is not independent of the creator and booker",
    )
    require(not fold["requiredSigners"], "the fold requires a private signer")
    states_in = [i for i in fold["inputs"] if state_asset in i["assets"]]
    require(
        len(states_in) == 1 and states_in[0] == state,
        "the fold does not spend this registry's own state",
    )
    continued = one(
        [o for o in fold["outputs"] if state_asset in o["assets"]],
        "the fold does not continue this registry",
    )
    require(
        continued["credential"] == state["credential"]
        and continued["assets"] == state["assets"]
        and continued["lovelace"] == state["lovelace"]
        and continued["datum"]["constructor"] == state["datum"]["constructor"] == 0
        and continued["datum"] != state["datum"],
        "the fold does not transition this registry's state root",
    )
    holding = one(
        [o for o in fold["outputs"] if o["datum"] == initial],
        "the fold does not deliver the booked initial datum",
    )
    control = initial["fields"][0]["fields"]
    require(
        initial["constructor"] == 2 and control[0] == identity and control[2] == key,
        "the holding belongs to another registry or key",
    )
    require(
        control[3] == {"bytes": controller} and control[4] == {"int": deposit},
        "the holding loses protected control",
    )
    active = {
        "policy": control[1]["fields"][0]["bytes"],
        "name": control[1]["fields"][1]["bytes"],
        "quantity": 1,
    }
    require(
        active["policy"] == policy
        and active["name"] != name
        and holding["assets"] == [active],
        "the holding lacks the key's unique token",
    )
    require(
        holding["credential"] == pending["credential"],
        "the holding leaves the committed application",
    )
    require(holding["lovelace"] == deposit, "the holding lacks the exact deposit")
    require(
        sorted(fold["mint"], key=lambda a: (a["policy"], a["name"]))
        == sorted(
            [active, dict(approval, quantity=-1)],
            key=lambda a: (a["policy"], a["name"]),
        ),
        "the fold does not mint the key token and burn the approval",
    )
    return {
        "registry": registry,
        "creation": creation["id"],
        "booking": booking["id"],
        "pending": pending["ref"],
        "fold": fold["id"],
        "stateBefore": state["ref"],
        "stateAfter": continued["ref"],
        "rootBefore": state["datum"],
        "rootAfter": continued["datum"],
        "holding": holding["ref"],
        "activeToken": active,
        "approval": approval,
        "deposit": deposit,
        "payload": initial["fields"][1],
    }


def main():
    work = Path(sys.argv[1])
    creation = json.loads((work / "chain/independent-create.tx.json").read_text())
    registry = json.loads((work / "receipts/create-independent.json").read_text())[
        "stateToken"
    ]
    transactions = json.loads((work / "chain/all-transactions.json").read_text())[
        "transactions"
    ]
    result = observe(transactions, creation, registry)
    controls = []
    for name, reason in [
        ("another registry's state", "own state"),
        ("holding without its deposit", "exact deposit"),
    ]:
        altered = copy.deepcopy(transactions)
        fold = next(tx for tx in altered if tx["id"] == result["fold"])
        if name == "another registry's state":
            original_state = next(
                i for i in fold["inputs"] if i["ref"] == result["stateBefore"]
            )
            first_creation = json.loads(
                (work / "chain/first-create.tx.json").read_text()
            )
            other = one(
                [
                    o
                    for o in first_creation["outputs"]
                    if o["credential"] == original_state["credential"]
                    and o["datum"] == result["rootBefore"]
                    and o["assets"] != original_state["assets"]
                ],
                "control needs another registry's initial state",
            )
            index = next(
                i
                for i, item in enumerate(fold["inputs"])
                if item["ref"] == result["stateBefore"]
            )
            fold["inputs"][index] = other
        else:
            next(o for o in fold["outputs"] if o["ref"] == result["holding"])[
                "lovelace"
            ] = 0
        require(altered != transactions, "control changed no observation")
        try:
            observe(altered, creation, registry)
        except ValueError as error:
            require(
                reason in str(error),
                "control refused for another reason: " + str(error),
            )
            controls.append(name)
        else:
            raise ValueError("altered observation accepted: " + name)
    result["controlsRejected"] = controls
    print(json.dumps(result))


if __name__ == "__main__":
    try:
        main()
    except ValueError as error:
        sys.exit(str(error))
