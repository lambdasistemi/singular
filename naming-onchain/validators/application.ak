use aiken/collection/dict.{get, keys}
use aiken/collection/list.{all, filter, find, has}
use aiken/crypto.{VerificationKeyHash}
use cardano/address
use cardano/assets.{flatten, lovelace_of, quantity_of, tokens, PolicyId, Value}
use cardano/transaction.{InlineDatum, Input, Output, OutputReference, Transaction}
use naming.{NamingRecord}

/// The naming application validator (issue #52).
///
/// One script serves both purposes, the way the imported partition's
/// state script serves as both spending validator and bootstrap minting
/// policy: the `mint` purpose is the application policy whose approval
/// tokens carry the refund binding, the `spend` purpose governs the
/// naming records and claims whose datum is the four-field naming
/// datum in the accepted encoding — nothing else, no fifth field.
///
/// The validator reads its own script hash from the spent input's
/// address credential, so it has no constructor parameters: the pinned
/// blueprint hash is the applied address.
///
/// Row demand (from the accepted v0.2.0 corpus, `LM-LC-rows.json`):
///
/// - `LM01..LM04` (`applicationSpend`): maintenance requires the
///   controller's signature, and preserves control and recovery fields;
///   only the payment destination is maintainable.
/// - `LC01..LC06` (`nativeSpend`): cancellation compares the presented
///   refund address against the one bound into the withdraw approval
///   token, consumes the approval by burning it, and pays the refund to
///   the bound destination.
pub type ApplicationRedeemer {
  /// Ordinary maintenance (`LM` rows).
  Maintain
  /// Cancel a claim to its stored refund destination (`LC` rows).
  Cancel { presented_refund: ByteArray }
  /// Fold a claim into a record: the four-field datum is frozen; the
  /// representative names are carried for the representative policy to
  /// bind.
  Fold { representatives: List<ByteArray> }
  /// Retire a record: the datum must not continue.
  Retire { representatives: List<ByteArray> }
}

/// Redeemer of the application policy's mint purpose: mint the
/// withdraw approval whose asset name is the refund destination it
/// binds. The controller must sign — this is the "separate cancellation
/// approval" the `LC03` refusal demands.
pub type ApplicationMintRedeemer {
  WithdrawApproval { controller: VerificationKeyHash, destination: ByteArray }
}

validator application {
  spend(
    maybe_datum: Option<Data>,
    redeemer: ApplicationRedeemer,
    self: OutputReference,
    tx: Transaction,
  ) {
    expect Some(datum) = maybe_datum
    let record = naming.expect_naming(datum)
    expect Some(claim) =
      find(tx.inputs, fn(input) { input.output_reference == self })
    expect address.Script(own_hash) = claim.output.address.payment_credential
    when redeemer is {
      Maintain -> maintain(record, claim, tx)
      Cancel { presented_refund } ->
        cancel(record, presented_refund, claim, own_hash, tx)
      Fold { representatives: _ } -> fold(record, claim, own_hash, tx)
      Retire { representatives: _ } -> retire(record, tx)
    }
  }

  mint(
    redeemer: ApplicationMintRedeemer,
    policy_id: PolicyId,
    tx: Transaction,
  ) {
    let WithdrawApproval { controller, destination } = redeemer
    let Transaction { extra_signatories, mint, .. } = tx
    // The controller authorizes the approval (`LC03`: insert approval
    // alone is insufficient; cancellation needs its own).
    expect has(extra_signatories, controller)
    // The approval's asset name IS the refund destination it binds:
    // cancellation later compares against exactly these bytes.
    expect naming.canonical_address(destination)
    let policy_tokens = tokens(mint, policy_id)
    expect [bound] = keys(policy_tokens)
    expect bound == destination
    expect get(policy_tokens, bound) == Some(1)
    True
  }

  else(_) {
    fail
  }
}

/// `LM01` accepts; `LM02` (no signature), `LM03` (tampered control or
/// recovery field) and `LM04` (altered quorum) refuse.
fn maintain(record: NamingRecord, claim: Input, tx: Transaction) -> Bool {
  let Transaction { extra_signatories, .. } = tx
  // The controller's payment key must sign; absence alone refuses.
  expect has(extra_signatories, naming.control_hash(record))
  // Exactly one continuation record at the application address.
  expect [continuation] = continuation_outputs(record, claim, tx)
  // Only the payment destination is maintainable: control, commitment
  // and quorum are preserved exactly.
  expect InlineDatum(successor_datum) = continuation.datum
  let successor = naming.expect_naming(successor_datum)
  expect successor.control_address == record.control_address
  expect successor.next_control_commitment == record.next_control_commitment
  expect successor.retirement_quorum == record.retirement_quorum
  // The record's value — including its representative — is preserved.
  expect value_preserved(claim.output.value, continuation.value)
  True
}

