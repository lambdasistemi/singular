"""Inventory reconciliation controls: manifest drift, collision, and the
reuse of tools/check_model.py's extraction as the identity source."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from singular_coverage.inventory import InventoryError, build_inventory
from tests.fixtures import REPO_ROOT, build_base_tree, export_manifests


class RealInventoryTest(unittest.TestCase):
    def test_real_tree_reconciles(self):
        # Re-frozen on integrating the reviewed naming hook/empty-fold
        # Lean (four theorems; see test_leanscan re-freeze note):
        # 113 = 109 + 4, unclassified unchanged.
        inv = build_inventory(REPO_ROOT)
        self.assertEqual(inv.manifest_bound, 113)
        self.assertEqual(inv.unclassified, 83)
        self.assertEqual(inv.manifest_bound + inv.unclassified, 196)

    def test_real_manifests_match_extraction_byte_for_byte(self):
        # build_inventory re-runs check_model.statement_inventory and compares
        # with the committed manifests; it raises on drift, so reaching here
        # is the assertion. Assert a couple of exact identities too.
        inv = build_inventory(REPO_ROOT)
        by_name = inv.by_name()
        self.assertIn("Singular.Statements.supply_conservation", by_name)
        self.assertIn("Singular.Inv.fresh_id", by_name)
        self.assertEqual(by_name["Singular.Inv.fresh_id"].classification, "unclassified")
        self.assertEqual(
            by_name["Singular.Statements.supply_conservation"].classification,
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
            self.assertEqual(inv.unclassified, 3)
            self.assertIn("Singular.Statements.greeter_iff", names)
            self.assertIn("Singular.helper.dotted", names)
            self.assertIn("Singular.primed_helper'", names)
            self.assertIn("Singular.attributed_zero", names)

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


if __name__ == "__main__":
    unittest.main()
