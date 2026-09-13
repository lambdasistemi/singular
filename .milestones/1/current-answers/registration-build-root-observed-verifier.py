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
import re
import shutil
import subprocess
import sys
import time
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
    "registry-adapter",
    "checkpoint-policy",
    "lifecycle-observer",
    "hash-proof-policy",
)

ALL_ARTIFACTS = frozenset(ARTIFACTS)
GENERIC_ARTIFACTS = frozenset(
    {
        "producer-state",
        "producer-request",
        "registry-adapter",
    }
)

# This is the operation-derived registration closure, not a projection of all
# programs shipped by the producer.  Consumer identities are pinned to the
# actual 14a64a source; naming application/representative programs are not
# registration purposes.  The adapter title/path is the implementation
# contract for the candidate-owned bounded compositor.
ARTIFACT_CONTRACT = {
    "producer-state": {
        "authority": "candidate",
        "project_subdir": "onchain",
        "source_file": "onchain/validators/state.ak",
        "blueprint_title": "state.state.spend",
        "module": "state",
        "validator": "state",
    },
    "producer-request": {
        "authority": "candidate",
        "project_subdir": "onchain",
        "source_file": "onchain/validators/request.ak",
        "blueprint_title": "request.request.spend",
        "module": "request",
        "validator": "request",
    },
    "registry-adapter": {
        "authority": "candidate",
        "project_subdir": "conformance/consumer-adapter/onchain",
        "source_file": "conformance/consumer-adapter/onchain/validators/consumer_adapter.ak",
        "blueprint_title": "consumer_adapter.consumer_adapter.withdraw",
        "module": "consumer_adapter",
        "validator": "consumer_adapter",
    },
    "checkpoint-policy": {
        "authority": "consumer",
        "project_subdir": "onchain",
        "source_file": "onchain/validators/checkpoint_register.ak",
        "blueprint_title": "checkpoint_register.checkpoint_register.mint",
        "module": "checkpoint_register",
        "validator": "checkpoint_register",
    },
    "lifecycle-observer": {
        "authority": "consumer",
        "project_subdir": "onchain",
        "source_file": "onchain/validators/checkpoint_observer.ak",
        "blueprint_title": "checkpoint_observer.observer_lifecycle.withdraw",
        "module": "checkpoint_observer",
        "validator": "observer_lifecycle",
    },
    "hash-proof-policy": {
        "authority": "consumer",
        "project_subdir": "onchain",
        "source_file": "onchain/validators/hash_proof.ak",
        "blueprint_title": "hash_proof.hash_proof.mint",
        "module": "hash_proof",
        "validator": "hash_proof",
    },
}

# consumer parameter <- provider applied script hash.  PolicyId is Aiken Data
# ByteArray, whose canonical CBOR for 28 bytes is 0x581c || hash.
ARTIFACT_RELATIONS = {
    "lifecycle-hash-proof-policy": ("lifecycle-observer", 1, "hash-proof-policy"),
    "checkpoint-lifecycle-observer": ("checkpoint-policy", 1, "lifecycle-observer"),
}

# Each row fixes the programs actually invoked by the operation and the full
# set of legitimate enforcing failures.  An absent withdrawal is not executed:
# omission is rejected by checkpoint-policy.ran_register_check, while the
# separate invoked-invalid row reaches lifecycle-observer.validate_registration.
CEK_ROWS: dict[str, tuple[frozenset[str], frozenset[str]]] = {
    "E0-register-valid-cek": (ALL_ARTIFACTS, frozenset()),
    "E1-omitted-inception-withdrawal-cek": (
        ALL_ARTIFACTS - {"lifecycle-observer"},
        frozenset({"checkpoint-policy"}),
    ),
    "E1-invalid-inception-evidence-cek": (
        ALL_ARTIFACTS,
        frozenset({"lifecycle-observer"}),
    ),
    "E4-wrong-allocation-cek": (
        ALL_ARTIFACTS,
        frozenset({"registry-adapter", "checkpoint-policy"}),
    ),
    "register-omitted-adapter": (
        ALL_ARTIFACTS - {"registry-adapter"},
        frozenset({"producer-state"}),
    ),
    "register-swapped-adapter": (
        ALL_ARTIFACTS - {"registry-adapter"},
        frozenset({"producer-state"}),
    ),
    "register-altered-pin": (ALL_ARTIFACTS, frozenset({"producer-state"})),
    "register-extra-checkpoint-mint": (
        ALL_ARTIFACTS,
        frozenset({"registry-adapter", "checkpoint-policy"}),
    ),
    "register-wrong-aid-name": (
        ALL_ARTIFACTS,
        frozenset({"registry-adapter", "checkpoint-policy", "lifecycle-observer"}),
    ),
    "register-delete": (
        frozenset({"producer-state", "producer-request", "registry-adapter"}),
        frozenset({"registry-adapter"}),
    ),
    "register-end": (
        frozenset({"producer-state", "producer-request", "registry-adapter"}),
        frozenset({"registry-adapter"}),
    ),
    "register-surplus-action": (
        GENERIC_ARTIFACTS,
        frozenset({"producer-state", "registry-adapter"}),
    ),
}

LEDGER_ROWS: dict[str, frozenset[str]] = {
    "E0-register-valid-ledger": frozenset(),
    "E1-omitted-inception-withdrawal-ledger": frozenset({"checkpoint-policy"}),
    "E1-invalid-inception-evidence-ledger": frozenset({"lifecycle-observer"}),
    "E4-wrong-allocation-ledger": frozenset({"registry-adapter", "checkpoint-policy"}),
}

ARTIFACT_PURPOSE_KIND = {
    "producer-state": "SpendingScript",
    "producer-request": "SpendingScript",
    "registry-adapter": "RewardingScript",
    "checkpoint-policy": "MintingScript",
    "lifecycle-observer": "RewardingScript",
    "hash-proof-policy": "MintingScript",
}

