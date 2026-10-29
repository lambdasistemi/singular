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
        # The retained reference library stays in the discovered denominator.
        inv = build_inventory(REPO_ROOT)
        self.assertEqual(inv.manifest_bound, 0)
        self.assertEqual(inv.unclassified, 58)
        self.assertEqual(inv.manifest_bound + inv.unclassified, 58)

    def test_real_manifests_match_extraction_byte_for_byte(self):
        # build_inventory re-runs check_model.statement_inventory and compares
        # with the committed manifests; it raises on drift, so reaching here
        # is the assertion. Assert a couple of exact identities too.
        inv = build_inventory(REPO_ROOT)
        by_name = inv.by_name()
        self.assertIn("Singular.rejectionAccepted_effect", by_name)
        self.assertIn("Singular.step_ok_consistent", by_name)
        self.assertEqual(
            by_name["Singular.step_ok_consistent"].classification, "unclassified"
        )
        self.assertEqual(
            by_name["Singular.rejectionAccepted_effect"].classification,
            "unclassified",
        )


class FixtureInventoryTest(unittest.TestCase):
    def declare_retirement(self, root):
        from singular_coverage.inventory import RETIRED_SURFACES, STATEMENT_MODULES

        source, _, manifest = STATEMENT_MODULES[0]
        records = json.loads((root / manifest).read_text())
        path = root / RETIRED_SURFACES
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(
                [
                    {
                        "source": source,
                        "manifest": manifest,
                        "identities": [
                            r["name"] + "@" + r["statementSha256"] for r in records
                        ],
                    }
                ]
            )
        )
        return root / source, root / manifest

    def test_declared_retired_pair_can_leave_without_hiding_other_declarations(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            build_base_tree(root)
            source, manifest = self.declare_retirement(root)
            before = build_inventory(root)
            source.unlink()
            manifest.unlink()
            after = build_inventory(root)
            self.assertEqual(len(before.obligations) - len(after.obligations), 2)
            self.assertEqual(after.unclassified, before.unclassified)

    def test_an_undeclared_absent_pair_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            build_base_tree(root)
            (root / "lean/Singular/Statements.lean").unlink()
            (root / "lean/theorem-debt.json").unlink()
            with self.assertRaisesRegex(InventoryError, "undeclared absent"):
                build_inventory(root)

    def test_one_sided_retirement_is_refused_in_both_directions(self):
        for missing in (0, 1):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                build_base_tree(root)
                pair = self.declare_retirement(root)
                pair[missing].unlink()
                with self.assertRaisesRegex(InventoryError, "one-sided"):
                    build_inventory(root)

    def test_present_retired_surface_keeps_its_live_identities(self):
        from singular_coverage.inventory import RETIRED_SURFACES

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            build_base_tree(root)
            before = build_inventory(root)
            self.declare_retirement(root)
            path = root / RETIRED_SURFACES
            records = json.loads(path.read_text())
            records[0]["identities"][0] = (
                records[0]["identities"][0].split("@")[0] + "@" + "0" * 64
            )
            path.write_text(json.dumps(records))
            after = build_inventory(root)
            self.assertEqual(after.obligations, before.obligations)
            self.assertEqual(after.manifest_bound, before.manifest_bound)
            self.assertEqual(after.unclassified, before.unclassified)

    def test_statements_split_across_modules_keep_their_identities(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            build_base_tree(root)
            before = build_inventory(root).by_name()
            facade = root / "lean/Singular/Statements.lean"
            sources = facade.with_suffix("")
            sources.mkdir()
            text = facade.read_text()
            split = text.index("/-- A second public statement")
            (sources / "First.lean").write_text(
                text[:split] + "end Statements\nend Singular\n"
            )
            (sources / "Second.lean").write_text(
                "namespace Singular\nnamespace Statements\n" + text[split:]
            )
            facade.write_text(
                "import Singular.Statements.First\nimport Singular.Statements.Second\n"
            )
            after = build_inventory(root).by_name()
            self.assertEqual(set(before), set(after))
            for name, old in before.items():
                self.assertEqual(old.identity, after[name].identity)
                self.assertEqual(old.classification, after[name].classification)

    def test_unregistered_statement_in_a_new_module_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            build_base_tree(root)
            sources = root / "lean/Singular/Statements"
            sources.mkdir()
            (sources / "Unproved.lean").write_text(
                "namespace Singular.Statements\n"
                "theorem unproved : False := by sorry\n"
                "end Singular.Statements\n"
            )
            with self.assertRaisesRegex(InventoryError, "drifts"):
                build_inventory(root)

    def test_fixture_tree_populates_both_classes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            build_base_tree(root)
            inv = build_inventory(root)
            names = inv.by_name()
            self.assertEqual(inv.manifest_bound, 6)
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
                before.statementSha256,
                after.statementSha256,
                "editing a statement must produce a new obligation identity",
            )


class CorpusTheoremBindingTest(unittest.TestCase):
    """Synthetic corpus rows exercise the retained identity-binding checker.

    The retired product corpora are not subjects of this harness test.
    Identities come from the real extraction over the fixture source.
    """

    def live(self) -> tuple[list[tuple[str, dict]], dict[str, Obligation]]:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            build_base_tree(root)
            by_name = build_inventory(root).by_name()
            corpus = {
                "cases": [
                    {"theorem": o.name, "statementSha256": o.statementSha256}
                    for o in by_name.values()
                    if o.classification == "manifest-bound"
                ]
            }
        return corpus_theorem_rows(corpus), by_name

    def test_every_corpus_theorem_row_binds_the_live_statement_identity(self):
        rows, by_name = self.live()
        self.assertGreater(
            len(rows),
            0,
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
                self.assertIn(
                    f"{path}: {row['theorem']} cites no statementSha256", violations
                )

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
