"""Obligation inventory for issue #80: manifests + discovery over all of lean/.

The obligation identity for manifest-bound statements is exactly
``qualified name + statementSha256`` produced by ``tools/check_model.py``'s
``statement_inventory`` — reused here, never re-modeled: this module imports
the tool and re-runs its extraction against the source, failing if the
committed manifests drift from it by one byte. There is no hand-maintained
registry anywhere in the gate.

Discovery then runs over ALL of ``lean/`` (strict lexical scan), so
declarations outside the four statements modules stay in the denominator as
unclassified. Reclassification is mapping work with reviewed rationale; this
module has no helper label that could shrink the count.
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

from .leanscan import Declaration, scan_tree_strict

# statements module -> (declaration prefix, manifest path), mirroring
# tools/check_model.py's own pairing.
STATEMENT_MODULES = [
    ("lean/Singular/Statements.lean", "Singular.Statements.", "lean/theorem-debt.json"),
    ("lean/Singular/NamingStatements.lean", "Singular.NamingStatements.", "lean/naming-theorem-debt.json"),
    ("lean/Singular/NamingLifecycleStatements.lean", "Singular.NamingLifecycleStatements.",
     "lean/lifecycle-theorem-debt.json"),
    ("lean/Singular/NamingWireStatements.lean", "Singular.NamingWireStatements.", "lean/wire-theorem-debt.json"),
]


@dataclass(frozen=True)
class Obligation:
    name: str                 # qualified declaration name
    statementSha256: str      # manifest digest for manifest-bound; signature digest otherwise
    classification: str       # manifest-bound | unclassified
    status: str               # PROVED | STATED | UNCLASSIFIED
    source: str               # repo-relative module path
    line: int
    attributed: bool
    references: int           # lexical occurrences beyond the declaration (a lead, never evidence)

    @property
    def identity(self) -> str:
        return f"{self.name}@{self.statementSha256}"


class InventoryError(Exception):
    pass


def _load_check_model(root: Path):
    tools = root / "tools"
    if not (tools / "check_model.py").exists():
        raise InventoryError(
            f"{tools}/check_model.py not found — obligation identity is derived from the "
            "manifests via that extraction; refusing to run without it"
        )
    sys.path.insert(0, str(tools))
    try:
        import check_model  # noqa: PLC0415 — loaded from the audited tree, by design
        return check_model
    except Exception as exc:  # pragma: no cover - import failure is environmental
        raise InventoryError(f"cannot import tools/check_model.py: {exc}") from exc
    finally:
        sys.path.remove(str(tools))


def _lexical_reference_counts(root: Path, short_names: set[str]) -> dict[str, int]:
    """Occurrences of each short name in cleaned lean/ beyond its declaration.

    A LEAD ONLY (the owner's measurement limit applies: textual, not
    proof-term, and qualified/short uses are pooled). It never classifies,
    never excludes, never shrinks anything.
    """
    from .leanscan import clean_source  # noqa: PLC0415

    patterns = {
        name: re.compile(rf"(?<![A-Za-z0-9_'!?]){re.escape(name)}(?![A-Za-z0-9_'!?])")
        for name in short_names
    }
    counts: dict[str, int] = dict.fromkeys(short_names, 0)
    for path in sorted((root / "lean").rglob("*.lean")):
        clean = clean_source(path.read_text())
        for name, pattern in patterns.items():
            counts[name] += len(pattern.findall(clean))
    return counts


@dataclass(frozen=True)
class Inventory:
    obligations: tuple[Obligation, ...]
    manifest_bound: int
    unclassified: int

    def by_identity(self) -> dict[str, Obligation]:
        return {o.identity: o for o in self.obligations}

    def by_name(self) -> dict[str, Obligation]:
        return {o.name: o for o in self.obligations}


def build_inventory(root: Path) -> Inventory:
    root = root.resolve()
    check_model = _load_check_model(root)

    manifest_records: dict[str, dict] = {}
    scanner_names_by_module: dict[str, set[str]] = {}
    for rel, prefix, manifest_rel in STATEMENT_MODULES:
        # The extraction itself, from the audited tool, against current source:
        records = check_model.statement_inventory(root / rel, prefix)
        manifest = json.loads((root / manifest_rel).read_text())
        if records != manifest:
            raise InventoryError(
                f"{manifest_rel} drifts from the {rel} extraction "
                "(statement edited without re-exporting the manifest)"
            )
        for record in records:
            if record["name"] in manifest_records:
                raise InventoryError(f"declaration inventory collides: {record['name']}")
            manifest_records[record["name"]] = record

    declarations = scan_tree_strict(root / "lean")
    refcounts = _lexical_reference_counts(root, {d.name.split(".")[-1] for d in declarations})

    obligations: list[Obligation] = []
    unclassified = 0
    seen_scan_names: set[str] = set()
    for decl in declarations:
        if decl.name in seen_scan_names:
            raise InventoryError(f"discovery found duplicate declaration name: {decl.name}")
        seen_scan_names.add(decl.name)
        record = manifest_records.get(decl.name)
        short_refs = max(0, refcounts.get(decl.name.split(".")[-1], 1) - 1)
        if record is not None:
            obligations.append(Obligation(
                name=decl.name,
                statementSha256=record["statementSha256"],
                classification="manifest-bound",
                status=record["status"],
                source=decl.source,
                line=decl.line,
                attributed=decl.attributed,
                references=short_refs,
            ))
        else:
            unclassified += 1
            obligations.append(Obligation(
                name=decl.name,
                statementSha256=decl.signatureSha256,
                classification="unclassified",
                status="UNCLASSIFIED",
                source=decl.source,
                line=decl.line,
                attributed=decl.attributed,
                references=short_refs,
            ))

    missing_from_scan = set(manifest_records) - seen_scan_names
    if missing_from_scan:
        raise InventoryError(
            "manifest declarations not found by discovery (tokenization or grammar gap): "
            + ", ".join(sorted(missing_from_scan))
        )

    return Inventory(
        obligations=tuple(sorted(obligations, key=lambda o: (o.source, o.line))),
        manifest_bound=len(manifest_records),
        unclassified=unclassified,
    )
