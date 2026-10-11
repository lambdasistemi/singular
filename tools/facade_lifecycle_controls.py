"""Actual private-node controls for joined facade sessions and fatal failures."""

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

from fixture_process import find_node, identity, observe, stop


def wait_for(predicate, process, seconds=120):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        if process.poll() is not None:
            raise RuntimeError(f"fixture exited early: {process.returncode}")
        time.sleep(0.02)
    raise TimeoutError("fixture startup or transition deadline")


def endpoint_refuses(url):
    try:
        urllib.request.urlopen(url + "/tip", timeout=2).close()
    except urllib.error.HTTPError:
        return False
    except urllib.error.URLError as error:
        return isinstance(error.reason, ConnectionRefusedError)
    return False


def gone(record):
    try:
        fields = (
            Path(f"/proc/{record['pid']}/stat").read_text().rsplit(")", 1)[1].split()
        )
    except FileNotFoundError:
        return True
    return fields[19] != record["start_ticks"] or fields[0] == "Z"


def control(devnet, root, case):
    work = root / case
    work.mkdir()
    markers = work / "control"
    arguments = [devnet, "--evidence-dir", str(work / "sources")]
    if case != "ordinary-unexpected-death":
        arguments += ["--restart-control-dir", str(markers)]
    if case == "missing-resume":
        arguments += ["--restart-resume-timeout-ms", "1000"]
    environment = dict(os.environ, TMPDIR=str(work))
    node = None
    settings = None
    result = {"case": case, "command": arguments}
    with owned_process(
        arguments, environment, work, "fixture", "stdout", "stderr"
    ) as process:

        def published():
            lines = (work / "stdout").read_text().splitlines()
            if not lines:
                return None
            try:
                return json.loads(lines[-1])
            except json.JSONDecodeError:
                return None

        settings = wait_for(published, process)
        if case != "ordinary-unexpected-death":
            wait_for(lambda: (markers / "ready.0").is_file(), process)
        node = find_node(
            str(work / "cardano-e2e/node-config.json"),
            settings["privateProbeSocket"],
            process.pid,
        )
        result.update(node=node, fixture=observe(process.pid), settings=settings)
        (work / "fixture-node.json").write_text(json.dumps(node, indent=2) + "\n")
        if "unexpected-death" in case:
            stop(node, "KILL", 5)
            code = process.wait(timeout=15)
            diagnostic = (work / "stderr").read_text()
            assert code != 0 and (
                "ExceptionInLinkedThread" in diagnostic
                or "source connection closed" in diagnostic
            ), diagnostic
        elif case == "out-of-order":
            (markers / "pause.2").touch(exist_ok=False)
            code = process.wait(timeout=15)
            assert (
                code != 0
                and "out-of-order facade request" in (work / "stderr").read_text()
            )
        else:
            (markers / "pause.1").touch(exist_ok=False)
            wait_for(lambda: (markers / "paused.1").is_file(), process)
            assert endpoint_refuses(settings["providerUrl"]), (
                "paused endpoint returned an answer"
            )
            result["paused_endpoint_refuses"] = True
            if case == "missing-resume":
                code = process.wait(timeout=15)
                assert (
                    code != 0
                    and "missing facade request: resume.1"
                    in (work / "stderr").read_text()
                )
            elif case == "caller-cancel":
                process.terminate()
                code = process.wait(timeout=30)
                assert code != 0
            elif case == "stale-request":
                (markers / "pause.1").touch(exist_ok=False)
                code = process.wait(timeout=15)
                assert (
                    code != 0
                    and "stale, duplicate or out-of-order"
                    in (work / "stderr").read_text()
                )
            else:
                raise RuntimeError(f"unmapped control: {case}")
        assert gone(node), "fixture exit left its original node live"
        assert endpoint_refuses(settings["providerUrl"]), "fixture exit left HTTP live"
        result.update(
            exit=code, original_node_gone=True, endpoint_refuses_after_exit=True
        )
        (work / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result), flush=True)


