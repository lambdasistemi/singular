use aiken/merkle_patricia_forestry as mpf
use lib
use registry/trie
use registry_fixtures as fx

// ----------------------------------------------------------------------------
// The names of the termination trie faults
// ----------------------------------------------------------------------------
//
// #177 I177-CHAIN: the `updateTerminal` transition of the trie refuses a key
// the trie does not bind at all (`key-unknown`), a key bound `Absent`
// (`not-booked`) and a key bound `Terminal` (`terminal-immutable`), at the
// validator's own named construction site (`trie.terminalFault`) BEFORE the
// library is reached: `mpf.update` would die inside the library on a proof
// that does not match the leaf, so the attributable refusal has to happen
// earlier. An Aiken test cannot read a `trace` back, so each name is asserted
// at the single construction site the validator itself reads.
//
// CP2: the fold rows of this file are retired with the legacy edge-only
// `updateTerminal` request, whose witness was a wallet-held token and whose
// deposit went back to the booker. A termination now folds from its pending
// request, which holds the key's singular tag and is burned with it
// (`tagged_fold.tests.ak`):
//
// - `update_terminal_retires_the_active_token` and
//   `the_trie_fault_control_accepts` are
//   `tagged_fold_state_folds_a_termination_after_both_windows`;
// - `unknown_key_refuses_cleanly`, `absent_key_refuses_cleanly` and
//   `terminal_key_refuses_cleanly` are
//   `tagged_fold_termination_refuses_a_key_the_trie_does_not_bind`,
//   `..._a_key_never_booked` and `..._a_key_already_terminal`, which assert
//   the reasons below through the real state spend;
// - `without_the_active_witness_refuses_cleanly` and
//   `another_keys_witness_refuses_cleanly` are
//   `tagged_fold_refuses_a_termination_without_its_singular_tag` (missing),
//   `tagged_fold_termination_refuses_an_unburned_singular_tag` (not burned),
//   `tagged_fold_refuses_a_termination_holding_another_keys_singular_tag` (the
//   wrong key's tag in the request) and
//   `tagged_fold_termination_refuses_a_burn_of_another_keys_singular_tag` (the
//   wrong key's tag burned); the witness is the request's own singular tag, not a
//   wallet input;
// - `a_surviving_active_carrier_refuses_cleanly` is
//   `tagged_fold_termination_refuses_a_singular_tag_that_survives`;
// - `the_witness_control_accepts` and `the_surviving_carrier_control_accepts`
//   are the same accepting fold.

test unknown_key_reason_is_key_unknown() {
  trie.terminalFault(mpf.from_root(fx.emptyRoot()), fx.keyA, []) == Some(
    @"key-unknown",
  )
}

test absent_key_reason_is_not_booked() {
  trie.terminalFault(
    mpf.from_root(fx.oneLeaf(fx.keyA, fx.absentLeaf)),
    fx.keyA,
    [],
  ) == Some(@"not-booked")
}

test terminal_key_reason_is_terminal_immutable() {
  trie.terminalFault(
    mpf.from_root(fx.oneLeaf(fx.keyA, fx.terminalLeaf)),
    fx.keyA,
    [],
  ) == Some(@"terminal-immutable")
}

/// An `Active` leaf is NOT a trie fault: the termination proceeds. Without
/// this row every answer could have become a refusal.
test an_active_leaf_is_not_a_trie_fault() {
  trie.terminalFault(
    mpf.from_root(fx.oneLeaf(fx.keyA, fx.activeLeaf)),
    fx.keyA,
    [],
  ) == None
}

/// The reasons are pairwise distinct, asserted by NAME rather than by
/// inequality.
test the_reasons_are_distinct_names() {
  and {
    trie.terminalFault(mpf.from_root(fx.emptyRoot()), fx.keyA, []) == Some(
      @"key-unknown",
    ),
    trie.terminalFault(
      mpf.from_root(fx.oneLeaf(fx.keyA, fx.absentLeaf)),
      fx.keyA,
      [],
    ) == Some(@"not-booked"),
    trie.terminalFault(
      mpf.from_root(fx.oneLeaf(fx.keyA, fx.terminalLeaf)),
      fx.keyA,
      [],
    ) == Some(@"terminal-immutable"),
    lib.occupiedRefusal() == Some(@"key-exists"),
    lib.mintRefusal() == Some(@"net-mint-mismatch"),
  }
}
