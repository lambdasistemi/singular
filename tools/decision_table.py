#!/usr/bin/env python3
"""Render the release decision table from the kept creation and batch receipts.

Obligation: the check and the controls are run by docs-check in the documentation
job. Every figure on the page is read from a kept receipt, and every row names the
receipts it was read from with their SHA-256; a row without a source receipt, or a
page that differs from what the receipts give, is refused.
"""

import argparse
import hashlib
import json
import re
import sys
from fractions import Fraction
from pathlib import Path

CREATION_DIRECTORY = "specs/745-shared-publications/evidence"
CREATION = {
    "previous": CREATION_DIRECTORY + "/previous.json",
    "candidate": CREATION_DIRECTORY + "/candidate.json",
}
BATCH = "test/fixtures/batch-measurement/receipt.json"
# The receipt this one replaced, kept as history beside it.
BATCH_EARLIER = "test/fixtures/batch-measurement/previous/receipt.json"
# The receipts before that one, oldest first: kept unchanged, hashed on the page, and
# not compared with anything.
BATCH_HISTORY = (
    "test/fixtures/batch-measurement/history/preprod-2026-10-04/receipt.json",
)
PAGE = "docs/release-decision-table.md"
REPOSITORY = "https://github.com/lambdasistemi/singular/blob/main/"
KINDS = ("registrations", "terminations", "mixed")
BATCH_NAMES = {
    "registrations": "batch of registrations",
    "terminations": "batch of terminations",
    "mixed": "mixed batch of registrations and terminations",
}
BATCH_METRICS = (
    ("memory", "execution memory", ""),
    ("steps", "execution steps", ""),
    ("serializedBytes", "signed transaction bytes", ""),
    ("fee", "fee", " lovelace"),
)
CREATION_TOTALS = (
    ("transactionCount", "transactions sent", ""),
    ("transactionBytes", "transaction bytes", ""),
    ("outputsCreated", "outputs created", ""),
    ("feesLovelace", "fees", " lovelace"),
    ("referenceOutputsCreated", "reference outputs created", ""),
    ("referenceScriptsBytes", "reference script bytes", ""),
    ("referenceAdaLockedLovelace", "ADA locked in reference outputs", " lovelace"),
)
# These are part of the totals above; they are listed on their own line so that
# nobody adds them twice.
CREATION_WITNESS = (
    ("witnessPublicationTransactions", "transactions", ""),
    ("witnessPublicationFeesLovelace", "fees", " lovelace"),
    (
        "witnessPublicationAdaLockedLovelace",
        "ADA locked in reference outputs",
        " lovelace",
    ),
)


CREATING_TRANSACTION = (
    ("sizeBytes", "registry-creating transaction bytes", ""),
    ("feeLovelace", "registry-creating transaction fee", " lovelace"),
)


class Refusal(Exception):
    """The page, a receipt or a row does not meet the rule that binds it."""


def require(condition, message):
    if not condition:
        raise Refusal(message)


class Receipt:
    def __init__(self, name, raw):
        self.name = name
        self.sha256 = hashlib.sha256(raw).hexdigest()
        self.value = json.loads(raw)

    def source(self):
        return (self.name, self.sha256)


class ChainRecord(Receipt):
    """The chain record a creation receipt names; it dates the parameters."""

    def __init__(self, name, raw, expected):
        require(
            hashlib.sha256(raw).hexdigest() == expected,
            f"the chain record {name} differs from the hash its receipt names",
        )
        self.name = name
        self.sha256 = expected
        # A cheap filter before parsing; the parsed event decides.
        events = (
            json.loads(line)
            for line in raw.decode().splitlines()
            if "http-ledger-exchange" in line and "cli_protocol_params" in line
        )
        self.parameter_reads = [
            event["observedAt"]
            for event in events
            if event["kind"] == "http-ledger-exchange"
            and event["path"] == "/api/v1/cli_protocol_params"
        ]
        require(
            self.parameter_reads, f"the chain record {name} holds no parameter read"
        )


