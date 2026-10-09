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


PROCESS_TIME_MS = 120000
RETRACT_TIME_MS = 120000


# ---------------------------------------------------------------
# Neutral observations: the harness's own readings, never an actor
# command and never a receipt under test. Address derivation mirrors
# Singular.Registry.Wallet.loadWallet (Ed25519 seed, enterprise
# Testnet address); the fee bound is read from the state datum on the
# chain through the development network's Koios-shaped provider.
# ---------------------------------------------------------------

_ED_Q = (1 << 255) - 19
_ED_L = (1 << 252) + 27742317777372353535851937790883648493
_ED_D = (-121665 * pow(121666, -1, _ED_Q)) % _ED_Q
_BECH32_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"


def _ed_inv(x):
    return pow(x, _ED_Q - 2, _ED_Q)


def _ed_xrecover(y):
    xx = (y * y - 1) * _ed_inv(_ED_D * y * y + 1)
    x = pow(xx, (_ED_Q + 3) // 8, _ED_Q)
    if (x * x - xx) % _ED_Q != 0:
        x = (x * pow(2, (_ED_Q - 1) // 4, _ED_Q)) % _ED_Q
    if x % 2 != 0:
        x = _ED_Q - x
    return x


def _ed_add(p, q):
    x1, y1, x2, y2 = p[0], p[1], q[0], q[1]
    x3 = (x1 * y2 + x2 * y1) * _ed_inv(1 + _ED_D * x1 * x2 * y1 * y2)
    y3 = (y1 * y2 + x1 * x2) * _ed_inv(1 - _ED_D * x1 * x2 * y1 * y2)
    return (x3 % _ED_Q, y3 % _ED_Q)


def _ed_scalarmult(p, e):
    q = (0, 1)
    while e > 0:
        if e & 1:
            q = _ed_add(q, p)
        p = _ed_add(p, p)
        e >>= 1
    return q


def _ed_base():
    comp = bytes.fromhex("58" + "66" * 31)
    y = int.from_bytes(comp, "little") & ~(1 << 255)
    x = _ed_xrecover(y)
    if x % 2 != 0:
        x = _ED_Q - x
    return (x, y)


_ED_G = _ed_base()


def _ed_pubkey(seed):
    digest = hashlib.sha512(seed).digest()
    a = int.from_bytes(digest[:32], "little")
    a &= ~(1 | 2 | 4 | (1 << 255))
    a |= 1 << 254
    return _ed_encodepoint(*_ed_scalarmult(_ED_G, a))


def _ed_encodepoint(x, y):
    bits = [(y >> i) & 1 for i in range(255)] + [x & 1]
    return bytes(sum(bits[i * 8 + j] << j for j in range(8)) for i in range(32))


def _bech32_polymod(values):
    generators = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]
    check = 1
    for value in values:
        top = check >> 25
        check = ((check & 0x1FFFFFF) << 5) ^ value
        for i in range(5):
            check ^= generators[i] if ((top >> i) & 1) else 0
    return check


def _bech32_hrp_expand(hrp):
    return [ord(c) >> 5 for c in hrp] + [0] + [ord(c) & 31 for c in hrp]


def _bech32_checksum(hrp, data):
    values = _bech32_hrp_expand(hrp) + data
    polymod = _bech32_polymod(values + [0, 0, 0, 0, 0, 0]) ^ 1
    return [(polymod >> 5 * (5 - i)) & 31 for i in range(6)]


def _bech32_convertbits(data, from_bits, to_bits, pad=True):
    acc, bits, out, maximum = 0, 0, [], (1 << to_bits) - 1
    for byte in data:
        acc = (acc << from_bits) | byte
        bits += from_bits
        while bits >= to_bits:
            bits -= to_bits
            out.append((acc >> bits) & maximum)
    if pad:
        if bits:
            out.append((acc << (to_bits - bits)) & maximum)
    elif bits >= from_bits or ((acc << (to_bits - bits)) & maximum):
        return None
    return out


def _bech32_encode(hrp, raw):
    data = _bech32_convertbits(raw, 8, 5)
    combined = data + _bech32_checksum(hrp, data)
    return hrp + "1" + "".join(_BECH32_CHARSET[d] for d in combined)


def read_wallet_skey_bytes(path):
    """The 32 signing-key bytes behind a wallet-key file.

    Mirrors the leniency of Wallet.loadWallet: 32 raw bytes, bare hex,
    or a JSON text envelope carrying cborHex (5820 plus 32 bytes).
    """
    raw = Path(path).read_bytes().strip()
    if len(raw) == 32 and not all(0x20 <= byte < 0x7F for byte in raw):
        return bytes(raw)
    text = raw.decode("utf-8", errors="strict").strip()
    if text.startswith("{"):
        parsed = json.loads(text)
        text = parsed["cborHex"]
    blob = bytes.fromhex(text)
    if len(blob) == 34 and blob[:2] == b"\x58\x20":
        return bytes(blob[2:])
    if len(blob) == 32:
        return blob
    raise ValueError(f"expected 32 key bytes, found {len(blob)}")


def derive_wallet_address(skey_bytes):
    """Key hash hex and enterprise Testnet address for 32 seed bytes."""
    if len(skey_bytes) != 32:
        raise ValueError(f"expected 32 seed bytes, found {len(skey_bytes)}")
    pub = _ed_pubkey(bytes(skey_bytes))
    key_hash = hashlib.blake2b(pub, digest_size=28).digest()
    return key_hash.hex(), _bech32_encode("addr_test", b"\x60" + key_hash)


def _cbor_item(buf, pos):
    """One CBOR item from BUF at POS; definite lengths only."""
    first = buf[pos]
    major, info = first >> 5, first & 0x1F
    pos += 1
    if info < 24:
        length = info
    elif info == 24:
        length = buf[pos]
        pos += 1
    elif info == 25:
        length = int.from_bytes(buf[pos : pos + 2], "big")
        pos += 2
    elif info == 26:
        length = int.from_bytes(buf[pos : pos + 4], "big")
        pos += 4
    elif info == 27:
        length = int.from_bytes(buf[pos : pos + 8], "big")
        pos += 8
    else:
        raise ValueError("indefinite CBOR lengths are not datum")
    if major == 0:
        return length, pos
    if major == 1:
        return -1 - length, pos
    if major == 2:
        return bytes(buf[pos : pos + length]), pos + length
    if major == 3:
        return bytes(buf[pos : pos + length]).decode("utf-8"), pos + length
    if major == 4:
        items = []
        for _ in range(length):
            item, pos = _cbor_item(buf, pos)
            items.append(item)
        return items, pos
    if major == 5:
        mapping = {}
        for _ in range(length):
            key, pos = _cbor_item(buf, pos)
            try:
                map_key = json.dumps(key, sort_keys=True)
            except TypeError:
                map_key = repr(key)
            mapping[map_key], pos = _cbor_item(buf, pos)
        return mapping, pos
    if major == 6:
        item, pos = _cbor_item(buf, pos)
        if 121 <= length <= 127:
            return ("constr", length - 121, item), pos
        if 1280 <= length <= 1400:
            return ("constr", length - 1280 + 7, item), pos
        return ("tag", length, item), pos
    raise ValueError(f"unsupported CBOR major type {major}")


def decode_plutus_datum(datum_hex):
    """The top Plutus-Data value of hex datum bytes."""
    raw = bytes.fromhex(datum_hex)
    value, pos = _cbor_item(raw, 0)
    if pos != len(raw):
        raise ValueError("trailing bytes after the datum")
    return value


def fetch_state_fee_bound(
    provider_url, policy_hex, name_hex, expect_process_ms, expect_retract_ms
):
    """Read the registry's fee bound from its state datum on the chain.

    Queries the Koios-shaped provider for unspent outputs holding the
    state token, decodes each inline datum, and takes the Constr-0
    eight-field state datum whose process and retract windows match the
    independently observed registry windows. Returns the fee bound with
    its provenance. Raises RuntimeError with a diagnostic otherwise.
    """
    import urllib.request

    base = provider_url.rstrip("/")
    body = json.dumps(
        {"_asset_list": [[policy_hex, name_hex]], "_extended": True}
    ).encode()
    last_error = "no datum decoded"
    for attempt in range(3):
        try:
            request = urllib.request.Request(
                base + "/asset_utxos",
                data=body,
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(request, timeout=30) as answer:
                rows = json.loads(answer.read().decode("utf-8"))
            if not isinstance(rows, list) or not rows:
                last_error = "asset_utxos answered no rows for the state token"
                raise ValueError(last_error)
            for row in rows:
                if not isinstance(row, dict):
                    continue
                inline = row.get("inline_datum")
                if not isinstance(inline, dict) or "bytes" not in inline:
                    continue
                try:
                    datum = decode_plutus_datum(inline["bytes"])
                except ValueError as error:
                    last_error = f"a datum did not decode: {error}"
                    continue
                if (
                    not isinstance(datum, tuple)
                    or len(datum) != 3
                    or datum[0] != "constr"
                    or datum[1] != 0
                    or not isinstance(datum[2], list)
                    or len(datum[2]) != 8
                ):
                    continue
                _root, fee, process, retract = datum[2][0:4]
                if not all(isinstance(v, int) for v in (fee, process, retract)):
                    continue
                if process != expect_process_ms or retract != expect_retract_ms:
                    last_error = (
                        f"a state datum carries other windows: {process}/{retract}"
                    )
                    continue
                if fee <= 0:
                    last_error = "a state datum carries no positive fee"
                    continue
                return {
                    "stateMaxFee": fee,
                    "processTime": process,
                    "retractTime": retract,
                    "observedTx": f"{row.get('tx_hash')}#{row.get('tx_index')}",
                }
            last_error = "no row carried the registry state datum"
            raise ValueError(last_error)
        except ValueError:
            if attempt >= 2:
                break
            time.sleep(2)
        except Exception as error:
            last_error = f"{type(error).__name__}: {error}"
            if attempt >= 2:
                break
            time.sleep(2)
    raise RuntimeError(f"the fee bound is not established: {last_error}")


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
    "foldDeadline",
    "retractTime",
    "processTime",
    "processingEnds",
    "retractEnds",
    "wallet",
    "topUp",
    "stateMaxFee",
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
                str(PROCESS_TIME_MS),
                "--retract-time",
                str(RETRACT_TIME_MS),
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
                str(PROCESS_TIME_MS),
                "--retract-time",
                str(RETRACT_TIME_MS),
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
        self.fetch_fee_bound()

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

    def wallet_address(self, party):
        """PARTY's enterprise Testnet address, derived neutrally.

        Read from the wallet-key file the harness itself generated
        outside every home; no actor command runs. Raises SetupFailure
        when the key is missing or unreadable.
        """
        try:
            skey = read_wallet_skey_bytes(self.keys / f"{party}.skey")
            _key_hash, address = derive_wallet_address(skey)
        except (OSError, ValueError) as error:
            raise SetupFailure(f"{party} wallet address is not derived: {error}")
        return address

    def fetch_fee_bound(self):
        """Read the registry's fee bound from its state datum on chain.

        A neutral harness read through the development network's
        provider (no actor command, no wallet): the unspent output
        holding the state token carries the eight-field state datum
        whose second field is the published fee. Stored for the rows
        beside the command receipts. A missing bound is setup, never a
        row result.
        """
        policy, _, name = self.state_token.partition(".")
        setup_require(policy and name, "the state token names no asset")
        try:
            bound = fetch_state_fee_bound(
                self.settings["providerUrl"],
                policy,
                name,
                PROCESS_TIME_MS,
                RETRACT_TIME_MS,
            )
        except RuntimeError as error:
            raise SetupFailure(str(error))
        bound["command"] = "fee-bound"
        bound["outcome"] = "success"
        bound["stateToken"] = self.state_token
        (self.receipts / "fee-bound.json").write_text(
            json.dumps(bound, indent=2) + "\n"
        )
        print(f"two actors: fee bound {bound['stateMaxFee']}", flush=True)
        return bound

    def now_ms(self):
        """The host clock in POSIX milliseconds."""
        return int(time.time() * 1000)

    def sleep_until_ms(self, target_ms):
        """Sleep until the host clock reaches TARGET_MS.

        The target is always a receipt deadline plus a margin, never a
        guessed duration: the booking receipt's fold deadline and the
        creator's retract window decide when a window opens and closes.
        """
        now = self.now_ms()
        if target_ms > now:
            print(
                f"two actors: waiting {(target_ms - now) // 1000}s until {target_ms}",
                flush=True,
            )
            time.sleep((target_ms - now) / 1000.0)

    def reject_command(self, party):
        """Reject every pending request with PARTY's wallet."""
        return [
            "registry",
            "reject",
            "--blueprint",
            self.blueprint,
            "--state-token",
            self.state_token,
            *self.node_arguments(),
            "--wallet-skey",
            str(self.keys / f"{party}.skey"),
        ]

    def reclaim_command(self, party, request):
        """Take back PARTY's named pending request."""
        return [
            "registry",
            "reclaim",
            "--request",
            request,
            "--blueprint",
            self.blueprint,
            "--state-token",
            self.state_token,
            *self.node_arguments(),
            "--wallet-skey",
            str(self.keys / f"{party}.skey"),
        ]

    def reject_leg(self, booker, rejector, key):
        """BOOKER books KEY; REJECTOR rejects it once expired.

        The booking receipt's fold deadline plus the creator's retract
        window decides the waits, never a guessed sleep. The early reject
        while the retract window is still open is refused by name with the
        request still pending; the late reject once it has closed succeeds
        with the refund bound to the request and the root unchanged.
        """
        booker_others = tuple(
            home for party, home in self.homes.items() if party != booker
        )
        rejector_others = tuple(
            home for party, home in self.homes.items() if party != rejector
        )
        leg = {}
        status, booking = self.run_party(
            booker,
            "reject-alice-3-booking",
            self.book(booker, "insert", key, "reject-alice-3"),
            booker_others,
        )
        require(
            status == 0 and booking.get("outcome") == "success",
            f"{booker} reject booking failed: exit {status}, {booking}",
        )
        require(
            isinstance(booking.get("request"), str),
            f"{booker} reject booking named no request: {booking}",
        )
        require(
            isinstance(booking.get("foldDeadline"), dict)
            and isinstance(booking["foldDeadline"].get("posixMs"), int),
            f"{booker} booking named no fold deadline: {booking}",
        )
        leg["booking"] = "reject-alice-3-booking"
        deadline_ms = booking["foldDeadline"]["posixMs"]
        self.sleep_until_ms(deadline_ms + 5000)
        status, early_before = self.run_party(
            rejector,
            "reject-early-inspect-before",
            self.inspect_key(key),
            rejector_others,
        )
        require(
            status == 0 and early_before.get("outcome") == "success",
            f"{rejector} early inspect-before failed: exit {status}, {early_before}",
        )
        leg["early_inspect_before"] = "reject-early-inspect-before"
        require(
            isinstance(early_before.get("retractTime"), int),
            f"{rejector} early inspect named no retract time: {early_before}",
        )
        retract_ends = deadline_ms + early_before["retractTime"]
        status, early_reject = self.run_party(
            rejector,
            "reject-early",
            self.reject_command(rejector),
            rejector_others,
        )
        require(
            status == 10
            and early_reject.get("outcome") == "client-refusal"
            and "still inside a window" in early_reject.get("reason", "")
            and booking["request"] in early_reject.get("reason", ""),
            f"{rejector} early reject was not refused by window: "
            f"exit {status}, {early_reject}",
        )
        leg["early_reject"] = "reject-early"
        status, early_after = self.run_party(
            rejector,
            "reject-early-inspect-after",
            self.inspect_key(key),
            rejector_others,
        )
        require(
            status == 0 and early_after.get("outcome") == "success",
            f"{rejector} early inspect-after failed: exit {status}, {early_after}",
        )
        require(
            early_after.get("root") == early_before.get("root"),
            f"{rejector} root moved under a refused reject: "
            f"{early_before.get('root')} -> {early_after.get('root')}",
        )
        require(
            early_after.get("pendingRequests") == early_before.get("pendingRequests"),
            f"{rejector} pending moved under a refused reject",
        )
        leg["early_inspect_after"] = "reject-early-inspect-after"
        self.sleep_until_ms(retract_ends + 5000)
        status, late_before = self.run_party(
            rejector,
            "reject-late-inspect-before",
            self.inspect_key(key),
            rejector_others,
        )
        require(
            status == 0 and late_before.get("outcome") == "success",
            f"{rejector} late inspect-before failed: exit {status}, {late_before}",
        )
        leg["late_inspect_before"] = "reject-late-inspect-before"
        status, late_reject = self.run_party(
            rejector,
            "reject-late",
            self.reject_command(rejector),
            rejector_others,
        )
        require(
            status == 0 and late_reject.get("outcome") == "success",
            f"{rejector} reject failed: exit {status}, {late_reject}",
        )
        require(
            isinstance(late_reject.get("reject"), str),
            f"{rejector} reject named no transaction: {late_reject}",
        )
        rejected = late_reject.get("rejected")
        require(
            isinstance(rejected, list) and len(rejected) == 1,
            f"{rejector} reject named no single request: {late_reject}",
        )
        require(
            rejected[0].get("request") == booking["request"],
            f"{rejector} rejected another request: {rejected[0].get('request')} "
            f"!= {booking['request']}",
        )
        require(
            rejected[0].get("owner") == booking.get("requester"),
            f"{rejector} reject names another owner: {rejected[0].get('owner')}",
        )
        require(
            rejected[0].get("returned"),
            f"{rejector} reject names no refund: {late_reject}",
        )
        require(
            late_reject.get("root"),
            f"{rejector} reject named no root: {late_reject}",
        )
        leg["late_reject"] = "reject-late"
        status, late_after = self.run_party(
            rejector,
            "reject-late-inspect-after",
            self.inspect_key(key),
            rejector_others,
        )
        require(
            status == 0 and late_after.get("outcome") == "success",
            f"{rejector} late inspect-after failed: exit {status}, {late_after}",
        )
        require(
            late_after.get("root")
            == late_before.get("root")
            == late_reject.get("root"),
            f"{rejector} root moved during a reject: "
            f"{late_before.get('root')} -> {late_after.get('root')} "
            f"vs {late_reject.get('root')}",
        )
        require(
            late_after.get("leaf") == "unknown",
            f"{rejector} rejected key is not unknown: {late_after.get('leaf')}",
        )
        late_after_pending = late_after.get("pendingRequests") or []
        require(
            not any(
                isinstance(entry, dict) and entry.get("request") == booking["request"]
                for entry in late_after_pending
            ),
            f"{rejector} rejected request is still pending: "
            f"{late_after.get('pendingRequests')}",
        )
        leg["late_inspect_after"] = "reject-late-inspect-after"
        return leg

    def reclaim_wrong_leg(self, owner, foreign, key):
        """FOREIGN attempts OWNER's KEY; refused as not-owner.

        OWNER books an insertion; FOREIGN's reclaim of it is refused by
        name with the not-owner class and a non-zero exit, and inspect
        shows the request still pending and the root unchanged.
        """
        owner_others = tuple(
            home for party, home in self.homes.items() if party != owner
        )
        foreign_others = tuple(
            home for party, home in self.homes.items() if party != foreign
        )
        leg = {}
        status, booking = self.run_party(
            owner,
            "reclaim-bob-3-booking",
            self.book(owner, "insert", key, "reclaim-bob-3"),
            owner_others,
        )
        require(
            status == 0 and booking.get("outcome") == "success",
            f"{owner} reclaim booking failed: exit {status}, {booking}",
        )
        require(
            isinstance(booking.get("request"), str),
            f"{owner} reclaim booking named no request: {booking}",
        )
        leg["booking"] = "reclaim-bob-3-booking"
        status, before = self.run_party(
            foreign,
            "reclaim-wrong-inspect-before",
            self.inspect_key(key),
            foreign_others,
        )
        require(
            status == 0 and before.get("outcome") == "success",
            f"{foreign} wrong inspect-before failed: exit {status}, {before}",
        )
        leg["inspect_before"] = "reclaim-wrong-inspect-before"
        status, attempt = self.run_party(
            foreign,
            "reclaim-wrong-attempt",
            self.reclaim_command(foreign, booking["request"]),
            foreign_others,
        )
        require(
            status == 10
            and attempt.get("outcome") == "client-refusal"
            and "retract-owner" in attempt.get("reason", ""),
            f"{foreign} reclaim was not refused as not-owner: exit {status}, {attempt}",
        )
        leg["attempt"] = "reclaim-wrong-attempt"
        status, after = self.run_party(
            foreign,
            "reclaim-wrong-inspect-after",
            self.inspect_key(key),
            foreign_others,
        )
        require(
            status == 0 and after.get("outcome") == "success",
            f"{foreign} wrong inspect-after failed: exit {status}, {after}",
        )
        require(
            after.get("root") == before.get("root"),
            f"{foreign} root moved under a refused reclaim: "
            f"{before.get('root')} -> {after.get('root')}",
        )
        require(
            after.get("pendingRequests") == before.get("pendingRequests"),
            f"{foreign} pending moved under a refused reclaim",
        )
        pending = before.get("pendingRequests") or []
        require(
            any(
                isinstance(entry, dict) and entry.get("request") == booking["request"]
                for entry in pending
            ),
            f"{foreign} reclaimed request is not still pending",
        )
        leg["inspect_after"] = "reclaim-wrong-inspect-after"
        return leg

    def reclaim_owner_leg(self, owner, key):
        """OWNER reclaims KEY inside its retract window.

        Reuses the booking the wrong-owner leg left pending in the same
        run. An early attempt before the processing deadline is refused by
        name; the reclaim inside the window succeeds with the return bound
        to the request. Only an insertion is retractable. After it a new
        request still folds.
        """
        owner_others = tuple(
            home for party, home in self.homes.items() if party != owner
        )
        other = "bob" if owner == "alice" else "alice"
        other_others = tuple(
            home for party, home in self.homes.items() if party != other
        )
        leg = {}
        leg["booking"] = "reclaim-bob-3-booking"
        booking = self.load_receipt(leg["booking"])
        require(
            booking is not None and isinstance(booking.get("request"), str),
            f"{owner} reclaim booking is not pending: {booking}",
        )
        require(
            isinstance(booking.get("foldDeadline"), dict)
            and isinstance(booking["foldDeadline"].get("posixMs"), int),
            f"{owner} booking named no fold deadline: {booking}",
        )
        deadline_ms = booking["foldDeadline"]["posixMs"]
        status, early_before = self.run_party(
            owner,
            "reclaim-early-inspect-before",
            self.inspect_key(key),
            owner_others,
        )
        require(
            status == 0 and early_before.get("outcome") == "success",
            f"{owner} early inspect-before failed: exit {status}, {early_before}",
        )
        leg["early_inspect_before"] = "reclaim-early-inspect-before"
        status, early_attempt = self.run_party(
            owner,
            "reclaim-early-attempt",
            self.reclaim_command(owner, booking["request"]),
            owner_others,
        )
        require(
            status == 10
            and early_attempt.get("outcome") == "client-refusal"
            and (
                "retract window opens" in early_attempt.get("reason", "")
                or "before the window" in early_attempt.get("reason", "")
            ),
            f"{owner} early reclaim was not refused by window: "
            f"exit {status}, {early_attempt}",
        )
        leg["early_attempt"] = "reclaim-early-attempt"
        status, early_after = self.run_party(
            owner,
            "reclaim-early-inspect-after",
            self.inspect_key(key),
            owner_others,
        )
        require(
            status == 0 and early_after.get("outcome") == "success",
            f"{owner} early inspect-after failed: exit {status}, {early_after}",
        )
        require(
            early_after.get("root") == early_before.get("root"),
            f"{owner} root moved under a refused reclaim",
        )
        leg["early_inspect_after"] = "reclaim-early-inspect-after"
        self.sleep_until_ms(deadline_ms + 5000)
        status, window_before = self.run_party(
            owner,
            "reclaim-window-inspect-before",
            self.inspect_key(key),
            owner_others,
        )
        require(
            status == 0 and window_before.get("outcome") == "success",
            f"{owner} window inspect-before failed: exit {status}, {window_before}",
        )
        leg["window_inspect_before"] = "reclaim-window-inspect-before"
        status, success = self.run_party(
            owner,
            "reclaim-success",
            self.reclaim_command(owner, booking["request"]),
            owner_others,
        )
        require(
            status == 0 and success.get("outcome") == "success",
            f"{owner} reclaim failed: exit {status}, {success}",
        )
        require(
            success.get("request") == booking["request"],
            f"{owner} reclaimed another request: {success.get('request')} "
            f"!= {booking['request']}",
        )
        require(
            success.get("edge") == "insertActive",
            f"{owner} reclaimed another edge: {success.get('edge')}",
        )
        require(
            success.get("owner") == booking.get("requester"),
            f"{owner} reclaim names another owner: {success.get('owner')}",
        )
        require(
            success.get("locked"),
            f"{owner} reclaim names no locked value: {success}",
        )
        returned = success.get("returned")
        require(
            isinstance(returned, dict)
            and returned.get("request") == booking["request"]
            and isinstance(returned.get("lovelace"), int),
            f"{owner} return is not bound to the request: {success}",
        )
        require(
            success.get("root"),
            f"{owner} reclaim named no root: {success}",
        )
        leg["success"] = "reclaim-success"
        status, window_after = self.run_party(
            owner,
            "reclaim-window-inspect-after",
            self.inspect_key(key),
            owner_others,
        )
        require(
            status == 0 and window_after.get("outcome") == "success",
            f"{owner} window inspect-after failed: exit {status}, {window_after}",
        )
        require(
            window_after.get("root")
            == window_before.get("root")
            == success.get("root"),
            f"{owner} root moved during a reclaim",
        )
        require(
            window_after.get("leaf") == "unknown",
            f"{owner} reclaimed key is not unknown: {window_after.get('leaf')}",
        )
        window_after_pending = window_after.get("pendingRequests") or []
        require(
            not any(
                isinstance(entry, dict) and entry.get("request") == booking["request"]
                for entry in window_after_pending
            ),
            f"{owner} reclaimed request is still pending",
        )
        leg["window_inspect_after"] = "reclaim-window-inspect-after"
        status, continue_booking = self.run_party(
            "alice",
            "reclaim-continue-booking",
            self.book("alice", "insert", "alice-4", "reclaim-continue"),
            tuple(home for party, home in self.homes.items() if party != "alice"),
        )
        require(
            status == 0 and continue_booking.get("outcome") == "success",
            f"alice continue booking failed: exit {status}, {continue_booking}",
        )
        leg["continue_booking"] = "reclaim-continue-booking"
        status, continue_fold = self.run_party(
            "bob",
            "reclaim-continue-fold",
            self.fold_pending("bob"),
            other_others if other == "bob" else owner_others,
        )
        require(
            status == 0 and continue_fold.get("outcome") == "success",
            f"bob continue fold failed: exit {status}, {continue_fold}",
        )
        require(
            continue_fold.get("request") == continue_booking["request"],
            "bob folded another request after reclaim",
        )
        require(
            continue_fold.get("edge") == "insertActive",
            "bob folded another edge after reclaim",
        )
        require(
            continue_fold.get("root"),
            f"bob continue fold named no root: {continue_fold}",
        )
        leg["continue_fold"] = "reclaim-continue-fold"
        for party, slot in (
            ("alice", "continue_inspect_a"),
            ("bob", "continue_inspect_b"),
        ):
            others = tuple(home for name, home in self.homes.items() if name != party)
            status, after = self.run_party(
                party,
                f"reclaim-continue-inspect-{party}",
                self.inspect_key("alice-4"),
                others,
            )
            require(
                status == 0 and after.get("outcome") == "success",
                f"{party} continue inspect failed: exit {status}, {after}",
            )
            require(
                after.get("leaf") == "active",
                f"{party} continued key is not active: {after.get('leaf')}",
            )
            require(
                after.get("root") == continue_fold["root"],
                f"{party} continued root differs from the fold",
            )
            leg[slot] = f"reclaim-continue-inspect-{party}"
        self.record_fold_root(
            leg["continue_fold"],
            "alice-4",
            leg["continue_inspect_a"],
            leg["continue_inspect_b"],
        )
        return leg

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
        deadline = booking.get("foldDeadline")
        if not isinstance(deadline, dict) or not isinstance(
            deadline.get("posixMs"), int
        ):
            return False, list(leg.values()), "the booking fold deadline"
        deadline_ms = deadline["posixMs"]
        for slot in ("early_inspect_before", "late_inspect_before"):
            inspect = docs[slot]
            if not isinstance(inspect.get("retractTime"), int):
                return False, list(leg.values()), "the registry retract time"
            if inspect["retractTime"] != RETRACT_TIME_MS:
                return False, list(leg.values()), "the fixture window"
        expected_close = deadline_ms + docs["early_inspect_before"]["retractTime"]
        if docs["late_inspect_before"].get("retractTime") != docs[
            "early_inspect_before"
        ].get("retractTime"):
            return False, list(leg.values()), "the registry retract time"
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
        late_pending_entry = next(
            (
                entry
                for entry in (late_before.get("pendingRequests") or [])
                if isinstance(entry, dict)
                and entry.get("request") == booking["request"]
            ),
            None,
        )
        if late_pending_entry is None:
            return False, list(leg.values()), "the pending request before reject"
        expected_locked = late_pending_entry.get("locked")
        if (
            not isinstance(expected_locked, dict)
            or row.get("locked") != expected_locked
        ):
            return False, list(leg.values()), "the locked value"
        tip = row.get("tip")
        fee_bound = self.load_receipt("fee-bound", receipts)
        if fee_bound is None or not isinstance(fee_bound.get("stateMaxFee"), int):
            return False, [], "the fee bound"
        bound = fee_bound["stateMaxFee"]
        if bound <= 0:
            return False, [], "the fee bound"
        if tip != bound:
            return False, list(leg.values()), "the authorized tip"
        returned = row.get("returned")
        if not isinstance(returned, dict):
            return False, list(leg.values()), "the owner refund"
        locked_lovelace = expected_locked.get("lovelace")
        returned_lovelace = returned.get("lovelace")
        if not isinstance(locked_lovelace, int) or not isinstance(
            returned_lovelace, int
        ):
            return False, list(leg.values()), "the refund lovelace"
        if returned_lovelace != locked_lovelace - bound:
            return False, list(leg.values()), "the refund net of the fee bound"
        if row.get("topUp", 0) != 0:
            return False, list(leg.values()), "the top-up"
        if row.get("processingEnds") != deadline_ms:
            return False, list(leg.values()), "the processing end"
        if row.get("retractEnds") != expected_close:
            return False, list(leg.values()), "the retract close"
        if returned.get("recipient") != self.wallet_address("alice"):
            return False, list(leg.values()), "the owner recipient"
        if returned.get("index") != 1:
            return False, list(leg.values()), "the designated output"
        if returned.get("output") != f"{late_reject.get('reject')}#1":
            return False, list(leg.values()), "the designated output"
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
        deadline = booking.get("foldDeadline")
        if not isinstance(deadline, dict) or not isinstance(
            deadline.get("posixMs"), int
        ):
            return False, list(leg.values()), "the booking fold deadline"
        deadline_ms = deadline["posixMs"]
        for slot in ("early_inspect_before", "window_inspect_before"):
            inspect = docs[slot]
            if not isinstance(inspect.get("retractTime"), int):
                return False, list(leg.values()), "the registry retract time"
            if inspect["retractTime"] != RETRACT_TIME_MS:
                return False, list(leg.values()), "the fixture window"
        if docs["window_inspect_before"].get("retractTime") != docs[
            "early_inspect_before"
        ].get("retractTime"):
            return False, list(leg.values()), "the registry retract time"
        expected_close = deadline_ms + docs["early_inspect_before"]["retractTime"]
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
        if early_before.get("pendingRequests") != early_after.get("pendingRequests"):
            return False, list(leg.values()), "the unchanged pending requests"
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
        window_pending_entry = next(
            (
                entry
                for entry in (window_before.get("pendingRequests") or [])
                if isinstance(entry, dict)
                and entry.get("request") == booking["request"]
            ),
            None,
        )
        if window_pending_entry is None:
            return False, list(leg.values()), "the pending request before reclaim"
        expected_locked = window_pending_entry.get("locked")
        if (
            not isinstance(expected_locked, dict)
            or success.get("locked") != expected_locked
        ):
            return False, list(leg.values()), "the locked value"
        returned = success.get("returned")
        if not isinstance(returned, dict):
            return False, list(leg.values()), "the owner return"
        if returned.get("request") != booking["request"]:
            return False, list(leg.values()), "the return bound to the request"
        locked_lovelace = expected_locked.get("lovelace")
        returned_lovelace = returned.get("lovelace")
        if not isinstance(locked_lovelace, int) or not isinstance(
            returned_lovelace, int
        ):
            return False, list(leg.values()), "the returned lovelace"
        top_up = success.get("topUp", 0)
        if not isinstance(top_up, int) or top_up < 0:
            return False, list(leg.values()), "the top-up"
        if returned_lovelace != locked_lovelace + top_up:
            return False, list(leg.values()), "the return net of the top-up"
        if returned_lovelace <= 0:
            return False, list(leg.values()), "the returned lovelace"
        if returned.get("recipient") != self.wallet_address("bob"):
            return False, list(leg.values()), "the owner recipient"
        if returned.get("index") != 0:
            return False, list(leg.values()), "the designated output"
        if returned.get("output") != f"{success.get('retract')}#0":
            return False, list(leg.values()), "the designated output"
        if success.get("processingEnds") != deadline_ms:
            return False, list(leg.values()), "the processing end"
        if success.get("retractEnds") != expected_close:
            return False, list(leg.values()), "the retract close"
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
            legs["reject"] = self.reject_leg("alice", "bob", "alice-3")
            legs["reclaim-wrong"] = self.reclaim_wrong_leg("bob", "alice", "bob-3")
            legs["reclaim-owner"] = self.reclaim_owner_leg("bob", "bob-3")
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
