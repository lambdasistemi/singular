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

import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
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
RUN_TWO_TERMINATE_ROWS = REQUIREMENTS[4:6]
RUN_TWO_ROWS = (
    "Alice folds Bob's termination from her own public replay",
    "Bob folds Alice's termination from his own public replay",
    "Another actor folds an insertion",
    "Another controller cannot update or terminate a key",
    "Both users inspect the fold's state root after every fold",
)
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


TRIM_THRESHOLD_BYTES = 262144
RECORD_KEPT_FIELDS = (
    "command",
    "outcome",
    "reason",
    "leaf",
    "root",
    "pendingRequests",
    "request",
    "requester",
    "edge",
    "folder",
    "stateToken",
    "reject",
    "rejected",
    "rejector",
    "retract",
    "returned",
    "locked",
    "owner",
    "key",
    "tip",
)


def trim_record(command, exit_code, raw):
    """Trim one command receipt to the record rows and the report read.

    Receipts at or under the threshold stay raw. A larger receipt is
    parsed once; the record keeps the command, its exit status, every
    field a row consumes, and the hash and size of the full output,
    which is then deleted. Row states are computed from these records,
    never typed.
    """
    if len(raw.encode()) <= TRIM_THRESHOLD_BYTES:
        return raw
    try:
        receipt = json.loads(raw)
    except json.JSONDecodeError:
        return raw
    if not isinstance(receipt, dict):
        return raw
    record = {key: receipt[key] for key in RECORD_KEPT_FIELDS if key in receipt}
    record["command"] = command
    record["exit"] = exit_code
    record["rawSha256"] = hashlib.sha256(raw.encode()).hexdigest()
    record["rawBytes"] = len(raw.encode())
    return json.dumps(record, indent=2) + "\n"


def check_record(name, raw):
    """One integrity error in a stored receipt, or None when it holds.

    A receipt over the trim threshold is untrimmed evidence and fails;
    a trimmed record must name its command, outcome and exit, and carry
    a well-formed hash with a raw size above the threshold.
    """
    if len(raw) > TRIM_THRESHOLD_BYTES:
        return f"{name} is {len(raw)} bytes over the trim threshold"
    try:
        receipt = json.loads(raw)
    except json.JSONDecodeError:
        return f"{name} is not JSON"
    if not isinstance(receipt, dict):
        return f"{name} is not a receipt"
    if "rawSha256" not in receipt:
        return None
    digest = receipt.get("rawSha256")
    if (
        not isinstance(digest, str)
        or len(digest) != 64
        or any(c not in "0123456789abcdef" for c in digest)
    ):
        return f"{name} names no raw hash"
    size = receipt.get("rawBytes")
    if not isinstance(size, int) or size <= TRIM_THRESHOLD_BYTES:
        return f"{name} raw size does not match its hash"
    for key in ("command", "outcome", "exit"):
        if key not in receipt:
            return f"{name} record names no {key}"
    return None


