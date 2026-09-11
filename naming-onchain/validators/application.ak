use aiken/collection/dict.{get, keys}
use aiken/collection/list.{all, filter, find, has}
use aiken/crypto.{VerificationKeyHash, blake2b_256}
use aiken/primitive/bytearray
use cardano/address
use cardano/assets.{flatten, lovelace_of, quantity_of, tokens, PolicyId, Value}
use cardano/transaction.{InlineDatum, Input, Output, OutputReference, Transaction}
use naming.{NamingRecord, RetirementQuorum}

/// The retirement custody script hash (issue #66): the only address a
/// `Retire` may place the representative at. Regenerated from the
/// custody validator's own blueprint; never hand-typed.
pub const retirement_custody_hash =
  #"0a92d14aa73db354d7468f0f09352cfedb6169adf32ea74e82666954"

/// The naming application validator (issue #52; mint burn half added
/// by #56's ledger run).
///
/// One script serves both purposes, the way the imported partition's
/// state script serves as both spending validator and bootstrap minting
/// policy: the `mint` purpose is the application policy whose approval
/// tokens carry the refund binding — minted on the controller's
/// signature at request time, burned exactly once riding the claim the
/// spend purpose folds or cancels — the `spend` purpose governs the
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
  /// Recover control with the committed next key (`LR` rows, issue #62):
  /// reveal the committed next-control address, prove its commitment,
  /// require its payment-key signer, install it as controller with a
  /// fresh commitment. Appended, never reordered: Maintain/Cancel/Fold/
  /// Retire keep their indices or the existing lmlc encodings break.
  Recover {
    revealed_control: ByteArray,
    representatives: List<ByteArray>,
    registry: ByteArray,
  }
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
      Retire { representatives: _ } ->
        retire(record, claim, own_hash, tx)
      Recover { revealed_control, representatives, registry } ->
        recover(
          record,
          revealed_control,
          representatives,
          registry,
          claim,
          own_hash,
          tx,
        )
    }
  }

  mint(
    redeemer: ApplicationMintRedeemer,
    policy_id: PolicyId,
    tx: Transaction,
  ) {
    let WithdrawApproval { controller, destination } = redeemer
    let Transaction { extra_signatories, mint, .. } = tx
    // The approval's asset name IS the refund destination it binds:
    // cancellation later compares against exactly these bytes.
    expect naming.canonical_address(destination)
    let policy_tokens = tokens(mint, policy_id)
    expect [bound] = keys(policy_tokens)
    expect bound == destination
    when get(policy_tokens, bound) is {
      // Minting a fresh approval: exactly one, on the controller's
      // signature (`LC03`: insert approval alone is insufficient;
      // cancellation needs its own).
      Some(1) -> has(extra_signatories, controller)
      // The burn the spend purpose itself demands at Fold and Cancel:
      // exactly -1, and the burned approval must ride exactly one live
      // input at our own application address — the claim the spend
      // purpose consumes with it. The cancellation is unsigned (the
      // approval token is the authorization; the LC rows demand no
      // signers), so no signature is required here.
      Some(-1) -> burn_rides_claim(policy_id, bound, tx)
      _ -> False
    }
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

/// `LR01` accepts; `LR02`/`LR04`/`LR06` (commitment), `LR03`/`LR07`
/// (required signer), `LR08` (fresh commitment), `LR09` (representative),
/// `LR10` (registry) and `LR11` (field preservation) refuse — in the
/// accepted `recoverController` order, so each refusal is attributable:
/// a transaction violating two conditions is refused for the one its row
/// names. Each negative row is a single-defect mutant of the accepted one.
///
/// Ledger realisation (issue #62): the record carries exactly one
/// representative token under the application policy; the redeemer claims
/// it (`representatives`) and the registry binding (`registry`); the
/// validator refuses when the claim disagrees with what the consumed
/// record actually carries — its address (`own_hash`) and its token —
/// making `LR09`/`LR10` real refusals rather than contrived ones. The
/// successor carries the record's value, representative included:
/// recovery moves control, never assets. The naming datum keeps exactly
/// four fields; no fifth field, no new datum shape.
fn recover(
  record: NamingRecord,
  revealed_control: ByteArray,
  representatives: List<ByteArray>,
  registry: ByteArray,
  claim: Input,
  own_hash: ByteArray,
  tx: Transaction,
) -> Bool {
  let Transaction { extra_signatories, .. } = tx
  // The registry binding is the application validator's own hash, read
  // from the spent input's address — the claim must name it (`LR10`).
  expect registry == own_hash
  // The claim must name exactly the representative the consumed record
  // carries under the application policy (`LR09`): a single token, the
  // single-representative shape.
  expect [stored_rep] = keys(tokens(claim.output.value, own_hash))
  expect representatives == [stored_rep]
  // The reveal is a canonical payment-key address (`recovery-payment-key`:
  // no row, but the order is load-bearing for attribution).
  expect Some(shape) = naming.decode_address(revealed_control)
  expect shape.payment_key
  let revealed_hash = shape.payment_hash
  // Domain-separated commitment over the whole binary address including
  // header and network (`recovery-hash-shape` is vacuous — blake2b-256 is
  // always 32 bytes — but the order mirrors the model).
  let computed =
    blake2b_256(
      bytearray.concat(
        bytearray.concat(
          bytearray.from_string(@"singular/naming/next-control/v1"),
          #"00",
        ),
        revealed_control,
      ),
    )
  expect bytearray.length(computed) == 32
  // The reveal's commitment equals the stored next-control commitment
  // (`LR02`, `LR04`, `LR06` — including the forged-digest row that passes
  // iff the domain separation is dropped).
  expect computed == record.next_control_commitment
  // The reveal's payment key is among the required signers (`LR03`,
  // `LR07`). The old controller need not — and for `LR01` must not — sign:
  // required signers are exactly the reveal's key (checked by the runner).
  expect has(extra_signatories, revealed_hash)
  // Exactly one continuation at the application address; its control is
  // exactly the reveal, and its payment destination and quorum are
  // unchanged (`LR11`).
  expect [continuation] = continuation_outputs(record, claim, tx)
  expect InlineDatum(successor_datum) = continuation.datum
  let successor = naming.expect_naming(successor_datum)
  expect successor.control_address == revealed_control
  expect successor.payment_destination == record.payment_destination
  expect successor.retirement_quorum == record.retirement_quorum
  // The record's value — representative included — moves to the successor.
  expect value_preserved(claim.output.value, continuation.value)
  // The successor's commitment is 32 bytes and differs from the consumed
  // one (`LR08`): the consumed commitment cannot be replayed.
  expect bytearray.length(successor.next_control_commitment) == 32
  expect successor.next_control_commitment != record.next_control_commitment
  // The successor datum is well formed (`invalid-fixture`: no row, but the
  // order closes the transition — expect_naming already enforced it, so
  // this names the reason rather than re-checking it).
  expect naming.well_formed(successor)
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

/// A retire consumes the record into completion-only custody (issue
/// #66, `beginRetirement` without the MPFS request layer): authorized by
/// the controller or by a distinct-member quorum threshold
/// (`retirement-authorization`), the representative lands at the custody
/// script (`retirement-request`), and the record does not continue.
///
/// `LT05`/`LT06` are not retirements: they are `maintain` actions refused
/// on `controller-signature` by the existing path.
fn retire(
  record: NamingRecord,
  claim: Input,
  own_hash: ByteArray,
  tx: Transaction,
) -> Bool {
  let Transaction { extra_signatories, outputs, .. } = tx
  // Authorization by exactly one of two routes: the control address's
  // payment key signs, or at least `threshold` distinct stored quorum
  // members sign (`eraseDups` is load-bearing — one member signing twice
  // does not reach a threshold of two).
  expect
    controller_authorized(record, extra_signatories)
      || quorum_authorized(record, extra_signatories)
  // Custody: the record carries a single representative under the
  // application policy (the t62 stand-in shape); exactly its
  // representative lands at the custody script address.
  expect [stored_rep] = keys(tokens(claim.output.value, own_hash))
  expect
    filter(
      outputs,
      fn(output) {
        output.address.payment_credential
          == address.Script(retirement_custody_hash)
          && quantity_of(output.value, own_hash, stored_rep) == 1
      },
    ) != []
  // The record does not continue anywhere in the transaction.
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

/// The control address's payment key is among the required signers.
fn controller_authorized(
  record: NamingRecord,
  extra_signatories: List<VerificationKeyHash>,
) -> Bool {
  has(extra_signatories, naming.control_hash(record))
}

/// At least `threshold` distinct members of the stored retirement quorum
/// are among the required signatories.
fn quorum_authorized(
  record: NamingRecord,
  extra_signatories: List<VerificationKeyHash>,
) -> Bool {
  let RetirementQuorum { threshold, members } = record.retirement_quorum
  let signed =
    filter(members, fn(member) { has(extra_signatories, member) })
  threshold > 0 && naming.distinct_count(signed) >= threshold
}

/// The burn half of Fold/Cancel: the approval being burned must ride
/// exactly one live input at the application validator's own address —
/// the claim or record the spend purpose consumes with it. Without a
/// claim carrying the approval, the burn cannot happen at all.
fn burn_rides_claim(
  policy_id: PolicyId,
  bound: ByteArray,
  tx: Transaction,
) -> Bool {
  let own_credential = address.Script(policy_id)
  expect [claim] =
    filter(
      tx.inputs,
      fn(input) {
        input.output.address.payment_credential == own_credential
          && quantity_of(input.output.value, policy_id, bound) == 1
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
