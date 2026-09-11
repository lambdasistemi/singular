"""The full-completion gate (issue #80), separate from the ratchet.

Strict completion requires every debt category zero: no unclassified
obligations, no missing mappings, no missing layers, no stale, skipped,
unexecuted, failing, vacuous or non-discriminating evidence. It never
defaults to passing because a PR is incremental — a nonzero debt anywhere is
INCOMPLETE, with the obligations named.
"""

from __future__ import annotations

from dataclasses import dataclass

from .debt import ObligationDebt, find_stale_bindings
from .inventory import Inventory
from .record import Record


@dataclass(frozen=True)
class CompletionVerdict:
    verdict: str  # COMPLETE | INCOMPLETE
    mapping_debt: tuple[str, ...]
    layer_debt: tuple[str, ...]
    execution_debt: tuple[str, ...]
    unclassified: tuple[str, ...]
    stale_bindings: tuple[str, ...]

    @property
    def complete(self) -> bool:
        return self.verdict == "COMPLETE"


def completion(inventory: Inventory, record: Record, debts: list[ObligationDebt]) -> CompletionVerdict:
    mapping = tuple(sorted(d.name for d in debts if d.mapping_debt))
    layer = tuple(sorted(d.name for d in debts if d.layer_debt))
    execution = tuple(
        sorted(f"{d.name} [{f.code}] {f.detail}" for d in debts for f in d.execution_findings)
    )
    unclassified = tuple(sorted(d.name for d in debts if d.unclassified))
    stale = tuple(sorted(f"{obligation}: {detail}" for _k, obligation, detail in find_stale_bindings(inventory, record)))
    complete = not (mapping or layer or execution or unclassified or stale)
    return CompletionVerdict(
        verdict="COMPLETE" if complete else "INCOMPLETE",
        mapping_debt=mapping,
        layer_debt=layer,
        execution_debt=execution,
        unclassified=unclassified,
        stale_bindings=stale,
    )
