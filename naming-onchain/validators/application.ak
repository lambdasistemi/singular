use aiken/collection/dict.{get, keys}
use aiken/collection/list.{filter, find, has}
use aiken/collection/pairs
use aiken/crypto.{VerificationKeyHash, blake2b_256}
use aiken/primitive/bytearray
use cardano/address
use cardano/assets.{PolicyId, Value, flatten, lovelace_of, quantity_of, tokens}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Spend, Transaction,
}
use naming
use naming.{NamingRecord, RetirementQuorum, mpfs_state_hash}

/// The registry's own active-token policy (#157 C7): genesis sets it,
/// every fold preserves it. Read from the spent state when present, else
/// from the reference (NOTE-014 item A1) — retires authenticate without
/// spending.
pub fn expected_active_policy(tx: Transaction) -> PolicyId {
  expect InlineDatum(datum) = find_registry_state(tx).output.datum
  naming.mpfs_state_policy(datum)
}

/// The registry state input, NFT-authenticated (issue #77, registry
/// association, NOTE-007; reference path NOTE-014 item A1): the spent
/// state if present, else the referenced state. Both lists use the
/// identical `is_registry_state` predicate — one authentication shape for
/// both paths. The ONE place that decides which UTxO is the registry.
fn find_registry_state(tx: Transaction) -> Input {
  when find(tx.inputs, is_registry_state) is {
    Some(spent) -> spent
    None -> {
      expect Some(referenced) = find(tx.reference_inputs, is_registry_state)
      referenced
    }
  }
}

fn is_registry_state(input: Input) -> Bool {
  when input.output.address.payment_credential is {
    address.Script(hash) ->
      hash == mpfs_state_hash && has_single_cage_token(input.output.value)
    _ -> False
  }
}

/// Exactly one cage token under the state policy (NOTE-009 §3): a single
/// asset NAME is not enough — its quantity must be exactly 1.
fn has_single_cage_token(value: Value) -> Bool {
  let policy_tokens = tokens(value, mpfs_state_hash)
  when keys(policy_tokens) is {
    [name] -> get(policy_tokens, name) == Some(1)
    _ -> False
  }
}

/// The supplied state's own authenticating token name (NOTE-007).
fn expected_registry_token(tx: Transaction) -> ByteArray {
  let policy_tokens =
    tokens(find_registry_state(tx).output.value, mpfs_state_hash)
  expect [token_name] = keys(policy_tokens)
  token_name
}

/// The authenticated registry the application selected: the FULL native
/// asset identity of the cage token — state policy id followed by the
/// token name — the same bytes `witness(kind, registry)` is parametrised
/// by, so both validators authorize against one state.
pub fn registry_identity(tx: Transaction) -> ByteArray {
  registry_asset_id(mpfs_state_hash, expected_registry_token(tx))
}

/// Reference-only selection shared by retirement and its executing
/// witness.
pub fn referenced_registry(tx: Transaction) -> (ByteArray, PolicyId) {
  expect Some(state) = find(tx.reference_inputs, is_registry_state)
  expect [token] = keys(tokens(state.output.value, mpfs_state_hash))
  expect InlineDatum(datum) = state.output.datum
  (registry_asset_id(mpfs_state_hash, token), naming.mpfs_state_policy(datum))
}

/// The retirement custody script hash (issue #66): the only address a
/// `Retire` may place the active token at. Regenerated from the custody
/// validator's own blueprint; never hand-typed.
pub const retirement_custody_hash =
  #"e476a762a1a24f2cbf2193b60c553de5450e0ceadef55f0bdfcda988"

