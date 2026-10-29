#!/usr/bin/env python3
"""Compare a measurement node with the recorded target's limits and prices.

The development node retains its own execution model. Only evaluation under
the recorded preprod parameters can decide the target's batch limit.
"""

import copy
import datetime
import hashlib
import json
import re
import runpy
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path


BOUNDING_FIELDS = (
    "maxTxSize",
    "maxTxExecutionUnits",
    "executionUnitPrices",
    "txFeeFixed",
    "txFeePerByte",
    "utxoCostPerByte",
    "minFeeRefScriptCostPerByte",
    "maxCollateralInputs",
    "collateralPercentage",
    "maxValueSize",
)


def differences(target, node):
    return [
        {"parameter": field, "target": target[field], "node": node.get(field)}
        for field in BOUNDING_FIELDS
        if target[field] != node.get(field)
    ]


def derive_genesis(source, original, destination):
    target = json.loads(json.loads(Path(source).read_text())["answer"]["body"])
    shutil.copytree(original, destination)
    Path(destination).chmod(0o700)
    changes = []
    patches = {
        "shelley-genesis.json": {
            "protocolParams": {
                "minFeeA": target["txFeePerByte"],
                "minFeeB": target["txFeeFixed"],
                "maxTxSize": target["maxTxSize"],
            }
        },
        "alonzo-genesis.json": {
            "maxTxExUnits": target["maxTxExecutionUnits"],
            "executionPrices": target["executionUnitPrices"],
            "maxCollateralInputs": target["maxCollateralInputs"],
            "collateralPercentage": target["collateralPercentage"],
            "maxValueSize": target["maxValueSize"],
            "lovelacePerUTxOWord": target["utxoCostPerByte"] * 8,
        },
        "conway-genesis.json": {
            "minFeeRefScriptCostPerByte": target["minFeeRefScriptCostPerByte"]
        },
    }
    for name, fields in patches.items():
        path = Path(destination) / name
        before = json.loads(path.read_text())
        after = copy.deepcopy(before)
        for field, value in fields.items():
            if field == "protocolParams":
                after[field].update(value)
            else:
                after[field] = value
        path.chmod(0o600)
        path.write_text(json.dumps(after, indent=2) + "\n")
        changes.append({"file": name, "before": before, "after": after})
    # The execution model stays the generated node's; it cannot parse the
    # recorded target model. The target evaluator is a separate obligation.
    Path(destination, "parameter-derivation.json").write_text(
        json.dumps(changes, sort_keys=True, indent=2) + "\n"
    )


def check_parameters(source, provider, output):
    recorded = json.loads(Path(source).read_text())
    target = json.loads(recorded["answer"]["body"])
    with urllib.request.urlopen(provider + "/cli_protocol_params", timeout=60) as reply:
        node = json.load(reply)
    # The control first restores all compared fields, then changes one real
    # parameter. This proves a permissive comparator cannot pass the job.
    equal = copy.deepcopy(node)
    equal.update({field: target[field] for field in BOUNDING_FIELDS})
    assert not differences(target, equal)
    changed = copy.deepcopy(equal)
    changed["maxTxExecutionUnits"]["memory"] += 1
    assert differences(target, changed), "altered node memory was not refused"
    report = {
        "target": target,
        "node": node,
        "sourceDate": dict(recorded["answer"]["headers"])["date"],
        "differences": differences(target, node),
        "control": "an altered node memory limit is refused",
    }
    Path(output).write_text(json.dumps(report, sort_keys=True, indent=2) + "\n")
    for item in report["differences"]:
        print(json.dumps(item, sort_keys=True), file=sys.stderr)
    assert not report["differences"], "the node's bounding parameters differ"


def builder_capacity(path):
    answer = json.loads(Path(path).read_text())
    match = re.fullmatch(
        r"the (transaction size|execution memory|execution steps) (\d+)(?: bytes)? "
        r"exceeds? the limit (\d+)(?: bytes)?",
        answer.get("reason", ""),
    )
    assert answer["outcome"] == "client-refusal"
    assert not answer.get("submissions", [])
    assert not answer.get("bundle", {}).get("transactions", [])
    assert match and int(match[2]) > int(match[3]), "not a measured capacity refusal"


