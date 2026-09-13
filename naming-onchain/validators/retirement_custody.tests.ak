use retirement_custody
use cardano/address
use cardano/assets.{add, zero}
use cardano/transaction.{InlineDatum, Input, NoDatum, Output, OutputReference, Spend}
use fixtures.{
  app_address, app_policy, consumer_pin, controller, mock_registry_token, record_value,
  rep_policy, representative_name, self_ref, state_datum, state_input, state_ref,
}
use naming.{
  MARejected, MAUpdate, MInsert, MLeaf, MRequest, MRequestDatum, MTokenId,
  MUpdate, MirrorEnd, MirrorModify, mpfs_state_datum_with_root, mpfs_state_hash, over_marker_for,
}

/// Completion-only custody (issue #66): the representative it holds is
/// burned exactly once, by anybody. Spending it is the next child
/// (`LT04`/`LT07`); these unit tests pin the shape this slice creates.

fn custody_input(value) {
  Input {
    output_reference: self_ref,
    output: Output {
      address: address.from_script(fixtures.custody_hash),
      value,
      datum: NoDatum,
      reference_script: None,
    },
  }
}

fn custody_tx(inputs, mint) {
  fixtures.tx(inputs, [], [], mint, [])
}

/// A co-created request input (NOTE-029): any script input from the
/// same creator transaction as the custody output. Carries the exact
/// pending Update the retire queued (NOTE-031): this registry's token
/// moving the held representative to its Over marker.
fn request_datum() {
  MRequestDatum(
    MRequest {
      requestToken: MTokenId { assetName: mock_registry_token },
      requestOwner: controller,
      requestKey: #"6b6579",
      requestValue:
        MUpdate(
          representative_name,
          over_marker_for(representative_name),
        ),
      tip: 1000000,
      submitted_at: 0,
    },
  )
}

fn request_input() {
  Input {
    output_reference: OutputReference {
      transaction_id: "1234567890abcdef",
      output_index: 9,
    },
    output: Output {
      address: app_address,
      value: zero,
      datum: InlineDatum(request_datum()),
      reference_script: None,
    },
  }
}

/// A request input from anywhere else (NOTE-029 negative): linkage
/// must refuse it.
fn foreign_request_input() {
  Input {
    output_reference: OutputReference {
      transaction_id: "ffffffffffffffff",
      output_index: 9,
    },
    output: Output {
      address: app_address,
      value: zero,
      datum: NoDatum,
      reference_script: None,
    },
  }
}

