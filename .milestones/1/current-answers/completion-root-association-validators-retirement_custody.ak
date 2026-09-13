use aiken/collection/list.{filter, find}
use cardano/assets.{flatten, quantity_of}
use cardano/transaction.{Input, OutputReference, Transaction}

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
/// - it requires no signature from anybody — completion is permissionless;
/// - creating an output here executes no receiving script: `LT08`'s
///   refusal comes from the application validator's `Retire` spend
///   checking the destination, not from this script, which this slice
///   never spends (spending it — `LT04` completion, `LT07` withdrawal
///   refusal — is the next child).
///
/// This validator carries no parameters, so its hash is stable: the
/// application validator hardcodes it and the runner derives and checks
/// it from the blueprint.
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
    expect held_burned_exactly_once(claim, tx)
    True
  }

  else(_) {
    fail
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