/// The naming application validator (issue #52), in registry mode (#157).
///
/// One script serves both purposes. The `mint` purpose IS the
/// application policy the registry pins: it certifies EDGES. Its
/// approvals are minted at request creation, one per request, carried by
/// the request UTxO and never burned — no script of naming's runs at fold
/// time at all. The cage recomputes each approval's name from the request
/// it rides and refuses a mismatch (C4, D-APPROVAL), so this validator's
/// only job is to decide WHEN an edge may be certified.
///
/// The `spend` purpose governs the record UTxOs the fold creates. There
/// is no pending claim any more, and so no `Fold` and no `Cancel`: a
/// booking is an approval plus a cage request, and the record comes into
/// being as the fold's own output (N3).
///
/// Row demand (from the accepted v0.2.0 corpus, `LM-LR-LT rows`):
///
/// - `LM01..LM04` (`maintain`): maintenance requires the controller's
///   signature and preserves control, commitment and quorum.
/// - `LR01..LR11` (`recover`): the committed next key, revealed and
///   signing, becomes the controller.
/// - `LT02`/`LT03` (`retire`): the quorum route. `LT01` is retired as a
///   row — the current control key alone no longer ends a name
///   (D-TERMINATE, want-ledger R1).
pub type ApplicationRedeemer {
  /// Ordinary maintenance (`LM` rows).
  Maintain
  /// End the name. `key` is the registry key being retired;
  /// `revealed_control` is the preimage of the record's
  /// `next_control_commitment` — the recovery route's proof — or empty
  /// bytes when the quorum is the route instead.
  ///
  /// The reveal rides the redeemer because `retire` needs exactly the
  /// proof `recover` needs, and nothing else in a transaction carries a
  /// full binary address (functions-model, `retire(...)`).
  Retire { key: ByteArray, revealed_control: ByteArray }
  /// Recover control with the committed next key (`LR` rows, issue #62).
  Recover { revealed_control: ByteArray, registry: ByteArray }
}

/// Redeemer of the application policy's mint purpose (#157 N2): certify
/// one edge of C2 for one key, one owner and one destination. The asset
/// name minted must equal the approval binding of exactly that tuple.
///
/// `WithdrawApproval` and `InsertApproval` are retired with the claim
/// mechanism — a declared contract change, listed in the conformance
/// page.
pub type ApplicationMintRedeemer {
  Approve {
    edge: Int,
    key: ByteArray,
    owner: ByteArray,
    destination: (ByteArray, ByteArray),
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
      Retire { key, revealed_control } ->
        when single_asset_name(claim.output.value) is {
          Some(stored) ->
            retire(
              record,
              claim,
              stored,
              key,
              revealed_control,
              own_hash,
              tx,
            )
          None -> {
            trace @"record-single-asset"
            False
          }
        }
      Recover { revealed_control, registry } ->
        when single_asset_name(claim.output.value) is {
          None -> {
            trace @"record-single-asset"
            False
          }
          Some(stored) ->
            recover(record, stored, revealed_control, registry, claim, own_hash, tx)
        }
    }
  }

  mint(
    redeemer: ApplicationMintRedeemer,
    policy_id: PolicyId,
    tx: Transaction,
  ) {
    let policy_tokens = tokens(tx.mint, policy_id)
    // Exactly one asset moves under our policy per transaction: one
    // approval minted, one request certified.
    when keys(policy_tokens) is {
      [bound] -> {
        let Approve { edge, key, owner, destination } = redeemer
        if get(policy_tokens, bound) != Some(1) {
          trace @"approval-quantity"
          False
        } else if bound != approval_name(edge, key, owner, destination) {
          // The name IS the binding (D-APPROVAL). The cage recomputes the
          // same bytes from the request; one formula, two partitions.
          trace @"approval-binding"
          False
        } else {
          approve(edge, key, owner, destination, policy_id, tx)
        }
      }
      _ -> {
        trace @"approval-quantity"
        False
      }
    }
  }

  else(_) {
    fail
  }
}

/// The approval binding (#157 D-APPROVAL): the identical formula the
/// cage recomputes — `blake2b_256(edge ‖ key ‖ owner ‖ destination)`,
/// the destination being its address bytes followed by its datum hash.
/// Transcribed rather than imported because the package fence blocks the
/// import; drift makes honest bookings refuse LOUDLY at the fold.
pub fn approval_name(
  edge: Int,
  key: ByteArray,
  owner: ByteArray,
  destination: (ByteArray, ByteArray),
) -> ByteArray {
  let (dest_address, datum_hash) = destination
  blake2b_256(
    bytearray.from_int_big_endian(edge, 1)
      |> bytearray.concat(key)
      |> bytearray.concat(owner)
      |> bytearray.concat(dest_address)
      |> bytearray.concat(datum_hash),
  )
}

