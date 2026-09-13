use aiken/collection/dict.{get, keys}
use aiken/collection/list.{filter, find, head}
use aiken/collection/pairs
use cardano/address
use cardano/assets.{PolicyId, Value, flatten, quantity_of, tokens}
use cardano/transaction.{InlineDatum, Input, OutputReference, Spend, Transaction}
use naming.{
  MUpdate, modify_action_count, mpfs_state_hash, mpfs_state_policy, mpfs_state_root,
  mrequest, over_marker_for,
}

/// The retirement custody script (issue #66): completion-only custody
/// for retired representatives.
///
/// A retirement places the record's representative here; the only way it
/// ever leaves is completion, which burns it. There is no withdrawal
/// path, no redirection path, no `Delete`: `LT07` will be true because
/// the path does not exist, not because a check rejects it.
///
/// - it succeeds only in a transaction that burns the representative it
///   holds, exactly once (each held non-lovelace asset burned exactly);
/// - the burn must ride a genuine registry transition: the transaction
///   spends the registry state (NOTE-028 — a standalone custody spend
///   with no state input refuses here; reference inputs do not count),
///   folds the retire's own pending request (NOTE-029 co-creation),
///   as a singleton `Modify` whose root genuinely changes (Rejected
///   processing plus a burn refuses);
/// - it requires no signature from anybody — completion is permissionless;
/// - creating an output here executes no receiving script: `LT08`'s
///   refusal comes from the application validator's `Retire` spend
///   checking the destination, not from this script.
///
/// This validator carries no parameters, so its hash is stable: the
/// application validator hardcodes it and the runner derives and checks
/// it from the blueprint. Spending it (completion, withdrawal refusal)
/// executes the single path below.
validator retirement_custody {
  spend(
    _maybe_datum: Option<Data>,
    _redeemer: Data,
    self: OutputReference,
    tx: Transaction,
  ) {
    expect Some(claim) =
      find(tx.inputs, fn(input) { input.output_reference == self })
    // Every non-lovelace asset the spent output holds is burned exactly
    // once; lovelace flows to fees/change. No signature is required.
    // (First: the original burn check keeps its verdicts — a burn-free
    // spend refuses here exactly as before.)
    expect held_burned_exactly_once(claim, tx)
    expect [stateIn] = filter(tx.inputs, is_spent_registry_state)
    // NOTE-029: exactly one co-created script input (the retire's
    // pending request) — none, or a confused batch of several,
    // refuses. Fee/collateral inputs are payment-key owned.
    expect [requestIn] =
      filter(tx.inputs, fn(input) { is_co_created_input(self, stateIn, input) })
    expect singleton_modify(tx, stateIn)
    expect root_changed(tx, stateIn)
    // NOTE-031: the co-created input is the exact pending request
    // for the held asset (datum, token, and value relation checked).
    expect request_binds_burn(claim, stateIn, requestIn)
    True
  }

  else(_) {
    fail
  }
}

/// A script input co-created with the custody output: not this spend,
/// not the state input, script-credentialed, from the same creator
/// transaction. Fee and collateral inputs are payment-key owned and
/// never match.
fn is_co_created_input(
  self: OutputReference,
  stateIn: Input,
  input: Input,
) -> Bool {
  input.output_reference != self
    && input.output_reference != stateIn.output_reference
    && is_script_input(input)
    && input.output_reference.transaction_id == self.transaction_id
}

fn is_script_input(input: Input) -> Bool {
  when input.output.address.payment_credential is {
    address.Script(_) -> True
    _ -> False
  }
}

/// The co-created input is the exact pending retirement request for
/// the held asset (NOTE-031/032): it decodes as a request datum
/// targeting this registry's cage token, updating some key from the
/// held asset to its Over marker — where the held asset is identified
/// by its COMPLETE (policy, name, quantity) identity bound to the
/// spent state's configured representative policy (a same-name token
/// under a foreign policy refuses here, even Burns-correct). Crash
/// refuses (single path).
fn request_binds_burn(claim: Input, stateIn: Input, requestIn: Input) -> Bool {
  expect InlineDatum(reqDatum) = requestIn.output.datum
  let req = mrequest(reqDatum)
  expect [cageToken] = keys(tokens(stateIn.output.value, mpfs_state_hash))
  expect req.requestToken.assetName == cageToken
  expect MUpdate(old, new) = req.requestValue
  expect InlineDatum(stateDatum) = stateIn.output.datum
  let expectedPolicy = mpfs_state_policy(stateDatum)
  expect new == over_marker_for(burned_of(claim, old, expectedPolicy))
  True
}

/// The held asset matching the request's old value, held once under
/// the registry's configured representative policy (NOTE-032: policy
/// is load-bearing — name alone admits foreign-policy lookalikes
/// whose burn the mint authorizer never sees).
fn burned_of(claim: Input, old: ByteArray, expectedPolicy: PolicyId) -> ByteArray {
  expect Some(heldEntry) =
    find(held_assets(claim.output.value), fn(entry) {
      let (policy, name, _) = entry
      policy == expectedPolicy && name == old
    })
  let (_, burned, qty) = heldEntry
  expect qty == 1
  burned
}

/// Non-lovelace assets of a value (extracted so the burn check and
/// the request binding share one shape).
fn held_assets(value: Value) -> List<(PolicyId, ByteArray, Int)> {
  filter(flatten(value), fn(entry) {
    let (policy_id, _asset_name, quantity) = entry
    policy_id != #"" && quantity > 0
  })
}

/// The state spend is a singleton `Modify` (exactly one action).
fn singleton_modify(tx: Transaction, stateIn: Input) -> Bool {
  when pairs.get_first(tx.redeemers, Spend(stateIn.output_reference)) is {
    Some(redeemer_data) -> modify_action_count(redeemer_data) == 1
    None -> False
  }
}

/// The continuation (outputs[0], the generic layer's own convention)
/// carries a different root than the spent state.
fn root_changed(tx: Transaction, stateIn: Input) -> Bool {
  expect Some(firstOut) = head(tx.outputs)
  expect InlineDatum(outDatum) = firstOut.datum
  expect InlineDatum(inDatum) = stateIn.output.datum
  mpfs_state_root(inDatum) != mpfs_state_root(outDatum)
}

/// A spent registry-state input authenticates exactly like the
/// application validator's `is_registry_state` (script hash plus the
/// single cage token). Reference inputs do not count.
fn is_spent_registry_state(input: Input) -> Bool {
  when input.output.address.payment_credential is {
    address.Script(hash) ->
      hash == mpfs_state_hash && has_single_cage_token(input.output.value)
    _ -> False
  }
}

fn has_single_cage_token(value: Value) -> Bool {
  let policy_tokens = tokens(value, mpfs_state_hash)
  when keys(policy_tokens) is {
    [name] -> get(policy_tokens, name) == Some(1)
    _ -> False
  }
}

/// Each held non-lovelace asset (policy non-empty) is burned by exactly
/// its held quantity, and at least one such asset is held.
fn held_burned_exactly_once(claim: Input, tx: Transaction) -> Bool {
  let held = held_assets(claim.output.value)
  expect held != []
  list_all(held, fn(entry) {
    let (policy_id, asset_name, quantity) = entry
    quantity_of(tx.mint, policy_id, asset_name) == -quantity
  })
}

fn list_all(items: List<a>, check: fn(a) -> Bool) -> Bool {
  when items is {
    [] -> True
    [head, ..tail] ->
      if check(head) {
        list_all(tail, check)
      } else {
        False
      }
  }
}
