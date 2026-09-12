"""Coverage record schema (singular-coverage-record-v1) and strict loading.

The record is the only place implementation coverage may be declared, and it
never decides PASS by itself: every check carries executed evidence, and the
gate recomputes validity. Unknown fields, unknown enums and malformed digests
fail closed — an unrecognized row or status must never pass silently.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from pathlib import Path

SCHEMA = "singular-coverage-record-v1"
LAYERS = ("property", "state-machine", "integration-story")
EVIDENCE_STATUSES = ("pass", "fail", "skipped", "unexecuted")
CONTROL_STATUSES = ("valid", "invalid")

_HEX64 = re.compile(r"\A[0-9a-f]{64}\Z")


class RecordError(Exception):
    pass


def _require_hex64(value, what: str) -> str:
    if not isinstance(value, str) or not _HEX64.match(value):
        raise RecordError(f"{what} must be a 64-char lowercase hex sha256, got {value!r}")
    return value


def _require_str(value, what: str, allow_empty: bool = False) -> str:
    if not isinstance(value, str) or (not allow_empty and not value):
        raise RecordError(f"{what} must be a non-empty string, got {value!r}")
    return value


def _require_int(value, what: str, minimum: int = 0) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        raise RecordError(f"{what} must be an integer >= {minimum}, got {value!r}")
    return value


@dataclass(frozen=True)
class Evidence:
    status: str
    candidateDigest: str
    candidatePaths: tuple[str, ...]
    command: str
    seed: str
    cases: int
    discards: int
    thenAssertions: int
    resultDigest: str

    @property
    def reached(self) -> int:
        return self.cases - self.discards


@dataclass(frozen=True)
class Control:
    kind: str
    target: str
    status: str


@dataclass(frozen=True)
class Check:
    checkId: str
    obligation: str
    statementSha256: str
    layer: str
    executionIdentity: str
    entryPoints: tuple[str, ...]
    definitionDigests: dict[str, str]
    evidence: Evidence
    control: Control | None

    @property
    def identity(self) -> str:
        return f"{self.obligation}@{self.statementSha256}"


@dataclass(frozen=True)
class Mapping:
    obligation: str
    statementSha256: str
    storyId: str
    clauses: dict
    vocabulary: dict

    @property
    def identity(self) -> str:
        return f"{self.obligation}@{self.statementSha256}"


@dataclass(frozen=True)
class Record:
    checks: tuple[Check, ...]
    mappings: tuple[Mapping, ...]
    discoveredPopulation: tuple[str, ...]
    path: str

    def by_identity_checks(self) -> dict[str, tuple[Check, ...]]:
        out: dict[str, list[Check]] = {}
        for check in self.checks:
            out.setdefault(check.identity, []).append(check)
        return {k: tuple(v) for k, v in out.items()}

    def by_identity_mappings(self) -> dict[str, Mapping]:
        return {m.identity: m for m in self.mappings}


def _parse_evidence(raw, where: str) -> Evidence:
    if not isinstance(raw, dict):
        raise RecordError(f"{where}.evidence must be an object")
    allowed = {
        "status", "candidateDigest", "candidatePaths", "command", "seed",
        "cases", "discards", "thenAssertions", "resultDigest",
    }
    unknown = set(raw) - allowed
    if unknown:
        raise RecordError(f"{where}.evidence has unknown fields: {sorted(unknown)}")
    missing = allowed - set(raw)
    if missing:
        raise RecordError(f"{where}.evidence is missing fields: {sorted(missing)}")
    status = raw["status"]
    if status not in EVIDENCE_STATUSES:
        raise RecordError(f"{where}.evidence.status must be one of {EVIDENCE_STATUSES}, got {status!r}")
    candidate = raw["candidateDigest"]
    if status in ("pass", "fail") or candidate:
        _require_hex64(candidate, f"{where}.evidence.candidateDigest")
    paths = raw["candidatePaths"]
    if not isinstance(paths, list) or not all(isinstance(p, str) and p for p in paths):
        raise RecordError(f"{where}.evidence.candidatePaths must be a list of non-empty strings")
    if status in ("pass", "fail") and not paths:
        raise RecordError(f"{where}.evidence.candidatePaths must bind the candidate for {status} evidence")
    _require_str(raw["command"], f"{where}.evidence.command", allow_empty=status == "unexecuted")
    _require_str(raw["seed"], f"{where}.evidence.seed", allow_empty=True)
    cases = _require_int(raw["cases"], f"{where}.evidence.cases")
    discards = _require_int(raw["discards"], f"{where}.evidence.discards")
    if discards > cases:
        raise RecordError(f"{where}.evidence.discards exceeds cases")
    then = _require_int(raw["thenAssertions"], f"{where}.evidence.thenAssertions")
    result = raw["resultDigest"]
    if status == "pass":
        _require_hex64(result, f"{where}.evidence.resultDigest (required for pass evidence)")
    elif result != "":
        _require_hex64(result, f"{where}.evidence.resultDigest")
    return Evidence(
        status=status, candidateDigest=candidate, candidatePaths=tuple(paths),
        command=raw["command"], seed=raw["seed"], cases=cases, discards=discards,
        thenAssertions=then, resultDigest=result,
    )


def _parse_control(raw, where: str) -> Control | None:
    if raw is None:
        return None
    if not isinstance(raw, dict):
        raise RecordError(f"{where}.control must be an object or null")
    allowed = {"kind", "target", "status"}
    unknown = set(raw) - allowed
    if unknown:
        raise RecordError(f"{where}.control has unknown fields: {sorted(unknown)}")
    missing = allowed - set(raw)
    if missing:
        raise RecordError(f"{where}.control is missing fields: {sorted(missing)}")
    if raw["status"] not in CONTROL_STATUSES:
        raise RecordError(f"{where}.control.status must be one of {CONTROL_STATUSES}")
    return Control(
        kind=_require_str(raw["kind"], f"{where}.control.kind"),
        target=_require_str(raw["target"], f"{where}.control.target"),
        status=raw["status"],
    )


def _parse_check(raw, where: str) -> Check:
    if not isinstance(raw, dict):
        raise RecordError(f"{where} must be an object")
    allowed = {
        "checkId", "obligation", "statementSha256", "layer", "executionIdentity",
        "entryPoints", "definitionDigests", "evidence", "control",
    }
    unknown = set(raw) - allowed
    if unknown:
        raise RecordError(f"{where} has unknown fields: {sorted(unknown)}")
    missing = allowed - set(raw)
    if missing:
        raise RecordError(f"{where} is missing fields: {sorted(missing)}")
    layer = raw["layer"]
    if layer not in LAYERS:
        raise RecordError(f"{where}.layer must be one of {LAYERS}, got {layer!r}")
    digests = raw["definitionDigests"]
    if not isinstance(digests, dict):
        raise RecordError(f"{where}.definitionDigests must be an object")
    for name, dig in digests.items():
        _require_str(name, f"{where}.definitionDigests key")
        _require_hex64(dig, f"{where}.definitionDigests[{name}]")
    entry_points = raw["entryPoints"]
    if not isinstance(entry_points, list) or not all(isinstance(p, str) and p for p in entry_points):
        raise RecordError(f"{where}.entryPoints must be a list of non-empty strings")
    return Check(
        checkId=_require_str(raw["checkId"], f"{where}.checkId"),
        obligation=_require_str(raw["obligation"], f"{where}.obligation"),
        statementSha256=_require_hex64(raw["statementSha256"], f"{where}.statementSha256"),
        layer=layer,
        executionIdentity=_require_str(raw["executionIdentity"], f"{where}.executionIdentity"),
        entryPoints=tuple(entry_points),
        definitionDigests=dict(digests),
        evidence=_parse_evidence(raw["evidence"], where),
        control=_parse_control(raw["control"], where),
    )


def _parse_mapping(raw, where: str) -> Mapping:
    if not isinstance(raw, dict):
        raise RecordError(f"{where} must be an object")
    allowed = {"obligation", "statementSha256", "storyId", "clauses", "vocabulary"}
    unknown = set(raw) - allowed
    if unknown:
        raise RecordError(f"{where} has unknown fields: {sorted(unknown)}")
    missing = allowed - set(raw)
    if missing:
        raise RecordError(f"{where} is missing fields: {sorted(missing)}")
    for clause in ("clauses", "vocabulary"):
        if not isinstance(raw[clause], dict):
            raise RecordError(f"{where}.{clause} must be an object")
    if not raw["clauses"]:
        raise RecordError(f"{where}.clauses must not be empty (a story with no clauses is not a story)")
    return Mapping(
        obligation=_require_str(raw["obligation"], f"{where}.obligation"),
        statementSha256=_require_hex64(raw["statementSha256"], f"{where}.statementSha256"),
        storyId=_require_str(raw["storyId"], f"{where}.storyId"),
        clauses=raw["clauses"],
        vocabulary=raw["vocabulary"],
    )


def parse_record_text(text: str, label: str) -> Record:
    try:
        raw = json.loads(text)
    except json.JSONDecodeError as exc:
        raise RecordError(f"record is not valid JSON: {label}: {exc}") from exc
    if not isinstance(raw, dict):
        raise RecordError(f"record must be a JSON object: {label}")
    if raw.get("schema") != SCHEMA:
        raise RecordError(f"record schema must be {SCHEMA!r}, got {raw.get('schema')!r}")
    unknown = set(raw) - {"schema", "checks", "mappings", "discoveredPopulation"}
    if unknown:
        raise RecordError(f"record has unknown top-level fields: {sorted(unknown)}")
    if "discoveredPopulation" not in raw:
        raise RecordError(
            "record is missing discoveredPopulation — the obligation population the record "
            "was cut against is what the ratchet protects; a record without it cannot be judged"
        )
    population = raw["discoveredPopulation"]
    if not isinstance(population, list) or not all(
        isinstance(i, str) and "@" in i for i in population
    ):
        raise RecordError("discoveredPopulation must be a list of name@digest identity strings")
    if len(set(population)) != len(population):
        raise RecordError("discoveredPopulation contains duplicate identities")
    checks_raw = raw.get("checks", [])
    mappings_raw = raw.get("mappings", [])
    if not isinstance(checks_raw, list) or not isinstance(mappings_raw, list):
        raise RecordError("record checks/mappings must be lists")
    checks = tuple(_parse_check(c, f"checks[{i}]") for i, c in enumerate(checks_raw))
    mappings = tuple(_parse_mapping(m, f"mappings[{i}]") for i, m in enumerate(mappings_raw))
    ids = [c.checkId for c in checks]
    if len(set(ids)) != len(ids):
        raise RecordError("duplicate checkId in record")
    return Record(
        checks=checks,
        mappings=mappings,
        discoveredPopulation=tuple(population),
        path=label,
    )


def load_record(path: Path) -> Record:
    try:
        text = path.read_text()
    except FileNotFoundError as exc:
        raise RecordError(f"record not found: {path}") from exc
    return parse_record_text(text, str(path))


def candidate_digest(root: Path, paths: tuple[str, ...]) -> str:
    """sha256 over the sorted (path, file digest) set of the candidate sources.

    The recorded evidence binds this digest; when the declared candidate
    sources change, the binding goes stale and the evidence stops paying.
    """
    accumulator = hashlib.sha256()
    files: list[Path] = []
    anchor = root.resolve()
    for rel in paths:
        base = (root / rel).resolve()
        if not base.is_relative_to(anchor):
            raise RecordError(f"candidatePath escapes the candidate root: {rel}")
        if not base.exists():
            raise RecordError(f"candidatePath does not exist: {rel}")
        if base.is_dir():
            files.extend(sorted(p for p in base.rglob("*") if p.is_file()))
        else:
            files.append(base)
    if not files:
        raise RecordError(f"candidatePaths bind no files: {paths}")
    for path in sorted(files):
        try:
            shown = path.relative_to(root)
        except ValueError:
            raise RecordError(f"candidatePath escapes the candidate root: {path}") from None
        accumulator.update(str(shown).encode())
        accumulator.update(hashlib.sha256(path.read_bytes()).digest())
    return accumulator.hexdigest()
def definition_digest(root: Path, qualified: str) -> str | None:
    """Digest of a named definition's full source span.

    Used to bind checks and mappings to the exact definitions an obligation
    talks about, so a definition change invalidates the binding. Unlike a
    theorem signature, a definition's body is its semantics, so the span
    covers the whole declaration: from the declaration keyword to the next
    top-level event (namespace/section/mutual/end or next declaration).
    Returns None when no such definition exists.
    """
    from .leanscan import QUALIDENT, clean_source  # noqa: PLC0415

    pattern = re.compile(
        rf"(?m)^(?:@\[[^\]\n]*\]\s*)*"
        rf"(?:(?:private|protected|noncomputable|unsafe|partial|sealed)\s+)*"
        rf"(?P<kw>def|abbrev|structure|inductive)\s+(?P<name>{QUALIDENT})(?![A-Za-z0-9_'!?])"
    )
    ns_open = re.compile(rf"(?m)^namespace\s+(?P<name>{QUALIDENT})\s*$")
    block_line = re.compile(r"(?m)^(?:end(?:\s+\S+)?|section(?:\s+\S+)?|mutual)\s*$")
    lean_dir = root / "lean"
    for path in sorted(lean_dir.rglob("*.lean")):
        clean = clean_source(path.read_text())
        events: list[tuple[int, int, object]] = []
        for m in ns_open.finditer(clean):
            events.append((m.start(), 0, ("namespace", m.group("name"))))
        for m in block_line.finditer(clean):
            events.append((m.start(), 1, None))
        for m in pattern.finditer(clean):
            events.append((m.start(), 2, m))
        events.sort(key=lambda e: (e[0], e[1]))
        stack: list[str | None] = []
        for idx, (_pos, _kind, payload) in enumerate(events):
            if payload is None:
                if stack:
                    stack.pop()
                continue
            if isinstance(payload, tuple):
                stack.append(payload[1])
                continue
            m = payload
            name = ".".join([s for s in stack if s] + m.group("name").split("."))
            if name != qualified:
                continue
            limit = events[idx + 1][0] if idx + 1 < len(events) else len(clean)
            span = " ".join(clean[m.start():limit].split())
            return hashlib.sha256((name + "\n" + span).encode()).hexdigest()
    return None
