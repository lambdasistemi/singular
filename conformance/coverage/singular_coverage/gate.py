#!/usr/bin/env python3
"""The theorem-coverage gate (issue #80) — inventory, ratchet, completion.

Three commands, three distinct verdicts:

  inventory    reconcile the theorem manifests against the source extraction
               (tools/check_model.py, reused) and discover the obligation
               population over ALL of lean/.
  ratchet      per-obligation regression check of the current coverage record
               against the protected base record. No offsetting. Exit 0 = no
               regression, 2 = regression, 3 = fail-closed.
  completion   the full-completion gate: strict, separate from the ratchet,
               never satisfied by an incremental PR. Exit 0 = COMPLETE,
               1 = INCOMPLETE (honest nonzero debt), 3 = fail-closed.
               --expect INCOMPLETE lets CI assert the expected honest verdict
               at a nonzero baseline; flipping that expectation to COMPLETE is
               the explicit act of claiming completion.

The gate never writes the base record and never derives PASS from typed
status alone — every layer must be paid by executed, fresh, non-vacuous,
non-discriminating-failure-free evidence bound to the current tree.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .completion import completion
from .debt import PopulationError, UnknownRowError, compute_debt
from .inventory import InventoryError, build_inventory
from .record import RecordError, load_record
from .report import (
    completion_json,
    completion_text,
    debt_json,
    debt_text,
    inventory_json,
    inventory_text,
    ratchet_json,
    ratchet_text,
    write_report,
)
from .ratchet import ratchet

GATE_DIR = Path(__file__).resolve().parent.parent

EXIT_OK = 0
EXIT_DEBT = 1        # completion INCOMPLETE / inventory failure
EXIT_REGRESSION = 2  # ratchet regression
EXIT_FAIL_CLOSED = 3
EXIT_EXPECTATION = 4  # --expect mismatch


def _defaults(args: argparse.Namespace) -> tuple[Path, Path, Path]:
    root = Path(args.root).resolve()
    record_path = Path(args.record) if args.record else GATE_DIR / "record" / "record.json"
    reference_path = Path(getattr(args, "reference", None)) if getattr(args, "reference", None) else GATE_DIR / "record" / "base-record.json"
    return root, record_path, reference_path


def cmd_inventory(args: argparse.Namespace) -> int:
    root, record_path, _ = _defaults(args)
    inventory = build_inventory(root)
    print(inventory_text(inventory, root))
    record = load_record(record_path)
    debts = compute_debt(inventory, record, root)
    print(debt_text(debts))
    if args.report:
        write_report(Path(args.report), {
            "inventory": inventory_json(inventory),
            "debt": debt_json(debts),
        })
    return EXIT_OK


def cmd_ratchet(args: argparse.Namespace) -> int:
    root, record_path, reference_path = _defaults(args)
    inventory = build_inventory(root)
    current = load_record(record_path)
    base = load_record(reference_path)
    result = ratchet(inventory, base, current, root)
    print(ratchet_text(result))
    if args.report:
        write_report(Path(args.report), ratchet_json(result))
    return EXIT_OK if result.passed else EXIT_REGRESSION


def cmd_completion(args: argparse.Namespace) -> int:
    root, record_path, _ = _defaults(args)
    inventory = build_inventory(root)
    record = load_record(record_path)
    debts = compute_debt(inventory, record, root)
    verdict = completion(inventory, record, debts)
    print(completion_text(verdict))
    print(debt_text(debts))
    if args.report:
        write_report(Path(args.report), completion_json(verdict))
    if args.expect is not None and args.expect != verdict.verdict:
        print(f"EXPECTED {args.expect} but the gate computed {verdict.verdict}")
        return EXIT_EXPECTATION
    if args.expect is None:
        return EXIT_OK if verdict.complete else EXIT_DEBT
    # an asserted expectation that held is a passing CI step, loudly labelled
    return EXIT_OK


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="coverage-gate", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=".", help="repository root (default: cwd)")
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--record", help="current coverage record (default: <gate>/record/record.json)")
    common.add_argument("--report", help="write the machine-readable verdict JSON here")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("inventory", parents=[common],
                   help="manifest reconciliation + discovery over all of lean/")

    p_ratchet = sub.add_parser("ratchet", parents=[common],
                               help="per-obligation regression check vs the protected base")
    p_ratchet.add_argument("--reference", help="base record (default: <gate>/record/base-record.json)")

    p_completion = sub.add_parser("completion", parents=[common],
                                  help="strict full-completion verdict (fails closed)")
    p_completion.add_argument("--expect", choices=("INCOMPLETE", "COMPLETE"), default=None,
                              help="assert the expected verdict (explicit nonzero baseline for CI)")

    args = parser.parse_args(argv)
    try:
        if args.command == "inventory":
            return cmd_inventory(args)
        if args.command == "ratchet":
            return cmd_ratchet(args)
        if args.command == "completion":
            return cmd_completion(args)
        parser.error(f"unknown command {args.command}")  # pragma: no cover
    except InventoryError as exc:
        print(f"FAIL-CLOSED inventory: {exc}", file=sys.stderr)
        return EXIT_FAIL_CLOSED
    except RecordError as exc:
        print(f"FAIL-CLOSED record: {exc}", file=sys.stderr)
        return EXIT_FAIL_CLOSED
    except UnknownRowError as exc:
        print(f"FAIL-CLOSED rows: {exc}", file=sys.stderr)
        return EXIT_FAIL_CLOSED
    except PopulationError as exc:
        print(f"FAIL-CLOSED population: {exc}", file=sys.stderr)
        return EXIT_FAIL_CLOSED
    except FileNotFoundError as exc:
        print(f"FAIL-CLOSED input: {exc}", file=sys.stderr)
        return EXIT_FAIL_CLOSED


if __name__ == "__main__":
    sys.exit(main())
