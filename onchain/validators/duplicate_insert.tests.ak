use cardano/assets.{merge}
use lib
use registry_fixtures as fx

// ----------------------------------------------------------------------------
// The names of the insert refusals
// ----------------------------------------------------------------------------
//
// #173 A173-REFUSALS: an `insertActive` on a key the trie already binds is
// refused `key-exists`, BEFORE any mint arithmetic runs; a claimed mint that
// agrees per kind and disagrees per `(kind, key)` was refused
// `net-mint-mismatch`. Both names are constructed in one place in `lib`, and
// the rows below bind the construction sites to the names.
//
// CP2: the legacy edge-only requests these rows used to fold are retired. Their
// fold rows moved to the tagged requests of `tagged_fold.tests.ak`:
//
// - `insert_active_places_one_active_token_at_the_named_output` is
//   `tagged_fold_state_folds_a_registration_inside_its_window` (and the carrier
//   rows around it);
// - `duplicate_insert_active_refuses_cleanly` is
//   `tagged_fold_registration_refuses_an_occupied_key`, which asserts the
//   reason `lib.occupiedRefusal` constructs;
// - `two_key_batch_with_the_right_distribution_accepts` and
//   `two_key_batch_with_the_wrong_distribution_refuses` are
//   `tagged_fold_state_folds_two_registrations` and
//   `tagged_fold_refuses_a_wrong_singular_distribution_over_two_registrations`
//   (the keyed mint of the tagged fold is refused `fold-singular-mismatch`).

/// A-006, A-009 and Lean `refusal`: occupancy is a fault of the TRIE
/// and has its own construction site, reached BEFORE the mint is
/// compared.
test duplicate_insert_active_reason_is_key_exists() {
  lib.occupiedRefusal() == Some(@"key-exists")
}

/// The two claims really do agree per kind: a per-kind guard accepts the
/// wrong distribution, which is why the keyed rows compare per `(kind, key)`.
test the_wrong_distribution_agrees_per_kind() {
  let right =
    merge(
      fx.mintOf(fx.activePolicy, fx.keyA, 1),
      fx.mintOf(fx.activePolicy, fx.keyB, 1),
    )
  let wrong = fx.mintOf(fx.activePolicy, fx.keyA, 2)
  lib.kindTotal(right, fx.activePolicy) == lib.kindTotal(wrong, fx.activePolicy) && right != wrong
}

/// A-006: the legacy keyed-mint refusal is `net-mint-mismatch`, a DIFFERENT
/// reason from the duplicate's `key-exists`. Two distinct fixtures, two
/// distinct names.
test keyed_mint_reason_is_net_mint_mismatch() {
  lib.mintRefusal() == Some(@"net-mint-mismatch")
}

test the_two_refusals_are_distinct_reasons() {
  // Asserted by NAME, not merely by inequality.
  let duplicate = lib.occupiedRefusal()
  lib.mintRefusal() == Some(@"net-mint-mismatch") && duplicate == Some(
    @"key-exists",
  ) && lib.mintRefusal() != duplicate
}