/// The registry continuation with a changed root (NOTE-029): what a
/// genuine `UpdateAction` leaves behind.
fn state_output_new() {
  Output {
    address: address.from_script(mpfs_state_hash),
    value: state_input().output.value,
    datum:
      InlineDatum(
        mpfs_state_datum_with_root(#"01", rep_policy, consumer_pin),
      ),
    reference_script: None,
  }
}

/// The registry continuation with the root preserved (NOTE-029
/// negative): what `Rejected` processing leaves behind.
fn state_output_same() {
  Output {
    address: address.from_script(mpfs_state_hash),
    value: state_input().output.value,
    datum: InlineDatum(state_datum()),
    reference_script: None,
  }
}

/// State-spend redeemers for the correspondence shapes below. Actions
/// are exact-shape mirrors (a singleton `UpdateAction` with a leaf
/// step, a two-action batch, a non-`Modify`): custody counts actions
/// and never interprets proofs. The `Data` boundary coerces each
/// mirror (same pattern as `spend_redeemer_data`).
fn state_redeemers(modify: Data) {
  [Pair(Spend(state_ref), modify)]
}

fn modify_singleton() {
  state_redeemers(
    MirrorModify([MAUpdate([MLeaf { skip: 0, key: #"", value: #"" }])]),
  )
}

fn modify_batch() {
  state_redeemers(
    MirrorModify([
      MAUpdate([MLeaf { skip: 0, key: #"", value: #"" }]),
      MARejected,
    ]),
  )
}

fn modify_end() {
  state_redeemers(MirrorEnd)
}

fn custody_completion_tx(inputs, outputs, mint, redeemers) {
  fixtures.tx(inputs, outputs, [], mint, redeemers)
}

fn held_value() {
  add(record_value, app_policy, fixtures.representative_name, 1)
}

fn burn_held() {
  add(zero, app_policy, fixtures.representative_name, -1)
}

/// Completion burns the held representative exactly once, with no
/// signature from anybody — riding a genuine registry transition
/// (NOTE-028/029): the spent state, the retire's own pending request
/// (same creator), a singleton `Modify`, and a changed root.
test custody_completion_burns_accepts() {
  retirement_custody.retirement_custody.spend(
    None,
    #"00",
    self_ref,
    custody_completion_tx(
      [custody_input(held_value()), state_input(), request_input()],
      [state_output_new()],
      burn_held(),
      modify_singleton(),
    ),
  )
}

/// Negation (NOTE-028): a standalone custody spend with no registry
/// state input refuses — the burn must ride a transition.
test custody_without_registry_transition_refuses() fail {
  retirement_custody.retirement_custody.spend(
    None,
    #"00",
    self_ref,
    custody_tx([custody_input(held_value())], burn_held()),
  )
}

/// Negation (NOTE-029): the root preserved (a `Rejected` shape) plus
/// a burn is not completed retirement and refuses — even with the
/// retire's own request and a singleton action.
test custody_rejected_root_preserved_refuses() fail {
  retirement_custody.retirement_custody.spend(
    None,
    #"00",
    self_ref,
    custody_completion_tx(
      [custody_input(held_value()), state_input(), request_input()],
      [state_output_same()],
      burn_held(),
      modify_singleton(),
    ),
  )
}

/// Negation (NOTE-029): a batch (`Modify` with two actions) refuses
/// even with a changed root — a completion is exactly one action.
test custody_multi_action_refuses() fail {
  retirement_custody.retirement_custody.spend(
    None,
    #"00",
    self_ref,
    custody_completion_tx(
      [custody_input(held_value()), state_input(), request_input()],
      [state_output_new()],
      burn_held(),
      modify_batch(),
    ),
  )
}

/// Negation (NOTE-029): a non-`Modify` state spend refuses.
test custody_non_modify_refuses() fail {
  retirement_custody.retirement_custody.spend(
    None,
    #"00",
    self_ref,
    custody_completion_tx(
      [custody_input(held_value()), state_input(), request_input()],
      [state_output_new()],
      burn_held(),
      modify_end(),
    ),
  )
}

/// Negation (NOTE-029): a request from anywhere else (different
/// creator transaction) refuses — the folded request must be the
/// retire's own.
test custody_foreign_request_refuses() fail {
  retirement_custody.retirement_custody.spend(
    None,
    #"00",
    self_ref,
    custody_completion_tx(
      [custody_input(held_value()), state_input(), foreign_request_input()],
      [state_output_new()],
      burn_held(),
      modify_singleton(),
    ),
  )
}

/// Negation (NOTE-029): no co-created request at all refuses — a
/// burn with a transition but no pending request is not completion.
test custody_missing_request_refuses() fail {
  retirement_custody.retirement_custody.spend(
    None,
    #"00",
    self_ref,
    custody_completion_tx(
      [custody_input(held_value()), state_input()],
      [state_output_new()],
      burn_held(),
      modify_singleton(),
    ),
  )
}

/// A request datum variant builder (NOTE-031 negatives): same
/// co-created input, varied operation or token.
fn request_input_with(datum) {
  Input {
    output_reference: OutputReference {
      transaction_id: "1234567890abcdef",
      output_index: 9,
    },
    output: Output {
      address: app_address,
      value: zero,
      datum: InlineDatum(datum),
      reference_script: None,
    },
  }
}

fn request_datum_with(value) {
  MRequestDatum(
    MRequest {
      requestToken: MTokenId { assetName: mock_registry_token },
      requestOwner: controller,
      requestKey: #"6b6579",
      requestValue: value,
      tip: 1000000,
      submitted_at: 0,
    },
  )
}

/// Negation (NOTE-031): a co-created input that is not a request
/// datum at all refuses (a state datum smuggled as the request).
test custody_non_request_datum_refuses() fail {
  retirement_custody.retirement_custody.spend(
    None,
    #"00",
    self_ref,
    custody_completion_tx(
      [custody_input(held_value()), state_input(), request_input_with(state_datum())],
      [state_output_new()],
      burn_held(),
      modify_singleton(),
    ),
  )
}

/// Negation (NOTE-031): a request for another registry's token
/// refuses (cross-cage confusion).
test custody_foreign_token_refuses() fail {
  let datum =
    MRequestDatum(
      MRequest {
        requestToken: MTokenId { assetName: #"ffff" },
        requestOwner: controller,
        requestKey: #"6b6579",
        requestValue:
          MUpdate(
            representative_name,
            over_marker_for(representative_name),
          ),
        tip: 1000000,
        submitted_at: 0,
      },
    )
  retirement_custody.retirement_custody.spend(
    None,
    #"00",
    self_ref,
    custody_completion_tx(
      [custody_input(held_value()), state_input(), request_input_with(datum)],
      [state_output_new()],
      burn_held(),
      modify_singleton(),
    ),
  )
}

/// Negation (NOTE-031): a non-Update operation refuses (an Insert
/// cannot complete a retirement).
test custody_non_update_value_refuses() fail {
  retirement_custody.retirement_custody.spend(
    None,
    #"00",
    self_ref,
    custody_completion_tx(
      [
        custody_input(held_value()),
        state_input(),
        request_input_with(request_datum_with(MInsert(representative_name))),
      ],
      [state_output_new()],
      burn_held(),
      modify_singleton(),
    ),
  )
}

/// Negation (NOTE-031): an Update from the wrong old value refuses
/// (not this key's current value).
test custody_wrong_old_value_refuses() fail {
  retirement_custody.retirement_custody.spend(
    None,
    #"00",
    self_ref,
    custody_completion_tx(
      [
        custody_input(held_value()),
        state_input(),
        request_input_with(
          request_datum_with(
            MUpdate(#"ffff", over_marker_for(representative_name)),
          ),
        ),
      ],
      [state_output_new()],
      burn_held(),
      modify_singleton(),
    ),
  )
}

/// Negation (NOTE-031): an Update to the wrong new value refuses
/// (not this asset's Over marker).
test custody_wrong_new_value_refuses() fail {
  retirement_custody.retirement_custody.spend(
    None,
    #"00",
    self_ref,
    custody_completion_tx(
      [
        custody_input(held_value()),
        state_input(),
        request_input_with(request_datum_with(MUpdate(representative_name, #"ffff"))),
      ],
      [state_output_new()],
      burn_held(),
      modify_singleton(),
    ),
  )
}

/// Negation: no burn, no completion.
test custody_without_burn_refuses() fail {
  retirement_custody.retirement_custody.spend(
    None,
    #"00",
    self_ref,
    custody_tx([custody_input(held_value())], zero),
  )
}

/// Negation: a wrong quantity is not the representative leaving exactly
/// once.
test custody_double_burn_refuses() fail {
  let double =
    add(burn_held(), app_policy, fixtures.representative_name, -1)
  retirement_custody.retirement_custody.spend(
    None,
    #"00",
    self_ref,
    custody_tx([custody_input(held_value())], double),
  )
}
