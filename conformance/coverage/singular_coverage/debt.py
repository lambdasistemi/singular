"""Per-obligation debt across the three axes (issue #80; code-the-design skill).

Axes are computed per obligation and reported separately; they are never
summed into one number:

1. mapping debt — the obligation has no bound Given/When/Then representation
   attached to its qualified identity and statement digest;
2. implementation-layer debt — fewer than two distinct executable checks: at
   least one property/state-machine layer AND one integration-story layer;
3. execution debt — required evidence that is stale, skipped, unexecuted,
   failing, vacuous, or whose discrimination control is invalid.

Layer achievement is computed, never typed: a check pays only when its
evidence says pass, binds the current candidate and definition digests,
reaches its precondition (non-vacuity), and carries a valid discrimination
control. Two checks sharing one executionIdentity are ONE check — aliases
never stack into a second layer. Mutation controls establish discrimination;
they are never a second layer by themselves.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from .inventory import Inventory
from .record import Record, candidate_digest, definition_digest

# Non-vacuity thresholds. A generator that never reaches its precondition, or
# that discards more than half its cases, does not establish coverage.
MAX_DISCARD_RATIO = 0.5

REQUIRED_LAYERS = (  # at least one of the first group AND one of the second
    ("property", "state-machine"),
    ("integration-story",),
)


@dataclass
class Finding:
    code: str
    detail: str

    def __str__(self) -> str:
        return f"{self.code}: {self.detail}"


@dataclass
class ObligationDebt:
    name: str
    identity: str
    classification: str
    mapping_debt: bool
    layer_debt: bool
    layers_achieved: frozenset[str] = frozenset()
    execution_findings: tuple[Finding, ...] = field(default_factory=tuple)
    unclassified: bool = False

    @property
    def has_execution_debt(self) -> bool:
        return bool(self.execution_findings)


def _validity_findings(check, root: Path) -> tuple[list[Finding], bool]:
    """Findings for one check; also returns whether it may pay a layer."""
    findings: list[Finding] = []
    ev = check.evidence
    pays = True

    if ev.status == "fail":
        findings.append(Finding("failing-check", f"{check.checkId} reported a failing result"))
        pays = False
    elif ev.status == "skipped":
        findings.append(Finding("skipped-check", f"{check.checkId} was skipped, not executed"))
        pays = False
    elif ev.status == "unexecuted":
        findings.append(
            Finding("unexecuted-check", f"{check.checkId} is recorded but not selected by the runner")
        )
        pays = False

    if ev.status in ("pass", "fail"):
        current = candidate_digest(root, ev.candidatePaths)
        if current != ev.candidateDigest:
            findings.append(
                Finding(
                    "stale-candidate",
                    f"{check.checkId} evidence binds candidate {ev.candidateDigest[:12]}… "
                    f"but {','.join(ev.candidatePaths)} now digests {current[:12]}…",
                )
            )
            pays = False
        for defn, bound in sorted(check.definitionDigests.items()):
            current_def = definition_digest(root, defn)
            if current_def is None:
                findings.append(Finding("definition-not-found", f"{check.checkId} binds unknown definition {defn}"))
                pays = False
            elif current_def != bound:
                findings.append(
                    Finding(
                        "stale-definition",
                        f"{check.checkId} binds {defn} at {bound[:12]}… but it now digests {current_def[:12]}…",
                    )
                )
                pays = False

    if ev.thenAssertions == 0:
        findings.append(
            Finding("vacuous-empty-then", f"{check.checkId} asserts nothing in its Then phase")
        )
        pays = False
    if ev.cases > 0 and ev.reached == 0:
        findings.append(
            Finding(
                "vacuous-generator",
                f"{check.checkId} never reached its precondition ({ev.cases} cases, {ev.discards} discarded)",
            )
        )
        pays = False
    if ev.cases == 0 and ev.status == "pass":
        findings.append(Finding("empty-generator", f"{check.checkId} ran zero cases and claimed a pass"))
        pays = False
    if ev.cases > 0 and ev.discards / ev.cases > MAX_DISCARD_RATIO:
        findings.append(
            Finding(
                "excessive-discards",
                f"{check.checkId} discarded {ev.discards}/{ev.cases} cases "
                f"(limit {MAX_DISCARD_RATIO:.0%}); shrinking must preserve the Given assumptions",
            )
        )
        pays = False

    if check.control is not None and check.control.status == "invalid":
        findings.append(
            Finding(
                "invalid-control",
                f"{check.checkId} discrimination control '{check.control.target}' is invalid "
                "(unreachable mutant, vacuous generator, or refusal for an unrelated reason)",
            )
        )
        pays = False

    return findings, pays


def compute_debt(inventory: Inventory, record: Record, root: Path) -> list[ObligationDebt]:
    checks_by_identity = record.by_identity_checks()
    mappings_by_identity = record.by_identity_mappings()

    debts: list[ObligationDebt] = []
    for obligation in inventory.obligations:
        checks = checks_by_identity.get(obligation.identity, ())
        mapping = mappings_by_identity.get(obligation.identity)

        findings: list[Finding] = []
        layers: dict[str, str] = {}  # layer -> executionIdentity that achieved it
        for check in checks:
            check_findings, pays = _validity_findings(check, root)
            findings.extend(check_findings)
            if pays:
                claimed = layers.get(check.layer)
                if claimed is None:
                    layers[check.layer] = check.executionIdentity
                elif claimed != check.executionIdentity:
                    findings.append(
                        Finding(
                            "duplicate-layer-identity",
                            f"{check.checkId} claims layer {check.layer} via execution "
                            f"'{check.executionIdentity}' but '{claimed}' already achieved it — "
                            "distinct layers must be distinct executions, not aliases",
                        )
                    )
                    # an alias does not add a layer; the original achievement stands

        # the required layers must be backed by distinct executions: the same
        # execution wearing two layer names is ONE layer aliased into two
        distinct_executions = set(layers.values())
        if len(layers) >= 2 and len(distinct_executions) < len(layers):
            findings.append(
                Finding(
                    "duplicate-layer-identity",
                    f"{obligation.name} claims {sorted(layers)} but they all resolve to "
                    f"execution(s) {sorted(distinct_executions)} — one execution aliased into "
                    "two layers",
                )
            )
        satisfied = len(layers) >= 2 and len(distinct_executions) == len(layers) and all(
            any(layer in layers for layer in group) for group in REQUIRED_LAYERS
        )
        debts.append(
            ObligationDebt(
                name=obligation.name,
                identity=obligation.identity,
                classification=obligation.classification,
                mapping_debt=mapping is None,
                layer_debt=not satisfied,
                layers_achieved=frozenset(layers),
                execution_findings=tuple(findings),
                unclassified=obligation.classification == "unclassified",
            )
        )
    return debts


class UnknownRowError(Exception):
    """A record row references a name discovery never produced. Fail closed."""


class PopulationError(Exception):
    """The record's claimed population disagrees with live discovery."""


