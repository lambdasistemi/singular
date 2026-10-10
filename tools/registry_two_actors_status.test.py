#!/usr/bin/env python3
"""Permanent check for the setup/teardown property class (#381).

Every setup-class condition, whichever the call site, maps to status 3,
and teardown of every process the journey started is guaranteed on every
exit path. A teardown failure is status 3 and never overrides status 2.

Usage: registry_two_actors_status.test.py [HARNESS.PY]
"""

import contextlib
import importlib.util
import io
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest import mock


def load_harness(path):
    name = f"two_actors_under_test_{abs(hash(str(path)))}"
    spec = importlib.util.spec_from_file_location(name, str(path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


FAILURES = []


def check(name, condition, detail=""):
    print(f"status-test: {'PASS' if condition else 'FAIL'}: {name} {detail}")
    if not condition:
        FAILURES.append(name)


def bare(mod, tmp):
    journey = mod.Journey.__new__(mod.Journey)
    journey.work = Path(tmp)
    journey.receipts = Path(tmp)
    journey.homes = {
        party: Path(tmp) / f"{party}-home" for party in ("creator", "alice", "bob")
    }
    journey.appendix = []
    journey.node = None
    journey.settings = {
        "providerUrl": "http://localhost:9",
        "networkMagic": 42,
        "networkTimeDirectory": str(tmp),
    }
    journey.state_token = "policy.name"
    journey.singular = "singular"
    journey.devnet = "devnet"
    journey.blueprint = "blueprint"
    journey.keys = Path(tmp)
    journey.payloads = Path(tmp)
    journey.tmp = Path(tmp)
    journey.neutral = Path(tmp)
    return journey


def quiet_execute(journey):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        status = journey.execute()
    return status, out.getvalue()


def test_fixture_failure_is_setup(mod, tmp):
    journey = bare(mod, tmp)
    journey.start_devnet = lambda: None
    journey.run_party = lambda *a, **k: (10, {"outcome": "client-refusal"})
    try:
        journey.fixture()
    except mod.SetupFailure:
        check("fixture-failure-is-setup", True)
    except Exception as error:  # noqa: BLE001 - the wrong mapping is the finding
        check(
            "fixture-failure-is-setup",
            False,
            f"mapped to {type(error).__name__}, want SetupFailure",
        )
    else:
        check("fixture-failure-is-setup", False, "no failure raised")


def fake_run(trace_text=None, receipt_text=None, code=0, exc=None):
    def run(argv, **kwargs):
        if exc is not None:
            raise exc
        if receipt_text is not None:
            kwargs["stdout"].write(receipt_text)
        words = list(argv)
        if "-o" in words:
            Path(words[words.index("-o") + 1]).write_text(trace_text or "")
        return subprocess.CompletedProcess(argv, code)

    return run


def party(mod, tmp):
    journey = bare(mod, tmp)
    journey.homes = {"actor": Path(tmp)}
    return journey


def test_empty_trace_is_setup(mod, tmp):
    journey = party(mod, tmp)
    fake = fake_run(trace_text="", receipt_text='{"outcome": "success"}')
    with mock.patch.object(mod.subprocess, "run", fake):
        try:
            journey.run_party("actor", "step", ["registry", "inspect"], ())
        except mod.SetupFailure:
            check("empty-trace-is-setup", True)
        except Exception as error:  # noqa: BLE001 - see above
            check(
                "empty-trace-is-setup",
                False,
                f"mapped to {type(error).__name__}, want SetupFailure",
            )
        else:
            check("empty-trace-is-setup", False, "no failure raised")


def test_command_timeout_is_setup(mod, tmp):
    journey = party(mod, tmp)
    fake = fake_run(exc=subprocess.TimeoutExpired("singular", 600))
    with mock.patch.object(mod.subprocess, "run", fake):
        try:
            journey.run_party("actor", "step", ["registry", "inspect"], ())
        except mod.SetupFailure:
            check("command-timeout-is-setup", True)
        except Exception as error:  # noqa: BLE001 - see above
            check(
                "command-timeout-is-setup",
                False,
                f"mapped to {type(error).__name__}, want SetupFailure",
            )
        else:
            check("command-timeout-is-setup", False, "no failure raised")


def test_provider_loss_is_setup(mod, tmp):
    journey = party(mod, tmp)
    fake = fake_run(
        trace_text="trace-line\n",
        receipt_text='{"outcome": "node-unavailable"}',
        code=12,
    )
    with mock.patch.object(mod.subprocess, "run", fake):
        try:
            journey.run_party("actor", "step", ["registry", "inspect"], ())
        except mod.SetupFailure:
            check("provider-loss-is-setup", True)
        except Exception as error:  # noqa: BLE001 - see above
            check(
                "provider-loss-is-setup",
                False,
                f"mapped to {type(error).__name__}, want SetupFailure",
            )
        else:
            check("provider-loss-is-setup", False, "no failure raised")


def test_fixture_blowup_tears_down(mod, tmp):
    journey = bare(mod, tmp)

    def fixture():
        raise RuntimeError("boom")

    journey.fixture = fixture
    stopped = []
    journey.stop_devnet = lambda: stopped.append(True)
    try:
        status, out = quiet_execute(journey)
    except Exception as error:  # noqa: BLE001 - teardown skipped is the finding
        check(
            "fixture-blowup-tears-down",
            False,
            f"escaped as {type(error).__name__}, want status 1 with teardown",
        )
        return
    check(
        "fixture-blowup-tears-down",
        status == 1 and stopped == [True] and "FAIL:" in out,
        f"status={status} stopped={stopped}",
    )


def test_guard_keeps_status_through_teardown_failure(mod, tmp):
    journey = bare(mod, tmp)
    journey.fixture = lambda: None

    def leg(actor, key):
        raise mod.GuardFired("/w/bob-home/journal.jsonl")

    journey.actor_leg = leg

    def stop():
        raise mod.SetupFailure("a node of this run survives")

    journey.stop_devnet = stop
    status, out = quiet_execute(journey)
    check(
        "guard-keeps-status-through-teardown-failure",
        status == 2 and "GUARD:" in out and "teardown failed" in out,
        f"status={status}",
    )


def test_teardown_failure_after_success_is_setup(mod, tmp):
    journey = bare(mod, tmp)
    journey.fixture = lambda: None
    journey.actor_leg = lambda actor, key: {}
    journey.removal_check = lambda legs: None
    journey.cap_check = lambda: None
    journey.compute_rows = lambda legs: [
        {
            "requirement": name,
            "state": "passed",
            "receipts": [],
            "dependencies": [],
            "waitingOn": "",
        }
        for name in mod.REQUIREMENTS
        if name not in mod.PAGE_ROWS
    ] + [
        {
            "requirement": name,
            "state": "pending",
            "receipts": [],
            "dependencies": [],
            "waitingOn": "",
        }
        for name in mod.PAGE_ROWS
    ]
    journey.report = lambda rows: None
    journey.node = object()

    def stop():
        raise mod.SetupFailure("a node of this run survives")

    journey.stop_devnet = stop
    try:
        status, out = quiet_execute(journey)
    except Exception as error:  # noqa: BLE001 - see above
        check(
            "teardown-failure-after-success-is-setup",
            False,
            f"escaped as {type(error).__name__}, want status 3",
        )
        return
    check(
        "teardown-failure-after-success-is-setup",
        status == 3 and "teardown failed" in out,
        f"status={status}",
    )


def test_real_stop_needs_its_tools(mod, tmp):
    journey = bare(mod, tmp)
    with mock.patch.object(mod, "which", lambda program: None):
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                journey.stop_devnet()
        except mod.SetupFailure:
            check("real-stop-needs-its-tools", True)
        except Exception as error:  # noqa: BLE001 - see above
            check(
                "real-stop-needs-its-tools",
                False,
                f"mapped to {type(error).__name__}, want SetupFailure",
            )
        else:
            check("real-stop-needs-its-tools", False, "unverified stop claimed clean")


def test_refusal_is_row_result(mod, tmp):
    journey = party(mod, tmp)
    fake = fake_run(
        trace_text="trace-line\n",
        receipt_text=(
            '{"outcome": "client-refusal", "reason": "the envelope\'s '
            'controller is 0x11 but this command signs as 0x22"}'
        ),
        code=10,
    )
    with mock.patch.object(mod.subprocess, "run", fake):
        try:
            status, receipt = journey.run_party(
                "actor", "step", ["registry", "terminate"], ()
            )
        except mod.SetupFailure as error:  # noqa: BLE001 - see above
            check(
                "refusal-is-row-result",
                False,
                f"a controller refusal mapped to setup: {error}",
            )
        except Exception as error:  # noqa: BLE001 - see above
            check(
                "refusal-is-row-result",
                False,
                f"mapped to {type(error).__name__}, want the receipt",
            )
        else:
            check(
                "refusal-is-row-result",
                status == 10 and receipt.get("outcome") == "client-refusal",
                f"status={status} outcome={receipt.get('outcome')}",
            )


def test_reject_refusal_is_row_result(mod, tmp):
    journey = party(mod, tmp)
    fake = fake_run(
        trace_text="trace-line\n",
        receipt_text='{"outcome": "client-refusal", '
        '"reason": "1 pending request is still inside a window: abc#0"}',
        code=10,
    )
    with mock.patch.object(mod.subprocess, "run", fake):
        try:
            status, receipt = journey.run_party(
                "actor", "step", ["registry", "reject"], ()
            )
        except mod.SetupFailure as error:  # noqa: BLE001 - see above
            check(
                "reject-refusal-is-row-result",
                False,
                f"an early reject refusal mapped to setup: {error}",
            )
        except Exception as error:  # noqa: BLE001 - see above
            check(
                "reject-refusal-is-row-result",
                False,
                f"mapped to {type(error).__name__}, want the receipt",
            )
        else:
            check(
                "reject-refusal-is-row-result",
                status == 10 and receipt.get("outcome") == "client-refusal",
                f"status={status} outcome={receipt.get('outcome')}",
            )


def test_reclaim_refusal_is_row_result(mod, tmp):
    journey = party(mod, tmp)
    fake = fake_run(
        trace_text="trace-line\n",
        receipt_text='{"outcome": "client-refusal", '
        '"reason": "retract-owner: this wallet is not the request\'s owner"}',
        code=10,
    )
    with mock.patch.object(mod.subprocess, "run", fake):
        try:
            status, receipt = journey.run_party(
                "actor", "step", ["registry", "reclaim"], ()
            )
        except mod.SetupFailure as error:  # noqa: BLE001 - see above
            check(
                "reclaim-refusal-is-row-result",
                False,
                f"a not-owner refusal mapped to setup: {error}",
            )
        except Exception as error:  # noqa: BLE001 - see above
            check(
                "reclaim-refusal-is-row-result",
                False,
                f"mapped to {type(error).__name__}, want the receipt",
            )
        else:
            check(
                "reclaim-refusal-is-row-result",
                status == 10 and receipt.get("outcome") == "client-refusal",
                f"status={status} outcome={receipt.get('outcome')}",
            )


def _write_receipt(tmp, name, doc, exit_code=None):
    import json as _json

    Path(tmp, f"{name}.json").write_text(_json.dumps(doc) + "\n")
    if exit_code is not None:
        Path(tmp, f"{name}.exit").write_text(f"{exit_code}\n")


def _reject_valid_base(tmp):
    deadline = 1000000
    retract_time = 120000
    expected_close = deadline + retract_time
    locked = {"lovelace": 3000000, "assets": []}
    tip = 1000000
    returned_lovelace = 2000000
    # Synthetic test-only seed (arbitrary bytes, never funded); the harness
    # must derive this same address neutrally from the skey file.
    alice_seed_hex = bytes(range(32)).hex()
    alice_wallet = "addr_test1vqn78rgwr835xn3nl0gqr5l7qj6mwemrlz9v6cj7p4mskscud5urh"
    fee_bound = {
        "command": "fee-bound",
        "outcome": "success",
        "stateToken": "policy.name",
        "stateMaxFee": 1000000,
        "processTime": 120000,
        "retractTime": 120000,
        "observedTx": "statetx#0",
    }
    booking_request = "abc123#0"
    owner_hex = "ownerhex000000000000000000000000000000000000000000000001"
    reject_tx = "rejecttx000000000000000000000000000000000000000000000000000001"
    root = "root000000000000000000000000000000000000000000000000000000000001"
    pending_entry = {
        "request": booking_request,
        "owner": owner_hex,
        "locked": locked,
        "key": "616c6963652d33",
        "edge": "insertActive",
    }
    booking = {
        "command": "insert",
        "outcome": "success",
        "request": booking_request,
        "requester": owner_hex,
        "foldDeadline": {"posixMs": deadline, "slot": 100},
    }
    early_before = {
        "command": "inspect",
        "outcome": "success",
        "root": root,
        "leaf": "unknown",
        "pendingRequests": [pending_entry],
        "retractTime": retract_time,
        "processTime": 120000,
    }
    early_reject = {
        "command": "reject",
        "outcome": "client-refusal",
        "reason": f"1 pending request is still inside a window: {booking_request}",
    }
    early_after = dict(early_before)
    late_before = dict(early_before)
    rejected_row = {
        "request": booking_request,
        "owner": owner_hex,
        "key": "616c6963652d33",
        "edge": "insertActive",
        "locked": locked,
        "tip": tip,
        "returned": {
            "request": booking_request,
            "recipient": alice_wallet,
            "output": f"{reject_tx}#1",
            "index": 1,
            "lovelace": returned_lovelace,
        },
        "processingEnds": deadline,
        "retractEnds": expected_close,
        "topUp": 0,
    }
    late_reject = {
        "command": "reject",
        "outcome": "success",
        "reject": reject_tx,
        "rejected": [rejected_row],
        "root": root,
    }
    late_after = {
        "command": "inspect",
        "outcome": "success",
        "root": root,
        "leaf": "unknown",
        "pendingRequests": [],
        "retractTime": retract_time,
    }
    alice_preview = {"command": "create", "outcome": "success", "wallet": alice_wallet}
    _write_receipt(tmp, "reject-alice-3-booking", booking)
    _write_receipt(tmp, "reject-early-inspect-before", early_before)
    _write_receipt(tmp, "reject-early", early_reject, exit_code=10)
    _write_receipt(tmp, "reject-early-inspect-after", early_after)
    _write_receipt(tmp, "reject-late-inspect-before", late_before)
    _write_receipt(tmp, "reject-late", late_reject)
    _write_receipt(tmp, "reject-late-inspect-after", late_after)
    _write_receipt(tmp, "alice-preview", alice_preview)
    Path(tmp, "alice.skey").write_text(alice_seed_hex + "\n")
    _write_receipt(tmp, "fee-bound", fee_bound)
    legs = {
        "reject": {
            "booking": "reject-alice-3-booking",
            "early_inspect_before": "reject-early-inspect-before",
            "early_reject": "reject-early",
            "early_inspect_after": "reject-early-inspect-after",
            "late_inspect_before": "reject-late-inspect-before",
            "late_reject": "reject-late",
            "late_inspect_after": "reject-late-inspect-after",
        }
    }
    return legs, Path(tmp)


def _owner_valid_base(tmp):
    deadline = 2000000
    retract_time = 120000
    expected_close = deadline + retract_time
    locked = {"lovelace": 2000000, "assets": []}
    # Synthetic test-only seed (arbitrary bytes, never funded).
    bob_seed_hex = bytes(range(1, 33)).hex()
    bob_wallet = "addr_test1vqxst3dzgs3gvqu24ufqtf927sdza8pmk8p5jcke3e362pq9ck9xr"
    booking_request = "def456#0"
    owner_hex = "bobownerhex000000000000000000000000000000000000000000000002"
    retract_tx = "retracttx000000000000000000000000000000000000000000000000000002"
    root = "root000000000000000000000000000000000000000000000000000000000002"
    pending_entry = {
        "request": booking_request,
        "owner": owner_hex,
        "locked": locked,
        "key": "626f622d33",
        "edge": "insertActive",
    }
    booking = {
        "command": "insert",
        "outcome": "success",
        "request": booking_request,
        "requester": owner_hex,
        "foldDeadline": {"posixMs": deadline, "slot": 200},
    }
    early_before = {
        "command": "inspect",
        "outcome": "success",
        "root": root,
        "leaf": "unknown",
        "pendingRequests": [pending_entry],
        "retractTime": retract_time,
        "processTime": 120000,
    }
    early_attempt = {
        "command": "reclaim",
        "outcome": "client-refusal",
        "reason": f"the retract window opens at {deadline} ms",
        "request": booking_request,
    }
    early_after = dict(early_before)
    window_before = dict(early_before)
    success = {
        "command": "reclaim",
        "outcome": "success",
        "request": booking_request,
        "retract": retract_tx,
        "owner": owner_hex,
        "key": "626f622d33",
        "edge": "insertActive",
        "locked": locked,
        "returned": {
            "request": booking_request,
            "recipient": bob_wallet,
            "output": f"{retract_tx}#0",
            "index": 0,
            "lovelace": 2000000,
            "value": {"lovelace": 2000000, "assets": []},
        },
        "topUp": 0,
        "processingEnds": deadline,
        "retractEnds": expected_close,
        "root": root,
    }
    window_after = {
        "command": "inspect",
        "outcome": "success",
        "root": root,
        "leaf": "unknown",
        "pendingRequests": [],
        "retractTime": retract_time,
    }
    continue_booking = {
        "command": "insert",
        "outcome": "success",
        "request": "ghi789#0",
        "requester": "alicehex",
        "foldDeadline": {"posixMs": 3000000, "slot": 300},
    }
    continue_fold = {
        "command": "fold",
        "outcome": "success",
        "request": "ghi789#0",
        "edge": "insertActive",
        "root": "root_continue_000000000000000000000000000003",
    }
    continue_a = {
        "command": "inspect",
        "outcome": "success",
        "leaf": "active",
        "root": "root_continue_000000000000000000000000000003",
    }
    continue_b = dict(continue_a)
    bob_preview = {"command": "create", "outcome": "success", "wallet": bob_wallet}
    Path(tmp, "bob.skey").write_text(bob_seed_hex + "\n")
    _write_receipt(tmp, "reclaim-bob-3-booking", booking)
    _write_receipt(tmp, "reclaim-early-inspect-before", early_before)
    _write_receipt(tmp, "reclaim-early-attempt", early_attempt, exit_code=10)
    _write_receipt(tmp, "reclaim-early-inspect-after", early_after)
    _write_receipt(tmp, "reclaim-window-inspect-before", window_before)
    _write_receipt(tmp, "reclaim-success", success)
    _write_receipt(tmp, "reclaim-window-inspect-after", window_after)
    _write_receipt(tmp, "reclaim-continue-booking", continue_booking)
    _write_receipt(tmp, "reclaim-continue-fold", continue_fold)
    _write_receipt(tmp, "reclaim-continue-inspect-alice", continue_a)
    _write_receipt(tmp, "reclaim-continue-inspect-bob", continue_b)
    _write_receipt(tmp, "bob-preview", bob_preview)
    legs = {
        "reclaim-owner": {
            "booking": "reclaim-bob-3-booking",
            "early_inspect_before": "reclaim-early-inspect-before",
            "early_attempt": "reclaim-early-attempt",
            "early_inspect_after": "reclaim-early-inspect-after",
            "window_inspect_before": "reclaim-window-inspect-before",
            "success": "reclaim-success",
            "window_inspect_after": "reclaim-window-inspect-after",
            "continue_booking": "reclaim-continue-booking",
            "continue_fold": "reclaim-continue-fold",
            "continue_inspect_a": "reclaim-continue-inspect-alice",
            "continue_inspect_b": "reclaim-continue-inspect-bob",
        }
    }
    return legs, Path(tmp)


def test_money_compares_value_and_recipient(mod, tmp):
    import json as _json

    journey = bare(mod, tmp)
    legs, receipts = _reject_valid_base(tmp)
    passed, _, _ = journey.reject_agreement(legs, receipts)
    check("money-valid-reject-passes", passed, "the valid reject base did not pass")
    cases = []
    raw = Path(tmp, "reject-late.json").read_text()
    doc = _json.loads(raw)
    zero = _json.loads(raw)
    zero["rejected"][0]["returned"] = dict(zero["rejected"][0]["returned"])
    zero["rejected"][0]["returned"]["lovelace"] = 0
    _write_receipt(tmp, "reject-late", zero)
    passed_zero, _, _ = journey.reject_agreement(legs, receipts)
    cases.append(("zero", not passed_zero))
    foreign = _json.loads(raw)
    foreign["rejected"][0]["returned"] = dict(foreign["rejected"][0]["returned"])
    foreign["rejected"][0]["returned"]["recipient"] = (
        "addr_test1_foreign_recipient_999999"
    )
    _write_receipt(tmp, "reject-late", foreign)
    passed_foreign, _, _ = journey.reject_agreement(legs, receipts)
    cases.append(("foreign", not passed_foreign))
    correlated_full = _json.loads(raw)
    correlated_full["rejected"][0]["tip"] = 3000000
    correlated_full["rejected"][0]["returned"] = dict(
        correlated_full["rejected"][0]["returned"]
    )
    correlated_full["rejected"][0]["returned"]["lovelace"] = 0
    _write_receipt(tmp, "reject-late", correlated_full)
    passed_corr_full, _, _ = journey.reject_agreement(legs, receipts)
    cases.append(("correlated-3M-0", not passed_corr_full))
    correlated_part = _json.loads(raw)
    correlated_part["rejected"][0]["tip"] = 2000000
    correlated_part["rejected"][0]["returned"] = dict(
        correlated_part["rejected"][0]["returned"]
    )
    correlated_part["rejected"][0]["returned"]["lovelace"] = 1000000
    _write_receipt(tmp, "reject-late", correlated_part)
    passed_corr_part, _, _ = journey.reject_agreement(legs, receipts)
    cases.append(("correlated-2M-1M", not passed_corr_part))
    unrelated = _json.loads(raw)
    unrelated["rejected"][0]["request"] = "ffff#0"
    unrelated["rejected"][0]["returned"] = dict(unrelated["rejected"][0]["returned"])
    unrelated["rejected"][0]["returned"]["request"] = "ffff#0"
    _write_receipt(tmp, "reject-late", unrelated)
    passed_unrelated, _, _ = journey.reject_agreement(legs, receipts)
    cases.append(("unrelated", not passed_unrelated))
    Path(tmp, "reject-late.json").write_text(raw)
    olegs, oreceipts = _owner_valid_base(tmp)
    opassed, _, _ = journey.owner_reclaim_agreement(olegs, oreceipts)
    check("money-valid-owner-passes", opassed, "the valid owner base did not pass")
    oraw = Path(tmp, "reclaim-success.json").read_text()
    odoc = _json.loads(oraw)
    ozero = _json.loads(oraw)
    ozero["returned"] = dict(ozero["returned"])
    ozero["returned"]["lovelace"] = 0
    _write_receipt(tmp, "reclaim-success", ozero)
    opassed_zero, _, _ = journey.owner_reclaim_agreement(olegs, oreceipts)
    cases.append(("owner-zero", not opassed_zero))
    oforeign = _json.loads(oraw)
    oforeign["returned"] = dict(oforeign["returned"])
    oforeign["returned"]["recipient"] = "addr_test1_foreign_recipient_999999"
    _write_receipt(tmp, "reclaim-success", oforeign)
    opassed_foreign, _, _ = journey.owner_reclaim_agreement(olegs, oreceipts)
    cases.append(("owner-foreign", not opassed_foreign))
    ounrelated = _json.loads(oraw)
    ounrelated["request"] = "ffff#0"
    ounrelated["returned"] = dict(ounrelated["returned"])
    ounrelated["returned"]["request"] = "ffff#0"
    _write_receipt(tmp, "reclaim-success", ounrelated)
    opassed_unrelated, _, _ = journey.owner_reclaim_agreement(olegs, oreceipts)
    cases.append(("owner-unrelated", not opassed_unrelated))
    Path(tmp, "reclaim-success.json").write_text(oraw)
    _ = odoc
    _ = doc
    failed = [name for name, ok in cases if not ok]
    check(
        "money-compares-value-and-recipient",
        not failed,
        f"tampered money still passed: {failed}" if failed else "",
    )


def test_no_preview_files_needed(mod, tmp):
    journey = bare(mod, tmp)
    legs, receipts = _reject_valid_base(tmp)
    for name in ("alice-preview", "bob-preview"):
        path = Path(tmp, f"{name}.json")
        if path.exists():
            path.unlink()
        exit_path = Path(tmp, f"{name}.exit")
        if exit_path.exists():
            exit_path.unlink()
    passed_reject, _, _ = journey.reject_agreement(legs, receipts)
    check(
        "reject-passes-without-previews",
        passed_reject,
        "the reject row needs preview files",
    )
    olegs, oreceipts = _owner_valid_base(tmp)
    for name in ("alice-preview", "bob-preview"):
        path = Path(tmp, f"{name}.json")
        if path.exists():
            path.unlink()
    passed_owner, _, _ = journey.owner_reclaim_agreement(olegs, oreceipts)
    check(
        "owner-passes-without-previews",
        passed_owner,
        "the owner row needs preview files",
    )


class _SpyDict(dict):
    """A receipt dict recording every key path read through get/item."""

    def __init__(self, mapping, log, path):
        super().__init__(mapping)
        object.__setattr__(self, "_log", log)
        object.__setattr__(self, "_path", path)

    def _wrap(self, key, value):
        path = self._path + (key,)
        if isinstance(value, dict):
            return _SpyDict(value, self._log, path)
        if isinstance(value, list):
            return _SpyList(value, self._log, path)
        return value

    def get(self, key, default=None):
        self._log.append(self._path + (key,))
        return self._wrap(key, super().get(key, default))

    def __getitem__(self, key):
        self._log.append(self._path + (key,))
        return self._wrap(key, super().__getitem__(key))


class _SpyList(list):
    """A receipt list recording every index read."""

    def __init__(self, items, log, path):
        super().__init__(items)
        object.__setattr__(self, "_log", log)
        object.__setattr__(self, "_path", path)

    def _wrap(self, index, value):
        path = self._path + (index,)
        if isinstance(value, dict):
            return _SpyDict(value, self._log, path)
        if isinstance(value, list):
            return _SpyList(value, self._log, path)
        return value

    def __getitem__(self, index):
        self._log.append(self._path + (index,))
        return self._wrap(index, super().__getitem__(index))

    def __iter__(self):
        for index in range(len(self)):
            self._log.append(self._path + (index,))
            yield self._wrap(index, super().__getitem__(index))


def _wrong_valid_base(tmp):
    booking_request = "wxyz12#0"
    owner_hex = "wrongownerhex00000000000000000000000000000000000000000003"
    root = "root000000000000000000000000000000000000000000000000000000000004"
    pending_entry = {
        "request": booking_request,
        "owner": owner_hex,
        "locked": {"lovelace": 2000000, "assets": []},
    }
    booking = {
        "command": "insert",
        "outcome": "success",
        "request": booking_request,
        "requester": owner_hex,
    }
    before = {
        "command": "inspect",
        "outcome": "success",
        "root": root,
        "pendingRequests": [pending_entry],
    }
    attempt = {
        "command": "reclaim",
        "outcome": "client-refusal",
        "reason": "retract-owner: this wallet is not the request's owner",
        "request": booking_request,
    }
    after = dict(before)
    _write_receipt(tmp, "wrong-booking", booking)
    _write_receipt(tmp, "wrong-inspect-before", before)
    _write_receipt(tmp, "wrong-attempt", attempt, exit_code=10)
    _write_receipt(tmp, "wrong-inspect-after", after)
    legs = {
        "reclaim-wrong": {
            "booking": "wrong-booking",
            "inspect_before": "wrong-inspect-before",
            "attempt": "wrong-attempt",
            "inspect_after": "wrong-inspect-after",
        }
    }
    return legs, Path(tmp)


def _refusal_valid_base(tmp):
    root = "root000000000000000000000000000000000000000000000000000000000005"
    inspect = {
        "command": "inspect",
        "outcome": "success",
        "root": root,
        "pendingRequests": [],
    }
    update = {
        "command": "update",
        "outcome": "client-refusal",
        "reason": "the envelope's controller is 0x11 but signs as 0x22",
    }
    terminate = {
        "command": "terminate",
        "outcome": "client-refusal",
        "reason": "the envelope's controller is 0x11 but signs as 0x22",
    }
    _write_receipt(tmp, "refuse-inspect-before", inspect)
    _write_receipt(tmp, "refuse-update", update, exit_code=10)
    _write_receipt(tmp, "refuse-terminate", terminate, exit_code=10)
    _write_receipt(tmp, "refuse-inspect-after", dict(inspect))
    legs = {
        "refusals": [
            {
                "inspect_before": "refuse-inspect-before",
                "refuse_update": "refuse-update",
                "refuse_terminate": "refuse-terminate",
                "inspect_after": "refuse-inspect-after",
            }
        ]
    }
    return legs, Path(tmp)


def _foldroots_valid_base(tmp):
    root = "root000000000000000000000000000000000000000000000000000000000006"
    fold = {"command": "fold", "outcome": "success", "root": root}
    first = {"command": "inspect", "outcome": "success", "root": root}
    _write_receipt(tmp, "foldroot-fold", fold)
    _write_receipt(tmp, "foldroot-inspect-a", first)
    _write_receipt(tmp, "foldroot-inspect-b", dict(first))
    legs = {
        "fold_roots": [
            {
                "fold": "foldroot-fold",
                "inspect_a": "foldroot-inspect-a",
                "inspect_b": "foldroot-inspect-b",
            }
        ]
    }
    return legs, Path(tmp)


def test_trim_derived_from_reads(mod, tmp):
    kept = set(getattr(mod, "RECORD_KEPT_FIELDS", ()))
    log = []
    journey = bare(mod, tmp)
    rlegs, _ = _reject_valid_base(tmp)
    olegs, _ = _owner_valid_base(tmp)
    wlegs, _ = _wrong_valid_base(tmp)
    glegs, _ = _refusal_valid_base(tmp)
    flegs, _ = _foldroots_valid_base(tmp)
    hist_wlegs, hist_alegs, _ = _history_valid_bases(tmp)
    real_load = journey.load_receipt

    def spy_load(name, receipts=None):
        doc = real_load(name, receipts)
        if doc is None:
            return None
        return _SpyDict(doc, log, (name,))

    journey.load_receipt = spy_load
    receipts = Path(tmp)
    checks = [
        ("reject", journey.reject_agreement(rlegs, receipts)),
        ("wrong", journey.wrong_reclaim_agreement(wlegs, receipts)),
        ("owner", journey.owner_reclaim_agreement(olegs, receipts)),
        ("refusal", journey.refusal_agreement(glegs, receipts)),
        ("foldroots", journey.fold_roots_agreement(flegs, receipts)),
        ("withheld", journey.withheld_fold_agreement(hist_wlegs, receipts)),
        ("altered", journey.altered_edge_agreement(hist_alegs, receipts)),
    ]
    for name, (passed, _, _) in checks:
        check(f"derived-valid-{name}-passes", passed, f"the {name} base did not pass")
    roots = {path[1] for path in log if len(path) == 2}
    missing = {key for key in roots if key not in kept}
    check(
        "trim-derived-from-reads",
        not missing,
        f"reads escape the kept set: {sorted(missing)}" if missing else "",
    )


def _cbor_uint(value):
    if value < 24:
        return bytes([value])
    if value < 256:
        return bytes([24, value])
    if value < 65536:
        return bytes([25]) + value.to_bytes(2, "big")
    return bytes([26]) + value.to_bytes(4, "big")


def _cbor_bstr(blob):
    assert len(blob) < 256
    if len(blob) < 24:
        return bytes([64 + len(blob)]) + blob
    return bytes([88, len(blob)]) + blob


def _cbor_array(items):
    assert len(items) < 24
    return bytes([128 + len(items)]) + b"".join(items)


def _cbor_tag(number, item):
    if number < 24:
        return bytes([192 + number]) + item
    return bytes([216, number]) + item


def _synthetic_state_fields(fee=1000000, process=120000, retract=120000):
    return [
        _cbor_bstr(bytes(range(32))),
        _cbor_uint(fee),
        _cbor_uint(process),
        _cbor_uint(retract),
        _cbor_bstr(bytes([1]) * 28),
        _cbor_bstr(bytes([2]) * 28),
        _cbor_bstr(bytes([3]) * 28),
        _cbor_bstr(bytes([4]) * 28),
    ]


def _synthetic_state_datum_hex(fee=1000000, process=120000, retract=120000):
    fields = _synthetic_state_fields(fee, process, retract)
    inner = _cbor_tag(121, _cbor_array(fields))
    return (_cbor_tag(122, _cbor_array([inner]))).hex()


def _synthetic_bare_state_datum_hex(fee=1000000, process=120000, retract=120000):
    fields = _synthetic_state_fields(fee, process, retract)
    return (_cbor_tag(121, _cbor_array(fields))).hex()


def _synthetic_state_datum_indefinite_hex():
    fields = _synthetic_state_fields()
    inner = _cbor_tag(121, b"\x9f" + b"".join(fields) + b"\xff")
    return (_cbor_tag(122, _cbor_array([inner]))).hex()


def test_cbor_decoder_synthetic(mod, tmp):
    decode = getattr(mod, "decode_plutus_datum", None)
    if decode is None:
        check("cbor-decoder-synthetic", False, "decode_plutus_datum is absent")
        return
    datum = decode(_synthetic_state_datum_hex())
    ok = (
        isinstance(datum, tuple)
        and datum[0] == "constr"
        and datum[1] == 1
        and isinstance(datum[2], list)
        and len(datum[2]) == 1
        and isinstance(datum[2][0], tuple)
        and datum[2][0][1] == 0
        and datum[2][0][2][1] == 1000000
        and datum[2][0][2][2] == 120000
        and datum[2][0][2][3] == 120000
    )
    check("cbor-decoder-synthetic", ok, "a hand-built state datum misdecoded")
    bare = decode(_synthetic_bare_state_datum_hex())
    check(
        "cbor-decoder-bare-state",
        isinstance(bare, tuple) and bare[0] == "constr" and bare[1] == 0,
        "a bare eight-field state datum misdecoded",
    )
    try:
        indefinite = decode(_synthetic_state_datum_indefinite_hex())
    except Exception as error:
        check(
            "cbor-decoder-indefinite",
            False,
            f"an indefinite-length datum did not decode: {type(error).__name__}",
        )
    else:
        check(
            "cbor-decoder-indefinite",
            isinstance(indefinite, tuple)
            and indefinite[0] == "constr"
            and indefinite[1] == 1
            and indefinite[2][0][2][1] == 1000000,
            "an indefinite-length state datum misdecoded",
        )
    try:
        decode("d8798800")
        check("cbor-decoder-rejects-short", False, "a truncated datum decoded")
    except ValueError:
        check("cbor-decoder-rejects-short", True)
    except Exception as error:
        check(
            "cbor-decoder-rejects-short",
            False,
            f"a truncated datum escaped as {type(error).__name__}, not ValueError",
        )


def test_plutus_json_walker(mod, tmp):
    walk = getattr(mod, "_plutus_json_value", None)
    if walk is None:
        check("plutus-json-walker", False, "_plutus_json_value is absent")
        return
    node = {
        "constructor": 0,
        "fields": [
            {"bytes": "00" * 32},
            {"int": 1000000},
            {"int": 120000},
            {"int": 120000},
        ],
    }
    value = walk(node)
    check(
        "plutus-json-walker",
        isinstance(value, tuple)
        and value[0] == "constr"
        and value[1] == 0
        and value[2][1] == 1000000,
        "a datum-value object misconverted",
    )


def test_fee_bound_fetch_mocked(mod, tmp):
    fetch = getattr(mod, "fetch_state_fee_bound", None)
    post = getattr(mod, "_koios_post", None)
    walk = getattr(mod, "_plutus_json_value", None)
    if fetch is None or post is None or walk is None:
        missing = [
            name
            for name, fn in (
                ("fetch_state_fee_bound", fetch),
                ("_koios_post", post),
                ("_plutus_json_value", walk),
            )
            if fn is None
        ]
        check(
            "fee-bound-fetch-mocked",
            False,
            f"the fetch path is absent: {missing}",
        )
        return
    from unittest import mock as _mock

    datum_hex = _synthetic_state_datum_hex()
    inline_row = {
        "tx_hash": "aa" * 32,
        "tx_index": 1,
        "inline_datum": {"bytes": datum_hex},
    }
    with _mock.patch.object(mod, "_koios_post", return_value=[inline_row]):
        bound = fetch("http://localhost:9/api/v1", "pp", "nn", 120000, 120000)
    check(
        "fee-bound-fetch-inline",
        bound["stateMaxFee"] == 1000000 and bound["observedTx"] == f"{'aa' * 32}#1",
        f"the inline datum gave {bound}",
    )
    hashed_row = {
        "tx_hash": "bb" * 32,
        "tx_index": 0,
        "datum_hash": "cc" * 32,
    }

    def fake_post(base, path, payload, timeout=30):
        if path == "/asset_utxos":
            return [hashed_row]
        if path == "/datum_info":
            return [{"bytes": datum_hex}]
        raise AssertionError(f"unexpected path {path}")

    with _mock.patch.object(mod, "_koios_post", side_effect=fake_post):
        bound = fetch("http://localhost:9/api/v1", "pp", "nn", 120000, 120000)
    check(
        "fee-bound-fetch-by-hash",
        bound["stateMaxFee"] == 1000000,
        f"the datum_info fallback gave {bound}",
    )
    other_row = {
        "tx_hash": "dd" * 32,
        "tx_index": 0,
        "inline_datum": {
            "bytes": _synthetic_state_datum_hex(
                fee=1000000, process=60000, retract=30000
            )
        },
    }
    with _mock.patch.object(mod, "_koios_post", return_value=[other_row]):
        try:
            fetch("http://localhost:9/api/v1", "pp", "nn", 120000, 120000)
            check("fee-bound-rejects-windows", False, "other windows accepted")
        except RuntimeError as error:
            check(
                "fee-bound-rejects-windows",
                "other windows" in str(error),
                f"unexpected error: {error}",
            )
    with _mock.patch.object(mod, "_koios_post", return_value=[]):
        try:
            fetch("http://localhost:9/api/v1", "pp", "nn", 120000, 120000)
            check("fee-bound-rejects-empty", False, "no rows accepted")
        except RuntimeError as error:
            check(
                "fee-bound-rejects-empty",
                "no rows" in str(error),
                f"unexpected error: {error}",
            )


def test_nonzero_topup_survives_trim(mod, tmp):
    import json as _json

    journey = bare(mod, tmp)
    legs, receipts = _owner_valid_base(tmp)
    raw = Path(tmp, "reclaim-success.json").read_text()
    wraw = Path(tmp, "reclaim-window-inspect-before.json").read_text()
    wdoc = _json.loads(wraw)
    wdoc["pendingRequests"][0]["locked"] = {
        "lovelace": 3000000,
        "assets": [],
    }
    Path(tmp, "reclaim-window-inspect-before.json").write_text(_json.dumps(wdoc) + "\n")
    topped = _json.loads(raw)
    topped["locked"] = {"lovelace": 3000000, "assets": []}
    topped["topUp"] = 1000000
    topped["returned"] = dict(topped["returned"])
    topped["returned"]["lovelace"] = 4000000
    topped["returned"]["value"] = {"lovelace": 4000000, "assets": []}
    _write_receipt(tmp, "reclaim-success", topped)
    bob_preview = {
        "command": "create",
        "outcome": "success",
        "wallet": "addr_test1vqxst3dzgs3gvqu24ufqtf927sdza8pmk8p5jcke3e362pq9ck9xr",
    }
    _write_receipt(tmp, "bob-preview", bob_preview)
    passed_plain, _, _ = journey.owner_reclaim_agreement(legs, receipts)
    check(
        "nonzero-topup-passes-untrimmed",
        passed_plain,
        "a topped-up return did not pass untrimmed",
    )
    threshold = getattr(mod, "TRIM_THRESHOLD_BYTES", 262144)
    bloated = dict(topped)
    bloated["sessionEvidence"] = "x" * (threshold + 1)
    raw_large = _json.dumps(bloated)
    trimmed = mod.trim_record("reclaim", 0, raw_large)
    Path(tmp, "reclaim-success.json").write_text(trimmed)
    error = mod.check_record("reclaim-success.json", trimmed.encode())
    check("nonzero-topup-trim-is-record", error is None, error or "")
    passed_trimmed, _, _ = journey.owner_reclaim_agreement(legs, receipts)
    check(
        "nonzero-topup-passes-trimmed",
        passed_trimmed,
        "a topped-up return did not pass after the trim",
    )
    dropped = _json.loads(raw)
    dropped = dict(_json.loads(_json.dumps(topped)))
    del dropped["topUp"]
    _write_receipt(tmp, "reclaim-success", dropped)
    passed_dropped, _, _ = journey.owner_reclaim_agreement(legs, receipts)
    check(
        "dropped-topup-does-not-pass",
        not passed_dropped,
        "a return without its top-up still passed",
    )
    Path(tmp, "reclaim-success.json").write_text(raw)
    Path(tmp, "reclaim-window-inspect-before.json").write_text(wraw)


def test_trim_preserves_run_three_predicates(mod, tmp):
    import hashlib as _hashlib
    import json as _json

    required = [
        "foldDeadline",
        "retractTime",
        "processTime",
        "processingEnds",
        "retractEnds",
        "wallet",
    ]
    kept = list(getattr(mod, "RECORD_KEPT_FIELDS", ()))
    missing = [key for key in required if key not in kept]
    check(
        "trim-keeps-run-three-fields",
        not missing,
        f"kept fields omit {missing}" if missing else "",
    )
    journey = bare(mod, tmp)
    legs, receipts = _reject_valid_base(tmp)
    passed_untrimmed, _, _ = journey.reject_agreement(legs, receipts)
    raw_booking = Path(tmp, "reject-alice-3-booking.json").read_text()
    booking_doc = _json.loads(raw_booking)
    booking_doc["sessionEvidence"] = "x" * (
        getattr(mod, "TRIM_THRESHOLD_BYTES", 262144) + 1
    )
    raw_large = _json.dumps(booking_doc)
    trimmed = mod.trim_record("insert", 0, raw_large)
    Path(tmp, "reject-alice-3-booking.json").write_text(trimmed)
    error = mod.check_record("reject-alice-3-booking.json", trimmed.encode())
    check("trim-large-booking-is-record", error is None, error or "")
    passed_trimmed, _, _ = journey.reject_agreement(legs, receipts)
    check(
        "trim-large-booking-same-state",
        passed_untrimmed and passed_trimmed,
        f"untrimmed={passed_untrimmed} trimmed={passed_trimmed}",
    )
    Path(tmp, "reject-alice-3-booking.json").write_text(raw_booking)
    _ = _hashlib.sha256(raw_large.encode()).hexdigest()


def test_refusal_compares_pending_set(mod, tmp):
    journey = bare(mod, tmp)
    legs, receipts = _owner_valid_base(tmp)
    passed_valid, _, _ = journey.owner_reclaim_agreement(legs, receipts)
    check(
        "refusal-valid-owner-passes", passed_valid, "the valid owner base did not pass"
    )
    import json as _json

    raw_after = Path(tmp, "reclaim-early-inspect-after.json").read_text()
    doc_after = _json.loads(raw_after)
    doc_after["pendingRequests"] = []
    Path(tmp, "reclaim-early-inspect-after.json").write_text(
        _json.dumps(doc_after) + "\n"
    )
    passed_tampered, _, _ = journey.owner_reclaim_agreement(legs, receipts)
    check(
        "refusal-compares-pending-set",
        not passed_tampered,
        "an after-inspect missing the request still passed",
    )
    Path(tmp, "reclaim-early-inspect-after.json").write_text(raw_after)


def test_window_comes_from_registry(mod, tmp):
    import json as _json

    journey = bare(mod, tmp)
    legs, receipts = _reject_valid_base(tmp)
    passed_valid, _, _ = journey.reject_agreement(legs, receipts)
    check(
        "window-valid-reject-passes", passed_valid, "the valid reject base did not pass"
    )
    raw_before = Path(tmp, "reject-early-inspect-before.json").read_text()
    doc_before = _json.loads(raw_before)
    doc_before["retractTime"] = 30000
    Path(tmp, "reject-early-inspect-before.json").write_text(
        _json.dumps(doc_before) + "\n"
    )
    passed_tampered, _, waiting = journey.reject_agreement(legs, receipts)
    check(
        "window-comes-from-registry",
        not passed_tampered,
        f"a registry window disagreeing with the fixture still passed: {waiting}",
    )
    Path(tmp, "reject-early-inspect-before.json").write_text(raw_before)


def test_trim_keeps_predicate_fields(mod, tmp):
    trim = getattr(mod, "trim_record", None)
    threshold = getattr(mod, "TRIM_THRESHOLD_BYTES", 262144)
    if trim is None:
        check("trim-keeps-predicate-fields", False, "trim_record is absent")
        return
    import hashlib as _hashlib
    import json as _json

    receipt = {
        "command": "inspect",
        "outcome": "success",
        "leaf": "active",
        "root": "ab" * 32,
        "pendingRequests": [],
        "sessionEvidence": "x" * (threshold + 1),
    }
    raw = _json.dumps(receipt)
    record = _json.loads(trim("inspect", 0, raw))
    check(
        "trim-keeps-predicate-fields",
        record.get("outcome") == "success"
        and record.get("leaf") == "active"
        and record.get("root") == "ab" * 32
        and record.get("pendingRequests") == []
        and "sessionEvidence" not in record
        and record.get("rawSha256") == _hashlib.sha256(raw.encode()).hexdigest()
        and record.get("rawBytes") == len(raw.encode())
        and record.get("command") == "inspect"
        and record.get("exit") == 0,
        "the record lost a predicate field or kept the snapshot",
    )


def test_record_tamper_is_detected(mod, tmp):
    check_record = getattr(mod, "check_record", None)
    threshold = getattr(mod, "TRIM_THRESHOLD_BYTES", 262144)
    if check_record is None:
        check("record-tamper-is-detected", False, "check_record is absent")
        return
    import json as _json

    good = _json.dumps(
        {
            "command": "inspect",
            "outcome": "success",
            "leaf": "active",
            "root": "ab" * 32,
            "pendingRequests": [],
            "exit": 0,
            "rawSha256": "ab" * 32,
            "rawBytes": threshold + 1,
        }
    ).encode()
    tampered_hash = _json.dumps(
        _json.loads(good.decode()) | {"rawSha256": "zz"}
    ).encode()
    tampered_size = _json.dumps(_json.loads(good.decode()) | {"rawBytes": 12}).encode()
    check(
        "record-tamper-is-detected",
        check_record("good.json", good) is None
        and check_record("tampered-hash.json", tampered_hash) is not None
        and check_record("tampered-size.json", tampered_size) is not None,
        "a tampered record passed verification",
    )


def test_oversize_untrimmed_is_detected(mod, tmp):
    check_record = getattr(mod, "check_record", None)
    threshold = getattr(mod, "TRIM_THRESHOLD_BYTES", 262144)
    if check_record is None:
        check("oversize-untrimmed-is-detected", False, "check_record is absent")
        return
    raw = b"{" + b"x" * (threshold + 1) + b"}"
    check(
        "oversize-untrimmed-is-detected",
        check_record("big.json", raw) is not None,
        "an untrimmed receipt over the threshold passed",
    )


def test_long_root_uses_short_runtime(mod, tmp):
    journey = bare(mod, tmp)
    long_root = Path(tmp) / ("l" * 120)
    journey.work = long_root
    journey.neutral = long_root / "devnet"
    journey.tmp = long_root / "tmp"
    try:
        env = journey.neutral_environment()
    except Exception as error:  # noqa: BLE001 - no short runtime is the finding
        check(
            "long-root-uses-short-runtime",
            False,
            f"neutral_environment raised {type(error).__name__}: {error}",
        )
        return
    tmpdir = env.get("TMPDIR", "")
    check(
        "long-root-uses-short-runtime",
        len(tmpdir) < 60 and str(long_root) not in tmpdir,
        f"TMPDIR={tmpdir[:80]} len={len(tmpdir)}",
    )


def test_setup_names_devnet_cause(mod, tmp):
    journey = bare(mod, tmp)
    journey.neutral.mkdir(parents=True, exist_ok=True)
    cause = "Timed out waiting for cardano-node socket"

    class _Exited:
        def poll(self):
            return 1

    def _popen(argv, **kwargs):
        err = kwargs.get("stderr")
        if err is not None:
            try:
                err.write(cause + "\n")
            except Exception:  # noqa: BLE001 - the harness still names the cause
                pass
        return _Exited()

    with mock.patch.object(mod.subprocess, "Popen", _popen):
        with mock.patch.object(mod.time, "sleep", lambda *_a, **_k: None):
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    journey.start_devnet()
            except mod.SetupFailure as failed:
                check(
                    "setup-names-devnet-cause",
                    cause in str(failed),
                    f"SetupFailure={failed}",
                )
            except Exception as error:  # noqa: BLE001 - wrong mapping is the finding
                check(
                    "setup-names-devnet-cause",
                    False,
                    f"mapped to {type(error).__name__}, want SetupFailure naming the cause",
                )
            else:
                check(
                    "setup-names-devnet-cause",
                    False,
                    "an exited development source claimed success",
                )


def _history_valid_bases(tmp):
    policy = "aa" * 28
    name = "bb" * 16
    token = f"{policy}.{name}"
    root = "cc" * 32
    fold_tx = "dd" * 32
    create = {"command": "create", "outcome": "success", "stateToken": token}
    positive = {
        "command": "inspect",
        "outcome": "success",
        "root": root,
        "leaf": "active",
        "pendingRequests": [],
    }
    fold = {
        "command": "fold",
        "outcome": "success",
        "request": "histreq#0",
        "edge": "insertActive",
        "folder": "ff",
        "root": root,
        "fold": fold_tx,
    }
    withheld_refusal = {
        "command": "inspect",
        "outcome": "stale-state",
        "reason": "TrieState HistoryIncomplete",
        "trieRefusal": {
            "registry": {"policy": policy, "name": name},
            "cause": "missing-transaction",
        },
    }
    altered_refusal = {
        "command": "inspect",
        "outcome": "stale-state",
        "reason": "TrieState RootDoesNotChain",
        "trieRefusal": {
            "registry": {"policy": policy, "name": name},
            "transaction": fold_tx,
            "cause": "roots-part",
            "rebuiltRoot": "ee" * 32,
            "recordedRoot": root,
        },
    }
    _write_receipt(tmp, "history-create", create)
    _write_receipt(tmp, "history-positive", positive)
    _write_receipt(tmp, "history-fold", fold)
    _write_receipt(tmp, "history-withheld", withheld_refusal, exit_code=14)
    _write_receipt(tmp, "history-altered", altered_refusal, exit_code=14)
    wlegs = {
        "withheld": {
            "create": "history-create",
            "positive_inspect": "history-positive",
            "withheld_inspect": "history-withheld",
        },
        "alice": {"fold": "history-fold"},
        "fold_roots": [
            {"fold": "history-fold", "key": "k", "inspect_a": "ia", "inspect_b": "ib"}
        ],
    }
    alegs = {
        "altered": {
            "create": "history-create",
            "positive_inspect": "history-positive",
            "altered_inspect": "history-altered",
        },
        "alice": {"fold": "history-fold"},
        "fold_roots": [
            {"fold": "history-fold", "key": "k", "inspect_a": "ia", "inspect_b": "ib"}
        ],
    }
    return wlegs, alegs, Path(tmp)


def test_history_refusals_bind_identity(mod, tmp):
    import json as _json

    journey = bare(mod, tmp)
    wlegs, alegs, receipts = _history_valid_bases(tmp)
    passed_w, _, _ = journey.withheld_fold_agreement(wlegs, receipts)
    check(
        "history-valid-withheld-passes",
        passed_w,
        "the valid withheld base did not pass",
    )
    passed_a, _, _ = journey.altered_edge_agreement(alegs, receipts)
    check(
        "history-valid-altered-passes",
        passed_a,
        "the valid altered base did not pass",
    )
    raw = Path(tmp, "history-withheld.json").read_text()
    doc = _json.loads(raw)
    doc["trieRefusal"]["registry"] = {"policy": "00" * 28, "name": "11" * 16}
    Path(tmp, "history-withheld.json").write_text(_json.dumps(doc) + "\n")
    passed_other, _, _ = journey.withheld_fold_agreement(wlegs, receipts)
    check(
        "history-other-registry-does-not-pass",
        not passed_other,
        "a refusal naming another registry still passed",
    )
    Path(tmp, "history-withheld.json").write_text(raw)
    raw_a = Path(tmp, "history-altered.json").read_text()
    doc_a = _json.loads(raw_a)
    doc_a["trieRefusal"]["transaction"] = "00" * 32
    Path(tmp, "history-altered.json").write_text(_json.dumps(doc_a) + "\n")
    passed_tx, _, _ = journey.altered_edge_agreement(alegs, receipts)
    check(
        "history-other-transaction-does-not-pass",
        not passed_tx,
        "a refusal naming another transaction still passed",
    )
    Path(tmp, "history-altered.json").write_text(raw_a)
    doc_bare = _json.loads(raw)
    del doc_bare["trieRefusal"]
    Path(tmp, "history-withheld.json").write_text(_json.dumps(doc_bare) + "\n")
    passed_noref, _, _ = journey.withheld_fold_agreement(wlegs, receipts)
    check(
        "history-missing-trierefusal-does-not-pass",
        not passed_noref,
        "a refusal with no trieRefusal still passed",
    )
    Path(tmp, "history-withheld.json").write_text(raw)


def test_history_reads_covered_and_load_bearing(mod, tmp):
    import json as _json

    kept = set(getattr(mod, "RECORD_KEPT_FIELDS", ()))
    check(
        "history-kept-has-trierefusal",
        "trieRefusal" in kept,
        "kept fields omit trieRefusal",
    )
    journey = bare(mod, tmp)
    wlegs, alegs, receipts = _history_valid_bases(tmp)
    log = []
    real_load = journey.load_receipt

    def spy_load(name, receipts=None):
        doc = real_load(name, receipts)
        if doc is None:
            return None
        return _SpyDict(doc, log, (name,))

    journey.load_receipt = spy_load
    passed_w, _, _ = journey.withheld_fold_agreement(wlegs, receipts)
    passed_a, _, _ = journey.altered_edge_agreement(alegs, receipts)
    check(
        "history-covered-withheld-passes",
        passed_w,
        "the covered withheld base did not pass",
    )
    check(
        "history-covered-altered-passes",
        passed_a,
        "the covered altered base did not pass",
    )
    roots = {path[1] for path in log if len(path) == 2}
    check(
        "history-contract-reads-trierefusal",
        "trieRefusal" in roots,
        "the history agreements never read trieRefusal, coverage is vacuous",
    )
    missing = {key for key in roots if key not in kept}
    check(
        "history-reads-stay-kept",
        not missing,
        f"history reads escape the kept set: {sorted(missing)}" if missing else "",
    )
    journey.load_receipt = real_load
    threshold = getattr(mod, "TRIM_THRESHOLD_BYTES", 262144)
    raw = Path(tmp, "history-withheld.json").read_text()
    doc = _json.loads(raw)
    doc["sessionEvidence"] = "x" * (threshold + 1)
    trimmed = mod.trim_record("inspect", 14, _json.dumps(doc))
    Path(tmp, "history-withheld.json").write_text(trimmed)
    error = mod.check_record("history-withheld.json", trimmed.encode())
    check("history-trimmed-is-record", error is None, error or "")
    kept_doc = _json.loads(trimmed)
    check(
        "history-trim-keeps-trierefusal",
        kept_doc.get("trieRefusal", {}).get("registry", {}).get("policy") == "aa" * 28,
        "the trim dropped the refused registry",
    )
    passed_trimmed, _, _ = journey.withheld_fold_agreement(wlegs, receipts)
    check(
        "history-passes-trimmed",
        passed_trimmed,
        "the withheld row did not pass on its trimmed record",
    )
    doc_dropped = _json.loads(raw)
    del doc_dropped["trieRefusal"]
    Path(tmp, "history-withheld.json").write_text(_json.dumps(doc_dropped) + "\n")
    passed_dropped, _, _ = journey.withheld_fold_agreement(wlegs, receipts)
    check(
        "history-dropped-trierefusal-does-not-pass",
        not passed_dropped,
        "a trimmed-shaped refusal without trieRefusal still passed",
    )
    Path(tmp, "history-withheld.json").write_text(raw)


def test_forwarder_withholds_state_asset(mod, tmp):
    import json as _json
    import threading as _threading
    from http.server import BaseHTTPRequestHandler as _Handler
    from http.server import ThreadingHTTPServer as _Server

    forward_cls = getattr(mod, "_WithholdingForwarder", None)
    if forward_cls is None:
        check(
            "forwarder-withholds-state-asset",
            False,
            "_WithholdingForwarder is absent",
        )
        return
    upstream_rows = [{"tx_hash": "aa" * 32, "block_height": 10}]

    class _Stub(_Handler):
        def _answer(self, payload):
            body = _json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path.startswith("/api/v1/asset_txs"):
                self._answer(upstream_rows)
            else:
                self._answer({"echo": self.path})

        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            self.rfile.read(length)
            self._answer({"echo": self.path})

        def log_message(self, *args):
            pass

    server = _Server(("127.0.0.1", 0), _Stub)
    thread = _threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        upstream = f"http://127.0.0.1:{server.server_address[1]}/api/v1"
        seen = {}

        class _RangedStub(_Handler):
            def _answer_ranged(self, payload):
                body = _json.dumps(payload).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Content-Range", "0-0/1")
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                seen["prefer"] = self.headers.get("Prefer")
                self._answer_ranged(upstream_rows)

            def log_message(self, *args):
                pass

        ranged = _Server(("127.0.0.1", 0), _RangedStub)
        ranged_thread = _threading.Thread(target=ranged.serve_forever, daemon=True)
        ranged_thread.start()
        try:
            ranged_upstream = f"http://127.0.0.1:{ranged.server_address[1]}/api/v1"
            forward = forward_cls(ranged_upstream, "aabbcc", "ddeeff")
            forward.start()
            try:
                import urllib.request as _url2

                request = _url2.Request(
                    forward.url
                    + "/asset_txs?_asset_policy=00&_asset_name=11&_history=true",
                    headers={"Prefer": "count=exact", "Accept": "application/json"},
                )
                with _url2.urlopen(request, timeout=10) as answer:
                    ranged_rows = _json.loads(answer.read().decode())
                    relayed_range = answer.headers.get("Content-Range")
                check(
                    "forwarder-relays-prefer",
                    seen.get("prefer") == "count=exact",
                    f"upstream saw Prefer={seen.get('prefer')!r}",
                )
                check(
                    "forwarder-relays-content-range",
                    ranged_rows == upstream_rows and relayed_range == "0-0/1",
                    f"rows={ranged_rows!r} range={relayed_range!r}",
                )
            finally:
                forward.stop()
        finally:
            ranged.shutdown()
            ranged.server_close()
            ranged_thread.join(timeout=10)
        upstream = f"http://127.0.0.1:{server.server_address[1]}/api/v1"
        forward = forward_cls(upstream, "aabbcc", "ddeeff")
        try:
            forward.start()
        except mod.SetupFailure as error:
            check(
                "forwarder-withholds-state-asset",
                False,
                f"an ephemeral forwarder did not start: {error}",
            )
            return
        try:
            import urllib.request as _url

            with _url.urlopen(
                forward.url
                + "/asset_txs?_asset_policy=aabbcc&_asset_name=ddeeff&_history=true",
                timeout=10,
            ) as answer:
                withheld = _json.loads(answer.read().decode())
                withheld_range = answer.headers.get("Content-Range")
            check(
                "forwarder-withholds-state-asset",
                withheld == [],
                f"state asset_txs answered {withheld!r}",
            )
            check(
                "forwarder-withheld-page-has-total",
                withheld_range == "*/0",
                f"withheld page range is {withheld_range!r}, want '*/0'",
            )
            with _url.urlopen(
                forward.url
                + "/asset_txs?_asset_policy=00&_asset_name=11&_history=true",
                timeout=10,
            ) as answer:
                other = _json.loads(answer.read().decode())
            check(
                "forwarder-forwards-other-assets",
                other == upstream_rows,
                f"other asset_txs answered {other!r}",
            )
            with _url.urlopen(forward.url + "/tip", timeout=10) as answer:
                tip = _json.loads(answer.read().decode())
            check(
                "forwarder-forwards-other-paths",
                tip == {"echo": "/api/v1/tip"},
                f"tip answered {tip!r}",
            )
        finally:
            forward.stop()
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=10)


def test_forwarder_start_failure_is_setup(mod, tmp):
    import socket as _socket

    forward_cls = getattr(mod, "_WithholdingForwarder", None)
    if forward_cls is None:
        check(
            "forwarder-start-failure-is-setup",
            False,
            "_WithholdingForwarder is absent",
        )
        return
    held = _socket.socket()
    held.bind(("127.0.0.1", 0))
    port = held.getsockname()[1]
    try:
        forward = forward_cls("http://127.0.0.1:9/api/v1", "aa", "bb", port=port)
        try:
            forward.start()
        except mod.SetupFailure:
            check("forwarder-start-failure-is-setup", True)
        except Exception as error:  # noqa: BLE001 - wrong mapping is the finding
            check(
                "forwarder-start-failure-is-setup",
                False,
                f"mapped to {type(error).__name__}, want SetupFailure",
            )
        else:
            check(
                "forwarder-start-failure-is-setup",
                False,
                "a bound port claimed success",
            )
            forward.stop()
    finally:
        held.close()


def _withheld_mocked_leg(mod, tmp, withheld_outcome):
    journey = bare(mod, tmp)
    journey.state_token = "aabbcc.ddeeff"
    root = "cc" * 32
    positive = {
        "command": "inspect",
        "outcome": "success",
        "root": root,
        "leaf": "active",
        "pendingRequests": [],
    }
    _write_receipt(tmp, "withheld-positive-inspect", positive)
    _write_receipt(
        tmp,
        "withheld-inspect",
        {
            "command": "inspect",
            "outcome": "stale-state",
            "reason": "TrieState HistoryIncomplete",
            "trieRefusal": {
                "registry": {"policy": "aabbcc", "name": "ddeeff"},
                "cause": "missing-transaction",
            },
        },
        exit_code=14,
    )
    _write_receipt(
        tmp,
        "create",
        {"command": "create", "outcome": "success", "stateToken": "aabbcc.ddeeff"},
    )
    _write_receipt(
        tmp,
        "withheld-alice-fold",
        {
            "command": "fold",
            "outcome": "success",
            "root": root,
            "fold": "dd" * 32,
        },
    )
    urls = []

    def fake_run_party(party, name, arguments, forbidden):
        assert "--state-token" in arguments, "an actor command without --state-token"
        if name == "withheld-positive-inspect":
            return 0, dict(positive)
        if name == "withheld-inspect":
            urls.append(arguments[arguments.index("--koios-url") + 1])
            return withheld_outcome()
        raise AssertionError(f"unexpected command {name}")

    return journey, urls, fake_run_party


def _forwarder_port_closed(url):
    import socket as _socket

    port = int(url.rsplit(":", 1)[1].split("/")[0])
    probe = _socket.socket()
    probe.settimeout(5)
    try:
        probe.connect(("127.0.0.1", port))
        return False
    except OSError:
        return True
    finally:
        probe.close()


def test_withheld_leg_records_and_passes(mod, tmp):
    if getattr(mod, "_WithholdingForwarder", None) is None or not hasattr(
        mod.Journey, "withheld_leg"
    ):
        check(
            "withheld-leg-records-and-passes",
            False,
            "the withheld leg is absent",
        )
        return
    refusal = {
        "command": "inspect",
        "outcome": "stale-state",
        "reason": "TrieState HistoryIncomplete",
        "trieRefusal": {
            "registry": {"policy": "aabbcc", "name": "ddeeff"},
            "cause": "missing-transaction",
        },
    }
    journey, urls, fake_run_party = _withheld_mocked_leg(
        mod, tmp, lambda: (14, dict(refusal))
    )
    with mock.patch.object(journey, "run_party", fake_run_party):
        try:
            leg = journey.withheld_leg("alice", "alice-2")
        except Exception as error:  # noqa: BLE001 - escaping is the finding
            check(
                "withheld-leg-records-and-passes",
                False,
                f"escaped as {type(error).__name__}: {error}",
            )
            return
    check(
        "withheld-leg-records-and-passes",
        leg.get("positive_inspect") == "withheld-positive-inspect"
        and leg.get("withheld_inspect") == "withheld-inspect"
        and leg.get("create") == "create",
        f"leg slots are {leg}",
    )
    check(
        "withheld-inspect-uses-forwarder",
        bool(urls) and urls[0].startswith("http://127.0.0.1:"),
        f"withheld koios urls are {urls}",
    )
    check(
        "withheld-forwarder-stops",
        bool(urls) and _forwarder_port_closed(urls[0]),
        "the forwarder still serves after the leg",
    )
    legs = {"withheld": leg, "alice": {"fold": "withheld-alice-fold"}}
    passed, _, waiting = journey.withheld_fold_agreement(legs, Path(tmp))
    check(
        "withheld-leg-agreement-passes",
        passed,
        f"the leg receipts did not pass: {waiting}",
    )


def test_forwarder_stops_after_leg_failure(mod, tmp):
    if getattr(mod, "_WithholdingForwarder", None) is None or not hasattr(
        mod.Journey, "withheld_leg"
    ):
        check(
            "forwarder-stops-after-leg-failure",
            False,
            "the withheld leg is absent",
        )
        return

    def accepted():
        raise mod.JourneyFailure("the withheld inspect was accepted")

    journey, urls, fake_run_party = _withheld_mocked_leg(mod, tmp, accepted)
    with mock.patch.object(journey, "run_party", fake_run_party):
        try:
            journey.withheld_leg("alice", "alice-2")
        except mod.JourneyFailure:
            failed_as_row = True
        except Exception as error:  # noqa: BLE001 - wrong mapping is the finding
            check(
                "forwarder-stops-after-leg-failure",
                False,
                f"mapped to {type(error).__name__}, want JourneyFailure",
            )
            return
        else:
            check(
                "forwarder-stops-after-leg-failure",
                False,
                "an accepted withheld inspect claimed success",
            )
            return
    check(
        "forwarder-stops-after-leg-failure",
        failed_as_row and bool(urls) and _forwarder_port_closed(urls[0]),
        "the failure escaped teardown or the row result",
    )


def _fold_set_bases(tmp):
    policy = "aa" * 28
    name = "bb" * 16
    token = f"{policy}.{name}"
    root = "cc" * 32
    txs = {
        slot: ("%02d" % index) * 32
        for index, slot in enumerate(
            ("actor-a", "actor-b", "term-1", "term-2", "cross-1", "cross-2", "continue")
        )
    }
    _write_receipt(
        tmp,
        "foldset-create",
        {"command": "create", "outcome": "success", "stateToken": token},
    )
    _write_receipt(
        tmp,
        "foldset-positive",
        {
            "command": "inspect",
            "outcome": "success",
            "root": root,
            "leaf": "active",
            "pendingRequests": [],
        },
    )
    folds = {
        "foldset-fold-a": txs["actor-a"],
        "foldset-fold-b": txs["actor-b"],
        "foldset-fold-t1": txs["term-1"],
        "foldset-fold-t2": txs["term-2"],
        "foldset-fold-c1": txs["cross-1"],
        "foldset-fold-c2": txs["cross-2"],
        "foldset-fold-continue": txs["continue"],
    }
    for receipt, tx in folds.items():
        _write_receipt(
            tmp,
            receipt,
            {
                "command": "fold",
                "outcome": "success",
                "root": root,
                "fold": tx,
            },
        )
    records = [
        {"fold": name, "key": "k", "inspect_a": "ia", "inspect_b": "ib"}
        for name in folds
    ]
    legs = {
        "altered": {
            "create": "foldset-create",
            "positive_inspect": "foldset-positive",
            "altered_inspect": "foldset-altered",
        },
        "alice": {"fold": "foldset-fold-a"},
        "bob": {"fold": "foldset-fold-b"},
        "terminate-bob-by-alice": {"fold": "foldset-fold-t1"},
        "terminate-alice-by-bob": {"fold": "foldset-fold-t2"},
        "cross-insert": {
            "alice-books": {"fold": "foldset-fold-c1"},
            "bob-books": {"fold": "foldset-fold-c2"},
        },
        "fold_roots": records,
    }
    return legs, txs, Path(tmp), policy, name, root


def _write_foldset_refusal(tmp, tx, policy, name):
    import json as _json

    doc = {
        "command": "inspect",
        "outcome": "stale-state",
        "reason": "TrieState RootDoesNotChain",
        "trieRefusal": {
            "registry": {"policy": policy, "name": name},
            "transaction": tx,
            "cause": "roots-part",
            "rebuiltRoot": "ee" * 32,
            "recordedRoot": "cc" * 32,
        },
    }
    Path(tmp, "foldset-altered.json").write_text(_json.dumps(doc) + "\n")
    Path(tmp, "foldset-altered.exit").write_text("14\n")


def test_fold_set_derived_from_record(mod, tmp):
    legs, txs, receipts, policy, name, _root = _fold_set_bases(tmp)
    journey = bare(mod, tmp)
    expected = set(txs.values())
    got = journey._journey_fold_txs(legs, receipts)
    check(
        "fold-set-derived-complete",
        got == expected,
        f"the set misses {sorted(expected - got)}" if got != expected else "",
    )
    failures = []
    for slot, tx in sorted(txs.items()):
        _write_foldset_refusal(tmp, tx, policy, name)
        passed, _, waiting = journey.altered_edge_agreement(legs, receipts)
        if not passed:
            failures.append(f"{slot}: {waiting}")
    check(
        "fold-set-every-held-fold-passes",
        not failures,
        "; ".join(failures) if failures else "",
    )
    _write_foldset_refusal(tmp, "ff" * 32, policy, name)
    passed_foreign, _, _ = journey.altered_edge_agreement(legs, receipts)
    check(
        "fold-set-foreign-transaction-does-not-pass",
        not passed_foreign,
        "a refusal naming a foreign transaction still passed",
    )


def test_fold_set_missing_record_excludes(mod, tmp):
    import json as _json

    legs, txs, receipts, policy, name, _root = _fold_set_bases(tmp)
    journey = bare(mod, tmp)
    failures = []
    for record in legs["fold_roots"]:
        receipt = Path(tmp, f"{record['fold']}.json")
        tx = _json.loads(receipt.read_text())["fold"]
        _write_foldset_refusal(tmp, tx, policy, name)
        passed_held, _, waiting = journey.altered_edge_agreement(legs, receipts)
        if not passed_held:
            failures.append(f"held {record['fold']}: {waiting}")
        trimmed = [entry for entry in legs["fold_roots"] if entry != record]
        legs_dropped = dict(legs, fold_roots=trimmed)
        passed_dropped, _, _ = journey.altered_edge_agreement(legs_dropped, receipts)
        if passed_dropped:
            failures.append(f"dropped {record['fold']} still passed")
    check(
        "fold-set-missing-record-excludes",
        not failures,
        "; ".join(failures) if failures else "",
    )


def test_start_runtime_allocation_failure_is_setup(mod, tmp):
    import tempfile as _tempfile

    journey = bare(mod, tmp)
    with mock.patch.object(
        _tempfile, "mkdtemp", side_effect=OSError("permission denied")
    ):
        status, out = quiet_execute(journey)
    check(
        "runtime-allocation-is-setup",
        status == 3,
        f"an unallocated runtime exited {status}, want 3",
    )
    check(
        "runtime-allocation-names-cause",
        "two actors: SETUP:" in out and "did not allocate" in out,
        "no setup line names the allocation cause",
    )
    check(
        "runtime-allocation-is-no-row",
        "two actors: FAIL:" not in out,
        "an allocation failure computed a row result",
    )


def test_runtime_removal_failure_is_setup(mod, tmp):
    import shutil as _shutil

    journey = bare(mod, tmp)
    runtime = Path(tmp) / "stuck-runtime"
    runtime.mkdir(exist_ok=True)
    journey.runtime = runtime
    with mock.patch.object(
        _shutil, "rmtree", side_effect=OSError("read-only filesystem")
    ):
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                journey.stop_devnet()
        except mod.SetupFailure as failed:
            check(
                "runtime-removal-names-cause",
                "did not clean" in str(failed) and "read-only" in str(failed),
                f"SetupFailure={failed}",
            )
        except Exception as error:  # noqa: BLE001 - wrong mapping is the finding
            check(
                "runtime-removal-names-cause",
                False,
                f"mapped to {type(error).__name__}, want SetupFailure",
            )
        else:
            check(
                "runtime-removal-names-cause",
                False,
                "a refused removal claimed clean",
            )


def test_runtime_removal_failure_flows(mod, tmp):
    import shutil as _shutil

    runtime = Path(tmp) / "stuck-runtime-flow"
    runtime.mkdir(exist_ok=True)

    def _boom_fixture(self):
        self.runtime = runtime
        raise mod.SetupFailure("injected")

    journey = bare(mod, tmp)
    journey.fixture = _boom_fixture.__get__(journey, mod.Journey)
    with mock.patch.object(
        _shutil, "rmtree", side_effect=OSError("read-only filesystem")
    ):
        status, out = quiet_execute(journey)
    check(
        "runtime-removal-flow-is-setup",
        status == 3,
        f"a removal failure exited {status}, want 3",
    )
    check(
        "runtime-removal-flow-names-cause",
        "did not clean" in out and "two actors: FAIL:" not in out,
        "no setup line names the removal cause without a row result",
    )
    journey_guard = bare(mod, tmp)
    journey_guard.runtime = runtime
    journey_guard.fixture = lambda: (_ for _ in ()).throw(
        mod.GuardFired("/w/bob-home/journal.jsonl")
    )
    with mock.patch.object(
        _shutil, "rmtree", side_effect=OSError("read-only filesystem")
    ):
        status_guard, out_guard = quiet_execute(journey_guard)
    check(
        "runtime-removal-keeps-guard",
        status_guard == 2 and "GUARD:" in out_guard,
        f"a removal failure overrode the guard with {status_guard}",
    )


def test_report_lists_marked_appendix_after_rows(mod, tmp):
    import contextlib as _contextlib
    import io as _io
    import json as _json

    journey = bare(mod, tmp)
    journey.appendix = [
        {"process": "alice withheld-inspect", "accessTrace": "/t/access"},
        {"fixture": "development-network-and-registry", "stateToken": "p.n"},
    ]
    rows = [
        {
            "requirement": "R1",
            "state": "passed",
            "receipts": [],
            "dependencies": [],
            "waitingOn": "",
        },
        {
            "requirement": "R2",
            "state": "pending",
            "receipts": [],
            "dependencies": [],
            "waitingOn": "later",
        },
    ]
    out = _io.StringIO()
    with _contextlib.redirect_stdout(out):
        journey.report(rows)
    lines = out.getvalue().splitlines()
    row_positions = [
        i for i, line in enumerate(lines) if ": passed" in line or ": pending" in line
    ]
    appendix_positions = [
        i for i, line in enumerate(lines) if "harness evidence" in line
    ]
    check(
        "report-appendix-after-rows",
        bool(row_positions)
        and bool(appendix_positions)
        and max(row_positions) < min(appendix_positions),
        "no harness-evidence appendix follows the product rows",
    )
    check(
        "report-appendix-labelled",
        any("harness's own, not product rows" in line for line in lines),
        "no label marks the appendix as the harness's own evidence",
    )
    check(
        "report-appendix-lists-entries",
        any("withheld-inspect" in line for line in lines)
        and any("fixture" in line for line in lines),
        "traces and fixture creation are not both listed",
    )
    stored = _json.loads(Path(tmp, "journey.json").read_text())
    check(
        "report-json-appendix-after-rows",
        list(stored.keys()) == ["requirements", "harnessAppendix"]
        and stored["harnessAppendix"] == journey.appendix,
        "journey.json carries no appendix after the product rows",
    )


def _replay_fault_mocked(mod, tmp, faulted_outcome):
    journey = bare(mod, tmp)
    journey.singular = "faulted-singular"
    journey.state_token = "aabbcc.ddeeff"
    root = "cc" * 32
    fold_tx = "dd" * 32
    _write_receipt(
        tmp,
        "create",
        {"command": "create", "outcome": "success", "stateToken": "aabbcc.ddeeff"},
    )
    _write_receipt(
        tmp,
        "rf-inspect-after",
        {
            "command": "inspect",
            "outcome": "success",
            "root": root,
            "leaf": "active",
            "pendingRequests": [],
        },
    )
    _write_receipt(
        tmp,
        "rf-fold",
        {
            "command": "fold",
            "outcome": "success",
            "request": "rfreq#0",
            "edge": "insertActive",
            "folder": "ff",
            "root": root,
            "fold": fold_tx,
        },
    )
    setup_leg = {
        "inspect_before": "rf-inspect-before",
        "booking": "rf-booking",
        "fold": "rf-fold",
        "inspect_after": "rf-inspect-after",
    }

    def fake_run_party(party, name, arguments, forbidden):
        assert "--state-token" in arguments, "an actor command without --state-token"
        if name == "replay-fault-inspect-bob":
            return 0, {
                "command": "inspect",
                "outcome": "success",
                "root": root,
                "leaf": "active",
                "pendingRequests": [],
            }
        if name == "replay-fault-inspect":
            return faulted_outcome()
        raise AssertionError(f"unexpected command {name}")

    return journey, setup_leg, fake_run_party


def test_replay_fault_control_passes(mod, tmp):
    if not hasattr(mod.Journey, "replay_fault_legs"):
        check(
            "replay-fault-control-passes",
            False,
            "the replay-fault control is absent",
        )
        return
    refusal = {
        "command": "inspect",
        "outcome": "stale-state",
        "reason": "TrieState RootDoesNotChain",
        "trieRefusal": {
            "registry": {"policy": "aabbcc", "name": "ddeeff"},
            "transaction": "dd" * 32,
            "cause": "roots-part",
            "rebuiltRoot": "ee" * 32,
            "recordedRoot": "cc" * 32,
        },
    }
    journey, setup_leg, fake_run_party = _replay_fault_mocked(
        mod, tmp, lambda: (14, dict(refusal))
    )
    _write_receipt(tmp, "replay-fault-inspect", refusal, exit_code=14)
    with mock.patch.dict(os.environ, {"SINGULAR_UNFAULTED": "unpatched-singular"}):
        with mock.patch.object(journey, "fixture", lambda: None):
            with mock.patch.object(journey, "actor_leg", lambda *a: dict(setup_leg)):
                with mock.patch.object(journey, "run_party", fake_run_party):
                    try:
                        legs = journey.replay_fault_legs()
                    except Exception as error:  # noqa: BLE001 - escape is the finding
                        check(
                            "replay-fault-control-passes",
                            False,
                            f"escaped as {type(error).__name__}: {error}",
                        )
                        return
    check(
        "replay-fault-uses-unpatched-setup",
        journey.singular == "faulted-singular",
        "the faulted binary was not restored after setup",
    )
    check(
        "replay-fault-records-altered-leg",
        legs.get("altered", {}).get("altered_inspect") == "replay-fault-inspect"
        and legs.get("altered", {}).get("create") == "create",
        f"altered leg slots are {legs.get('altered')}",
    )
    full = dict(legs, fold_roots=getattr(journey, "fold_records", []))
    passed, _, waiting = journey.altered_edge_agreement(full, Path(tmp))
    check(
        "replay-fault-control-passes",
        passed,
        f"the control receipts did not pass: {waiting}",
    )
    check(
        "replay-fault-status-is-zero",
        journey.replay_fault_status(full) == 0,
        "a passing control did not map to exit 0",
    )


def test_replay_fault_control_accepted_is_row_failure(mod, tmp):
    if not hasattr(mod.Journey, "replay_fault_legs"):
        check(
            "replay-fault-accepted-is-row-failure",
            False,
            "the replay-fault control is absent",
        )
        return

    def accepted():
        return 0, {"command": "inspect", "outcome": "success", "root": "cc" * 32}

    journey, setup_leg, fake_run_party = _replay_fault_mocked(mod, tmp, accepted)
    with mock.patch.dict(os.environ, {"SINGULAR_UNFAULTED": "unpatched-singular"}):
        with mock.patch.object(journey, "fixture", lambda: None):
            with mock.patch.object(journey, "actor_leg", lambda *a: dict(setup_leg)):
                with mock.patch.object(journey, "run_party", fake_run_party):
                    try:
                        journey.replay_fault_legs()
                    except mod.JourneyFailure:
                        check("replay-fault-accepted-is-row-failure", True)
                    except Exception as error:  # noqa: BLE001 - wrong mapping
                        check(
                            "replay-fault-accepted-is-row-failure",
                            False,
                            f"mapped to {type(error).__name__}, want JourneyFailure",
                        )
                    else:
                        check(
                            "replay-fault-accepted-is-row-failure",
                            False,
                            "an accepted faulted inspect claimed success",
                        )


def test_replay_fault_control_needs_unpatched(mod, tmp):
    if not hasattr(mod.Journey, "replay_fault_legs"):
        check(
            "replay-fault-needs-unpatched",
            False,
            "the replay-fault control is absent",
        )
        return
    journey = bare(mod, tmp)
    with mock.patch.dict(os.environ, {}, clear=True):
        try:
            journey.replay_fault_legs()
        except mod.SetupFailure as failed:
            check(
                "replay-fault-needs-unpatched",
                "unpatched" in str(failed),
                f"SetupFailure={failed}",
            )
        except Exception as error:  # noqa: BLE001 - wrong mapping is the finding
            check(
                "replay-fault-needs-unpatched",
                False,
                f"mapped to {type(error).__name__}, want SetupFailure",
            )
        else:
            check(
                "replay-fault-needs-unpatched",
                False,
                "a control without its unpatched binary claimed success",
            )


def test_replay_fault_status_maps(mod, tmp):
    if not hasattr(mod.Journey, "replay_fault_status"):
        check(
            "replay-fault-status-maps",
            False,
            "the replay-fault verdict is absent",
        )
        return
    journey = bare(mod, tmp)
    legs, _txs, receipts, policy, name, _root = _fold_set_bases(tmp)
    _write_foldset_refusal(tmp, "ff" * 32, policy, name)
    with contextlib.redirect_stdout(io.StringIO()):
        failed_status = journey.replay_fault_status(legs)
    check(
        "replay-fault-status-maps",
        failed_status == 1,
        f"a pending control mapped to {failed_status}, want 1",
    )


def test_forwarder_thread_start_failure_is_setup_and_teardown(mod, tmp):
    import threading as _threading

    forward_cls = getattr(mod, "_WithholdingForwarder", None)
    if forward_cls is None:
        check(
            "forwarder-thread-start-is-setup",
            False,
            "_WithholdingForwarder is absent",
        )
        return
    forward = forward_cls("http://127.0.0.1:9/api/v1", "aa", "bb")
    with mock.patch.object(
        _threading.Thread, "start", side_effect=RuntimeError("cannot start thread")
    ):
        try:
            forward.start()
        except mod.SetupFailure as failed:
            check(
                "forwarder-thread-start-is-setup",
                "thread" in str(failed) and "cannot start thread" in str(failed),
                f"SetupFailure={failed}",
            )
        except Exception as error:  # noqa: BLE001 - wrong mapping is the finding
            check(
                "forwarder-thread-start-is-setup",
                False,
                f"mapped to {type(error).__name__}: {error}",
            )
            # Leave the bound socket to stop(): on the pre-repair harness
            # shutdown() blocks forever on the loop that never started,
            # which the bounded check below turns into a failure, not a hang.
    done = []

    def _stop():
        try:
            forward.stop()
        finally:
            done.append(True)

    watcher = _threading.Thread(target=_stop, daemon=True)
    watcher.start()
    watcher.join(timeout=15)
    check(
        "forwarder-stop-after-failed-start-completes",
        done == [True],
        "stop() hung on a serving loop that never started",
    )


def _pgrep_script(codes, seen):
    def fake_run(argv, **kwargs):
        if argv[0] == "pkill":
            return subprocess.CompletedProcess(argv, 1)
        if argv[0] == "pgrep":
            seen.append(argv[2])
            code, err = codes.pop(0) if codes else (1, "")
            return subprocess.CompletedProcess(argv, code, stderr=err)
        raise AssertionError(argv)

    return fake_run


def test_forwarder_close_error_is_setup_and_releases(mod, tmp):
    from http.server import ThreadingHTTPServer as _Server

    forward_cls = getattr(mod, "_WithholdingForwarder", None)
    if forward_cls is None:
        check(
            "forwarder-close-error-is-setup",
            False,
            "_WithholdingForwarder is absent",
        )
        return
    forward = forward_cls("http://127.0.0.1:9/api/v1", "aa", "bb")
    forward.start()
    joined = []
    real_join = forward.thread.join

    def _join(timeout=None):
        joined.append(timeout)
        return real_join(timeout)

    with mock.patch.object(_Server, "server_close", side_effect=OSError("denied")):
        with mock.patch.object(forward.thread, "join", _join):
            try:
                forward.stop()
            except mod.SetupFailure as failed:
                stopped = f"SetupFailure: {failed}"
            except Exception as error:  # noqa: BLE001 - wrong mapping is the finding
                stopped = f"{type(error).__name__}: {error}"
            else:
                stopped = "clean"
    check(
        "forwarder-close-error-is-setup",
        stopped.startswith("SetupFailure") and "denied" in stopped,
        f"a refused close gave {stopped}",
    )
    check(
        "forwarder-close-error-still-joins",
        bool(joined),
        "a failed close skipped the thread join",
    )


def test_forwarder_shutdown_error_releases(mod, tmp):
    from http.server import ThreadingHTTPServer as _Server

    forward_cls = getattr(mod, "_WithholdingForwarder", None)
    if forward_cls is None:
        check(
            "forwarder-shutdown-error-releases",
            False,
            "_WithholdingForwarder is absent",
        )
        return
    forward = forward_cls("http://127.0.0.1:9/api/v1", "aa", "bb")
    forward.start()
    closed = []
    real_close = forward.server.server_close

    def _close():
        closed.append(True)
        return real_close()

    with mock.patch.object(_Server, "shutdown", side_effect=OSError("broken")):
        with mock.patch.object(forward.server, "server_close", _close):
            try:
                forward.stop()
            except mod.SetupFailure as failed:
                stopped = f"SetupFailure: {failed}"
            except Exception as error:  # noqa: BLE001 - wrong mapping is the finding
                stopped = f"{type(error).__name__}: {error}"
            else:
                stopped = "clean"
    check(
        "forwarder-shutdown-error-is-setup",
        stopped.startswith("SetupFailure") and "broken" in stopped,
        f"a refused shutdown gave {stopped}",
    )
    check(
        "forwarder-shutdown-error-still-closes",
        bool(closed),
        "a failed shutdown skipped the socket close",
    )


def test_forwarder_join_survivor_is_setup(mod, tmp):
    forward_cls = getattr(mod, "_WithholdingForwarder", None)
    if forward_cls is None:
        check(
            "forwarder-join-survivor-is-setup",
            False,
            "_WithholdingForwarder is absent",
        )
        return
    forward = forward_cls("http://127.0.0.1:9/api/v1", "aa", "bb")
    forward.start()
    with mock.patch.object(forward.thread, "join", lambda timeout=None: None):
        with mock.patch.object(forward.thread, "is_alive", lambda: True):
            try:
                forward.stop()
            except mod.SetupFailure as failed:
                stopped = f"SetupFailure: {failed}"
            except Exception as error:  # noqa: BLE001 - wrong mapping is the finding
                stopped = f"{type(error).__name__}: {error}"
            else:
                stopped = "clean"
    try:
        forward.stop()
    except Exception:
        pass
    check(
        "forwarder-join-survivor-is-setup",
        stopped.startswith("SetupFailure") and "serving after timeout" in stopped,
        f"a surviving thread gave {stopped}",
    )


def test_withheld_cleanup_failure_keeps_setup_and_receipts(mod, tmp):
    import json as _json
    from http.server import ThreadingHTTPServer as _Server

    if getattr(mod, "_WithholdingForwarder", None) is None or not hasattr(
        mod.Journey, "withheld_leg"
    ):
        check(
            "withheld-cleanup-failure-keeps-setup",
            False,
            "the withheld leg is absent",
        )
        return
    refusal = {
        "command": "inspect",
        "outcome": "stale-state",
        "reason": "TrieState HistoryIncomplete",
        "trieRefusal": {
            "registry": {"policy": "aabbcc", "name": "ddeeff"},
            "cause": "missing-transaction",
        },
    }
    journey, _urls, fake_run_party = _withheld_mocked_leg(
        mod, tmp, lambda: (14, dict(refusal))
    )
    with mock.patch.object(_Server, "server_close", side_effect=OSError("denied")):
        with mock.patch.object(journey, "run_party", fake_run_party):
            try:
                journey.withheld_leg("alice", "alice-2")
            except mod.SetupFailure:
                kept_setup = True
            except Exception as error:  # noqa: BLE001 - row status is the finding
                kept_setup = f"{type(error).__name__}: {error}"
            else:
                kept_setup = "clean"
    raw = Path(tmp, "withheld-inspect.json").read_text()
    check(
        "withheld-cleanup-failure-keeps-setup",
        kept_setup is True,
        f"a cleanup failure after the refusal gave {kept_setup}",
    )
    check(
        "withheld-cleanup-keeps-refusal",
        _json.loads(raw).get("outcome") == "stale-state",
        "the observed refusal did not survive cleanup",
    )


def test_pgrep_exit_2_and_3_are_setup(mod, tmp):
    # Every pattern (neutral, runtime) at both sites (settle loop, final
    # check): only exit 1 means nothing found; 2/3 are named setup failures.
    # Names are literal so the inventory script finds each control by name.
    cases = [
        ("pgrep-loop-0-2-is-setup", 0, 2, "pgrep: syntax error"),
        ("pgrep-loop-0-3-is-setup", 0, 3, "pgrep: fatal"),
        ("pgrep-loop-1-2-is-setup", 1, 2, "pgrep: syntax error"),
        ("pgrep-loop-1-3-is-setup", 1, 3, "pgrep: fatal"),
        ("pgrep-final-2-2-is-setup", 2, 2, "pgrep: syntax error"),
        ("pgrep-final-2-3-is-setup", 2, 3, "pgrep: fatal"),
        ("pgrep-final-3-2-is-setup", 3, 2, "pgrep: syntax error"),
        ("pgrep-final-3-3-is-setup", 3, 3, "pgrep: fatal"),
    ]
    sites = ("loop", "loop", "final", "final")
    for name, position, exit_code, diagnostic in cases:
        site = sites[position]
        journey = bare(mod, tmp)
        journey.runtime = Path(tmp) / f"rt-{name}"
        journey.runtime.mkdir(exist_ok=True)
        codes = [(1, "")] * position + [(exit_code, diagnostic)]
        seen = []
        out = io.StringIO()
        with mock.patch.object(mod.subprocess, "run", _pgrep_script(codes, seen)):
            with contextlib.redirect_stdout(out):
                try:
                    journey.stop_devnet()
                except mod.SetupFailure as failed:
                    stopped = f"{type(failed).__name__}: {failed}"
                except Exception as error:  # noqa: BLE001 - wrong mapping
                    stopped = f"{type(error).__name__}: {error}"
                else:
                    stopped = "clean"
        text = out.getvalue()
        check(
            name,
            stopped.startswith("SetupFailure")
            and "process query failed" in stopped
            and str(exit_code) in stopped
            and diagnostic in stopped
            and "owned processes: none" not in text,
            f"{site} call {position} exit {exit_code} gave {stopped}",
        )
    journey = bare(mod, tmp)
    journey.runtime = Path(tmp) / "rt-clean"
    journey.runtime.mkdir(exist_ok=True)
    seen = []
    out = io.StringIO()
    with mock.patch.object(mod.subprocess, "run", _pgrep_script([], seen)):
        with contextlib.redirect_stdout(out):
            journey.stop_devnet()
    check(
        "pgrep-clean-queries-both-patterns",
        "owned processes: none" in out.getvalue()
        and any(str(journey.neutral) in pattern for pattern in seen)
        and any("rt-clean" in pattern for pattern in seen),
        f"patterns seen: {seen}",
    )
    check(
        "stop-receipt-prints-query-exits",
        "survivor query neutral exit=1" in out.getvalue()
        and "survivor query runtime exit=1" in out.getvalue(),
        "the stop receipt names no per-pattern query exit",
    )


def test_pkill_failure_is_best_effort(mod, tmp):
    journey = bare(mod, tmp)
    runtime = Path(tmp) / "rt-pkill"
    runtime.mkdir(exist_ok=True)
    journey.runtime = runtime
    out = io.StringIO()
    with mock.patch.object(mod.subprocess, "run", _pgrep_script([], [])):
        with contextlib.redirect_stdout(out):
            journey.stop_devnet()
    check(
        "pkill-failure-is-best-effort",
        "owned processes: none" in out.getvalue() and not runtime.exists(),
        "a best-effort kill failure failed teardown or leaked the runtime",
    )


def test_pgrep_failure_flows(mod, tmp):
    journey = bare(mod, tmp)

    def _boom(self):
        self.runtime = Path(tmp) / "rt-flow"
        self.runtime.mkdir(exist_ok=True)
        raise mod.SetupFailure("injected")

    journey.fixture = _boom.__get__(journey, mod.Journey)
    with mock.patch.object(mod.subprocess, "run", _pgrep_script([], [])):
        with mock.patch.object(
            mod.shutil, "rmtree", side_effect=OSError("read-only filesystem")
        ):
            status, out = quiet_execute(journey)
    check(
        "pgrep-failure-flow-is-setup",
        status == 3,
        f"a removal failure exited {status}, want 3",
    )
    check(
        "pgrep-failure-flow-names-cause",
        "did not clean" in out and "two actors: FAIL:" not in out,
        "no setup line names the removal cause without a row result",
    )
    journey_guard = bare(mod, tmp)
    journey_guard.runtime = Path(tmp) / "rt-flow-guard"
    journey_guard.runtime.mkdir(exist_ok=True)
    journey_guard.fixture = lambda: (_ for _ in ()).throw(
        mod.GuardFired("/w/bob-home/journal.jsonl")
    )
    with mock.patch.object(mod.subprocess, "run", _pgrep_script([], [])):
        with mock.patch.object(
            mod.shutil, "rmtree", side_effect=OSError("read-only filesystem")
        ):
            status_guard, out_guard = quiet_execute(journey_guard)
    check(
        "pgrep-failure-flow-keeps-guard",
        status_guard == 2 and "GUARD:" in out_guard,
        f"a removal failure overrode the guard with {status_guard}",
    )


def _altered_mocked(mod, tmp, faulted_outcome):
    journey = bare(mod, tmp)
    journey.singular = "journey-singular"
    journey.state_token = "aabbcc.ddeeff"
    root = "cc" * 32
    positive = {
        "command": "inspect",
        "outcome": "success",
        "root": root,
        "leaf": "active",
        "pendingRequests": [],
    }
    _write_receipt(tmp, "altered-positive-inspect", positive)
    _write_receipt(
        tmp,
        "create",
        {"command": "create", "outcome": "success", "stateToken": "aabbcc.ddeeff"},
    )
    _write_receipt(
        tmp,
        "altered-alice-fold",
        {
            "command": "fold",
            "outcome": "success",
            "root": root,
            "fold": "dd" * 32,
        },
    )
    seen_binaries = []

    def fake_run_party(party, name, arguments, forbidden):
        assert "--state-token" in arguments, "an actor command without --state-token"
        if name == "altered-positive-inspect":
            return 0, dict(positive)
        if name == "altered-inspect":
            seen_binaries.append(journey.singular)
            return faulted_outcome()
        raise AssertionError(f"unexpected command {name}")

    return journey, seen_binaries, fake_run_party


def test_altered_leg_records_and_passes(mod, tmp):
    if not hasattr(mod.Journey, "altered_leg"):
        check(
            "altered-leg-records-and-passes",
            False,
            "the altered journey leg is absent",
        )
        return
    refusal = {
        "command": "inspect",
        "outcome": "stale-state",
        "reason": "TrieState RootDoesNotChain",
        "trieRefusal": {
            "registry": {"policy": "aabbcc", "name": "ddeeff"},
            "transaction": "dd" * 32,
            "cause": "roots-part",
            "rebuiltRoot": "ee" * 32,
            "recordedRoot": "cc" * 32,
        },
    }
    journey, seen_binaries, fake_run_party = _altered_mocked(
        mod, tmp, lambda: (14, dict(refusal))
    )
    _write_receipt(tmp, "altered-inspect", refusal, exit_code=14)
    with mock.patch.dict(os.environ, {"SINGULAR_REPLAY_FAULT": "faulted-singular"}):
        with mock.patch.object(journey, "run_party", fake_run_party):
            try:
                leg = journey.altered_leg("bob", "bob-2")
            except Exception as error:  # noqa: BLE001 - escape is the finding
                check(
                    "altered-leg-records-and-passes",
                    False,
                    f"escaped as {type(error).__name__}: {error}",
                )
                return
    check(
        "altered-leg-runs-faulted-binary",
        seen_binaries == ["faulted-singular"],
        f"faulted inspect ran on {seen_binaries}",
    )
    check(
        "altered-leg-restores-binary",
        journey.singular == "journey-singular",
        "the journey binary was not restored after the faulted inspect",
    )
    check(
        "altered-leg-records-and-passes",
        leg is not None
        and leg.get("positive_inspect") == "altered-positive-inspect"
        and leg.get("altered_inspect") == "altered-inspect"
        and leg.get("create") == "create",
        f"leg slots are {leg}",
    )
    legs = {
        "altered": leg,
        "fold_roots": [
            {
                "fold": "altered-alice-fold",
                "key": "k",
                "inspect_a": "ia",
                "inspect_b": "ib",
            }
        ],
    }
    passed, _, waiting = journey.altered_edge_agreement(legs, Path(tmp))
    check(
        "altered-leg-agreement-passes",
        passed,
        f"the leg receipts did not pass: {waiting}",
    )


def test_altered_leg_skips_without_faulted_binary(mod, tmp):
    if not hasattr(mod.Journey, "altered_leg"):
        check(
            "altered-leg-skips-without-faulted-binary",
            False,
            "the altered journey leg is absent",
        )
        return
    journey = bare(mod, tmp)
    with mock.patch.dict(os.environ, {}, clear=True):
        try:
            leg = journey.altered_leg("bob", "bob-2")
        except Exception as error:  # noqa: BLE001 - skip must not raise
            check(
                "altered-leg-skips-without-faulted-binary",
                False,
                f"a skipped leg raised {type(error).__name__}: {error}",
            )
            return
    check(
        "altered-leg-skips-without-faulted-binary",
        leg is None,
        f"a leg without its faulted binary returned {leg}",
    )


def test_altered_leg_accepted_is_row_failure(mod, tmp):
    if not hasattr(mod.Journey, "altered_leg"):
        check(
            "altered-leg-accepted-is-row-failure",
            False,
            "the altered journey leg is absent",
        )
        return

    def accepted():
        return 0, {"command": "inspect", "outcome": "success", "root": "cc" * 32}

    journey, _seen, fake_run_party = _altered_mocked(mod, tmp, accepted)
    with mock.patch.dict(os.environ, {"SINGULAR_REPLAY_FAULT": "faulted-singular"}):
        with mock.patch.object(journey, "run_party", fake_run_party):
            try:
                journey.altered_leg("bob", "bob-2")
            except mod.JourneyFailure:
                check("altered-leg-accepted-is-row-failure", True)
            except Exception as error:  # noqa: BLE001 - wrong mapping
                check(
                    "altered-leg-accepted-is-row-failure",
                    False,
                    f"mapped to {type(error).__name__}, want JourneyFailure",
                )
            else:
                check(
                    "altered-leg-accepted-is-row-failure",
                    False,
                    "an accepted faulted inspect claimed success",
                )


def test_killpg_failure_is_setup_and_continues(mod, tmp):
    journey = bare(mod, tmp)
    journey.node = mock.Mock(pid=12345)
    journey.node.wait.return_value = None
    runtime = Path(tmp) / "rt-killpg"
    runtime.mkdir(exist_ok=True)
    journey.runtime = runtime
    out = io.StringIO()
    with mock.patch.object(mod.os, "killpg", side_effect=PermissionError("denied")):
        with mock.patch.object(mod.subprocess, "run", _pgrep_script([], [])):
            with contextlib.redirect_stdout(out):
                try:
                    journey.stop_devnet()
                except mod.SetupFailure as failed:
                    stopped = f"SetupFailure: {failed}"
                except Exception as error:  # noqa: BLE001 - wrong mapping
                    stopped = f"{type(error).__name__}: {error}"
                else:
                    stopped = "clean"
    check(
        "killpg-failure-is-setup",
        stopped.startswith("SetupFailure") and "denied" in stopped,
        f"a refused signal gave {stopped}",
    )
    check(
        "killpg-failure-still-tears-down",
        not runtime.exists() and "owned processes: none" not in out.getvalue(),
        "teardown stopped at the signal failure",
    )


def test_devnet_cause_read_fallback(mod, tmp):
    journey = bare(mod, tmp)
    journey.neutral = Path(tmp) / "no-such-dir"
    check(
        "devnet-cause-missing-file",
        journey._devnet_cause() == "no devnet.err",
        "a missing error file named no cause",
    )
    journey.neutral = Path(tmp)
    (Path(tmp) / "devnet.err").write_text("\n")
    check(
        "devnet-cause-empty-file",
        journey._devnet_cause() == "empty devnet.err",
        "an empty error file named no cause",
    )
    (Path(tmp) / "devnet.err").write_text("boot\nTimed out waiting for socket\n")
    check(
        "devnet-cause-names-tail",
        "Timed out waiting for socket" in journey._devnet_cause(),
        "the error tail is not named",
    )


def test_forwarder_relay_failure_is_502(mod, tmp):
    import json as _json
    import urllib.request as _url
    from http.server import BaseHTTPRequestHandler as _Handler
    from http.server import ThreadingHTTPServer as _Server

    forward_cls = getattr(mod, "_WithholdingForwarder", None)
    if forward_cls is None:
        check(
            "forwarder-relay-failure-is-502",
            False,
            "_WithholdingForwarder is absent",
        )
        return

    doomed = _Server(("127.0.0.1", 0), _Handler)
    doomed_port = doomed.server_address[1]
    doomed.server_close()
    forward = forward_cls(f"http://127.0.0.1:{doomed_port}/api/v1", "aa", "bb")
    forward.start()
    try:
        request = _url.Request(forward.url + "/tip")
        try:
            with _url.urlopen(request, timeout=10) as answer:
                code, payload = answer.status, _json.loads(answer.read().decode())
        except Exception as error:  # noqa: BLE001 - urllib raises for 502
            import urllib.error as _err

            if isinstance(error, _err.HTTPError):
                code, payload = error.code, _json.loads(error.read().decode())
            else:
                raise
    finally:
        forward.stop()
    check(
        "forwarder-relay-failure-is-502",
        code == 502 and "error" in payload,
        f"a dead upstream gave {code} {payload!r}",
    )


def test_node_wait_timeout_continues_teardown(mod, tmp):
    journey = bare(mod, tmp)
    journey.node = mock.Mock(pid=12345)
    journey.node.wait.side_effect = mod.subprocess.TimeoutExpired("wait", 60)
    runtime = Path(tmp) / "rt-wait"
    runtime.mkdir(exist_ok=True)
    journey.runtime = runtime
    out = io.StringIO()
    with mock.patch.object(mod.subprocess, "run", _pgrep_script([], [])):
        with contextlib.redirect_stdout(out):
            try:
                journey.stop_devnet()
            except mod.SetupFailure as failed:
                stopped = f"SetupFailure: {failed}"
            except Exception as error:  # noqa: BLE001 - wrong mapping
                stopped = f"{type(error).__name__}: {error}"
            else:
                stopped = "clean"
    check(
        "node-wait-timeout-is-setup",
        stopped.startswith("SetupFailure") and "did not stop" in stopped,
        f"a stuck node gave {stopped}",
    )
    check(
        "node-wait-timeout-still-tears-down",
        not runtime.exists() and "owned processes: none" not in out.getvalue(),
        "teardown stopped at the stuck node",
    )


def test_which_missing_still_removes_runtime(mod, tmp):
    journey = bare(mod, tmp)
    runtime = Path(tmp) / "rt-no-tools"
    runtime.mkdir(exist_ok=True)
    journey.runtime = runtime
    out = io.StringIO()
    with mock.patch.object(mod, "which", lambda program: None):
        with contextlib.redirect_stdout(out):
            try:
                journey.stop_devnet()
            except mod.SetupFailure as failed:
                stopped = f"SetupFailure: {failed}"
            except Exception as error:  # noqa: BLE001 - wrong mapping
                stopped = f"{type(error).__name__}: {error}"
            else:
                stopped = "clean"
    check(
        "which-missing-is-setup",
        stopped.startswith("SetupFailure") and "cannot verify" in stopped,
        f"missing tools gave {stopped}",
    )
    check(
        "which-missing-still-removes-runtime",
        not runtime.exists() and "owned processes: none" not in out.getvalue(),
        "teardown stopped at the missing tools",
    )


def test_apps_supply_process_tools(mod, tmp):
    # The harness needs pkill/pgrep at teardown; an app that runs it must
    # supply procps, or any runner whose PATH lacks it fails setup. The
    # flake is resolved beside the harness, else beside the working tree.
    candidates = [
        Path(getattr(mod, "__file__", "tools/registry_two_actors.py")).parent.parent
        / "flake.nix",
        Path("flake.nix"),
    ]
    flake = next((path for path in candidates if path.exists()), None)
    if flake is None:
        check(
            "apps-supply-process-tools",
            False,
            "flake.nix not found beside the harness or the working tree",
        )
        return
    text = flake.read_text()
    missing = []
    for app in (
        "registry-two-actors",
        "registry-two-actors-control",
        "registry-two-actors-replay-fault",
    ):
        start = text.find(f'name = "{app}"')
        segment = text[start : start + 1200] if start >= 0 else ""
        if "runtimeInputs" not in segment or "procps" not in segment:
            missing.append(app)
    check(
        "apps-supply-process-tools",
        not missing,
        f"apps without procps: {missing}" if missing else "",
    )


def test_thread_construction_failure_is_setup(mod, tmp):
    import threading as _threading

    forward_cls = getattr(mod, "_WithholdingForwarder", None)
    if forward_cls is None:
        check(
            "thread-construction-failure-is-setup",
            False,
            "_WithholdingForwarder is absent",
        )
        return
    forward = forward_cls("http://127.0.0.1:9/api/v1", "aa", "bb")
    with mock.patch.object(
        _threading, "Thread", side_effect=RuntimeError("cannot construct thread")
    ):
        try:
            forward.start()
        except mod.SetupFailure as failed:
            stopped = f"SetupFailure: {failed}"
        except Exception as error:  # noqa: BLE001 - wrong mapping is the finding
            stopped = f"{type(error).__name__}: {error}"
        else:
            stopped = "clean"
    check(
        "thread-construction-failure-is-setup",
        stopped.startswith("SetupFailure") and "thread" in stopped,
        f"a refused thread construction gave {stopped}",
    )
    check(
        "thread-construction-frees-socket",
        getattr(forward, "server", None) is None,
        "a failed construction leaked the bound socket",
    )


def test_removal_check_flips_row(mod, tmp):
    journey = bare(mod, tmp)
    root = "cc" * 32
    booking_request = "abc123#0"
    owner_hex = "ownerhex000000000000000000000000000000000000000000000001"
    before = {
        "command": "inspect",
        "outcome": "success",
        "leaf": "unknown",
        "root": root,
        "pendingRequests": [],
    }
    booking = {
        "command": "insert",
        "outcome": "success",
        "request": booking_request,
        "requester": owner_hex,
    }
    fold = {
        "command": "fold",
        "outcome": "success",
        "request": booking_request,
        "edge": "insertActive",
        "folder": owner_hex,
        "root": root,
    }
    after = {
        "command": "inspect",
        "outcome": "success",
        "leaf": "active",
        "root": root,
        "pendingRequests": [],
    }
    _write_receipt(tmp, "removal-inspect-before", before)
    _write_receipt(tmp, "removal-booking", booking)
    # The removal control unlinks exactly this name; keep it literal.
    _write_receipt(tmp, "alice-fold", fold)
    _write_receipt(tmp, "removal-inspect-after", after)
    legs = {
        "alice": {
            "inspect_before": "removal-inspect-before",
            "booking": "removal-booking",
            "fold": "alice-fold",
            "inspect_after": "removal-inspect-after",
        }
    }
    passed, _, _ = journey.run_one_agreement("alice", legs["alice"], Path(tmp))
    check(
        "removal-check-valid-passes",
        passed,
        "the valid removal base did not pass",
    )
    try:
        journey.removal_check(legs)
    except Exception as error:  # noqa: BLE001 - escape is the finding
        check(
            "removal-check-flips-row",
            False,
            f"escaped as {type(error).__name__}: {error}",
        )
    else:
        check("removal-check-flips-row", True)


def test_environment_isolates_party_tmp(mod, tmp):
    journey = bare(mod, tmp)
    env = journey.environment("alice")
    party_tmp = Path(tmp) / "alice"
    check(
        "environment-isolates-party-tmp",
        env.get("HOME", "").endswith("alice-home")
        and env.get("TMPDIR", "") == str(party_tmp)
        and party_tmp.is_dir()
        and "XDG_STATE_HOME" not in env,
        "a party's home or temporary directory escapes its own root",
    )


def test_journey_init_creates_worktree(mod, tmp):
    work = Path(tmp) / "fresh-work"
    journey = mod.Journey.__new__(mod.Journey)
    try:
        mod.Journey.__init__(journey, "singular", "devnet", "blueprint", str(work))
    except Exception as error:  # noqa: BLE001 - escape is the finding
        check(
            "journey-init-creates-worktree",
            False,
            f"escaped as {type(error).__name__}: {error}",
        )
        return
    check(
        "journey-init-creates-worktree",
        (work / "devnet").is_dir()
        and (work / "receipts").is_dir()
        and (work / "creator-home").is_dir()
        and (work / "alice-home").is_dir()
        and (work / "bob-home").is_dir(),
        "fresh homes and receipt roots are missing",
    )


def test_koios_post_roundtrip(mod, tmp):
    import threading as _threading
    from http.server import BaseHTTPRequestHandler as _Handler
    from http.server import ThreadingHTTPServer as _Server

    class _Echo(_Handler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = _Server(("127.0.0.1", 0), _Echo)
    thread = _threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        answer = mod._koios_post(
            f"http://127.0.0.1:{server.server_address[1]}",
            "/echo",
            {"hello": "world"},
        )
    except Exception as error:  # noqa: BLE001 - escape is the finding
        answer = f"{type(error).__name__}: {error}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=10)
    check(
        "koios-post-roundtrip",
        answer == {"hello": "world"},
        f"a provider round trip gave {answer!r}",
    )


def _wrap_steps_for_injection(steps, index):
    ran = []

    def _record(name, action):
        def call():
            ran.append(name)
            return action()

        return call

    def _raise(name, kind):
        def call():
            ran.append(name)
            if kind == "launch":
                raise OSError(f"injected-{name}")
            raise RuntimeError(f"injected-{name}")

        return call

    wrapped = []
    for position, (name, kind, action) in enumerate(steps):
        if position <= index:
            wrapped.append((name, kind, _raise(name, kind)))
        else:
            wrapped.append((name, kind, _record(name, action)))
    return wrapped, ran


def _wrap_steps_for_injection(steps, index):
    ran = []

    def _record(name, action):
        def call():
            ran.append(name)
            return action()

        return call

    def _raise(name, kind):
        def call():
            ran.append(name)
            if kind == "launch":
                raise OSError(f"injected-{name}")
            raise RuntimeError(f"injected-{name}")

        return call

    wrapped = []
    for position, (name, kind, action) in enumerate(steps):
        if position <= index:
            wrapped.append((name, kind, _raise(name, kind)))
        else:
            wrapped.append((name, kind, _record(name, action)))
    return wrapped, ran


def test_stop_registry_total(mod, tmp):
    if not hasattr(mod.Journey, "_stop_release_steps"):
        check(
            "stop-registry-total",
            False,
            "the stop release registry is absent",
        )
        return
    template = bare(mod, tmp)
    template.runtime = Path(tmp) / "rt-registry-shape"
    template.runtime.mkdir(exist_ok=True)
    step_names = [name for name, _kind, _fn in template._stop_release_steps()]
    for index, (name, _kind, _fn) in enumerate(template._stop_release_steps()):
        run = bare(mod, tmp)
        run.runtime = Path(tmp) / f"rt-registry-{index}"
        run.runtime.mkdir(exist_ok=True)

        def _boom(self):
            raise mod.SetupFailure("injected")

        run.fixture = _boom.__get__(run, mod.Journey)
        wrapped, ran = _wrap_steps_for_injection(run._stop_release_steps(), index)
        with mock.patch.object(run, "_stop_release_steps", lambda: wrapped):
            status, out = quiet_execute(run)
        present = all(f"{step}:" in out for step in step_names[: index + 1])
        check(
            f"stop-registry-total-{name}",
            status == 3
            and present
            and set(ran) == set(step_names)
            and "two actors: FAIL:" not in out
            and "internal error" not in out
            and "owned processes: none" not in out,
            f"injecting {name} gave status={status} ran={sorted(ran)}",
        )


def test_forwarder_registry_total(mod, tmp):
    forward_cls = getattr(mod, "_WithholdingForwarder", None)
    if forward_cls is None or not hasattr(mod.Journey, "withheld_leg"):
        check(
            "forwarder-registry-total",
            False,
            "the forwarder release registry is absent",
        )
        return
    import json as _json

    step_methods = {
        "shutdown-if-serving": "_release_shutdown",
        "close": "_release_close",
        "join-and-check": "_release_join",
    }
    template = forward_cls("http://127.0.0.1:9/api/v1", "aa", "bb")
    step_names = [name for name, _kind, _fn in template._release_steps()]
    refusal = {
        "command": "inspect",
        "outcome": "stale-state",
        "reason": "TrieState HistoryIncomplete",
        "trieRefusal": {
            "registry": {"policy": "aabbcc", "name": "ddeeff"},
            "cause": "missing-transaction",
        },
    }
    for index, (name, _kind, _fn) in enumerate(template._release_steps()):
        journey, _urls, fake_run_party = _withheld_mocked_leg(
            mod, tmp, lambda: (14, dict(refusal))
        )
        ran = []
        patches = []
        for position, (step_name, _step_kind, _step_fn) in enumerate(
            template._release_steps()
        ):
            method = getattr(forward_cls, step_methods[step_name])

            def _record(*args, _method=method, _step_name=step_name, **kwargs):
                ran.append(_step_name)
                return _method(*args, **kwargs)

            def _raise(*args, _step_name=step_name, **kwargs):
                ran.append(_step_name)
                raise RuntimeError(f"injected-{_step_name}")

            if position <= index:
                patches.append(
                    mock.patch.object(forward_cls, step_methods[step_name], _raise)
                )
            else:
                patches.append(
                    mock.patch.object(forward_cls, step_methods[step_name], _record)
                )
        for patch in patches:
            patch.start()
        try:
            with mock.patch.object(journey, "run_party", fake_run_party):
                try:
                    journey.withheld_leg("alice", "alice-2")
                except mod.SetupFailure as failed:
                    outcome = f"SetupFailure: {failed}"
                except Exception as error:  # noqa: BLE001 - row status is the finding
                    outcome = f"{type(error).__name__}: {error}"
                else:
                    outcome = "clean"
        finally:
            for patch in reversed(patches):
                patch.stop()
        raw = Path(tmp, "withheld-inspect.json").read_text()
        check(
            f"forwarder-registry-total-{name}",
            outcome.startswith("SetupFailure")
            and all(f"{step}:" in outcome for step in step_names[: index + 1])
            and set(ran) == set(step_names)
            and _json.loads(raw).get("outcome") == "stale-state",
            f"injecting {name} gave {outcome} ran={sorted(ran)}",
        )


def test_receipt_loaders_handle_absence(mod, tmp):
    journey = bare(mod, tmp)
    check(
        "receipt-loaders-handle-absence",
        journey.load_receipt("no-such-receipt", Path(tmp)) is None
        and journey.load_exit("no-such-receipt", Path(tmp)) is None,
        "a missing receipt did not read as absent",
    )


def main():
    path = (
        Path(sys.argv[1])
        if len(sys.argv) > 1
        else Path(__file__).with_name("registry_two_actors.py")
    )
    mod = load_harness(path)
    print(f"status-test: harness under test: {path}")
    cases = [
        test_fixture_failure_is_setup,
        test_empty_trace_is_setup,
        test_command_timeout_is_setup,
        test_provider_loss_is_setup,
        test_refusal_is_row_result,
        test_reject_refusal_is_row_result,
        test_reclaim_refusal_is_row_result,
        test_money_compares_value_and_recipient,
        test_no_preview_files_needed,
        test_trim_derived_from_reads,
        test_cbor_decoder_synthetic,
        test_plutus_json_walker,
        test_fee_bound_fetch_mocked,
        test_nonzero_topup_survives_trim,
        test_trim_preserves_run_three_predicates,
        test_refusal_compares_pending_set,
        test_window_comes_from_registry,
        test_trim_keeps_predicate_fields,
        test_record_tamper_is_detected,
        test_oversize_untrimmed_is_detected,
        test_long_root_uses_short_runtime,
        test_setup_names_devnet_cause,
        test_history_refusals_bind_identity,
        test_history_reads_covered_and_load_bearing,
        test_forwarder_withholds_state_asset,
        test_forwarder_start_failure_is_setup,
        test_withheld_leg_records_and_passes,
        test_forwarder_stops_after_leg_failure,
        test_fold_set_derived_from_record,
        test_fold_set_missing_record_excludes,
        test_start_runtime_allocation_failure_is_setup,
        test_runtime_removal_failure_is_setup,
        test_runtime_removal_failure_flows,
        test_report_lists_marked_appendix_after_rows,
        test_replay_fault_control_passes,
        test_replay_fault_control_accepted_is_row_failure,
        test_replay_fault_control_needs_unpatched,
        test_replay_fault_status_maps,
        test_forwarder_thread_start_failure_is_setup_and_teardown,
        test_pgrep_exit_2_and_3_are_setup,
        test_pkill_failure_is_best_effort,
        test_pgrep_failure_flows,
        test_forwarder_close_error_is_setup_and_releases,
        test_forwarder_shutdown_error_releases,
        test_forwarder_join_survivor_is_setup,
        test_withheld_cleanup_failure_keeps_setup_and_receipts,
        test_killpg_failure_is_setup_and_continues,
        test_devnet_cause_read_fallback,
        test_forwarder_relay_failure_is_502,
        test_node_wait_timeout_continues_teardown,
        test_which_missing_still_removes_runtime,
        test_stop_registry_total,
        test_forwarder_registry_total,
        test_thread_construction_failure_is_setup,
        test_removal_check_flips_row,
        test_environment_isolates_party_tmp,
        test_journey_init_creates_worktree,
        test_koios_post_roundtrip,
        test_receipt_loaders_handle_absence,
        test_apps_supply_process_tools,
        test_altered_leg_records_and_passes,
        test_altered_leg_skips_without_faulted_binary,
        test_altered_leg_accepted_is_row_failure,
        test_fixture_blowup_tears_down,
        test_guard_keeps_status_through_teardown_failure,
        test_teardown_failure_after_success_is_setup,
        test_real_stop_needs_its_tools,
    ]
    with tempfile.TemporaryDirectory() as tmp:
        for case in cases:
            try:
                case(mod, tmp)
            except Exception as error:  # noqa: BLE001 - an escaping case is RED
                check(
                    case.__name__,
                    False,
                    f"escaped as {type(error).__name__}: {error}",
                )
    if FAILURES:
        print(f"status-test: {len(FAILURES)} case(s) failed: {FAILURES}")
        return 1
    print("status-test: all cases passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
