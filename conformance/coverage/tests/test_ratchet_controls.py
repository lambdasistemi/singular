"""The ratchet's own failure controls (issue #80; code-the-design skill list).

Each test arms one control against the real gate and asserts rejection FOR
THE INTENDED REASON — the regression kind or debt code must be the one the
control names, not merely a nonzero exit:

  remove a theorem mapping                -> mapping-removed
  stale a definition digest               -> stale-definition
  rename a row                            -> fail-closed unrecognized row
  remove a Then assertion                 -> vacuous-empty-then
  skip a test                             -> skipped-check
  present but not selected by the runner  -> unexecuted-check
  alias one test into two layers          -> duplicate-layer-identity
  offset a lost obligation with new cover -> mapping-removed despite additions
  vacuous generator                       -> vacuous-generator
  excessive discarding                    -> excessive-discards
  failing behavior relabelled expected    -> failing-check (no relabel exists)
  stale a statement (weakened invariant)  -> stale-binding + obligation-vanished
  theorem removal (denominator shrink)    -> obligation-vanished
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from singular_coverage.debt import UnknownRowError, compute_debt, find_stale_bindings, unknown_rows
from singular_coverage.inventory import build_inventory
from singular_coverage.ratchet import ratchet
from tests.fixtures import (
    REPO_ROOT,
    build_base_tree,
    build_variant,
    full_check,
    mapping_row,
    write_record,
)


class ControlCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        base = Path(self._tmp.name)
        self.tree = base / "tree-base"
        build_base_tree(self.tree)
        (self.tree / "src").mkdir()
        (self.tree / "src/Greeter.hs").write_text("-- implementation candidate\n")
        from singular_coverage.record import candidate_digest, definition_digest

        self.candidate = candidate_digest(self.tree, ("src",))
        self.greeter_digest = definition_digest(self.tree, "Singular.greeter")
        self.inventory = build_inventory(self.tree)

    def tearDown(self):
        self._tmp.cleanup()

    def base_record(self, *, with_mapping=True, with_layers=True):
        checks = []
        if with_layers:
            checks = [
                full_check(self.tree, layer="property", execution="exec-1",
                           check_id="c-prop", name="Singular.Statements.greeter_iff",
                           definition_digest=self.greeter_digest, candidate=self.candidate),
                full_check(self.tree, layer="integration-story", execution="exec-2",
                           check_id="c-story", name="Singular.Statements.greeter_iff",
                           definition_digest=self.greeter_digest, candidate=self.candidate),
            ]
        mappings = [mapping_row(self.tree, "Singular.Statements.greeter_iff", "S-1")] \
            if with_mapping else []
        return {"schema": "singular-coverage-record-v1", "checks": checks, "mappings": mappings}

    def current_record(self, checks, mappings):
        return {"schema": "singular-coverage-record-v1", "checks": checks, "mappings": mappings}

    def run_ratchet(self, base, current, tree=None):
        tree = tree or self.tree
        # the base record is cut against the base tree; the current record
        # against the (possibly mutated) tree under test
        base_p = write_record(self.tree, base, "base.json")
        cur_p = write_record(tree, current, "current.json")
        inv = build_inventory(tree)
        return ratchet(inv, load(base_p), load(cur_p), tree)

    def kinds(self, result):
        return {r.kind for r in result.regressions}


def load(path):
    from singular_coverage.record import load_record

    return load_record(path)


class PositiveBaseline(ControlCase):
    """Before arming the controls: a covered obligation in a stable world pays."""

    def test_no_regression_when_current_equals_base(self):
        result = self.run_ratchet(self.base_record(), self.base_record())
        self.assertTrue(result.passed, result.regressions)

    def test_covered_obligation_achieves_both_layers_and_passes_nonvacuity(self):
        from singular_coverage.debt import compute_debt

        debts = compute_debt(self.inventory, load(write_record(self.tree, self.base_record())), self.tree)
        greeter = next(d for d in debts if d.name == "Singular.Statements.greeter_iff")
        self.assertFalse(greeter.mapping_debt)
        self.assertFalse(greeter.layer_debt)
        self.assertEqual(greeter.layers_achieved, frozenset({"property", "integration-story"}))
        self.assertEqual(greeter.execution_findings, ())
        # ...but strict completion stays INCOMPLETE: unclassified debt remains
        from singular_coverage.completion import completion

        verdict = completion(self.inventory, load(write_record(self.tree, self.base_record())), debts)
        self.assertEqual(verdict.verdict, "INCOMPLETE")
        self.assertIn("Singular.helper.dotted", verdict.unclassified)


class MappingControls(ControlCase):
    def test_remove_a_theorem_mapping(self):
        current = self.base_record()
        current["mappings"] = []
        result = self.run_ratchet(self.base_record(), current)
        self.assertFalse(result.passed)
        self.assertIn("mapping-removed", self.kinds(result))
        target = [r for r in result.regressions if r.kind == "mapping-removed"]
        self.assertTrue(any("greeter_iff" in r.obligation for r in target),
                        "regression must name the obligation that lost its mapping")
        self.assertEqual(result.additions, (), "no additions exist in this scenario")

    def test_offset_a_lost_obligation_with_unrelated_new_coverage(self):
        current = self.base_record()
        current["mappings"] = []
        current["checks"] = current["checks"] + [
            full_check(self.tree, layer="property", execution="exec-3",
                       check_id="c-prop-size", name="Singular.Statements.size_bound",
                       definition_digest=self.greeter_digest, candidate=self.candidate),
            full_check(self.tree, layer="integration-story", execution="exec-4",
                       check_id="c-story-size", name="Singular.Statements.size_bound",
                       definition_digest=self.greeter_digest, candidate=self.candidate),
        ]
        result = self.run_ratchet(self.base_record(), current)
        self.assertFalse(result.passed, "new coverage elsewhere must not offset the lost mapping")
        self.assertIn("mapping-removed", self.kinds(result))
        self.assertEqual(len(result.additions), 1, "additions are reported per identity, never offsetting")


class RowIdentityControls(ControlCase):
    def test_rename_a_row_fails_closed(self):
        current = self.base_record()
        current["checks"][0]["obligation"] = "Singular.Statements.greeter_iff_renamed"
        with self.assertRaises(UnknownRowError) as ctx:
            unknown_rows(self.inventory, load(write_record(self.tree, current)))
        self.assertIn("unrecognized obligation row", str(ctx.exception))

    def test_theorem_removal_cannot_shrink_the_denominator(self):
        tree = build_variant(self.tree, "theorem-removed")
        result = self.run_ratchet(self.base_record(), self.base_record(), tree=tree)
        self.assertFalse(result.passed)
        self.assertIn("obligation-vanished", self.kinds(result))
        vanished = [r for r in result.regressions if r.kind == "obligation-vanished"]
        self.assertTrue(any("size_bound" in r.obligation for r in vanished),
                        "the removed theorem must be named")


class EvidenceControls(ControlCase):
    def control_check(self, **evidence_overrides):
        check = full_check(self.tree, layer="property", execution="exec-1",
                           check_id="c-prop", name="Singular.Statements.greeter_iff",
                           definition_digest=self.greeter_digest, candidate=self.candidate)
        check["evidence"].update(evidence_overrides)
        return check

    def assert_execution_code(self, record, code):
        from singular_coverage.debt import compute_debt

        debts = compute_debt(self.inventory, load(write_record(self.tree, record)), self.tree)
        greeter = next(d for d in debts if d.name == "Singular.Statements.greeter_iff")
        codes = {f.code for f in greeter.execution_findings}
        self.assertIn(code, codes, f"expected {code}, got {greeter.execution_findings}")
        self.assertTrue(greeter.layer_debt, "the control must strip the layer it fakes")
        return greeter

    def test_skip_a_test(self):
        current = self.base_record()
        current["checks"][0]["evidence"]["status"] = "skipped"
        self.assert_execution_code(current, "skipped-check")

    def test_present_but_not_selected_by_the_runner(self):
        current = self.base_record()
        current["checks"][0]["evidence"]["status"] = "unexecuted"
        self.assert_execution_code(current, "unexecuted-check")

    def test_remove_a_then_assertion(self):
        current = self.base_record()
        current["checks"][0]["evidence"]["thenAssertions"] = 0
        self.assert_execution_code(current, "vacuous-empty-then")

    def test_generator_that_never_reaches_its_precondition(self):
        current = self.base_record()
        current["checks"][0]["evidence"]["discards"] = current["checks"][0]["evidence"]["cases"]
        self.assert_execution_code(current, "vacuous-generator")

    def test_excessive_discarding(self):
        current = self.base_record()
        current["checks"][0]["evidence"]["cases"] = 10
        current["checks"][0]["evidence"]["discards"] = 8
        self.assert_execution_code(current, "excessive-discards")

    def test_stale_result_reused_for_changed_code(self):
        tree = build_variant(self.tree, "definition-changed")
        result = self.run_ratchet(self.base_record(), self.base_record(), tree=tree)
        self.assertFalse(result.passed, "base evidence must not keep paying over changed code")
        self.assertIn("layer-lost", self.kinds(result))
        from singular_coverage.debt import compute_debt

        debts = compute_debt(build_inventory(tree), load(write_record(tree, self.base_record())), tree)
        greeter = next(d for d in debts if d.name == "Singular.Statements.greeter_iff")
        self.assertIn("stale-definition", {f.code for f in greeter.execution_findings})

    def test_failing_behavior_relabelled_expected(self):
        current = self.base_record()
        current["checks"][0]["evidence"]["status"] = "fail"
        current["checks"][0]["evidence"]["resultDigest"] = "b" * 64
        self.assert_execution_code(current, "failing-check")
        # the schema has no expected-failure escape hatch: PASS is computed
        # from selected executed evidence, never typed. A relabelled record
        # would need a field that does not exist and cannot exist.
        sample = current["checks"][0]
        self.assertNotIn("expected", json.dumps(sample).lower())
        # A hand-written PASS record without the executed bindings cannot even
        # load: pass evidence requires a result digest and a candidate binding.
        from singular_coverage.record import RecordError, load_record

        forged = json.loads(json.dumps(current))
        forged["checks"][0]["evidence"]["status"] = "pass"
        forged["checks"][0]["evidence"]["resultDigest"] = ""
        with self.assertRaises(RecordError):
            load_record(write_record(self.tree, forged))

    def test_invalid_discrimination_control(self):
        current = self.base_record()
        current["checks"][0]["control"] = {
            "kind": "mutation", "target": "Singular.greeter", "status": "invalid",
        }
        self.assert_execution_code(current, "invalid-control")

    def test_alias_one_test_into_two_layers(self):
        current = self.base_record()
        # the integration-story check is a wrapper around the SAME execution
        current["checks"][1]["executionIdentity"] = current["checks"][0]["executionIdentity"]
        self.assert_execution_code(current, "duplicate-layer-identity")


class StatementEditControls(ControlCase):
    def test_weakened_invariant_invalidates_coverage_and_does_not_inherit(self):
        tree = build_variant(self.tree, "statement-edit")
        base = self.base_record()
        base_p = write_record(tree, base, "base.json")
        cur_p = write_record(tree, base, "current.json")
        inv = build_inventory(tree)
        result = ratchet(inv, load(base_p), load(cur_p), tree)
        self.assertFalse(result.passed, "a weakened statement invalidates its coverage")
        self.assertIn("stale-binding", self.kinds(result))
        self.assertIn("obligation-vanished", self.kinds(result))
        # the NEW identity carries no inherited coverage
        debts = compute_debt(inv, load(cur_p), tree)
        greeter = next(d for d in debts if d.name == "Singular.Statements.greeter_iff")
        self.assertTrue(greeter.mapping_debt, "new identity must not inherit the old mapping")
        self.assertTrue(greeter.layer_debt, "new identity must not inherit the layers")

    def test_stale_binding_detected_as_invalidation(self):
        tree = build_variant(self.tree, "statement-edit")
        inv = build_inventory(tree)
        stale = find_stale_bindings(inv, load(write_record(tree, self.base_record())))
        self.assertTrue(any("greeter_iff" in obligation for _k, obligation, _d in stale))


if __name__ == "__main__":
    unittest.main()
