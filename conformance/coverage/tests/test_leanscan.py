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
    """The frozen tree: 107 = 56 manifest-bound + 51 unclassified.

    The registry's 35 statements include the absent-insertion transaction
    row, the statement that no fold requires a signer, the four statements
    of where every exit's deposit goes, the statement that every
    transaction an exit builds settles what it owes and the statement that
    a retract pays exactly its obligations; naming contributes 7, lifecycle
    9 and wire encoding 5. Five helpers were added: the two spellings of the
    fold's transaction from its step and the three lemmas settling one
    payment; three more read a retraction's bound return as its largest
    output. The predecessor populations were 104 = 56 + 48 and 97 = 54 + 43.
    """

    def test_population_at_base(self):
        inv_root = REPO_ROOT
        decls = scan_tree_strict(inv_root / "lean")
        self.assertEqual(len(decls), 107, "base population drifted; the denominator must be re-examined")
        statements = [d for d in decls if d.source.endswith("Statements.lean")]
        self.assertEqual(len(statements), 56)

    def test_attributed_count_at_base(self):
        # The fourth is the @[simp] on trieGet_erase_eq.
        decls = scan_tree_strict(REPO_ROOT / "lean")
        self.assertEqual(sum(1 for d in decls if d.attributed), 4)


if __name__ == "__main__":
    unittest.main()
