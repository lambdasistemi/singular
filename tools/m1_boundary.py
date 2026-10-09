#!/usr/bin/env python3
"""Evaluate exported M1 validator bytes over independent Aiken fixture contexts.

These are component evaluations, not reachable ledger states or a connected
journey. A test-only always-accepting program is the deliberate artifact fault the
checker must detect. Keep raw executions.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


class DataDecoder:
    """Decode only the ledger Data CBOR needed for exported script contexts."""

    def __init__(self, payload):
        self.payload = payload
        self.offset = 0

    def take(self, count):
        end = self.offset + count
        if end > len(self.payload):
            raise ValueError("truncated context CBOR")
        result = self.payload[self.offset : end]
        self.offset = end
        return result

    def item(self):
        header = self.take(1)[0]
        major, size = header >> 5, header & 31
        if size < 24:
            length = size
        elif size < 28:
            length = int.from_bytes(self.take(1 << (size - 24)), "big")
        elif size == 31:
            length = None
        else:
            raise ValueError("reserved CBOR length")
        if major in (0, 1):
            if length is None:
                raise ValueError("indefinite integer")
            return ("I", length if major == 0 else -1 - length)
        if major == 2:
            if length is not None:
                return ("B", self.take(length).hex())
            chunks = self.sequence(None)
            if any(chunk[0] != "B" for chunk in chunks):
                raise ValueError("non-byte chunk")
            return ("B", "".join(chunk[1] for chunk in chunks))
        if major == 4:
            return ("List", self.sequence(length))
        if major == 5:
            values = self.sequence(None if length is None else length * 2)
            if len(values) % 2:
                raise ValueError("odd map")
            return ("Map", list(zip(values[::2], values[1::2])))
        if major == 6:
            fields = self.item()
            if fields[0] != "List":
                raise ValueError("constructor fields are not a list")
            if 121 <= length <= 127:
                tag = length - 121
            elif 1280 <= length <= 1400:
                tag = length - 1280 + 7
            elif length == 102:
                index, fields = fields[1]
                if index[0] != "I" or fields[0] != "List":
                    raise ValueError("invalid general constructor")
                tag = index[1]
            else:
                raise ValueError(f"unsupported Data tag {length}")
            return ("Constr", tag, fields[1])
        raise ValueError(f"not ledger Data: major type {major}")

    def sequence(self, length):
        values = []
        while length is None or len(values) < length:
            if length is None and self.payload[self.offset] == 255:
                self.offset += 1
                return values
            values.append(self.item())
        return values


def literal(data):
    kind = data[0]
    if kind == "I":
        return f"I {data[1]}"
    if kind == "B":
        return f"B #{data[1]}"
    if kind == "Constr":
        return f"Constr {data[1]} [{', '.join(map(literal, data[2]))}]"
    if kind == "List":
        return f"List [{', '.join(map(literal, data[1]))}]"
    if kind == "Map":
        pairs = ", ".join(f"({literal(k)}, {literal(v)})" for k, v in data[1])
        return f"Map [{pairs}]"
    raise ValueError(kind)


def parse_contexts(path):
    raw = path.read_text()
    document, _ = json.JSONDecoder().raw_decode(raw[raw.index("{") :])
    if document["summary"]["failed"] or not document["summary"]["total"]:
        raise ValueError("fixture producer did not pass executed tests")
    contexts = {}
    extras = {}
    routes = {name: {} for name in ("REQUEST", "MINT", "JOINED")}
    for module in document["modules"]:
        for test in module["tests"]:
            for trace in test.get("traces", []):
                match = re.fullmatch(
                    r"M1-(CONTEXT|EXTRA|REQUEST|MINT|JOINED):(\d+):([0-9A-Fa-f]+)",
                    trace,
                )
                if match:
                    edge = int(match[2])
                    target = (
                        contexts
                        if match[1] == "CONTEXT"
                        else extras
                        if match[1] == "EXTRA"
                        else routes[match[1]]
                    )
                    if edge in target:
                        raise ValueError(f"duplicate edge context {edge}")
                    target[edge] = bytes.fromhex(match[3])
    if set(contexts) != set(range(7)):
        raise ValueError("missing independently constructed edge contexts")
    if set(extras) != set(range(7)):
        raise ValueError("missing mixed or malformed contexts")
    if any(set(cases) != set(range(7)) for cases in routes.values()):
        raise ValueError("missing composed request/state/mint route contexts")
    return contexts, extras, routes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--blueprint", type=Path, required=True)
    parser.add_argument("--contexts", type=Path, required=True)
    parser.add_argument("--application-contexts", type=Path, required=True)
    parser.add_argument("--aiken", required=True)
    parser.add_argument("--receipts-dir", type=Path, required=True)
    parser.add_argument("--fault-child", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    args.receipts_dir.mkdir(parents=True, exist_ok=False)
    blueprint = json.loads(args.blueprint.read_text())
    contexts, extras, routes = parse_contexts(args.contexts)
    raw = args.application_contexts.read_text()
    application_document, _ = json.JSONDecoder().raw_decode(raw[raw.index("{") :])
    if (
        application_document["summary"]["failed"]
        or not application_document["summary"]["total"]
    ):
        raise ValueError("application fixture producer did not pass executed tests")
    application_contexts = {}
    for module in application_document["modules"]:
        for test in module["tests"]:
            for trace in test.get("traces", []):
                match = re.fullmatch(r"M1-APPLICATION:(\d+):([0-9A-Fa-f]+)", trace)
                if match:
                    number = int(match[1])
                    if number in application_contexts:
                        raise ValueError("duplicate application context")
                    application_contexts[number] = bytes.fromhex(match[2])
    if set(application_contexts) != set(range(4)):
        raise ValueError("missing application booking/update/release contexts")
    rows = []
    failures = []
    evaluations = []
    for title, bounded in [
        ("state.state.spend", True),
    ]:
        cases = [
            (f"edge-{edge}", edge, payload, not bounded or edge in (1, 3), False)
            for edge, payload in sorted(contexts.items())
        ]
        cases += [
            (f"extra-{number}", None, payload, not bounded and number == 0, False)
            for number, payload in sorted(extras.items())
        ]
        evaluations.append((title, cases))
    for route, title in [
        ("REQUEST", "request.request.spend"),
        ("MINT", "witness.witness.mint"),
        ("JOINED", "state.state.spend"),
    ]:
        evaluations.append(
            (
                title,
                [
                    (
                        f"{route.lower()}-{edge}",
                        edge,
                        payload,
                        route != "JOINED" or edge in (1, 3),
                        route != "JOINED",
                    )
                    for edge, payload in sorted(routes[route].items())
                ],
            )
        )
    for family, bounded in [("open_datum", True)]:
        for purpose, numbers in [("mint", (0, 1)), ("spend", (2, 3))]:
            evaluations.append(
                (
                    f"{family}.open_datum.{purpose}",
                    [
                        (
                            f"application-{number}",
                            None,
                            application_contexts[number],
                            bounded or number == 2,
                            True,
                        )
                        for number in numbers
                    ],
                )
            )
    for title, cases in evaluations:
        entries = [v for v in blueprint["validators"] if v["title"] == title]
        if len(entries) != 1:
            raise ValueError(f"expected exactly one {title}")
        validator = entries[0]
        program = args.receipts_dir / f"{title}.cbor.hex"
        program.write_text(validator["compiledCode"])
        for name, edge, payload, expected, bundle in cases:
            decoder = DataDecoder(payload)
            data = decoder.item()
            if decoder.offset != len(payload):
                raise ValueError("trailing context bytes")
            if bundle and (
                data[0] != "List"
                or len(data[1]) != len(validator.get("parameters", [])) + 1
            ):
                raise ValueError(
                    "parameterized route must have its parameters and one context"
                )
            arguments = [
                f"(con data ({literal(arg)}))"
                for arg in (data[1] if bundle else [data])
            ]
            (args.receipts_dir / f"{name}.data.uplc").write_text("\n".join(arguments))
            command = [args.aiken, "uplc", "eval", "--cbor", str(program), *arguments]
            run = subprocess.run(
                command, capture_output=True, text=True, timeout=60, check=False
            )
            (args.receipts_dir / f"{title}-{name}.stdout").write_text(run.stdout)
            (args.receipts_dir / f"{title}-{name}.stderr").write_text(run.stderr)
            accepted = run.returncode == 0
            if accepted:
                outcome = json.loads(run.stdout)
                if outcome["result"] != "(con unit ())":
                    raise ValueError(f"unexpected validator result {outcome['result']}")
            elif "Error" not in run.stderr or "Costs" not in run.stderr:
                raise ValueError("evaluator setup failure is not a validator refusal")
            if accepted != expected:
                failures.append(f"{title}: {name} {accepted=}, {expected=}")
            rows.append(
                {
                    "validator": title,
                    "scriptHash": validator["hash"],
                    "edge": edge,
                    "case": name,
                    "contextSha256": hashlib.sha256(payload).hexdigest(),
                    "exit": run.returncode,
                    "accepted": accepted,
                    "expectedAccepted": expected,
                    "boundaryFaultDetected": title == "state.state.spend"
                    and accepted
                    and edge not in (1, 3),
                }
            )
    report = {
        "boundary": "exported compiled component evaluation",
        "compiler": blueprint["preamble"]["compiler"],
        "blueprintSha256": hashlib.sha256(args.blueprint.read_bytes()).hexdigest(),
        "rows": rows,
        "failures": failures,
        "limits": [
            "fixture roots are not connected ledger journeys",
            "absent states are unreachable from M1 genesis",
            "request and witness components admit co-present folds; the state's decision enforces the boundary",
            "route fixture witness policies are not applied ledger policy identities",
            "Aiken CEK evaluation does not establish ledger acceptance or execution budgets",
        ],
    }
    if not failures and not args.fault_child:
        # Replace only the state artifact with a test-only always-unit program.
        # This admits the same excluded contexts and must fail this same checker.
        faulty = json.loads(args.blueprint.read_text())
        bounded = next(
            v for v in faulty["validators"] if v["title"] == "state.state.spend"
        )
        fault_source = args.receipts_dir / "always-accept.uplc"
        fault_source.write_text("(program 1.1.0 (lam context (con unit ())))\n")
        encoded = subprocess.check_output(
            [args.aiken, "uplc", "encode", "--cbor", "--hex", str(fault_source)],
            text=True,
        ).strip()
        bytes.fromhex(encoded)
        bounded["compiledCode"] = encoded
        bounded["hash"] = hashlib.blake2b(
            b"\x03" + bytes.fromhex(encoded), digest_size=28
        ).hexdigest()
        fault_path = args.receipts_dir / "admitted-excluded-fault.json"
        fault_path.write_text(json.dumps(faulty) + "\n")
        child = subprocess.run(
            [
                sys.executable,
                str(Path(__file__).resolve()),
                "--fault-child",
                "--blueprint",
                str(fault_path),
                "--contexts",
                str(args.contexts),
                "--application-contexts",
                str(args.application_contexts),
                "--aiken",
                args.aiken,
                "--receipts-dir",
                str(args.receipts_dir / "fault-replay"),
            ],
            capture_output=True,
            text=True,
            timeout=180,
            check=False,
        )
        (args.receipts_dir / "fault-replay.stdout").write_text(child.stdout)
        (args.receipts_dir / "fault-replay.stderr").write_text(child.stderr)
        diagnostic = "state.state.spend: edge-6 accepted=True, expected=False"
        if child.returncode == 0 or diagnostic not in child.stdout + child.stderr:
            failures.append(
                "controlled excluded-admission fault was not detected by this checker"
            )
        report["faultControl"] = {
            "exit": child.returncode,
            "diagnostic": diagnostic,
            "detected": child.returncode != 0
            and diagnostic in child.stdout + child.stderr,
        }
    (args.receipts_dir / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    if failures:
        raise SystemExit("\n".join(failures))
    print(
        f"Exported M1: {len(rows)} component evaluations; 2 allowed/5 excluded edges, mixed and 6 malformed controls, joined request/mint/state routes, fixed application booking/update/release; excluded-admission artifact fault refused by checker"
    )


if __name__ == "__main__":
    main()
