"""Bind private fixture processes before signalling; never select by broad pkill."""

import argparse
import json
import os
from pathlib import Path
import signal
import time


def observe(pid):
    base = Path(f"/proc/{pid}")
    fields = (base / "stat").read_text().rsplit(")", 1)[1].split()
    return {
        "pid": pid,
        "start_ticks": fields[19],
        "parent": int(fields[1]),
        "state": fields[0],
        "executable": str((base / "exe").resolve(strict=True)),
        "cwd": str((base / "cwd").resolve(strict=True)),
        "arguments": (base / "cmdline").read_bytes().decode().rstrip("\0").split("\0"),
    }


def descendant(pid, parent):
    while pid > 1:
        if pid == parent:
            return True
        pid = observe(pid)["parent"]
    return False


def find_node(config, socket, owner):
    matches = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdecimal():
            continue
        try:
            record = observe(int(entry.name))
            args = record["arguments"]
            if (
                Path(record["executable"]).name == "cardano-node"
                and args[1:2] == ["run"]
                and any(
                    args[i : i + 2] == ["--config", config] for i in range(len(args))
                )
                and any(
                    args[i : i + 2] == ["--socket-path", socket]
                    for i in range(len(args))
                )
                and descendant(record["pid"], owner)
            ):
                matches.append(record)
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue
    if len(matches) != 1:
        raise RuntimeError(f"expected one exact owned node, found {len(matches)}")
    return matches[0]


def stop(record, kind, seconds):
    pid = record["pid"]
    try:
        descriptor = os.pidfd_open(pid)
    except ProcessLookupError:
        return
    try:
        try:
            fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        except FileNotFoundError:
            return
        if fields[19] == record["start_ticks"] and fields[0] == "Z":
            return
        current = observe(pid)
        for field in ("start_ticks", "executable", "cwd", "arguments"):
            if current[field] != record[field]:
                raise RuntimeError(f"process identity changed: {pid} {field}")
        signal.pidfd_send_signal(descriptor, getattr(signal, "SIG" + kind))
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
                if fields[19] != record["start_ticks"] or fields[0] == "Z":
                    return
            except FileNotFoundError:
                return
            time.sleep(0.05)
        raise TimeoutError(f"owned process {pid} did not stop after {kind}")
    finally:
        os.close(descriptor)


def gone(record):
    try:
        fields = (
            Path(f"/proc/{record['pid']}/stat").read_text().rsplit(")", 1)[1].split()
        )
    except FileNotFoundError:
        return True
    return fields[19] != record["start_ticks"] or fields[0] == "Z"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    bind = sub.add_parser("bind")
    bind.add_argument("output", type=Path)
    choice = bind.add_mutually_exclusive_group(required=True)
    choice.add_argument("--pid", type=int)
    choice.add_argument("--config")
    bind.add_argument("--socket")
    bind.add_argument("--owner", type=int)
    terminate = sub.add_parser("stop")
    terminate.add_argument("record", type=Path)
    terminate.add_argument("--signal", choices=["INT", "TERM", "KILL"], required=True)
    terminate.add_argument("--seconds", type=float, default=30)
    starting = sub.add_parser("stop-child")
    starting.add_argument("record", type=Path)
    starting.add_argument("--pid", type=int, required=True)
    starting.add_argument("--start-ticks", required=True)
    starting.add_argument("--owner", type=int, required=True)
    starting.add_argument("--signal", choices=["INT", "TERM", "KILL"], required=True)
    starting.add_argument("--seconds", type=float, default=30)
    absent = sub.add_parser("assert-gone")
    absent.add_argument("record", type=Path)
    args = parser.parse_args()
    if args.command == "bind":
        if args.pid is not None:
            record = observe(args.pid)
        else:
            if args.socket is None or args.owner is None:
                parser.error("node binding needs --socket and --owner")
            record = find_node(args.config, args.socket, args.owner)
        with args.output.open("x") as output:
            json.dump(record, output, indent=2)
            output.write("\n")
        print(record["pid"])
    elif args.command == "stop-child":
        # The shell captured the child's start ticks with a builtin while
        # deferring cancellation. This works before socket/exec readiness.
        identity = {"pid": args.pid, "start_ticks": args.start_ticks}
        if gone(identity):
            return
        record = observe(args.pid)
        if record["start_ticks"] != args.start_ticks or record["parent"] != args.owner:
            raise RuntimeError("starting process is not the exact owned child")
        if not args.record.exists():
            with args.record.open("x") as output:
                json.dump(record, output, indent=2)
                output.write("\n")
        stop(record, args.signal, args.seconds)
    elif args.command == "assert-gone":
        if not gone(json.loads(args.record.read_text())):
            raise RuntimeError(f"recorded fixture process remains live: {args.record}")
    else:
        stop(json.loads(args.record.read_text()), args.signal, args.seconds)


if __name__ == "__main__":
    main()