@contextmanager
def owned_process(command, environment, work, name, stdout_name=None, stderr_name=None):
    """Own the direct child across normal completion, timeout and interruption.

    The experiment is a direct Bash controller, in its own session so caller
    Ctrl-C reaches this owner first. TERM reaches its cleanup trap, which joins
    replacement then fixture; the owner waits before inspecting descendants.
    """
    record = None
    original_error = None
    cleanup_error = None
    with (
        (work / (stdout_name or name + ".out")).open("w") as output,
        (work / (stderr_name or name + ".err")).open("w") as errors,
    ):
        process = None
        pending = []
        # Defer caller interruption only while acquiring the direct child and
        # its start identity. Catch handlers reset on exec; no signal mask is
        # inherited by the experiment. Cleanup already owns it before delivery.
        previous_handlers = {}
        try:
            try:
                for kind in (signal.SIGTERM, signal.SIGINT):
                    previous_handlers[kind] = signal.signal(
                        kind, lambda number, _frame: pending.append(number)
                    )
                process = subprocess.Popen(
                    command,
                    env=environment,
                    stdout=output,
                    stderr=errors,
                    start_new_session=True,
                )
                try:
                    record = identity(process.pid)
                except FileNotFoundError:
                    process.wait(timeout=5)
                    raise RuntimeError(
                        f"owned command exited during acquisition: {process.returncode}"
                    ) from None
                try:
                    observed = observe(process.pid)
                    if observed["start_ticks"] == record["start_ticks"]:
                        record = observed
                except FileNotFoundError:
                    # The minimal identity already owns an acquiring/exited
                    # child; absence of an executable image cannot erase it.
                    pass
            finally:
                for kind, handler in previous_handlers.items():
                    signal.signal(kind, handler)
            if pending:
                raise KeyboardInterrupt(
                    f"private lifecycle owner interrupted during acquisition: {pending}"
                )
            yield process
        except BaseException as error:
            original_error = {"type": type(error).__name__, "diagnostic": str(error)}
            raise
        finally:
            # Repeated caller signals must not abandon cleanup half-way. The
            # bounded cleanup completes before a pending interrupt propagates.
            previous = signal.pthread_sigmask(
                signal.SIG_BLOCK, {signal.SIGTERM, signal.SIGINT}
            )
            try:
                if process is not None and process.poll() is None:
                    if record is None:
                        raise RuntimeError("owned live command lacks acquired identity")
                    stop(record, "TERM", 90, child_owner=os.getpid())
                if process is not None:
                    process.wait(timeout=5)
                # These checks also run when an unexpected caller interrupt
                # propagates: cleanup is not inferred from wrapper exit alone.
                fixture_node = work / "fixture-node.json"
                if fixture_node.is_file() and not gone(
                    json.loads(fixture_node.read_text())
                ):
                    raise RuntimeError("owned fixture left its original node live")
                direct_settings = work / (stdout_name or name + ".out")
                if direct_settings.is_file():
                    for line in direct_settings.read_text().splitlines():
                        try:
                            settings = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        if isinstance(settings, dict) and "providerUrl" in settings:
                            if not endpoint_refuses(settings["providerUrl"]):
                                raise RuntimeError(
                                    "owned fixture left its HTTP endpoint live"
                                )
                experiment = work / "run"
                if experiment.exists():
                    paths = [
                        experiment / "original-node.json",
                        experiment / "devnet-process.json",
                        *experiment.glob("replacement-node-*.json"),
                    ]
                    for path in paths:
                        if path.is_file() and not gone(json.loads(path.read_text())):
                            raise RuntimeError(
                                f"owned experiment left a live process: {path}"
                            )
                    point = experiment / "startup-cancellation-point"
                    if point.is_file():
                        pid, ticks = point.read_text().strip().split("/")
                        if not gone({"pid": int(pid), "start_ticks": ticks}):
                            raise RuntimeError("acquiring replacement remains live")
                    settings_file = experiment / "devnet.out"
                    if settings_file.is_file():
                        for line in settings_file.read_text().splitlines():
                            try:
                                settings = json.loads(line)
                            except json.JSONDecodeError:
                                continue
                            if isinstance(settings, dict) and "providerUrl" in settings:
                                if not endpoint_refuses(settings["providerUrl"]):
                                    raise RuntimeError(
                                        "owned experiment left its HTTP endpoint live"
                                    )
            except BaseException as error:
                cleanup_error = {"type": type(error).__name__, "diagnostic": str(error)}
                # A failed owner is not allowed to abandon the experiment.
                # Bind the exact starting child before any fallback signal;
                # stop replacement, then fixture, then the controller itself.
                fixture_node = work / "fixture-node.json"
                if fixture_node.is_file():
                    stop(json.loads(fixture_node.read_text()), "KILL", 5)
                experiment = work / "run"
                point = experiment / "startup-cancellation-point"
                replacement_records = list(experiment.glob("replacement-node-*.json"))
                if point.is_file() and not replacement_records:
                    pid, ticks = point.read_text().strip().split("/")
                    starting_identity = {"pid": int(pid), "start_ticks": ticks}
                    if not gone(starting_identity):
                        node = observe(int(pid))
                        if (
                            node["start_ticks"] != ticks
                            or node["parent"] != process.pid
                        ):
                            raise RuntimeError(
                                "startup fallback is not the bound controller child"
                            ) from error
                        stop(node, "KILL", 5, child_owner=process.pid)
                for path in replacement_records:
                    stop(json.loads(path.read_text()), "KILL", 5)
                fixture = experiment / "devnet-process.json"
                if fixture.is_file():
                    stop(json.loads(fixture.read_text()), "TERM", 35)
                if process.poll() is None and record is not None:
                    stop(record, "KILL", 5, child_owner=os.getpid())
                process.wait(timeout=5)
                raise RuntimeError(
                    f"owned command cleanup failed: {cleanup_error}"
                ) from error
            finally:
                ownership = {
                    "command": command,
                    "process": record,
                    "exit": process.returncode if process is not None else None,
                    "original_error": original_error,
                    "cleanup_error": cleanup_error,
                }
                (work / (name + ".owner.json")).write_text(
                    json.dumps(ownership, indent=2) + "\n"
                )
                signal.pthread_sigmask(signal.SIG_SETMASK, previous)


