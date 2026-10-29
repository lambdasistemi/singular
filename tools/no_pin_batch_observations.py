#!/usr/bin/env python3
"""Judge public mixed batches from the independently decoded chain.

Command receipts supply only statements to compare with chain facts. They
never supply a transaction outcome, request amount, fee or expected gain.
Every verdict predicate is also run on altered observations and must refuse.
"""

import copy
import json
import sys
from collections import Counter
from pathlib import Path


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def load_context(work, prefix, policy, application, duplicate):
    def load(directory, name):
        return json.loads((work / directory / name).read_text())

    stages = [
        "create",
        "other-create",
        "seed-fold",
        "terminate",
        "first",
        "rest",
        "foreign",
    ]
    return {
        "prefix": prefix,
        "policy": policy,
        "application": application,
        "duplicate": duplicate,
        "tx": {stage: load("chain", f"{prefix}-{stage}.tx.json") for stage in stages},
        "views": {
            stage: load("chain", f"{prefix}-{stage}.unspent.json")
            for stage in ["before", "after-first", "after-rest", "after-foreign"]
        },
        "reports": {
            stage: load("receipts", f"{prefix}-{stage}.json")
            for stage in ["first", "rest", "foreign"]
        },
        "argv": {
            stage: load("invocations", f"{prefix}-{stage}.json")
            for stage in ["first", "rest", "foreign"]
        },
        "listings": {
            stage: (work / "listings" / f"{prefix}-{stage}-before.txt")
            .read_text()
            .splitlines()
            for stage in ["first", "rest", "foreign"]
        },
    }


def identity(context, other=False):
    stage = "other-create" if other else "create"
    assets = [
        a
        for a in context["tx"][stage]["mint"]
        if a["policy"] == context["policy"] and a["quantity"] == 1
    ]
    require(len(assets) == 1, "setup: creation has no unique registry identity")
    return assets[0]["policy"], assets[0]["name"]


def holds(output, asset):
    return any(
        (a["policy"], a["name"]) == asset and a["quantity"] == 1
        for a in output["assets"]
    )


def registration(output):
    datum = output["datum"]
    if not isinstance(datum, dict) or datum.get("constructor") != 1:
        return None
    fields = datum["fields"][0]["fields"]
    registry = tuple(field["bytes"] for field in fields[0]["fields"])
    return {
        "output": output,
        "registry": registry,
        "key": fields[1]["bytes"],
        "controller": fields[2]["bytes"],
        "initial": fields[5],
        "deposit": fields[6]["int"],
        "take": output["lovelace"] - fields[6]["int"],
        "kind": "registration",
    }


def request_holders(context):
    return [
        o
        for o in context["views"]["before"]["outputs"]
        if any(a["policy"] == context["application"] for a in o["assets"])
    ]


def termination(context):
    candidates = [
        o
        for o in context["tx"]["terminate"]["outputs"]
        if o["credential"] == {"type": "script", "hash": context["application"]}
        and o["datum"] is None
    ]
    require(len(candidates) == 1, "setup: no unique reached termination request")
    output = candidates[0]
    return {
        "output": output,
        "key": "batch-terminal".encode().hex(),
        "take": output["lovelace"],
        "deposit": 0,
        "kind": "termination",
    }


def pool(context):
    registrations = [
        r
        for o in request_holders(context)
        if (r := registration(o)) and r["registry"] == identity(context)
    ]
    return registrations + [termination(context)]


def ordered(context):
    result, seen = [], set()
    for request in sorted(
        pool(context), key=lambda r: (-r["take"], r["output"]["ref"])
    ):
        if request["key"] not in seen:
            result.append(request)
            seen.add(request["key"])
    return result


def references(outputs):
    return {o["ref"] for o in outputs}


def state_pair(context, stage):
    tx = context["tx"][stage]
    before = [o for o in tx["inputs"] if holds(o, identity(context))]
    after = [o for o in tx["outputs"] if holds(o, identity(context))]
    require(len(before) == len(after) == 1, "state: one registry must continue")
    return before[0], after[0]


