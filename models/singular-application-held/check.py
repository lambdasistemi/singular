"""Check the compiled port against its frozen investigation statements and axioms."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

PROJECT = Path(__file__).resolve().parent
REPOSITORY = PROJECT.parent.parent
STANDARD = {"propext", "Classical.choice", "Quot.sound"}
PRINTER = "Lean.reprStr ConstantInfo.type; default Repr options; Lean 4.27.0"
RENAMES = [
    ("NoPin.ApplicationRequests", "SingularApplicationHeld"),
    ("NoPin.", "SingularApplicationHeld.Assets."),
]


def require(condition, message):
    if not condition:
        raise ValueError("application-held model: " + message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def renamed(text):
    for old, new in RENAMES:
        text = text.replace(old, new)
    return text


def code_only(text):
    """Discard nested Lean comments and strings, preserving token boundaries."""
    result = []
    index = 0
    depth = 0
    while index < len(text):
        if text.startswith("/-", index):
            depth += 1
            index += 2
        elif depth and text.startswith("-/", index):
            depth -= 1
            index += 2
            result.append(" ")
        elif depth:
            index += 1
        elif text.startswith("--", index):
            end = text.find("\n", index)
            index = len(text) if end < 0 else end
            result.append(" ")
        elif text[index] == '"':
            index += 1
            while index < len(text):
                if text[index] == "\\":
                    index += 2
                elif text[index] == '"':
                    index += 1
                    break
                else:
                    index += 1
            result.append(" ")
        else:
            result.append(text[index])
            index += 1
    require(depth == 0, "unterminated Lean comment")
    return "".join(result)


def preflight(statement_stage=False):
    sources = sorted((PROJECT / "lean").rglob("*.lean")) + [PROJECT / "lakefile.lean"]
    require(sources, "empty library source extent")
    for source in sources:
        text = code_only(source.read_text())
        if statement_stage and source.name == "HistoryClaims.lean":
            require(text.count(":= by sorry") == 4, "expected four history proof holes")
            text = text.replace(":= by sorry", ":= by")
        escape = re.search(
            r"\b(sorry|admit|axiom|unsafe|implemented_by|extern|native_decide|ofReduceBool)\b",
            text,
        )
        require(
            not escape, f"library escape in {source.relative_to(PROJECT)}: {escape}"
        )
    record = json.loads((PROJECT / "correspondence.json").read_text())
    require(record["printer"] == PRINTER, f"printer configuration must be {PRINTER}")
    require(
        record["renames"] == [list(pair) for pair in RENAMES], "namespace map changed"
    )
    ledger_bytes = (PROJECT / "investigation-statements.json").read_bytes()
    require(
        digest(ledger_bytes) == record["ledgerSha256"], "investigation ledger changed"
    )
    ledger = json.loads(ledger_bytes)["statements"]
    rows = [
        row for row in record["statements"] if ".HistoryStatements." not in row["name"]
    ]
    require(len(rows) == len(ledger) == 16, "expected sixteen statement rows")
    for key in ("investigationName", "name"):
        require(len({row[key] for row in rows}) == 16, f"duplicate {key}")
    frozen = {row["theorem"]: row for row in ledger}
    require(
        {row["investigationName"] for row in rows} == set(frozen), "source names differ"
    )
    for row in rows:
        old = frozen[row["investigationName"]]
        require(old["status"] == old["proofStatus"] == "PROVED", "source proof debt")
        require(
            row["name"] == renamed(row["investigationName"]), "wrong theorem rename"
        )
        require(
            row["statementSha256"] == old["statementSha256"], "ledger digest differs"
        )
        require(
            digest(row["investigationType"].encode()) == row["statementSha256"],
            f"recorded type digest differs: {row['investigationName']}; printer={PRINTER}",
        )
    print(
        f"PASS source binding: {len(rows)} distinct compiled types; escape scan {len(sources)} files"
    )
    import history_check

    history_check.preflight()
    import reader_check

    reader_check.preflight()
    return rows


def compiled(report, statement_stage=False):
    rows = preflight(statement_stage)
    text = report.read_text()
    statements = []
    for line in text.splitlines():
        if line.startswith('{"statement":'):
            statements.append(json.loads(line))
    require(
        len(statements) == 16, "compiled statement report must contain sixteen records"
    )
    observed = {row["statement"]: row["type"] for row in statements}
    require(len(observed) == 16, "duplicate compiled statement")
    require(
        set(observed) == {row["name"] for row in rows},
        "compiled statement extent differs",
    )
    for row in rows:
        require(
            observed[row["name"]] == row["investigationType"],
            f"compiled statement differs: {row['name']}; printer={PRINTER}",
        )
    axioms = {}
    for name, dependencies in re.findall(
        r"'([^']+)' depends on axioms: \[([^\]]*)\]", text
    ):
        require(name not in axioms, f"duplicate axiom report: {name}")
        axioms[name] = set(re.findall(r"[A-Za-z_][A-Za-z0-9_.]*", dependencies))
    for name in re.findall(r"'([^']+)' does not depend on any axioms", text):
        require(name not in axioms, f"duplicate axiom report: {name}")
        axioms[name] = set()
    require(set(axioms) == set(observed), "axiom report extent differs")
    for name, dependencies in axioms.items():
        require(
            dependencies <= STANDARD,
            f"untrusted axioms for {name}: {sorted(dependencies)}",
        )
    print("PASS compiled correspondence and standard-axiom audit: sixteen statements")
    import history_check

    history_check.compiled(
        [json.loads(line) for line in text.splitlines() if line.startswith("{")],
        statement_stage,
    )
    import reader_check

    reader_check.compiled(report)


def controls():
    """Each scratch defect runs the same recipe and fails before recursive controls."""
    with tempfile.TemporaryDirectory(prefix="singular-application-held-") as temporary:
        baseline = Path(temporary) / "baseline"
        baseline.mkdir()
        for name in ("lean", ".lake"):
            original = REPOSITORY / name
            if original.exists():
                shutil.copytree(original, baseline / name)
        for name in (
            "justfile",
            "lean-toolchain",
            "lakefile.toml",
            "lake-manifest.json",
        ):
            original = REPOSITORY / name
            if original.exists():
                shutil.copy2(original, baseline / name)
        shutil.copytree(
            PROJECT,
            baseline / "models/singular-application-held",
            ignore=shutil.ignore_patterns("__pycache__"),
        )
        for label, diagnostic in (
            ("dropped-premise", "compiled statement differs"),
            ("recorded-type", "recorded type digest differs"),
            ("unreferenced-hole", "library escape"),
            ("history-definition", "frozen history closure changed"),
            ("history-row-dropped", "expected four history statements"),
        ):
            scratch = Path(temporary) / label
            shutil.copytree(baseline, scratch)
            project = scratch / "models/singular-application-held"
            if label == "dropped-premise":
                path = project / "lean/SingularApplicationHeld/Statements.lean"
                text = path.read_text()
                start = text.index("theorem registration_effects ")
                end = text.index("theorem termination_effects ", start)
                block = text[start:end]
                premise = (
                    "    (_case : q.surface = .registration ∧ caseShape q = true) :"
                )
                require(
                    block.count(premise) == 1,
                    "premise control did not identify its edit",
                )
                replacement = block.replace(premise, "    :")
                path.write_text(text[:start] + replacement + text[end:])
                require(path.read_text() != text, "premise control was not applied")
            elif label == "recorded-type":
                path = project / "correspondence.json"
                record = json.loads(path.read_text())
                record["statements"][0]["investigationType"] += " altered"
                path.write_text(json.dumps(record, indent=2) + "\n")
                require(
                    " altered" in path.read_text(), "record control was not applied"
                )
            elif label == "history-definition":
                path = project / "lean/SingularApplicationHeld/HistoryClaims.lean"
                text = path.read_text()
                before = "  world.domain ++ [.active registry.identity key]"
                require(
                    text.count(before) == 1, "history definition edit extent differs"
                )
                path.write_text(
                    text.replace(
                        before, "  id (world.domain ++ [.active registry.identity key])"
                    )
                )
                require(
                    path.read_text() != text, "history definition edit was not applied"
                )
            elif label == "history-row-dropped":
                path = project / "correspondence.json"
                record = json.loads(path.read_text())
                rows = record["statements"]
                record["statements"] = rows[:-1]
                require(
                    len(rows) == len(record["statements"]) + 1,
                    "history row edit failed",
                )
                path.write_text(json.dumps(record, indent=2) + "\n")
            else:
                path = project / "lean/Unreferenced.lean"
                path.write_text("theorem unreferenced : True := by sorry\n")
                require(path.exists(), "helper control was not applied")
            result = subprocess.run(
                ["just", "application-held-model"],
                cwd=scratch,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                check=False,
                timeout=300,
            )
            require(
                result.returncode != 0 and diagnostic in result.stdout,
                f"control {label} failed for another reason or survived:\n{result.stdout}",
            )
            if label in {"dropped-premise", "history-definition"}:
                require(
                    "error: Lean exited" not in result.stdout,
                    "premise control did not compile",
                )
            print(
                f"PASS control {label}: exit={result.returncode}, diagnostic={diagnostic}"
            )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--controls", action="store_true")
    parser.add_argument("--statement-stage", action="store_true")
    args = parser.parse_args()
    if args.controls:
        controls()
    elif args.report:
        compiled(args.report, args.statement_stage)
    else:
        preflight(args.statement_stage)


if __name__ == "__main__":
    main()
