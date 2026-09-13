#!/usr/bin/env python3
"""Parent-owned verifier for the bounded registration compositor.

This program deliberately does not consume candidate verdicts.  The candidate
prepares raw UPLC arguments and real transaction files; a parent seal pins the
meaning and digest of those inputs.  This program rebuilds every program,
executes the fixed row matrix, inspects/submits the fixed ledger rows, and runs
the fixed mutation matrix before it can write a success receipt.

The verifier is reviewable before the final producer seal exists.  Until a
complete parent seal and a genuine E0 run exist it has no successful mode.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, NoReturn


SCHEMA = "singular-consumer-registration-parent-seal-v3"
RECEIPT_SCHEMA = "singular-consumer-registration-parent-receipt-v3"
PREPARED_SCHEMA = "singular-consumer-registration-prepared-v3"
VECTOR_SCHEMA = "singular-consumer-registration-cek-vectors-v3"
LEDGER_SCHEMA = "singular-consumer-registration-ledger-plan-v3"
INVENTORY_SCHEMA = "singular-consumer-registration-inventory-v2"

ARTIFACTS = (
    "producer-state",
    "producer-request",
    "producer-application",
    "producer-applied-representative",
    "registry-adapter",
    "checkpoint-policy",
    "lifecycle-observer",
)

# None means every program must halt.  Otherwise exactly the named program must
# fail with an evaluator logic error and all six prerequisites must halt.
CEK_ROWS: dict[str, str | None] = {
    "E0-register-valid-cek": None,
    "E1-missing-inception-cek": "lifecycle-observer",
    "E4-wrong-allocation-cek": "registry-adapter",
    "register-omitted-adapter": "producer-state",
    "register-swapped-adapter": "producer-state",
    "register-altered-pin": "producer-state",
    "register-extra-checkpoint-mint": "registry-adapter",
    "register-wrong-aid-name": "registry-adapter",
    "register-delete": "registry-adapter",
    "register-end": "registry-adapter",
    "register-surplus-action": "producer-state",
}

LEDGER_ROWS: dict[str, str | None] = {
    "E0-register-valid-ledger": None,
    "E1-missing-inception-ledger": "lifecycle-observer",
    "E4-wrong-allocation-ledger": "registry-adapter",
}

MUTATIONS: dict[str, tuple[str, bool]] = {
    "always-refuse": ("E0-register-valid-cek", False),
    "always-accept": ("E1-missing-inception-cek", True),
    "remove-inception-observer-check": ("E1-missing-inception-cek", True),
    "remove-allocation-check": ("E4-wrong-allocation-cek", True),
    "remove-unaccounted-checkpoint-check": (
        "register-extra-checkpoint-mint",
        True,
    ),
    "remove-mandatory-adapter-invocation": ("register-omitted-adapter", True),
}
ALL_CONTROLS = tuple(MUTATIONS) + ("inventory-remove-one",)

CNE_MARKERS = (
    "free index",
    "debruijn",
    "decode",
    "deserial",
    "parse",
    "unsupported builtin",
    "unknown builtin",
    "builtinsemantics",
    "out of budget",
    "exceeded",
    "timeout",
)


class GateError(RuntimeError):
    pass


def fail(message: str) -> NoReturn:
    raise GateError(message)


def canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def sha_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as src:
        for chunk in iter(lambda: src.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text())
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"invalid JSON {path}: {exc}")


def exact_keys(value: dict[str, Any], keys: set[str], where: str) -> None:
    got = set(value)
    if got != keys:
        fail(f"{where} keys differ: missing={sorted(keys-got)} extra={sorted(got-keys)}")


def hex64(value: Any, where: str) -> str:
    if not isinstance(value, str) or len(value) != 64:
        fail(f"{where} is not a SHA-256")
    try:
        bytes.fromhex(value)
    except ValueError:
        fail(f"{where} is not lowercase hex")
    if value.lower() != value:
        fail(f"{where} is not lowercase hex")
    return value


def safe_rel(value: Any, where: str) -> Path:
    if not isinstance(value, str) or not value or value.startswith("/"):
        fail(f"{where} is not a nonempty relative path")
    result = Path(value)
    if any(part in ("", ".", "..") for part in result.parts):
        fail(f"{where} contains an unsafe component")
    return result


def raw_file(raw: Path, ref: dict[str, Any], where: str) -> Path:
    exact_keys(ref, {"path", "sha256"}, where)
    path = raw / safe_rel(ref["path"], f"{where}.path")
    if not path.is_file() or path.is_symlink():
        fail(f"{where} is missing or not a regular nonsymlink file: {path}")
    if sha_file(path) != hex64(ref["sha256"], f"{where}.sha256"):
        fail(f"{where} digest mismatch")
    return path


def run(
    argv: list[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    timeout: int = 300,
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            argv,
            cwd=cwd,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        fail(f"command could not execute: {argv!r}: {exc}")


def require_ok(cp: subprocess.CompletedProcess[str], what: str) -> str:
    if cp.returncode != 0:
        fail(f"{what} exit={cp.returncode}: {cp.stderr[-1200:]}")
    return cp.stdout


def git(repo: Path, *args: str) -> str:
    return require_ok(run(["git", "-C", str(repo), *args]), f"git {' '.join(args)}").strip()


def tracked_tree_digest(repo: Path) -> str:
    names = git(repo, "ls-files", "-z").split("\0")
    rows: list[dict[str, Any]] = []
    for name in names:
        if not name:
            continue
        rel = safe_rel(name, "tracked source path")
        path = repo / rel
        if not path.is_file() or path.is_symlink():
            fail(f"tracked source is not a regular nonsymlink file: {rel}")
        rows.append({"path": name, "bytes": path.stat().st_size, "sha256": sha_file(path)})
    return sha_bytes(canonical(rows))


def copy_tracked(repo: Path, dst: Path) -> None:
    archive = subprocess.Popen(
        ["git", "-C", str(repo), "archive", "--format=tar", "HEAD"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert archive.stdout is not None
    untar = subprocess.run(
        ["tar", "-x", "-C", str(dst)],
        stdin=archive.stdout,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    archive.stdout.close()
    archive_err = archive.stderr.read() if archive.stderr is not None else b""
    archive_rc = archive.wait()
    if archive_rc != 0 or untar.returncode != 0:
        fail(
            "tracked source copy failed: "
            + archive_err.decode(errors="replace")[-800:]
            + untar.stderr.decode(errors="replace")[-800:]
        )


@dataclass(frozen=True)
class BuiltArtifact:
    artifact_id: str
    code_hex: str
    sha256: str
    script_hash: str
    code_file: Path
    source_copy: Path


def tool_version(path: str, expected: str, arg: str, label: str) -> None:
    if not Path(path).is_file() or not os.access(path, os.X_OK):
        fail(f"sealed {label} is not executable: {path}")
    output = require_ok(run([path, arg]), f"{label} version").strip()
    if output != expected:
        fail(f"{label} version drift: got {output!r}, want {expected!r}")


def artifact_index(seal: dict[str, Any]) -> dict[str, dict[str, Any]]:
    rows = seal.get("artifacts")
    if not isinstance(rows, list):
        fail("seal.artifacts is not an array")
    index: dict[str, dict[str, Any]] = {}
    for n, row in enumerate(rows):
        if not isinstance(row, dict):
            fail(f"seal.artifacts[{n}] is not an object")
        required = {
            "id",
            "source_repo",
            "source_commit",
            "source_tree_sha256",
            "project_subdir",
            "blueprint_title",
            "module",
            "validator",
            "parameters_cbor",
            "cek_argument_count",
            "compiled_sha256",
            "script_hash",
        }
        exact_keys(row, required, f"seal.artifacts[{n}]")
        aid = row["id"]
        if aid in index or aid not in ARTIFACTS:
            fail(f"unknown/duplicate artifact id: {aid!r}")
        index[aid] = row
    if set(index) != set(ARTIFACTS):
        fail(f"seal artifact inventory differs from fixed inventory: {sorted(index)}")
    return index


def build_one(
    aid: str,
    spec: dict[str, Any],
    *,
    aiken: str,
    cardano_cli: str,
    work: Path,
) -> BuiltArtifact:
    source = Path(spec["source_repo"])
    if not source.is_absolute() or not source.is_dir():
        fail(f"{aid}: source_repo must be an existing absolute directory")
    if git(source, "rev-parse", "HEAD") != spec["source_commit"]:
        fail(f"{aid}: source commit drift")
    if git(source, "status", "--porcelain"):
        fail(f"{aid}: source tree is dirty")
    if tracked_tree_digest(source) != hex64(spec["source_tree_sha256"], f"{aid}.source_tree_sha256"):
        fail(f"{aid}: tracked source-tree digest drift")

    copy = work / "sources" / aid
    copy.mkdir(parents=True)
    copy_tracked(source, copy)
    project = copy / safe_rel(spec["project_subdir"], f"{aid}.project_subdir")
    if not (project / "aiken.toml").is_file():
        fail(f"{aid}: sealed project_subdir has no aiken.toml")
    build = run([aiken, "build", "-D"], cwd=project, timeout=900)
    require_ok(build, f"{aid}: aiken build -D")
    blueprint = project / "plutus.json"
    bp = load_json(blueprint)
    matches = [v for v in bp.get("validators", []) if v.get("title") == spec["blueprint_title"]]
    if len(matches) != 1:
        fail(f"{aid}: exact blueprint title has {len(matches)} matches")

    current = blueprint
    params = spec["parameters_cbor"]
    if not isinstance(params, list) or not all(isinstance(x, str) for x in params):
        fail(f"{aid}: parameters_cbor must be an array of hex strings")
    for i, cbor in enumerate(params):
        try:
            bytes.fromhex(cbor)
        except ValueError:
            fail(f"{aid}: parameter {i} is not hex CBOR")
        out = project / f"parent-applied-{i}.json"
        cp = run(
            [
                aiken,
                "blueprint",
                "apply",
                "-i",
                str(current),
                "-o",
                str(out),
                "-m",
                spec["module"],
                "-v",
                spec["validator"],
                cbor,
            ],
            cwd=project,
        )
        require_ok(cp, f"{aid}: apply parameter {i}")
        current = out

    applied = load_json(current)
    matches = [v for v in applied.get("validators", []) if v.get("title") == spec["blueprint_title"]]
    if len(matches) != 1:
        fail(f"{aid}: applied exact title has {len(matches)} matches")
    code_hex = "".join(matches[0].get("compiledCode", "").split())
    try:
        code = bytes.fromhex(code_hex)
    except ValueError:
        fail(f"{aid}: compiledCode is not hex")
    if not code:
        fail(f"{aid}: compiledCode is empty")
    digest = sha_bytes(code)
    if digest != hex64(spec["compiled_sha256"], f"{aid}.compiled_sha256"):
        fail(f"{aid}: compiled-byte digest drift")
    script_hash = hashlib.blake2b(b"\x03" + code, digest_size=28).hexdigest()
    if script_hash != spec["script_hash"]:
        fail(f"{aid}: V3 script hash drift")

    code_file = work / "compiled" / f"{aid}.hex"
    code_file.parent.mkdir(parents=True, exist_ok=True)
    code_file.write_text(code_hex)
    envelope = work / "compiled" / f"{aid}.plutus"
    envelope.write_text(json.dumps({"type": "PlutusScriptV3", "description": aid, "cborHex": code_hex}) + "\n")
    cli_hash = require_ok(
        run([cardano_cli, "conway", "transaction", "policyid", "--script-file", str(envelope)]),
        f"{aid}: cardano-cli policyid",
    ).strip()
    if cli_hash != script_hash:
        fail(f"{aid}: independent cardano-cli script hash disagrees")
    return BuiltArtifact(aid, code_hex, digest, script_hash, code_file, copy)


def validate_vector_bindings(
    prepared: dict[str, Any], seal: dict[str, Any], raw: Path
) -> dict[str, dict[str, list[Path]]]:
    exact_keys(prepared, {"schema", "rows"}, "cek-vectors.json")
    if prepared["schema"] != VECTOR_SCHEMA or not isinstance(prepared["rows"], list):
        fail("invalid cek vector schema")
    supplied: dict[str, Any] = {}
    for n, row in enumerate(prepared["rows"]):
        if not isinstance(row, dict):
            fail(f"cek row {n} is not an object")
        exact_keys(row, {"id", "arguments"}, f"cek row {n}")
        rid = row["id"]
        if rid in supplied or rid not in CEK_ROWS:
            fail(f"unknown/duplicate CEK row {rid!r}")
        supplied[rid] = row["arguments"]
    if set(supplied) != set(CEK_ROWS):
        fail("CEK row inventory differs from fixed parent inventory")

    binding = seal.get("cek_bindings")
    if not isinstance(binding, dict) or set(binding) != set(CEK_ROWS):
        fail("seal.cek_bindings differs from fixed CEK row inventory")
    result: dict[str, dict[str, list[Path]]] = {}
    for rid in CEK_ROWS:
        if not isinstance(supplied[rid], dict) or set(supplied[rid]) != set(ARTIFACTS):
            fail(f"{rid}: argument artifact inventory differs")
        if not isinstance(binding[rid], dict) or set(binding[rid]) != set(ARTIFACTS):
            fail(f"{rid}: sealed binding artifact inventory differs")
        result[rid] = {}
        for aid in ARTIFACTS:
            refs = supplied[rid][aid]
            sealed_refs = binding[rid][aid]
            if refs != sealed_refs:
                fail(f"{rid}/{aid}: raw arguments differ from parent semantic binding")
            if not isinstance(refs, list):
                fail(f"{rid}/{aid}: argument refs must be an array")
            result[rid][aid] = [
                raw_file(raw, ref, f"{rid}/{aid}/argument[{i}]") for i, ref in enumerate(refs)
            ]
    return result


def cek_eval(aiken: str, artifact: BuiltArtifact, args: list[Path]) -> tuple[bool, str]:
    terms = []
    for path in args:
        try:
            terms.append(path.read_text().strip())
        except UnicodeDecodeError:
            fail(f"UPLC argument is not text: {path}")
        if not terms[-1]:
            fail(f"UPLC argument is empty: {path}")
    cp = run([aiken, "uplc", "eval", "--cbor", str(artifact.code_file), *terms], timeout=180)
    combined = (cp.stdout + "\n" + cp.stderr).strip()
    lower = combined.lower()
    if any(marker in lower for marker in CNE_MARKERS):
        fail(f"{artifact.artifact_id}: evaluator setup/unsupported failure, not semantic refusal: {combined[-800:]}")
    if cp.returncode == 0:
        try:
            decoded = json.loads(cp.stdout)
        except json.JSONDecodeError:
            fail(f"{artifact.artifact_id}: evaluator success output is not JSON")
        if not isinstance(decoded, dict) or not {"result", "cpu", "mem"}.issubset(decoded):
            fail(f"{artifact.artifact_id}: evaluator success JSON lacks result/cpu/mem")
        if not isinstance(decoded["result"], str) or decoded["result"].lstrip().startswith("(lam"):
            fail(f"{artifact.artifact_id}: partial application returned a lambda, not validator success")
        return True, combined
    return False, combined


def check_cek_rows(
    *,
    aiken: str,
    artifacts: dict[str, BuiltArtifact],
    vectors: dict[str, dict[str, list[Path]]],
    seal: dict[str, Any],
) -> dict[str, Any]:
    markers = seal.get("logic_error_markers")
    if not isinstance(markers, dict) or set(markers) != {k for k, v in CEK_ROWS.items() if v}:
        fail("seal.logic_error_markers differs from fixed negative rows")
    receipt: dict[str, Any] = {}
    for rid, failing in CEK_ROWS.items():
        observations: dict[str, Any] = {}
        for aid in ARTIFACTS:
            halted, output = cek_eval(aiken, artifacts[aid], vectors[rid][aid])
            wanted = aid != failing
            if halted != wanted:
                fail(f"{rid}: {aid} halted={halted}, expected={wanted}")
            if not halted:
                marker = markers[rid]
                if not isinstance(marker, str) or not marker or marker not in output:
                    fail(f"{rid}: exact parent-sealed logic-error marker absent")
            observations[aid] = {"halted": halted, "output_sha256": sha_bytes(output.encode())}
        receipt[rid] = observations
    return receipt


def json_pointer(value: Any, pointer: str) -> Any:
    if pointer == "":
        return value
    if not pointer.startswith("/"):
        fail(f"invalid JSON pointer {pointer!r}")
    cur = value
    for raw_part in pointer[1:].split("/"):
        part = raw_part.replace("~1", "/").replace("~0", "~")
        if isinstance(cur, list):
            try:
                cur = cur[int(part)]
            except (ValueError, IndexError):
                fail(f"JSON pointer misses list element: {pointer}")
        elif isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            fail(f"JSON pointer misses element: {pointer}")
    return cur


def inspect_ledger_semantics(views: dict[str, Any], seal: dict[str, Any]) -> None:
    semantics = seal.get("ledger_semantics")
    if not isinstance(semantics, dict):
        fail("seal.ledger_semantics is not an object")
    exact_keys(semantics, {"exact", "relations"}, "seal.ledger_semantics")
    exact = semantics["exact"]
    if not isinstance(exact, dict) or set(exact) != set(LEDGER_ROWS):
        fail("ledger exact semantics differ from fixed ledger rows")
    for rid, assertions in exact.items():
        if not isinstance(assertions, list) or not assertions:
            fail(f"{rid}: exact assertions must be a nonempty array")
        for n, assertion in enumerate(assertions):
            if not isinstance(assertion, dict):
                fail(f"{rid}: assertion {n} is not an object")
            exact_keys(assertion, {"pointer", "value"}, f"{rid}: assertion {n}")
            actual = json_pointer(views[rid], assertion["pointer"])
            if actual != assertion["value"]:
                fail(f"{rid}: parent semantic assertion {assertion['pointer']} differs")

    relations = semantics["relations"]
    required_relations = {
        "E1-identical-except-lifecycle-withdrawal",
        "E4-correct-total-wrong-checkpoint-destination",
    }
    if not isinstance(relations, dict) or set(relations) != required_relations:
        fail("ledger semantic relations differ from fixed relations")

    e1 = relations["E1-identical-except-lifecycle-withdrawal"]
    exact_keys(e1, {"equal_pointers", "e0_lifecycle", "e1_lifecycle"}, "E1 relation")
    for ptr in e1["equal_pointers"]:
        if json_pointer(views["E0-register-valid-ledger"], ptr) != json_pointer(
            views["E1-missing-inception-ledger"], ptr
        ):
            fail(f"E1 is not E0-equivalent at {ptr}")
    if json_pointer(views["E0-register-valid-ledger"], e1["e0_lifecycle"]) in (None, {}, [], 0):
        fail("E0 lacks the real lifecycle withdrawal")
    try:
        missing = json_pointer(views["E1-missing-inception-ledger"], e1["e1_lifecycle"])
    except GateError:
        missing = None
    if missing not in (None, {}, [], 0):
        fail("E1 does not omit the lifecycle withdrawal")

    e4 = relations["E4-correct-total-wrong-checkpoint-destination"]
    exact_keys(
        e4,
        {
            "equal_pointers",
            "e0_checkpoint_quantity",
            "e4_checkpoint_quantity",
            "e0_refund_quantity",
            "e4_refund_quantity",
            "bond",
            "total_value_pointers",
        },
        "E4 relation",
    )
    for ptr in e4["equal_pointers"] + e4["total_value_pointers"]:
        if json_pointer(views["E0-register-valid-ledger"], ptr) != json_pointer(
            views["E4-wrong-allocation-ledger"], ptr
        ):
            fail(f"E4 differs from E0 outside exact allocation at {ptr}")
    bond = e4["bond"]
    if not isinstance(bond, int) or bond <= 0:
        fail("sealed registration bond is not a positive integer")
    e0_checkpoint = json_pointer(views["E0-register-valid-ledger"], e4["e0_checkpoint_quantity"])
    e4_checkpoint = json_pointer(views["E4-wrong-allocation-ledger"], e4["e4_checkpoint_quantity"])
    e0_refund = json_pointer(views["E0-register-valid-ledger"], e4["e0_refund_quantity"])
    e4_refund = json_pointer(views["E4-wrong-allocation-ledger"], e4["e4_refund_quantity"])
    if e0_checkpoint - e4_checkpoint != bond or e4_refund - e0_refund != bond:
        fail("E4 does not move exactly the bond from checkpoint to refund")


def validate_ledger_plan(plan: dict[str, Any], seal: dict[str, Any], raw: Path) -> dict[str, Any]:
    exact_keys(plan, {"schema", "rows"}, "ledger-plan.json")
    if plan["schema"] != LEDGER_SCHEMA or not isinstance(plan["rows"], list):
        fail("invalid ledger plan schema")
    index: dict[str, Any] = {}
    for n, row in enumerate(plan["rows"]):
        exact_keys(row, {"id", "signed_tx", "watched_txins", "watched_addresses"}, f"ledger row {n}")
        rid = row["id"]
        if rid in index or rid not in LEDGER_ROWS:
            fail(f"unknown/duplicate ledger row {rid!r}")
        tx = raw_file(raw, row["signed_tx"], f"{rid}.signed_tx")
        if not isinstance(row["watched_txins"], list) or not all(isinstance(x, str) for x in row["watched_txins"]):
            fail(f"{rid}: watched_txins invalid")
        if not isinstance(row["watched_addresses"], list) or not all(isinstance(x, str) for x in row["watched_addresses"]):
            fail(f"{rid}: watched_addresses invalid")
        index[rid] = {**row, "signed_path": tx}
    if set(index) != set(LEDGER_ROWS):
        fail("ledger row inventory differs from fixed parent inventory")
    bindings = seal.get("ledger_file_bindings")
    if not isinstance(bindings, dict) or set(bindings) != set(LEDGER_ROWS):
        fail("seal ledger file bindings differ from fixed rows")
    for rid, row in index.items():
        if row["signed_tx"] != bindings[rid]:
            fail(f"{rid}: signed transaction differs from parent binding")
    return index


def ledger_args(prepared: dict[str, Any], cardano_cli: str) -> tuple[list[str], dict[str, str]]:
    network_magic = prepared.get("network_magic")
    socket = prepared.get("node_socket")
    if not isinstance(network_magic, int) or network_magic < 0:
        fail("prepared network_magic invalid")
    if not isinstance(socket, str) or not Path(socket).is_socket():
        fail("prepared node_socket is not a live socket")
    env = os.environ.copy()
    env["CARDANO_NODE_SOCKET_PATH"] = socket
    return [cardano_cli, "conway"], env


def query_watch(
    base: list[str], env: dict[str, str], network: list[str], row: dict[str, Any]
) -> dict[str, Any]:
    observed: dict[str, Any] = {"txins": {}, "addresses": {}}
    for txin in row["watched_txins"]:
        cp = run(base + ["query", "utxo", *network, "--tx-in", txin, "--output-json"], env=env)
        observed["txins"][txin] = json.loads(require_ok(cp, f"query watched tx-in {txin}"))
    for address in row["watched_addresses"]:
        cp = run(base + ["query", "utxo", *network, "--address", address, "--output-json"], env=env)
        observed["addresses"][address] = json.loads(require_ok(cp, f"query watched address {address}"))
    return observed


def run_ledger_rows(
    *,
    cardano_cli: str,
    prepared: dict[str, Any],
    rows: dict[str, Any],
    seal: dict[str, Any],
) -> dict[str, Any]:
    base, env = ledger_args(prepared, cardano_cli)
    network = ["--testnet-magic", str(prepared["network_magic"])]
    protocol = run(base + ["query", "protocol-parameters", *network, "--output-json"], env=env)
    protocol_json = json.loads(require_ok(protocol, "live protocol query"))
    if protocol_json.get("protocolVersion", {}).get("major") != 10:
        fail("live protocol major is not the sealed Variant-C major 10")

    views: dict[str, Any] = {}
    txids: dict[str, str] = {}
    before: dict[str, Any] = {}
    for rid, row in rows.items():
        tx = str(row["signed_path"])
        view = run([cardano_cli, "debug", "transaction", "view", "--tx-file", tx])
        views[rid] = json.loads(require_ok(view, f"{rid}: transaction view"))
        txid = require_ok(
            run(base + ["transaction", "txid", "--tx-file", tx, "--output-text"]),
            f"{rid}: txid",
        ).strip()
        if len(txid) != 64:
            fail(f"{rid}: invalid computed transaction id")
        txids[rid] = txid
        before[rid] = query_watch(base, env, network, row)

    # Semantics are checked before any submission so E1/E4 cannot be certified
    # by unrelated refusal and E0 cannot establish the wrong operation.
    inspect_ledger_semantics(views, seal)

    failure_markers = seal.get("ledger_failure_markers")
    if not isinstance(failure_markers, dict) or set(failure_markers) != {
        "E1-missing-inception-ledger",
        "E4-wrong-allocation-ledger",
    }:
        fail("ledger failure markers differ from fixed negative rows")
    results: dict[str, Any] = {}
    for rid, failing in LEDGER_ROWS.items():
        tx = str(rows[rid]["signed_path"])
        cp = run(base + ["transaction", "submit", *network, "--tx-file", tx], env=env)
        combined = cp.stdout + "\n" + cp.stderr
        if failing is None:
            if cp.returncode != 0:
                fail(f"{rid}: real positive submission failed exit={cp.returncode}: {combined[-1200:]}")
        else:
            if cp.returncode == 0:
                fail(f"{rid}: negative transaction was accepted")
            marker = failure_markers[rid]
            exact_keys(marker, {"phase2", "purpose"}, f"{rid}: failure marker")
            if marker["phase2"] not in combined or marker["purpose"] not in combined:
                fail(f"{rid}: refusal is not the sealed phase-2 purpose")
        after = query_watch(base, env, network, rows[rid])
        if failing is None and before[rid] == after:
            fail("E0 submission had no watched ledger effect")
        if failing is not None and before[rid] != after:
            fail(f"{rid}: refused transaction changed watched ledger state")
        results[rid] = {
            "txid": txids[rid],
            "submit_exit": cp.returncode,
            "submit_sha256": sha_bytes(combined.encode()),
            "view_sha256": sha_bytes(canonical(views[rid])),
            "before_sha256": sha_bytes(canonical(before[rid])),
            "after_sha256": sha_bytes(canonical(after)),
        }
    return {"protocol_sha256": sha_bytes(canonical(protocol_json)), "rows": results}


def mutation_index(seal: dict[str, Any], raw: Path) -> dict[str, dict[str, Any]]:
    rows = seal.get("mutations")
    if not isinstance(rows, list):
        fail("seal.mutations is not an array")
    index: dict[str, dict[str, Any]] = {}
    for n, row in enumerate(rows):
        if not isinstance(row, dict):
            fail(f"mutation {n} is not an object")
        exact_keys(row, {"id", "artifact", "patch"}, f"mutation {n}")
        mid = row["id"]
        if mid in index or mid not in MUTATIONS:
            fail(f"unknown/duplicate mutation {mid!r}")
        if row["artifact"] not in ARTIFACTS:
            fail(f"{mid}: unknown mutated artifact")
        raw_file(raw, row["patch"], f"{mid}.patch")
        index[mid] = row
    if set(index) != set(MUTATIONS):
        fail("mutation inventory differs from fixed parent inventory")
    return index


def rebuild_mutated(
    *,
    mid: str,
    spec: dict[str, Any],
    original: BuiltArtifact,
    patch: Path,
    aiken: str,
    work: Path,
) -> BuiltArtifact:
    dst = work / "mutations" / mid
    shutil.copytree(original.source_copy, dst)
    cp = run(["git", "apply", "--unsafe-paths", str(patch)], cwd=dst)
    require_ok(cp, f"{mid}: parent patch application")
    # Build from the patched copy without using build_one's git/source identity
    # preflight; exact source identity and restoration are checked around it.
    project = dst / safe_rel(spec["project_subdir"], f"{mid}.project_subdir")
    build = run([aiken, "build", "-D"], cwd=project, timeout=900)
    require_ok(build, f"{mid}: mutated aiken build")
    current = project / "plutus.json"
    for i, cbor in enumerate(spec["parameters_cbor"]):
        out = project / f"parent-mutated-applied-{i}.json"
        require_ok(
            run(
                [aiken, "blueprint", "apply", "-i", str(current), "-o", str(out), "-m", spec["module"], "-v", spec["validator"], cbor],
                cwd=project,
            ),
            f"{mid}: apply parameter {i}",
        )
        current = out
    bp = load_json(current)
    matches = [v for v in bp.get("validators", []) if v.get("title") == spec["blueprint_title"]]
    if len(matches) != 1:
        fail(f"{mid}: mutated exact title has {len(matches)} matches")
    code_hex = "".join(matches[0].get("compiledCode", "").split())
    try:
        code = bytes.fromhex(code_hex)
    except ValueError:
        fail(f"{mid}: mutated code is not hex")
    digest = sha_bytes(code)
    if digest == original.sha256:
        fail(f"{mid}: source patch did not change compiled bytes")
    code_file = work / "mutations" / f"{mid}.hex"
    code_file.write_text(code_hex)
    return BuiltArtifact(original.artifact_id, code_hex, digest, hashlib.blake2b(b"\x03" + code, digest_size=28).hexdigest(), code_file, dst)


def run_mutations(
    *,
    aiken: str,
    artifacts: dict[str, BuiltArtifact],
    artifact_specs: dict[str, dict[str, Any]],
    vectors: dict[str, dict[str, list[Path]]],
    mutations: dict[str, dict[str, Any]],
    raw: Path,
    work: Path,
) -> dict[str, Any]:
    results: dict[str, Any] = {}
    for mid, (rid, expected_halt) in MUTATIONS.items():
        row = mutations[mid]
        aid = row["artifact"]
        patch = raw_file(raw, row["patch"], f"{mid}.patch")
        changed = rebuild_mutated(
            mid=mid,
            spec=artifact_specs[aid],
            original=artifacts[aid],
            patch=patch,
            aiken=aiken,
            work=work,
        )
        halted, output = cek_eval(aiken, changed, vectors[rid][aid])
        if halted != expected_halt:
            fail(f"{mid}: positive control did not fire on {rid}/{aid}")
        # Re-execute the unmodified bytes after each mutant.  This proves the
        # source patch never leaked into the accepted artifact set.
        restored_halt, _ = cek_eval(aiken, artifacts[aid], vectors[rid][aid])
        original_expected = aid != CEK_ROWS[rid]
        if restored_halt != original_expected:
            fail(f"{mid}: original artifact behavior was not restored")
        if artifacts[aid].code_file.read_text() != artifacts[aid].code_hex:
            fail(f"{mid}: original compiled file changed")
        results[mid] = {
            "artifact": aid,
            "row": rid,
            "mutated_compiled_sha256": changed.sha256,
            "mutated_halted": halted,
            "output_sha256": sha_bytes(output.encode()),
            "original_restored": True,
        }

    # The inventory-removal control is parent-generated: removing one declared
    # path from an otherwise exact closed inventory must be rejected.
    declared = sorted(p.relative_to(raw).as_posix() for p in raw.rglob("*") if p.is_file())
    first = declared[0]
    mutant = [p for p in declared if p != first]
    if set(mutant) == set(declared):
        fail("inventory removal positive control did not change the inventory")
    if inventory_closed(mutant, declared):
        fail("inventory removal checker false-green")
    results["inventory-remove-one"] = {"removed": first, "rejected": True}
    return results


def inventory_closed(declared: list[str], actual: list[str]) -> bool:
    return len(declared) == len(set(declared)) and set(declared) == set(actual)


def validate_closed_inventory(prepared: Path, raw: Path) -> dict[str, Any]:
    inv = load_json(prepared / "inventory.json")
    exact_keys(inv, {"schema", "files"}, "inventory.json")
    if inv["schema"] != INVENTORY_SCHEMA or not isinstance(inv["files"], list) or not inv["files"]:
        fail("invalid closed inventory schema")
    declared: dict[str, dict[str, Any]] = {}
    for n, row in enumerate(inv["files"]):
        exact_keys(row, {"path", "sha256", "bytes"}, f"inventory row {n}")
        rel = safe_rel(row["path"], f"inventory row {n}.path").as_posix()
        if rel in declared:
            fail(f"duplicate inventory path {rel}")
        declared[rel] = row
    actual = {
        p.relative_to(raw).as_posix(): p
        for p in raw.rglob("*")
        if p.is_file() and not p.is_symlink()
    }
    if not inventory_closed(list(declared), list(actual)):
        fail("raw artifact inventory is not closed")
    for rel, path in actual.items():
        row = declared[rel]
        if sha_file(path) != hex64(row["sha256"], f"inventory {rel}.sha256"):
            fail(f"inventory digest mismatch: {rel}")
        if path.stat().st_size != row["bytes"]:
            fail(f"inventory byte count mismatch: {rel}")
    return inv


def validate_seal(seal: dict[str, Any], candidate: str) -> None:
    required = {
        "schema",
        "candidate_commit",
        "historical_base",
        "integration_base",
        "consumer_source_commit",
        "plutus_version",
        "protocol_major",
        "builtin_semantics_variant",
        "parent_verifier",
        "tools",
        "artifacts",
        "cek_bindings",
        "logic_error_markers",
        "ledger_file_bindings",
        "ledger_failure_markers",
        "ledger_semantics",
        "mutations",
    }
    exact_keys(seal, required, "parent seal")
    if seal["schema"] != SCHEMA or seal["candidate_commit"] != candidate:
        fail("seal schema/candidate mismatch")
    if seal["plutus_version"] != "v3" or seal["protocol_major"] != 10:
        fail("seal does not bind Plutus V3 / protocol major 10")
    if seal["builtin_semantics_variant"] != "defaultFunSemanticsVariantC":
        fail("seal does not bind semantics Variant C")
    exact_keys(seal["parent_verifier"], {"path", "sha256"}, "seal.parent_verifier")
    safe_rel(seal["parent_verifier"]["path"], "seal.parent_verifier.path")
    hex64(seal["parent_verifier"]["sha256"], "seal.parent_verifier.sha256")
    tools = seal["tools"]
    exact_keys(
        tools,
        {"python", "python_version", "aiken", "aiken_version", "cardano_cli", "cardano_cli_version"},
        "seal.tools",
    )
    verifier = seal["parent_verifier"]
    if not isinstance(verifier, dict):
        fail("seal.parent_verifier is not an object")
    exact_keys(verifier, {"path", "sha256"}, "seal.parent_verifier")
    safe_rel(verifier["path"], "seal.parent_verifier.path")
    hex64(verifier["sha256"], "seal.parent_verifier.sha256")


def validate_ref_shape(ref: Any, where: str) -> None:
    if not isinstance(ref, dict):
        fail(f"{where} is not an object")
    exact_keys(ref, {"path", "sha256"}, where)
    safe_rel(ref["path"], f"{where}.path")
    hex64(ref["sha256"], f"{where}.sha256")


def validate_seal_structure(seal: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """Validate the complete authority packet without touching candidate code."""
    tools = seal["tools"]
    for key in ("python", "python_version", "aiken", "aiken_version", "cardano_cli", "cardano_cli_version"):
        if not isinstance(tools[key], str) or not tools[key]:
            fail(f"seal.tools.{key} is empty/non-string")
    tool_version(tools["python"], tools["python_version"], "--version", "python")
    tool_version(tools["aiken"], tools["aiken_version"], "--version", "aiken")
    tool_version(tools["cardano_cli"], tools["cardano_cli_version"], "--version", "cardano-cli")

    artifacts = artifact_index(seal)
    for aid, spec in artifacts.items():
        for key in ("source_commit", "source_tree_sha256", "compiled_sha256"):
            hex64(spec[key], f"{aid}.{key}")
        if not isinstance(spec["script_hash"], str) or len(spec["script_hash"]) != 56:
            fail(f"{aid}.script_hash is not a V3 script hash")
        try:
            bytes.fromhex(spec["script_hash"])
        except ValueError:
            fail(f"{aid}.script_hash is not hex")
        for key in ("project_subdir", "blueprint_title", "module", "validator"):
            if not isinstance(spec[key], str) or not spec[key]:
                fail(f"{aid}.{key} is empty/non-string")
        safe_rel(spec["project_subdir"], f"{aid}.project_subdir")
        if not isinstance(spec["cek_argument_count"], int) or spec["cek_argument_count"] <= 0:
            fail(f"{aid}.cek_argument_count is not a positive integer")
        source = Path(spec["source_repo"])
        if not source.is_absolute() or not source.is_dir():
            fail(f"{aid}.source_repo is not an existing absolute directory")
        if git(source, "rev-parse", "HEAD") != spec["source_commit"]:
            fail(f"{aid}: sealed source commit is not checked out")
        if git(source, "status", "--porcelain"):
            fail(f"{aid}: sealed source tree is dirty")
        if tracked_tree_digest(source) != spec["source_tree_sha256"]:
            fail(f"{aid}: sealed tracked-source digest differs")
        params = spec["parameters_cbor"]
        if not isinstance(params, list):
            fail(f"{aid}.parameters_cbor is not an array")
        for n, value in enumerate(params):
            if not isinstance(value, str):
                fail(f"{aid}.parameters_cbor[{n}] is not a string")
            try:
                bytes.fromhex(value)
            except ValueError:
                fail(f"{aid}.parameters_cbor[{n}] is not hex CBOR")

    bindings = seal["cek_bindings"]
    if not isinstance(bindings, dict) or set(bindings) != set(CEK_ROWS):
        fail("seal.cek_bindings differs from fixed CEK rows")
    for rid, by_artifact in bindings.items():
        if not isinstance(by_artifact, dict) or set(by_artifact) != set(ARTIFACTS):
            fail(f"{rid}: sealed argument artifact inventory differs")
        for aid, refs in by_artifact.items():
            if not isinstance(refs, list):
                fail(f"{rid}/{aid}: sealed arguments are not an array")
            for n, ref in enumerate(refs):
                validate_ref_shape(ref, f"{rid}/{aid}/argument[{n}]")
            if len(refs) != artifacts[aid]["cek_argument_count"]:
                fail(f"{rid}/{aid}: sealed argument count differs from artifact arity")

    markers = seal["logic_error_markers"]
    if not isinstance(markers, dict) or set(markers) != {rid for rid, aid in CEK_ROWS.items() if aid}:
        fail("seal.logic_error_markers differs from fixed negative rows")
    if not all(isinstance(x, str) and x for x in markers.values()):
        fail("a sealed logic-error marker is empty/non-string")

    ledger_bindings = seal["ledger_file_bindings"]
    if not isinstance(ledger_bindings, dict) or set(ledger_bindings) != set(LEDGER_ROWS):
        fail("seal.ledger_file_bindings differs from fixed ledger rows")
    for rid, ref in ledger_bindings.items():
        validate_ref_shape(ref, f"{rid}.signed_tx")

    failure_markers = seal["ledger_failure_markers"]
    if not isinstance(failure_markers, dict) or set(failure_markers) != {
        "E1-missing-inception-ledger",
        "E4-wrong-allocation-ledger",
    }:
        fail("seal.ledger_failure_markers differs from fixed negative ledger rows")
    for rid, marker in failure_markers.items():
        if not isinstance(marker, dict):
            fail(f"{rid}: failure marker is not an object")
        exact_keys(marker, {"phase2", "purpose"}, f"{rid}: failure marker")
        if not all(isinstance(x, str) and x for x in marker.values()):
            fail(f"{rid}: empty/non-string ledger failure marker")

    semantics = seal["ledger_semantics"]
    if not isinstance(semantics, dict):
        fail("seal.ledger_semantics is not an object")
    exact_keys(semantics, {"exact", "relations"}, "seal.ledger_semantics")
    if not isinstance(semantics["exact"], dict) or set(semantics["exact"]) != set(LEDGER_ROWS):
        fail("sealed exact ledger semantics differ from fixed rows")
    for rid, assertions in semantics["exact"].items():
        if not isinstance(assertions, list) or not assertions:
            fail(f"{rid}: sealed exact assertions are empty/non-array")
        for n, assertion in enumerate(assertions):
            if not isinstance(assertion, dict):
                fail(f"{rid}: assertion {n} is not an object")
            exact_keys(assertion, {"pointer", "value"}, f"{rid}: assertion {n}")
            if not isinstance(assertion["pointer"], str) or not assertion["pointer"].startswith("/"):
                fail(f"{rid}: assertion {n} has invalid JSON pointer")
    if not isinstance(semantics["relations"], dict) or set(semantics["relations"]) != {
        "E1-identical-except-lifecycle-withdrawal",
        "E4-correct-total-wrong-checkpoint-destination",
    }:
        fail("sealed ledger relations differ from fixed relations")

    mutations = seal["mutations"]
    if not isinstance(mutations, list):
        fail("seal.mutations is not an array")
    seen: set[str] = set()
    for n, row in enumerate(mutations):
        if not isinstance(row, dict):
            fail(f"mutation {n} is not an object")
        exact_keys(row, {"id", "artifact", "patch"}, f"mutation {n}")
        if row["id"] in seen or row["id"] not in MUTATIONS:
            fail(f"unknown/duplicate mutation {row['id']!r}")
        if row["artifact"] not in ARTIFACTS:
            fail(f"{row['id']}: unknown artifact")
        validate_ref_shape(row["patch"], f"{row['id']}.patch")
        seen.add(row["id"])
    if seen != set(MUTATIONS):
        fail("sealed mutation inventory differs from fixed controls")
    return artifacts


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--seal", required=True)
    ap.add_argument("--prepared")
    ap.add_argument("--receipt")
    ap.add_argument("--preflight-only", action="store_true")
    args = ap.parse_args()

    repo = Path(args.repo).resolve()
    seal_path = Path(args.seal).resolve()
    seal = load_json(seal_path)
    validate_seal(seal, args.candidate)
    if git(repo, "rev-parse", "HEAD") != args.candidate or git(repo, "status", "--porcelain"):
        fail("candidate commit/tree changed after admission")
    artifact_specs = validate_seal_structure(seal)
    if args.preflight_only:
        if args.prepared or args.receipt:
            fail("--preflight-only forbids --prepared/--receipt")
        print(f"parent-verifier-v1: SEALED-PREFLIGHT candidate={args.candidate}")
        return 0
    if not args.prepared or not args.receipt:
        fail("full verification requires --prepared and --receipt")
    prepared_dir = Path(args.prepared).resolve()
    receipt = Path(args.receipt).resolve()
    if receipt.exists():
        fail("parent receipt path must not already exist")

    pmeta = load_json(prepared_dir / "prepared.json")
    exact_keys(pmeta, {"schema", "node_socket", "network_magic", "node_log"}, "prepared.json")
    if pmeta["schema"] != PREPARED_SCHEMA:
        fail("invalid prepared schema")
    raw = prepared_dir / "raw"
    if not raw.is_dir() or raw.is_symlink() or any(p.is_symlink() for p in raw.rglob("*")):
        fail("raw evidence tree is missing or contains symlinks")
    inventory = validate_closed_inventory(prepared_dir, raw)
    raw_file(raw, pmeta["node_log"], "prepared.node_log")
    socket_path = Path(pmeta["node_socket"]).resolve()
    try:
        socket_path.relative_to(prepared_dir)
    except ValueError:
        fail("prepared node_socket is outside the evidence directory")
    vectors_json = load_json(prepared_dir / "cek-vectors.json")
    ledger_json = load_json(prepared_dir / "ledger-plan.json")
    vectors = validate_vector_bindings(vectors_json, seal, raw)
    ledger_rows = validate_ledger_plan(ledger_json, seal, raw)
    mutations = mutation_index(seal, raw)

    tools = seal["tools"]
    tool_version(tools["aiken"], tools["aiken_version"], "--version", "aiken")
    tool_version(tools["cardano_cli"], tools["cardano_cli_version"], "--version", "cardano-cli")
    with tempfile.TemporaryDirectory(prefix="e18-parent-registration-verifier-") as td:
        work = Path(td)
        built = {
            aid: build_one(
                aid,
                artifact_specs[aid],
                aiken=tools["aiken"],
                cardano_cli=tools["cardano_cli"],
                work=work,
            )
            for aid in ARTIFACTS
        }
        cek = check_cek_rows(aiken=tools["aiken"], artifacts=built, vectors=vectors, seal=seal)
        ledger = run_ledger_rows(
            cardano_cli=tools["cardano_cli"],
            prepared=pmeta,
            rows=ledger_rows,
            seal=seal,
        )
        controls = run_mutations(
            aiken=tools["aiken"],
            artifacts=built,
            artifact_specs=artifact_specs,
            vectors=vectors,
            mutations=mutations,
            raw=raw,
            work=work,
        )
        receipt_data = {
            "schema": RECEIPT_SCHEMA,
            "candidate_commit": args.candidate,
            "seal_sha256": sha_file(seal_path),
            "prepared_inventory_sha256": sha_bytes(canonical(inventory)),
            "artifacts": {
                aid: {"compiled_sha256": row.sha256, "script_hash": row.script_hash}
                for aid, row in built.items()
            },
            "cek_rows": cek,
            "ledger": ledger,
            "mutations": controls,
            "real_positive_executed": True,
            "real_positive_accepted": True,
            "all_fixed_rows_satisfied": True,
            "all_parent_mutation_controls_fired": set(controls) == set(ALL_CONTROLS),
            "artifacts_rebuilt_and_measured": True,
            "ledger_submitted_and_queried": True,
        }
        if not receipt_data["all_parent_mutation_controls_fired"]:
            fail("parent mutation control inventory incomplete")
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps(receipt_data, indent=2, sort_keys=True) + "\n")
    print(f"parent-verifier-v1: GREEN candidate={args.candidate} receipt={receipt}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except GateError as exc:
        print(f"parent-verifier-v1: RED: {exc}", file=sys.stderr)
        raise SystemExit(1)