/// The six arms of R-NM4 (#157 N2). Edge indices are the C2 row indices:
/// `0` insertAbsent, `1` insertActive, `2` updateActive, `3`
/// updateTerminal, `4` deleteAbsent, `5` deleteActive.
fn approve(
  edge: Int,
  key: ByteArray,
  owner: ByteArray,
  destination: (ByteArray, ByteArray),
  policy_id: PolicyId,
  tx: Transaction,
) -> Bool {
  let (dest_address, datum_hash) = destination
  if edge == 0 {
    // insertAbsent — anyone may witness that a name is free. What the
    // approval binds is where the deposit goes back to: `owner` is the
    // refund address's payment key, and the request's destination names
    // that address. No signature: Carol needs nobody's permission to say
    // a name is unclaimed, and she alone can retract it later.
    if datum_hash != #"" {
      trace @"absence-names-no-datum"
      False
    } else if !refund_binds(dest_address, owner) {
      trace @"absence-refund-binding"
      False
    } else {
      True
    }
  } else if edge == 1 || edge == 2 {
    // insertActive / updateActive — the controller who will own the
    // record signs, and the destination binds the record datum, so the
    // folder cannot create Alice's record with a controller of its own
    // choosing (D-DEST).
    if !has(tx.extra_signatories, owner) {
      trace @"controller-signature"
      False
    } else if !record_destination(dest_address, datum_hash, policy_id) {
      trace @"record-destination"
      False
    } else {
      True
    }
  } else if edge == 3 {
    // updateTerminal — the same transaction must be the `Retire` that
    // proves the committed recovery key or the quorum. The proof is
    // checked once, by `retire`; this arm requires its presence, so a
    // terminate approval cannot be minted on its own.
    if destination != (#"", #"") {
      trace @"termination-names-no-destination"
      False
    } else if !retire_present(key, policy_id, tx) {
      trace @"retire-required"
      False
    } else {
      True
    }
  } else if edge == 4 {
    // deleteAbsent — the refund address the cage recorded in custody for
    // this key signs. The custody UTxO is read as a REFERENCE input: the
    // fold spends it, this arm only reads what it says.
    if destination != (#"", #"") {
      trace @"deletion-names-no-destination"
      False
    } else if !custody_refund_signs(key, owner, tx) {
      trace @"custody-refund-signature"
      False
    } else {
      True
    }
  } else {
    // deleteActive — never certified. A live registration does not
    // return to absence; it ends (`updateTerminal`) or it is deleted by
    // nobody.
    trace @"never-certified"
    False
  }
}

/// The refund address is canonical, pays a key, and that key is the
/// `owner` the approval binds.
fn refund_binds(dest_address: ByteArray, owner: ByteArray) -> Bool {
  when naming.decode_address(dest_address) is {
    Some(shape) -> shape.payment_key && shape.payment_hash == owner
    None -> False
  }
}

/// The destination of a booking is the application's own address, and it
/// names a well-formed (32-byte) datum hash.
fn record_destination(
  dest_address: ByteArray,
  datum_hash: ByteArray,
  policy_id: PolicyId,
) -> Bool {
  when naming.decode_address(dest_address) is {
    Some(shape) ->
      !shape.payment_key && shape.payment_hash == policy_id && bytearray.length(
        datum_hash,
      ) == 32
    None -> False
  }
}

/// A `Retire` for this key is being executed in this transaction, BY THIS
/// APPLICATION, on the real record of this key (#157 F-002).
///
/// A redeemer alone proves nothing: any script permissive enough to
/// accept a `Retire`-shaped redeemer would otherwise certify the
/// termination of a name it has never governed. So the governing input is
/// authenticated three ways before its redeemer is read — it sits at this
/// validator's OWN address (the spend and mint purposes are one script,
/// so the policy id IS the script hash), its datum decodes as a naming
/// record, and it holds exactly one active token named `key` under the
/// policy the AUTHENTICATED registry state pins. That last one is what
/// binds the certification to a registry: the active policy is not a
/// literal, it is read from the NFT-authenticated state this transaction
/// carries.
fn retire_present(key: ByteArray, policy_id: PolicyId, tx: Transaction) -> Bool {
  when active_policy(tx) is {
    None -> False
    Some(active) ->
      find(
        tx.inputs,
        fn(input) {
          governs_key(input, key, policy_id, active) && spent_retiring(
            input,
            key,
            tx,
          )
        },
      ) != None
  }
}

