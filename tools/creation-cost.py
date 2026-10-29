#!/usr/bin/env python3
"""Measure creation from chain bytes; check the committed receipts and generated page.

The capture command is a measuring tool. The check and controls commands are
obligations invoked by creation-cost-check in the documentation job.
"""

import argparse
import copy
import hashlib
import json
import runpy
import subprocess
import sys
from pathlib import Path

CHAIN = runpy.run_path(str(Path(__file__).with_name("no_pin_chain_view.py")))
decode, get = CHAIN["decode"], CHAIN["get"]
EVIDENCE = Path("specs/745-shared-publications/evidence")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(value):
    return hashlib.sha256(value).hexdigest()


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def read_chain(path):
    events = [json.loads(line) for line in path.read_text().splitlines()]
    genesis = [e for e in events if e["kind"] == "initial-genesis-ledger"]
    require(len(genesis) == 1, "one initial genesis observation is required")
    parameters = [
        json.loads(bytes.fromhex(e["responseBytes"]))
        for e in events
        if e["kind"] == "http-ledger-exchange"
        and e["path"] == "/api/v1/cli_protocol_params"
    ]
    require(
        parameters and all(p == parameters[0] for p in parameters),
        "parameters changed or were not observed",
    )
    initial = genesis[0]
    network = {
        "shelleyGenesisSha256": digest(bytes.fromhex(initial["genesisBytes"])),
        "byronGenesisSha256": digest(bytes.fromhex(initial["byronGenesisBytes"])),
        "protocolParametersCborSha256": digest(
            bytes.fromhex(initial["source"]["protocolParametersCBOR"])
        ),
        "protocolParameters": parameters[0],
        "protocolParametersSha256": digest(encoded(parameters[0])),
    }
    transactions = {}
    for event in events:
        if event["kind"] != "chain-sync-full-block":
            continue
        for transaction in event["block"]["transactions"]:
            identity = transaction["material"]["tx_hash"]
            require(
                identity not in transactions, "duplicate transaction in chain record"
            )
            transactions[identity] = transaction
    require(transactions, "chain record contains no transaction")
    return network, transactions


def measure(transaction):
    raw = bytes.fromhex(transaction["cbor"])
    require(raw[0] == 0x84, "expected a complete four-part ledger transaction")
    tx, end = decode(raw)
    require(end == len(raw), "trailing or truncated transaction bytes")
    _, body_end = decode(raw, 1)
    identity = hashlib.blake2b(raw[1:body_end], digest_size=32).hexdigest()
    require(
        identity == transaction["material"]["tx_hash"],
        "transaction identity differs from body bytes",
    )
    outputs = []
    for index, output in enumerate(get(tx[0], 1)):
        mapped = isinstance(output, tuple) and output[0] == "map"
        value = get(output, 1) if mapped else output[1]
        lovelace = value if isinstance(value, int) else value[0]
        embedded = get(output, 3) if mapped else None
        script = None
        if embedded is not None:
            (language, carried), last = decode(embedded)
            require(
                last == len(embedded) and language in (1, 2, 3),
                "unsupported reference script",
            )
            script = {
                "hash": hashlib.blake2b(
                    bytes([language]) + carried, digest_size=28
                ).hexdigest(),
                "sizeBytes": len(carried),
                "language": language,
            }
        outputs.append(
            {
                "reference": f"{identity}#{index}",
                "lovelace": lovelace,
                "referenceScript": script,
            }
        )

    def references(key):
        return [f"{txid.hex()}#{index}" for txid, index in get(tx[0], key) or []]

    signers = [
        hashlib.blake2b(pair[0], digest_size=28).hexdigest()
        for pair in get(tx[1], 0) or []
    ]
    return {
        "id": identity,
        "sizeBytes": len(raw),
        "feeLovelace": get(tx[0], 2),
        "outputs": outputs,
        "inputsSpent": references(0),
        "inputsRead": references(18),
        "signers": sorted(signers),
    }