class Recording(Receipt):
    """The preprod parameter recording a batch receipt names; it dates them."""

    def __init__(self, root, batch):
        target = batch.value["claim"]["target"]
        name = target["source"]
        path = Path(root) / name
        require(path.is_file(), f"source recording missing: {name}")
        raw = path.read_bytes()
        require(
            hashlib.sha256(raw).hexdigest() == target["sourceSha256"],
            f"the recording {name} differs from the hash its receipt names",
        )
        super().__init__(name, raw)
        answer = self.value["answer"]
        date = dict(answer["headers"])["date"]
        require(
            date == target["recordingDate"],
            f"the recording {name} was made on {date}, not on the date its receipt names",
        )
        require(
            json.loads(answer["body"]) == target["parameters"],
            f"the recording {name} holds other parameters than its receipt names",
        )


def read_receipt(root, name):
    path = Path(root) / name
    require(path.is_file(), f"source receipt missing: {name}")
    return Receipt(name, path.read_bytes())


def read_chain_record(root, receipt):
    name = (Path(receipt.name).parent / receipt.value["chainRecord"]).as_posix()
    path = Path(root) / name
    require(path.is_file(), f"source receipt missing: {name}")
    return ChainRecord(name, path.read_bytes(), receipt.value["chainRecordSha256"])


def link(name):
    return f"[`{name}`]({REPOSITORY}{name})"


def plural(number, word):
    return f"{number} {word}" + ("" if number == 1 else "s")


def moved(before, after, unit):
    return f"{before} to {after}{unit}"


def compare(entries):
    """Split (label, before, after, unit) entries into gains and regressions.

    Every compared figure is a cost: lower is better, higher is worse, equal is
    neither.
    """
    gains, regressions = [], []
    for label, before, after, unit in entries:
        left, right = Fraction(before), Fraction(after)
        if right < left:
            gains.append(f"{label}: {moved(before, after, unit)}")
        elif right > left:
            regressions.append(f"{label}: {moved(before, after, unit)}")
    return gains, regressions


def cell(items, none="none measured"):
    return "<br>".join(items) if items else none


def creating_transaction(creation):
    found = [t for t in creation["transactions"] if t["step"] in ("boot", "create")]
    require(len(found) == 1, "a creation has no unique registry-creating transaction")
    return found[0]


def creation_requirements(previous, candidate):
    for receipt, design in ((previous, "previous"), (candidate, "candidate")):
        value = receipt.value
        require(
            value.get("schema") == "creation-cost-v1" and value["design"] == design,
            f"{receipt.name} is not the {design} creation receipt",
        )
    for field in ("application", "network", "workload", "tools"):
        require(
            previous.value[field] == candidate.value[field],
            f"the creation receipts differ in {field}",
        )


def to_second(timestamp):
    return timestamp.partition(".")[0].rstrip("Z") + "Z"


def read_times(chains):
    stamps = [to_second(min(chain.parameter_reads)) for chain in chains]
    if stamps[0] == stamps[1]:
        return f"{stamps[0]} for both designs"
    return f"{stamps[0]} for the previous design and {stamps[1]} for the application-held design"


def short_node(version):
    return version.splitlines()[0].split(" - ")[0]


