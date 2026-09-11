"""The per-obligation ratchet (issue #80): regression without offsetting.

The ratchet compares the current coverage record against a protected base
record, row by row, per obligation and per required layer. It has no total
arithmetic whatsoever: ten new layers elsewhere cannot offset losing one.
Adding coverage is reported as information; it never enters the verdict.

Base layers are judged structurally (executed pass, non-vacuous, valid
control) because they were fresh when the base was cut; current layers must
additionally be fresh against the current tree, so reusing a base result for
changed code regresses instead of inheriting.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .debt import MAX_DISCARD_RATIO, PopulationError, UnknownRowError, check_current_population, unknown_rows
from .inventory import Inventory
from .record import Record

@dataclass(frozen=True)
class Regression:
    kind: str
    obligation: str
    detail: str

    def __str__(self) -> str:
        return f"{self.kind} {self.obligation}: {self.detail}"


@dataclass(frozen=True)
class RatchetResult:
    regressions: tuple[Regression, ...]
    additions: tuple[str, ...]

    @property
    def passed(self) -> bool:
        return not self.regressions


def structural_layers(checks) -> frozenset[str]:
    """Layers that would have counted when the record was cut: executed pass,
    non-vacuous, valid control — without freshness against today's tree."""
    layers: set[str] = set()
    for check in checks:
        ev = check.evidence
        if ev.status != "pass":
            continue
        if ev.thenAssertions == 0:
            continue
        if ev.cases == 0 or (ev.cases > 0 and ev.reached == 0):
            continue
        if ev.cases > 0 and ev.discards / ev.cases > MAX_DISCARD_RATIO:
            continue
        if check.control is not None and check.control.status == "invalid":
            continue
        layers.add(check.layer)
    return frozenset(layers)


def ratchet(inventory: Inventory, base: Record, current: Record, root: Path) -> RatchetResult:
    unknown_rows(inventory, current)
    unknown_rows(inventory, base)
    check_current_population(inventory, current)

    regressions: list[Regression] = []
    identities = inventory.by_identity()
    names = inventory.by_name()

    # every identity in the protected base population must still exist —
    # theorem removal cannot shrink the denominator, coverage record or not
    for identity in sorted(set(base.discoveredPopulation)):
        if identity not in identities:
            regressions.append(
                Regression(
                    "obligation-vanished",
                    identity,
                    "the protected base discovered this obligation but current discovery does "
                    "not — theorem removal cannot shrink the denominator",
                )
            )
            continue

    # current rows keyed to stale statement digests: the invalidation signal
    from .debt import find_stale_bindings  # noqa: PLC0415

    for kind, obligation, detail in find_stale_bindings(inventory, current):
        regressions.append(Regression(kind, obligation, detail))

    base_checks = base.by_identity_checks()
    base_mappings = base.by_identity_mappings()
    current_checks = current.by_identity_checks()
    current_mappings = current.by_identity_mappings()

    # every identity the base rows mention must still exist (statement-edit
    # invalidation surfaces here as well)
    for identity in sorted(set(base_checks) | set(base_mappings)):
        if identity not in identities:
            regressions.append(
                Regression(
                    "obligation-vanished",
                    identity,
                    "the protected base references this obligation but discovery no longer "
                    "finds it — coverage does not survive a statement edit",
                )
            )
            continue

        if identity in base_mappings and identity not in current_mappings:
            regressions.append(
                Regression(
                    "mapping-removed",
                    identity,
                    f"the base bound a story representation ({base_mappings[identity].storyId}) "
                    "and the current record no longer does",
                )
            )

        base_layers = structural_layers(base_checks.get(identity, ()))
        current_achieved = {
            check.layer
            for check in current_checks.get(identity, ())
            if _fresh_and_paying(check, root)
        }
        for layer in sorted(base_layers - current_achieved):
            regressions.append(
                Regression(
                    "layer-lost",
                    identity,
                    f"the base holds a passing {layer} check and the current record does not",
                )
            )

    additions = sorted(
        identity
        for identity in set(current_checks) | set(current_mappings)
        if identity not in set(base_checks) | set(base_mappings)
    )
    return RatchetResult(regressions=tuple(regressions), additions=tuple(additions))


def _fresh_and_paying(check, root: Path) -> bool:
    from .debt import _validity_findings  # noqa: PLC0415

    findings, pays = _validity_findings(check, root)
    return pays and not findings
