#!/usr/bin/env python3
"""Render the kept batch measurement into its checked documentation block."""

import argparse
import hashlib
import json
from pathlib import Path
import sys


START = "<!-- batch-limits:start -->"
END = "<!-- batch-limits:end -->"
METRICS = ("memory", "steps", "serializedBytes", "fee")
REPOSITORY = "https://github.com/lambdasistemi/singular/blob/main/"


def table(header, rows):
    return [
        "| " + " | ".join(header) + " |",
        "|" + "---|" * len(header),
        *["| " + " | ".join(map(str, row)) + " |" for row in rows],
        "",
    ]


def render(content):
    """A deterministic value from explicit receipt bytes; no process reads."""
    claim = json.loads(content)["claim"]
    target = claim["target"]
    rows, per_request, marginal, shapes = [], [], [], []
    for kind in ("registrations", "terminations", "mixed"):
        workload = claim["workloads"][kind]
        accepted, refused = workload["samples"][-2:]
        count = workload["largestAccepted"]
        assert accepted["count"] == count and refused["count"] == count + 1
        measured = accepted["measurement"]
        assert not measured["exceeded"] and refused["measurement"]["exceeded"]
        rows.append(
            [
                kind,
                count,
                refused["count"],
                ", ".join(refused["measurement"]["exceeded"]),
                *[measured[key] for key in METRICS],
                measured["ledgerBytes"],
            ]
        )
        # Exact ratios preserve all precision: these are averages, not a
        # universal marginal cost law or a rounded quote for a future batch.
        per_request.append([kind, *[f"{measured[key]}/{count}" for key in METRICS]])
        marginal.append(
            [kind, *[accepted["marginalLastRequest"][key] for key in METRICS]]
        )
        changes = measured["changes"]
        shapes.append(
            [
                kind,
                workload["poolSize"],
                accepted["registrySizeBefore"],
                ", ".join(str(n) for n in sorted({c["keyBytes"] for c in changes})),
                ", ".join(c["kind"] for c in changes),
                hashlib.sha256(
                    json.dumps(accepted["initialDatumShapes"], sort_keys=True).encode()
                ).hexdigest(),
            ]
        )
    parameters = target["parameters"]
    lines = [
        START,
        "",
        "These figures are generated from the [kept measurement receipt]("
        + REPOSITORY
        + "test/fixtures/batch-measurement/receipt.json).",
        "",
        "| Binding | Recorded value |",
        "|---|---|",
        f"| Receipt SHA-256 | `{hashlib.sha256(content).hexdigest()}` |",
        f"| Parameter recording date | {target['recordingDate']} |",
        f"| Parameter source | [{target['source']}]({REPOSITORY}{target['source']}) |",
        f"| Parameter source SHA-256 | `{target['sourceSha256']}` |",
        f"| Evaluated parameter bytes SHA-256 | `{target['parametersSha256']}` |",
        *[
            f"| Applied {name} script | `{value}` |"
            for name, value in sorted(claim["scripts"].items())
        ],
        f"| Maximum transaction memory | {parameters['maxTxExecutionUnits']['memory']} |",
        f"| Maximum transaction steps | {parameters['maxTxExecutionUnits']['steps']} |",
        f"| Maximum ledger-counted bytes | {parameters['maxTxSize']} |",
        "",
        "The largest accepted named prefix and the next refused size follow.",
        "Bytes are the complete signed transaction length; ledger-counted bytes are listed separately. Fees are lovelace from the development-node-balanced transaction body.",
        "",
        *table(
            [
                "Kind",
                "Accepted requests",
                "Next refused requests",
                "Exceeded limit",
                "Memory",
                "Steps",
                "Signed bytes",
                "Fee (lovelace)",
                "Ledger-counted bytes",
            ],
            rows,
        ),
        "Per-request figures are exact total divided by accepted count, including transaction overhead. A fraction is exact, not a rounded price.",
        "",
        *table(
            [
                "Kind",
                "Memory per request",
                "Steps per request",
                "Signed bytes per request",
                "Fee per request (lovelace)",
            ],
            per_request,
        ),
        "The marginal last request is the difference from the preceding kept prefix. It is an observation for this ordered workload, not a constant cost per request.",
        "",
        *table(
            [
                "Kind",
                "Last-request memory",
                "Last-request steps",
                "Last-request signed bytes",
                "Last-request fee (lovelace)",
            ],
            marginal,
        ),
        "The workload starts from the registry sizes below. The listed sequence is the accepted named prefix; the mixed result concerns that alternating order only. The digest binds the full initial datum shapes in the receipt, alongside the kept trie inputs.",
        "",
        *table(
            [
                "Kind",
                "Pending pool",
                "Registry size before fold",
                "Key bytes",
                "Accepted kind order",
                "Initial datum shapes SHA-256",
            ],
            shapes,
        ),
        END,
    ]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument(
        "--check", action="store_true", help="refuse a stale generated block"
    )
    mode.add_argument(
        "--write", action="store_true", help="explicitly refresh the generated block"
    )
    parser.add_argument(
        "--receipt",
        type=Path,
        default=Path("test/fixtures/batch-measurement/receipt.json"),
    )
    parser.add_argument("--page", type=Path, default=Path("docs/folding-requests.md"))
    args = parser.parse_args()
    page = args.page.read_text()
    if page.count(START) != 1 or page.count(END) != 1:
        parser.error("the page needs exactly one marked limits block")
    before, rest = page.split(START)
    _, after = rest.split(END)
    expected = before + render(args.receipt.read_bytes()) + after
    if args.write:
        args.page.write_text(expected)
    elif page != expected:
        print(
            "batch limits documentation differs from its committed receipt",
            file=sys.stderr,
        )
        return 1
    print("batch limits documentation matches its committed receipt")
    return 0


if __name__ == "__main__":
    sys.exit(main())