def creation_rows(previous, candidate, chains):
    creation_requirements(previous, candidate)
    network = previous.value["network"]["protocolParameters"]
    workload = previous.value["workload"]
    node = short_node(previous.value["tools"]["cardanoNode"])
    release = {
        design: receipt.value["first"]["release"]["version"]
        for design, receipt in (("previous", previous), ("candidate", candidate))
    }
    rows = []
    for name, wording in (
        ("first", "a first registry, with no live copy of its scripts"),
        ("later", "a later registry, with the earlier shared copies live"),
    ):
        before, after = previous.value[name], candidate.value[name]
        live = (
            len(before["liveReferenceScriptsBefore"]),
            len(after["liveReferenceScriptsBefore"]),
        )
        require(
            (live == (0, 0)) == (name == "first")
            and (min(live) > 0) == (name == "later"),
            f"the {name} creation does not start as its row says",
        )
        gains, regressions = compare(
            [
                (label, before["totals"][key], after["totals"][key], unit)
                for key, label, unit in CREATION_TOTALS
            ]
        )
        included, _ = compare(
            [
                (label, before["totals"][key], after["totals"][key], unit)
                for key, label, unit in CREATION_WITNESS
            ]
        )
        if included:
            gains.append("of which, included above: " + "; ".join(included))
        _, creating = compare(
            [
                (
                    label,
                    creating_transaction(before)[key],
                    creating_transaction(after)[key],
                    unit,
                )
                for key, label, unit in CREATING_TRANSACTION
            ]
        )
        regressions.extend(creating)
        headline = (
            f"Creating {wording.partition(',')[0]} takes "
            f"{plural(after['totals']['transactionCount'], 'transaction')} under the "
            f"application-held design against {before['totals']['transactionCount']} "
            "under the previous design."
        )
        if regressions:
            headline += " What rose: " + "; ".join(regressions) + "."
        rows.append(
            {
                "headline": headline,
                "measurement": f"Creating {wording}: transactions, bytes, fees and "
                "capital locked, previous design against application-held design",
                "parameters": "<br>".join(
                    [
                        "Development network; protocol parameters read from its chain at "
                        f"{read_times(chains)}: "
                        f"maximum transaction size {network['maxTxSize']} bytes, "
                        f"memory {network['maxTxExecutionUnits']['memory']}, "
                        f"steps {network['maxTxExecutionUnits']['steps']}, "
                        f"fee per byte {network['txFeePerByte']}, "
                        f"fixed fee {network['txFeeFixed']}",
                        f"Node: {node}",
                        f"Previous design: {release['previous']}",
                        f"Application-held design: {release['candidate']}",
                        f"Live script copies before the creation: {live[0]} with the "
                        f"previous design, {live[1]} with the application-held design",
                        f"Workload: {workload['fundingOutputs']} funding outputs of "
                        f"{workload['fundingLovelacePerOutput']} lovelace, processing window "
                        f"{workload['processingMilliseconds']} ms, reclaiming window "
                        f"{workload['reclaimingMilliseconds']} ms",
                    ]
                ),
                "gain": "Previous design to application-held design:<br>" + cell(gains),
                "regression": cell(regressions),
                "unmeasured": cell(
                    [
                        "Fees and limits of any other network: the receipts are from a development network",
                        "Variation between runs: each design is one captured run",
                    ]
                ),
                "sources": [
                    previous.source(),
                    chains[0].source(),
                    candidate.source(),
                    chains[1].source(),
                ],
            }
        )
    return rows


def script_hashes(scripts):
    found = {}
    for name, value in sorted(scripts.items()):
        match = re.search(r"[0-9a-f]{56}", value)
        require(match, f"no script hash for the {name} script")
        found[name] = match[0]
    return found


def bracket(claim, kind):
    """The largest accepted sample, the next refused one and the one-request fold."""
    workload = claim["workloads"][kind]
    largest = workload["largestAccepted"]
    samples = workload["samples"]
    accepted, refused, single = samples[largest - 1], samples[largest], samples[0]
    require(
        accepted["count"] == largest
        and refused["count"] == largest + 1
        and single["count"] == 1
        and not accepted["measurement"]["exceeded"]
        and refused["measurement"]["exceeded"],
        f"the {kind} samples do not bracket the largest accepted batch",
    )
    return largest, accepted, refused, single


