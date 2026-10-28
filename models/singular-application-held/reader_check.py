"""Bind the reader's frozen statements, compiler evidence and replay corpus."""

import argparse
import copy
import hashlib
import json
from pathlib import Path
import subprocess

PROJECT = Path(__file__).resolve().parent
REPOSITORY = PROJECT.parent.parent
APPLICATION = REPOSITORY / "models/open-datum-application-held"
STANDARD = {"propext", "Classical.choice", "Quot.sound"}
FROZEN_TYPES = {
    "shared": "91fa63dfab2f9ce28ce8882a8679700e6fcc2cf8167bf16194708ec894aa2a16",
    "application": "53a6816d6995b73784703cc1641ffe94eacbe3b2e9036ca2c933576ad0c63ca7",
}


def require(condition, message):
    if not condition:
        raise ValueError("reader: " + message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def projects(scope):
    return [("shared", PROJECT)] + (
        [("application", APPLICATION)] if scope == "all" else []
    )


def manifests(scope):
    return [
        json.loads((path / "reader-statements.json").read_text())
        for _, path in projects(scope)
    ]


def preflight(scope="shared"):
    for (kind, project), ledger in zip(projects(scope), manifests(scope), strict=True):
        rows = ledger["statements"]
        count = 55 if kind == "shared" else 6
        require(len(rows) == count, f"expected {count} reader statements in {kind}")
        types = {row["name"]: row["typeSha256"] for row in rows}
        require(len(types) == count, "duplicate reader statement")
        encoded = json.dumps(types, sort_keys=True, separators=(",", ":")).encode()
        require(
            digest(encoded) == FROZEN_TYPES[kind], "approved reader type map changed"
        )
        require(
            ledger["generated"] and ledger["stage"] == "PROOFS",
            "reader inventory is not generated proof evidence",
        )
        require(ledger["definitionClosure"], "empty reader definition closure")
        require(ledger["proofSourceHashes"], "empty reader proof source map")
        for row in rows:
            require(row["proofStatus"] == "PROVED", "reader proof debt")
            require(
                set(row["observedAxioms"]) <= STANDARD, "reader recorded axiom debt"
            )
        for path, expected in ledger["proofSourceHashes"].items():
            source = (REPOSITORY / path).resolve()
            require(
                source.is_relative_to(project.resolve()),
                "reader source outside its model",
            )
            require(
                source.is_file() and digest(source.read_bytes()) == expected,
                f"reader proof source changed: {path}",
            )
    return manifests(scope)


def typed_records(records, field):
    selected = [row for row in records if field in row]
    result = {row[field]: row for row in selected}
    require(len(result) == len(selected), f"duplicate {field}")
    return result


def checked(records, scope="shared"):
    ledgers = preflight(scope)
    expected = {row["name"]: row for ledger in ledgers for row in ledger["statements"]}
    observed = typed_records(records, "readerStatement")
    require(set(observed) == set(expected), "reader compiled statement extent differs")
    for name, row in observed.items():
        require(
            digest(row["type"].encode()) == expected[name]["typeSha256"],
            f"reader compiled type differs: {name}",
        )
        require(set(row["axioms"]) <= STANDARD, f"reader untrusted axioms: {name}")
        require(
            set(row["axioms"]) == set(expected[name]["observedAxioms"]),
            f"reader recorded axioms differ: {name}",
        )
    support = {row["name"]: row for ledger in ledgers for row in ledger["support"]}
    compiled_support = typed_records(records, "readerSupport")
    require(
        set(compiled_support) == set(support), "reader equality support extent differs"
    )
    for name, row in compiled_support.items():
        require(
            digest(row["type"].encode()) == support[name]["typeSha256"],
            f"reader equality support type differs: {name}",
        )
        require(
            set(row["axioms"]) <= STANDARD,
            f"reader equality support axiom debt: {name}",
        )
        require(
            set(row["axioms"]) == set(support[name]["observedAxioms"]),
            f"reader equality support recorded axioms differ: {name}",
        )
    definitions = typed_records(records, "readerDefinition")
    require(
        set(definitions) == set(ledgers[0]["definitions"]),
        "reader definition extent differs",
    )
    for name, expected_hashes in ledgers[0]["definitions"].items():
        row = definitions[name]
        require(
            digest(row["type"].encode()) == expected_hashes["typeSha256"],
            f"reader definition type changed: {name}",
        )
        require(
            digest((row["value"] or "").encode()) == expected_hashes["valueSha256"],
            f"reader definition changed: {name}",
        )
    frames = [row["readerClosure"] for row in records if "readerClosure" in row]
    require(len(frames) == 1, "expected one walked reader closure")
    closure = {row["name"]: row for row in frames[0]}
    require(len(closure) == len(frames[0]), "duplicate walked reader definition")
    frozen = {
        name: value
        for ledger in ledgers
        for name, value in ledger["definitionClosure"].items()
    }
    require(set(closure) == set(frozen), "walked reader closure extent differs")
    for name, expected_hashes in frozen.items():
        row = closure[name]
        require(
            digest(row["type"].encode()) == expected_hashes["typeSha256"],
            f"reader closure type changed: {name}",
        )
        require(
            digest((row["value"] or "").encode()) == expected_hashes["valueSha256"],
            f"reader closure value changed: {name}",
        )
    return len(expected)


def report_controls(records, scope):
    """Report-integrity controls; these do not certify reader behavior."""
    cases = [
        ("dropped statement", "readerStatement", "drop", "statement extent"),
        ("changed type", "readerStatement", "type", "compiled type differs"),
        ("hidden proof hole", "readerStatement", "axioms", "untrusted axioms"),
        ("dropped equality support", "readerSupport", "drop", "support extent"),
        ("changed definition", "readerDefinition", "value", "definition changed"),
        ("dropped closure entry", "readerClosure", "closure", "closure extent"),
    ]
    for label, field, mutation, diagnostic in cases:
        changed = copy.deepcopy(records)
        index = next(i for i, row in enumerate(changed) if field in row)
        if mutation == "drop":
            changed.pop(index)
        elif mutation == "closure":
            changed[index][field].pop()
        elif mutation == "axioms":
            changed[index]["axioms"] = ["sorryAx"]
        else:
            changed[index][mutation] = "altered"
        try:
            checked(changed, scope)
        except ValueError as error:
            require(
                diagnostic in str(error),
                f"inventory control failed elsewhere: {label}: {error}",
            )
        else:
            raise ValueError("reader: inventory control survived: " + label)
        print("PASS reader inventory control: " + label)


def compiled(report, scope="shared"):
    records = [
        json.loads(line)
        for line in report.read_text().splitlines()
        if line.startswith("{")
    ]
    total = checked(records, scope)
    report_controls(records, scope)
    print(
        f"PASS reader compiled types, standard axioms and walked definitions: {total} statements"
    )


def invoke(driver, source):
    return subprocess.run(
        [str(driver.resolve())],
        input=source,
        text=True,
        capture_output=True,
        check=False,
        timeout=30,
    )


def driver_probe(driver):
    query = {
        "request": {"network": 42, "registry": {"policy": 10, "name": 7}, "key": 1},
        "observation": {
            "network": {"complete": {"value": 9007199254740993}},
            "release": None,
            "activeOutputs": "missing",
            "state": "missing",
            "trie": "missing",
        },
        "codes": [],
        "hashes": [],
        "roots": [],
        "decoding": [],
    }
    result = invoke(driver, json.dumps(query))
    require(
        result.returncode == 0,
        "reader driver failed the exact-integer probe: " + result.stderr,
    )
    expected = {
        "refused": {
            "reason": {"wrongNetwork": {"requested": 42, "served": 9007199254740993}}
        }
    }
    require(json.loads(result.stdout) == expected, "reader driver rounded a Nat")
    for source in ("{", "{}", json.dumps(query) + "\n{}"):
        result = invoke(driver, source)
        require(
            result.returncode == 1 and result.stderr.strip() and not result.stdout,
            "reader driver accepted malformed input",
        )
    print(
        "PASS reader transport: exact Nat above 2^53 and three malformed inputs rejected"
    )


def corpus(report, driver, neutral_driver):
    ledger = json.loads((APPLICATION / "reader-statements.json").read_text())
    path = REPOSITORY / ledger["corpus"]
    require(
        digest(path.read_bytes()) == ledger["corpusSha256"],
        "reader corpus digest differs",
    )
    expected = json.loads(path.read_text())
    observed = [
        json.loads(line) for line in report.read_text().splitlines() if line.strip()
    ]
    require(
        len(expected) == 37 and len({row["name"] for row in expected}) == 37,
        "reader corpus extent differs",
    )
    require(observed == expected, "reader corpus is stale")
    for row in observed:
        result = invoke(driver, json.dumps(row["query"]))
        require(result.returncode == 0, "reader replay failed: " + row["name"])
        require(
            json.loads(result.stdout) == row["answer"],
            "reader replay differs: " + row["name"],
        )
        neutral = invoke(neutral_driver, json.dumps(row["query"]))
        require(neutral.returncode == 0, "neutral reader replay failed: " + row["name"])
        require(
            json.loads(neutral.stdout) == row["neutralAnswer"],
            "neutral reader replay differs: " + row["name"],
        )
    driver_probe(driver)
    driver_probe(neutral_driver)
    print(
        f"PASS reader definition-computed corpus freshness and transport replay: {len(observed)} rows"
    )


def generate_corpus(report):
    """Regenerate the snapshot without passing integers through floating point."""
    rows = [
        json.loads(line)
        for line in report.read_text().splitlines()
        if line.startswith("{")
    ]
    require(len(rows) == 37, "reader generated corpus extent differs")
    target = APPLICATION / "reader-corpus.json"
    target.write_text(json.dumps(rows, indent=2, ensure_ascii=False) + "\n")
    print(f"WROTE definition-computed reader corpus: {len(rows)} rows")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scope", choices=("shared", "all"), default="shared")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--corpus", type=Path)
    parser.add_argument("--driver", type=Path)
    parser.add_argument("--neutral-driver", type=Path)
    parser.add_argument("--generate-corpus", type=Path)
    args = parser.parse_args()
    if args.generate_corpus:
        generate_corpus(args.generate_corpus)
        return
    if args.report:
        compiled(args.report, args.scope)
    else:
        preflight(args.scope)
    if args.corpus:
        require(args.driver is not None, "reader corpus needs the compiled driver")
        require(
            args.neutral_driver is not None,
            "reader corpus needs the compiled neutral driver",
        )
        corpus(args.corpus, args.driver, args.neutral_driver)
    elif args.driver:
        driver_probe(args.driver)
        if args.neutral_driver:
            driver_probe(args.neutral_driver)


if __name__ == "__main__":
    main()
