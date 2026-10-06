#!/usr/bin/env python3
"""Prepare Demo 1's private creator and two empty users; retain pending coverage.

The creator's real CLI receipts establish fixture creation only. No actor is
configured from a creator file. Token joining and every later CLI step await
#437; cross-actor insertion folding additionally awaits #419. Access traces and
directory hashes are harness evidence, recorded separately from product rows.
"""

import hashlib
import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import sys
import time


JOIN_ISSUE = "https://github.com/lambdasistemi/singular/issues/437"
INSERTION_ISSUE = "https://github.com/lambdasistemi/singular/issues/419"
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


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def digest(directory):
    value = hashlib.sha256()
    for path in sorted(directory.rglob("*")):
        value.update(str(path.relative_to(directory)).encode())
        if path.is_file():
            value.update(path.read_bytes())
    return value.hexdigest()


def check_access(trace, forbidden):
    for line in trace.splitlines():
        if any(call in line for call in ("open(", "openat(", "openat2(")):
            for directory in forbidden:
                require(
                    str(directory) not in line,
                    f"process attempted another actor's directory: {line}",
                )


class Journey:
    def __init__(self, singular, devnet, blueprint, work):
        self.singular, self.devnet, self.blueprint = singular, devnet, blueprint
        self.work = Path(work).resolve()
        self.work.mkdir(parents=True, exist_ok=False)
        self.creator = self.work / "creator"
        self.creator.mkdir()
        self.home = self.creator / "home"
        self.home.mkdir()
        self.temporary = self.creator / "temporary"
        self.temporary.mkdir()
        self.reg = self.creator / "registry"
        self.receipts = self.creator / "receipts"
        self.receipts.mkdir()
        # The generated key belongs only to this private development fixture.
        (self.home / "payment.skey").write_text(secrets.token_hex(32))
        self.actors = {}
        for actor in ("alice", "bob"):
            self.actors[actor] = (
                self.work / f"{actor}-home",
                self.work / f"{actor}-registry",
            )
            for directory in self.actors[actor]:
                directory.mkdir()
                require(list(directory.iterdir()) == [], "actor did not start empty")
        self.forbidden = tuple(
            path for directories in self.actors.values() for path in directories
        )
        self.initial = {str(path): digest(path) for path in self.forbidden}
        self.settings = None
        self.node = None
        self.appendix = []
        self.fixture_receipts = []

    def environment(self):
        environment = os.environ.copy()
        environment.update(HOME=str(self.home), TMPDIR=str(self.temporary))
        environment.pop("SINGULAR_NODE_SOCKET", None)
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

    def unchanged(self):
        for path in self.forbidden:
            require(digest(path) == self.initial[str(path)], f"creator changed {path}")
            require(
                list(path.iterdir()) == [], f"actor directory no longer empty: {path}"
            )

    def actor_paths(self, actor):
        """Return a user's HOME and registry paths, without configuring a join."""
        home, registry = self.actors[actor]
        return {"home": home, "registry": registry}

    def run_actor(self, actor, name, arguments, outcome="success", status=0):
        """Run caller-supplied CLI arguments after the real #437 integration.

        The caller supplies the actual token/page/provider interface and its own
        wallet inputs. This seam adds no identity, join, request selection or
        private creator material. It returns the subject's parsed JSON receipt.
        """
        home, registry = self.actors[actor]
        foreign = (self.creator,) + tuple(
            path
            for other, paths in self.actors.items()
            if other != actor
            for path in paths
        )
        before = {str(path): digest(path) for path in foreign}
        trace = self.work / f"{actor}-{name}.access"
        stdout, stderr = (
            self.work / f"{actor}-{name}.json",
            self.work / f"{actor}-{name}.err",
        )
        environment = os.environ.copy()
        environment.update(HOME=str(home), TMPDIR=str(home))
        environment.pop("SINGULAR_NODE_SOCKET", None)
        with stdout.open("w") as output, stderr.open("w") as error:
            result = subprocess.run(
                self.traced(trace, [self.singular] + list(arguments)),
                env=environment,
                cwd=home,
                stdout=output,
                stderr=error,
                check=False,
                timeout=600,
            )
        check_access(trace.read_text(), foreign)
        after = {str(path): digest(path) for path in foreign}
        require(after == before, f"{actor} changed a foreign directory")
        receipt = json.loads(stdout.read_text())
        require(
            result.returncode == status and receipt["outcome"] == outcome,
            f"{actor} {name}: exit {result.returncode}, receipt {receipt}",
        )
        self.appendix.append(
            {
                "process": f"{actor} {name}",
                "accessTrace": str(trace),
                "foreignDirectoriesBefore": before,
                "foreignDirectoriesAfter": after,
            }
        )
        return receipt

    def book(
        self, actor, command, arguments, name="booking", outcome="success", status=0
    ):
        """Book insert/terminate using explicit caller arguments; return its receipt."""
        require(
            command in ("insert", "terminate"), "booking must be insert or terminate"
        )
        return self.run_actor(
            actor, name, ["registry", command] + list(arguments), outcome, status
        )

    def fold(self, actor, arguments, name="fold", outcome="success", status=0):
        """Fold using explicit caller arguments; impose no pending-request count."""
        return self.run_actor(
            actor, name, ["registry", "fold"] + list(arguments), outcome, status
        )

    def run_creator(self, name, arguments):
        self.unchanged()
        trace = self.receipts / f"{name}.access"
        command = [self.singular, "registry"] + arguments
        command += [
            "--blueprint",
            self.blueprint,
            "--koios-url",
            self.settings["providerUrl"],
            "--network-magic",
            str(self.settings["networkMagic"]),
            "--network-time",
            self.settings["networkTimeDirectory"],
            "--wallet-skey",
            str(self.home / "payment.skey"),
        ]
        stdout, stderr = self.receipts / f"{name}.json", self.receipts / f"{name}.err"
        with stdout.open("w") as output, stderr.open("w") as error:
            result = subprocess.run(
                self.traced(trace, command),
                env=self.environment(),
                cwd=self.home,
                stdout=output,
                stderr=error,
                check=False,
                timeout=600,
            )
        check_access(trace.read_text(), self.forbidden)
        self.unchanged()
        receipt = json.loads(stdout.read_text())
        require(
            result.returncode == 0 and receipt["outcome"] == "success",
            f"creator {name}: exit {result.returncode}, receipt {receipt}",
        )
        self.fixture_receipts.append(
            {"receipt": str(stdout), "outcome": receipt["outcome"]}
        )
        self.appendix.append(
            {
                "process": f"creator {name}",
                "accessTrace": str(trace),
                "actorDirectories": self.initial,
            }
        )
        return receipt

    def controlled_open(self):
        """A real subject command aimed at a foreign directory must fail the guard."""
        trace = self.receipts / "foreign-open.access"
        command = [
            self.singular,
            "registry",
            "inspect",
            "--registry",
            str(self.forbidden[0]),
            "--blueprint",
            self.blueprint,
            "--key",
            "guard-control",
            "--koios-url",
            self.settings["providerUrl"],
            "--network-magic",
            "42",
            "--network-time",
            self.settings["networkTimeDirectory"],
        ]
        with (self.receipts / "foreign-open.json").open("w") as output:
            subprocess.run(
                self.traced(trace, command),
                env=self.environment(),
                cwd=self.home,
                stdout=output,
                stderr=subprocess.DEVNULL,
                check=False,
                timeout=60,
            )
        # With the control requested, this deliberately fails from subject access.
        check_access(trace.read_text(), self.forbidden)
        raise AssertionError("foreign-open control did not reach the access guard")

    def report(self):
        # None of these rows has a subject receipt until the #437 integration runs.
        rows = [
            {
                "requirement": name,
                "receipts": [],
                "dependencies": [JOIN_ISSUE]
                + ([INSERTION_ISSUE] if name == REQUIREMENTS[-1] else []),
            }
            for name in REQUIREMENTS
        ]
        for row in rows:
            row["state"] = "passed" if row["receipts"] else "pending"
        report = {
            "requirements": rows,
            "fixtureCreation": self.fixture_receipts,
            "harnessAppendix": self.appendix,
        }
        (self.work / "journey.json").write_text(json.dumps(report, indent=2) + "\n")
        for row in rows:
            print(
                f"two actors: {row['requirement']}: {row['state']} ({', '.join(row['dependencies'])})",
                flush=True,
            )

    def execute(self):
        trace = self.creator / "devnet.access"
        try:
            with (
                (self.creator / "devnet.out").open("w") as output,
                (self.creator / "devnet.err").open("w") as error,
            ):
                command = [
                    self.devnet,
                    "--fund-outputs",
                    "8",
                    "--fund-lovelace",
                    "2000000000",
                    "--fund-skey",
                    str(self.home / "payment.skey"),
                ]
                self.node = subprocess.Popen(
                    self.traced(trace, command),
                    env=self.environment(),
                    cwd=self.home,
                    stdout=output,
                    stderr=error,
                    start_new_session=True,
                )
            deadline = time.monotonic() + 900
            while time.monotonic() < deadline:
                lines = (self.creator / "devnet.out").read_text().splitlines()
                if lines:
                    self.settings = json.loads(lines[0])
                    break
                require(
                    self.node.poll() is None, "SETUP: creator development source exited"
                )
                time.sleep(1)
            require(
                self.settings is not None,
                "SETUP: creator development source did not start",
            )
            preview = self.run_creator(
                "preview", ["create", "--preview", "--registry", str(self.reg)]
            )
            self.run_creator(
                "create",
                [
                    "create",
                    "--seed",
                    preview["seed"],
                    "--registry",
                    str(self.reg),
                    "--process-time",
                    "90000",
                    "--retract-time",
                    "30000",
                ],
            )
            if os.environ.get("SINGULAR_TWO_ACTOR_CONTROL") == "foreign-open":
                self.controlled_open()
        finally:
            if self.node:
                try:
                    os.killpg(self.node.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                self.node.wait(timeout=30)
                check_access(trace.read_text(), self.forbidden)
                self.unchanged()
                self.appendix.append(
                    {
                        "process": "creator development source",
                        "accessTrace": str(trace),
                        "actorDirectories": self.initial,
                    }
                )
            self.report()


if __name__ == "__main__":
    require(
        len(sys.argv) == 5,
        "usage: registry_two_actors.py SINGULAR DEVNET BLUEPRINT WORKDIR",
    )
    Journey(*sys.argv[1:]).execute()