def batch_rows(receipt):
    claim = receipt.value["claim"]
    target = claim["target"]
    parameters = target["parameters"]
    observed = receipt.value["captureObservations"]
    node = short_node(observed["node"]["version"])
    scripts = script_hashes(claim["scripts"])
    rows = []
    for kind in KINDS:
        workload = claim["workloads"][kind]
        largest, accepted, refused, single = bracket(claim, kind)
        answers = (
            observed["nodeAnswers"][f"{kind}-{largest}"]["outcome"],
            observed["nodeAnswers"][f"{kind}-{largest + 1}"]["outcome"],
        )
        require(
            answers == ("accepted", "refused"),
            f"the development node does not agree with the {kind} boundary",
        )
        gains, regressions = [], []
        for key, label, unit in BATCH_METRICS:
            total, alone = accepted["measurement"][key], single["measurement"][key]
            sentence = (
                f"{label} per request: {total}/{largest}{unit} in the largest batch "
                f"against {alone}{unit} in a one-request fold"
            )
            if Fraction(total, largest) < alone:
                gains.append(sentence)
            elif Fraction(total, largest) > alone:
                regressions.append(sentence)
        changes = accepted["measurement"]["changes"]
        order = ", ".join(change["kind"] for change in changes)
        unmeasured = list(claim["limitsOfThisMeasurement"])
        unmeasured.append(
            "Folding the same requests one at a time in separate transactions: the "
            "comparison is with the one-request fold from the same starting registry"
        )
        if kind == "mixed":
            unmeasured.append(
                "Any order of registrations and terminations other than this one: "
                + order
            )
        against = "Against a one-request fold of the same workload from the same registry:<br>"

        def labels(items):
            return " and ".join(item.partition(" per request:")[0] for item in items)

        headline = (
            f"The largest accepted fold in the {kind} workload carries {largest} requests, "
            f"and one more request exceeds the {' and '.join(refused['measurement']['exceeded'])} limit."
        )
        if gains:
            headline += f" Per request the largest batch costs less than a one-request fold in {labels(gains)}"
            headline += f" and more in {labels(regressions)}." if regressions else "."
        elif regressions:
            headline += f" Per request the largest batch costs more than a one-request fold in {labels(regressions)}."
        rows.append(
            {
                "headline": headline,
                "measurement": f"Largest {BATCH_NAMES[kind]} one fold carries: {largest} "
                f"accepted, {largest + 1} exceed the {', '.join(refused['measurement']['exceeded'])} limit",
                "parameters": "<br>".join(
                    [
                        f"Preprod protocol parameters recorded {target['recordingDate']}: "
                        f"maximum transaction memory {parameters['maxTxExecutionUnits']['memory']}, "
                        f"steps {parameters['maxTxExecutionUnits']['steps']}, "
                        f"size {parameters['maxTxSize']} bytes",
                        "Evaluated by the ledger evaluator under those parameters; the "
                        f"development node {node} {answers[0]} the batch of {largest} and "
                        f"{answers[1]} the batch of {largest + 1}",
                        "Revision: the receipt records none; the applied scripts are "
                        + " and ".join(
                            f"{name} `{value}`" for name, value in scripts.items()
                        ),
                        f"Registry before the fold: {accepted['registrySizeBefore']} entries; "
                        f"pending pool {workload['poolSize']}; key bytes "
                        + ", ".join(
                            str(n) for n in sorted({c["keyBytes"] for c in changes})
                        ),
                    ]
                ),
                "gain": against + cell(gains),
                "regression": against + cell(regressions),
                "unmeasured": cell(unmeasured),
                "sources": [receipt.source()],
            }
        )
    return rows


def source_cell(row):
    require(
        row["sources"],
        "a row without a source receipt is refused: " + row["measurement"],
    )
    for name, sha in row["sources"]:
        require(
            name and re.fullmatch(r"[0-9a-f]{64}", sha),
            "a row without a source receipt is refused: " + row["measurement"],
        )
    return "<br>".join(
        f"{link(name)}<br>`{sha}`" for name, sha in dict.fromkeys(row["sources"])
    )


def table(rows):
    lines = [
        "| Measurement | Taken under | Gain | Regression | Not measured | Source receipt and SHA-256 |",
        "|---|---|---|---|---|---|",
    ]
    for row in rows:
        sources = source_cell(row)
        lines.append(
            "| "
            + " | ".join(
                [
                    row["measurement"],
                    row["parameters"],
                    row["gain"],
                    row["regression"],
                    row["unmeasured"],
                    sources,
                ]
            )
            + " |"
        )
    return lines


ABSENT = (None, "absent")


def shown(value):
    text = json.dumps(value, sort_keys=True, separators=(",", ":"))
    if len(text) <= 80:
        return text
    return "sha256 " + hashlib.sha256(text.encode()).hexdigest()[:16]


