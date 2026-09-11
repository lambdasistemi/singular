"""Human and machine rendering for the coverage gate.

Debt is reported per obligation, never only as totals; the three axes are
reported separately and never summed.
"""

from __future__ import annotations

import json
from pathlib import Path

from .completion import CompletionVerdict
from .debt import ObligationDebt
from .inventory import Inventory
from .ratchet import RatchetResult


def inventory_text(inventory: Inventory, root: Path) -> str:
    lines = [
        f"INVENTORY {inventory.manifest_bound + inventory.unclassified} obligations "
        f"= {inventory.manifest_bound} manifest-bound + {inventory.unclassified} unclassified",
        "  manifest identity: qualified name + statementSha256 via tools/check_model.py",
        "  discovery: all of lean/, dotted/primed/'?' identifiers included",
    ]
    by_source: dict[str, int] = {}
    for obligation in inventory.obligations:
        by_source[obligation.source] = by_source.get(obligation.source, 0) + 1
    for source in sorted(by_source):
        lines.append(f"    {source}: {by_source[source]}")
    unclassified = [o for o in inventory.obligations if o.classification == "unclassified"]
    lines.append(f"  unclassified ({len(unclassified)}):")
    for obligation in unclassified:
        lead = f", lexical-lead references={obligation.references}" if obligation.references else ", declaration-only (lexical lead)"
        lines.append(f"    {obligation.name} [{obligation.source}:{obligation.line}]{lead}")
    lines.append(
        "  limits: lexical, not proof-term; reference counts are leads and never "
        "classify, exclude or shrink anything"
    )
    return "\n".join(lines)


def inventory_json(inventory: Inventory) -> dict:
    return {
        "manifestBound": inventory.manifest_bound,
        "unclassified": inventory.unclassified,
        "total": inventory.manifest_bound + inventory.unclassified,
        "obligations": [
            {
                "name": o.name,
                "statementSha256": o.statementSha256,
                "classification": o.classification,
                "status": o.status,
                "source": o.source,
                "line": o.line,
                "attributed": o.attributed,
                "lexicalLeadReferences": o.references,
            }
            for o in inventory.obligations
        ],
    }


def debt_text(debts: list[ObligationDebt]) -> str:
    mapping = [d for d in debts if d.mapping_debt]
    layer = [d for d in debts if d.layer_debt]
    execution = [(d, f) for d in debts for f in d.execution_findings]
    unclassified = [d for d in debts if d.unclassified]
    lines = [
        f"DEBT axes (reported separately, never summed)",
        f"  mapping debt: {len(mapping)} obligations without a bound story representation",
        f"  implementation-layer debt: {len(layer)} obligations with fewer than two distinct layers",
        f"  execution debt: {len(execution)} findings (stale/skipped/unexecuted/failing/vacuous/invalid-control)",
        f"  unclassified: {len(unclassified)} declarations outside the manifests",
    ]
    for d in debts:
        notes = []
        if d.mapping_debt:
            notes.append("unmapped")
        if d.layer_debt:
            achieved = ",".join(sorted(d.layers_achieved)) or "none"
            notes.append(f"layers<{','.join(achieved)}>" if achieved != "none" else "no-layer")
        for f in d.execution_findings:
            notes.append(f.code)
        if d.unclassified:
            notes.append("unclassified")
        if notes:
            lines.append(f"    {d.name}: {'; '.join(notes)}")
    return "\n".join(lines)


def debt_json(debts: list[ObligationDebt]) -> dict:
    return {
        "mappingDebt": sorted(d.name for d in debts if d.mapping_debt),
        "layerDebt": sorted(d.name for d in debts if d.layer_debt),
        "executionDebt": [
            {"obligation": d.name, "code": f.code, "detail": f.detail}
            for d in debts for f in d.execution_findings
        ],
        "unclassified": sorted(d.name for d in debts if d.unclassified),
    }


def ratchet_text(result: RatchetResult) -> str:
    if result.passed:
        lines = [f"RATCHET: PASS — no per-obligation regression against the protected base"]
    else:
        lines = [f"RATCHET: FAIL — {len(result.regressions)} per-obligation regression(s)"]
    for r in result.regressions:
        lines.append(f"  {r.kind} {r.obligation}: {r.detail}")
    if result.additions:
        lines.append(f"  additions (informational, never offset regressions): {len(result.additions)}")
        for a in result.additions:
            lines.append(f"    + {a}")
    return "\n".join(lines)


def ratchet_json(result: RatchetResult) -> dict:
    return {
        "verdict": "PASS" if result.passed else "FAIL",
        "regressions": [
            {"kind": r.kind, "obligation": r.obligation, "detail": r.detail}
            for r in result.regressions
        ],
        "additions": list(result.additions),
    }


def completion_text(verdict: CompletionVerdict) -> str:
    lines = [
        f"COMPLETION: {verdict.verdict}",
        f"  mapping debt rows: {len(verdict.mapping_debt)}",
        f"  implementation-layer debt rows: {len(verdict.layer_debt)}",
        f"  execution debt findings: {len(verdict.execution_debt)}",
        f"  unclassified rows: {len(verdict.unclassified)}",
        f"  stale bindings: {len(verdict.stale_bindings)}",
    ]
    if not verdict.complete:
        lines.append("  strict completion requires every category zero — an incremental PR does not")
    for s in verdict.stale_bindings:
        lines.append(f"    stale-binding {s}")
    return "\n".join(lines)


def completion_json(verdict: CompletionVerdict) -> dict:
    return {
        "verdict": verdict.verdict,
        "mappingDebt": list(verdict.mapping_debt),
        "layerDebt": list(verdict.layer_debt),
        "executionDebt": list(verdict.execution_debt),
        "unclassified": list(verdict.unclassified),
        "staleBindings": list(verdict.stale_bindings),
    }


def write_report(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