def judge_nonbooker(context):
    first = context["tx"]["first"]
    selected = references(first["inputs"])
    registration_count = sum(
        r["kind"] == "registration" and r["output"]["ref"] in selected
        for r in pool(context)
    )
    require(
        registration_count == 3,
        "nonbooker: three registrations must be included together",
    )
    term = termination(context)
    require(
        term["output"]["ref"] in selected,
        "nonbooker: the same transaction must include termination",
    )
    seed = [
        o
        for o in context["tx"]["seed-fold"]["outputs"]
        if isinstance(o["datum"], dict) and o["datum"].get("constructor") == 2
    ]
    require(
        len(seed) == 1
        and seed[0]["ref"] in references(context["tx"]["terminate"]["inputs"]),
        "nonbooker: termination must follow a real registered holding",
    )
    bookers = {
        r["controller"] for r in pool(context) if r["kind"] == "registration"
    } | set(context["tx"]["terminate"]["signers"])
    for stage in ["first", "rest", "foreign"]:
        actor = context["prefix"] + "-" + stage
        require(
            context["listings"][stage]
            == sorted([f"cwd/{actor}.skey", "cwd/plutus.json"]),
            "nonbooker: fresh directories must contain only the folder key and release",
        )
        args = context["argv"][stage]
        require(
            args[1] == "fold" and "--pending" not in args,
            "nonbooker: packaged fold must discover without named requests",
        )
        require(
            args[args.index("--wallet-skey") + 1] == actor + ".skey",
            "nonbooker: the folder must use its own key",
        )
        wanted = identity(context, other=stage == "foreign")
        require(
            args[args.index("--state-token") + 1] == ".".join(wanted),
            "nonbooker: command registry must equal its included creation",
        )
        signers = context["tx"][stage]["signers"]
        require(
            len(signers) == 1 and not (set(signers) & bookers),
            "nonbooker: no booker may sign the fold",
        )
    return {
        "transaction": first["id"],
        "registrations": registration_count,
        "terminations": int(term["output"]["ref"] in selected),
        "folder": first["signers"][0],
    }


def judge_state(context):
    for stage in ["first", "rest"]:
        before, after = state_pair(context, stage)
        require(
            before["assets"] == after["assets"]
            and before["lovelace"] == after["lovelace"],
            "state: the continuing state value must be preserved",
        )
        require(
            before["datum"] != after["datum"], "state: a real fold must change the root"
        )
    return {
        "registry": ".".join(identity(context)),
        "folds": [context["tx"][stage]["id"] for stage in ["first", "rest"]],
    }


def judge_limit(context):
    candidates = ordered(context)
    require(
        len(candidates) == 5, "limit: the observed pool must have five foldable keys"
    )
    first_refs = references(context["tx"]["first"]["inputs"])
    require(
        {r["output"]["ref"] for r in candidates[:4]} <= first_refs
        and candidates[4]["output"]["ref"] not in first_refs,
        "limit: the four greatest takes must be consumed first",
    )
    args = context["argv"]["first"]
    require(
        args[args.index("--limit") + 1] == "4",
        "limit: the cap must be passed to the packaged command",
    )
    for stage, chosen, left in [
        ("first", candidates[:4], 1),
        ("rest", candidates[4:], 0),
    ]:
        report = context["reports"][stage]
        require(
            report["left"] == left,
            "limit: the reported remainder must equal the chain's unconsumed foldable requests",
        )
        wanted = [
            {"pending": r["output"]["ref"], "key": r["key"], "kind": r["kind"]}
            for r in chosen
        ]
        require(
            report["folded"] == wanted,
            "limit: the reported folded order must match chain-derived take order",
        )
        require(
            {r["output"]["ref"] for r in chosen}
            <= references(context["tx"][stage]["inputs"]),
            "limit: every reported fold must actually be consumed",
        )
    remaining = candidates[4]["output"]["ref"]
    require(
        remaining in references(context["views"]["after-first"]["outputs"])
        and remaining not in references(context["views"]["after-rest"]["outputs"]),
        "limit: the second fold must consume the request left by the first",
    )
    return {
        "ordered": [
            {"reference": r["output"]["ref"], "kind": r["kind"], "take": r["take"]}
            for r in candidates
        ],
        "firstCount": sum(r["output"]["ref"] in first_refs for r in candidates),
        "leftAfterFirst": sum(
            r["output"]["ref"] in references(context["views"]["after-first"]["outputs"])
            for r in candidates
        ),
        "leftAfterSecond": sum(
            r["output"]["ref"] in references(context["views"]["after-rest"]["outputs"])
            for r in candidates
        ),
    }