/// This input is this application's own record UTxO for `key`, holding
/// the registry's active token for that key.
fn governs_key(
  input: Input,
  key: ByteArray,
  policy_id: PolicyId,
  active: PolicyId,
) -> Bool {
  input.output.address.payment_credential == address.Script(policy_id) && (
    when input.output.datum is {
      InlineDatum(datum) -> naming.is_naming_datum(datum)
      _ -> False
    }
  ) && quantity_of(input.output.value, active, key) == 1
}

/// That input is being spent with a `Retire` naming this key.
fn spent_retiring(input: Input, key: ByteArray, tx: Transaction) -> Bool {
  when pairs.get_first(tx.redeemers, Spend(input.output_reference)) is {
    Some(data) ->
      if data is Retire { key: retired, revealed_control: _ }: ApplicationRedeemer {
        retired == key
      } else {
        False
      }
    None -> False
  }
}

/// The registry's active-token policy, TOTAL: `None` when this
/// transaction carries no authenticated registry state at all, so a
/// hostile shape refuses with one named trace instead of crashing.
fn active_policy(tx: Transaction) -> Option<PolicyId> {
  when find(tx.inputs, is_registry_state) is {
    Some(spent) -> state_policy_of(spent)
    None ->
      when find(tx.reference_inputs, is_registry_state) is {
        Some(referenced) -> state_policy_of(referenced)
        None -> None
      }
  }
}

fn state_policy_of(input: Input) -> Option<PolicyId> {
  when input.output.datum is {
    InlineDatum(datum) -> Some(naming.mpfs_state_policy(datum))
    _ -> None
  }
}

/// The custody UTxO for this key, read as a reference input, records a
/// refund address whose payment key is `owner` — and `owner` signs.
fn custody_refund_signs(
  key: ByteArray,
  owner: ByteArray,
  tx: Transaction,
) -> Bool {
  when
    find(
      tx.reference_inputs,
      fn(input) {
        is_cage_address(input) && custody_key_of(input) == Some(key)
      },
    )
  is {
    Some(custody) ->
      when custody_refund_of(custody) is {
        Some(refund) ->
          refund_binds(refund, owner) && has(tx.extra_signatories, owner)
        None -> False
      }
    None -> False
  }
}

fn is_cage_address(input: Input) -> Bool {
  input.output.address.payment_credential == address.Script(mpfs_state_hash)
}

fn custody_key_of(input: Input) -> Option<ByteArray> {
  when input.output.datum is {
    InlineDatum(datum) ->
      when naming.mpfs_custody(datum) is {
        Some((key, _)) -> Some(key)
        None -> None
      }
    _ -> None
  }
}

fn custody_refund_of(input: Input) -> Option<ByteArray> {
  when input.output.datum is {
    InlineDatum(datum) ->
      when naming.mpfs_custody(datum) is {
        Some((_, refund)) -> Some(refund)
        None -> None
      }
    _ -> None
  }
}

/// `LM01` accepts; `LM02` (no signature), `LM03` (tampered control or
/// recovery field) and `LM04` (altered quorum) refuse. NM2 (#157 N9):
/// maintenance never touches the trie, so the registry state may not be
/// a spent input of this transaction at all.
fn maintain(record: NamingRecord, claim: Input, tx: Transaction) -> Bool {
  if registry_is_spent(tx) {
    trace @"no-registry-spend"
    False
  } else {
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
    // The record's value — including its active token — is preserved.
    value_preserved(claim.output.value, continuation.value)
  }
}

fn registry_is_spent(tx: Transaction) -> Bool {
  find(tx.inputs, is_registry_state) != None
}

/// The domain-separated commitment over a full binary address, exactly as
/// the accepted corpus computes it. Shared by `recover` and `retire`:
/// termination needs the proof recovery needs, and nothing weaker.
fn next_control_commitment(revealed_control: ByteArray) -> ByteArray {
  blake2b_256(
    bytearray.concat(
      bytearray.concat(
        bytearray.from_string(@"singular/naming/next-control/v1"),
        #"00",
      ),
      revealed_control,
    ),
  )
}

