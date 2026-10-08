#!/usr/bin/env python3
"""Replay every exported row through the actual JSON transport entry point."""

import hashlib
import json
import copy
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[2]
TRANSPORT = "conformance/lean/DriverTransport.lean"


def execute(question):
    return subprocess.run(["lake", "env", "lean", "--run", TRANSPORT], cwd=ROOT,
                          input=json.dumps(question), capture_output=True, text=True)


def answer(question):
    result = execute(question)
    assert result.returncode == 0, result.stdout + result.stderr
    return json.loads(result.stdout)


def run():
    corpus = json.loads((ROOT / "lean/driver-corpus.json").read_text())
    count = 0
    for row in corpus["scenarios"] + corpus["batches"]:
        question = {**row, "setup": [s["request"] for s in row["setup"]]}
        if "operation" in row:
            question["exit"] = row["operation"]
            if "outputs" in row:
                question["inputs"] = []
        observed = answer(question)
        for key in ("outcome", "reason", "observations", "premise", "settle"):
            assert observed.get(key) == row.get(key), (row["id"], key, observed.get(key), row.get(key))
        count += 1
        if count % 20 == 0:
            print(f"replayed {count} rows", flush=True)
    refused = next(row for row in corpus["scenarios"] if row["id"] == "PR-live-compatible")
    question = {**refused, "exit": "reject", "setup": [], "inputs": [], "outputs": []}
    result = answer(question)
    assert result["reason"] == "reject-compatible" and "settle" not in result
    expired = next(row for row in corpus["scenarios"] if row["id"] == "PR-expiry-boundary")
    expiry_question = {**expired, "exit": "reject", "setup": []}
    assert answer(expiry_question)["outcome"] == "accepted"
    metadata_controls = 0
    for path in [
        ("request", "submittedAt"), ("request", "registryId"),
        ("start", "config", "registryId"),
        ("rejection", "evidence", "registryId"),
        ("rejection", "evidence", "registry", "registryId"),
        ("rejection", "evidence", "request", "submittedAt"),
        ("rejection", "evidence", "request", "registryId"),
    ]:
        for mode in ("missing", "null"):
            q = copy.deepcopy(expiry_question)
            obj = q
            for key in path[:-1]:
                obj = obj[key]
            if mode == "missing":
                del obj[path[-1]]
            else:
                obj[path[-1]] = None
            bad = execute(q)
            assert bad.returncode != 0, (path, mode, bad.stdout)
            assert ("unknown field" in bad.stderr or "expected" in bad.stderr
                    or "not found" in bad.stderr), (path, mode, bad.stderr)
            metadata_controls += 1
    fold = next(row for row in corpus["scenarios"] if row["id"] == "DR14-register-active-claimed")
    wrong_exit = {**fold, "exit": fold["operation"], "setup": [],
                  "rejection": expired["rejection"]}
    bad = execute(wrong_exit)
    assert bad.returncode != 0 and "only a rejection question carries" in bad.stderr
    receipt = {"rowsReplayed": count, "admissionBeforeSettlement": True,
               "requiredMetadataControls": metadata_controls, "rejectWitnessOnFoldRefused": True,
               "sha256": {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest()
                          for p in [TRANSPORT, "lean/driver-corpus.json"]}}
    (ROOT / "specs/494-protected-rejection/transport-receipt.json").write_text(
        json.dumps(receipt, indent=2) + "\n")
    print(f"PASS: {count} rows; admission precedes settlement; "
          f"{metadata_controls} required-metadata controls; wrong-exit witness refused")


if __name__ == "__main__":
    run()
