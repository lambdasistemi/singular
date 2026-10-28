"""Check the compiled port against its frozen investigation statements and axioms."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

PROJECT = Path(__file__).resolve().parent
REPOSITORY = PROJECT.parent.parent
STANDARD = {"propext", "Classical.choice", "Quot.sound"}
PRINTER = "Lean.reprStr ConstantInfo.type; default Repr options; Lean 4.27.0"
RENAMES = [
    ("NoPin.ApplicationRequests.Refund", "OpenDatumApplicationHeld.Refund"),
    (
        "NoPin.ApplicationRequests.ApplicationAction.inputReference",
        "OpenDatumApplicationHeld.ApplicationAction.inputReference",
    ),
    (
        "NoPin.ApplicationRequests.ApplicationAction.birthIndex",
        "OpenDatumApplicationHeld.ApplicationAction.birthIndex",
    ),
    (
        "NoPin.ApplicationRequests.ApplicationObservation",
        "OpenDatumApplicationHeld.ApplicationObservation",
    ),
    (
        "NoPin.ApplicationRequests.configurationCreate",
        "OpenDatumApplicationHeld.configurationCreate",
    ),
    (
        "NoPin.ApplicationRequests.applicationFoldView",
        "OpenDatumApplicationHeld.applicationFoldView",
    ),
    (
        "NoPin.ApplicationRequests.configurationAsset",
        "OpenDatumApplicationHeld.configurationAsset",
    ),
    (
        "NoPin.ApplicationRequests.configurationShape",
        "OpenDatumApplicationHeld.configurationShape",
    ),
    (
        "NoPin.ApplicationRequests.ApplicationAction",
        "OpenDatumApplicationHeld.ApplicationAction",
    ),
    (
        "NoPin.ApplicationRequests.configurationRead",
        "OpenDatumApplicationHeld.configurationRead",
    ),
    (
        "NoPin.ApplicationRequests.approvalsConsumed",
        "OpenDatumApplicationHeld.approvalsConsumed",
    ),
    (
        "NoPin.ApplicationRequests.registrationClock",
        "OpenDatumApplicationHeld.registrationClock",
    ),
    (
        "NoPin.ApplicationRequests.registrationSpend",
        "OpenDatumApplicationHeld.registrationSpend",
    ),
    (
        "NoPin.ApplicationRequests.applicationAction",
        "OpenDatumApplicationHeld.applicationAction",
    ),
    (
        "NoPin.ApplicationRequests.requestValueSplit",
        "OpenDatumApplicationHeld.requestValueSplit",
    ),
    (
        "NoPin.ApplicationRequests.registrationBook",
        "OpenDatumApplicationHeld.registrationBook",
    ),
    (
        "NoPin.ApplicationRequests.terminationSpend",
        "OpenDatumApplicationHeld.terminationSpend",
    ),
    (
        "NoPin.ApplicationRequests.requiredPayments",
        "OpenDatumApplicationHeld.requiredPayments",
    ),
    (
        "NoPin.ApplicationRequests.requiredTreasury",
        "OpenDatumApplicationHeld.requiredTreasury",
    ),
    (
        "NoPin.ApplicationRequests.terminationBook",
        "OpenDatumApplicationHeld.terminationBook",
    ),
    (
        "NoPin.ApplicationRequests.approvalBurned",
        "OpenDatumApplicationHeld.approvalBurned",
    ),
    (
        "NoPin.ApplicationRequests.initialControl",
        "OpenDatumApplicationHeld.initialControl",
    ),
    ("NoPin.ApplicationRequests.requestInput", "OpenDatumApplicationHeld.requestInput"),
    ("NoPin.ApplicationRequests.freshAsset", "OpenDatumApplicationHeld.freshAsset"),
    ("NoPin.ApplicationRequests.liveUpdate", "OpenDatumApplicationHeld.liveUpdate"),
    ("NoPin.ApplicationRequests.liveShape", "OpenDatumApplicationHeld.liveShape"),
    ("NoPin.ApplicationRequests.paidTo", "OpenDatumApplicationHeld.paidTo"),
    ("NoPin.ApplicationRequests.birth", "OpenDatumApplicationHeld.birth"),
    (
        "NoPin.ApplicationRequests.instBEqApplicationAction",
        "OpenDatumApplicationHeld.instBEqApplicationAction",
    ),
    ("NoPin.ApplicationRequests.", "SingularApplicationHeld."),
    ("NoPin.", "SingularApplicationHeld.Assets."),
]


def require(condition, message):
    if not condition:
        raise ValueError("application-held model: " + message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def renamed(text):
    for old, new in RENAMES:
        if text.startswith(old):
            return new + text[len(old) :]
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
        if statement_stage and source.name == "MoneyStatements.lean":
            require(
                text.count(":= by sorry") == 12,
                "statement stage must expose twelve proof holes",
            )
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
    rows = record["statements"]
    require(len(rows) == len(ledger) == 19, "expected nineteen statement rows")
    for key in ("investigationName", "name"):
        require(len({row[key] for row in rows}) == 19, f"duplicate {key}")
    frozen = {row["theorem"]: row for row in ledger}
    require(
        {row["investigationName"] for row in rows} == set(frozen), "source names differ"
    )
    for row in rows:
        old = frozen[row["investigationName"]]
        require(
            old["status"] == old.get("proofStatus", old["status"]) == "PROVED",
            "source proof debt",
        )
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
    added = record["added"]
    added_names = [row["name"] for row in added]
    require(
        len(set(added_names)) == len(added_names)
        and not set(added_names) & {row["name"] for row in rows},
        "duplicate added statement",
    )
    for row in added:
        require(
            digest(row["type"].encode()) == row["typeSha256"],
            f"recorded type digest differs: {row['name']}; printer={PRINTER}",
        )
        require(
            row["definitions"], f"added statement without definitions: {row['name']}"
        )
    print(
        f"PASS source binding: {len(rows)} distinct compiled types and {len(added)} added; escape scan {len(sources)} files"
    )
    import money_check

    money_check.preflight()
    sys.path.insert(0, str(PROJECT.parent / "singular-application-held"))
    import reader_check

    reader_check.preflight("all")
    return rows, added


def compiled(report, statement_stage=False):
    rows, added = preflight(statement_stage)
    total = len(rows) + len(added)
    text = report.read_text()
    records = [json.loads(line) for line in text.splitlines() if line.startswith("{")]
    statements = [record for record in records if "statement" in record]
    require(
        len(statements) == total,
        f"compiled statement report must contain {total} records",
    )
    observed = {row["statement"]: row["type"] for row in statements}
    require(len(observed) == total, "duplicate compiled statement")
    require(
        set(observed) == {row["name"] for row in rows} | {row["name"] for row in added},
        "compiled statement extent differs",
    )
    for row in rows:
        require(
            observed[row["name"]] == row["investigationType"],
            f"compiled statement differs: {row['name']}; printer={PRINTER}",
        )
    definitions = {
        entry["currentName"]: entry
        for record in records
        for entry in record.get("definitionClosure", [])
    }
    for row in added:
        require(
            observed[row["name"]] == row["type"],
            f"compiled statement differs: {row['name']}; printer={PRINTER}",
        )
        for name, expected in row["definitions"].items():
            entry = definitions.get(name)
            require(entry is not None, f"added statement definition missing: {name}")
            require(
                digest((entry["value"] or "").encode()) == expected,
                f"added statement definition changed: {name}",
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
    print(
        f"PASS compiled correspondence and standard-axiom audit: {total} statements ({len(rows)} from the investigation, {len(added)} added)"
    )
    import money_check

    money_check.compiled(records, statement_stage)
    import reader_check

    reader_check.compiled(report, "all")


def controls():
    """Each scratch defect runs the same recipe and fails before recursive controls."""
    with tempfile.TemporaryDirectory(
        prefix="open-datum-application-held-"
    ) as temporary:
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
            baseline / "models/open-datum-application-held",
            ignore=shutil.ignore_patterns("__pycache__"),
        )
        shutil.copytree(
            REPOSITORY / "models/singular-application-held",
            baseline / "models/singular-application-held",
            ignore=shutil.ignore_patterns("__pycache__"),
        )
        shutil.copytree(
            REPOSITORY / "applications/open-datum",
            baseline / "applications/open-datum",
            ignore=shutil.ignore_patterns("__pycache__"),
        )
        for label, diagnostic in (
            ("dropped-premise", "compiled statement differs"),
            ("recorded-type", "recorded type digest differs"),
            ("unreferenced-hole", "library escape"),
            ("money-definition", "frozen money closure changed"),
            ("dropped-genesis-mint", "omega could not prove the goal"),
        ):
            scratch = Path(temporary) / label
            shutil.copytree(baseline, scratch)
            project = scratch / "models/open-datum-application-held"
            if label == "dropped-premise":
                path = (
                    project
                    / "lean/OpenDatumApplicationHeld/RefundLifecycleStatements.lean"
                )
                text = path.read_text()
                start = text.index("theorem configurationCreate_inversion ")
                end = text.index("theorem bookRegistration_inversion ", start)
                block = text[start:end]
                premise = "    (_premises : configurationCreate_inversion_premise .none h c t decode release q) :"
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
            elif label == "money-definition":
                path = project / "lean/OpenDatumApplicationHeld/MoneyClaims.lean"
                text = path.read_text()
                before = "def oldGenesis (b : Baseline) : RegistryState :="
                require(text.count(before) == 1, "money control edit extent differs")
                path.write_text(text.replace(before, before + " id"))
                require(path.read_text() != text, "money control not applied")
            elif label == "dropped-genesis-mint":
                guard = (
                    " &&\n      SingularApplicationHeld.Assets.mintQty observation.assets "
                    "(configurationAsset hash code release registry) == 1"
                )
                for name, spelling in (
                    ("Application.lean", guard),
                    ("RefundLifecycleConditions.lean", guard),
                ):
                    path = project / "lean/OpenDatumApplicationHeld" / name
                    text = path.read_text()
                    require(
                        text.count(spelling) == 1,
                        "genesis mint control did not identify its edit",
                    )
                    path.write_text(text.replace(spelling, ""))
                    require(
                        path.read_text() != text, "genesis mint control not applied"
                    )
            else:
                path = project / "lean/Unreferenced.lean"
                path.write_text("theorem unreferenced : True := by sorry\n")
                require(path.exists(), "helper control was not applied")
            result = subprocess.run(
                ["just", "open-datum-application-held-model"],
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
            if label == "dropped-genesis-mint":
                require(
                    "RefundLifecycleProofs.lean" in result.stdout,
                    "genesis mint control failed outside the statement proof",
                )
            if label in {"dropped-premise", "money-definition"}:
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
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    if args.evidence:
        import money_check

        money_check.evidence(args.evidence)
    elif args.controls:
        controls()
    elif args.report:
        compiled(args.report, args.statement_stage)
    else:
        preflight(args.statement_stage)


if __name__ == "__main__":
    main()
