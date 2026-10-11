#!/usr/bin/env python3
"""Bind actual boot or public-lineage observations to recovery receipts.

PR411 retired mutable mirror creation/acceptance. Boot has public command
events; stored-registry operations have independently emitted TrieState events.
Neither source is populated from a receipt. Controls mutate actual observations
in memory, retaining the original inputs and every recovery assertion.
"""

import argparse
import copy
import json
import re
import sys
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def records(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines() if line]


def check(receipt, observations, identity, command_trace):
    require(
        receipt.get("outcome") == "success" and receipt.get("preview") is not True,
        "subject is not a completed nonpreview command",
    )
    command = receipt.get("command")
    require(observations, "observations are empty")
    ends = [event for event in command_trace if event.get("event") == "command-ended"]
    require(
        len(ends) == 1
        and command_trace[-1] == ends[0]
        and ends[0].get("command") == command
        and ends[0].get("outcome") == "success",
        "public trace does not complete with the receipt command/outcome",
    )
    policy, name = (receipt.get("stateToken") or identity).split(".")
    require(
        re.fullmatch(r"[0-9a-f]{56}", policy) and re.fullmatch(r"[0-9a-f]+", name),
        "receipt identity is malformed",
    )
    if command == "create":
        # Create.boot reads the real token-bearing output before emitting both
        # Created and RegistrySeen. These are boot observations, not a stored
        # trie allocation or a synthetic TrieObservation.Created.
        created = [event for event in observations if event.get("event") == "created"]
        seen = [event for event in observations if event.get("event") == "registry"]
        ended = [
            event for event in observations if event.get("event") == "command-ended"
        ]
        require(
            len(created) == 1 and len(seen) == 1,
            "boot observations are missing or ambiguous",
        )
        boot_output = receipt["boot"] + "#0"
        require(
            created[0].get("token") == name == receipt["token"], "boot token differs"
        )
        require(
            created[0].get("state") == seen[0].get("state") == boot_output,
            "observed boot output differs",
        )
        require(
            seen[0].get("root") == receipt["root"] == "0" * 64,
            "observed initial root differs",
        )
        require(seen[0].get("pending") == 0, "boot observation has pending requests")
        require(
            len(ended) == 1
            and observations[-1] == ended[0]
            and ended[0].get("command") == command
            and ended[0].get("outcome") == "success",
            "boot trace does not complete with the receipt outcome",
        )
        return
    require(
        command
        in {"insert", "update", "terminate", "fold", "reject", "reclaim", "inspect"},
        "successful command has no observation mapping",
    )
    selected = [event for event in observations if event.get("operation") == "select"]
    require(selected, "public lineage selection is missing")
    require(
        all(
            event.get("identity") == {"policy": policy, "name": name}
            for event in observations
        ),
        "capability observation belongs to another identity",
    )
    for event in selected:
        require(
            event.get("identity") == {"policy": policy, "name": name},
            "selected registry identity differs",
        )
        require(
            re.fullmatch(r"[0-9a-f]{64}#[0-9]+", event.get("output", ""))
            and re.fullmatch(r"[0-9a-f]{64}", event.get("root", "")),
            "selected output or root is malformed",
        )
    if command == "inspect":
        require(
            any(
                event.get("root") == receipt["root"]
                and any(
                    public.get("event") == "registry"
                    and public.get("root") == receipt["root"]
                    and public.get("state") == event["output"]
                    for public in command_trace
                )
                for event in selected
            ),
            "inspected output/root differs from public command read",
        )
        require(
            any(
                event.get("operation") == "leafAt"
                and event.get("key") == receipt["key"]
                and event.get("root") == receipt["root"]
                and event.get("leaf") == receipt["leaf"]
                for event in observations
            ),
            "authenticated leaf differs or is missing",
        )
    elif receipt.get("fold") is not None:
        require(
            any(
                event.get("root") == receipt["root"]
                and event.get("output") == receipt["fold"] + "#0"
                for event in selected
            ),
            "actual folded output/root was not selected",
        )
        require(
            any(
                event.get("operation") == "speculateEdges"
                and event.get("rootAfter") == receipt["root"]
                and type(event.get("proofCount")) is int
                and event["proofCount"] > 0
                and isinstance(event.get("proofs"), str)
                and event["proofs"]
                for event in observations
            ),
            "fold speculation/proofs differ or are missing",
        )
    elif receipt.get("root") is not None:
        require(
            any(event["root"] == receipt["root"] for event in selected),
            "receipt root was not selected",
        )
    if receipt.get("fold") is None:
        require(
            any(
                any(
                    public.get("event") == "registry"
                    and public.get("state") == event["output"]
                    and public.get("root") == event["root"]
                    for public in command_trace
                )
                for event in selected
            ),
            "selection differs from the public command state read",
        )