def totals(transactions):
    references = [o for t in transactions for o in t["outputs"] if o["referenceScript"]]
    witness = [t for t in transactions if t["step"].startswith("publish-witness")]
    return {
        "transactionCount": len(transactions),
        "transactionBytes": sum(t["sizeBytes"] for t in transactions),
        "outputsCreated": sum(len(t["outputs"]) for t in transactions),
        "feesLovelace": sum(t["feeLovelace"] for t in transactions),
        "referenceOutputsCreated": len(references),
        "referenceScriptsBytes": sum(
            o["referenceScript"]["sizeBytes"] for o in references
        ),
        "referenceAdaLockedLovelace": sum(o["lovelace"] for o in references),
        "witnessPublicationTransactions": len(witness),
        "witnessPublicationFeesLovelace": sum(t["feeLovelace"] for t in witness),
        "witnessPublicationAdaLockedLovelace": sum(
            o["lovelace"] for t in witness for o in t["outputs"] if o["referenceScript"]
        ),
    }


def configuration_fields(transaction):
    decoded, _ = decode(bytes.fromhex(transaction["cbor"]))
    configurations = []
    for output in get(decoded[0], 1):
        if not isinstance(output, tuple):
            continue
        datum = get(output, 2)
        if not datum or datum[0] != 1:
            continue
        value, _ = decode(datum[1])
        if (
            isinstance(value, tuple)
            and value[0] == "constr"
            and len(value[2]) == 1
            and isinstance(value[2][0], tuple)
            and value[2][0][0] == "constr"
        ):
            configurations.append(value[2][0][2])
    require(len(configurations) == 1, "creation has no unique chain configuration")
    return configurations[0]


def creation(selectors, chain):
    transactions = []
    for selected in selectors:
        require(selected["id"] in chain, "submitted transaction missing from chain")
        transactions.append(dict(measure(chain[selected["id"]]), step=selected["step"]))
    identities = [t["id"] for t in transactions]
    require(
        identities and len(set(identities)) == len(identities),
        "empty or repeated creation transaction",
    )
    order = list(chain)
    require(
        identities == sorted(identities, key=order.index),
        "creation submissions are not in chain order",
    )
    before = {}
    for identity, raw in chain.items():
        if identity == identities[0]:
            break
        observed = measure(raw)
        for reference in observed["inputsSpent"]:
            before.pop(reference, None)
        before.update((o["reference"], o) for o in observed["outputs"])
    required = {
        o["referenceScript"]["hash"]
        for t in transactions
        for o in t["outputs"]
        if o["referenceScript"]
    }
    for t in transactions:
        for reference in t["inputsRead"]:
            txid, _, index = reference.partition("#")
            output = measure(chain[txid])["outputs"][int(index)]
            if output["referenceScript"]:
                required.add(output["referenceScript"]["hash"])
    live = [
        o
        for o in before.values()
        if o["referenceScript"] and o["referenceScript"]["hash"] in required
    ]
    return {
        "transactions": transactions,
        "liveReferenceScriptsBefore": live,
        "totals": totals(transactions),
    }


