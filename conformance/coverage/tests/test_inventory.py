"""Inventory reconciliation controls: manifest drift, collision, the reuse of
tools/check_model.py's extraction as the identity source, and the binding of
every exported corpus row to the theorem identity it cites."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from singular_coverage.inventory import InventoryError, Obligation, build_inventory
from tests.fixtures import REPO_ROOT, build_base_tree, export_manifests

CORPUS = "lean/corpus.json"


def corpus_theorem_rows(node: object, path: str = "$") -> list[tuple[str, dict]]:
    """Every object anywhere in a corpus that cites a theorem, with its path.

    Discovery, not enumeration: a row family added to the corpus later is
    covered the day it is exported, without this file being edited to keep
    covering its own subject.
    """
    rows: list[tuple[str, dict]] = []
    if isinstance(node, dict):
        if "theorem" in node:
            rows.append((path, node))
        for key, value in node.items():
            rows.extend(corpus_theorem_rows(value, f"{path}.{key}"))
    elif isinstance(node, list):
        for index, value in enumerate(node):
            rows.extend(corpus_theorem_rows(value, f"{path}[{index}]"))
    return rows


def binding_violations(
    rows: list[tuple[str, dict]], by_name: dict[str, Obligation]
) -> list[str]:
    """Rows citing an unknown theorem, no digest, or a digest that has moved.

    A row that names a theorem but carries no ``statementSha256`` is a
    violation, never a skip: dropping it would turn an occurrence into a
    silently smaller denominator.
    """
    violations: list[str] = []
    for path, row in rows:
        name = row["theorem"]
        obligation = by_name.get(name)
        if obligation is None:
            violations.append(f"{path}: {name} is not a declared obligation")
            continue
        pinned = row.get("statementSha256")
        if pinned is None:
            violations.append(f"{path}: {name} cites no statementSha256")
        elif pinned != obligation.statementSha256:
            violations.append(
                f"{path}: {name} pins {pinned} but its live identity is "
                f"{obligation.statementSha256}"
            )
    return violations


class RealInventoryTest(unittest.TestCase):
    def test_real_tree_reconciles(self):
        # The statement that no fold requires a signer adds one manifest-bound
        # obligation: 93 = 50 + 43, previously 92 = 49 + 43. The registry has
        # 29 statements; naming, lifecycle and wire retain 7, 9 and 5.
        inv = build_inventory(REPO_ROOT)
        self.assertEqual(inv.manifest_bound, 50)
        self.assertEqual(inv.unclassified, 43)
        self.assertEqual(inv.manifest_bound + inv.unclassified, 93)

    def test_real_manifests_match_extraction_byte_for_byte(self):
        # build_inventory re-runs check_model.statement_inventory and compares
        # with the committed manifests; it raises on drift, so reaching here
        # is the assertion. Assert a couple of exact identities too.
        inv = build_inventory(REPO_ROOT)
        by_name = inv.by_name()
        self.assertIn("Singular.Statements.biconditional_supply_sync", by_name)
        self.assertIn("Singular.step_ok_consistent", by_name)
        self.assertEqual(by_name["Singular.step_ok_consistent"].classification, "unclassified")
        self.assertEqual(
            by_name["Singular.Statements.biconditional_supply_sync"].classification,
            "manifest-bound",
        )


class FixtureInventoryTest(unittest.TestCase):
    def test_fixture_tree_populates_both_classes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            build_base_tree(root)
            inv = build_inventory(root)
            names = inv.by_name()
            self.assertEqual(inv.manifest_bound, 5)
            self.assertEqual(inv.unclassified, 5)
            self.assertIn("Singular.Statements.greeter_iff", names)
            self.assertIn("Singular.helper.dotted", names)
            self.assertIn("Singular.primed_helper'", names)
            self.assertIn("Singular.attributed_zero", names)
            self.assertIn("Singular.find?_filter_key_ne", names)
            self.assertIn("Singular.entry_key", names)

    def test_manifest_drift_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            build_base_tree(root)
            manifest_path = root / "lean/theorem-debt.json"
            manifest = json.loads(manifest_path.read_text())
            manifest[0]["statementSha256"] = "0" * 64
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
            with self.assertRaises(InventoryError) as ctx:
                build_inventory(root)
            self.assertIn("drifts", str(ctx.exception))

    def test_reexport_heals_drift_but_changes_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            build_base_tree(root)
            before = build_inventory(root).by_name()["Singular.Statements.greeter_iff"]
            src = root / "lean/Singular/Statements.lean"
            edited = src.read_text().replace("(n : Nat) (h : n > 0)", "(n : Nat)")
            src.write_text(edited)
            export_manifests(root)  # the honest re-export after a statement edit
            after = build_inventory(root).by_name()["Singular.Statements.greeter_iff"]
            self.assertNotEqual(
                before.statementSha256, after.statementSha256,
                "editing a statement must produce a new obligation identity",
            )


class CorpusTheoremBindingTest(unittest.TestCase):
    """Exported corpus rows cite the theorem identity the source has today.

    The digests the corpus carries are written into lean/Main.lean by hand:
    the corpus binary runs under nix/model.nix with an arbitrary cwd and
    cannot read lean/theorem-debt.json to derive them. Without a permanent
    check they are pinned only by whichever ticket gate happened to be frozen
    when they were added, and that gate retires with its ticket. Here they are
    compared against tools/check_model.py's own extraction from the source, so
    a statement edit that leaves a row behind fails rather than shipping a
    stale proof identity beside a changed theorem.
    """

    def live(self) -> tuple[list[tuple[str, dict]], dict[str, Obligation]]:
        corpus = json.loads((REPO_ROOT / CORPUS).read_text())
        return corpus_theorem_rows(corpus), build_inventory(REPO_ROOT).by_name()

    def test_every_corpus_theorem_row_binds_the_live_statement_identity(self):
        rows, by_name = self.live()
        self.assertGreater(
            len(rows), 0,
            "no corpus row cites a theorem: the quantifier has nothing to range "
            "over and would report success having compared nothing",
        )
        self.assertEqual(binding_violations(rows, by_name), [])

    def test_control_a_drifted_digest_is_caught_in_every_row(self):
        """Per row, so a comparator that only reads the first one dies here."""
        rows, by_name = self.live()
        self.assertGreater(len(rows), 0)
        for path, row in rows:
            with self.subTest(row=path):
                held = row["statementSha256"]
                row["statementSha256"] = "0" * 64
                try:
                    violations = binding_violations(rows, by_name)
                finally:
                    row["statementSha256"] = held
                self.assertTrue(
                    any(v.startswith(f"{path}: ") for v in violations),
                    f"a moved digest at {path} was not reported",
                )

    def test_control_a_row_without_a_digest_is_caught_in_every_row(self):
        rows, by_name = self.live()
        self.assertGreater(len(rows), 0)
        for path, row in rows:
            with self.subTest(row=path):
                held = row.pop("statementSha256")
                try:
                    violations = binding_violations(rows, by_name)
                finally:
                    row["statementSha256"] = held
                self.assertIn(f"{path}: {row['theorem']} cites no statementSha256", violations)

    def test_control_a_row_citing_an_undeclared_theorem_is_caught(self):
        rows, by_name = self.live()
        self.assertGreater(len(rows), 0)
        path, row = rows[0]
        held = row["theorem"]
        row["theorem"] = "Singular.Statements.no_such_theorem"
        try:
            violations = binding_violations(rows, by_name)
        finally:
            row["theorem"] = held
        self.assertIn(
            f"{path}: Singular.Statements.no_such_theorem is not a declared obligation",
            violations,
        )

    def test_control_the_extent_guard_can_fire(self):
        """The non-empty guard is itself falsified: a corpus citing no theorem
        must discover nothing, so the guard above would fail rather than pass
        over an empty range."""
        self.assertEqual(
            corpus_theorem_rows({"schema": "x", "cases": [{"id": "C1"}], "folds": []}),
            [],
        )


if __name__ == "__main__":
    unittest.main()
