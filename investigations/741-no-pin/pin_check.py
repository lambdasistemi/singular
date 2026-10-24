"""Bind file pins to tracked, committed source and reject local cache artifacts."""

import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[1]


def git(*args):
    return subprocess.check_output(["git", "-C", str(REPO), *args])


def check(ledgers):
    tracked = set(git("ls-files", "-z").decode().split("\0"))
    committed = {}
    count = 0
    for ledger_path in sorted(ledgers.glob("*statements.json")):
        ledger = json.loads(ledger_path.read_text())
        for section in (
            "definitions",
            "preservedBaseArtifacts",
            "preservedStatementRows",
        ):
            for name, expected in ledger.get(section, {}).items():
                path = Path(os.path.relpath(ROOT / name, REPO)).as_posix()
                if "__pycache__" in Path(path).parts or path not in tracked:
                    raise ValueError(f"untracked/cache pin: {ledger_path.name}: {name}")
                ignored = subprocess.run(
                    [
                        "git",
                        "-C",
                        str(REPO),
                        "check-ignore",
                        "--no-index",
                        "--quiet",
                        path,
                    ],
                    check=False,
                )
                if ignored.returncode != 1:
                    raise ValueError(f"ignored pin or ignore check failed: {path}")
                if path not in committed:
                    committed[path] = git("show", f"HEAD:{path}")
                content = committed[path]
                if section == "preservedStatementRows":
                    content = json.dumps(
                        json.loads(content)["statements"],
                        ensure_ascii=False,
                        separators=(",", ":"),
                    ).encode()
                if hashlib.sha256(content).hexdigest() != expected:
                    raise ValueError(
                        f"committed pin mismatch: {ledger_path.name}: {name}"
                    )
                count += 1
    if count == 0:
        raise ValueError("no ledger file pins discovered")
    return count


def controls():
    ledgers = {p.name: json.loads(p.read_text()) for p in ROOT.glob("*statements.json")}
    target = "refund-lifecycle-statements.json"
    source = next(iter(ledgers[target]["definitions"]))
    mutations = {
        "cache-pin": ("__pycache__/check.cpython-313.pyc", "0" * 64),
        "untracked-pin": ("untracked-pin-control.py", "0" * 64),
        "wrong-committed-digest": (source, "0" * 64),
        "untracked-symlink": (source, ledgers[target]["definitions"][source]),
    }
    for label, (name, digest) in mutations.items():
        with tempfile.TemporaryDirectory(prefix="no-pin-ledger-control-") as temp:
            if label == "untracked-symlink":
                alias = Path(temp) / "untracked-alias"
                alias.symlink_to(ROOT / source)
                name = str(alias)
            changed = copy.deepcopy(ledgers)
            changed[target]["definitions"][name] = digest
            for filename, ledger in changed.items():
                (Path(temp) / filename).write_text(json.dumps(ledger))
            try:
                check(Path(temp))
            except ValueError as error:
                reason = (
                    "committed pin mismatch"
                    if label == "wrong-committed-digest"
                    else "untracked/cache pin"
                )
                if reason not in str(error) or name not in str(error):
                    raise
            else:
                raise ValueError(f"ledger pin control survived: {label}")
    history = json.loads(
        git("show", "HEAD:investigations/741-no-pin/history-statements.json")
    )
    stale = copy.deepcopy(history["statements"])
    stale[0]["status"] = "STATED" if stale[0]["status"] == "PROVED" else "PROVED"
    stale_digest = hashlib.sha256(
        json.dumps(stale, ensure_ascii=False, separators=(",", ":")).encode()
    ).hexdigest()
    with tempfile.TemporaryDirectory(prefix="no-pin-history-ripple-control-") as temp:
        changed = copy.deepcopy(ledgers)
        changed["money-statements.json"]["preservedStatementRows"][
            "history-statements.json"
        ] = stale_digest
        for filename, ledger in changed.items():
            (Path(temp) / filename).write_text(json.dumps(ledger))
        try:
            check(Path(temp))
        except ValueError as error:
            if (
                "committed pin mismatch: money-statements.json: history-statements.json"
                not in str(error)
            ):
                raise
        else:
            raise ValueError(
                "history status change without refreshing its dependent pin survived"
            )
    return list(mutations) + ["history-status-ripple"]


if __name__ == "__main__":
    print(json.dumps({"row": "S20", "filePins": check(ROOT), "controls": controls()}))