def recompute(receipt, directory):
    path = directory / receipt["chainRecord"]
    network, chain = read_chain(path)
    require(
        digest(path.read_bytes()) == receipt["chainRecordSha256"],
        "chain record hash differs",
    )
    rebuilt = copy.deepcopy(receipt)
    rebuilt["network"] = network
    all_ids = []
    for name in ("first", "later"):
        selectors = [
            {"id": t["id"], "step": t["step"]} for t in receipt[name]["transactions"]
        ]
        rebuilt[name] = dict(
            creation(selectors, chain), release=receipt[name]["release"]
        )
        all_ids.extend(t["id"] for t in rebuilt[name]["transactions"])
    require(
        len(all_ids) == len(set(all_ids)), "a transaction belongs to both creations"
    )
    measured = [measure(t) for t in chain.values()]
    signers = set(rebuilt["first"]["transactions"][0]["signers"])
    require(len(signers) == 1, "creation has no unique creator signer")
    order = list(chain)
    start = order.index(all_ids[0])
    funded = []
    for transaction in list(chain.values())[:start]:
        decoded, _ = decode(bytes.fromhex(transaction["cbor"]))
        observed = measure(transaction)
        for index, output in enumerate(get(decoded[0], 1)):
            address = get(output, 0) if isinstance(output, tuple) else output[0]
            if address[0] >> 4 in (0, 2, 4, 6) and address[1:29].hex() in signers:
                funded.append(observed["outputs"][index]["lovelace"])
    workload = receipt["workload"]
    require(
        len(funded) == workload["fundingOutputs"]
        and all(amount == workload["fundingLovelacePerOutput"] for amount in funded),
        "wallet funding differs from chain outputs",
    )
    for name in ("first", "later"):
        creates = [
            t for t in receipt[name]["transactions"] if t["step"] in ("boot", "create")
        ]
        require(len(creates) == 1, "the workload contains no unique registry creation")
        configuration = configuration_fields(chain[creates[0]["id"]])
        require(
            configuration[2] == workload["processingMilliseconds"]
            and configuration[3] == workload["reclaimingMilliseconds"],
            "creation windows differ from chain configuration",
        )
        witness_transactions = [
            t
            for t in rebuilt[name]["transactions"]
            if t["step"].startswith("publish-witness")
        ]
        if receipt["design"] == "previous":
            require(
                len(configuration) == 6 and isinstance(configuration[5], bytes),
                "previous configuration carries no active witness policy",
            )
            active_policy = configuration[5].hex()
            publications = [
                t
                for t in rebuilt[name]["transactions"]
                if any(
                    o["referenceScript"]
                    and o["referenceScript"]["hash"] == active_policy
                    for o in t["outputs"]
                )
            ]
            require(
                len(publications) == 1
                and witness_transactions == publications
                and publications[0]["step"] == "publish-witness-active",
                "active witness publication is not named from its chain configuration",
            )
        else:
            require(
                not witness_transactions
                and len(configuration) == 5
                and all(isinstance(field, int) for field in configuration),
                "candidate publishes or configures a witness policy",
            )
        for transaction in rebuilt[name]["transactions"]:
            spent = 0
            for reference in transaction["inputsSpent"]:
                identity, _, index = reference.partition("#")
                require(
                    identity in chain,
                    "creation funding input is absent from the chain record",
                )
                spent += measure(chain[identity])["outputs"][int(index)]["lovelace"]
            created = sum(output["lovelace"] for output in transaction["outputs"])
            require(
                spent == created + transaction["feeLovelace"],
                "creation fee does not reconcile spent and created ADA",
            )
    # The run record bounds the creation workload independently of its receipt.
    # A live journey captures this prefix before the creator runs another command.
    # Never shrink this extent to the first/last retained receipt transaction.
    creator_transactions = [
        t["id"] for t in measured if signers.intersection(t["signers"])
    ]
    require(
        creator_transactions == all_ids,
        "creation selection omits or adds a creator transaction",
    )
    require(
        not rebuilt["first"]["liveReferenceScriptsBefore"],
        "first creation already has a live script copy",
    )
    require(
        rebuilt["later"]["liveReferenceScriptsBefore"],
        "later creation reuses no live script copy",
    )
    require(
        rebuilt == receipt, "receipt figure differs from the chain-derived measurement"
    )
    return rebuilt


def capture(arguments):
    manifest = json.loads(Path(arguments.manifest).read_text())
    source = Path(arguments.source)
    # A running journey appends events. Snapshot only complete newline-delimited
    # events, then require every selected creation transaction in that prefix.
    events = [
        json.loads(line)
        for line in source.read_bytes().splitlines(keepends=True)
        if line.endswith(b"\n")
    ]
    kept = [
        e
        for e in events
        if e["kind"] in ("initial-genesis-ledger", "chain-sync-full-block")
        or (
            e["kind"] == "http-ledger-exchange"
            and e["path"] == "/api/v1/cli_protocol_params"
        )
    ]
    target = Path(arguments.output)
    target.parent.mkdir(parents=True, exist_ok=True)
    chain_path = target.with_name(target.stem + "-chain.jsonl")
    chain_path.write_text(
        "".join(json.dumps(e, separators=(",", ":")) + "\n" for e in kept)
    )
    network, chain = read_chain(chain_path)
    receipt = dict(
        manifest,
        schema="creation-cost-v1",
        network=network,
        chainRecord=chain_path.name,
        chainRecordSha256=digest(chain_path.read_bytes()),
    )
    for name in ("first", "later"):
        command = json.loads(Path(manifest[name]["commandReceipt"]).read_text())
        require(command["outcome"] == "success", "creation command did not succeed")
        selectors = [{"id": t["tx"], "step": t["step"]} for t in command["submissions"]]
        receipt[name] = dict(
            creation(selectors, chain), release=manifest[name]["release"]
        )
    recompute(receipt, target.parent)
    target.write_text(json.dumps(receipt, indent=2) + "\n")
    print(
        f"creation-cost: captured {receipt['design']} from {len(chain)} chain transactions"
    )