def batch_figures(receipt, kind):
    """Every figure of a workload that two batch receipts can be compared on."""
    largest, accepted, refused, single = bracket(receipt.value["claim"], kind)
    exceeded = refused["measurement"]["exceeded"]
    figures = {
        "requests in the largest accepted batch": (largest, str(largest)),
        "limit the next request exceeds": (exceeded, " and ".join(exceeded)),
    }
    for sample, where in (
        (accepted, "of the largest accepted batch"),
        (single, "of a one-request fold"),
    ):
        for key, label, unit in BATCH_METRICS:
            value = sample["measurement"][key]
            figures[f"{label} {where}"] = (value, f"{value}{unit}")
    return figures


def parameter_figures(receipt):
    parameters = receipt.value["claim"]["target"]["parameters"]
    return {name: (value, shown(value)) for name, value in sorted(parameters.items())}


def movement(measurement, before, after, sources, count_unchanged=False):
    """What differs between two receipts' figures, and what does not."""
    moved_before, moved_after, unchanged = [], [], []
    names = [*before, *(name for name in after if name not in before)]
    for name in names:
        old, new = before.get(name, ABSENT), after.get(name, ABSENT)
        if old[0] == new[0]:
            unchanged.append(f"{name}: {old[1]}")
        else:
            moved_before.append(f"{name}: {old[1]}")
            moved_after.append(f"{name}: {new[1]}")
    if count_unchanged and unchanged:
        unchanged = [f"{len(unchanged)} of {len(names)} parameters"]
    return {
        "measurement": measurement,
        "before": cell(moved_before, "none moved"),
        "after": cell(moved_after, "none moved"),
        "unchanged": cell(unchanged, "none"),
        "sources": sources,
    }


def movement_rows(earlier, current, recordings):
    sources = [
        earlier.source(),
        recordings[0].source(),
        current.source(),
        recordings[1].source(),
    ]
    rows = [
        movement(
            f"{BATCH_NAMES[kind].capitalize()}: the largest accepted batch and a "
            "one-request fold",
            batch_figures(earlier, kind),
            batch_figures(current, kind),
            sources,
        )
        for kind in KINDS
    ]
    rows.append(
        movement(
            "Preprod protocol parameters: every parameter of the two receipts",
            parameter_figures(earlier),
            parameter_figures(current),
            sources,
            count_unchanged=True,
        )
    )
    return rows


def recording_date(receipt):
    return receipt.value["claim"]["target"]["recordingDate"]


def measured_at(receipt):
    return to_second(receipt.value["runMetadata"]["recordedAt"])


def movement_sentences(earlier, current):
    """Say what the two receipts have in common, computed from both."""
    old, new = (r.value["claim"] for r in (earlier, current))
    differing = [
        sorted(n for n in set(a) | set(b) if a.get(n) != b.get(n))
        for a, b in (
            (old["target"]["parameters"], new["target"]["parameters"]),
            (old["scripts"], new["scripts"]),
        )
    ]
    parameters, scripts = differing
    same_bytes = old["target"]["parametersSha256"] == new["target"]["parametersSha256"]
    same_recording = old["target"]["sourceSha256"] == new["target"]["sourceSha256"]
    lines = [
        f"The earlier receipt holds parameters recorded {recording_date(earlier)}, "
        f"and its batches were measured at {measured_at(earlier)}. This receipt holds "
        f"parameters recorded {recording_date(current)}, and its batches were measured "
        f"at {measured_at(current)}."
    ]
    if not (parameters or scripts) and same_bytes:
        lines.append(
            (
                "Both receipts evaluated the same recording of "
                if same_recording
                else "Both recordings hold the same "
            )
            + f"{len(old['target']['parameters'])} protocol parameters, the same "
            "parameter bytes were evaluated and both receipts apply the same scripts, "
            "so a figure that moved comes from the new capture of the same workload, "
            "made on a fresh development node with the commands the repository held "
            "when it was captured, and not from a change of parameters or scripts."
        )
    else:
        found = []
        if parameters:
            found.append(
                "The recordings differ in these parameters: "
                + ", ".join(parameters)
                + "."
            )
        if not same_bytes:
            found.append("The parameter bytes evaluated differ.")
        if scripts:
            found.append("The applied scripts differ: " + ", ".join(scripts) + ".")
        lines.append(
            " ".join(found) + " A figure that moved can come from any of these "
            "differences as well as from the new capture."
        )
    return lines


