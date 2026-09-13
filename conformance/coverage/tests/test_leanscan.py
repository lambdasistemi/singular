"""Tokenizer and scanner controls — the tests that would have caught the
epic owner's measurement errors (dotted and primed names split or dropped)
plus the attributed-declaration miss this slice found."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tests.fixtures import REPO_ROOT, build_base_tree, build_variant
from singular_coverage.leanscan import (
    Declaration,
    clean_source,
    keyword_accounting,
    scan_text,
    scan_tree_strict,
)


class TokenizerTest(unittest.TestCase):
    def test_dotted_name_stays_whole(self):
        clean = clean_source("namespace Singular\ntheorem Inv.fresh_id (s : State) : True := by\n  trivial\n")
        decls = scan_text(clean, "x.lean")
        self.assertEqual([d.name for d in decls], ["Singular.Inv.fresh_id"])

    def test_primed_name_stays_whole(self):
        clean = clean_source("namespace Singular\ntheorem not_mem_of_nodup_append' (n : Nat) : n = n := rfl\n")
        decls = scan_text(clean, "x.lean")
        self.assertEqual(decls[0].name, "Singular.not_mem_of_nodup_append'")

    def test_question_mark_name_stays_whole(self):
        clean = clean_source("theorem find?_filter_key_ne (l : List Nat) : True := rfl")
        self.assertEqual(scan_text(clean, "x.lean")[0].name, "find?_filter_key_ne")

    def test_attributed_declaration_is_recognized_and_flagged(self):
        clean = clean_source("namespace Singular\n@[simp] theorem entry_key (s : State) : True := rfl\n")
        decls = scan_text(clean, "x.lean")
        self.assertEqual(decls[0].name, "Singular.entry_key")
        self.assertTrue(decls[0].attributed)

    def test_comments_and_strings_never_yield_declarations(self):
        src = """\
/-! theorem fake_one : True := by trivial -/
-- theorem fake_two : True := by trivial
namespace Singular
theorem real_one : True := by trivial
example : String := "theorem fake_three : True"
theorem real_two : True := rfl
end Singular
"""
        decls = scan_text(clean_source(src), "x.lean")
        self.assertEqual([d.name for d in decls], ["Singular.real_one", "Singular.real_two"])

    def test_keyword_accounting_fails_closed_on_unknown_grammar(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            build_base_tree(root)
            tree = build_variant(root, "unknown-grammar")
            with self.assertRaises(ValueError) as ctx:
                scan_tree_strict(tree / "lean")
            self.assertIn("grammar incomplete", str(ctx.exception))


class RealTreeDiscoveryTest(unittest.TestCase):
    """The frozen tree at base: 196 = 113 manifest-bound + 83 unclassified.

    Re-frozen on integrating the reviewed naming hook/empty-fold Lean
    (four theorems: empty_fold_never_ok, empty_fold_error,
    nonempty_fold_invokes_consumer, substituted_consumer_pin_refused;
    fold_iff restated with items-nonempty). Prior base 192 = 109 + 83."""

    def test_population_at_base(self):
        inv_root = REPO_ROOT
        decls = scan_tree_strict(inv_root / "lean")
        self.assertEqual(len(decls), 196, "base population drifted; the denominator must be re-examined")
        statements = [d for d in decls if d.source.endswith("Statements.lean")]
        self.assertEqual(len(statements), 113)

    def test_owner_reported_tricky_names_are_found_whole(self):
        decls = {d.name for d in scan_tree_strict(REPO_ROOT / "lean")}
        for name in (
            "Singular.Inv.fresh_id",            # dotted (owner's earlier error)
            "Singular.not_mem_of_nodup_append'",  # primed (owner's earlier error)
            "Singular.find?_filter_key_ne",     # '?'
            "Singular.requireSome_none",        # @[simp]-attributed (this slice's finding)
            "Singular.entry_key",               # @[simp]-attributed, multi-line
        ):
            self.assertIn(name, decls)

    def test_attributed_count_at_base(self):
        decls = scan_tree_strict(REPO_ROOT / "lean")
        self.assertEqual(sum(1 for d in decls if d.attributed), 21)


if __name__ == "__main__":
    unittest.main()