def judge_economics(context):
    observed = []
    for stage, chosen in [
        ("first", ordered(context)[:4]),
        ("rest", ordered(context)[4:]),
    ]:
        tx = context["tx"][stage]
        state_in, state_out = state_pair(context, stage)
        consumed = {state_in["ref"]} | {r["output"]["ref"] for r in chosen}
        ordinary = [o for o in tx["inputs"] if o["ref"] not in consumed]
        wallet = {"type": "key", "hash": tx["signers"][0]}
        require(
            ordinary
            and all(o["credential"] == wallet and not o["assets"] for o in ordinary),
            "economics: ordinary inputs must belong to the folder alone",
        )
        delivered = set()
        minted = Counter()
        for request in chosen:
            for asset in request["output"]["assets"]:
                if (
                    asset["policy"] == context["application"]
                    or request["kind"] == "termination"
                ):
                    minted[(asset["policy"], asset["name"])] -= asset["quantity"]
            if request["kind"] == "registration":
                control = request["initial"]["fields"][0]["fields"]
                active = control[1]["fields"]
                expected_asset = {
                    "policy": active[0]["bytes"],
                    "name": active[1]["bytes"],
                    "quantity": 1,
                }
                holding = [o for o in tx["outputs"] if o["datum"] == request["initial"]]
                require(
                    len(holding) == 1
                    and holding[0]["assets"] == [expected_asset]
                    and holding[0]["credential"]
                    == {"type": "script", "hash": context["application"]}
                    and holding[0]["lovelace"] == request["deposit"],
                    "economics: each registration must deliver its committed token, datum and deposit",
                )
                delivered.add(holding[0]["ref"])
                minted[(expected_asset["policy"], expected_asset["name"])] += 1
        actual_mint = Counter(
            {(a["policy"], a["name"]): a["quantity"] for a in tx["mint"]}
        )
        require(
            dict(actual_mint) == {a: q for a, q in minted.items() if q},
            "economics: mint must be exactly the registration active tokens and request/termination burns",
        )
        paid = [
            o for o in tx["outputs"] if o["ref"] not in delivered | {state_out["ref"]}
        ]
        require(
            paid and all(o["credential"] == wallet and not o["assets"] for o in paid),
            "economics: all residual value must go to the folder",
        )
        gain = sum(o["lovelace"] for o in paid) - sum(i["lovelace"] for i in ordinary)
        takes = sum(r["take"] for r in chosen)
        require(
            gain == takes - tx["fee"],
            "economics: folder gain must equal chain request takes minus the chain fee",
        )
        observed.append(
            {
                "transaction": tx["id"],
                "registrationSurplus": sum(
                    r["take"] for r in chosen if r["kind"] == "registration"
                ),
                "terminationValue": sum(
                    r["take"] for r in chosen if r["kind"] == "termination"
                ),
                "fee": tx["fee"],
                "folderGain": gain,
            }
        )
    return observed


def skip_map(report):
    rows = report["skipped"]
    require(
        len({r["reference"] for r in rows}) == len(rows),
        "accounting: a skipped holder is repeated",
    )
    return {r["reference"]: r["reason"] for r in rows}


