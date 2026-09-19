"""Tokenizer and scanner controls — the tests that would have caught the
epic owner's measurement errors (dotted and primed names split or dropped)
plus the attributed-declaration miss this slice found."""

from __future__ import annotations

import sys
import tempfile
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


class TrickyNameGrammarTest(unittest.TestCase):
    """The identifier shapes that have each defeated the scanner at least once.

    This was asserted against the product tree until #156. That made a grammar
    regression test depend on the model happening to contain a primed name — and
    when registry mode retired those declarations the tree kept no primed and no
    `?`-carrying identifier at all, so re-pointing the test at names that exist
    today would have quietly deleted coverage for three real scanner bugs. The
    subjects now live in the synthetic fixture tree, where the model cannot take
    them away.
    """

    def test_tricky_names_are_found_whole(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            build_base_tree(root)
            decls = {d.name for d in scan_tree_strict(root / "lean")}
        for name in (
            "Singular.helper.dotted",        # dotted
            "Singular.primed_helper'",       # primed
            "Singular.find?_filter_key_ne",  # '?'
            "Singular.attributed_zero",      # @[simp]-attributed, inline
            "Singular.entry_key",            # @[simp]-attributed, across lines
        ):
            self.assertIn(name, decls)

    def test_the_guard_can_fail(self):
        """A grammar that drops a shape must be caught, not merely trusted."""
        clean = clean_source("namespace Singular\ntheorem plain (n : Nat) : n = n := rfl\nend Singular\n")
        decls = {d.name for d in scan_text(clean, "lean/Singular/Lemmas.lean")}
        self.assertNotIn("Singular.primed_helper'", decls)


class RealTreeDiscoveryTest(unittest.TestCase):
    """The frozen tree at base: 85 = 48 manifest-bound + 37 unclassified.

    Re-frozen on #177's transaction row. The 48 are the registry's 27
    statements plus naming's 7, its lifecycle's 9 and its wire encoding's 5; the
    37 are the lemmas and effect equations they are proved from. The registry's
    26 became 27 with update_terminal_transaction_row, so this denominator grew
    by exactly the one statement the slice added. The #157 base was 82 = 45 + 37, the #156
    base 79 = 42 + 37 and before it 196 = 113 + 83, retired with the model it
    described — the disposition of all 44 of those base declarations is in
    docs/model-ledger.md (1 carried, 3 renamed, 40 retired), so the earlier
    shrinking denominator is the recorded retirement and not an undiscovered
    population.
    """

    def test_population_at_base(self):
        inv_root = REPO_ROOT
        decls = scan_tree_strict(inv_root / "lean")
        self.assertEqual(len(decls), 85, "base population drifted; the denominator must be re-examined")
        statements = [d for d in decls if d.source.endswith("Statements.lean")]
        self.assertEqual(len(statements), 48)

    def test_attributed_count_at_base(self):
        decls = scan_tree_strict(REPO_ROOT / "lean")
        self.assertEqual(sum(1 for d in decls if d.attributed), 3)


if __name__ == "__main__":
    unittest.main()