def included(source, identity, transaction):
    observed = []
    for line in Path(source).read_text().splitlines():
        event = json.loads(line)
        if event.get("kind") == "chain-sync-full-block":
            observed.extend(
                bytes.fromhex(tx["cbor"])
                for tx in event["block"]["transactions"]
                if tx["material"]["tx_hash"] == identity
            )
    assert observed == [Path(transaction).read_bytes()], "included bytes differ"


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def transaction_identity(path):
    raw = Path(path).read_bytes()
    decoder = runpy.run_path(str(Path(__file__).with_name("no_pin_chain_view.py")))[
        "decode"
    ]
    assert raw[0] == 0x84, "not a four-field Conway transaction"
    _, body_end = decoder(raw, 1)
    return hashlib.blake2b(raw[1:body_end], digest_size=32).hexdigest()


def datum_shapes(packet, measured):
    reader = runpy.run_path(str(Path(__file__).with_name("no_pin_chain_view.py")))
    inputs, _ = reader["decode"]((packet / "inputs.cbor").read_bytes())
    outputs = {
        f"{reference[0].hex()}#{reference[1]}": output for reference, output in inputs
    }

    def shape(data):
        if isinstance(data, bytes):
            return {"bytes": len(data)}
        if isinstance(data, int):
            return "integer"
        if isinstance(data, list):
            return [shape(item) for item in data]
        if data[0] == "constr":
            return {"constructor": data[1], "fields": [shape(item) for item in data[2]]}
        assert data[0] == "map", "unknown datum structure"
        return {"map": [[shape(key), shape(value)] for key, value in data[1]]}

    result = []
    for changed in measured["changes"]:
        if changed["kind"] == "termination":
            result.append(None)
            continue
        option = reader["get"](outputs[changed["pending"]], 2)
        assert option[0] == 1, "registration does not carry inline data"
        datum, _ = reader["decode"](option[1])
        assert datum[:2] == ("constr", 1)
        fields = datum[2][0]
        assert fields[:2] == ("constr", 0)
        result.append(shape(fields[2][5]))
    return result


def evaluated(harness, parameters, packet):
    return json.loads(
        subprocess.check_output(
            [harness, "evaluate-batch", parameters, str(packet)], timeout=300
        )
    )


def pool(kind, material):
    material = Path(material)
    receipts = [
        json.loads(path.read_text())
        for path in sorted((material / "receipts").glob(f"{kind}-book-*.json"))
    ]
    assert receipts and all(row["outcome"] == "success" for row in receipts)
    assert len({row["pending"] for row in receipts}) == len(receipts)
    (material / "pools").mkdir(exist_ok=True)
    (material / "pools" / (kind + ".json")).write_text(
        json.dumps(receipts, sort_keys=True, indent=2) + "\n"
    )


def builder_summary(raw):
    result = {
        key: raw[key] for key in ("command", "outcome", "reason", "left") if key in raw
    }
    if "bundle" in raw:
        result["bundle"] = {key: raw["bundle"][key] for key in ("hash", "transactions")}
    folded = raw.get("expected", raw).get("folded")
    if folded is not None:
        result["folded"] = folded
    return result


def booking_summary(raw):
    return {
        key: raw[key]
        for key in ("command", "outcome", "pending", "submissions", "treasuryDonation")
        if key in raw
    }


def observations(material):
    material = Path(material)
    return {
        "node": {
            "version": (material / "node-version.txt").read_text().strip(),
            "parameters": json.loads((material / "node-parameters.json").read_text())[
                "node"
            ],
        },
        "bookings": {
            path.stem: [booking_summary(row) for row in json.loads(path.read_text())]
            for path in sorted((material / "pools").glob("*.json"))
        },
        "nodeAnswers": {
            path.parent.name: json.loads(path.read_text())
            for path in sorted((material / "packets").glob("*/node.json"))
        },
    }