def moves(rows, earlier, current):
    lines = [
        "| Measurement | Moved: earlier receipt, parameters recorded "
        f"{recording_date(earlier)}, measured {measured_at(earlier)} | Moved: this "
        f"receipt, parameters recorded {recording_date(current)}, measured "
        f"{measured_at(current)} | Unchanged since the earlier receipt | "
        "Source receipts and SHA-256 |",
        "|---|---|---|---|---|",
    ]
    for row in rows:
        lines.append(
            "| "
            + " | ".join(
                [
                    row["measurement"],
                    row["before"],
                    row["after"],
                    row["unchanged"],
                    source_cell(row),
                ]
            )
            + " |"
        )
    return lines


def conditions(previous, batch, earlier):
    network = previous.value["network"]
    target = batch.value["claim"]["target"]
    lines = [
        "| Condition | Value |",
        "|---|---|",
    ]
    for name, label in (
        ("shelleyGenesisSha256", "Shelley genesis SHA-256"),
        ("byronGenesisSha256", "Byron genesis SHA-256"),
        ("protocolParametersCborSha256", "protocol parameters, CBOR SHA-256"),
        ("protocolParametersSha256", "protocol parameters, JSON SHA-256"),
    ):
        lines.append(f"| Development network, {label} | `{network[name]}` |")
    before = earlier.value["claim"]["target"]
    lines += [
        f"| Earlier preprod parameters, recording date | {before['recordingDate']} |",
        f"| Earlier preprod parameters, source | {link(before['source'])} |",
        f"| Earlier preprod parameters, source SHA-256 | `{before['sourceSha256']}` |",
        f"| Preprod parameters, recording date | {target['recordingDate']} |",
        f"| Preprod parameters, source | {link(target['source'])} |",
        f"| Preprod parameters, source SHA-256 | `{target['sourceSha256']}` |",
        f"| Preprod parameters, evaluated bytes SHA-256 | `{target['parametersSha256']}` |",
    ]
    return lines


def receipts_table(receipts):
    lines = ["| Kept file | SHA-256 |", "|---|---|"]
    shown_names = set()
    for receipt in receipts:
        if receipt.name not in shown_names:
            shown_names.add(receipt.name)
            lines.append(f"| {link(receipt.name)} | `{receipt.sha256}` |")
    return lines


def history_sentences(history):
    """Say which older receipts are kept, and that nothing on the page compares them."""
    return [
        f"The receipt measured {measured_at(receipt)} under parameters recorded "
        f"{recording_date(receipt)} is kept as history: its file and its parameter "
        "recording are hashed in the table below and neither is compared with the "
        "other receipts on this page."
        for receipt, _ in history
    ]