def pair(receipts, directory):
    require(
        [r["design"] for r in receipts] == ["previous", "candidate"],
        "the pair must contain both designs in order",
    )
    for receipt in receipts:
        require(
            receipt["schema"] == "creation-cost-v1", "unknown creation receipt schema"
        )
        recompute(receipt, directory)
        require(
            receipt["first"]["release"] == receipt["later"]["release"],
            "a design mixes application releases",
        )
        require(
            receipt["workload"]["creations"] == ["first", "later"],
            "the workload is not first then later creation",
        )
    for field in ("application", "network", "workload", "tools"):
        require(receipts[0][field] == receipts[1][field], f"the legs differ in {field}")
    return receipts


def candidate_matches(measured, committed):
    require(
        measured["schema"] == committed["schema"] == "creation-cost-v1"
        and measured["design"] == committed["design"] == "candidate",
        "live measurement has the wrong receipt schema or design",
    )
    for name in ("first", "later"):
        actual = measured[name]
        expected = committed[name]
        require(
            actual["totals"]["transactionCount"]
            == expected["totals"]["transactionCount"],
            "candidate transaction count changed",
        )

        def hashes(creation):
            return sorted(
                o["referenceScript"]["hash"]
                for t in creation["transactions"]
                for o in t["outputs"]
                if o["referenceScript"]
            )

        require(
            hashes(actual) == hashes(expected),
            "candidate publication script hashes changed",
        )
        require(
            sorted(
                o["referenceScript"]["hash"]
                for o in actual["liveReferenceScriptsBefore"]
            )
            == sorted(
                o["referenceScript"]["hash"]
                for o in expected["liveReferenceScriptsBefore"]
            ),
            "candidate reused script hashes changed",
        )