def claim(harness, parameters, source, blueprint, material):
    material = Path(material)
    report = json.loads((material / "node-parameters.json").read_text())
    target = json.loads(json.loads(Path(source).read_text())["answer"]["body"])
    assert report["target"] == target and not differences(target, report["node"])
    release = json.loads(subprocess.check_output([harness, "batch-release", blueprint]))
    result = {
        "target": {
            "source": "offchain/test/fixtures/koios/preprod/cli_protocol_params-b777448425778d13.json",
            "recordingDate": report["sourceDate"],
            "sourceSha256": digest(source),
            "parametersSha256": digest(parameters),
            "parameters": target,
        },
        "scripts": release,
        "workloads": {},
        "limitsOfThisMeasurement": [
            "Transaction evaluation under preprod parameters recorded on the stated date, corroborated by a development node; no preprod submission.",
            "Protocol parameters can change by governance.",
            "Transaction slots use the retained development network's time; this is phase-two evaluation, not preprod phase-one validation.",
            "No claim for another registry size, trie depth, scripts, key or payload shapes, or parameters.",
        ],
        "refreshCommand": "nix run .#no-pin-batch-measurement -- --refresh test/fixtures/batch-measurement",
    }
    for kind in ("registrations", "terminations", "mixed"):
        booked = json.loads((material / "pools" / (kind + ".json")).read_text())
        packets = sorted(
            (material / "packets").glob(kind + "-*"),
            key=lambda path: int(path.name.rsplit("-", 1)[1]),
        )
        assert len(packets) > 1, "no accepted/refused pair"
        samples = []
        previous = {
            metric: 0 for metric in ("memory", "steps", "serializedBytes", "fee")
        }
        for count, packet in enumerate(packets, 1):
            assert packet.name == f"{kind}-{count}", "missing measured size"
            measured = evaluated(harness, parameters, packet)
            assert measured == json.loads((packet / "evaluation.json").read_text()), (
                "kept evaluation figures differ from re-evaluation"
            )
            assert (
                measured["parameters"]["protocolVersion"] == target["protocolVersion"]
            )
            assert (
                measured["parameters"]["costModels"]["PlutusV3"]
                == target["costModels"]["PlutusV3"]
            )
            assert not differences(target, measured["parameters"])
            assert len(measured["changes"]) == count
            assert len({row["pending"] for row in measured["changes"]}) == count
            assert [row["pending"] for row in measured["changes"]] == [
                row["pending"] for row in booked[:count]
            ], "measured inputs differ from the named workload prefix"
            assert {row["script"] for row in measured["scriptReferences"]} == set(
                release.values()
            )
            assert len(measured["scriptReferences"]) == len(release)
            assert measured["memory"] == sum(
                row["memory"] for row in measured["purposes"]
            )
            assert measured["steps"] == sum(
                row["steps"] for row in measured["purposes"]
            )
            assert (
                measured["serializedBytes"]
                == (packet / "transaction.cbor").stat().st_size
            )
            kinds = {row["kind"] for row in measured["changes"]}
            assert kinds <= (
                {"registration"}
                if kind == "registrations"
                else {"termination"}
                if kind == "terminations"
                else {"registration", "termination"}
            )
            assert (
                not measured["exceeded"]
                if count < len(packets)
                else measured["exceeded"]
            )
            preparation = json.loads((packet / "preparation.json").read_text())
            assert preparation["foldedCount"] == count
            assert preparation["transaction"] == transaction_identity(
                packet / "transaction.cbor"
            )
            per_request, marginal = {}, {}
            for metric in previous:
                value = measured[metric]
                per_request[metric] = {"numerator": value, "denominator": count}
                marginal[metric] = value - previous[metric]
                previous[metric] = value
            sample = {
                "count": count,
                "measurement": measured,
                "perRequest": per_request,
                "marginalLastRequest": marginal,
                "registrySizeBefore": preparation["registrySizeBefore"],
                "bytes": {
                    str(path.relative_to(packet)): digest(path)
                    for path in sorted(packet.rglob("*.cbor"))
                },
                "timeManifestSha256": digest(packet / "time/time-manifest.json"),
                "time": json.loads((packet / "time/time-manifest.json").read_text()),
                "builder": builder_summary(
                    json.loads((packet / "builder.json").read_text())
                ),
                "initialDatumShapes": datum_shapes(packet, measured),
            }
            if count >= len(packets) - 1:
                answer = json.loads((packet / "node.json").read_text())
                assert answer["transaction"] == preparation["transaction"]
                expected = "accepted" if count < len(packets) else "refused"
                assert answer["outcome"] == expected, (
                    "node disagrees with target evaluation"
                )
                if expected == "refused":
                    assert any(
                        name in answer["answer"]
                        for name in ("ExUnitsTooBigUTxO", "MaxTxSizeUTxO")
                    ), "node refusal is not a capacity rule"
            samples.append(sample)
        assert kind != "mixed" or {
            row["kind"] for row in samples[-2]["measurement"]["changes"]
        } == {"registration", "termination"}
        assert len(booked) > len(samples) - 1, "pool does not exceed the boundary"
        result["workloads"][kind] = {
            "largestAccepted": len(samples) - 1,
            "poolSize": len(booked),
            "samples": samples,
        }
    return result