def render(previous, candidate, batch, chains, earlier, recordings, history):
    """The whole page, a deterministic value of the kept receipts and recordings."""
    rows = creation_rows(previous, candidate, chains) + batch_rows(batch)
    date = recording_date(batch)
    lines = [
        "# Release decision table",
        "",
        "As a reader deciding whether this release's measurements support your use, you find "
        "on this page the measurements this line delivered of what creating a registry costs and "
        "of the largest batch of requests one fold carries. Each row gives the conditions it was "
        "taken under, what it improved, what it made worse and what it did not measure.",
        "",
        "```mermaid",
        "flowchart TB",
        "    creation[Creation receipts] -->|figures and SHA-256| page[This page]",
        "    batch[Batch receipt] -->|figures and SHA-256| page",
        "    earlier[Earlier batch receipt] -->|figures and SHA-256| page",
        "    kept[Kept history receipts] -->|SHA-256 only| page",
        "    recordings[Parameter recordings] -->|date, hash and parameters| check",
        "    page -->|regenerated and compared| check[Documentation check]",
        "    check -->|differs| refuse[Refused]",
        "```",
        "",
        "Every figure on the page is read or computed from the kept receipts below. The documentation "
        "check regenerates the page from the receipts, their chain records and the parameter "
        "recordings, and refuses a page that differs, a receipt, chain record or recording that "
        "is missing or altered and a row that names no receipt.",
        "",
        "## Reading the decision table",
        "",
        "Each row is one measurement. The gain lists the figures that are lower than the alternative "
        "the row is compared with, and the regression lists those that are higher. Every compared "
        "figure is a cost, so lower is better. A figure that is equal is in neither list, and "
        "none measured means no compared figure was higher.",
        "",
        f"The batch rows rest on preprod protocol parameters recorded on {date}, taken from the "
        "kept batch receipt. The earlier batch receipt, kept beside it, rests on parameters "
        f"recorded on {recording_date(earlier)}. The creation rows rest on the development network's protocol "
        "parameters, read from its chain at the times the kept chain records note: "
        f"{read_times(chains)}.",
        "",
        "## The decision table",
        "",
        "The first two rows compare creating a registry under the previous design with the "
        "application-held design. The last three rows give the largest batch a fold carries, "
        "compared with a fold of one request.",
        "",
        " ".join(row["headline"] for row in rows[:2]),
        "",
        " ".join(row["headline"] for row in rows[2:]),
        "",
        *table(rows),
        "",
        "## What moved against the earlier recording",
        "",
        "As a reader comparing this release's batch limits with the earlier recording, you find "
        "below the figures that moved and the figures that did not. Each row gives, for one "
        "measurement, the figures that moved with the figure in each receipt, and the figures "
        "that are equal in both receipts. The equal parameters are counted, not listed.",
        "",
        "\n\n".join(movement_sentences(earlier, batch)),
        "",
        *moves(movement_rows(earlier, batch, recordings), earlier, batch),
        "",
        "## Conditions the figures were taken under",
        "",
        "The creation receipts share one development network genesis and one set of protocol "
        "parameters, and the batch receipt carries the preprod parameters it evaluated under. "
        "The hashes below bind those inputs.",
        "",
        *conditions(previous, batch, earlier),
        "",
        "## The kept receipts",
        "",
        "The receipts, the chain records they name and the preprod parameter recordings are "
        "committed with the repository. Their SHA-256 is computed when this page is generated, "
        "so a file that changes also changes this page.",
        "",
        *[line for sentence in history_sentences(history) for line in (sentence, "")],
        *receipts_table(
            [
                previous,
                chains[0],
                candidate,
                chains[1],
                batch,
                recordings[1],
                earlier,
                recordings[0],
                *[kept for pair in history for kept in pair],
            ]
        ),
        "",
        "## Regenerate this page",
        "",
        "Run `python3 tools/decision_table.py --write` to regenerate the page, then regenerate its "
        "speech and changed narration. The documentation check runs `python3 tools/decision_table.py --check`.",
        "",
    ]
    return "\n".join(lines)


def load(root, creation, batch, earlier, history):
    previous = read_receipt(root, creation["previous"])
    candidate = read_receipt(root, creation["candidate"])
    chains = [read_chain_record(root, previous), read_chain_record(root, candidate)]
    batch, earlier = read_receipt(root, batch), read_receipt(root, earlier)
    recordings = [Recording(root, earlier), Recording(root, batch)]
    history = [
        (receipt, Recording(root, receipt))
        for receipt in (read_receipt(root, name) for name in history)
    ]
    return previous, candidate, batch, chains, earlier, recordings, history


def expected_page(
    root, creation=CREATION, batch=BATCH, earlier=BATCH_EARLIER, history=BATCH_HISTORY
):
    return render(*load(root, creation, batch, earlier, history))


def check(
    root,
    page=PAGE,
    creation=CREATION,
    batch=BATCH,
    earlier=BATCH_EARLIER,
    history=BATCH_HISTORY,
):
    path = Path(root) / page
    require(path.is_file(), f"the decision table page is missing: {page}")
    require(
        path.read_text() == expected_page(root, creation, batch, earlier, history),
        "the decision table differs from what its receipts give",
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write", action="store_true")
    parser.add_argument("--root", type=Path, default=Path("."))
    arguments = parser.parse_args()
    try:
        if arguments.write:
            (arguments.root / PAGE).write_text(expected_page(arguments.root))
        else:
            check(arguments.root)
    except Refusal as error:
        print(f"decision table: {error}", file=sys.stderr)
        return 1
    print("decision table matches its receipts")
    return 0


if __name__ == "__main__":
    sys.exit(main())