def check_current_population(inventory: Inventory, record: Record) -> None:
    """The current record must claim exactly the population discovery finds.

    A record that omits a discovered obligation hides debt; one that claims a
    vanished obligation is stale. Both fail closed: updating the record's
    population is an explicit act that accompanies any inventory change.
    """
    claimed = set(record.discoveredPopulation)
    live = set(inventory.by_identity())
    missing = sorted(claimed - live)
    extra = sorted(live - claimed)
    if missing or extra:
        raise PopulationError(
            "current record population disagrees with discovery: "
            f"{len(missing)} claimed but no longer discovered (e.g. {missing[:2]}), "
            f"{len(extra)} discovered but unclaimed (e.g. {extra[:2]}) — re-emit the "
            "record population; a shrinking denominator is a finding, never a cleanup"
        )


def unknown_rows(inventory: Inventory, record: Record) -> None:
    """Fail closed on rows referencing obligation names discovery does not know.

    A row keyed to a never-discovered name is unrecognized (renamed row,
    typo) and fails closed. Stale statement digests are not raised here:
    they are the ratchet's invalidation signal (see find_stale_bindings).
    """
    by_name = inventory.by_name()
    for check in record.checks:
        if check.obligation not in by_name:
            raise UnknownRowError(
                f"check {check.checkId} references unrecognized obligation row {check.obligation}"
            )
    for mapping in record.mappings:
        if mapping.obligation not in by_name:
            raise UnknownRowError(
                f"mapping {mapping.storyId} references unrecognized obligation row {mapping.obligation}"
            )


def find_stale_bindings(inventory: Inventory, record: Record) -> list[tuple[str, str, str]]:
    """Rows bound to a known obligation name at a stale statement digest.

    Coverage never inherits across statement edits: a weakened or otherwise
    edited statement yields a new identity, and every row still keyed to the
    old one is reported. Returns (kind, obligation, detail) triples.
    """
    by_name = inventory.by_name()
    stale: list[tuple[str, str, str]] = []
    for check in record.checks:
        obligation = by_name.get(check.obligation)
        if obligation is not None and check.statementSha256 != obligation.statementSha256:
            stale.append((
                "stale-binding",
                check.obligation,
                f"check {check.checkId} binds {check.obligation} at digest "
                f"{check.statementSha256[:12]}… but the statement now digests "
                f"{obligation.statementSha256[:12]}… — coverage does not inherit across "
                "statement edits; re-bind and re-establish the layers",
            ))
    for mapping in record.mappings:
        obligation = by_name.get(mapping.obligation)
        if obligation is not None and mapping.statementSha256 != obligation.statementSha256:
            stale.append((
                "stale-binding",
                mapping.obligation,
                f"mapping {mapping.storyId} binds {mapping.obligation} at a stale statement "
                f"digest ({mapping.statementSha256[:12]}…); re-bind it to the current identity",
            ))
    return stale