def compare(expected, actual):
    assert expected == actual, "committed claim differs from re-evaluation"


def compare_scripts(expected, actual):
    assert expected == actual, (
        "committed script hashes differ from the current blueprint"
    )


def compare_boundaries(kept, fresh):
    for kind, original in kept["workloads"].items():
        current = fresh["workloads"][kind]
        assert original["largestAccepted"] == current["largestAccepted"], (
            "fresh count boundary differs"
        )
        assert current["samples"][-1]["measurement"]["exceeded"], "fresh next size fits"
        assert not current["samples"][-2]["measurement"]["exceeded"], (
            "fresh accepted size exceeds a limit"
        )


def workload_shape(workload):
    fields = (
        "kind",
        "key",
        "keyBytes",
        "heldLovelace",
        "protectedDeposit",
        "folderTake",
        "datumBytes",
        "initialDatumBytes",
    )
    return {
        "poolSize": workload["poolSize"],
        "samples": [
            {
                "count": sample["count"],
                "registrySizeBefore": sample["registrySizeBefore"],
                "initialDatumShapes": sample["initialDatumShapes"],
                "changes": [
                    {field: changed[field] for field in fields}
                    for changed in sample["measurement"]["changes"]
                ],
            }
            for sample in workload["samples"]
        ],
    }


def must_refuse(function, *arguments):
    try:
        function(*arguments)
    except AssertionError:
        return
    raise AssertionError("the altered observation passed its guard")


def controls(expected):
    # Exercise the same complete comparison CI uses, changing each published
    # metric in turn; originals are always obtained from the actual evaluator.
    caught = 0
    for kind in expected["workloads"]:
        for metric in ("memory", "steps", "serializedBytes", "fee"):
            changed = copy.deepcopy(expected)
            changed["workloads"][kind]["samples"][0]["measurement"][metric] += 1
            assert changed != expected
            try:
                compare(expected, changed)
            except AssertionError:
                caught += 1
            else:
                raise AssertionError("an altered committed figure passed")
    changed = copy.deepcopy(expected["scripts"])
    key = sorted(changed)[0]
    match = re.search(r"[0-9a-f]{56}", changed[key])
    assert match, "no actual script hash to alter"
    altered = match[0][:-1] + ("0" if match[0][-1] != "0" else "1")
    changed[key] = changed[key][: match.start()] + altered + changed[key][match.end() :]
    assert changed != expected["scripts"]
    compare_scripts(expected["scripts"], expected["scripts"])
    must_refuse(compare_scripts, expected["scripts"], changed)
    return {"alteredFigures": caught, "alteredScriptHash": 1}


def revalidate(harness, parameters, source, blueprint, committed, output):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=False)
    first = claim(harness, parameters, source, blueprint, committed)
    second = claim(harness, parameters, source, blueprint, committed)
    first_bytes = json.dumps(first, sort_keys=True, separators=(",", ":"))
    second_bytes = json.dumps(second, sort_keys=True, separators=(",", ":"))
    assert first_bytes == second_bytes, "claim fields vary across two re-evaluations"
    (output / "remeasured.json").write_text(first_bytes + "\n")
    stored = json.loads(Path(committed, "receipt.json").read_text())
    compare_scripts(first["scripts"], stored["claim"]["scripts"])
    compare(first, stored["claim"])
    count = controls(first)
    print(f"recorded-parameter re-evaluation: identical runs; refused controls {count}")