/// Does this reveal prove the record's committed next-control key, and
/// does that key sign? The one proof `Recover` uses (#157 D-TERMINATE).
fn recovery_proved(
  record: NamingRecord,
  revealed_control: ByteArray,
  extra_signatories: List<VerificationKeyHash>,
) -> Bool {
  when naming.decode_address(revealed_control) is {
    Some(shape) ->
      shape.payment_key && next_control_commitment(revealed_control) == record.next_control_commitment && has(
        extra_signatories,
        shape.payment_hash,
      )
    None -> False
  }
}

/// `LR01` accepts; `LR02`/`LR04`/`LR06` (commitment), `LR03`/`LR07`
/// (required signer), `LR08` (fresh commitment), `LR09` (active token),
/// `LR10` (registry) and `LR11` (field preservation) refuse — in the
/// accepted `recoverController` order, so each refusal is attributable.
fn recover(
  record: NamingRecord,
  stored: ByteArray,
  revealed_control: ByteArray,
  registry: ByteArray,
  claim: Input,
  own_hash: ByteArray,
  tx: Transaction,
) -> Bool {
  if registry_is_spent(tx) {
    trace @"no-registry-spend"
    False
  } else {
    let Transaction { extra_signatories, .. } = tx
    // The registry binding is the application validator's own hash, read
    // from the spent input's address — the claim must name it (`LR10`).
    expect registry == own_hash
    // The record carries exactly one non-ADA asset: the active token the
    // fold minted for it (`LR09`).
    expect stored != #""
    // The reveal is a canonical payment-key address, its commitment is
    // the stored one, and its key signs (`LR02`-`LR07`).
    expect Some(shape) = naming.decode_address(revealed_control)
    expect shape.payment_key
    expect bytearray.length(next_control_commitment(revealed_control)) == 32
    expect next_control_commitment(revealed_control) == record.next_control_commitment
    expect has(extra_signatories, shape.payment_hash)
    // Exactly one continuation at the application address; its control is
    // exactly the reveal, and its destination and quorum are unchanged
    // (`LR11`).
    expect [continuation] = continuation_outputs(record, claim, tx)
    expect InlineDatum(successor_datum) = continuation.datum
    let successor = naming.expect_naming(successor_datum)
    expect successor.control_address == revealed_control
    expect successor.payment_destination == record.payment_destination
    expect successor.retirement_quorum == record.retirement_quorum
    // The successor's commitment is 32 bytes and differs from the
    // consumed one (`LR08`): the consumed commitment cannot be replayed.
    expect bytearray.length(successor.next_control_commitment) == 32
    expect successor.next_control_commitment != record.next_control_commitment
    expect naming.well_formed(successor)
    value_preserved(claim.output.value, continuation.value)
  }
}

/// A retire consumes the record into completion-only custody (issue #66),
/// and in registry mode it also co-creates the completion request that
/// will fold `Update(0x01, 0x02)` (#157 N4).
///
/// **Who may end a name (D-TERMINATE, want-ledger R1, 2026-09-16).** The
/// committed recovery key — revealed and signing, the proof `Recover`
/// uses — or a distinct-member quorum. The CURRENT control key alone does
/// not: a thief holding Alice's current key can change where her name
/// pays until she recovers, but they cannot end it, because the recovery
/// key is the one thing they do not have. `LT01` is retired as a row.
fn retire(
  record: NamingRecord,
  claim: Input,
  stored: ByteArray,
  key: ByteArray,
  revealed_control: ByteArray,
  own_hash: ByteArray,
  tx: Transaction,
) -> Bool {
  let Transaction { extra_signatories, outputs, .. } = tx
  if !recovery_proved(record, revealed_control, extra_signatories) && !quorum_authorized(
    record,
    extra_signatories,
  ) {
    trace @"retire-needs-recovery-key"
    False
  } else {
    let (_, expected) = referenced_registry(tx)
    // The record carries the active token of exactly this key (D-ASSET:
    // under each token policy the asset name IS the registry key), and
    // exactly that asset lands at the custody script.
    if stored != key || quantity_of(claim.output.value, expected, stored) != 1 {
      trace @"retirement-token"
      False
    } else if filter(
      outputs,
      fn(output) {
        output.address.payment_credential == address.Script(
          retirement_custody_hash,
        ) && quantity_of(output.value, expected, stored) == 1
      },
    ) == [] {
      trace @"retirement-request"
      False
    } else if filter(
      outputs,
      fn(output) {
        when output.datum is {
          InlineDatum(datum) -> naming.is_same_record(datum, record)
          _ -> False
        }
      },
    ) != [] {
      // The record does not continue anywhere in the transaction.
      trace @"retirement-continuation"
      False
    } else {
      // #157 F-003 — the two obligations a retirement CO-CREATES. Ending
      // a name is a tree edge, so it is not finished by moving the token
      // to custody: the same transaction must book the `updateTerminal`
      // edge against the registry, or the record is destroyed while the
      // trie still says the name is live. Both halves are required here,
      // and the approval is checked against the request that carries it,
      // so neither can be satisfied by a stray token.
      when retirement_completion(key, own_hash, tx) is {
        None -> {
          trace @"retirement-request-missing"
          False
        }
        Some(bound) ->
          if quantity_of(tx.mint, own_hash, bound) != 1 {
            trace @"retirement-approval-missing"
            False
          } else {
            True
          }
      }
    }
  }
}