def setup_require(condition, message):
    if not condition:
        raise SetupFailure(message)


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
        environment.update(HOME=str(self.homes[party]), TMPDIR=str(self.tmp / party))
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
            try:
                result = subprocess.run(
                    self.traced(trace, [self.singular] + list(arguments)),
                    env=self.environment(party),
                    cwd=self.homes[party],
                    stdout=output,
                    stderr=error,
                    check=False,
                    timeout=600,
                )
            except subprocess.TimeoutExpired:
                raise SetupFailure(f"{party} {name} timed out")
            except OSError as error:
                raise SetupFailure(f"{party} {name} did not start: {error}")
        trace_text = trace.read_text() if trace.exists() else ""
        setup_require(trace_text != "", f"{party} {name} left no access trace")
        check_access(trace_text, forbidden)
        raw = stdout.read_text()
        try:
            receipt = json.loads(raw)
        except json.JSONDecodeError as error:
            raise SetupFailure(
                f"{party} {name} printed no JSON receipt "
                f"(exit {result.returncode}): {error}"
            )
        (self.receipts / f"{name}.exit").write_text(f"{result.returncode}\n")
        stdout.write_text(
            trim_record(receipt.get("command", name), result.returncode, raw)
        )
        self.appendix.append({"process": f"{party} {name}", "accessTrace": str(trace)})
        if result.returncode == 12 or receipt.get("outcome") == "node-unavailable":
            raise SetupFailure(
                f"{party} {name} lost the provider: exit "
                f"{result.returncode}, {receipt.get('reason')}"
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
            setup_require(self.node.poll() is None, "development source exited")
            time.sleep(1)
        setup_require(
            self.settings is not None,
            "development source did not print settings",
        )
        for field in ("providerUrl", "networkMagic", "networkTimeDirectory"):
            setup_require(
                self.settings.get(field),
                f"development settings lack {field}",
            )

    def stop_devnet(self):
        if self.node is not None:
            try:
                os.killpg(self.node.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                self.node.wait(timeout=60)
            except subprocess.TimeoutExpired:
                raise SetupFailure("the development source did not stop")
            self.node = None
        if which("pkill") is None or which("pgrep") is None:
            raise SetupFailure("cannot verify no surviving node")
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
        setup_require(probe.returncode != 0, "a node of this run survives")
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
        setup_require(
            preview_status == 0 and preview.get("outcome") == "success",
            f"creator preview failed: exit {preview_status}, {preview}",
        )
        setup_require(preview.get("seed"), "creator preview named no seed")
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
        setup_require(
            create_status == 0 and create.get("outcome") == "success",
            f"creator create failed: exit {create_status}, {create}",
        )
        setup_require(create.get("stateToken"), "create named no state token")
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

    def actor_leg(self, actor, key):
        """One actor proves a key absent, books it, folds it, reads it back."""
        others = tuple(home for party, home in self.homes.items() if party != actor)
        leg = {}
        status, before = self.run_party(
            actor,
            f"{actor}-inspect-before",
            [
                "registry",
                "inspect",
                "--key",
                key,
                "--blueprint",
                self.blueprint,
                "--state-token",
                self.state_token,
                *self.node_arguments(),
            ],
            others,
        )
        require(
            status == 0 and before.get("outcome") == "success",
            f"{actor} inspect-before failed: exit {status}, {before}",
        )
        require(
            before.get("leaf") == "unknown",
            f"{actor} key {key} is not absent: {before.get('leaf')}",
        )
        require(
            before.get("pendingRequests") == [],
            f"{actor} saw pending requests before booking: "
            f"{before.get('pendingRequests')}",
        )
        leg["inspect_before"] = f"{actor}-inspect-before"
        status, booking = self.run_party(
            actor,
            f"{actor}-booking",
            self.book(actor, "insert", key, f"{actor}-payload"),
            others,
        )
        require(
            status == 0 and booking.get("outcome") == "success",
            f"{actor} booking failed: exit {status}, {booking}",
        )
        require(
            isinstance(booking.get("request"), str),
            f"{actor} booking named no request: {booking}",
        )
        leg["booking"] = f"{actor}-booking"
        status, fold = self.run_party(
            actor,
            f"{actor}-fold",
            [
                "registry",
                "fold",
                "--request",
                booking["request"],
                "--blueprint",
                self.blueprint,
                "--state-token",
                self.state_token,
                *self.node_arguments(),
                "--wallet-skey",
                str(self.keys / f"{actor}.skey"),
            ],
            others,
        )
        require(
            status == 0 and fold.get("outcome") == "success",
            f"{actor} fold failed: exit {status}, {fold}",
        )
        require(
            fold.get("request") == booking["request"],
            f"{actor} folded another request: {fold.get('request')} "
            f"!= {booking['request']}",
        )
        require(
            fold.get("edge") == "insertActive",
            f"{actor} folded another edge: {fold.get('edge')}",
        )
        require(
            fold.get("folder") == booking.get("requester"),
            f"{actor} fold names another folder: {fold.get('folder')}",
        )
        require(fold.get("root"), f"{actor} fold named no root: {fold}")
        leg["fold"] = f"{actor}-fold"
        status, after = self.run_party(
            actor,
            f"{actor}-inspect-after",
            [
                "registry",
                "inspect",
                "--key",
                key,
                "--blueprint",
                self.blueprint,
                "--state-token",
                self.state_token,
                *self.node_arguments(),
            ],
            others,
        )
        require(
            status == 0 and after.get("outcome") == "success",
            f"{actor} inspect-after failed: exit {status}, {after}",
        )
        require(
            after.get("leaf") == "active",
            f"{actor} key {key} is not active: {after.get('leaf')}",
        )
        require(
            after.get("root") == fold["root"],
            f"{actor} inspect root {after.get('root')} != fold root {fold['root']}",
        )
        leg["inspect_after"] = f"{actor}-inspect-after"
        other = "bob" if actor == "alice" else "alice"
        other_others = tuple(
            home for party, home in self.homes.items() if party != other
        )
        status, seen = self.run_party(
            other,
            f"{actor}-fold-seen-by-{other}",
            self.inspect_key(key),
            other_others,
        )
        require(
            status == 0 and seen.get("outcome") == "success",
            f"{other} inspect-after failed: exit {status}, {seen}",
        )
        require(
            seen.get("root") == fold["root"],
            f"{other} inspect root {seen.get('root')} != fold root {fold['root']}",
        )
        self.record_fold_root(
            leg["fold"], key, leg["inspect_after"], f"{actor}-fold-seen-by-{other}"
        )
        return leg

    def record_fold_root(self, fold, key, inspect_a, inspect_b):
        """Remember one fold both actors must read back at its root."""
        if not hasattr(self, "fold_records"):
            self.fold_records = []
        self.fold_records.append(
            {
                "fold": fold,
                "key": key,
                "inspect_a": inspect_a,
                "inspect_b": inspect_b,
            }
        )

    def fold_pending(self, party):
        """Fold the one pending request, discovering it from the chain alone.

        The fold names no `--request` and carries no payload file: the
        folder reads the pending request on the chain, never a file the
        booker wrote.
        """
        return [
            "registry",
            "fold",
            "--blueprint",
            self.blueprint,
            "--state-token",
            self.state_token,
            *self.node_arguments(),
            "--wallet-skey",
            str(self.keys / f"{party}.skey"),
        ]

    def inspect_key(self, key):
        """Read one key through the state token alone."""
        return [
            "registry",
            "inspect",
            "--key",
            key,
            "--blueprint",
            self.blueprint,
            "--state-token",
            self.state_token,
            *self.node_arguments(),
        ]

    def terminate_leg(self, controller, folder, key):
        """CONTROLLER terminates KEY; FOLDER folds it from the chain request."""
        direction = f"terminate-{key}-by-{folder}"
        controller_others = tuple(
            home for party, home in self.homes.items() if party != controller
        )
        folder_others = tuple(
            home for party, home in self.homes.items() if party != folder
        )
        leg = {}
        status, before = self.run_party(
            controller,
            f"{direction}-inspect-before",
            self.inspect_key(key),
            controller_others,
        )
        require(
            status == 0 and before.get("outcome") == "success",
            f"{controller} inspect-before failed: exit {status}, {before}",
        )
        require(
            before.get("leaf") == "active",
            f"{controller} key {key} is not live: {before.get('leaf')}",
        )
        leg["inspect_before"] = f"{direction}-inspect-before"
        status, booking = self.run_party(
            controller,
            f"{direction}-booking",
            self.book(controller, "terminate", key, direction),
            controller_others,
        )
        require(
            status == 0 and booking.get("outcome") == "success",
            f"{controller} terminate failed: exit {status}, {booking}",
        )
        require(
            isinstance(booking.get("request"), str),
            f"{controller} termination named no request: {booking}",
        )
        leg["booking"] = f"{direction}-booking"
        status, fold = self.run_party(
            folder,
            f"{direction}-fold",
            self.fold_pending(folder),
            folder_others,
        )
        require(
            status == 0 and fold.get("outcome") == "success",
            f"{folder} fold failed: exit {status}, {fold}",
        )
        require(
            fold.get("request") == booking["request"],
            f"{folder} folded another request: {fold.get('request')} "
            f"!= {booking['request']}",
        )
        require(
            fold.get("edge") == "updateTerminal",
            f"{folder} folded another edge: {fold.get('edge')}",
        )
        require(
            fold.get("folder") != booking.get("requester"),
            f"{folder} fold names the booker as folder: {fold.get('folder')}",
        )
        require(fold.get("root"), f"{folder} fold named no root: {fold}")
        leg["fold"] = f"{direction}-fold"
        for party, slot in ((controller, "inspect_owner"), (folder, "inspect_other")):
            others = tuple(home for name, home in self.homes.items() if name != party)
            status, after = self.run_party(
                party,
                f"{direction}-inspect-{party}",
                self.inspect_key(key),
                others,
            )
            require(
                status == 0 and after.get("outcome") == "success",
                f"{party} inspect-after failed: exit {status}, {after}",
            )
            require(
                after.get("leaf") == "terminal",
                f"{party} key {key} is not terminal: {after.get('leaf')}",
            )
            require(
                after.get("root") == fold["root"],
                f"{party} inspect root {after.get('root')} != fold root {fold['root']}",
            )
            leg[slot] = f"{direction}-inspect-{party}"
        self.record_fold_root(
            leg["fold"], key, leg["inspect_owner"], leg["inspect_other"]
        )
        return leg

    def cross_insert_leg(self, booker, folder, key):
        """BOOKER inserts KEY; FOLDER folds it from the chain request.

        FOLDER holds no copy of the booking: the fold names no `--request`
        and carries no payload file; the datum it delivers is the request's
        inline datum on the chain.
        """
        direction = f"cross-{key}-by-{folder}"
        booker_others = tuple(
            home for party, home in self.homes.items() if party != booker
        )
        folder_others = tuple(
            home for party, home in self.homes.items() if party != folder
        )
        leg = {}
        status, before = self.run_party(
            booker,
            f"{direction}-inspect-before",
            self.inspect_key(key),
            booker_others,
        )
        require(
            status == 0 and before.get("outcome") == "success",
            f"{booker} inspect-before failed: exit {status}, {before}",
        )
        require(
            before.get("leaf") == "unknown",
            f"{booker} key {key} is not absent: {before.get('leaf')}",
        )
        require(
            before.get("pendingRequests") == [],
            f"{booker} saw pending requests before booking: "
            f"{before.get('pendingRequests')}",
        )
        leg["inspect_before"] = f"{direction}-inspect-before"
        status, booking = self.run_party(
            booker,
            f"{direction}-booking",
            self.book(booker, "insert", key, direction),
            booker_others,
        )
        require(
            status == 0 and booking.get("outcome") == "success",
            f"{booker} booking failed: exit {status}, {booking}",
        )
        require(
            isinstance(booking.get("request"), str),
            f"{booker} booking named no request: {booking}",
        )
        leg["booking"] = f"{direction}-booking"
        status, fold = self.run_party(
            folder,
            f"{direction}-fold",
            self.fold_pending(folder),
            folder_others,
        )
        require(
            status == 0 and fold.get("outcome") == "success",
            f"{folder} fold failed: exit {status}, {fold}",
        )
        require(
            fold.get("request") == booking["request"],
            f"{folder} folded another request: {fold.get('request')} "
            f"!= {booking['request']}",
        )
        require(
            fold.get("edge") == "insertActive",
            f"{folder} folded another edge: {fold.get('edge')}",
        )
        require(
            fold.get("folder") != booking.get("requester"),
            f"{folder} fold names the booker as folder: {fold.get('folder')}",
        )
        require(fold.get("root"), f"{folder} fold named no root: {fold}")
        leg["fold"] = f"{direction}-fold"
        for party, slot in ((booker, "inspect_booker"), (folder, "inspect_folder")):
            others = tuple(home for name, home in self.homes.items() if name != party)
            status, after = self.run_party(
                party,
                f"{direction}-inspect-{party}",
                self.inspect_key(key),
                others,
            )
            require(
                status == 0 and after.get("outcome") == "success",
                f"{party} inspect-after failed: exit {status}, {after}",
            )
            require(
                after.get("leaf") == "active",
                f"{party} key {key} is not active: {after.get('leaf')}",
            )
            require(
                after.get("root") == fold["root"],
                f"{party} inspect root {after.get('root')} != fold root {fold['root']}",
            )
            leg[slot] = f"{direction}-inspect-{party}"
        self.record_fold_root(
            leg["fold"], key, leg["inspect_booker"], leg["inspect_folder"]
        )
        return leg

    def refusal_leg(self, owner, foreign, key):
        """FOREIGN's `update` and `terminate` of OWNER's key are refused.

        Each attempt must end refused by name with the controller refusal
        class and a non-zero exit, submitting nothing; FOREIGN's own
        `inspect` before and after shows the root and the pending requests
        unchanged (one inspector suffices: both actors read the same chain
        root). `update` is not a booking verb, so its command is assembled
        here, at the one place that attempts it.
        """
        direction = f"refuse-{key}-by-{foreign}"
        leg = {}
        foreign_others = tuple(
            home for party, home in self.homes.items() if party != foreign
        )
        status, before = self.run_party(
            foreign,
            f"{direction}-inspect-before",
            self.inspect_key(key),
            foreign_others,
        )
        require(
            status == 0 and before.get("outcome") == "success",
            f"{foreign} inspect-before failed: exit {status}, {before}",
        )
        leg["inspect_before"] = f"{direction}-inspect-before"
        status, refused_update = self.run_party(
            foreign,
            f"{direction}-refuse-update",
            [
                "registry",
                "update",
                "--key",
                key,
                "--payload",
                str(self.payload(f"{direction}-update")),
                "--blueprint",
                self.blueprint,
                "--state-token",
                self.state_token,
                *self.node_arguments(),
                "--wallet-skey",
                str(self.keys / f"{foreign}.skey"),
            ],
            foreign_others,
        )
        require(
            status == 10
            and refused_update.get("outcome") == "client-refusal"
            and "controller" in refused_update.get("reason", ""),
            f"{foreign} update was not refused by controller: "
            f"exit {status}, {refused_update}",
        )
        leg["refuse_update"] = f"{direction}-refuse-update"
        status, refused_terminate = self.run_party(
            foreign,
            f"{direction}-refuse-terminate",
            self.book(foreign, "terminate", key, direction),
            foreign_others,
        )
        require(
            status == 10
            and refused_terminate.get("outcome") == "client-refusal"
            and "controller" in refused_terminate.get("reason", ""),
            f"{foreign} terminate was not refused by controller: "
            f"exit {status}, {refused_terminate}",
        )
        leg["refuse_terminate"] = f"{direction}-refuse-terminate"
        status, after = self.run_party(
            foreign,
            f"{direction}-inspect-after",
            self.inspect_key(key),
            foreign_others,
        )
        require(
            status == 0 and after.get("outcome") == "success",
            f"{foreign} inspect-after failed: exit {status}, {after}",
        )
        require(
            after.get("root") == before.get("root"),
            f"{foreign} root moved under a refused command: "
            f"{before.get('root')} -> {after.get('root')}",
        )
        require(
            after.get("pendingRequests") == before.get("pendingRequests"),
            f"{foreign} pending requests moved under a refused command: "
            f"{before.get('pendingRequests')} -> "
            f"{after.get('pendingRequests')}",
        )
        leg["inspect_after"] = f"{direction}-inspect-after"
        return leg

    def report(self, rows):
        report = {
            "requirements": rows,
            "harnessAppendix": self.appendix,
        }
        (self.work / "journey.json").write_text(json.dumps(report, indent=2) + "\n")
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

    def load_receipt(self, name, receipts=None):
        path = (receipts or self.receipts) / f"{name}.json"
        if not path.exists():
            return None
        try:
            return json.loads(path.read_text())
        except json.JSONDecodeError:
            return None

    def load_exit(self, name, receipts=None):
        """The exit status a command ended with, beside its JSON receipt."""
        path = (receipts or self.receipts) / f"{name}.exit"
        if not path.exists():
            return None
        try:
            return int(path.read_text().strip())
        except ValueError:
            return None

    def terminate_fold_agreement(self, folder, leg, legs, receipts=None):
        """Recompute one terminate-and-fold row from its receipts on disk.

        The controller books the termination of its own key; FOLDER, who
        holds no copy of the booking, folds the one pending request from
        the chain. The fold names the booking's request, the
        `updateTerminal` edge and the folder's own identity, and both
        actors then read the key terminal under the fold's root.
        """
        docs = {
            slot: self.load_receipt(leg[slot], receipts) if slot in leg else None
            for slot in (
                "inspect_before",
                "booking",
                "fold",
                "inspect_owner",
                "inspect_other",
            )
        }
        missing = [slot for slot, doc in docs.items() if doc is None]
        if missing:
            return False, [], f"the termination's {', '.join(missing)} receipt"
        before, booking, fold, inspect_owner, inspect_other = (
            docs["inspect_before"],
            docs["booking"],
            docs["fold"],
            docs["inspect_owner"],
            docs["inspect_other"],
        )
        if before.get("leaf") != "active":
            return False, list(leg.values()), "the live key readback"
        if not isinstance(booking.get("request"), str):
            return False, list(leg.values()), "the termination booking request"
        if fold.get("request") != booking["request"]:
            return False, list(leg.values()), "the fold of the termination"
        if fold.get("edge") != "updateTerminal":
            return False, list(leg.values()), "the termination fold"
        own_name = legs.get(folder, {}).get("fold")
        own = self.load_receipt(own_name, receipts) if own_name else None
        if own is None or fold.get("folder") != own.get("folder"):
            return False, list(leg.values()), "the folder's own booking"
        if fold.get("folder") == booking.get("requester"):
            return False, list(leg.values()), "a folder other than the booker"
        if not fold.get("root"):
            return False, list(leg.values()), "the fold root"
        for inspect in (inspect_owner, inspect_other):
            if inspect.get("leaf") != "terminal":
                return False, list(leg.values()), "the terminal key readback"
            if inspect.get("root") != fold["root"]:
                return False, list(leg.values()), "the fold root readback"
        return True, list(leg.values()), ""

    def cross_insert_agreement(self, legs, receipts=None):
        """Recompute the cross-actor insertion row from its receipts.

        Each direction books an insertion; the other actor folds the one
        pending request from the chain, carrying no payload file and no
        copy of the booking. Both directions must agree.
        """
        directions = legs.get("cross-insert", {})
        found = []
        for direction in ("alice-books", "bob-books"):
            leg = directions.get(direction, {})
            folder = "bob" if direction == "alice-books" else "alice"
            docs = {
                slot: self.load_receipt(leg[slot], receipts) if slot in leg else None
                for slot in (
                    "inspect_before",
                    "booking",
                    "fold",
                    "inspect_booker",
                    "inspect_folder",
                )
            }
            missing = [slot for slot, doc in docs.items() if doc is None]
            if missing:
                return (
                    False,
                    [],
                    f"the cross-actor insertion's {', '.join(missing)} receipt",
                )
            before, booking, fold, inspect_booker, inspect_folder = (
                docs["inspect_before"],
                docs["booking"],
                docs["fold"],
                docs["inspect_booker"],
                docs["inspect_folder"],
            )
            if before.get("leaf") != "unknown":
                return False, found, "the absent key readback"
            if before.get("pendingRequests") != []:
                return False, found, "the empty pending readback"
            if not isinstance(booking.get("request"), str):
                return False, found, "the insertion booking request"
            if fold.get("request") != booking["request"]:
                return False, found, "the fold of the insertion"
            if fold.get("edge") != "insertActive":
                return False, found, "the insertion fold"
            own_name = legs.get(folder, {}).get("fold")
            own = self.load_receipt(own_name, receipts) if own_name else None
            if own is None or fold.get("folder") != own.get("folder"):
                return False, found, "the folder's own booking"
            if fold.get("folder") == booking.get("requester"):
                return False, found, "a folder other than the booker"
            if not fold.get("root"):
                return False, found, "the fold root"
            for inspect in (inspect_booker, inspect_folder):
                if inspect.get("leaf") != "active":
                    return False, found, "the active key readback"
                if inspect.get("root") != fold["root"]:
                    return False, found, "the fold root readback"
            found += list(leg.values())
        return True, found, ""

    def refusal_agreement(self, legs, receipts=None):
        """Recompute the controller-refusal row from its receipts.

        In each direction the foreign actor's `update` and `terminate`
        of a key it did not create are refused by name with the
        controller refusal class and a non-zero exit, and both actors'
        `inspect` root and pending requests are unchanged.
        """
        attempts = legs.get("refusals", [])
        if not attempts:
            return False, [], "the controller refusal receipts"
        found = []
        for leg in attempts:
            docs = {
                slot: self.load_receipt(leg[slot], receipts) if slot in leg else None
                for slot in (
                    "inspect_before",
                    "refuse_update",
                    "refuse_terminate",
                    "inspect_after",
                )
            }
            missing = [slot for slot, doc in docs.items() if doc is None]
            if missing:
                return (
                    False,
                    [],
                    f"the controller refusal's {', '.join(missing)} receipt",
                )
            for name in ("refuse_update", "refuse_terminate"):
                if self.load_exit(leg[name], receipts) != 10:
                    return False, found, "the controller refusal exit"
                if docs[name].get("outcome") != "client-refusal":
                    return False, found, "the controller refusal class"
                if "controller" not in docs[name].get("reason", ""):
                    return False, found, "the controller refusal name"
            if docs["inspect_before"].get("root") != docs["inspect_after"].get("root"):
                return False, found, "the unchanged root"
            if docs["inspect_before"].get("pendingRequests") != docs[
                "inspect_after"
            ].get("pendingRequests"):
                return False, found, "the unchanged pending requests"
            found += list(leg.values())
        return True, found, ""

    def fold_roots_agreement(self, legs, receipts=None):
        """Recompute the fold-root row from every fold's receipts.

        After each fold the journey executed, both actors' `inspect`
        root equals the root in that fold's receipt.
        """
        records = legs.get("fold_roots", [])
        if not records:
            return False, [], "the fold root readbacks"
        found = []
        for record in records:
            fold = self.load_receipt(record["fold"], receipts)
            first = self.load_receipt(record["inspect_a"], receipts)
            second = self.load_receipt(record["inspect_b"], receipts)
            found += [record["fold"], record["inspect_a"], record["inspect_b"]]
            if fold is None or first is None or second is None:
                return False, [], "the fold root readbacks"
            if not fold.get("root"):
                return False, found, "the fold root"
            if first.get("root") != fold["root"]:
                return False, found, "both actors' root readback"
            if second.get("root") != fold["root"]:
                return False, found, "both actors' root readback"
        return True, found, ""

    def reject_agreement(self, legs, receipts=None):
        """Recompute the cross-actor reject row from its receipts.

        Alice books an insertion and leaves it past its processing
        deadline. Bob's reject while the retract window is still open is
        refused by name with the request still pending, and succeeds once
        the window has closed: the reject names the request, the request
        is no longer pending, the root is unchanged, and the owner's
        refund is returned.
        """
        leg = legs.get("reject", {})
        docs = {
            slot: self.load_receipt(leg[slot], receipts) if slot in leg else None
            for slot in (
                "booking",
                "early_inspect_before",
                "early_reject",
                "early_inspect_after",
                "late_inspect_before",
                "late_reject",
                "late_inspect_after",
            )
        }
        missing = [slot for slot, doc in docs.items() if doc is None]
        if missing:
            return False, [], f"the reject's {', '.join(missing)} receipt"
        (
            booking,
            early_before,
            early_reject,
            early_after,
            late_before,
            late_reject,
            late_after,
        ) = (
            docs["booking"],
            docs["early_inspect_before"],
            docs["early_reject"],
            docs["early_inspect_after"],
            docs["late_inspect_before"],
            docs["late_reject"],
            docs["late_inspect_after"],
        )
        if not isinstance(booking.get("request"), str):
            return False, list(leg.values()), "the reject booking request"
        if not isinstance(booking.get("foldDeadline"), dict):
            return False, list(leg.values()), "the booking fold deadline"
        if self.load_exit(leg["early_reject"], receipts) != 10:
            return False, list(leg.values()), "the early reject refusal exit"
        if early_reject.get("outcome") != "client-refusal":
            return False, list(leg.values()), "the early reject refusal class"
        if "still inside a window" not in early_reject.get("reason", ""):
            return False, list(leg.values()), "the early reject refusal name"
        if booking["request"] not in early_reject.get("reason", ""):
            return False, list(leg.values()), "the early rejected request name"
        if early_before.get("root") != early_after.get("root"):
            return False, list(leg.values()), "the unchanged root"
        if early_before.get("pendingRequests") != early_after.get("pendingRequests"):
            return False, list(leg.values()), "the unchanged pending requests"
        before_pending = early_before.get("pendingRequests") or []
        if not any(
            isinstance(entry, dict) and entry.get("request") == booking["request"]
            for entry in before_pending
        ):
            return False, list(leg.values()), "the still-pending request"
        if late_reject.get("outcome") != "success":
            return False, list(leg.values()), "the reject"
        if not isinstance(late_reject.get("reject"), str):
            return False, list(leg.values()), "the reject transaction"
        rejected = late_reject.get("rejected")
        if not isinstance(rejected, list) or len(rejected) != 1:
            return False, list(leg.values()), "the rejected request"
        row = rejected[0]
        if not isinstance(row, dict):
            return False, list(leg.values()), "the rejected request"
        if row.get("request") != booking["request"]:
            return False, list(leg.values()), "the rejected request"
        if row.get("owner") != booking.get("requester"):
            return False, list(leg.values()), "the rejected owner"
        if not row.get("returned"):
            return False, list(leg.values()), "the owner refund"
        if not late_reject.get("root"):
            return False, list(leg.values()), "the reject root"
        if late_before.get("root") != late_after.get("root"):
            return False, list(leg.values()), "the unchanged root"
        if late_before.get("root") != late_reject.get("root"):
            return False, list(leg.values()), "the reject root readback"
        late_before_pending = late_before.get("pendingRequests") or []
        if not any(
            isinstance(entry, dict) and entry.get("request") == booking["request"]
            for entry in late_before_pending
        ):
            return False, list(leg.values()), "the pending request before reject"
        late_after_pending = late_after.get("pendingRequests") or []
        if any(
            isinstance(entry, dict) and entry.get("request") == booking["request"]
            for entry in late_after_pending
        ):
            return False, list(leg.values()), "the cleared request"
        if late_after.get("leaf") != "unknown":
            return False, list(leg.values()), "the rejected key readback"
        return True, list(leg.values()), ""

    def wrong_reclaim_agreement(self, legs, receipts=None):
        """Recompute the wrong-owner reclaim row from its receipts.

        The other actor's reclaim of a request it did not book is refused
        by name with the not-owner class and a non-zero exit, and inspect
        shows the request still pending and the root unchanged.
        """
        leg = legs.get("reclaim-wrong", {})
        docs = {
            slot: self.load_receipt(leg[slot], receipts) if slot in leg else None
            for slot in ("booking", "inspect_before", "attempt", "inspect_after")
        }
        missing = [slot for slot, doc in docs.items() if doc is None]
        if missing:
            return False, [], f"the wrong-owner reclaim's {', '.join(missing)} receipt"
        booking, before, attempt, after = (
            docs["booking"],
            docs["inspect_before"],
            docs["attempt"],
            docs["inspect_after"],
        )
        if not isinstance(booking.get("request"), str):
            return False, list(leg.values()), "the reclaim booking request"
        if self.load_exit(leg["attempt"], receipts) != 10:
            return False, list(leg.values()), "the not-owner refusal exit"
        if attempt.get("outcome") != "client-refusal":
            return False, list(leg.values()), "the not-owner refusal class"
        if "retract-owner" not in attempt.get("reason", ""):
            return False, list(leg.values()), "the not-owner refusal name"
        if before.get("root") != after.get("root"):
            return False, list(leg.values()), "the unchanged root"
        if before.get("pendingRequests") != after.get("pendingRequests"):
            return False, list(leg.values()), "the unchanged pending requests"
        pending = before.get("pendingRequests") or []
        if not any(
            isinstance(entry, dict) and entry.get("request") == booking["request"]
            for entry in pending
        ):
            return False, list(leg.values()), "the still-pending request"
        return True, list(leg.values()), ""

    def owner_reclaim_agreement(self, legs, receipts=None):
        """Recompute the owner-reclaim row from its receipts.

        An early attempt before the processing deadline is refused by
        name; the owner's reclaim inside the window succeeds with the
        receipt's request, locked and returned binding the return to that
        request, and the request is no longer pending. Only an insertion
        is retractable. After it a new request still folds.
        """
        leg = legs.get("reclaim-owner", {})
        docs = {
            slot: self.load_receipt(leg[slot], receipts) if slot in leg else None
            for slot in (
                "booking",
                "early_inspect_before",
                "early_attempt",
                "early_inspect_after",
                "window_inspect_before",
                "success",
                "window_inspect_after",
                "continue_booking",
                "continue_fold",
                "continue_inspect_a",
                "continue_inspect_b",
            )
        }
        missing = [slot for slot, doc in docs.items() if doc is None]
        if missing:
            return False, [], f"the owner reclaim's {', '.join(missing)} receipt"
        (
            booking,
            early_before,
            early_attempt,
            early_after,
            window_before,
            success,
            window_after,
            continue_booking,
            continue_fold,
            continue_a,
            continue_b,
        ) = (
            docs["booking"],
            docs["early_inspect_before"],
            docs["early_attempt"],
            docs["early_inspect_after"],
            docs["window_inspect_before"],
            docs["success"],
            docs["window_inspect_after"],
            docs["continue_booking"],
            docs["continue_fold"],
            docs["continue_inspect_a"],
            docs["continue_inspect_b"],
        )
        if not isinstance(booking.get("request"), str):
            return False, list(leg.values()), "the reclaim booking request"
        if not isinstance(booking.get("foldDeadline"), dict):
            return False, list(leg.values()), "the booking fold deadline"
        if self.load_exit(leg["early_attempt"], receipts) != 10:
            return False, list(leg.values()), "the early reclaim refusal exit"
        if early_attempt.get("outcome") != "client-refusal":
            return False, list(leg.values()), "the early reclaim refusal class"
        early_reason = early_attempt.get("reason", "")
        if (
            "retract window opens" not in early_reason
            and "before the window" not in early_reason
        ):
            return False, list(leg.values()), "the early reclaim refusal name"
        if early_before.get("root") != early_after.get("root"):
            return False, list(leg.values()), "the unchanged root"
        early_pending = early_before.get("pendingRequests") or []
        if not any(
            isinstance(entry, dict) and entry.get("request") == booking["request"]
            for entry in early_pending
        ):
            return False, list(leg.values()), "the still-pending request"
        if success.get("outcome") != "success":
            return False, list(leg.values()), "the reclaim"
        if success.get("request") != booking["request"]:
            return False, list(leg.values()), "the reclaimed request"
        if success.get("edge") != "insertActive":
            return False, list(leg.values()), "the retractable edge"
        if success.get("owner") != booking.get("requester"):
            return False, list(leg.values()), "the reclaim owner"
        if not success.get("locked"):
            return False, list(leg.values()), "the locked value"
        returned = success.get("returned")
        if not isinstance(returned, dict):
            return False, list(leg.values()), "the owner return"
        if returned.get("request") != booking["request"]:
            return False, list(leg.values()), "the return bound to the request"
        if not isinstance(returned.get("lovelace"), int):
            return False, list(leg.values()), "the returned lovelace"
        if not success.get("root"):
            return False, list(leg.values()), "the reclaim root"
        if window_before.get("root") != window_after.get("root"):
            return False, list(leg.values()), "the unchanged root"
        if window_before.get("root") != success.get("root"):
            return False, list(leg.values()), "the reclaim root readback"
        window_before_pending = window_before.get("pendingRequests") or []
        if not any(
            isinstance(entry, dict) and entry.get("request") == booking["request"]
            for entry in window_before_pending
        ):
            return False, list(leg.values()), "the pending request before reclaim"
        window_after_pending = window_after.get("pendingRequests") or []
        if any(
            isinstance(entry, dict) and entry.get("request") == booking["request"]
            for entry in window_after_pending
        ):
            return False, list(leg.values()), "the cleared request"
        if window_after.get("leaf") != "unknown":
            return False, list(leg.values()), "the reclaimed key readback"
        if not isinstance(continue_booking.get("request"), str):
            return False, list(leg.values()), "the continued booking request"
        if continue_fold.get("request") != continue_booking["request"]:
            return False, list(leg.values()), "the fold after reclaim"
        if continue_fold.get("edge") != "insertActive":
            return False, list(leg.values()), "the continued insertion fold"
        if not continue_fold.get("root"):
            return False, list(leg.values()), "the continued fold root"
        for inspect in (continue_a, continue_b):
            if inspect.get("leaf") != "active":
                return False, list(leg.values()), "the continued active readback"
            if inspect.get("root") != continue_fold["root"]:
                return False, list(leg.values()), "the continued root readback"
        return True, list(leg.values()), ""

    def verify_records(self):
        """Every stored receipt is raw-small or a well-formed record."""
        for path in sorted(self.receipts.glob("*.json")):
            error = check_record(path.name, path.read_bytes())
            require(error is None, error)
        print("two actors: receipt records verified", flush=True)

    def directory_bytes(self, path):
        return sum(entry.stat().st_size for entry in path.rglob("*") if entry.is_file())

    def removal_check(self, legs):
        """One receipt removed must turn its row pending, on a scratch copy."""
        scratch = self.work / "scratch-remove-one"
        if scratch.exists():
            shutil.rmtree(scratch)
        shutil.copytree(self.receipts, scratch)
        (scratch / "alice-fold.json").unlink()
        passed, _, _ = self.run_one_agreement("alice", legs["alice"], scratch)
        require(
            not passed,
            "the receipt-removal control did not turn the row pending",
        )
        print("two actors: receipt-removal control holds", flush=True)

    def cap_check(self):
        size = self.directory_bytes(self.receipts)
        print(
            f"two actors: receipts {size} bytes (cap {RECEIPT_CAP_BYTES})",
            flush=True,
        )
        require(
            size <= RECEIPT_CAP_BYTES,
            f"receipts exceed the cap: {size} > {RECEIPT_CAP_BYTES}",
        )

    def run_one_agreement(self, actor, leg, receipts=None):
        """Recompute one run-one row from its receipts on disk."""
        docs = {
            slot: self.load_receipt(leg[slot], receipts) if slot in leg else None
            for slot in ("inspect_before", "booking", "fold", "inspect_after")
        }
        missing = [slot for slot, doc in docs.items() if doc is None]
        if missing:
            return False, [], f"the actor's {', '.join(missing)} receipt"
        before, booking, fold, after = (
            docs["inspect_before"],
            docs["booking"],
            docs["fold"],
            docs["inspect_after"],
        )
        if before.get("leaf") != "unknown":
            return False, list(leg.values()), "the absent key readback"
        if before.get("pendingRequests") != []:
            return False, list(leg.values()), "the empty pending readback"
        if not isinstance(booking.get("request"), str):
            return False, list(leg.values()), "the booking request"
        if fold.get("request") != booking["request"]:
            return False, list(leg.values()), "the fold of the booking"
        if fold.get("edge") != "insertActive":
            return False, list(leg.values()), "the insertion fold"
        if fold.get("folder") != booking.get("requester"):
            return False, list(leg.values()), "the folder's own booking"
        if not fold.get("root"):
            return False, list(leg.values()), "the fold root"
        if after.get("leaf") != "active":
            return False, list(leg.values()), "the active key readback"
        if after.get("root") != fold["root"]:
            return False, list(leg.values()), "the fold root readback"
        return True, list(leg.values()), ""

    def compute_rows(self, legs):
        rows = []
        for name in REQUIREMENTS:
            if name in PAGE_ROWS:
                actor = "alice" if name.startswith("Alice") else "bob"
                joining = (
                    [legs[actor]["inspect_before"]]
                    if "inspect_before" in legs.get(actor, {})
                    else []
                )
                rows.append(
                    {
                        "requirement": name,
                        "state": "pending",
                        "receipts": joining,
                        "dependencies": [ISSUE_503],
                        "waitingOn": ISSUE_503,
                    }
                )
            elif name in RUN_ONE_ROWS:
                actor = "alice" if name.startswith("Alice") else "bob"
                passed, receipts, waiting = self.run_one_agreement(
                    actor, legs.get(actor, {})
                )
                rows.append(
                    {
                        "requirement": name,
                        "state": "passed" if passed else "pending",
                        "receipts": receipts,
                        "dependencies": [],
                        "waitingOn": waiting,
                    }
                )
            elif name in RUN_TWO_TERMINATE_ROWS:
                folder = "alice" if name.startswith("Alice") else "bob"
                direction = (
                    "terminate-bob-by-alice"
                    if folder == "alice"
                    else "terminate-alice-by-bob"
                )
                passed, receipts, waiting = self.terminate_fold_agreement(
                    folder, legs.get(direction, {}), legs
                )
                rows.append(
                    {
                        "requirement": name,
                        "state": "passed" if passed else "pending",
                        "receipts": receipts,
                        "dependencies": [],
                        "waitingOn": waiting,
                    }
                )
            elif name == "Another actor folds an insertion":
                passed, receipts, waiting = self.cross_insert_agreement(legs)
                rows.append(
                    {
                        "requirement": name,
                        "state": "passed" if passed else "pending",
                        "receipts": receipts,
                        "dependencies": [],
                        "waitingOn": waiting,
                    }
                )
            elif name == "Another controller cannot update or terminate a key":
                passed, receipts, waiting = self.refusal_agreement(legs)
                rows.append(
                    {
                        "requirement": name,
                        "state": "passed" if passed else "pending",
                        "receipts": receipts,
                        "dependencies": [],
                        "waitingOn": waiting,
                    }
                )
            elif name == "Bob rejects Alice's expired request":
                passed, receipts, waiting = self.reject_agreement(legs)
                rows.append(
                    {
                        "requirement": name,
                        "state": "passed" if passed else "pending",
                        "receipts": receipts,
                        "dependencies": [],
                        "waitingOn": waiting,
                    }
                )
            elif name == "Alice cannot reclaim Bob's request":
                passed, receipts, waiting = self.wrong_reclaim_agreement(legs)
                rows.append(
                    {
                        "requirement": name,
                        "state": "passed" if passed else "pending",
                        "receipts": receipts,
                        "dependencies": [],
                        "waitingOn": waiting,
                    }
                )
            elif name == "Bob reclaims his request during its retract window":
                passed, receipts, waiting = self.owner_reclaim_agreement(legs)
                rows.append(
                    {
                        "requirement": name,
                        "state": "passed" if passed else "pending",
                        "receipts": receipts,
                        "dependencies": [],
                        "waitingOn": waiting,
                    }
                )
            elif name == "Both users inspect the fold's state root after every fold":
                passed, receipts, waiting = self.fold_roots_agreement(legs)
                rows.append(
                    {
                        "requirement": name,
                        "state": "passed" if passed else "pending",
                        "receipts": receipts,
                        "dependencies": [],
                        "waitingOn": waiting,
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
                        "waitingOn": ("the actor's inspect, booking and fold receipts"),
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
        # Every exit path below funnels through the one unconditional
        # teardown: no run ends with a surviving node, whatever failed.
        # A teardown failure is status 3 and never overrides status 2,
        # so the foreign-open control keeps its guard evidence.
        legs = {}
        status = None
        try:
            self.fixture()
            if os.environ.get("SINGULAR_TWO_ACTOR_CONTROL") == "foreign-open":
                self.foreign_open()
            for actor, key in (("alice", "alice-1"), ("bob", "bob-1")):
                legs[actor] = self.actor_leg(actor, key)
            legs["refusals"] = [
                self.refusal_leg("alice", "bob", "alice-1"),
                self.refusal_leg("bob", "alice", "bob-1"),
            ]
            legs["terminate-bob-by-alice"] = self.terminate_leg("bob", "alice", "bob-1")
            legs["terminate-alice-by-bob"] = self.terminate_leg(
                "alice", "bob", "alice-1"
            )
            legs["cross-insert"] = {
                "alice-books": self.cross_insert_leg("alice", "bob", "alice-2"),
                "bob-books": self.cross_insert_leg("bob", "alice", "bob-2"),
            }
            legs["fold_roots"] = getattr(self, "fold_records", [])
            self.removal_check(legs)
            self.cap_check()
            self.verify_records()
            rows = self.compute_rows(legs)
            self.report(rows)
            status = self.exit_for(rows)
        except GuardFired as fired:
            status = 2
            print(f"two actors: GUARD: {fired.path}", flush=True)
            self.report(self.pending_report())
        except SetupFailure as failed:
            status = 3
            print(f"two actors: SETUP: {failed}", flush=True)
            self.report(self.pending_report())
        except JourneyFailure as failed:
            status = 1
            print(f"two actors: FAIL: {failed}", flush=True)
            self.report(self.compute_rows(legs))
        except Exception as failed:  # noqa: BLE001 - a harness-internal
            # error fails the journey as a row result; it never masquerades
            # as setup and never escapes without teardown and a report.
            status = 1
            print(
                f"two actors: FAIL: internal error: {type(failed).__name__}: {failed}",
                flush=True,
            )
            try:
                self.report(self.compute_rows(legs))
            except Exception as report_failed:  # noqa: BLE001 - see above
                print(
                    f"two actors: FAIL: report failed: {report_failed}",
                    flush=True,
                )
        finally:
            try:
                self.stop_devnet()
            except Exception as teardown:  # noqa: BLE001 - see below
                print(
                    f"two actors: SETUP: teardown failed: {teardown}",
                    flush=True,
                )
                if status != 2:
                    status = 3
        return status


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
