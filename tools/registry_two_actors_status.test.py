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