/// The completion request this retirement creates: exactly one output at
/// the cage, whose datum is a request for `key` folding `Update(0x01,
/// 0x02)` — live to over — and which CARRIES the terminate approval bound
/// to its own owner. Answers that approval's name, so the caller can
/// require the matching mint. `None` when the obligation is unmet.
fn retirement_completion(
  key: ByteArray,
  own_hash: ByteArray,
  tx: Transaction,
) -> Option<ByteArray> {
  when
    filter(
      tx.outputs,
      fn(output) {
        output.address.payment_credential == address.Script(mpfs_state_hash) && completion_owner_of(
          output,
          key,
        ) != None
      },
    )
  is {
    [request] ->
      when completion_owner_of(request, key) is {
        Some(owner) -> {
          // The terminate edge names no destination (R-NM4 row 3), so the
          // binding is over the key and its owner alone.
          let bound = approval_name(3, key, owner, (#"", #""))
          if quantity_of(request.value, own_hash, bound) == 1 {
            Some(bound)
          } else {
            None
          }
        }
        None -> None
      }
    _ -> None
  }
}

fn completion_owner_of(output: Output, key: ByteArray) -> Option<ByteArray> {
  when output.datum is {
    InlineDatum(datum) -> naming.completion_request_owner(datum, key)
    _ -> None
  }
}

/// At least `threshold` distinct members of the stored retirement quorum
/// are among the required signatories.
fn quorum_authorized(
  record: NamingRecord,
  extra_signatories: List<VerificationKeyHash>,
) -> Bool {
  let RetirementQuorum { threshold, members } = record.retirement_quorum
  let signed = filter(members, fn(member) { has(extra_signatories, member) })
  threshold > 0 && naming.distinct_count(signed) >= threshold
}

/// The registry asset identity (NOTE-007): the FULL native asset identity
/// of the cage token — state policy id plus cage token name — as the raw
/// component bytes in that order.
fn registry_asset_id(
  state_policy_bytes: ByteArray,
  token_name: ByteArray,
) -> ByteArray {
  expect bytearray.length(state_policy_bytes) == 28
  bytearray.concat(state_policy_bytes, token_name)
}

fn non_ada_assets(value: Value) -> List<(PolicyId, ByteArray, Int)> {
  filter(
    flatten(value),
    fn(entry) {
      let (policy, _, _) = entry
      policy != #""
    },
  )
}

/// A record carries exactly one non-ADA asset: its active token.
/// Malformed cardinality is reported by the caller before reading the
/// name.
fn single_asset_name(value: Value) -> Option<ByteArray> {
  when non_ada_assets(value) is {
    [(_, name, _)] -> Some(name)
    _ -> None
  }
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

/// Non-ADA policy, name and quantity are identical; ADA may only
/// increase.
fn value_preserved(previous: Value, next: Value) -> Bool {
  if lovelace_of(next) >= lovelace_of(previous) && non_ada_assets(next) == non_ada_assets(
    previous,
  ) {
    True
  } else {
    trace @"record-value-preservation"
    False
  }
}
