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
        # Re-frozen on #156's registry-mode model: 79 = 42 manifest-bound + 37
        # unclassified. The 42 are the registry's 24 statements plus naming's 7,
        # its lifecycle's 6 and its wire encoding's 5; the 37 are the lemmas and
        # effect equations they are proved from. The previous base was
        # 196 = 113 + 83 and is retired with the model it described — the
        # disposition of all 44 base declarations is in docs/model-ledger.md
        # (1 carried, 3 renamed, 40 retired).
        inv = build_inventory(REPO_ROOT)
        self.assertEqual(inv.manifest_bound, 42)
        self.assertEqual(inv.unclassified, 37)
        self.assertEqual(inv.manifest_bound + inv.unclassified, 79)

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


if __name__ == "__main__":
    unittest.main()