def judge_configuration(context):
    configs = [
        o
        for o in request_holders(context)
        if isinstance(o["datum"], dict) and o["datum"].get("constructor") == 0
    ]
    require(
        configs,
        "configuration: a real non-request configuration holder must be present",
    )
    for stage in ["first", "rest"]:
        skipped = skip_map(context["reports"][stage])
        after = {o["ref"]: o for o in context["views"]["after-" + stage]["outputs"]}
        require(
            all(
                skipped.get(o["ref"]) == "not accepted by the application's decode"
                for o in configs
            ),
            "configuration: every actual configuration holder must be named as undecodable",
        )
        require(
            all(after.get(o["ref"]) == o for o in configs),
            "configuration: skipped configuration holders must remain unspent and unchanged",
        )
    return {
        "references": [o["ref"] for o in configs],
        "unitOnly": ["approval held at a key address", "malformed request datum"],
    }


def judge_foreign(context):
    foreign = [
        r
        for o in request_holders(context)
        if (r := registration(o)) and r["registry"] == identity(context, other=True)
    ]
    require(
        len(foreign) == 1,
        "foreign: one other-registry request must coexist at the same application",
    )
    output = foreign[0]["output"]
    require(
        output["credential"] == {"type": "script", "hash": context["application"]},
        "foreign: the foreign request must share the application address",
    )
    for stage in ["first", "rest"]:
        require(
            skip_map(context["reports"][stage]).get(output["ref"])
            == "a request of another registry",
            "foreign: the other-registry request must be named with its reason",
        )
        require(
            output in context["views"]["after-" + stage]["outputs"],
            "foreign: the skipped request must remain unspent and unchanged",
        )
    require(
        output["ref"] in references(context["tx"]["foreign"]["inputs"])
        and output["ref"]
        not in references(context["views"]["after-foreign"]["outputs"]),
        "foreign: its own registry must fold the previously skipped request later",
    )
    return {
        "reference": output["ref"],
        "ownRegistryFold": context["tx"]["foreign"]["id"],
    }


def judge_duplicate(context):
    requests = sorted(pool(context), key=lambda r: (-r["take"], r["output"]["ref"]))
    kept, duplicates = {}, []
    for request in requests:
        if request["key"] in kept:
            duplicates.append(request)
        else:
            kept[request["key"]] = request
    require(
        len(duplicates) == int(context["duplicate"]),
        "duplicate: the control and attempt must differ by exactly one later same-key request",
    )
    for request in duplicates:
        ref = request["output"]["ref"]
        reason = skip_map(context["reports"]["first"]).get(ref)
        require(
            reason
            == "another foldable request has already taken the key " + request["key"],
            "duplicate: the lower-take duplicate must be named with its cause",
        )
        require(
            kept[request["key"]]["output"]["ref"]
            in references(context["tx"]["first"]["inputs"]),
            "duplicate: the earlier foldable request must be consumed",
        )
        for stage in ["first", "rest"]:
            require(
                ref not in references(context["tx"][stage]["inputs"])
                and request["output"] in context["views"]["after-" + stage]["outputs"],
                "duplicate: the skipped duplicate must remain pending, never folded",
            )
    return {
        "skipped": [r["output"]["ref"] for r in duplicates],
        "controlWithoutDuplicate": not duplicates,
    }


def judge_accounting(context):
    holders = references(request_holders(context))
    candidates = ordered(context)
    folded = {r["output"]["ref"] for r in candidates[:4]}
    left = {r["output"]["ref"] for r in candidates[4:]}
    skipped = set(skip_map(context["reports"]["first"]))
    require(
        not (folded & skipped or left & skipped or folded & left),
        "accounting: folded, skipped and left must be disjoint",
    )
    require(
        folded | skipped | left == holders,
        "accounting: every policy holder must be accounted for",
    )
    return {
        "policyHolders": len(holders),
        "folded": len(folded),
        "skipped": len(skipped),
        "left": len(left),
    }


def logical_shape(context):
    return sorted(
        (r["key"], r["kind"], r["deposit"], r["take"]) for r in ordered(context)
    )


def judge_equivalence(contexts):
    require(
        logical_shape(contexts[0]) == logical_shape(contexts[1]),
        "equivalence: both reachable pools must have identical key/kind/deposit/take shape after removing the duplicate",
    )
    return {
        "sharedShape": logical_shape(contexts[0]),
        "differentRegistryIdentities": [identity(c) for c in contexts],
    }


