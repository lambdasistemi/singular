#!/usr/bin/env python3
"""Reconcile creation experiments with independently recorded node submissions.

This tool measures experiments, never selects a production creation strategy.
The hosted creation-cost-check invokes its receipt and alteration checks.
"""

import argparse
import copy
import hashlib
import json
import re
import runpy
import sys
from pathlib import Path

FORMS = {
    "referenced": (False, False, False),
    "witnesses": (True, True, False),
    "reference-outputs": (True, True, True),
    "state-witness": (True, False, False),
    "application-witness": (False, True, False),
}
LABELS = {
    "referenced": "Both scripts read from live reference outputs",
    "witnesses": "Both scripts carried in witnesses",
    "reference-outputs": "Both scripts carried in witnesses and new reference outputs",
    "state-witness": "State script carried; application script referenced",
    "application-witness": "Application script carried; state script referenced",
}


def require(condition, message):
    if not condition:
        raise ValueError("carrying: " + message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def script_identity(language, data):
    return hashlib.blake2b(bytes([language]) + data, digest_size=28).hexdigest()


def rebuild(receipt, directory, candidate, cost):
    source = directory / receipt["chainRecord"]
    require(
        digest(source.read_bytes()) == receipt["chainRecordSha256"],
        "chain record hash differs",
    )
    network, chain = cost["read_chain"](source)
    require(
        network["protocolParametersCborSha256"]
        == candidate["network"]["protocolParametersCborSha256"],
        "protocol parameter CBOR differs from the creation comparison",
    )
    require(
        network["protocolParameters"] == candidate["network"]["protocolParameters"],
        "protocol parameters differ from the creation comparison",
    )
    events = [json.loads(line) for line in source.read_text().splitlines()]
    submissions = [
        event
        for event in events
        if event.get("path") == "/api/v1/submittx"
        and event.get("source", {}).get("kind") == "actual-node-submission"
    ]
    require(receipt["schema"] == "creation-carrying-v1", "unknown receipt schema")
    require(
        [form["form"] for form in receipt["forms"]] == list(FORMS),
        "all five distinct forms in declared order are required",
    )
    scripts = [
        output["referenceScript"]
        for tx in candidate["first"]["transactions"]
        for output in tx["outputs"]
        if output["referenceScript"]
    ]
    require(len(scripts) == 2, "comparison must identify state and application scripts")
    expected_hashes = [script["hash"] for script in scripts]
    rebuilt = copy.deepcopy(receipt)
    rebuilt["network"] = network
    parameters = network["protocolParameters"]
    limits = {
        "transactionBytes": parameters["maxTxSize"],
        "executionMemory": parameters["maxTxExecutionUnits"]["memory"],
        "executionSteps": parameters["maxTxExecutionUnits"]["steps"],
        "feePerByteLovelace": parameters["txFeePerByte"],
        "fixedFeeLovelace": parameters["txFeeFixed"],
        "executionPrices": parameters["executionUnitPrices"],
        "referenceScriptFeePerByteLovelace": parameters["minFeeRefScriptCostPerByte"],
    }
    rebuilt["limits"] = limits
    rebuilt["scripts"] = scripts
    identities = []
    configurations = []
    for form in rebuilt["forms"]:
        attach_state, attach_application, creates = FORMS[form["form"]]
        raw = bytes.fromhex(form["signedTransactionCBOR"])
        matches = [event for event in submissions if event["requestBytes"] == raw.hex()]
        require(
            len(matches) == 1,
            "signed transaction has no unique independent node submission",
        )
        event = matches[0]
        require(
            event["source"]["transactionCBOR"] == raw.hex(), "node source bytes differ"
        )
        require(event["requestSha256"] == digest(raw), "node request hash differs")
        response_bytes = bytes.fromhex(event["responseBytes"])
        require(
            event["responseSha256"] == digest(response_bytes),
            "node response hash differs",
        )
        response = json.loads(response_bytes)
        require(
            response == event["source"]["result"],
            "node source result differs from response",
        )
        identity = event["source"]["transactionId"]
        material = {"cbor": raw.hex(), "material": {"tx_hash": identity}}
        measured = cost["measure"](material)
        identities.append(identity)
        tx, end = cost["decode"](raw)
        require(
            end == len(raw) and tx[2] is True,
            "complete script-valid transaction required",
        )
        require(
            form["protocolParameters"] == parameters,
            "form parameters differ from independently observed parameters",
        )
        mint = cost["get"](tx[0], 9)
        require(
            isinstance(mint, tuple)
            and mint[0] == "map"
            and {key.hex() for key, _ in mint[1]} == set(expected_hashes),
            "creation must mint under the two measured scripts",
        )
        attached = cost["get"](tx[1], 7) or []
        attached_hashes = {script_identity(3, script) for script in attached}
        needed_attached = {
            hash_
            for hash_, chosen in zip(
                expected_hashes, [attach_state, attach_application], strict=True
            )
            if chosen
        }
        require(
            attached_hashes == needed_attached,
            "witness scripts do not implement this form",
        )
        references = []
        for reference in measured["inputsRead"]:
            txid, _, index = reference.partition("#")
            require(txid in chain, "reference parent not observed on chain")
            output = cost["measure"](chain[txid])["outputs"][int(index)]
            if output["referenceScript"]:
                references.append(output)
        require(
            {output["referenceScript"]["hash"] for output in references}
            == set(expected_hashes) - needed_attached,
            "live references do not implement this form",
        )
        # Prove every referenced output was still live before submission. Accepted
        # forms also receive the node's own normal/reference-input checks.
        before = {}
        for observed in events[: events.index(event)]:
            if observed["kind"] != "chain-sync-full-block":
                continue
            for transaction in observed["block"]["transactions"]:
                facts = cost["measure"](transaction)
                for reference in facts["inputsSpent"]:
                    before.pop(reference, None)
                before.update(
                    (output["reference"], output) for output in facts["outputs"]
                )
        require(
            all(before.get(output["reference"]) == output for output in references),
            "a script reference was not live at submission",
        )
        published = [
            output["referenceScript"]["hash"]
            for output in measured["outputs"]
            if output["referenceScript"]
        ]
        require(
            set(published) == (set(expected_hashes) if creates else set())
            and len(published) == (2 if creates else 0),
            "created reference outputs do not implement this form",
        )
        configurations.append(cost["configuration_fields"](material))
        redeemers = cost["get"](tx[1], 5)
        require(
            isinstance(redeemers, tuple)
            and redeemers[0] == "map"
            and len(redeemers[1]) == 2,
            "both script purposes must be evaluated",
        )
        budgets = {int(key[1]): value[1] for key, value in redeemers[1] if key[0] == 1}
        require(set(budgets) == {0, 1}, "two minting purposes required")
        evaluations = form["evaluation"]
        require(len(evaluations) == 2, "both execution results required")
        for index, evaluation in enumerate(evaluations):
            require(
                evaluation["purpose"] == f"ConwayMinting (AsIx {{unAsIx = {index}}})",
                "evaluation purpose differs",
            )
            require(
                evaluation["result"]
                == dict(zip(["memory", "steps"], budgets[index], strict=True)),
                "final ledger evaluation differs from signed execution units",
            )
        memory = sum(budget[0] for budget in budgets.values())
        steps = sum(budget[1] for budget in budgets.values())
        # The complete four-field CBOR includes the one-byte validity flag.
        # The independently observed MaxTxSizeUTxO failures use the ledger count.
        ledger_bytes = len(raw) - 1
        accepted = event["status"] == 200
        stops = []
        if ledger_bytes > limits["transactionBytes"]:
            stops.append("maximum transaction size")
        if memory > limits["executionMemory"]:
            stops.append("maximum transaction execution memory")
        if steps > limits["executionSteps"]:
            stops.append("maximum transaction execution steps")
        require(
            event["status"] in (200, 400), "transport failure is not a node verdict"
        )
        if accepted:
            require(response == identity, "accepted response names another transaction")
            require(
                identity in chain and chain[identity]["cbor"] == raw.hex(),
                "accepted transaction not independently included with identical bytes",
            )
            require(not stops, "node acceptance contradicts measured limits")
        else:
            require(identity not in chain, "refused transaction was included")
            require(stops, "node refusal has no measured limiting parameter")
            require(
                "maximum transaction size" in stops and "MaxTxSizeUTxO" in response,
                "refusal is not the measured size limit",
            )
            reported = re.search(r"supplied: (\d+), expected: (\d+)", response)
            require(
                reported is not None
                and [int(value) for value in reported.groups()]
                == [ledger_bytes, limits["transactionBytes"]],
                "node size figures disagree with signed CBOR and parameters",
            )
        form.update(
            {
                "stateSource": "witness" if attach_state else "live reference output",
                "applicationSource": "witness"
                if attach_application
                else "live reference output",
                "createsReferenceOutputs": creates,
                "sizeBytes": len(raw),
                "ledgerSizeBytes": ledger_bytes,
                "feeLovelace": measured["feeLovelace"],
                "executionMemory": memory,
                "executionSteps": steps,
                "node": {
                    "outcome": "accepted and confirmed" if accepted else "refused",
                    "transaction": identity,
                    "response": response,
                },
                "fits": accepted and not stops,
                "limitingParameters": stops,
                "liveReferenceScripts": references,
                "createdReferenceScripts": [
                    output
                    for output in measured["outputs"]
                    if output["referenceScript"]
                ],
            }
        )
    require(len(set(identities)) == len(FORMS), "forms must be distinct transactions")
    require(
        all(fields == configurations[0] for fields in configurations),
        "creation configuration differs between forms",
    )
    rebuilt["configuration"] = configurations[0]
    require(
        len(configurations[0]) == 5, "five-field application configuration required"
    )
    return rebuilt


def load(directory, candidate, cost):
    path = directory / "carrying.json"
    require(path.is_file(), "experiment receipt is missing")
    receipt = json.loads(path.read_text())
    rebuilt = rebuild(receipt, directory, candidate, cost)
    require(
        receipt == rebuilt,
        "receipt figures differ from independent submissions, CBOR, evaluation or chain inclusion",
    )
    return rebuilt


def controls(receipt, directory, candidate, cost):
    count = 0

    def refused(altered, label):
        nonlocal count
        try:
            rebuilt = rebuild(altered, directory, candidate, cost)
            require(altered == rebuilt, "altered computed fields")
        except (ValueError, KeyError, IndexError, TypeError):
            count += 1
            return
        raise AssertionError("carrying control accepted " + label)

    for index, form in enumerate(receipt["forms"]):
        for field in (
            "sizeBytes",
            "ledgerSizeBytes",
            "feeLovelace",
            "executionMemory",
            "executionSteps",
        ):
            altered = copy.deepcopy(receipt)
            altered["forms"][index][field] += 1
            refused(altered, form["form"] + " " + field)
        for field in (
            "fits",
            "limitingParameters",
            "node",
            "liveReferenceScripts",
            "createdReferenceScripts",
            "stateSource",
            "applicationSource",
            "createsReferenceOutputs",
        ):
            altered = copy.deepcopy(receipt)
            altered["forms"][index][field] = "altered"
            refused(altered, form["form"] + " " + field)
        altered = copy.deepcopy(receipt)
        altered["forms"][index]["evaluation"] = []
        refused(altered, "size-only fit")
        altered = copy.deepcopy(receipt)
        altered["forms"][index]["signedTransactionCBOR"] = receipt["forms"][
            (index + 1) % len(FORMS)
        ]["signedTransactionCBOR"]
        refused(altered, "another transaction relabelled as this form")
    for key in receipt["limits"]:
        altered = copy.deepcopy(receipt)
        altered["limits"][key] = "altered"
        refused(altered, "limit or fee parameter " + key)
    for field in ("configuration", "network", "scripts"):
        altered = copy.deepcopy(receipt)
        altered[field] = []
        refused(altered, field)
    altered = copy.deepcopy(receipt)
    altered["forms"].pop()
    refused(altered, "omitted form")
    altered = copy.deepcopy(receipt)
    altered["forms"][0] = copy.deepcopy(altered["forms"][1])
    refused(altered, "duplicated form")
    print(
        f"creation-carrying: {count} altered figures, missing execution, false fits, limits and form substitutions refused"
    )


def page(receipt, candidate):
    forms = {form["form"]: form for form in receipt["forms"]}
    limits = receipt["limits"]
    witnesses = forms["witnesses"]
    outputs = forms["reference-outputs"]
    state = forms["state-witness"]
    application = forms["application-witness"]
    configuration = receipt["configuration"]
    require(
        [form["fits"] for form in receipt["forms"]] == [True, False, False, True, True],
        "the frozen experiment's outcomes changed; its explanation must be reviewed",
    )
    lines = [
        "## Can creation carry its scripts",
        "",
        f"The measuring tool built {len(forms)} registry-creation forms with the real genesis and application configuration builders, on one fresh development network with the same frozen protocol parameters as the comparison above. Each form creates a fresh registry with the same configuration; only script placement changes. The normal referenced form is the reference point. These are experiments, and the production command keeps its shared publications.",
        "",
        "Both live copies were available for this controlled experiment. A form carrying a script deliberately ignores that script's live copy. A form creating reference outputs also carries witnesses: a transaction cannot read its own new outputs as reference inputs.",
        "",
        f"The state-carried form has {state['sizeBytes']} complete signed bytes and the application-carried form has {application['sizeBytes']}. The node accepted and confirmed both mixed forms. Each still needs the other script's live reference output.",
        "",
        f"Carrying both scripts in witnesses has {witnesses['sizeBytes']} complete signed bytes; carrying them in witnesses and new reference outputs has {outputs['sizeBytes']}. The node refused both for maximum transaction size: it counts {witnesses['ledgerSizeBytes']} and {outputs['ledgerSizeBytes']} bytes respectively, against a limit of {limits['transactionBytes']}. The complete signed transaction length and the length the ledger counts are different figures; the ledger count here is one byte less. Both appear below.",
        "",
        "| Creation form | Complete signed bytes | Ledger-counted bytes | Fee (lovelace) | Evaluated memory | Evaluated steps | Node outcome | Limiting parameter |",
        "|---|---:|---:|---:|---:|---:|---|---|",
    ]
    for form in receipt["forms"]:
        lines.append(
            "| "
            + " | ".join(
                [
                    LABELS[form["form"]],
                    *[
                        str(form[field])
                        for field in (
                            "sizeBytes",
                            "ledgerSizeBytes",
                            "feeLovelace",
                            "executionMemory",
                            "executionSteps",
                        )
                    ],
                    form["node"]["outcome"],
                    ", ".join(form["limitingParameters"]) or "none",
                ]
            )
            + " |"
        )
    lines += [
        "",
        "A fit requires successful execution, size within the ledger limit, and the development node's acceptance and confirmation. The execution figures are the ledger evaluator's final results on the actual chain inputs and equal the signed execution budgets. The oversized forms were evaluated locally, then refused by the node's size check before its script-execution phase; their execution figures do not claim node execution. A size comparison alone is never reported as a fit.",
        "",
        "### Frozen limits and fee parameters",
        "",
        f"Every form used maximum transaction size {limits['transactionBytes']}, maximum transaction execution memory {limits['executionMemory']} and maximum transaction execution steps {limits['executionSteps']}. The parameters and their hash are read from the independent chain record, rather than supplied by the measuring command.",
        "",
        "| Parameter | Chain-read value |",
        "|---|---:|",
        f"| Maximum transaction bytes | {limits['transactionBytes']} |",
        f"| Maximum transaction execution memory | {limits['executionMemory']} |",
        f"| Maximum transaction execution steps | {limits['executionSteps']} |",
        f"| Fee per byte (lovelace) | {limits['feePerByteLovelace']} |",
        f"| Fixed fee (lovelace) | {limits['fixedFeeLovelace']} |",
        f"| Execution price per memory unit | {limits['executionPrices']['priceMemory']} |",
        f"| Execution price per step | {limits['executionPrices']['priceSteps']} |",
        f"| Initial reference-script fee per byte (lovelace) | {limits['referenceScriptFeePerByteLovelace']} |",
        "",
        "The experiment holds the application's configuration fixed across forms. These explicit experimental values do not change command defaults.",
        "",
        "| Application configuration | Value |",
        "|---|---:|",
    ]
    for label, value in zip(
        (
            "Registration cost (lovelace)",
            "Minimum tip (lovelace)",
            "Processing window (milliseconds)",
            "Reclaiming window (milliseconds)",
            "Booking width (milliseconds)",
        ),
        configuration,
        strict=True,
    ):
        lines.append(f"| {label} | {value} |")
    lines += [
        "",
        "### What the result gives a creator",
        "",
        "Each fitting mixed form still needs one prior publication. When a first creation finds no live copy, it cannot skip both publications by carrying: the both-witness form that needs no live reference is refused for size. A fitting mixed form creates no reference output for the script it carries. If a first creation published only the other script, a later registry using the unchanged production command would still have to publish the carried script. Carrying defers that publication; it does not remove it.",
        "",
        f"The production workflow remains as measured: the first creation sends {candidate['first']['totals']['transactionCount']} transactions, and the later creation sends {candidate['later']['totals']['transactionCount']} transaction by reusing the shared publications. The measured carrying outcomes are reported without recommending or adopting a mixed form.",
        "",
        "### Measurement appendix",
        "",
        "The [carrying receipt](https://github.com/lambdasistemi/singular/blob/main/specs/745-shared-publications/evidence/carrying.json) records the test-only producer, its exact source changes and executable hash, the signed transactions, local execution results and independent node answers. The experiment has its own recorded genesis and start time; its protocol parameters match the earlier creation comparison. The receipt checker recomputes lengths, fees, script hashes, placements and execution budgets, binds each transaction to the independent node submission, and requires identical included bytes for every fit. Every refusal must reproduce the node's limiting parameter and figures. Missing forms, missing execution, altered figures and false fits are refused by the hosted documentation check. The test harness is outside the released command's source and changes no production builder or shared receipt.",
        "",
    ]
    return lines


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    capture = commands.add_parser("capture")
    for name in ("tool", "source", "output", "program", "producer-sources"):
        capture.add_argument("--" + name, required=True)
    commands.add_parser("check")
    commands.add_parser("controls")
    args = parser.parse_args()
    cost = runpy.run_path(str(Path(__file__).with_name("creation-cost.py")))
    directory = cost["EVIDENCE"]
    candidate = cost["load_pair"]()[1]
    if args.command == "capture":
        output = Path(args.output)
        source = Path(args.source)
        copied = output.with_name("carrying-chain.jsonl")
        copied.write_bytes(source.read_bytes())
        receipt = json.loads(Path(args.tool).read_text())
        receipt.update(
            chainRecord=copied.name,
            chainRecordSha256=digest(copied.read_bytes()),
            producer={
                "programSha256": digest(Path(args.program).read_bytes()),
                "sources": json.loads(Path(args.producer_sources).read_text()),
            },
        )
        receipt = rebuild(receipt, output.parent, candidate, cost)
        output.write_text(json.dumps(receipt, indent=2) + "\n")
    else:
        receipt = load(directory, candidate, cost)
        if args.command == "controls":
            controls(receipt, directory, candidate, cost)
        else:
            print(
                "creation-carrying: all five forms agree with independent node submissions, execution budgets and inclusion"
            )


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, IndexError, TypeError, AssertionError) as error:
        sys.exit(str(error))
