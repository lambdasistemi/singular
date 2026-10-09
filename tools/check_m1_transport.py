#!/usr/bin/env python3
"""Replay bounded receipts through the conformance suite's actual Lean transport."""

import argparse
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root", type=Path, default=Path(__file__).resolve().parent.parent
    )
    parser.add_argument("--evaluator", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    command = (
        [str(args.evaluator)]
        if args.evaluator
        else ["lake", "env", "lean", "--run", "conformance/lean/DriverTransport.lean"]
    )
    corpus = json.loads((root / "lean/m1-corpus.json").read_text())
    manifest = json.loads((root / "lean/m1-theorem-debt.json").read_text())
    bindings = {row["name"]: row["statementSha256"] for row in manifest}
    rows = []

    def evaluate(question):
        run = subprocess.run(
            command,
            input=json.dumps(question),
            capture_output=True,
            text=True,
            cwd=root,
            timeout=60,
            check=False,
        )
        assert run.returncode == 0, run.stderr + run.stdout
        return json.loads(run.stdout)

    for row in corpus["scenarios"]:
        question = {
            key: row[key]
            for key in (
                "start",
                "request",
                "lovelace",
                "id",
                "theorem",
                "statementSha256",
            )
        }
        question.update(
            contract="permanent-m1",
            exit=row["operation"],
            setup=[step["request"] for step in row["setup"]],
        )
        if row["operation"] == "retract":
            question["witness"] = row["witness"]
        result = evaluate(question)
        for field in ("outcome", "reason", "observations"):
            assert result[field] == row[field], (row["id"], field)
        rows.append(
            {
                "requirement": row["id"],
                "outcome": result["outcome"],
                "reason": result["reason"],
            }
        )
        if row["operation"] == "witnessTerminal":
            broad = evaluate(
                {key: value for key, value in question.items() if key != "contract"}
            )
            assert (
                broad["outcome"] == "refused" and broad["reason"] == "edge-inadmissible"
            ), "canonical admission control did not fire"
    name = "Singular.M1.Statements.successful_batch_members_allowed"
    for row in corpus["batches"]:
        question = {
            "contract": "permanent-m1",
            "id": row["requirement"],
            "question": "foldBatch",
            "start": corpus["scenarios"][0]["start"],
            "requests": row["requests"],
            "theorem": name,
            "statementSha256": bindings[name],
        }
        result = evaluate(question)
        for field in ("outcome", "reason", "observations"):
            assert result[field] == row[field], (row["requirement"], field)
        rows.append(
            {
                "requirement": row["requirement"],
                "outcome": result["outcome"],
                "reason": result["reason"],
            }
        )
    bad = subprocess.run(
        command,
        input=json.dumps({"contract": "unknown"}),
        text=True,
        capture_output=True,
        cwd=root,
        timeout=60,
        check=False,
    )
    assert bad.returncode != 0 and "unknown contract" in bad.stdout + bad.stderr
    if args.report:
        args.report.write_text(
            json.dumps(
                {
                    "rows": rows,
                    "controlsDetected": 2,
                    "boundary": "abstract conformance transport, not ledger",
                },
                indent=2,
            )
            + "\n"
        )
    print(
        "Permanent conformance transport: 10 scenarios and 4 batches; canonical admission and unknown-contract controls detected"
    )


if __name__ == "__main__":
    main()