# id -> (actual enforcing artifact, exact row, required mutated observation).
MUTATIONS: dict[str, tuple[str, str, bool]] = {
    "always-refuse": ("registry-adapter", "E0-register-valid-cek", False),
    "always-accept": ("registry-adapter", "E4-wrong-allocation-cek", True),
    "remove-inception-observer-check": (
        "lifecycle-observer",
        "E1-invalid-inception-evidence-cek",
        True,
    ),
    "remove-allocation-check": ("registry-adapter", "E4-wrong-allocation-cek", True),
    "remove-unaccounted-checkpoint-check": (
        "registry-adapter",
        "register-extra-checkpoint-mint",
        True,
    ),
    "remove-mandatory-adapter-invocation": (
        "producer-state",
        "register-omitted-adapter",
        True,
    ),
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

# `aiken uplc eval` does not expose a semantics-variant flag.  These two
# programs make the active evaluator semantics observable before any candidate
# vector is credited: Variant C accepts byte 255 and rejects 256, whereas the
# earlier consByteString semantics reduce 256 modulo 256 and return #00.
VARIANT_C_VALID_CANARY = (
    "(program 1.1.0 [(builtin consByteString) (con integer 255) "
    "(con bytestring #)])\n"
)
VARIANT_C_REJECT_CANARY = (
    "(program 1.1.0 [(builtin consByteString) (con integer 256) "
    "(con bytestring #)])\n"
)
VARIANT_C_REJECT_MARKER = "attempt to consByteString something than isn't a byte between [0-255]"


class GateError(RuntimeError):
    pass


COMMAND_EVIDENCE: Path | None = None
COMMAND_SEQUENCE = 0


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


def exact_keys(value: Any, keys: set[str], where: str) -> None:
    if not isinstance(value, dict):
        fail(f"{where} is not an object")
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


def hex40(value: Any, where: str) -> str:
    if not isinstance(value, str) or len(value) != 40:
        fail(f"{where} is not a 40-hex commit")
    try:
        bytes.fromhex(value)
    except ValueError:
        fail(f"{where} is not hex")
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
    global COMMAND_SEQUENCE
    COMMAND_SEQUENCE += 1
    command_id = COMMAND_SEQUENCE
    try:
        cp = subprocess.run(
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
        if COMMAND_EVIDENCE is not None:
            stem = COMMAND_EVIDENCE / f"{command_id:04d}"
            stem.with_suffix(".json").write_text(
                json.dumps(
                    {
                        "argv": argv,
                        "cwd": str(cwd) if cwd else None,
                        "timeout_seconds": timeout,
                        "environment": {
                            "CARDANO_NODE_SOCKET_PATH": env.get("CARDANO_NODE_SOCKET_PATH")
                            if env is not None else None
                        },
                        "exception": repr(exc),
                    },
                    indent=2,
                    sort_keys=True,
                )
                + "\n"
            )
        fail(f"command could not execute: {argv!r}: {exc}")
    if COMMAND_EVIDENCE is not None:
        stem = COMMAND_EVIDENCE / f"{command_id:04d}"
        stem.with_suffix(".stdout").write_text(cp.stdout)
        stem.with_suffix(".stderr").write_text(cp.stderr)
        stem.with_suffix(".json").write_text(
            json.dumps(
                {
                    "argv": argv,
                    "cwd": str(cwd) if cwd else None,
                    "timeout_seconds": timeout,
                    "environment": {
                        "CARDANO_NODE_SOCKET_PATH": env.get("CARDANO_NODE_SOCKET_PATH")
                        if env is not None else None
                    },
                    "exit": cp.returncode,
                    "stdout": stem.with_suffix(".stdout").name,
                    "stderr": stem.with_suffix(".stderr").name,
                },
                indent=2,
                sort_keys=True,
            )
            + "\n"
        )
    return cp


def require_ok(cp: subprocess.CompletedProcess[str], what: str) -> str:
    if cp.returncode != 0:
        fail(f"{what} exit={cp.returncode}: {(cp.stdout + cp.stderr)[-2400:]}")
    return cp.stdout


def git(repo: Path, *args: str) -> str:
    return require_ok(run(["git", "-C", str(repo), *args]), f"git {' '.join(args)}").strip()


def tracked_tree_digest(repo: Path) -> str:
    entries = git(repo, "ls-files", "--stage", "-z").split("\0")
    rows: list[dict[str, Any]] = []
    for entry in entries:
        if not entry:
            continue
        meta, name = entry.split("\t", 1)
        mode, blob, stage = meta.split(" ")
        safe_rel(name, "tracked source path")
        if stage != "0" or not re.fullmatch(r"[0-9a-f]{40,64}", blob):
            fail(f"tracked source index entry is unmerged/invalid: {name}")
        rows.append({"path": name, "mode": mode, "blob": blob})
    return sha_bytes(canonical(rows))


def copy_tracked(repo: Path, dst: Path, project_subdir: Path) -> None:
    # Copy exactly the tracked tree in-process.  The git enumeration itself is
    # retained by run(); avoiding an unrecorded archive|tar pipeline also keeps
    # the true exit and every copied input reviewable on failure.
    names = git(repo, "ls-files", "-z").split("\0")
    for name in names:
        if not name:
            continue
        rel = safe_rel(name, "tracked source path")
        try:
            rel.relative_to(project_subdir)
        except ValueError:
            continue
        source = repo / rel
        target = dst / rel
        if not source.is_file() or source.is_symlink():
            fail(f"tracked source is not a regular nonsymlink file: {rel}")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)


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


def verify_variant_c(aiken: str, work: Path) -> dict[str, Any]:
    """Execute a positive/negative discriminator for the actual CEK semantics."""
    canary_dir = work / "semantics-canary"
    canary_dir.mkdir(parents=True)
    valid_path = canary_dir / "cons-byte-string-255.uplc"
    reject_path = canary_dir / "cons-byte-string-256.uplc"
    valid_path.write_text(VARIANT_C_VALID_CANARY)
    reject_path.write_text(VARIANT_C_REJECT_CANARY)

    valid = run([aiken, "uplc", "eval", str(valid_path)], timeout=60)
    if valid.returncode != 0:
        fail("Variant-C positive canary rejected byte 255")
    try:
        valid_json = json.loads(valid.stdout)
    except json.JSONDecodeError:
        fail("Variant-C positive canary output is not JSON")
    if not isinstance(valid_json, dict) or valid_json.get("result") != "(con bytestring #ff)":
        fail("Variant-C positive canary returned the wrong byte")

    reject = run([aiken, "uplc", "eval", str(reject_path)], timeout=60)
    reject_output = (reject.stdout + "\n" + reject.stderr).strip()
    if reject.returncode == 0:
        fail("semantics false-green: byte 256 was accepted (not Variant C)")
    if VARIANT_C_REJECT_MARKER not in reject_output:
        fail("Variant-C negative canary failed for an unrecognized/setup reason")

    return {
        "variant": "defaultFunSemanticsVariantC",
        "valid_255_exit": valid.returncode,
        "valid_255_output_sha256": sha_bytes((valid.stdout + "\n" + valid.stderr).encode()),
        "reject_256_exit": reject.returncode,
        "reject_256_output_sha256": sha_bytes(reject_output.encode()),
        "discriminator_fired": True,
    }


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
            "source_file",
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
        fixed = ARTIFACT_CONTRACT[aid]
        for key in ("project_subdir", "source_file", "blueprint_title", "module", "validator"):
            if row.get(key) != fixed[key]:
                fail(f"{aid}: {key} differs from the fixed operation-derived program")
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
    if not isinstance(spec["source_repo"], str):
        fail(f"{aid}: source_repo must be an absolute path string")
    source = Path(spec["source_repo"])
    if not source.is_absolute() or not source.is_dir():
        fail(f"{aid}: source_repo must be an existing absolute directory")
    if git(source, "rev-parse", "HEAD") != spec["source_commit"]:
        fail(f"{aid}: source commit drift")
    if git(source, "status", "--porcelain"):
        fail(f"{aid}: source tree is dirty")
    if tracked_tree_digest(source) != hex64(spec["source_tree_sha256"], f"{aid}.source_tree_sha256"):
        fail(f"{aid}: tracked source-tree digest drift")
    source_file = source / safe_rel(spec["source_file"], f"{aid}.source_file")
    if not source_file.is_file() or source_file.is_symlink():
        fail(f"{aid}: fixed source file is missing or a symlink")

    copy = work / "sources" / aid
    copy.mkdir(parents=True)
    project_subdir = safe_rel(spec["project_subdir"], f"{aid}.project_subdir")
    copy_tracked(source, copy, project_subdir)
    project = copy / project_subdir
    if not (project / "aiken.toml").is_file():
        fail(f"{aid}: sealed project_subdir has no aiken.toml")
    build = run([aiken, "build"], cwd=project, timeout=900)
    require_ok(build, f"{aid}: aiken build")
    blueprint = project / "plutus.json"
    bp = load_json(blueprint)
    if not isinstance(bp, dict) or not isinstance(bp.get("validators"), list):
        fail(f"{aid}: compiler blueprint lacks a validators array")
    if not all(isinstance(v, dict) for v in bp["validators"]):
        fail(f"{aid}: compiler blueprint contains a non-object validator")
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
    if not isinstance(applied, dict) or not isinstance(applied.get("validators"), list):
        fail(f"{aid}: applied blueprint lacks a validators array")
    if not all(isinstance(v, dict) for v in applied["validators"]):
        fail(f"{aid}: applied blueprint contains a non-object validator")
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
        applicable, _ = CEK_ROWS[rid]
        if not isinstance(supplied[rid], dict) or set(supplied[rid]) != set(applicable):
            fail(f"{rid}: argument artifact inventory differs")
        if not isinstance(binding[rid], dict) or set(binding[rid]) != set(applicable):
            fail(f"{rid}: sealed binding artifact inventory differs")
        result[rid] = {}
        for aid in ARTIFACTS:
            if aid not in applicable:
                continue
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
    negative_rows = {rid for rid, (_, failures) in CEK_ROWS.items() if failures}
    if not isinstance(markers, dict) or set(markers) != negative_rows:
        fail("seal.logic_error_markers differs from fixed negative rows")
    receipt: dict[str, Any] = {}
    for rid, (applicable, failures) in CEK_ROWS.items():
        observations: dict[str, Any] = {}
        for aid in ARTIFACTS:
            if aid not in applicable:
                observations[aid] = {"invoked": False}
                continue
            halted, output = cek_eval(aiken, artifacts[aid], vectors[rid][aid])
            wanted = aid not in failures
            if halted != wanted:
                fail(f"{rid}: {aid} halted={halted}, expected={wanted}")
            if not halted:
                row_markers = markers[rid]
                if not isinstance(row_markers, dict) or set(row_markers) != set(failures):
                    fail(f"{rid}: logic markers differ from legitimate enforcing failures")
                marker = row_markers[aid]
                if not isinstance(marker, str) or not marker or marker not in output:
                    fail(f"{rid}: exact parent-sealed logic-error marker absent")
            observations[aid] = {
                "invoked": True,
                "halted": halted,
                "output_sha256": sha_bytes(output.encode()),
            }
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


LEDGER_SEMANTIC_ROLES = frozenset(
    {
        "operation",
        "authenticated_request_key",
        "authenticated_request_value",
        "state_input",
        "request_input",
        "state_pin_before",
        "state_pin_after",
        "adapter_withdrawal",
        "adapter_redeemer",
        "lifecycle_withdrawal",
        "lifecycle_redeemer",
        "inception_evidence",
        "hash_proof_input",
        "hash_proof_burn",
        "checkpoint_policy",
        "checkpoint_asset_name",
        "checkpoint_mint_quantity",
        "checkpoint_output_address",
        "checkpoint_output_datum",
        "checkpoint_output_value",
        "request_bond",
        "tip_destination",
        "tip_value",
        "complete_inputs",
        "complete_outputs",
        "complete_mint",
        "complete_withdrawals",
        "complete_redeemers",
    }
)

PROOF_SETUP_ROLES = frozenset(
    {
        "proof_policy",
        "proof_asset_name",
        "proof_mint_quantity",
        "proof_output_address",
        "proof_output_value",
        "complete_inputs",
        "complete_outputs",
        "complete_mint",
        "complete_redeemers",
    }
)

LEDGER_PROGRAMS = {
    "E0-register-valid-ledger": ALL_ARTIFACTS,
    "E1-omitted-inception-withdrawal-ledger": ALL_ARTIFACTS - {"lifecycle-observer"},
    "E1-invalid-inception-evidence-ledger": ALL_ARTIFACTS,
    "E4-wrong-allocation-ledger": ALL_ARTIFACTS,
}


def inspect_ledger_semantics(
    documents: dict[str, Any],
    artifacts: dict[str, BuiltArtifact],
    seal: dict[str, Any],
) -> None:
    semantics = seal.get("ledger_semantics")
    if not isinstance(semantics, dict):
        fail("seal.ledger_semantics is not an object")
    exact_keys(semantics, {"rows", "relations"}, "seal.ledger_semantics")
    rows = semantics["rows"]
    if not isinstance(rows, dict) or set(rows) != set(LEDGER_ROWS):
        fail("ledger semantics differ from fixed ledger rows")
    for rid, row in rows.items():
        exact_keys(
            row,
            {
                "fields",
                "witnesses",
                "proof_setup_fields",
                "proof_setup_witness",
                "proof_setup_output_index",
                "proof_input_pointer",
                "created_output_indices",
                "created_output_assertions",
            },
            f"ledger semantics {rid}",
        )
        fields = row["fields"]
        if not isinstance(fields, dict) or set(fields) != set(LEDGER_SEMANTIC_ROLES):
            fail(f"{rid}: semantic fields differ from complete registration field set")
        for role, assertion in fields.items():
            exact_keys(assertion, {"pointer", "value"}, f"{rid}.{role}")
            actual = json_pointer(documents[rid], assertion["pointer"])
            if actual != assertion["value"]:
                fail(f"{rid}: parent semantic role {role} differs at {assertion['pointer']}")

        witnesses = row["witnesses"]
        if not isinstance(witnesses, dict) or set(witnesses) != set(LEDGER_PROGRAMS[rid]):
            fail(f"{rid}: measured witness set differs from invoked program set")
        for aid, assertion in witnesses.items():
            exact_keys(assertion, {"hash_pointer"}, f"{rid}.witnesses.{aid}")
            observed_hash = json_pointer(documents[rid], assertion["hash_pointer"])
            if observed_hash != artifacts[aid].script_hash:
                fail(f"{rid}: {aid} witness is not the parent-rebuilt program")
        proof_fields = row["proof_setup_fields"]
        if not isinstance(proof_fields, dict) or set(proof_fields) != set(PROOF_SETUP_ROLES):
            fail(f"{rid}: proof setup fields differ from the fixed acquisition set")
        for role, assertion in proof_fields.items():
            exact_keys(assertion, {"pointer", "value"}, f"{rid}.proof_setup.{role}")
            actual = json_pointer(documents[rid]["proof_setup"], assertion["pointer"])
            if actual != assertion["value"]:
                fail(f"{rid}: proof setup role {role} differs at {assertion['pointer']}")
        proof_witness = row["proof_setup_witness"]
        exact_keys(proof_witness, {"hash_pointer"}, f"{rid}.proof_setup_witness")
        observed_hash = json_pointer(documents[rid]["proof_setup"], proof_witness["hash_pointer"])
        if observed_hash != artifacts["hash-proof-policy"].script_hash:
            fail(f"{rid}: proof acquisition does not invoke the rebuilt hash-proof policy")
        if not isinstance(row["proof_setup_output_index"], int) or row["proof_setup_output_index"] < 0:
            fail(f"{rid}: proof setup output index is invalid")
        proof_input = json_pointer(documents[rid], row["proof_input_pointer"])
        expected_input = f"{documents[rid]['proof_setup_txid']}#{row['proof_setup_output_index']}"
        if proof_input != expected_input:
            fail(f"{rid}: registration does not consume its authentic proof acquisition output")

    relations = semantics["relations"]
    required_relations = {
        "E1-omission-identical-except-lifecycle-withdrawal",
        "E1-invalid-identical-except-inception-evidence",
        "E4-correct-total-wrong-checkpoint-destination",
    }
    if not isinstance(relations, dict) or set(relations) != required_relations:
        fail("ledger semantic relations differ from fixed relations")

    e1 = relations["E1-omission-identical-except-lifecycle-withdrawal"]
    exact_keys(e1, {"equal_pointers", "e0_lifecycle", "e1_lifecycle"}, "E1 relation")
    for ptr in e1["equal_pointers"]:
        if json_pointer(documents["E0-register-valid-ledger"], ptr) != json_pointer(
            documents["E1-omitted-inception-withdrawal-ledger"], ptr
        ):
            fail(f"E1 is not E0-equivalent at {ptr}")
    if json_pointer(documents["E0-register-valid-ledger"], e1["e0_lifecycle"]) in (None, {}, [], 0):
        fail("E0 lacks the real lifecycle withdrawal")
    try:
        missing = json_pointer(
            documents["E1-omitted-inception-withdrawal-ledger"], e1["e1_lifecycle"]
        )
    except GateError:
        missing = None
    if missing not in (None, {}, [], 0):
        fail("E1 omission row does not omit the lifecycle withdrawal")

    invalid = relations["E1-invalid-identical-except-inception-evidence"]
    exact_keys(
        invalid,
        {"equal_pointers", "e0_evidence", "invalid_evidence", "invalid_lifecycle"},
        "E1 invalid relation",
    )
    for ptr in invalid["equal_pointers"]:
        if json_pointer(documents["E0-register-valid-ledger"], ptr) != json_pointer(
            documents["E1-invalid-inception-evidence-ledger"], ptr
        ):
            fail(f"E1 invalid-evidence row differs from E0 outside evidence at {ptr}")
    if json_pointer(
        documents["E1-invalid-inception-evidence-ledger"], invalid["invalid_lifecycle"]
    ) in (None, {}, [], 0):
        fail("E1 invalid-evidence row does not invoke the real lifecycle observer")
    if json_pointer(documents["E0-register-valid-ledger"], invalid["e0_evidence"]) == json_pointer(
        documents["E1-invalid-inception-evidence-ledger"], invalid["invalid_evidence"]
    ):
        fail("E1 invalid-evidence row did not change inception evidence")

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
        if json_pointer(documents["E0-register-valid-ledger"], ptr) != json_pointer(
            documents["E4-wrong-allocation-ledger"], ptr
        ):
            fail(f"E4 differs from E0 outside exact allocation at {ptr}")
    bond = e4["bond"]
    if not isinstance(bond, int) or bond <= 0:
        fail("sealed registration bond is not a positive integer")
    e0_checkpoint = json_pointer(documents["E0-register-valid-ledger"], e4["e0_checkpoint_quantity"])
    e4_checkpoint = json_pointer(documents["E4-wrong-allocation-ledger"], e4["e4_checkpoint_quantity"])
    e0_refund = json_pointer(documents["E0-register-valid-ledger"], e4["e0_refund_quantity"])
    e4_refund = json_pointer(documents["E4-wrong-allocation-ledger"], e4["e4_refund_quantity"])
    if e0_checkpoint - e4_checkpoint != bond or e4_refund - e0_refund != bond:
        fail("E4 does not move exactly the bond from checkpoint to refund")


def validate_ledger_plan(plan: dict[str, Any], seal: dict[str, Any], raw: Path) -> dict[str, Any]:
    exact_keys(plan, {"schema", "rows"}, "ledger-plan.json")
    if plan["schema"] != LEDGER_SCHEMA or not isinstance(plan["rows"], list):
        fail("invalid ledger plan schema")
    index: dict[str, Any] = {}
    for n, row in enumerate(plan["rows"]):
        if not isinstance(row, dict):
            fail(f"ledger row {n} is not an object")
        exact_keys(
            row,
            {
                "id",
                "proof_setup_tx",
                "signed_tx",
                "setup_watched_txins",
                "setup_watched_addresses",
                "watched_txins",
                "watched_addresses",
            },
            f"ledger row {n}",
        )
        rid = row["id"]
        if rid in index or rid not in LEDGER_ROWS:
            fail(f"unknown/duplicate ledger row {rid!r}")
        tx = raw_file(raw, row["signed_tx"], f"{rid}.signed_tx")
        proof_setup = raw_file(raw, row["proof_setup_tx"], f"{rid}.proof_setup_tx")
        for prefix in ("setup_", ""):
            txins = row[f"{prefix}watched_txins"]
            addresses = row[f"{prefix}watched_addresses"]
            if not isinstance(txins, list) or not txins or not all(
                isinstance(x, str) and re.fullmatch(r"[0-9a-f]{64}#[0-9]+", x) for x in txins
            ):
                fail(f"{rid}: {prefix}watched_txins invalid")
            if len(txins) != len(set(txins)):
                fail(f"{rid}: {prefix}watched_txins contains duplicates")
            if not isinstance(addresses, list) or not addresses or not all(
                isinstance(x, str) and x for x in addresses
            ):
                fail(f"{rid}: {prefix}watched_addresses invalid")
            if len(addresses) != len(set(addresses)):
                fail(f"{rid}: {prefix}watched_addresses contains duplicates")
        index[rid] = {**row, "signed_path": tx, "proof_setup_path": proof_setup}
    if set(index) != set(LEDGER_ROWS):
        fail("ledger row inventory differs from fixed parent inventory")
    bindings = seal.get("ledger_file_bindings")
    if not isinstance(bindings, dict) or set(bindings) != set(LEDGER_ROWS):
        fail("seal ledger file bindings differ from fixed rows")
    for rid, row in index.items():
        if not isinstance(bindings[rid], dict):
            fail(f"{rid}: ledger binding is not an object")
        bound_fields = {
            "proof_setup_tx",
            "signed_tx",
            "setup_watched_txins",
            "setup_watched_addresses",
            "watched_txins",
            "watched_addresses",
        }
        exact_keys(bindings[rid], bound_fields, f"{rid}: ledger binding")
        for field in bound_fields:
            if row[field] != bindings[rid][field]:
                fail(f"{rid}: {field} differs from parent binding")
    owners: dict[str, str] = {}
    for rid, row in index.items():
        for txin in row["setup_watched_txins"] + row["watched_txins"]:
            if txin in owners:
                fail(f"ledger rows are not input-isolated: {txin} is shared by {owners[txin]} and {rid}")
            owners[txin] = rid
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
    artifacts: dict[str, BuiltArtifact],
) -> dict[str, Any]:
    base, env = ledger_args(prepared, cardano_cli)
    network = ["--testnet-magic", str(prepared["network_magic"])]
    protocol = run(base + ["query", "protocol-parameters", *network, "--output-json"], env=env)
    protocol_json = json.loads(require_ok(protocol, "live protocol query"))
    if protocol_json.get("protocolVersion", {}).get("major") != 10:
        fail("live protocol major is not the sealed Variant-C major 10")

    views: dict[str, Any] = {}
    txids: dict[str, str] = {}
    proof_views: dict[str, Any] = {}
    proof_txids: dict[str, str] = {}
    for rid, row in rows.items():
        tx = str(row["signed_path"])
        proof_tx = str(row["proof_setup_path"])
        view = run([cardano_cli, "debug", "transaction", "view", "--tx-file", tx])
        views[rid] = json.loads(require_ok(view, f"{rid}: transaction view"))
        proof_view = run([cardano_cli, "debug", "transaction", "view", "--tx-file", proof_tx])
        proof_views[rid] = json.loads(require_ok(proof_view, f"{rid}: proof setup transaction view"))
        txid = require_ok(
            run(base + ["transaction", "txid", "--tx-file", tx, "--output-text"]),
            f"{rid}: txid",
        ).strip()
        proof_txid = require_ok(
            run(base + ["transaction", "txid", "--tx-file", proof_tx, "--output-text"]),
            f"{rid}: proof setup txid",
        ).strip()
        if not re.fullmatch(r"[0-9a-f]{64}", txid):
            fail(f"{rid}: invalid computed transaction id")
        if not re.fullmatch(r"[0-9a-f]{64}", proof_txid):
            fail(f"{rid}: invalid computed proof setup transaction id")
        txids[rid] = txid
        proof_txids[rid] = proof_txid

    # Semantics are checked before any submission so E1/E4 cannot be certified
    # by unrelated refusal and E0 cannot establish the wrong operation.
    documents = {
        rid: {
            "view": views[rid],
            "proof_setup": proof_views[rid],
            "proof_setup_txid": proof_txids[rid],
        }
        for rid in LEDGER_ROWS
    }
    inspect_ledger_semantics(documents, artifacts, seal)

    failure_re = re.compile(
        r'The script hash is:ScriptHash "([0-9a-f]{56})".*?'
        r'ScriptInfo: (SpendingScript|MintingScript|RewardingScript|CertifyingScript)',
        re.DOTALL,
    )
    results: dict[str, Any] = {}
    # Refusals run first against mutually disjoint inputs.  The sole positive
    # runs last, so its accepted state change cannot become a negative's setup.
    order = [rid for rid, failures in LEDGER_ROWS.items() if failures] + [
        rid for rid, failures in LEDGER_ROWS.items() if not failures
    ]
    semantics_rows = seal["ledger_semantics"]["rows"]
    for rid in order:
        failures = LEDGER_ROWS[rid]
        tx = str(rows[rid]["signed_path"])
        proof_tx = str(rows[rid]["proof_setup_path"])
        setup_watch = {
            "watched_txins": rows[rid]["setup_watched_txins"],
            "watched_addresses": rows[rid]["setup_watched_addresses"],
        }
        setup_before = query_watch(base, env, network, setup_watch)
        for txin, value in setup_before["txins"].items():
            if not value:
                fail(f"{rid}: sealed proof-setup input {txin} was not live before submission")
        setup_cp = run(base + ["transaction", "submit", *network, "--tx-file", proof_tx], env=env)
        setup_combined = setup_cp.stdout + "\n" + setup_cp.stderr
        if setup_cp.returncode != 0:
            fail(
                f"{rid}: authentic hash-proof acquisition failed exit={setup_cp.returncode}: "
                f"{setup_combined[-1200:]}"
            )
        setup_index = semantics_rows[rid]["proof_setup_output_index"]
        proof_txin = f"{proof_txids[rid]}#{setup_index}"
        if proof_txin not in rows[rid]["watched_txins"]:
            fail(f"{rid}: authentic proof output is absent from the parent-bound registration watch set")
        proof_found: dict[str, Any] | None = None
        for _ in range(30):
            setup_query = run(
                base + ["query", "utxo", *network, "--tx-in", proof_txin, "--output-json"],
                env=env,
            )
            proof_found = json.loads(require_ok(setup_query, f"{rid}: query proof output {proof_txin}"))
            if proof_txin in proof_found:
                break
            time.sleep(1)
        if not isinstance(proof_found, dict) or proof_txin not in proof_found:
            fail(f"{rid}: authentic hash-proof output {proof_txin} was not observed")
        setup_after = query_watch(base, env, network, setup_watch)
        for txin, value in setup_after["txins"].items():
            if value:
                fail(f"{rid}: proof acquisition did not consume setup input {txin}")
        before = query_watch(base, env, network, rows[rid])
        for txin, value in before["txins"].items():
            if not value:
                fail(f"{rid}: sealed registration input {txin} was not live before submission")
        cp = run(base + ["transaction", "submit", *network, "--tx-file", tx], env=env)
        combined = cp.stdout + "\n" + cp.stderr
        observed_failures = set(failure_re.findall(combined))
        expected_failures = {
            (artifacts[aid].script_hash, ARTIFACT_PURPOSE_KIND[aid]) for aid in failures
        }
        if not failures:
            if cp.returncode != 0:
                fail(f"{rid}: real positive submission failed exit={cp.returncode}: {combined[-1200:]}")
            if observed_failures:
                fail(f"{rid}: accepted positive nevertheless contains parsed script failures")
        else:
            if cp.returncode == 0:
                fail(f"{rid}: negative transaction was accepted")
            if "ValidationTagMismatch Phase2Valid" not in combined or "CekError" not in combined:
                fail(f"{rid}: refusal is not an actual phase-2 CEK failure")
            if observed_failures != expected_failures:
                fail(
                    f"{rid}: actual failing script/purpose set differs: "
                    f"got={sorted(observed_failures)} want={sorted(expected_failures)}"
                )
        created: dict[str, Any] = {}
        if not failures:
            for index in semantics_rows[rid]["created_output_indices"]:
                created_txin = f"{txids[rid]}#{index}"
                found: dict[str, Any] | None = None
                for _ in range(30):
                    cp_query = run(
                        base + ["query", "utxo", *network, "--tx-in", created_txin, "--output-json"],
                        env=env,
                    )
                    found = json.loads(require_ok(cp_query, f"query created output {created_txin}"))
                    if created_txin in found:
                        break
                    time.sleep(1)
                if not isinstance(found, dict) or created_txin not in found:
                    fail(f"{rid}: accepted txid output {created_txin} was not observed on ledger")
                created[str(index)] = found[created_txin]
            after = query_watch(base, env, network, rows[rid])
            for txin, value in after["txins"].items():
                if value:
                    fail(f"{rid}: accepted transaction did not consume watched input {txin}")
            for assertion in semantics_rows[rid]["created_output_assertions"]:
                index = str(assertion["index"])
                actual = json_pointer(created[index], assertion["pointer"])
                if actual != assertion["value"]:
                    fail(f"{rid}: created output {index} differs at {assertion['pointer']}")
        else:
            after = query_watch(base, env, network, rows[rid])
            if before != after:
                fail(f"{rid}: refused transaction changed watched ledger state")
        results[rid] = {
            "txid": txids[rid],
            "proof_setup_txid": proof_txids[rid],
            "proof_setup_submit_exit": setup_cp.returncode,
            "proof_setup_submit_sha256": sha_bytes(setup_combined.encode()),
            "proof_setup_before_sha256": sha_bytes(canonical(setup_before)),
            "proof_setup_after_sha256": sha_bytes(canonical(setup_after)),
            "proof_output_sha256": sha_bytes(canonical(proof_found[proof_txin])),
            "submit_exit": cp.returncode,
            "submit_sha256": sha_bytes(combined.encode()),
            "failing_script_purposes": sorted(
                (
                    {"script_hash": script_hash, "purpose": purpose}
                    for script_hash, purpose in observed_failures
                ),
                key=lambda row: (row["script_hash"], row["purpose"]),
            ),
            "view_sha256": sha_bytes(canonical(views[rid])),
            "before_sha256": sha_bytes(canonical(before)),
            "after_sha256": sha_bytes(canonical(after)),
            "created_outputs_sha256": sha_bytes(canonical(created)),
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
        fixed_artifact, _, _ = MUTATIONS[mid]
        if row["artifact"] != fixed_artifact:
            fail(f"{mid}: mutated artifact differs from fixed enforcing artifact {fixed_artifact}")
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
    before = {
        path.relative_to(original.source_copy).as_posix(): sha_file(path)
        for path in original.source_copy.rglob("*")
        if path.is_file() and not path.is_symlink()
    }
    cp = run(["git", "apply", str(patch)], cwd=dst)
    require_ok(cp, f"{mid}: parent patch application")
    if any(path.is_symlink() for path in dst.rglob("*")):
        fail(f"{mid}: source patch created a symlink")
    after = {
        path.relative_to(dst).as_posix(): sha_file(path)
        for path in dst.rglob("*")
        if path.is_file() and not path.is_symlink()
    }
    changed = {
        name for name in set(before) | set(after) if before.get(name) != after.get(name)
    }
    expected_source = safe_rel(spec["source_file"], f"{mid}.source_file").as_posix()
    if changed != {expected_source}:
        fail(
            f"{mid}: patch changed paths outside the fixed enforcing source: "
            f"got={sorted(changed)} want={[expected_source]}"
        )
    # Build from the patched copy without using build_one's git/source identity
    # preflight; exact source identity and restoration are checked around it.
    project = dst / safe_rel(spec["project_subdir"], f"{mid}.project_subdir")
    build = run([aiken, "build"], cwd=project, timeout=900)
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
    if not isinstance(bp, dict) or not isinstance(bp.get("validators"), list):
        fail(f"{mid}: mutated blueprint lacks a validators array")
    if not all(isinstance(v, dict) for v in bp["validators"]):
        fail(f"{mid}: mutated blueprint contains a non-object validator")
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
    for mid, (fixed_artifact, rid, expected_halt) in MUTATIONS.items():
        row = mutations[mid]
        aid = row["artifact"]
        if aid != fixed_artifact:
            fail(f"{mid}: mutation was redirected away from {fixed_artifact}")
        applicable, failures = CEK_ROWS[rid]
        if aid not in applicable:
            fail(f"{mid}: fixed artifact is not invoked by {rid}")
        original_expected = aid not in failures
        original_halt, original_output = cek_eval(aiken, artifacts[aid], vectors[rid][aid])
        if original_halt != original_expected:
            fail(f"{mid}: fixed original observation disagrees with row semantics")
        if original_halt == expected_halt:
            fail(f"{mid}: mutation target does not demand the opposite observation")
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
        if restored_halt != original_halt:
            fail(f"{mid}: original artifact behavior was not restored")
        if artifacts[aid].code_file.read_text() != artifacts[aid].code_hex:
            fail(f"{mid}: original compiled file changed")
        results[mid] = {
            "artifact": aid,
            "row": rid,
            "mutated_compiled_sha256": changed.sha256,
            "mutated_halted": halted,
            "original_halted": original_halt,
            "original_output_sha256": sha_bytes(original_output.encode()),
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


def retained_evidence_inventory(root: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            fail(f"retained evidence contains a symlink: {path}")
        if path.is_file():
            rows.append(
                {
                    "path": path.relative_to(root).as_posix(),
                    "bytes": path.stat().st_size,
                    "sha256": sha_file(path),
                }
            )
    return rows


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
        "artifact_relations",
        "cek_bindings",
        "logic_error_markers",
        "ledger_file_bindings",
        "ledger_semantics",
        "mutations",
    }
    exact_keys(seal, required, "parent seal")
    if seal["schema"] != SCHEMA or seal["candidate_commit"] != candidate:
        fail("seal schema/candidate mismatch")
    for key in ("candidate_commit", "historical_base", "integration_base", "consumer_source_commit"):
        hex40(seal[key], f"seal.{key}")
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
    consumer_sources: set[tuple[str, str, str]] = set()
    for aid, spec in artifacts.items():
        hex40(spec["source_commit"], f"{aid}.source_commit")
        for key in ("source_tree_sha256", "compiled_sha256"):
            hex64(spec[key], f"{aid}.{key}")
        if not isinstance(spec["script_hash"], str) or len(spec["script_hash"]) != 56:
            fail(f"{aid}.script_hash is not a V3 script hash")
        try:
            bytes.fromhex(spec["script_hash"])
        except ValueError:
            fail(f"{aid}.script_hash is not hex")
        for key in ("project_subdir", "source_file", "blueprint_title", "module", "validator"):
            if not isinstance(spec[key], str) or not spec[key]:
                fail(f"{aid}.{key} is empty/non-string")
        safe_rel(spec["project_subdir"], f"{aid}.project_subdir")
        safe_rel(spec["source_file"], f"{aid}.source_file")
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
        if not (source / spec["source_file"]).is_file() or (source / spec["source_file"]).is_symlink():
            fail(f"{aid}: fixed source file is missing or a symlink")
        authority = ARTIFACT_CONTRACT[aid]["authority"]
        if authority == "consumer":
            if spec["source_commit"] != seal["consumer_source_commit"]:
                fail(f"{aid}: consumer program is not bound to the declared consumer commit")
            consumer_sources.add(
                (str(source.resolve()), spec["source_commit"], spec["source_tree_sha256"])
            )
        elif authority == "candidate" and spec["source_commit"] != seal["candidate_commit"]:
            fail(f"{aid}: candidate program is not bound to the admitted candidate commit")
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

    if len(consumer_sources) != 1:
        fail("consumer lifecycle/checkpoint/proof programs do not share one bound source tree")

    relations = seal["artifact_relations"]
    if not isinstance(relations, list):
        fail("seal.artifact_relations is not an array")
    seen_relations: set[str] = set()
    for n, relation in enumerate(relations):
        if not isinstance(relation, dict):
            fail(f"artifact relation {n} is not an object")
        exact_keys(
            relation,
            {"id", "consumer", "parameter_index", "provider", "encoding"},
            f"artifact relation {n}",
        )
        relation_id = relation["id"]
        if relation_id in seen_relations or relation_id not in ARTIFACT_RELATIONS:
            fail(f"unknown/duplicate artifact relation {relation_id!r}")
        consumer, parameter_index, provider = ARTIFACT_RELATIONS[relation_id]
        if (
            relation["consumer"] != consumer
            or relation["parameter_index"] != parameter_index
            or relation["provider"] != provider
            or relation["encoding"] != "aiken-data-bytes-cbor"
        ):
            fail(f"{relation_id}: relation differs from fixed dependency binding")
        params = artifacts[consumer]["parameters_cbor"]
        if parameter_index >= len(params):
            fail(f"{relation_id}: consumer parameter index is absent")
        expected = "581c" + artifacts[provider]["script_hash"]
        if params[parameter_index].lower() != expected:
            fail(f"{relation_id}: applied parameter does not encode provider script hash")
        seen_relations.add(relation_id)
    if seen_relations != set(ARTIFACT_RELATIONS):
        fail("sealed artifact dependency relation inventory is incomplete")

    bindings = seal["cek_bindings"]
    if not isinstance(bindings, dict) or set(bindings) != set(CEK_ROWS):
        fail("seal.cek_bindings differs from fixed CEK rows")
    for rid, by_artifact in bindings.items():
        applicable, _ = CEK_ROWS[rid]
        if not isinstance(by_artifact, dict) or set(by_artifact) != set(applicable):
            fail(f"{rid}: sealed argument artifact inventory differs")
        for aid, refs in by_artifact.items():
            if not isinstance(refs, list):
                fail(f"{rid}/{aid}: sealed arguments are not an array")
            for n, ref in enumerate(refs):
                validate_ref_shape(ref, f"{rid}/{aid}/argument[{n}]")
            if len(refs) != artifacts[aid]["cek_argument_count"]:
                fail(f"{rid}/{aid}: sealed argument count differs from artifact arity")

    markers = seal["logic_error_markers"]
    negative_rows = {rid for rid, (_, failures) in CEK_ROWS.items() if failures}
    if not isinstance(markers, dict) or set(markers) != negative_rows:
        fail("seal.logic_error_markers differs from fixed negative rows")
    for rid, row_markers in markers.items():
        failures = CEK_ROWS[rid][1]
        if not isinstance(row_markers, dict) or set(row_markers) != set(failures):
            fail(f"{rid}: sealed logic markers differ from enforcing artifacts")
        if not all(isinstance(x, str) and x for x in row_markers.values()):
            fail(f"{rid}: a sealed logic-error marker is empty/non-string")

    ledger_bindings = seal["ledger_file_bindings"]
    if not isinstance(ledger_bindings, dict) or set(ledger_bindings) != set(LEDGER_ROWS):
        fail("seal.ledger_file_bindings differs from fixed ledger rows")
    for rid, ref in ledger_bindings.items():
        if not isinstance(ref, dict):
            fail(f"{rid}: ledger binding is not an object")
        exact_keys(
            ref,
            {
                "proof_setup_tx",
                "signed_tx",
                "setup_watched_txins",
                "setup_watched_addresses",
                "watched_txins",
                "watched_addresses",
            },
            f"{rid}: ledger binding",
        )
        validate_ref_shape(ref["proof_setup_tx"], f"{rid}.proof_setup_tx")
        validate_ref_shape(ref["signed_tx"], f"{rid}.signed_tx")
        for prefix in ("setup_", ""):
            txins = ref[f"{prefix}watched_txins"]
            addresses = ref[f"{prefix}watched_addresses"]
            if not isinstance(txins, list) or not txins or not all(
                isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}#[0-9]+", value)
                for value in txins
            ) or len(txins) != len(set(txins)):
                fail(f"{rid}: parent-bound {prefix}watched_txins invalid")
            if not isinstance(addresses, list) or not addresses or not all(
                isinstance(value, str) and value for value in addresses
            ) or len(addresses) != len(set(addresses)):
                fail(f"{rid}: parent-bound {prefix}watched_addresses invalid")

    semantics = seal["ledger_semantics"]
    if not isinstance(semantics, dict):
        fail("seal.ledger_semantics is not an object")
    exact_keys(semantics, {"rows", "relations"}, "seal.ledger_semantics")
    semantic_rows = semantics["rows"]
    if not isinstance(semantic_rows, dict) or set(semantic_rows) != set(LEDGER_ROWS):
        fail("sealed ledger semantics differ from fixed rows")

    def pointer(value: Any, where: str) -> None:
        if not isinstance(value, str) or not value.startswith("/"):
            fail(f"{where} is not a nonempty JSON pointer")

    for rid, row in semantic_rows.items():
        if not isinstance(row, dict):
            fail(f"{rid}: semantic row is not an object")
        exact_keys(
            row,
            {
                "fields",
                "witnesses",
                "proof_setup_fields",
                "proof_setup_witness",
                "proof_setup_output_index",
                "proof_input_pointer",
                "created_output_indices",
                "created_output_assertions",
            },
            f"ledger semantics {rid}",
        )
        fields = row["fields"]
        if not isinstance(fields, dict) or set(fields) != set(LEDGER_SEMANTIC_ROLES):
            fail(f"{rid}: semantic fields differ from complete registration field set")
        for role, assertion in fields.items():
            if not isinstance(assertion, dict):
                fail(f"{rid}.{role}: assertion is not an object")
            exact_keys(assertion, {"pointer", "value"}, f"{rid}.{role}")
            pointer(assertion["pointer"], f"{rid}.{role}.pointer")
        witnesses = row["witnesses"]
        if not isinstance(witnesses, dict) or set(witnesses) != set(LEDGER_PROGRAMS[rid]):
            fail(f"{rid}: witness inventory differs from invoked program set")
        for aid, assertion in witnesses.items():
            if not isinstance(assertion, dict):
                fail(f"{rid}.{aid}: witness assertion is not an object")
            exact_keys(assertion, {"hash_pointer"}, f"{rid}.{aid}")
            pointer(assertion["hash_pointer"], f"{rid}.{aid}.hash_pointer")
        proof_fields = row["proof_setup_fields"]
        if not isinstance(proof_fields, dict) or set(proof_fields) != set(PROOF_SETUP_ROLES):
            fail(f"{rid}: proof setup fields differ from the fixed acquisition set")
        for role, assertion in proof_fields.items():
            if not isinstance(assertion, dict):
                fail(f"{rid}.proof_setup.{role}: assertion is not an object")
            exact_keys(assertion, {"pointer", "value"}, f"{rid}.proof_setup.{role}")
            pointer(assertion["pointer"], f"{rid}.proof_setup.{role}.pointer")
        proof_witness = row["proof_setup_witness"]
        if not isinstance(proof_witness, dict):
            fail(f"{rid}: proof setup witness is not an object")
        exact_keys(proof_witness, {"hash_pointer"}, f"{rid}.proof_setup_witness")
        pointer(proof_witness["hash_pointer"], f"{rid}.proof_setup_witness.hash_pointer")
        if not isinstance(row["proof_setup_output_index"], int) or row["proof_setup_output_index"] < 0:
            fail(f"{rid}: proof setup output index is invalid")
        pointer(row["proof_input_pointer"], f"{rid}.proof_input_pointer")
        indices = row["created_output_indices"]
        if not isinstance(indices, list) or not all(
            isinstance(index, int) and index >= 0 for index in indices
        ) or len(indices) != len(set(indices)):
            fail(f"{rid}: created output indices are invalid")
        assertions = row["created_output_assertions"]
        if not isinstance(assertions, list):
            fail(f"{rid}: created output assertions are not an array")
        for n, assertion in enumerate(assertions):
            if not isinstance(assertion, dict):
                fail(f"{rid}: created output assertion {n} is not an object")
            exact_keys(assertion, {"index", "pointer", "value"}, f"{rid}: created output assertion {n}")
            if assertion["index"] not in indices:
                fail(f"{rid}: created output assertion references an undeclared index")
            pointer(assertion["pointer"], f"{rid}: created output assertion {n}.pointer")
        if rid == "E0-register-valid-ledger":
            if not indices or not assertions:
                fail("E0 must bind at least one created output and assertion")
        elif indices or assertions:
            fail(f"{rid}: refused row cannot claim created outputs")

    relations = semantics["relations"]
    required_relations = {
        "E1-omission-identical-except-lifecycle-withdrawal",
        "E1-invalid-identical-except-inception-evidence",
        "E4-correct-total-wrong-checkpoint-destination",
    }
    if not isinstance(relations, dict) or set(relations) != required_relations:
        fail("sealed ledger relations differ from fixed relations")
    relation_keys = {
        "E1-omission-identical-except-lifecycle-withdrawal": {
            "equal_pointers", "e0_lifecycle", "e1_lifecycle"
        },
        "E1-invalid-identical-except-inception-evidence": {
            "equal_pointers", "e0_evidence", "invalid_evidence", "invalid_lifecycle"
        },
        "E4-correct-total-wrong-checkpoint-destination": {
            "equal_pointers", "e0_checkpoint_quantity", "e4_checkpoint_quantity",
            "e0_refund_quantity", "e4_refund_quantity", "bond", "total_value_pointers"
        },
    }
    for name, relation in relations.items():
        if not isinstance(relation, dict):
            fail(f"{name}: relation is not an object")
        exact_keys(relation, relation_keys[name], name)
        for key, value in relation.items():
            if key == "bond":
                if not isinstance(value, int) or value <= 0:
                    fail("sealed registration bond is not positive")
            elif key.endswith("pointers"):
                if not isinstance(value, list) or not value:
                    fail(f"{name}.{key} is empty/non-array")
                for n, item in enumerate(value):
                    pointer(item, f"{name}.{key}[{n}]")
            else:
                pointer(value, f"{name}.{key}")

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
        fixed_artifact, _, _ = MUTATIONS[row["id"]]
        if row["artifact"] != fixed_artifact:
            fail(f"{row['id']}: artifact differs from fixed enforcing artifact {fixed_artifact}")
        validate_ref_shape(row["patch"], f"{row['id']}.patch")
        seen.add(row["id"])
    if seen != set(MUTATIONS):
        fail("sealed mutation inventory differs from fixed controls")
    return artifacts


def main() -> int:
    global COMMAND_EVIDENCE, COMMAND_SEQUENCE
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--seal", required=True)
    ap.add_argument("--prepared")
    ap.add_argument("--receipt")
    ap.add_argument("--evidence-root", required=True)
    ap.add_argument("--preflight-only", action="store_true")
    args = ap.parse_args()

    evidence_root = Path(args.evidence_root).resolve()
    if evidence_root.exists() and (evidence_root.is_symlink() or not evidence_root.is_dir()):
        fail("parent evidence root exists but is not a nonsymlink directory")
    evidence_root.mkdir(parents=True, exist_ok=True)
    if any(evidence_root.iterdir()):
        fail("parent evidence root must start empty")
    COMMAND_EVIDENCE = evidence_root / "commands"
    COMMAND_EVIDENCE.mkdir()
    COMMAND_SEQUENCE = 0

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
    work = evidence_root / "work"
    work.mkdir()
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
    semantics_control = verify_variant_c(tools["aiken"], work)
    cek = check_cek_rows(aiken=tools["aiken"], artifacts=built, vectors=vectors, seal=seal)
    ledger = run_ledger_rows(
        cardano_cli=tools["cardano_cli"],
        prepared=pmeta,
        rows=ledger_rows,
        seal=seal,
        artifacts=built,
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
        "parent_evidence_root": str(evidence_root),
        "parent_evidence_inventory": retained_evidence_inventory(evidence_root),
        "artifacts": {
            aid: {"compiled_sha256": row.sha256, "script_hash": row.script_hash}
            for aid, row in built.items()
        },
        "cek_semantics_control": semantics_control,
        "cek_rows": cek,
        "ledger": ledger,
        "mutations": controls,
        "real_positive_executed": True,
        "real_positive_accepted": True,
        "all_fixed_rows_satisfied": True,
        "all_parent_mutation_controls_fired": set(controls) == set(ALL_CONTROLS),
        "artifacts_rebuilt_and_measured": True,
        "ledger_submitted_and_queried": True,
        "authentic_hash_proof_setups_executed": all(
            row["proof_setup_submit_exit"] == 0 for row in ledger["rows"].values()
        ),
        "variant_c_executed_and_discriminated": semantics_control["discriminator_fired"],
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
        if COMMAND_EVIDENCE is not None:
            failure_path = COMMAND_EVIDENCE.parent / "failure.json"
            if not failure_path.exists():
                failure_path.write_text(
                    json.dumps({"error": str(exc)}, indent=2, sort_keys=True) + "\n"
                )
        print(f"parent-verifier-v1: RED: {exc}", file=sys.stderr)
        raise SystemExit(1)