def controls(receipt, observations, identity, command_trace):
    """The same checker must reject loss or alteration of real observations."""
    command = receipt["command"]
    rejected = []
    unknown_receipt = copy.deepcopy(receipt)
    unknown_trace = copy.deepcopy(command_trace)
    unknown_receipt["command"] = "unmapped-successful-command"
    for event in unknown_trace:
        if event.get("event") == "command-ended":
            event["command"] = unknown_receipt["command"]
    try:
        check(unknown_receipt, observations, identity, unknown_trace)
    except (ValueError, KeyError, TypeError):
        rejected.append("unmapped successful command")
    else:
        raise ValueError("unmapped successful command was omitted from coverage")
    mutations = [("empty observations", lambda _: [])]

    def drop(tag, value):
        return lambda events: [event for event in events if event.get(tag) != value]

    def change(tag, value, field, replacement):
        def alter(events):
            for event in events:
                if event.get(tag) == value:
                    event[field] = replacement
            return events

        return alter

    if command == "create":
        for event in ("created", "registry", "command-ended"):
            mutations.append(("missing " + event, drop("event", event)))
        for event, field, value in (
            ("created", "token", "0" * 64),
            ("created", "state", "0" * 64 + "#0"),
            ("registry", "state", "0" * 64 + "#0"),
            ("registry", "root", "1" * 64),
            ("command-ended", "outcome", "partial"),
        ):
            mutations.append(
                ("altered " + event + "." + field, change("event", event, field, value))
            )
    else:
        mutations.append(("missing selection", drop("operation", "select")))
        for field, value in (
            ("output", "0" * 64 + "#999"),
            ("root", "1" * 64),
            ("identity", {"policy": "0" * 56, "name": "00"}),
        ):
            mutations.append(
                (
                    "altered selected " + field,
                    change("operation", "select", field, value),
                )
            )
        if command == "inspect":
            mutations.append(("missing leaf", drop("operation", "leafAt")))
            for field, value in (
                ("key", "wrong-key"),
                ("root", "1" * 64),
                ("leaf", "wrong-leaf"),
            ):
                mutations.append(
                    (
                        "altered leaf " + field,
                        change("operation", "leafAt", field, value),
                    )
                )
        elif receipt.get("fold") is not None:
            mutations.append(
                ("missing speculation", drop("operation", "speculateEdges"))
            )
            for field, value in (
                ("rootAfter", "1" * 64),
                ("proofCount", 0),
                ("proofs", None),
            ):
                mutations.append(
                    (
                        "altered speculation " + field,
                        change("operation", "speculateEdges", field, value),
                    )
                )
    for name, alter in mutations:
        changed = alter(copy.deepcopy(observations))
        require(
            changed != observations, "negative control did not alter evidence: " + name
        )
        try:
            check(receipt, changed, identity, command_trace)
        except (ValueError, KeyError, TypeError):
            rejected.append(name)
            print(
                "recovery observation control rejected: " + command + ": " + name,
                file=sys.stderr,
            )
        else:
            raise ValueError("negative control passed: " + name)
    if command != "create":
        for name, alter in (
            ("missing public registry read", drop("event", "registry")),
            ("missing command completion", drop("event", "command-ended")),
            (
                "altered command outcome",
                change("event", "command-ended", "outcome", "partial"),
            ),
        ):
            # A fold binds its output directly; other reads bind the selection
            # to the independently emitted public RegistrySeen observation.
            if (
                name == "missing public registry read"
                and receipt.get("fold") is not None
            ):
                continue
            changed = alter(copy.deepcopy(command_trace))
            require(
                changed != command_trace,
                "control did not change command trace: " + name,
            )
            try:
                check(receipt, observations, identity, changed)
            except (ValueError, KeyError, TypeError):
                rejected.append(name)
                print(
                    "recovery observation control rejected: " + command + ": " + name,
                    file=sys.stderr,
                )
            else:
                raise ValueError("command trace control passed: " + name)
    return rejected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("receipt")
    parser.add_argument("trie")
    parser.add_argument("trace")
    parser.add_argument("--controls", action="store_true")
    parser.add_argument(
        "--identity-file",
        required=True,
        help="exact state-token argument recorded by the command controller",
    )
    args = parser.parse_args()
    receipt = json.loads(Path(args.receipt).read_text())
    source = (
        "boot-command-trace"
        if receipt.get("command") == "create"
        else "public-lineage-capability"
    )
    trace = records(args.trace)
    observed = trace if receipt.get("command") == "create" else records(args.trie)
    identity = Path(args.identity_file).read_text().strip()
    check(receipt, observed, identity, trace)
    rejected = controls(receipt, observed, identity, trace) if args.controls else []
    print(
        json.dumps(
            {
                "command": receipt["command"],
                "key": receipt.get("key"),
                "root": receipt.get("root"),
                "source": source,
                "executions": len(observed),
                "negativeControlsRejected": rejected,
            }
        )
    )


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError) as error:
        print("recovery observation refused: " + str(error), file=sys.stderr)
        sys.exit(1)
