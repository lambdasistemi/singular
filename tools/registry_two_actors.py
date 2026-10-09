#!/usr/bin/env python3
"""Run one of Demo 1's independent-user journey (#381): token-only actors.

The creator makes the registry with `registry create` and no directory
option. Alice and Bob each run from a fresh home on the state token alone,
with their own wallet key and the development network's provider, magic,
time source and public blueprint. Every actor command carries
`--state-token` and none carries `--registry` or `--state-dir`. No
assertion reads a home or a state root: fresh homes are empty by
construction, and "nothing was submitted" is an `inspect` before and
after. Every party process is traced; a traced path under another party's
home fails the journey at the guard with status 2.

Exit statuses: 0 when every row that waits on no other ticket is passed;
1 when one such row is not passed; 2 when the access guard fired;
3 when setup failed. `SINGULAR_TWO_ACTOR_CONTROL=foreign-open` runs one
real booking with `--state-dir` aimed at the other actor's state root and
must end at status 2 with the guard diagnostic naming the path.
"""

import json
import os
from pathlib import Path
import secrets
from shutil import which
import signal
import subprocess
import sys
import time


ISSUE_503 = "https://github.com/lambdasistemi/singular/issues/503"
ISSUE_381 = "https://github.com/lambdasistemi/singular/issues/381"
RECEIPT_CAP_BYTES = 52428800
REQUIREMENTS = (
    "Alice reads the registry page and joins by state token",
    "Bob reads the registry page and joins by state token",
    "Alice inserts a key and folds her insertion",
    "Bob inserts a key and folds his insertion",
    "Alice folds Bob's termination from her own public replay",
    "Bob folds Alice's termination from his own public replay",
    "Bob rejects Alice's expired request",
    "Alice cannot reclaim Bob's request",
    "Bob reclaims his request during its retract window",
    "Another controller cannot update or terminate a key",
    "Both users inspect the fold's state root after every fold",
    "Withheld fold history refuses HistoryIncomplete without a trie",
    "An altered request edge refuses RootDoesNotChain without a trie",
    "Another actor folds an insertion",
)
PAGE_ROWS = REQUIREMENTS[0:2]
RUN_ONE_ROWS = REQUIREMENTS[2:4]
# Later runs own the rest; in run one they wait on those runs' legs.
WAITING_ON = {
    "Alice folds Bob's termination from her own public replay": (
        "run two legs of the mandate (terminate-and-fold)"
    ),
    "Bob folds Alice's termination from his own public replay": (
        "run two legs of the mandate (terminate-and-fold)"
    ),
    "Bob rejects Alice's expired request": "run three legs of the mandate",
    "Alice cannot reclaim Bob's request": "run three legs of the mandate",
    "Bob reclaims his request during its retract window": (
        "run three legs of the mandate"
    ),
    "Another controller cannot update or terminate a key": (
        "run two legs of the mandate (controller refusals)"
    ),
    "Both users inspect the fold's state root after every fold": (
        "run two legs of the mandate (fold roots)"
    ),
    "Withheld fold history refuses HistoryIncomplete without a trie": (
        "run four legs of the mandate (history faults)"
    ),
    "An altered request edge refuses RootDoesNotChain without a trie": (
        "run four legs of the mandate (history faults)"
    ),
    "Another actor folds an insertion": (
        "run two legs of the mandate (cross-actor folds)"
    ),
}


class SetupFailure(Exception):
    pass


class GuardFired(Exception):
    def __init__(self, path):
        super().__init__(path)
        self.path = path


class JourneyFailure(Exception):
    pass


def require(condition, message):
    if not condition:
        raise JourneyFailure(message)


def check_access(trace, forbidden):
    """Fail the journey at the guard when a trace names another home."""
    for line in trace.splitlines():
        if any(call in line for call in ("open(", "openat(", "openat2(")):
            for directory in forbidden:
                if str(directory) in line:
                    raise GuardFired(line.strip())