def build_path(root, target, work, name):
    command = [
        "nix",
        "build",
        "--quiet",
        "--no-link",
        "--print-out-paths",
        str(root / target),
    ]
    with owned_process(command, os.environ.copy(), work, name) as process:
        code = process.wait(timeout=600)
    if code != 0:
        raise RuntimeError(f"fixture prerequisite build failed: {name} exit {code}")
    lines = (work / (name + ".out")).read_text().splitlines()
    if len(lines) != 1 or not Path(lines[0]).exists():
        raise RuntimeError(f"fixture prerequisite has no unique real path: {name}")
    return Path(lines[0])


def startup_control(args, directory, mode, open_datum, blueprint):
    # The short location is an owned, retained sibling of the caller's short
    # TMPDIR; nesting the real node beneath a long evidence root cannot bind.
    work = Path(tempfile.mkdtemp(prefix="fsc.", dir=os.environ.get("TMPDIR")))
    evidence = directory / ("startup-" + mode)
    evidence.mkdir()
    (evidence / "location.json").write_text(
        json.dumps({"actual_work": str(work)}) + "\n"
    )
    environment = dict(
        os.environ,
        TMPDIR=str(work),
        DEMO1_KEEP_SCRATCH="1",
        CLI_RECOVERY_PARTS="rollback",
        CLI_RECOVERY_CANCEL_AT_STARTUP="1" if mode == "self-cancel" else "delay",
    )
    command = [
        "bash",
        args.startup_controller,
        args.singular,
        str(open_datum / "bin/open-datum"),
        args.devnet,
        str(blueprint),
        str(work / "run"),
        str(args.root),
    ]
    original_error = None
    try:
        with owned_process(command, environment, work, "controller") as process:
            if mode == "self-cancel":
                process.wait(timeout=600)
            else:
                wait_for(
                    lambda: (work / "run/startup-cancellation-point").is_file(), process
                )
                if mode == "caller-cancel":
                    # Exercise this owner's actual signal/interruption path.
                    os.kill(os.getpid(), signal.SIGTERM)
                    raise RuntimeError("caller cancellation handler did not interrupt")
                process.wait(timeout=0.2)
                raise RuntimeError("delayed experiment failed to exercise timeout")
    except KeyboardInterrupt as error:
        if mode != "caller-cancel":
            raise
        original_error = {"type": type(error).__name__, "diagnostic": str(error)}
    except subprocess.TimeoutExpired as error:
        if mode != "timeout":
            raise
        original_error = {"type": type(error).__name__, "diagnostic": str(error)}
    result = json.loads((work / "controller.owner.json").read_text())
    assert result["exit"] == 143 and result["cleanup_error"] is None, result
    experiment = work / "run"
    assert (experiment / "startup-cancellation-point").is_file()
    assert (experiment / "cleanup-order").read_text().splitlines() == [
        "replacement-joined",
        "fixture-joined",
    ]
    records = [
        experiment / "original-node.json",
        experiment / "devnet-process.json",
        *experiment.glob("replacement-node-*.json"),
    ]
    assert len(records) == 3 and all(
        gone(json.loads(path.read_text())) for path in records
    )
    settings = json.loads((experiment / "devnet.out").read_text().splitlines()[0])
    assert endpoint_refuses(settings["providerUrl"])
    result.update(
        case="replacement-startup-" + mode,
        actual_work=str(work),
        interruption=original_error,
        replacement_joined_before_fixture=True,
        bound_processes_gone=len(records),
        endpoint_refuses_after_exit=True,
    )
    (evidence / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result), flush=True)


def interrupted(_signal, _frame):
    raise KeyboardInterrupt("private lifecycle owner received TERM")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("devnet")
    parser.add_argument("work", type=Path)
    parser.add_argument("--startup-controller")
    parser.add_argument("--singular")
    parser.add_argument("--root", type=Path)
    args = parser.parse_args()
    if args.startup_controller and (args.root is None or args.singular is None):
        parser.error(
            "startup experiment requires its real source root and test singular binary"
        )
    args.work.mkdir()
    previous = signal.signal(signal.SIGTERM, interrupted)
    try:
        for case in (
            "ordinary-unexpected-death",
            "restart-unexpected-death",
            "missing-resume",
            "caller-cancel",
            "out-of-order",
            "stale-request",
        ):
            control(args.devnet, args.work, case)
        if args.startup_controller:
            open_datum = build_path(
                args.root,
                "applications/open-datum/offchain#open-datum-test-harness",
                args.work,
                "open-datum",
            )
            blueprint = build_path(
                args.root,
                "applications/open-datum/onchain#open-datum-blueprint",
                args.work,
                "blueprint",
            )
            for mode in ("self-cancel", "caller-cancel", "timeout"):
                startup_control(args, args.work, mode, open_datum, blueprint)
    finally:
        signal.signal(signal.SIGTERM, previous)


if __name__ == "__main__":
    main()
