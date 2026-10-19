use aiken/builtin
use cardano/address
use cardano/assets.{PolicyId, add, zero}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Spend,
}
use fixtures.{
  app_address, app_policy, controller, mock_registry_token, record_value,
  registry_key, rep_policy, self_ref, state_datum, state_input, state_ref,
}
use naming.{
  MARejected, MAUpdate, MInsert, MLeaf, MRequest, MRequestDatum, MTokenId,
  MUpdate, MirrorEnd, MirrorModify, mpfs_state_datum_with_root, mpfs_state_hash,
}
use retirement_custody

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
/// moving the held active token from live (`0x01`) to over (`0x02`).
fn request_datum() {
  MRequestDatum(
    MRequest {
      requestToken: MTokenId { assetName: mock_registry_token },
      requestOwner: controller,
      requestKey: registry_key,
      // #157 N4/N8: completion folds `Update(0x01, 0x02)` — the leaf
      // codec IS the value now, and the Over marker is gone with the
      // naming value vocabulary.
      requestValue: MUpdate(#"01", #"02"),
      tip: 1000000,
      submitted_at: 0,
      destination: (#"", None),
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
    datum: InlineDatum(
      mpfs_state_datum_with_root(#"01", rep_policy, app_policy),
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
    MirrorModify(
      [MAUpdate([MLeaf { skip: 0, key: #"", value: #"" }]), MARejected],
    ),
  )
}

fn modify_end() {
  state_redeemers(MirrorEnd)
}

fn custody_completion_tx(inputs, outputs, mint, redeemers) {
  fixtures.tx(inputs, outputs, [], mint, redeemers)
}

fn held_value() {
  add(record_value, rep_policy, fixtures.registry_key, 1)
}

fn burn_held() {
  add(zero, rep_policy, fixtures.registry_key, -1)
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
      requestKey: "alice",
      requestValue: value,
      tip: 1000000,
      submitted_at: 0,
      destination: (#"", None),
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
      [
        custody_input(held_value()),
        state_input(),
        request_input_with(state_datum()),
      ],
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
        requestKey: "alice",
        requestValue: MUpdate(#"01", #"02"),
        tip: 1000000,
        submitted_at: 0,
        destination: (#"", None),
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
        request_input_with(request_datum_with(MInsert(#"01"))),
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
        request_input_with(request_datum_with(MUpdate(#"ffff", #"02"))),
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
        request_input_with(request_datum_with(MUpdate(#"01", #"ffff"))),
      ],
      [state_output_new()],
      burn_held(),
      modify_singleton(),
    ),
  )
}

/// Negation (NOTE-032): a same-name token under a FOREIGN policy,
/// held once and burned exactly with everything else genuine
/// (state, co-created exact request, singleton Modify, changed
/// root), refuses — specifically at the policy binding. The
/// configured representative policy mints zero and need not execute;
/// the consumer (positive mints only) cannot see this negative-mint
/// path, so custody is the single executing check on the burn's
/// policy.
test custody_foreign_policy_lookalike_refuses() fail {
  let foreign_held = add(zero, #"666f726569676e2d706f6c696379", registry_key, 1)
  let foreign_burn =
    add(zero, #"666f726569676e2d706f6c696379", registry_key, -1)
  retirement_custody.retirement_custody.spend(
    None,
    #"00",
    self_ref,
    custody_completion_tx(
      [custody_input(foreign_held), state_input(), request_input()],
      [state_output_new()],
      foreign_burn,
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
  let double = add(burn_held(), app_policy, fixtures.registry_key, -1)
  retirement_custody.retirement_custody.spend(
    None,
    #"00",
    self_ref,
    custody_tx([custody_input(held_value())], double),
  )
}

/// The correct old/new values and burn cannot conceal a different key.
test custody_wrong_spelling_refuses() fail {
  let datum: Data =
    MRequestDatum(
      MRequest {
        requestToken: MTokenId { assetName: fixtures.mock_registry_token },
        requestOwner: #"abcd",
        requestKey: "bob",
        requestValue: MUpdate(#"01", #"02"),
        tip: 1000000,
        submitted_at: 0,
        destination: (#"", None),
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

// ============================================================================
// N8 — completion (#157 Gate S)
// ============================================================================

/// Completion is the fold of `Update(0x01, 0x02)`: the completion-only
/// custody is spent, the active token it holds is exactly the burn the
/// delta requires, and the name's leaf is `0x02` forever. Nobody signs —
/// the retirement already decided; completion only executes it.
test completion_folds_the_terminal_update_accepts() {
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

/// A completion whose burn is not the asset the custody holds is not
/// this completion: the held token would survive a transition that says
/// it died.
test completion_burning_another_token_refuses() fail {
  retirement_custody.retirement_custody.spend(
    None,
    #"00",
    self_ref,
    custody_completion_tx(
      [custody_input(held_value()), state_input(), request_input()],
      [state_output_new()],
      add(zero, rep_policy, #"6e6f742d7468652d6b6579", -1),
      modify_singleton(),
    ),
  )
}

// ----------------------------------------------------------------------------
// The registry state as the registry's wire carries it
// ----------------------------------------------------------------------------
//
// The registry State now has eleven fields: the eight this consumer has always
// read, then the registration cost, the widest booking interval and the request
// policy. The rows below hand the real completion path states built field by
// field from data in the registry's own order, never through the mirror type or
// its construction helper, so a mirror that drifted from the wire cannot agree
// with itself. The consumer reads the root and the active policy; every other
// field carries a distinct value so a read from the wrong position is seen.

const wire_absent_policy = "wire_absent_policy"

const wire_terminal_policy = "wire_terminal_policy"

const wire_request_policy = "wire_request_policy"

fn wire_state(
  root: ByteArray,
  tip: Int,
  application: PolicyId,
  active: PolicyId,
  absent: PolicyId,
  terminal: PolicyId,
) -> Data {
  builtin.constr_data(
    1,
    [
      builtin.constr_data(
        0,
        [
          builtin.b_data(root),
          builtin.i_data(tip),
          builtin.i_data(600_000),
          builtin.i_data(300_000),
          builtin.b_data(application),
          builtin.b_data(active),
          builtin.b_data(absent),
          builtin.b_data(terminal),
          builtin.i_data(2_000_000),
          builtin.i_data(10_000),
          builtin.b_data(wire_request_policy),
        ],
      ),
    ],
  )
}

/// A registry state with the representative policy where it belongs.
fn honest_wire_state(root: ByteArray, tip: Int) -> Data {
  wire_state(
    root,
    tip,
    app_policy,
    rep_policy,
    wire_absent_policy,
    wire_terminal_policy,
  )
}

fn state_input_holding(datum: Data) -> Input {
  let base = state_input()
  Input { ..base, output: Output { ..base.output, datum: InlineDatum(datum) } }
}

fn state_output_holding(datum: Data) -> Output {
  let base = state_output_new()
  Output { ..base, datum: InlineDatum(datum) }
}

fn complete_with(spent: Data, continued: Data) -> Bool {
  retirement_custody.retirement_custody.spend(
    None,
    #"00",
    self_ref,
    custody_completion_tx(
      [custody_input(held_value()), state_input_holding(spent), request_input()],
      [state_output_holding(continued)],
      burn_held(),
      modify_singleton(),
    ),
  )
}

/// The completion rides a genuine transition between two eleven-field
/// states: the root changes, the representative policy is the held token's.
test retirement_custody_wire_state_completion_accepts() {
  complete_with(
    honest_wire_state(#"00", 1_000_000),
    honest_wire_state(#"01", 1_000_000),
  )
}

/// Authority is kept: a state whose active policy is not the held token's
/// policy refuses, whatever the other fields say.
test retirement_custody_wire_state_foreign_active_policy_refuses() fail {
  complete_with(
    wire_state(
      #"00",
      1_000_000,
      app_policy,
      "foreign_policy",
      wire_absent_policy,
      wire_terminal_policy,
    ),
    wire_state(
      #"01",
      1_000_000,
      app_policy,
      "foreign_policy",
      wire_absent_policy,
      wire_terminal_policy,
    ),
  )
}

/// The representative policy sitting in every other policy position does not
/// stand in for the active policy.
test retirement_custody_wire_state_representative_policy_in_other_fields_refuses() fail {
  complete_with(
    wire_state(
      #"00",
      1_000_000,
      rep_policy,
      "foreign_policy",
      rep_policy,
      rep_policy,
    ),
    wire_state(
      #"01",
      1_000_000,
      rep_policy,
      "foreign_policy",
      rep_policy,
      rep_policy,
    ),
  )
}

/// A preserved root is not a completion, even when another field changed.
test retirement_custody_wire_state_changed_tip_with_preserved_root_refuses() fail {
  complete_with(
    honest_wire_state(#"00", 1_000_000),
    honest_wire_state(#"00", 2_000_000),
  )
}