class Journey:
    def __init__(self, singular, devnet, blueprint, work):
        self.singular, self.devnet, self.blueprint = singular, devnet, blueprint
        self.work = Path(work)
        # Fresh by construction: a rerun at the same path refuses to start.
        self.work.mkdir(parents=True, exist_ok=False)
        self.neutral = self.work / "devnet"
        self.neutral.mkdir()
        self.homes = {}
        for party in ("creator", "alice", "bob"):
            home = self.work / f"{party}-home"
            home.mkdir(exist_ok=False)
            self.homes[party] = home
        self.receipts = self.work / "receipts"
        self.receipts.mkdir()
        self.keys = self.receipts / "keys"
        self.keys.mkdir()
        for party in ("creator", "alice", "bob"):
            # Development-fixture wallet keys live outside every home.
            (self.keys / f"{party}.skey").write_text(secrets.token_hex(32))
        self.payloads = self.receipts / "payloads"
        self.payloads.mkdir()
        self.tmp = self.work / "tmp"
        self.tmp.mkdir()
        self.settings = None
        self.state_token = None
        self.node = None
        self.appendix = []

    def payload(self, name):
        """Write one insert payload outside every home; return its path."""
        path = self.payloads / f"{name}.json"
        path.write_text(
            json.dumps(
                {
                    "map": [
                        {
                            "k": {"bytes": "6e616d65"},
                            "v": {
                                "list": [
                                    {"int": -7},
                                    {"bytes": "616c696365"},
                                    {"constructor": 2, "fields": []},
                                ]
                            },
                        }
                    ]
                }
            )
            + "\n"
        )
        return path

    def environment(self, party):
        environment = os.environ.copy()
        environment.update(
            HOME=str(self.homes[party]), TMPDIR=str(self.tmp / party)
        )
        (self.tmp / party).mkdir(exist_ok=True)
        environment.pop("SINGULAR_NODE_SOCKET", None)
        environment.pop("SINGULAR_STATE_TOKEN", None)
        environment.pop("XDG_STATE_HOME", None)
        return environment

    def neutral_environment(self):
        environment = os.environ.copy()
        environment.update(HOME=str(self.neutral), TMPDIR=str(self.neutral))
        environment.pop("SINGULAR_NODE_SOCKET", None)
        environment.pop("SINGULAR_STATE_TOKEN", None)
        environment.pop("XDG_STATE_HOME", None)
        return environment

    def traced(self, trace, command):
        return [
            "strace",
            "-f",
            "-yy",
            "-s",
            "4096",
            "-e",
            "trace=%file",
            "-o",
            str(trace),
        ] + command

    def node_arguments(self):
        return [
            "--koios-url",
            self.settings["providerUrl"],
            "--network-magic",
            str(self.settings["networkMagic"]),
            "--network-time",
            self.settings["networkTimeDirectory"],
        ]

    def run_party(self, party, name, arguments, forbidden):
        """Run one real command as PARTY; return its parsed JSON receipt."""
        trace = self.receipts / f"{name}.access"
        stdout, stderr = (
            self.receipts / f"{name}.json",
            self.receipts / f"{name}.err",
        )
        with stdout.open("w") as output, stderr.open("w") as error:
            result = subprocess.run(
                self.traced(trace, [self.singular] + list(arguments)),
                env=self.environment(party),
                cwd=self.homes[party],
                stdout=output,
                stderr=error,
                check=False,
                timeout=600,
            )
        trace_text = trace.read_text() if trace.exists() else ""
        require(trace_text != "", f"SETUP: {party} {name} left no access trace")
        check_access(trace_text, forbidden)
        try:
            receipt = json.loads(stdout.read_text())
        except json.JSONDecodeError as error:
            raise SetupFailure(
                f"{party} {name} printed no JSON receipt "
                f"(exit {result.returncode}): {error}"
            )
        self.appendix.append(
            {"process": f"{party} {name}", "accessTrace": str(trace)}
        )
        return result.returncode, receipt

    def book(self, party, command, key, name):
        """Book one request; every booking command is assembled here alone.

        `insert` and `terminate` are the commands that book a request, so
        the command-line split moves them by changing this one place.
        """
        require(
            command in ("insert", "terminate"), "booking must be insert or terminate"
        )
        arguments = ["registry", command, "--key", key]
        if command == "insert":
            arguments += ["--payload", str(self.payload(name))]
        arguments += [
            "--blueprint",
            self.blueprint,
            "--state-token",
            self.state_token,
            *self.node_arguments(),
            "--wallet-skey",
            str(self.keys / f"{party}.skey"),
        ]
        return arguments

    def start_devnet(self):
        trace = self.neutral / "devnet.access"
        with (
            (self.neutral / "devnet.out").open("w") as output,
            (self.neutral / "devnet.err").open("w") as error,
        ):
            command = [
                self.devnet,
                "--fund-outputs",
                "8",
                "--fund-lovelace",
                "2000000000",
                "--fund-skey",
                str(self.keys / "creator.skey"),
                "--fund-skey",
                str(self.keys / "alice.skey"),
                "--fund-skey",
                str(self.keys / "bob.skey"),
            ]
            self.node = subprocess.Popen(
                self.traced(trace, command),
                env=self.neutral_environment(),
                cwd=self.neutral,
                stdout=output,
                stderr=error,
                start_new_session=True,
            )
        deadline = time.monotonic() + 900
        while time.monotonic() < deadline:
            lines = (self.neutral / "devnet.out").read_text().splitlines()
            if lines:
                try:
                    self.settings = json.loads(lines[0])
                except json.JSONDecodeError:
                    self.settings = None
                if self.settings is not None:
                    break
            require(
                self.node.poll() is None, "SETUP: development source exited"
            )
            time.sleep(1)
        require(
            self.settings is not None,
            "SETUP: development source did not print settings",
        )
        for field in ("providerUrl", "networkMagic", "networkTimeDirectory"):
            require(
                self.settings.get(field),
                f"SETUP: development settings lack {field}",
            )

    def stop_devnet(self):
        if self.node is not None:
            try:
                os.killpg(self.node.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            self.node.wait(timeout=60)
            self.node = None
        if which("pkill"):
            subprocess.run(
                ["pkill", "-f", f"cardano-node run --config {self.neutral}/"],
                check=False,
            )
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                probe = subprocess.run(
                    ["pgrep", "-f", f"cardano-node run --config {self.neutral}/"],
                    check=False,
                )
                if probe.returncode != 0:
                    break
                time.sleep(0.5)
            probe = subprocess.run(
                ["pgrep", "-f", f"cardano-node run --config {self.neutral}/"],
                check=False,
            )
            require(probe.returncode != 0, "SETUP: a node of this run survives")
        print("two actors: owned processes: none", flush=True)

    def fixture(self):
        """Start the network and let the creator make the registry alone."""
        self.start_devnet()
        forbidden = (self.homes["alice"], self.homes["bob"])
        preview_status, preview = self.run_party(
            "creator",
            "preview",
            [
                "registry",
                "create",
                "--process-time",
                "120000",
                "--retract-time",
                "30000",
                "--preview",
                "--blueprint",
                self.blueprint,
                *self.node_arguments(),
                "--wallet-skey",
                str(self.keys / "creator.skey"),
            ],
            forbidden,
        )
        require(
            preview_status == 0 and preview.get("outcome") == "success",
            f"SETUP: creator preview failed: exit {preview_status}, {preview}",
        )
        require(preview.get("seed"), "SETUP: creator preview named no seed")
        create_status, create = self.run_party(
            "creator",
            "create",
            [
                "registry",
                "create",
                "--process-time",
                "120000",
                "--retract-time",
                "30000",
                "--seed",
                preview["seed"],
                "--blueprint",
                self.blueprint,
                *self.node_arguments(),
                "--wallet-skey",
                str(self.keys / "creator.skey"),
            ],
            forbidden,
        )
        require(
            create_status == 0 and create.get("outcome") == "success",
            f"SETUP: creator create failed: exit {create_status}, {create}",
        )
        require(create.get("stateToken"), "SETUP: create named no state token")
        self.state_token = create["stateToken"]
        print(f"two actors: registry {self.state_token} created", flush=True)

    def foreign_open(self):
        """One real booking with --state-dir at the other actor's root."""
        print("two actors: foreign-open control is on", flush=True)
        bob_root = self.homes["bob"] / ".local" / "state" / "singular"
        status, receipt = self.run_party(
            "creator",
            "foreign-open",
            [
                *self.book("creator", "insert", "control-key", "control"),
                "--state-dir",
                str(bob_root),
            ],
            (self.homes["alice"], self.homes["bob"]),
        )
        raise JourneyFailure(
            "the foreign-open control passed without reaching the guard: "
            f"exit {status}, {receipt}"
        )

    def report(self, rows):
        report = {
            "requirements": rows,
            "harnessAppendix": self.appendix,
        }
        (self.work / "journey.json").write_text(
            json.dumps(report, indent=2) + "\n"
        )
        for row in rows:
            waiting = (
                f" waiting on {row['waitingOn']}"
                if row["state"] == "pending" and row.get("waitingOn")
                else ""
            )
            print(
                f"two actors: {row['requirement']}: {row['state']}{waiting}",
                flush=True,
            )

    def pending_report(self):
        rows = []
        for name in REQUIREMENTS:
            if name in PAGE_ROWS:
                rows.append(
                    {
                        "requirement": name,
                        "state": "pending",
                        "receipts": [],
                        "dependencies": [ISSUE_503],
                        "waitingOn": ISSUE_503,
                    }
                )
            elif name in RUN_ONE_ROWS:
                rows.append(
                    {
                        "requirement": name,
                        "state": "pending",
                        "receipts": [],
                        "dependencies": [],
                        "waitingOn": (
                            "the actor's inspect, booking and fold receipts"
                        ),
                    }
                )
            else:
                rows.append(
                    {
                        "requirement": name,
                        "state": "pending",
                        "receipts": [],
                        "dependencies": [ISSUE_381],
                        "waitingOn": WAITING_ON[name],
                    }
                )
        return rows

    def exit_for(self, rows):
        if all(
            row["state"] == "passed"
            for row in rows
            if row["requirement"] not in PAGE_ROWS
        ):
            return 0
        return 1

    def execute(self):
        try:
            self.fixture()
            if os.environ.get("SINGULAR_TWO_ACTOR_CONTROL") == "foreign-open":
                self.foreign_open()
        except GuardFired as fired:
            print(f"two actors: GUARD: {fired.path}", flush=True)
            try:
                self.report(self.pending_report())
            finally:
                self.stop_devnet()
            return 2
        except SetupFailure as failed:
            print(f"two actors: SETUP: {failed}", flush=True)
            try:
                self.report(self.pending_report())
            finally:
                self.stop_devnet()
            return 3
        try:
            rows = self.pending_report()
            self.report(rows)
        finally:
            self.stop_devnet()
        return self.exit_for(rows)


if __name__ == "__main__":
    require(
        len(sys.argv) == 5,
        "usage: registry_two_actors.py SINGULAR DEVNET BLUEPRINT WORKDIR",
    )
    try:
        sys.exit(Journey(*sys.argv[1:]).execute())
    except JourneyFailure as failed:
        print(f"two actors: FAIL: {failed}", flush=True)
        sys.exit(1)
