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
        test_nonzero_topup_survives_trim,
        test_trim_preserves_run_three_predicates,
        test_refusal_compares_pending_set,
        test_window_comes_from_registry,
        test_trim_keeps_predicate_fields,
        test_record_tamper_is_detected,
        test_oversize_untrimmed_is_detected,
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
