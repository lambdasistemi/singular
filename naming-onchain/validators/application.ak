use aiken/collection/dict.{get, keys}
use aiken/collection/list.{all, filter, find, has, length}
use aiken/crypto.{VerificationKeyHash, blake2b_256}
use aiken/primitive/bytearray
use cardano/address
use cardano/assets.{flatten, lovelace_of, quantity_of, tokens, PolicyId, Value}
use cardano/transaction.{InlineDatum, Input, Output, OutputReference, Transaction}
use naming.{NamingRecord, RetirementQuorum, mpfs_state_hash}

/// The expected representative policy from the spent registry state (issue
/// #77, E-001): genesis sets it, `validModify` preserves it. The spent state
/// is the input at the MPFS address carrying exactly one cage token under
/// the state policy — requests and forgeries at the same address carry none
/// (the cage NFT is seed-gated and unforgeable), so the token authenticates
/// without decoding. Folds and retires without a spent state refuse — honest
/// connected transactions always spend the state via `Modify`.
fn expected_rep_policy(tx: Transaction) -> PolicyId {
  expect Some(state_input) =
    find(tx.inputs, fn(input) {
      when input.output.address.payment_credential is {
        address.Script(hash) ->
          hash == mpfs_state_hash
            && length(keys(tokens(input.output.value, mpfs_state_hash))) == 1
        _ -> False
      }
    })
  expect InlineDatum(datum) = state_input.output.datum
  naming.mpfs_state_policy(datum)
}

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
/// binds, or (issue #77) the insert approval whose asset name is the
/// domain-separated hash of the proposal core it binds. The controller
/// must sign in both arms. Appended, never reordered: `InsertApproval`
/// is index 1 and `WithdrawApproval` keeps index 0, or the merged
/// runners' mint encodings break.
pub type ApplicationMintRedeemer {
  WithdrawApproval { controller: VerificationKeyHash, destination: ByteArray }
  InsertApproval {
    controller: VerificationKeyHash,
    control: ByteArray,
    commitment: ByteArray,
  }
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
      Fold { representatives } ->
        fold(record, representatives, claim, own_hash, tx)
      Retire { representatives: _ } ->
        retire(record, claim, tx)
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
    let Transaction { extra_signatories, mint, .. } = tx
    let policy_tokens = tokens(mint, policy_id)
    // Exactly one asset moves under our policy per transaction: one
    // approval minted or burned.
    expect [bound] = keys(policy_tokens)
    when redeemer is {
      WithdrawApproval { controller, destination } -> {
        // The approval's asset name IS the refund destination it binds:
        // cancellation later compares against exactly these bytes.
        expect naming.canonical_address(destination)
        expect bound == destination
        approval_roundtrip(
          policy_id,
          bound,
          get(policy_tokens, bound),
          extra_signatories,
          controller,
          tx,
        )
      }
      InsertApproval { controller, control, commitment } -> {
        // The approval's asset name IS the bound proposal hash: the
        // insert fold later recomputes it from the frozen datum.
        expect bound == insert_approval_name(control, commitment)
        approval_roundtrip(
          policy_id,
          bound,
          get(policy_tokens, bound),
          extra_signatories,
          controller,
          tx,
        )
      }
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
/// Ledger realisation (issues #62, #77): the record carries exactly one
/// representative token under the representative policy, minted by the
/// insert fold that created the record; the redeemer claims
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
  // carries (`LR09`): a single non-ADA asset — the representative the
  // insert fold minted under the representative policy (issue #77; the
  // application-policy stand-in is gone) — so the
  // single-representative shape holds whatever policy carries it.
  let stored_rep = single_asset_name(claim.output.value)
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
  representatives: List<ByteArray>,
  claim: Input,
  own_hash: ByteArray,
  tx: Transaction,
) -> Bool {
  let Transaction { mint, .. } = tx
  // Exactly one approval rides the claim under our own policy —
  // withdraw or insert. No token, no fold.
  let approval = single_asset_name(claim.output.value)
  // The approval is consumed: burned exactly once, and nothing else
  // moves under our policy.
  expect [burned] = keys(tokens(mint, own_hash))
  expect burned == approval
  expect quantity_of(mint, own_hash, approval) == -1
  expect [continuation] = continuation_outputs(record, claim, tx)
  expect InlineDatum(successor_datum) = continuation.datum
  expect naming.is_same_record(successor_datum, record)
  // The record inherits the claim's value minus the consumed approval.
  expect value_preserved_except(
    claim.output.value,
    continuation.value,
    own_hash,
  )
  when representatives is {
    [] -> {
      // The withdraw-approval fold (`LC`/`LM` rows): the consumed
      // approval is the canonical-shaped refund binding, never an
      // insert hash.
      expect naming.canonical_address(approval)
      True
    }
    _ -> {
      // The insert fold (`Singular.foldOne` `.insert`): the consumed
      // approval binds this exact datum — recomputed, never trusted
      // from the redeemer.
      expect approval
        == insert_approval_name(
          record.control_address,
          record.next_control_commitment,
        )
      // `representative-identity`: the names are exactly this
      // record's representative under the representative policy.
      expect representatives
        == [representative_name(naming.control_hash(record))]
      // `representative-policy` (issue #77, E-001): the moved
      // representative's policy is the registry's own configuration — the
      // spent state's expected policy, genesis-set and `Modify`-preserved.
      // A foreign-policy fake carries the right name under the wrong
      // policy and refuses here. Certified output, mint and value thirds:
      // the fold mints exactly once under the expected policy, and the
      // record carries each named representative exactly once under it.
      let expected = expected_rep_policy(tx)
      expect
        all(representatives, fn(name) {
          quantity_of(mint, expected, name) == 1
        })
      expect
        all(representatives, fn(name) {
          quantity_of(continuation.value, expected, name) == 1
        })
      True
    }
  }
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
  // Custody: the record carries a single representative (issue #77: the
  // insert fold minted it under the representative policy); exactly
  // that asset, under the registry's expected policy (issue #77, E-001),
  // lands at the custody script address. `representative-policy` refuses
  // foreign-policy fakes. The representative moves, it does not burn here
  // (completion burns it later) — so no mint rides a retire.
  let stored_rep = single_asset_name(claim.output.value)
  let expected = expected_rep_policy(tx)
  expect quantity_of(claim.output.value, expected, stored_rep) == 1
  expect
    filter(
      outputs,
      fn(output) {
        output.address.payment_credential
          == address.Script(retirement_custody_hash)
          && quantity_of(output.value, expected, stored_rep) == 1
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

/// The insert-approval name bound at mint and recomputed at fold:
/// `BLAKE2b-256("singular/naming/insert-approval/v1" || 0x00 ||
/// control address || next-control commitment)`. The shape mirrors the
/// next-control commitment; 32 bytes, so never a canonical address and
/// never confusable with a withdraw approval.
fn insert_approval_name(control: ByteArray, commitment: ByteArray) -> ByteArray {
  blake2b_256(
    bytearray.concat(
      bytearray.concat(
        bytearray.concat(
          bytearray.from_string(@"singular/naming/insert-approval/v1"),
          #"00",
        ),
        control,
      ),
      commitment,
    ),
  )
}

/// The representative asset name for a record (`Singular.representative`
/// scoped by the entry's incarnation): `Rep || control key hash ||
/// incarnation byte`. Fresh inserts carry incarnation `0x00`; the
/// registry half of the scope lives in the representative policy
/// itself, parameterized by the application policy hash. 32 bytes, so
/// never a canonical address.
fn representative_name(control_hash: ByteArray) -> ByteArray {
  bytearray.concat(
    bytearray.concat(#"526570", control_hash),
    #"00",
  )
}

/// The single non-ADA asset name a claim or record carries — the
/// approval on a claim, the representative on a folded record. More
/// than one, or none, refuses: the single-token shape Lean's `supply`
/// counts.
fn single_asset_name(value: Value) -> ByteArray {
  let named =
    filter(
      flatten(value),
      fn(entry) {
        let (policy_id, _name, _quantity) = entry
        policy_id != #""
      },
    )
  expect [only] = named
  let (_policy, asset_name, _quantity) = only
  asset_name
}

/// Does this value carry exactly one unit of the named asset under any
/// policy but ADA? The representative policy's exact-movement rule
/// fixes which policy may move the name; here the name is what binds.
fn value_carries_name(value: Value, asset_name: ByteArray) -> Bool {
  length(
    filter(
      flatten(value),
      fn(entry) {
        let (policy_id, name, quantity) = entry
        policy_id != #"" && name == asset_name && quantity == 1
      },
    ),
  ) == 1
}

/// The shared mint/burn roundtrip both approval arms ride: a fresh
/// approval mints exactly once on the controller's signature; the burn
/// the spend purpose itself demands at Fold and Cancel burns exactly
/// once, riding the claim the spend purpose consumes with it.
fn approval_roundtrip(
  policy_id: PolicyId,
  bound: ByteArray,
  minted: Option<Int>,
  extra_signatories: List<VerificationKeyHash>,
  controller: VerificationKeyHash,
  tx: Transaction,
) -> Bool {
  when minted is {
    // Minting a fresh approval: exactly one, on the controller's
    // signature.
    Some(1) -> has(extra_signatories, controller)
    // The burn the spend purpose itself demands at Fold and Cancel:
    // exactly -1, and the burned approval must ride exactly one live
    // input at the application validator's own address.
    Some(-1) -> burn_rides_claim(policy_id, bound, tx)
    _ -> False
  }
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
