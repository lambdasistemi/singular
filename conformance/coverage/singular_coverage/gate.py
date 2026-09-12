#!/usr/bin/env python3
"""The theorem-coverage gate (issue #80) — inventory, ratchet, completion, release.

Four commands, distinct verdicts:

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
  release      the release-boundary gate: `completion` bound to an exact
               candidate commit, blocking. The record that authorizes
               publication is resolved from the candidate root
               (conformance/coverage/record/record.json under it) — never
               from the tool closure and never from a `--record` override,
               which `release` refuses. Exit 0 = COMPLETE for that
               candidate (publish may proceed); 1 = honest INCOMPLETE
               (refused, labelled as debt, never as a crash); 3 = fail-closed
               (candidate mismatch, missing inventory, absent execution,
               unknown status, unbound release input); 5 = checker crash (any
               unexpected exception, labelled CRASH, never green, never
               INCOMPLETE). No --expect escape hatch exists on this command
               by design.

The gate never writes the base record and never derives PASS from typed
status alone — every layer must be paid by executed, fresh, non-vacuous,
non-discriminating-failure-free evidence bound to the current tree.
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
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
EXIT_CRASH = 5       # release: unexpected checker exception (never green, never INCOMPLETE)


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


class ReleaseBindingError(Exception):
    """The run is not bound to its declared release candidate."""


def _git(root: Path, *git_args: str) -> str:
    """Run git in root, returning stdout stripped. Raises on failure."""
    import subprocess

    try:
        proc = subprocess.run(
            ["git", *git_args], cwd=root, capture_output=True, text=True, timeout=60
        )
    except OSError as exc:
        raise ReleaseBindingError(f"git unavailable: {exc}") from exc
    if proc.returncode != 0:
        raise ReleaseBindingError(f"git error: {proc.stderr.strip()[:200]}")
    return proc.stdout.strip()


@dataclass
class CandidateBinding:
    """Outcome of binding the working tree to the declared candidate."""

    ok: bool
    reason: str


def check_candidate_binding(root: Path, candidate: str) -> CandidateBinding:
    """Bind the working tree to the declared release candidate, fail-closed.

    Every failure mode rejects: unknown identity (git unavailable or the
    tree answers nothing), HEAD mismatch, a release root that is not the
    repository top level, and any difference between the tree and the
    candidate — tracked modifications and non-ignored untracked files
    alike. Untracked *implementation inputs* are never accepted into the
    released artifact; git-ignored generated output does not trip the
    check. The record, inventory and implementation inputs used at
    publication are therefore the candidate's own: content is pinned by
    candidate digests and population, and the tree is pinned here.
    """
    try:
        head = _git(root, "rev-parse", "HEAD")
    except ReleaseBindingError as exc:
        return CandidateBinding(False, f"candidate identity unknown: {exc}")
    if head != candidate:
        return CandidateBinding(
            False, f"candidate mismatch: checked-out {head} is not claimed {candidate}"
        )
    try:
        top = _git(root, "rev-parse", "--show-toplevel")
    except ReleaseBindingError as exc:
        return CandidateBinding(False, f"candidate root identity unknown: {exc}")
    if Path(top).resolve() != root.resolve():
        return CandidateBinding(
            False,
            f"candidate root mismatch: release root {root} is not the repository top level {top}",
        )
    try:
        status = _git(root, "status", "--porcelain")
    except ReleaseBindingError as exc:
        return CandidateBinding(False, f"candidate cleanliness unknown: {exc}")
    dirty = [line for line in status.splitlines() if line.strip()]
    if dirty:
        return CandidateBinding(
            False,
            f"candidate-tree mismatch: {len(dirty)} differing paths vs {candidate} "
            f"(e.g. {dirty[0].strip()})",
        )
    return CandidateBinding(True, "bound: HEAD matches; tree clean; root is top level")


def cmd_release(args: argparse.Namespace) -> int:
    """Release-boundary gate: strict completion bound to an exact candidate.

    Refuses (nonzero) on honest debt, on any fail-closed absence, on
    candidate mismatch, on unbound release inputs, and on checker
    crashes — each labelled distinctly. Only a COMPLETE verdict for the
    declared candidate exits 0.
    """
    root, _, _ = _defaults(args)
    candidate = args.candidate
    if args.record is not None:
        print(
            "FAIL-CLOSED unbound release input: release resolves its record "
            "from the candidate root and does not accept --record",
            file=sys.stderr,
        )
        return EXIT_FAIL_CLOSED
    # Authoritative record: the candidate's own, never the tool closure's.
    record_path = root / "conformance/coverage/record/record.json"
    binding = check_candidate_binding(root, candidate)
    if not binding.ok:
        print(f"FAIL-CLOSED {binding.reason}", file=sys.stderr)
        return EXIT_FAIL_CLOSED
    try:
        inventory = build_inventory(root)
        record = load_record(record_path)
        debts = compute_debt(inventory, record, root)
        verdict = completion(inventory, record, debts)
    except (InventoryError, RecordError, UnknownRowError, PopulationError, FileNotFoundError) as exc:
        print(f"FAIL-CLOSED {type(exc).__name__}: {exc}", file=sys.stderr)
        return EXIT_FAIL_CLOSED
    except Exception as exc:  # never green, never INCOMPLETE
        label = f"CRASH unexpected {type(exc).__name__}: {exc}"
        print(label, file=sys.stderr)
        if args.report:
            write_report(
                Path(args.report),
                {"verdict": "CRASH", "command": "release", "candidate": candidate, "error": label},
            )
        return EXIT_CRASH
    print(completion_text(verdict))
    print(debt_text(debts))
    print(f"candidate: {candidate} ({binding.reason})")
    if args.report:
        payload = completion_json(verdict)
        payload.update({"command": "release", "candidate": candidate, "binding": binding.reason})
        write_report(Path(args.report), payload)
    return EXIT_OK if verdict.complete else EXIT_DEBT


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

    p_release = sub.add_parser("release", parents=[common],
                               help="release-boundary gate: candidate-bound strict verdict (blocking)")
    p_release.add_argument("--candidate", required=True,
                           help="exact release-candidate commit sha; HEAD must equal it")

    args = parser.parse_args(argv)
    try:
        if args.command == "inventory":
            return cmd_inventory(args)
        if args.command == "ratchet":
            return cmd_ratchet(args)
        if args.command == "completion":
            return cmd_completion(args)
        if args.command == "release":
            return cmd_release(args)
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