def page(receipts):
    baseline, candidate = receipts
    first, later = (
        baseline[n]["totals"]["transactionCount"] for n in ("first", "later")
    )
    claim = "matches" if (first, later) == (4, 2) else "does not match"
    lines = [
        "# What creating a registry costs",
        "",
        "As a registry creator, you can compare what the first and a later registry cost under the previous design and the application-held design. The figures below are measured from transactions included on a development network; fees are spent ADA, while ADA locked in reference outputs remains in those outputs.",
        "",
        "The two legs run the previous design's last release and this line's release of open datum. Their validators differ: this compares two creation workflows, rather than one release run twice. Within each design, both creations use the same executable and deployment blueprint.",
        "",
        "## Finding a shared script",
        "",
        "As a creator, you can reuse another wallet's live publications with your own wallet and a fresh state directory. You need the release and your provider settings, but no file or address from the publisher. The provider finds candidate live outputs by script hash. The command computes the hash of each carried script, including its language and applied parameters, before deciding whether to reuse it.",
        "",
        "```mermaid",
        "flowchart TD",
        "    C[Creator with the release] -->|Expected script hash| P[Provider lookup]",
        "    P -->|Candidate output| V[Verify the carried script]",
        "    V -->|Genuine live copy| R[Reuse its reference]",
        "    P -->|No live copy returned| M[Publish the missing script]",
        "    V -->|Foreign script| M",
        "```",
        "",
        "Each script in the creation receipt has one outcome: reused or published. Its discovery record retains the candidate references, the hashes found and expected, and whether each candidate is genuine or foreign. A foreign candidate is skipped even if another genuine copy is reused. No live copy means none was found by this provider; the unspent-output query cannot distinguish a spent output from one that never existed.",
        "",
        "This is discovery by script hash through the configured provider. Publishing references for everyone, naming a trusted publisher and general public discovery remain outside this workflow, in issues 355 and 473. No witness-policy publication or witness-pin configuration is needed.",
        "",
        "After an interruption around publication, rerunning reuses what is live and publishes only what is missing. An uncertain submission keeps its saved transaction identity and signed body; a later invocation reconciles it without automatically resubmitting it. Create is not idempotent: a further invocation can create another registry from a new seed. Repeating an explicit seed that has already been spent retains the existing refusal.",
        "",
        "## Measured creations",
        "",
        f"The previous design sent {first} transactions for its first creation and {later} for its later creation. The issue's four-then-two claim {claim} these measured counts. "
        f"The application-held design sent {candidate['first']['totals']['transactionCount']} and {candidate['later']['totals']['transactionCount']} respectively.",
        "",
        "The first creation starts without a live copy of any script it needs. Later creations have the earlier shared copies available. Under the previous design only the state script is shared; request, witness and application scripts are specific to the new registry. The application-held design reuses both the state and application scripts.",
        "",
        "| Design | Creation | Transactions | Transaction bytes | Outputs created | Fees (lovelace) | Reference outputs | Reference script bytes | ADA locked in reference outputs (lovelace) |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for receipt in receipts:
        for name in ("first", "later"):
            total = receipt[name]["totals"]
            values = [receipt["design"], name] + [
                str(total[k])
                for k in (
                    "transactionCount",
                    "transactionBytes",
                    "outputsCreated",
                    "feesLovelace",
                    "referenceOutputsCreated",
                    "referenceScriptsBytes",
                    "referenceAdaLockedLovelace",
                )
            ]
            lines.append("| " + " | ".join(values) + " |")
    lines += [
        "",
        "## Witness publication overhead",
        "",
        "The previous design publishes an active witness policy for each registry. That publication is unused by the permanent two-edge contract. Its fee and its reference-output capital are included above and separated below; they must not be added twice. The application-held design publishes no witness policy.",
        "",
        "| Design | Creation | Witness publication transactions | Witness publication fees (lovelace) | Witness reference ADA (lovelace) |",
        "|---|---|---:|---:|---:|",
    ]
    for receipt in receipts:
        for name in ("first", "later"):
            total = receipt[name]["totals"]
            lines.append(
                "| "
                + " | ".join(
                    [receipt["design"], name]
                    + [
                        str(total[k])
                        for k in (
                            "witnessPublicationTransactions",
                            "witnessPublicationFeesLovelace",
                            "witnessPublicationAdaLockedLovelace",
                        )
                    ]
                )
                + " |"
            )
    lines += [
        "",
        "## Transactions and reference outputs",
        "",
        "Every creation transaction is listed in submission order. Spent and read inputs are output references decoded from that transaction. Each reference output lists the hash computed from its carried script, the script's byte length and its locked lovelace.",
        "",
    ]
    for receipt in receipts:
        lines += [
            f"### {receipt['design'].capitalize()} design",
            "",
            f"Release: `{receipt['first']['release']['version']}`. Revision: `{receipt['revision']}`. Deployment blueprint SHA-256: `{receipt['first']['release']['blueprintSha256']}`.",
            "",
        ]
        for name in ("first", "later"):
            lines += [
                f"**{name.capitalize()} creation**",
                "",
                "| Step | Transaction | Bytes | Fee (lovelace) | Created outputs | Spent inputs | Read inputs |",
                "|---|---|---:|---:|---:|---|---|",
            ]
            for transaction in receipt[name]["transactions"]:
                lines.append(
                    "| "
                    + " | ".join(
                        [
                            transaction["step"],
                            f"`{transaction['id']}`",
                            str(transaction["sizeBytes"]),
                            str(transaction["feeLovelace"]),
                            str(len(transaction["outputs"])),
                            ", ".join(f"`{r}`" for r in transaction["inputsSpent"]),
                            ", ".join(f"`{r}`" for r in transaction["inputsRead"])
                            or "none",
                        ]
                    )
                    + " |"
                )
            lines += [
                "",
                "| Reference output | Script hash | Script bytes | Locked lovelace |",
                "|---|---|---:|---:|",
            ]
            references = [
                o
                for t in receipt[name]["transactions"]
                for o in t["outputs"]
                if o["referenceScript"]
            ]
            for output in references:
                lines.append(
                    f"| `{output['reference']}` | `{output['referenceScript']['hash']}` | {output['referenceScript']['sizeBytes']} | {output['lovelace']} |"
                )
            if not references:
                lines.append("| none | none | — | — |")
            lines.append("")
    carrying_checker, carrying = load_carrying(receipts)
    lines += carrying_checker["page"](carrying, candidate)
    network = baseline["network"]
    lines += [
        "## Matched conditions and evidence",
        "",
        "The legs use separate fresh development networks from the same frozen genesis, the same protocol parameters, the same generated wallet funding and the same processing and reclaim windows. Each network is read independently. The receipts include the complete chain-read protocol parameters and the tool versions.",
        "",
        "| Shared condition | Value |",
        "|---|---|",
    ]
    for name in (
        "shelleyGenesisSha256",
        "byronGenesisSha256",
        "protocolParametersCborSha256",
        "protocolParametersSha256",
    ):
        lines.append(f"| {name} | `{network[name]}` |")
    for name, value in baseline["workload"].items():
        lines.append(f"| {name} | {value} |")
    lines += [
        "",
        "The [committed receipts and chain records](https://github.com/lambdasistemi/singular/tree/main/specs/745-shared-publications/evidence) preserve the transactions, their complete bytes and the network observations. The documentation check recomputes every figure from those bytes, checks the two workloads and regenerates this entire page for comparison. Altered figures and mismatched legs are refused. The hosted registration journey writes the candidate receipt in the same schema and compares its transaction counts and script hashes; fees may differ between runs.",
        "",
        "## Limits",
        "",
        "These are development-network measurements, not fee quotes for another network. Reference-output capital is reported separately from fees; this page does not claim it is spent. The measured transactions do not establish public reference discovery for everyone, batch limits or release acceptance. Those remain the work of issues 355 and 473, issue 746 and issue 747 respectively. Existing uncovered registration comparisons remain uncovered.",
        "",
        "Creation behavior remains bound to the application-held model's genesis and recognition inversions, creation money statement, configuration creation inversion and immutable configuration statement. This measuring tool changes no validator, model or wire format, and the measurements do not establish new model conformance. The trie library's proofs are assumed sound.",
        "",
    ]
    return "\n".join(lines)


def load_pair():
    return [
        json.loads((EVIDENCE / (name + ".json")).read_text())
        for name in ("previous", "candidate")
    ]


def load_carrying(receipts):
    checker = runpy.run_path(str(Path(__file__).with_name("creation-carrying.py")))
    return checker, checker["load"](EVIDENCE, receipts[1], globals())


def page_matches(text, receipts):
    require(text == page(receipts), "page differs from receipt-derived figures")


def journey(arguments):
    work = Path(arguments.work)
    version = subprocess.check_output(
        [arguments.program, "--version"], text=True
    ).strip()
    release = {
        "version": version,
        "blueprintSha256": digest(Path(arguments.blueprint).read_bytes()),
        "programSha256": digest(Path(arguments.program).read_bytes()),
    }
    manifest = {
        "design": "candidate",
        "revision": version.partition("(commit ")[2].rstrip(")"),
        "application": "open datum",
        "tools": {
            "openDatum": version,
            "devnetSha256": digest(Path(arguments.devnet).read_bytes()),
            "python": sys.version,
        },
        "workload": {
            "creations": ["first", "later"],
            "fundingOutputs": 8,
            "fundingLovelacePerOutput": 2000000000,
            "processingMilliseconds": 60000,
            "reclaimingMilliseconds": 180000,
        },
        "first": {
            "release": release,
            "commandReceipt": str(work / "receipts/create-first.json"),
        },
        "later": {
            "release": release,
            "commandReceipt": str(work / "receipts/create-later.json"),
        },
    }
    manifest_path = work / "candidate-creation-manifest.json"
    manifest_path.write_text(json.dumps(manifest))
    output = work / "candidate-creation.json"
    capture(
        argparse.Namespace(
            manifest=str(manifest_path), source=arguments.source, output=str(output)
        )
    )
    measured = json.loads(output.read_text())
    candidate_matches(measured, json.loads(Path(arguments.reference).read_text()))
    print(
        "creation-cost: journey counts and carried/reused script hashes agree with the committed candidate"
    )


def controls(receipts):
    count = 0

    def refused(subject, operation, label):
        nonlocal count
        try:
            operation(subject)
        except (ValueError, KeyError):
            count += 1
            return
        raise ValueError(f"control accepted {label}")

    for leg in range(len(receipts)):
        for name in ("first", "later"):
            _, chain = read_chain(EVIDENCE / receipts[leg]["chainRecord"])
            for endpoint in (0, -1):
                altered = copy.deepcopy(receipts)
                transactions = altered[leg][name]["transactions"]
                del transactions[endpoint]
                if transactions:
                    selected = [
                        {"id": t["id"], "step": t["step"]} for t in transactions
                    ]
                    release = altered[leg][name]["release"]
                    altered[leg][name] = dict(
                        creation(selected, chain), release=release
                    )
                refused(
                    altered, lambda r: pair(r, EVIDENCE), "omitted creation endpoint"
                )
            if receipts[leg]["design"] == "previous":
                altered = copy.deepcopy(receipts)
                selectors = [
                    {
                        "id": t["id"],
                        "step": "publish-application"
                        if t["step"].startswith("publish-witness")
                        else t["step"],
                    }
                    for t in altered[leg][name]["transactions"]
                ]
                altered[leg][name] = dict(
                    creation(selectors, chain), release=altered[leg][name]["release"]
                )
                refused(
                    altered,
                    lambda r: pair(r, EVIDENCE),
                    "witness publication relabelled as application",
                )
            for field in receipts[leg][name]["totals"]:
                altered = copy.deepcopy(receipts)
                altered[leg][name]["totals"][field] += 1
                refused(altered, lambda r: pair(r, EVIDENCE), field)
            altered = copy.deepcopy(receipts)
            total = altered[leg][name]["totals"]
            total["feesLovelace"] += total["referenceAdaLockedLovelace"]
            total["referenceAdaLockedLovelace"] = 0
            if altered != receipts:
                refused(
                    altered,
                    lambda r: pair(r, EVIDENCE),
                    "reference capital counted as fees",
                )
            for index, transaction in enumerate(receipts[leg][name]["transactions"]):
                for field in ("sizeBytes", "feeLovelace"):
                    altered = copy.deepcopy(receipts)
                    altered[leg][name]["transactions"][index][field] += 1
                    refused(altered, lambda r: pair(r, EVIDENCE), field)
                for output_index, output in enumerate(transaction["outputs"]):
                    for field in ("lovelace",):
                        altered = copy.deepcopy(receipts)
                        altered[leg][name]["transactions"][index]["outputs"][
                            output_index
                        ][field] += 1
                        refused(altered, lambda r: pair(r, EVIDENCE), field)
                    if output["referenceScript"]:
                        for field in ("hash", "sizeBytes"):
                            altered = copy.deepcopy(receipts)
                            script = altered[leg][name]["transactions"][index][
                                "outputs"
                            ][output_index]["referenceScript"]
                            script[field] = (
                                "0" * 56 if field == "hash" else script[field] + 1
                            )
                            refused(
                                altered,
                                lambda r: pair(r, EVIDENCE),
                                "carried script " + field,
                            )
        altered = copy.deepcopy(receipts)
        altered[leg]["later"]["release"]["blueprintSha256"] = "0" * 64
        refused(altered, lambda r: pair(r, EVIDENCE), "mixed releases")
    for field in ("application", "workload", "network"):
        altered = copy.deepcopy(receipts)
        altered[1][field] = {"altered": True}
        refused(altered, lambda r: pair(r, EVIDENCE), "mismatched " + field)
    for field in (
        "fundingOutputs",
        "fundingLovelacePerOutput",
        "processingMilliseconds",
        "reclaimingMilliseconds",
    ):
        altered = copy.deepcopy(receipts)
        for receipt in altered:
            receipt["workload"][field] += 1
        refused(
            altered, lambda r: pair(r, EVIDENCE), "matching but false workload " + field
        )
    for name in ("first", "later"):
        altered = copy.deepcopy(receipts[1])
        altered[name]["totals"]["transactionCount"] += 1
        refused(altered, lambda r: candidate_matches(r, receipts[1]), "candidate count")
    altered = copy.deepcopy(receipts[1])
    altered["first"]["transactions"][0]["outputs"][0]["referenceScript"]["hash"] = (
        "0" * 56
    )
    refused(altered, lambda r: candidate_matches(r, receipts[1]), "candidate script")
    altered = copy.deepcopy(receipts[1])
    altered["later"]["liveReferenceScriptsBefore"][0]["referenceScript"]["hash"] = (
        "0" * 56
    )
    refused(
        altered, lambda r: candidate_matches(r, receipts[1]), "candidate reused script"
    )
    altered = copy.deepcopy(receipts[1])
    altered["schema"] = "unrecognised"
    refused(altered, lambda r: candidate_matches(r, receipts[1]), "candidate schema")
    varied_fees = copy.deepcopy(receipts[1])
    for name in ("first", "later"):
        for transaction in varied_fees[name]["transactions"]:
            transaction["feeLovelace"] += 1
        varied_fees[name]["totals"]["feesLovelace"] += len(
            varied_fees[name]["transactions"]
        )
    candidate_matches(varied_fees, receipts[1])
    rendered = page(receipts)
    altered_page = rendered.replace(
        str(receipts[0]["first"]["totals"]["feesLovelace"]), "altered", 1
    )
    require(altered_page != rendered, "page alteration control did not apply")
    refused(
        altered_page, lambda text: page_matches(text, receipts), "altered page figure"
    )
    print(
        f"creation-cost: {count} altered figures, mismatched legs and candidate changes refused; different live fees allowed"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    capture_parser = subcommands.add_parser("capture")
    for name in ("manifest", "source", "output"):
        capture_parser.add_argument("--" + name, required=True)
    subcommands.add_parser("check")
    subcommands.add_parser("controls")
    subcommands.add_parser("render")
    subcommands.add_parser("receipts")
    live_parser = subcommands.add_parser("candidate")
    live_parser.add_argument("receipt")
    journey_parser = subcommands.add_parser("journey")
    for name in ("work", "source", "program", "blueprint", "devnet", "reference"):
        journey_parser.add_argument("--" + name, required=True)
    arguments = parser.parse_args()
    if arguments.command == "capture":
        capture(arguments)
    elif arguments.command == "journey":
        journey(arguments)
    elif arguments.command == "candidate":
        measured = json.loads(Path(arguments.receipt).read_text())
        recompute(measured, Path(arguments.receipt).parent)
        candidate_matches(measured, load_pair()[1])
        print("creation-cost: candidate transaction counts and script hashes agree")
    else:
        receipts = pair(load_pair(), EVIDENCE)
        carrying_checker, carrying = load_carrying(receipts)
        if arguments.command == "render":
            print(page(receipts), end="")
        elif arguments.command == "controls":
            controls(receipts)
            carrying_checker["controls"](carrying, EVIDENCE, receipts[1], globals())
        elif arguments.command == "receipts":
            print("creation-cost: all receipt figures were recomputed from chain bytes")
        else:
            page_matches(Path("docs/creation-cost.md").read_text(), receipts)
            print(
                "creation-cost: both receipts agree with chain bytes, each other and the page"
            )


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, AssertionError) as error:
        sys.exit(f"creation-cost: {error}")
