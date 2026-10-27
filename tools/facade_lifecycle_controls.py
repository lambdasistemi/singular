"""Actual private-node controls for joined facade sessions and fatal failures."""

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import signal
import subprocess
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
            except BaseException as error:
                cleanup_error = {"type": type(error).__name__, "diagnostic": str(error)}
                # A failed owner must still stop its fixture node and direct
                # child before returning the cleanup failure.
                fixture_node = work / "fixture-node.json"
                if fixture_node.is_file():
                    stop(json.loads(fixture_node.read_text()), "KILL", 5)
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


def interrupted(_signal, _frame):
    raise KeyboardInterrupt("private lifecycle owner received TERM")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("devnet")
    parser.add_argument("work", type=Path)
    args = parser.parse_args()
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
    finally:
        signal.signal(signal.SIGTERM, previous)


if __name__ == "__main__":
    main()
