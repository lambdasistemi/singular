"""Actual private-node controls for joined facade sessions and fatal failures."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.request

from fixture_process import find_node, observe, stop


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
    with (work / "stdout").open("w") as output, (work / "stderr").open("w") as errors:
        # This scope owns and waits for its direct fixture child. No watcher.
        process = subprocess.Popen(
            arguments, env=environment, stdout=output, stderr=errors
        )
        node = None
        settings = None
        result = {"case": case, "command": arguments}
        try:

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
            assert endpoint_refuses(settings["providerUrl"]), (
                "fixture exit left HTTP live"
            )
            result.update(
                exit=code, original_node_gone=True, endpoint_refuses_after_exit=True
            )
            (work / "result.json").write_text(json.dumps(result, indent=2) + "\n")
            print(json.dumps(result), flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    # Keep the directory and original result. This is a failed
                    # cleanup, not evidence that the fixture bracket joined.
                    if node is not None and not gone(node):
                        stop(node, "KILL", 5)
                    process.kill()
                    process.wait()
                    raise RuntimeError(
                        "fixture cancellation did not join its owner"
                    ) from None
            if node is not None and not gone(node):
                stop(node, "KILL", 5)
                raise RuntimeError("control cleanup found an unjoined original node")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("devnet")
    parser.add_argument("work", type=Path)
    parser.add_argument("--startup-controller")
    args = parser.parse_args()
    args.work.mkdir()
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
        scratch = args.work / "startup-cancel"
        scratch.mkdir()
        environment = dict(
            os.environ,
            RUNNER_TEMP=str(scratch),
            TMPDIR=str(scratch),
            CLI_RECOVERY_CANCEL_AT_STARTUP="1",
            DEMO1_KEEP_SCRATCH="1",
        )
        with (
            (scratch / "stdout").open("w") as output,
            (scratch / "stderr").open("w") as errors,
        ):
            code = subprocess.run(
                [args.startup_controller],
                env=environment,
                stdout=output,
                stderr=errors,
                timeout=600,
            ).returncode
        runs = list(scratch.glob("cli-recovery.*/run"))
        assert len(runs) == 1 and code == 143, (
            f"startup control code={code}, runs={runs}"
        )
        work = runs[0]
        assert (work / "startup-cancellation-point").is_file()
        assert (work / "cleanup-order").read_text().splitlines() == [
            "replacement-joined",
            "fixture-joined",
        ]
        records = [
            work / "original-node.json",
            work / "devnet-process.json",
            *work.glob("replacement-node-*.json"),
        ]
        assert len(records) == 3
        for path in records:
            assert gone(json.loads(path.read_text())), (
                f"startup cancellation left a live process: {path}"
            )
        result = {
            "case": "replacement-startup-cancel",
            "exit": code,
            "replacement_joined_before_fixture": True,
            "bound_processes_gone": len(records),
        }
        (scratch / "result.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