def refresh(harness, parameters, source, blueprint, material, destination):
    material = Path(material)
    first = claim(harness, parameters, source, blueprint, material)
    second = claim(harness, parameters, source, blueprint, material)
    compare(first, second)
    controls(first)
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    for name in ("node-parameters.json", "node-version.txt"):
        shutil.copyfile(material / name, destination / name)
    for name in ("packets", "pools"):
        if (destination / name).exists():
            assert (destination / "receipt.json").is_file(), (
                "refusing to replace an unrecognized capture directory"
            )
            shutil.rmtree(destination / name)
        shutil.copytree(material / name, destination / name)
    for path in (destination / "packets").glob("*/builder.json"):
        path.write_text(
            json.dumps(
                builder_summary(json.loads(path.read_text())), sort_keys=True, indent=2
            )
            + "\n"
        )
    for path in (destination / "pools").glob("*.json"):
        path.write_text(
            json.dumps(
                [booking_summary(row) for row in json.loads(path.read_text())],
                sort_keys=True,
                indent=2,
            )
            + "\n"
        )
    (destination / "receipt.json").write_text(
        json.dumps(
            {
                "claim": first,
                "captureObservations": observations(material),
                "fieldMeaning": {
                    "claim": "The exact kept transactions, their captured context and their evaluation under the recorded parameters; repeated re-evaluations must be byte-identical.",
                    "captureObservations": "A fresh capture's node answers and identifiers; figures from another capture may vary. The hosted job requires the same count boundary and reports the exact variation.",
                },
                "runMetadata": {
                    "recordedAt": datetime.datetime.now(
                        datetime.timezone.utc
                    ).isoformat()
                },
            },
            sort_keys=True,
            indent=2,
        )
        + "\n"
    )
    print(f"explicitly refreshed {destination}; no preprod submission")


def fresh_result(harness, parameters, source, blueprint, material, output):
    kept = json.loads(Path(output, "kept/remeasured.json").read_text())
    fresh = claim(harness, parameters, source, blueprint, material)
    compare_scripts(kept["scripts"], fresh["scripts"])
    assert kept["target"] == fresh["target"], "fresh parameter source differs"
    compare_boundaries(kept, fresh)
    variations = {}
    for kind, original in kept["workloads"].items():
        current = fresh["workloads"][kind]
        assert workload_shape(original) == workload_shape(current), (
            "fresh workload shape differs"
        )
        variations[kind] = [
            {
                "count": before["count"],
                "kept": {
                    metric: before["measurement"][metric]
                    for metric in ("memory", "steps", "serializedBytes", "fee")
                },
                "fresh": {
                    metric: after["measurement"][metric]
                    for metric in ("memory", "steps", "serializedBytes", "fee")
                },
                "difference": {
                    metric: after["measurement"][metric] - before["measurement"][metric]
                    for metric in ("memory", "steps", "serializedBytes", "fee")
                },
            }
            for before, after in zip(
                original["samples"], current["samples"], strict=True
            )
        ]
        changed = copy.deepcopy(kept)
        changed["workloads"][kind]["largestAccepted"] += 1
        assert changed != kept
        must_refuse(compare_boundaries, changed, fresh)
    result = {
        "claim": kept,
        "runObservations": {
            **observations(material),
            "freshEvaluation": fresh,
            "observedVariation": variations,
        },
        "fieldMeaning": {
            "claim": "The exact kept transactions and their reproducible evaluation under the recorded parameters.",
            "runObservations": "A fresh capture, its node answers and exact figure differences; the count boundaries and workload shape must agree, figures may vary.",
        },
        "controls": {"offByOneCommittedCount": len(variations)},
    }
    Path(output, "receipt.json").write_text(
        json.dumps(result, sort_keys=True, indent=2) + "\n"
    )
    print(
        "fresh node capture: same count boundaries; exact figure differences recorded as observed variation; off-by-one controls refused"
    )


def run_result(output, status):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    status = int(status)
    result = {
        "exitCode": status,
        "completed": status == 0,
        "receiptAvailable": (output / "receipt.json").is_file(),
        "evaluatedPackets": len(list(output.glob("fresh/packets/*/evaluation.json"))),
    }
    (output / "run.json").write_text(
        json.dumps(result, sort_keys=True, indent=2) + "\n"
    )
    assert status or result["receiptAvailable"], (
        "successful run did not write its measurement receipt"
    )
    if status:
        (output / "receipt.json").write_text(
            json.dumps(
                {"claim": None, "runObservations": result}, sort_keys=True, indent=2
            )
            + "\n"
        )


if __name__ == "__main__":
    commands = {
        "derive": derive_genesis,
        "builder-capacity": builder_capacity,
        "included": included,
        "pool": pool,
        "revalidate": revalidate,
        "refresh": refresh,
        "fresh-result": fresh_result,
        "run-result": run_result,
    }
    if sys.argv[1] in commands:
        commands[sys.argv[1]](*sys.argv[2:])
    else:
        check_parameters(*sys.argv[1:])
