use aiken/collection/dict.{get, keys}
use aiken/collection/list.{filter, find}
use cardano/address
use cardano/assets.{Value, flatten, quantity_of, tokens}
use cardano/transaction.{Input, OutputReference, Transaction}
use naming.{mpfs_state_hash}

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
///   with no state input refuses here, not just in the representative
///   policy; reference inputs do not count);
/// - it requires no signature from anybody — completion is permissionless;
/// - creating an output here executes no receiving script: `LT08`'s
///   refusal comes from the application validator's `Retire` spend
///   checking the destination, not from this script.
///
/// This validator carries no parameters, so its hash is stable: the
/// application validator hardcodes it and the runner derives and checks
/// it from the blueprint. Spending it (`LT04` completion, `LT07`
/// withdrawal refusal, OV rows) executes the single path below.
validator retirement_custody {
  spend(
    _maybe_datum: Option<Data>,
    _redeemer: Data,
    self: OutputReference,
    tx: Transaction,
  ) {
    expect Some(claim) =
      find(tx.inputs, fn(input) { input.output_reference == self })
    // NOTE-028: the burn must ride a genuine registry transition —
    // the spent registry state authenticates exactly like the
    // application validator's `is_registry_state` (script hash plus
    // the single cage token).
    expect has_spent_registry_state(tx)
    // Every non-lovelace asset the spent output holds is burned exactly
    // once; lovelace flows to fees/change. No signature is required.
    expect held_burned_exactly_once(claim, tx)
    True
  }

  else(_) {
    fail
  }
}

/// A spent registry-state input is present (reference inputs do not
/// count — a transition spends).
fn has_spent_registry_state(tx: Transaction) -> Bool {
  when find(tx.inputs, is_spent_registry_state) is {
    Some(_) -> True
    None -> False
  }
}

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
  let held =
    filter(flatten(claim.output.value), fn(entry) {
      let (policy_id, _asset_name, quantity) = entry
      policy_id != #"" && quantity > 0
    })
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