/// `LC01` accepts; `LC02` (redirect), `LC03` (no withdraw approval),
/// `LC04`/`LC06` (fold/replay: the approval is already consumed) refuse.
fn cancel(
  record: NamingRecord,
  presented_refund: ByteArray,
  claim: Input,
  own_hash: ByteArray,
  tx: Transaction,
) -> Bool {
  let Transaction { mint, outputs, fee, .. } = tx
  // The withdraw approval rides the claim under our own policy; its
  // asset name is the stored refund destination. No token, no
  // cancellation (`LC03`).
  let claim_tokens = tokens(claim.output.value, own_hash)
  expect [stored_refund] = keys(claim_tokens)
  // The presented refund address must be the stored one (`LC02`).
  expect presented_refund == stored_refund
  // The approval is consumed: burned exactly once, and nothing else
  // moves under our policy.
  expect [burned] = keys(tokens(mint, own_hash))
  expect burned == stored_refund
  expect quantity_of(mint, own_hash, stored_refund) == -1
  // The claim dies here: no continuation record.
  expect [] = continuation_outputs(record, claim, tx)
  // The refund pays the claim's lovelace to the stored destination: at
  // least one output goes there, and every output that does pays at
  // least what the claim held (net of fee).
  let owed = lovelace_of(claim.output.value) - fee
  let refund_credential = naming.payment_credential(stored_refund)
  let refund_outputs =
    filter(
      outputs,
      fn(output) { output.address.payment_credential == refund_credential },
    )
  expect refund_outputs != []
  expect all(refund_outputs, fn(output) { lovelace_of(output.value) >= owed })
  True
}

/// A fold turns a claim into a record: the four-field datum is frozen
/// exactly as the claim carried it, the claim's value moves into the
/// record, and the withdraw approval is consumed — burned exactly once,
/// the way the application policy burns on fold or on cancellation.
/// A folded claim therefore cannot be cancelled afterwards (`LC04`),
/// and a cancelled approval cannot authorize a replay (`LC06`).
fn fold(
  record: NamingRecord,
  claim: Input,
  own_hash: ByteArray,
  tx: Transaction,
) -> Bool {
  let Transaction { mint, .. } = tx
  // The withdraw approval rides the claim under our own policy; its
  // asset name is the stored refund destination. No token, no fold.
  let claim_tokens = tokens(claim.output.value, own_hash)
  expect [stored_refund] = keys(claim_tokens)
  // The approval is consumed: burned exactly once, and nothing else
  // moves under our policy.
  expect [burned] = keys(tokens(mint, own_hash))
  expect burned == stored_refund
  expect quantity_of(mint, own_hash, stored_refund) == -1
  expect [continuation] = continuation_outputs(record, claim, tx)
  expect InlineDatum(successor_datum) = continuation.datum
  expect naming.is_same_record(successor_datum, record)
  // The record inherits the claim's value minus the consumed approval.
  expect value_preserved_except(
    claim.output.value,
    continuation.value,
    own_hash,
  )
  True
}

/// A retire consumes the record: its datum must not continue anywhere
/// in the transaction.
fn retire(record: NamingRecord, tx: Transaction) -> Bool {
  let Transaction { outputs, .. } = tx
  expect
    [] =
    filter(
      outputs,
      fn(output) {
        when output.datum is {
          InlineDatum(datum) -> naming.is_same_record(datum, record)
          _ -> False
        }
      },
    )
  True
}

/// The outputs at the application address — the candidate continuations
/// of the record.
fn continuation_outputs(
  _record: NamingRecord,
  claim: Input,
  tx: Transaction,
) -> List<Output> {
  filter(
    tx.outputs,
    fn(output) {
      output.address.payment_credential == claim.output.address.payment_credential
    },
  )
}

/// Every non-ADA asset of the previous value is present in the next at
/// the same quantity — except assets under `exempt` (the policy whose
/// token the transition consumes) — and the lovelace does not decrease.
fn value_preserved_except(
  previous: Value,
  next: Value,
  exempt: PolicyId,
) -> Bool {
  lovelace_of(next) >= lovelace_of(previous)
    && all(flatten(previous), fn(entry) {
      let (policy_id, asset_name, quantity) = entry
      policy_id == exempt
        || quantity_of(next, policy_id, asset_name) >= quantity
    })
}

/// Every non-ADA asset of the previous value is present in the next at
/// the same quantity, and the lovelace does not decrease.
fn value_preserved(previous: Value, next: Value) -> Bool {
  lovelace_of(next) >= lovelace_of(previous)
    && all(flatten(previous), fn(entry) {
      let (policy_id, asset_name, quantity) = entry
      quantity_of(next, policy_id, asset_name) >= quantity
    })
}