def altered_control(name, predicate, original, change, family):
    altered = copy.deepcopy(original)
    change(altered)
    require(altered != original, "harness: a control altered nothing: " + name)
    try:
        predicate(altered)
    except ValueError as error:
        require(
            str(error).startswith(family + ":"),
            "harness: control failed for another reason: " + name + ": " + str(error),
        )
        return name
    raise ValueError("harness: altered observation accepted: " + name)


def main():
    work, policy, application = sys.argv[1:]
    contexts = [
        load_context(Path(work), "batch-control", policy, application, False),
        load_context(Path(work), "batch-duplicate", policy, application, True),
    ]
    predicates = [
        judge_nonbooker,
        judge_state,
        judge_limit,
        judge_economics,
        judge_configuration,
        judge_foreign,
        judge_duplicate,
        judge_accounting,
    ]
    observations = [
        {
            "scenario": c["prefix"],
            "checks": {p.__name__.removeprefix("judge_"): p(c) for p in predicates},
        }
        for c in contexts
    ]
    equivalence = judge_equivalence(contexts)
    context = contexts[1]
    controls = []
    controlled = set()

    def control(name, predicate, change, family):
        controls.append(altered_control(name, predicate, context, change, family))
        controlled.add(predicate.__name__)

    control(
        "booker signs the fold",
        judge_nonbooker,
        lambda c: c["tx"]["first"].update(signers=c["tx"]["terminate"]["signers"]),
        "nonbooker",
    )
    control(
        "booker file in fresh folder",
        judge_nonbooker,
        lambda c: c["listings"]["first"].append("home/booker-journal.jsonl"),
        "nonbooker",
    )
    control(
        "named request replaces discovery",
        judge_nonbooker,
        lambda c: c["argv"]["first"].extend(["--pending", "foreign#0"]),
        "nonbooker",
    )
    registration_ref = next(
        r["output"]["ref"] for r in ordered(context)[:4] if r["kind"] == "registration"
    )
    control(
        "only two registrations folded",
        judge_nonbooker,
        lambda c: c["tx"]["first"].update(
            inputs=[
                o for o in c["tx"]["first"]["inputs"] if o["ref"] != registration_ref
            ]
        ),
        "nonbooker",
    )
    termination_ref = termination(context)["output"]["ref"]
    control(
        "mixed batch loses termination",
        judge_nonbooker,
        lambda c: c["tx"]["first"].update(
            inputs=[
                o for o in c["tx"]["first"]["inputs"] if o["ref"] != termination_ref
            ]
        ),
        "nonbooker",
    )
    control(
        "state value changes",
        judge_state,
        lambda c: state_pair(c, "first")[1].update(
            lovelace=state_pair(c, "first")[1]["lovelace"] + 1
        ),
        "state",
    )
    control(
        "wrong reported remainder",
        judge_limit,
        lambda c: c["reports"]["first"].update(left=2),
        "limit",
    )
    control(
        "wrong reported order",
        judge_limit,
        lambda c: c["reports"]["first"]["folded"].reverse(),
        "limit",
    )
    control(
        "different count cap",
        judge_limit,
        lambda c: c["argv"]["first"].__setitem__(
            c["argv"]["first"].index("--limit") + 1, "3"
        ),
        "limit",
    )

    def wrong_prefix(c):
        chosen = ordered(c)
        c["tx"]["first"]["inputs"] = [
            o
            for o in c["tx"]["first"]["inputs"]
            if o["ref"] != chosen[0]["output"]["ref"]
        ] + [chosen[-1]["output"]]

    control("lower take replaces greatest take", judge_limit, wrong_prefix, "limit")

    def short_payment(c):
        wallet = {"type": "key", "hash": c["tx"]["first"]["signers"][0]}
        paid = next(o for o in c["tx"]["first"]["outputs"] if o["credential"] == wallet)
        paid["lovelace"] -= 1

    control(
        "folder receives one lovelace less", judge_economics, short_payment, "economics"
    )
    control(
        "chain fee differs by one lovelace",
        judge_economics,
        lambda c: c["tx"]["first"].update(fee=c["tx"]["first"]["fee"] + 1),
        "economics",
    )
    control(
        "missing mint or burn",
        judge_economics,
        lambda c: c["tx"]["first"]["mint"].pop(),
        "economics",
    )

    def short_deposit(c):
        holding = next(
            o
            for o in c["tx"]["first"]["outputs"]
            if isinstance(o["datum"], dict) and o["datum"].get("constructor") == 2
        )
        holding["lovelace"] -= 1

    control(
        "holding loses one lovelace of deposit",
        judge_economics,
        short_deposit,
        "economics",
    )

    config_ref = judge_configuration(context)["references"][0]
    control(
        "configuration omitted from skips",
        judge_configuration,
        lambda c: c["reports"]["first"].update(
            skipped=[
                r
                for r in c["reports"]["first"]["skipped"]
                if r["reference"] != config_ref
            ]
        ),
        "configuration",
    )
    control(
        "configuration spent",
        judge_configuration,
        lambda c: c["views"]["after-first"].update(
            outputs=[
                o
                for o in c["views"]["after-first"]["outputs"]
                if o["ref"] != config_ref
            ]
        ),
        "configuration",
    )
    foreign_ref = judge_foreign(context)["reference"]
    control(
        "foreign request omitted from skips",
        judge_foreign,
        lambda c: c["reports"]["first"].update(
            skipped=[
                r
                for r in c["reports"]["first"]["skipped"]
                if r["reference"] != foreign_ref
            ]
        ),
        "foreign",
    )
    control(
        "foreign request consumed too early",
        judge_foreign,
        lambda c: c["views"]["after-first"].update(
            outputs=[
                o
                for o in c["views"]["after-first"]["outputs"]
                if o["ref"] != foreign_ref
            ]
        ),
        "foreign",
    )
    control(
        "foreign request never folded",
        judge_foreign,
        lambda c: c["tx"]["foreign"].update(
            inputs=[o for o in c["tx"]["foreign"]["inputs"] if o["ref"] != foreign_ref]
        ),
        "foreign",
    )
    duplicate_ref = judge_duplicate(context)["skipped"][0]
    control(
        "duplicate loses its named cause",
        judge_duplicate,
        lambda c: next(
            r
            for r in c["reports"]["first"]["skipped"]
            if r["reference"] == duplicate_ref
        ).update(reason=""),
        "duplicate",
    )
    control(
        "duplicate incorrectly folded",
        judge_duplicate,
        lambda c: c["tx"]["first"]["inputs"].append(
            next(
                o for o in c["views"]["before"]["outputs"] if o["ref"] == duplicate_ref
            )
        ),
        "duplicate",
    )
    control(
        "policy holder disappears from accounting",
        judge_accounting,
        lambda c: c["reports"]["first"]["skipped"].pop(),
        "accounting",
    )

    def change_take(pair):
        request = next(r for r in pool(pair[1]) if r["kind"] == "registration")
        request["output"]["lovelace"] += 1

    controls.append(
        altered_control(
            "passing control has another take",
            judge_equivalence,
            contexts,
            change_take,
            "equivalence",
        )
    )
    controlled.add(judge_equivalence.__name__)
    executed = {p.__name__ for p in predicates} | {judge_equivalence.__name__}

    def coverage_guard():
        declared = {
            name
            for name, value in globals().items()
            if name.startswith("judge_") and callable(value)
        }
        require(
            declared == executed == controlled,
            "harness: every discovered verdict predicate must run on passing and altered input",
        )

    coverage_guard()
    globals()["judge_uncalled_control"] = lambda _: None
    try:
        coverage_guard()
    except ValueError:
        controls.append("uncalled verdict predicate")
    else:
        raise ValueError("harness: an uncalled verdict predicate escaped the guard")
    finally:
        del globals()["judge_uncalled_control"]
    coverage_guard()
    print(
        json.dumps(
            {
                "scenarios": observations,
                "equivalence": equivalence,
                "controlsRejected": controls,
                "harnessAppendix": {
                    "verdictPredicates": sorted(executed),
                    "predicateCount": len(executed),
                },
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, IndexError, StopIteration) as error:
        sys.exit(str(error))
