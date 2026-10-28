#!/usr/bin/env python3
"""Judge the connected holding lifecycle from independently decoded chain transactions.

The caller supplies the run directory, registry policy, registry name and key.
No command receipt supplies an expected outcome or amount. Fees and wallet
funding are separated from the termination request's value.
"""

import copy
import json
import sys
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def judge(transactions, policy, state_name, key):
    def state(output):
        return any(
            asset["policy"] == policy and asset["name"] == state_name
            for asset in output["assets"]
        )

    def live(output):
        datum = output["datum"]
        return (
            isinstance(datum, dict)
            and datum.get("constructor") == 2
            and datum["fields"][0]["fields"][2] == {"bytes": key}
            and any(asset["policy"] == policy for asset in output["assets"])
        )

    def successor(reference):
        found = [
            tx
            for tx in transactions
            if any(i["ref"] == reference for i in tx["inputs"])
        ]
        require(len(found) == 1, "the holding lifecycle has no unique next transaction")
        return found[0]

    initial = [
        output
        for tx in transactions
        if any(a["policy"] == policy and a["quantity"] == 1 for a in tx["mint"])
        for output in tx["outputs"]
        if live(output)
    ]
    require(len(initial) == 1, "registration delivered no unique live holding")
    before = initial[0]
    update = successor(before["ref"])
    updated = [o for o in update["outputs"] if live(o)]
    require(len(updated) == 1, "the update recreates no unique holding")
    after = updated[0]
    control = before["datum"]["fields"][0]
    deposit = control["fields"][4]["int"]
    controller = control["fields"][3]["bytes"]
    require(
        after["datum"]["fields"][0] == control, "the update changes protected control"
    )
    require(after["assets"] == before["assets"], "the update changes tokens")
    require(after["address"] == before["address"], "the update moves the holding")
    require(after["lovelace"] >= deposit, "the update loses the deposit")
    require(
        after["datum"]["fields"][1] != before["datum"]["fields"][1],
        "the payload never changes",
    )
    require(
        update["signers"] == [controller],
        "the controller did not sign the update alone",
    )
    require(
        not update["mint"] and not any(state(i) for i in update["inputs"]),
        "the update folds the registry",
    )
    require(update["donation"] == 0, "the update donates money")

    booking = successor(after["ref"])
    require(
        booking["signers"] == [controller],
        "the controller did not sign termination booking alone",
    )
    require(
        booking["donation"] == deposit,
        "the deposit does not reach the treasury at booking",
    )
    require(
        not any(state(i) for i in booking["inputs"]),
        "termination booking spends the registry",
    )
    active = before["assets"][0]
    requests = [o for o in booking["outputs"] if active in o["assets"]]
    require(len(requests) == 1, "booking creates no unique termination request")
    pending = requests[0]
    require(
        pending["address"] == before["address"] and pending["datum"] is None,
        "the request is not datumless at the application",
    )
    require(len(pending["assets"]) == 2, "the request does not hold exactly two tokens")
    approvals = [a for a in pending["assets"] if a != active]
    require(
        len(approvals) == 1 and approvals[0]["quantity"] == 1,
        "the request holds no single approval",
    )
    require(booking["mint"] == approvals, "booking does not mint exactly the approval")

    fold = successor(pending["ref"])
    require(
        len(fold["signers"]) == 1 and controller not in fold["signers"],
        "the controller signs the termination fold",
    )
    require(not fold["requiredSigners"], "the termination fold requires a signer")
    require(fold["donation"] == 0, "the fold pays the treasury again")
    require(
        sorted(fold["mint"], key=lambda a: a["policy"])
        == sorted(
            [dict(a, quantity=-1) for a in pending["assets"]], key=lambda a: a["policy"]
        ),
        "the fold does not burn exactly the active token and approval",
    )
    states_in = [i for i in fold["inputs"] if state(i)]
    states_out = [o for o in fold["outputs"] if state(o)]
    require(
        len(states_in) == len(states_out) == 1,
        "the fold does not continue one registry",
    )
    require(
        states_in[0]["assets"] == states_out[0]["assets"]
        and states_in[0]["lovelace"] == states_out[0]["lovelace"],
        "the fold changes the state value",
    )
    require(
        states_in[0]["datum"] != states_out[0]["datum"],
        "termination leaves the state root unchanged",
    )
    wallet = {"type": "key", "hash": fold["signers"][0]}
    ordinary = [
        i
        for i in fold["inputs"]
        if i["ref"] not in (pending["ref"], states_in[0]["ref"])
    ]
    require(
        ordinary
        and all(i["credential"] == wallet and not i["assets"] for i in ordinary),
        "the fold has non-folder ordinary funding",
    )
    paid = [o for o in fold["outputs"] if not state(o)]
    require(
        paid and all(o["credential"] == wallet and not o["assets"] for o in paid),
        "the request value escapes the folder",
    )
    require(
        sum(o["lovelace"] for o in paid) + fold["fee"]
        == sum(i["lovelace"] for i in ordinary) + pending["lovelace"],
        "the folder does not receive the whole request value after its fee",
    )
    return {
        "update": update["id"],
        "booking": booking["id"],
        "fold": fold["id"],
        "deposit": deposit,
        "requestValue": pending["lovelace"],
        "folder": wallet["hash"],
        "fee": fold["fee"],
    }


def main():
    directory, policy, state_name, key = sys.argv[1:]
    transactions = [
        json.loads(path.read_text()) for path in Path(directory).glob("*.tx.json")
    ]
    # A transaction may have been observed under more than one name.
    unique = {tx["id"]: tx for tx in transactions}
    try:
        observed = list(unique.values())
        result = judge(observed, policy, state_name, key)
        controls = []
        # Each control changes an actual observation, rather than inventing a
        # successful fixture. Check both application and economic boundaries.
        changes = [
            ("update signature", "update", "signers", [], "controller did not sign"),
            ("booking treasury", "booking", "donation", 0, "treasury at booking"),
            ("fold burn", "fold", "mint", [], "burn exactly"),
            ("fold treasury", "fold", "donation", 1, "treasury again"),
            (
                "fold authorization",
                "fold",
                "requiredSigners",
                [result["folder"]],
                "requires a signer",
            ),
        ]
        for name, stage, field, value, reason in changes:
            altered = copy.deepcopy(observed)
            selected = next(tx for tx in altered if tx["id"] == result[stage])
            selected[field] = value
            require(altered != observed, "a control did not alter its observation")
            try:
                judge(altered, policy, state_name, key)
            except ValueError as error:
                require(reason in str(error), "a control failed for another reason")
                controls.append(name)
            else:
                raise ValueError("altered observation accepted: " + name)
        altered = copy.deepcopy(observed)
        folded = next(tx for tx in altered if tx["id"] == result["fold"])
        payment = next(o for o in folded["outputs"] if o["credential"]["type"] == "key")
        payment["lovelace"] -= 1
        require(altered != observed, "the payment control changed nothing")
        try:
            judge(altered, policy, state_name, key)
        except ValueError as error:
            require(
                "whole request value" in str(error),
                "payment control failed for another reason",
            )
            controls.append("whole request value")
        else:
            raise ValueError("a short folder payment was accepted")
        result["controlsRejected"] = controls
        print(json.dumps(result))
    except ValueError as error:
        sys.exit(str(error))


if __name__ == "__main__":
    main()
