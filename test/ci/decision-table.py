#!/usr/bin/env python3
"""Exercise the decision table check, including deliberate drift.

Each control alters one thing in a scratch copy of the page, its receipts and the
preprod parameter recordings, and requires the check to refuse it. The unaltered
copy is required to pass first, so a refusal is not a broken copy.
"""

import importlib.util
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def load(root):
    spec = importlib.util.spec_from_file_location(
        "decision_table", root / "tools" / "decision_table.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    tool = load(root)
    chains = [
        (
            Path(name).parent / json.loads((root / name).read_text())["chainRecord"]
        ).as_posix()
        for name in tool.CREATION.values()
    ]
    receipts = (tool.BATCH_EARLIER, tool.BATCH)
    recordings = [
        json.loads((root / name).read_text())["claim"]["target"]["source"]
        for name in receipts
    ]
    names = [tool.PAGE, *tool.CREATION.values(), *chains, *receipts, *recordings]
    controls = 0

    def scratch_copy(directory):
        for name in names:
            target = directory / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(root / name, target)

    def refuses(directory, message):
        nonlocal controls
        try:
            tool.check(directory)
        except tool.Refusal as error:
            assert message in str(error), f"refused for another reason: {error}"
        else:
            raise AssertionError(f"the check accepted: {message}")
        controls += 1

    with tempfile.TemporaryDirectory(prefix="decision-table-control-") as directory:
        scratch = Path(directory)
        scratch_copy(scratch)
        tool.check(scratch)

        # The page: every number in the decision table is changed in turn.
        page = (scratch / tool.PAGE).read_text()
        start = page.index("| Measurement |")
        end = page.index("## Conditions")
        for match in list(re.finditer(r"\d+", page[start:end])):
            position = start + match.start()
            digit = page[position]
            changed = (
                page[:position] + str((int(digit) + 1) % 10) + page[position + 1 :]
            )
            (scratch / tool.PAGE).write_text(changed)
            refuses(scratch, "differs from what its receipts give")
        (scratch / tool.PAGE).write_text(page)

        # The creation receipts: each compared figure of each design is changed.
        for design, name in tool.CREATION.items():
            original = (root / name).read_text()
            value = json.loads(original)
            for creation in ("first", "later"):
                for field in value[creation]["totals"]:
                    changed = json.loads(original)
                    changed[creation]["totals"][field] += 1
                    (scratch / name).write_text(json.dumps(changed))
                    refuses(scratch, "differs from what its receipts give")
                for field in ("sizeBytes", "feeLovelace"):
                    changed = json.loads(original)
                    creating = [
                        t
                        for t in changed[creation]["transactions"]
                        if t["step"] in ("boot", "create")
                    ]
                    creating[0][field] += 1
                    (scratch / name).write_text(json.dumps(changed))
                    refuses(scratch, "differs from what its receipts give")
            (scratch / name).write_text(original)

        # Both batch receipts, the current one and the earlier one it replaced: each
        # published metric of the accepted batch and of the one-request fold, for
        # every kind.
        for batch in receipts:
            original = (root / batch).read_text()
            value = json.loads(original)
            for kind, workload in value["claim"]["workloads"].items():
                for index in (0, workload["largestAccepted"] - 1):
                    for metric in ("memory", "steps", "serializedBytes", "fee"):
                        changed = json.loads(original)
                        changed["claim"]["workloads"][kind]["samples"][index][
                            "measurement"
                        ][metric] += 1
                        (scratch / batch).write_text(json.dumps(changed))
                        refuses(scratch, "differs from what its receipts give")
            # The recording date and the parameters of a receipt move together with
            # the recording they come from, or the receipt is refused.
            changed = json.loads(original)
            changed["claim"]["target"]["recordingDate"] = (
                "Mon, 05 Oct 2026 00:00:00 GMT"
            )
            (scratch / batch).write_text(json.dumps(changed))
            refuses(scratch, "not on the date its receipt names")
            changed = json.loads(original)
            changed["claim"]["target"]["parameters"]["maxTxExecutionUnits"][
                "memory"
            ] += 1
            (scratch / batch).write_text(json.dumps(changed))
            refuses(scratch, "holds other parameters than its receipt names")
            (scratch / batch).write_text(original)

        # A figure that differs between the two receipts is listed as moved, with the
        # figure of each receipt, and one that is equal is listed as unchanged. The
        # expected values are read from the earlier receipt, not typed.
        earlier = json.loads((root / tool.BATCH_EARLIER).read_text())
        original = (root / tool.BATCH).read_text()
        row_start = "| " + tool.BATCH_NAMES["registrations"].capitalize() + ": "
        label = "fee of a one-request fold"
        was = earlier["claim"]["workloads"]["registrations"]["samples"][0][
            "measurement"
        ]["fee"]
        for now, listed in ((was, "unchanged"), (was + 1, "moved")):
            changed = json.loads(original)
            changed["claim"]["workloads"]["registrations"]["samples"][0]["measurement"][
                "fee"
            ] = now
            (scratch / tool.BATCH).write_text(json.dumps(changed))
            (row,) = [
                line
                for line in tool.expected_page(scratch).splitlines()
                if line.startswith(row_start)
            ]
            before, after, unchanged = row.split(" | ")[1:4]
            assert (f"{label}: {was} lovelace" in unchanged) == (listed == "unchanged")
            assert (f"{label}: {was} lovelace" in before) == (listed == "moved")
            assert (f"{label}: {now} lovelace" in after) == (listed == "moved")
            controls += 1
        (scratch / tool.BATCH).write_text(original)

        # A receipt that the page names is removed: refused for that reason, in the
        # check and in the command.
        for name in [*tool.CREATION.values(), *chains, *receipts]:
            kept = (scratch / name).read_bytes()
            (scratch / name).unlink()
            refuses(scratch, "source receipt missing: " + name)
            result = subprocess.run(
                [sys.executable, str(root / "tools" / "decision_table.py"), "--check"],
                cwd=scratch,
                text=True,
                capture_output=True,
                check=False,
            )
            assert (
                result.returncode == 1 and "source receipt missing" in result.stderr
            ), f"the command accepted a missing receipt: {result}"
            controls += 1
            (scratch / name).write_bytes(kept)

        # A parameter recording that a receipt names is removed or altered: refused.
        for name in recordings:
            kept = (scratch / name).read_bytes()
            (scratch / name).unlink()
            refuses(scratch, "source recording missing: " + name)
            (scratch / name).write_bytes(kept + b"\n")
            refuses(scratch, "differs from the hash its receipt names")
            (scratch / name).write_bytes(kept)

        # A chain record that is not the one its receipt names is refused.
        for name in chains:
            kept = (scratch / name).read_bytes()
            (scratch / name).write_bytes(kept + b"\n")
            refuses(scratch, "differs from the hash its receipt names")
            (scratch / name).write_bytes(kept)

        # The two creation receipts must describe the same workload.
        original = (root / tool.CREATION["candidate"]).read_text()
        changed = json.loads(original)
        changed["workload"]["fundingOutputs"] += 1
        (scratch / tool.CREATION["candidate"]).write_text(json.dumps(changed))
        refuses(scratch, "the creation receipts differ in workload")
        (scratch / tool.CREATION["candidate"]).write_text(original)

        # A row that names no receipt, or a hash that is not a SHA-256, is refused.
        previous, candidate, _, records, *_ = tool.load(
            scratch, tool.CREATION, tool.BATCH, tool.BATCH_EARLIER
        )
        sources = tool.creation_rows(previous, candidate, records)[0]
        for altered in ([], [("a-receipt.json", "not-a-hash")]):
            try:
                tool.table([dict(sources, sources=altered)])
            except tool.Refusal as error:
                assert "a row without a source receipt is refused" in str(error)
            else:
                raise AssertionError("a row without a source receipt was accepted")
            controls += 1

        # The command itself fails on an altered page.
        (scratch / tool.PAGE).write_text(page.replace("# Release", "# Releases", 1))
        result = subprocess.run(
            [sys.executable, str(root / "tools" / "decision_table.py"), "--check"],
            cwd=scratch,
            text=True,
            capture_output=True,
            check=False,
        )
        assert result.returncode == 1 and "differs" in result.stderr, (
            f"the command accepted an altered page: {result}"
        )
        controls += 1
    print(
        f"decision table: the committed page matches its receipts; {controls} altered figures,"
        " missing receipts and rows without a receipt refused"
    )


if __name__ == "__main__":
    main()
