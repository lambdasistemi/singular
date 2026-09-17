use aiken/collection/list
use aiken/crypto.{blake2b_256}
use aiken/fuzz
use aiken/primitive/bytearray
use application
use application.{Approve, Maintain, Recover, Retire}
use cardano/address
use cardano/assets
use cardano/assets.{add, from_lovelace, zero}
use cardano/transaction
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Spend, Transaction,
}
use fixtures
use naming
use naming.{NamingRecord, RetirementQuorum}
use witness

/// Registry-mode rows for naming (#157 Gate S): the six approval arms,
/// the fold-created record, retirement's authority, completion, and the
/// three token policies.
///
/// Naming is an INSTANCE of the registry now. Nothing of its runs at fold
/// time: the approval its mint purpose certifies is evidence the cage
/// recomputes, and the witness policies only refuse to let a token move
/// when the cage is not there to say how many.

// ----------------------------------------------------------------------------
// Fixtures
// ----------------------------------------------------------------------------

/// The application policy's own script hash — 28 bytes, because a record
/// destination names the application's own address and the mint purpose
/// compares the two.
const appPolicy: ByteArray =
  #"a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9"

/// The application's own enterprise script address, as a destination
/// carries it.
const recordAddress: ByteArray =
  #"71a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9"

const registryKey: ByteArray = #"616c696365"

const otherKey: ByteArray = #"626f62"

const controllerKey: ByteArray =
  #"0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c"

const inserterKey: ByteArray =
  #"a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbc"

const inserterAddress: ByteArray =
  #"61a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbc"

const strangerKey: ByteArray =
  #"d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebec"

const strangerAddress: ByteArray =
  #"61d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebec"

const recordDatumHash: ByteArray =
  #"1111111111111111111111111111111111111111111111111111111111111111"

/// The three token policies of this instance.
const activePolicy: ByteArray = fixtures.rep_policy

const absentPolicy: ByteArray =
  #"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"

const terminalPolicy: ByteArray =
  #"c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0"

fn bookingDestination() -> (ByteArray, ByteArray) {
  (recordAddress, recordDatumHash)
}

fn refundDestination() -> (ByteArray, ByteArray) {
  (inserterAddress, #"")
}

fn noDestination() -> (ByteArray, ByteArray) {
  (#"", #"")
}

/// The full native asset identity of this registry's cage token — the
/// parameter every witness instance is bound to.
fn registryId() -> ByteArray {
  bytearray.concat(naming.mpfs_state_hash, fixtures.mock_registry_token)
}

fn approvalOf(
  edge: Int,
  key: ByteArray,
  owner: ByteArray,
  destination: (ByteArray, ByteArray),
) -> ByteArray {
  application.approval_name(edge, key, owner, destination)
}

/// A transaction that mints one approval, with whatever else the row
/// needs around it.
fn mintTx(
  edge: Int,
  key: ByteArray,
  owner: ByteArray,
  destination: (ByteArray, ByteArray),
  signers: List<ByteArray>,
  inputs: List<Input>,
  references: List<Input>,
  redeemers: Pairs<transaction.ScriptPurpose, Data>,
) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    mint: add(zero, appPolicy, approvalOf(edge, key, owner, destination), 1),
    extra_signatories: signers,
    inputs,
    reference_inputs: references,
    redeemers,
  }
}

fn certify(
  edge: Int,
  key: ByteArray,
  owner: ByteArray,
  destination: (ByteArray, ByteArray),
  tx: Transaction,
) -> Bool {
  application.application.mint(
    Approve { edge, key, owner, destination },
    appPolicy,
    tx,
  )
}

/// The custody UTxO the cage created for an absence witness, read as a
/// REFERENCE input by the `deleteAbsent` arm.
fn custodyReference(key: ByteArray, refund: ByteArray) -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: #"435553544f4459",
      output_index: 0,
    },
    output: Output {
      address: address.from_script(naming.mpfs_state_hash),
      value: add(from_lovelace(2_000_000), absentPolicy, key, 1),
      datum: InlineDatum(naming.MpfsAbsentCustody { key, refund }),
      reference_script: None,
    },
  }
}

// ============================================================================
// N1, N2 — booking edges are certified by the controller who will own the
// record, and bind the record datum
// ============================================================================

fn bookingCertified(edge: Int, signers: List<ByteArray>) -> Bool {
  certify(
    edge,
    registryKey,
    controllerKey,
    bookingDestination(),
    mintTx(
      edge,
      registryKey,
      controllerKey,
      bookingDestination(),
      signers,
      [],
      [],
      [],
    ),
  )
}

test t157_n1_insert_active_with_controller_signature_accepts() {
  bookingCertified(1, [controllerKey])
}

test t157_n1_insert_active_without_signature_refuses() fail {
  bookingCertified(1, [])
}

/// The binding is over all four components: a different edge for the same
/// key, owner and destination is a different approval, so an approval
/// certified for one edge cannot be spent on another.
test t157_n1_prop_approval_name_binds_the_edge(
  pair via fuzz.tuple(fuzz.int_between(0, 5), fuzz.int_between(0, 5)),
) {
  let (left, right) = pair
  let nameOf =
    fn(edge) {
      approvalOf(edge, registryKey, controllerKey, bookingDestination())
    }
  if left == right {
    nameOf(left) == nameOf(right)
  } else {
    nameOf(left) != nameOf(right)
  }
}

test t157_n2_update_active_with_controller_signature_accepts() {
  bookingCertified(2, [controllerKey])
}

test t157_n2_update_active_without_signature_refuses() fail {
  bookingCertified(2, [])
}

// ============================================================================
// N3 — anyone may witness that a name is free
// ============================================================================

/// `insertAbsent` needs no signature at all: Carol needs nobody's
/// permission to say a name is unclaimed. What the approval binds is
/// where her deposit comes back to.
test t157_n3_insert_absent_without_any_signature_accepts() {
  certify(
    0,
    registryKey,
    inserterKey,
    refundDestination(),
    mintTx(0, registryKey, inserterKey, refundDestination(), [], [], [], []),
  )
}

// ============================================================================
// N4 — deleting an absence witness needs the refund address it recorded
// ============================================================================

fn deleteAbsentCertified(
  owner: ByteArray,
  signers: List<ByteArray>,
  references: List<Input>,
) -> Bool {
  certify(
    4,
    registryKey,
    owner,
    noDestination(),
    mintTx(
      4,
      registryKey,
      owner,
      noDestination(),
      signers,
      [],
      references,
      [],
    ),
  )
}

test t157_n4_delete_absent_by_the_recorded_refund_accepts() {
  deleteAbsentCertified(
    inserterKey,
    [inserterKey],
    [custodyReference(registryKey, inserterAddress)],
  )
}

test t157_n4_delete_absent_by_another_address_refuses() fail {
  deleteAbsentCertified(
    strangerKey,
    [strangerKey],
    [custodyReference(registryKey, inserterAddress)],
  )
}

test t157_n4_delete_absent_unsigned_refuses() fail {
  deleteAbsentCertified(
    inserterKey,
    [],
    [custodyReference(registryKey, inserterAddress)],
  )
}

test t157_n4_delete_absent_without_custody_reference_refuses() fail {
  deleteAbsentCertified(inserterKey, [inserterKey], [])
}

/// The refund binding reads the custody datum, never the redeemer: for
/// any owner that is not the payment key of the address the cage
/// recorded, the arm refuses.
test t157_n4_prop_refund_binding_reads_the_custody(
  owner via fuzz.bytearray_between(28, 28),
) {
  let certified =
    deleteAbsentCertified(
      owner,
      [owner],
      [custodyReference(registryKey, inserterAddress)],
    )
  if owner == inserterKey {
    certified
  } else {
    !certified
  }
}

// ============================================================================
// N5 — a live registration never returns to absence
// ============================================================================

test t157_n5_delete_active_is_never_certified_refuses() fail {
  certify(
    5,
    registryKey,
    controllerKey,
    noDestination(),
    mintTx(
      5,
      registryKey,
      controllerKey,
      noDestination(),
      [controllerKey, inserterKey, strangerKey],
      [],
      [],
      [],
    ),
  )
}

// ============================================================================
// N6 — who may end a name
// ============================================================================

const recoveryReveal: ByteArray =
  #"611d1e1f202122232425262728292a2b2c2d2e2f303132333435363738"

const recoveryKey: ByteArray =
  #"1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738"

fn recoveryCommitment() -> ByteArray {
  blake2b_256(
    bytearray.concat(
      bytearray.concat(
        bytearray.from_string(@"singular/naming/next-control/v1"),
        #"00",
      ),
      recoveryReveal,
    ),
  )
}

fn retirementRecord() -> NamingRecord {
  NamingRecord {
    control_address: fixtures.control,
    payment_destination: naming.NoDestination,
    next_control_commitment: recoveryCommitment(),
    retirement_quorum: RetirementQuorum {
      threshold: 2,
      members: [fixtures.member1, fixtures.member2, fixtures.member3],
    },
  }
}

fn recordValue() -> assets.Value {
  add(from_lovelace(5_000_000), activePolicy, registryKey, 1)
}

fn recordInput(value: assets.Value) -> Input {
  Input {
    output_reference: fixtures.self_ref,
    output: Output {
      address: address.from_script(appPolicy),
      value,
      datum: InlineDatum(fixtures.as_datum(retirementRecord())),
      reference_script: None,
    },
  }
}

fn custodyOutput() -> Output {
  Output {
    address: address.from_script(application.retirement_custody_hash),
    value: add(from_lovelace(2_000_000), activePolicy, registryKey, 1),
    datum: NoDatum,
    reference_script: None,
  }
}

/// The approval a retirement must mint: the `updateTerminal` edge bound
/// to this key, the completion request's owner, and no destination.
fn terminateApproval() -> assets.Value {
  add(zero, appPolicy, approvalOf(3, registryKey, controllerKey, noDestination()), 1)
}

/// The completion request the retirement must co-create: at the cage's
/// own address, folding `Update(0x01, 0x02)` for this key, carrying the
/// approval that certifies it.
fn completionRequestOutput() -> Output {
  Output {
    address: address.from_script(naming.mpfs_state_hash),
    value: add(from_lovelace(3_000_000), appPolicy, approvalOf(3, registryKey, controllerKey, noDestination()), 1),
    datum: InlineDatum(
      naming.MRequestDatum(
        naming.MRequest {
          requestToken: naming.MTokenId { assetName: fixtures.mock_registry_token },
          requestOwner: controllerKey,
          requestKey: registryKey,
          requestValue: naming.MUpdate(#"01", #"02"),
          tip: 1_000_000,
          submitted_at: 0,
          destination: (#"", #""),
        },
      ),
    ),
    reference_script: None,
  }
}

fn retireTx(signers: List<ByteArray>, value: assets.Value) -> Transaction {
  retireTxWith(signers, value, True, True)
}

/// The retirement transaction, with either co-created obligation
/// withheld so a row can isolate it.
fn retireTxWith(
  signers: List<ByteArray>,
  value: assets.Value,
  withApproval: Bool,
  withRequest: Bool,
) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    inputs: [recordInput(value)],
    reference_inputs: [fixtures.state_input()],
    outputs: if withRequest {
      [custodyOutput(), completionRequestOutput()]
    } else {
      [custodyOutput()]
    },
    mint: if withApproval {
      terminateApproval()
    } else {
      zero
    },
    extra_signatories: signers,
  }
}

fn retireWith(reveal: ByteArray, signers: List<ByteArray>) -> Bool {
  retireShaped(reveal, signers, True, True)
}

fn retireShaped(
  reveal: ByteArray,
  signers: List<ByteArray>,
  withApproval: Bool,
  withRequest: Bool,
) -> Bool {
  application.application.spend(
    Some(fixtures.as_datum(retirementRecord())),
    Retire { key: registryKey, revealed_control: reveal },
    fixtures.self_ref,
    retireTxWith(signers, recordValue(), withApproval, withRequest),
  )
}

/// The committed recovery key, revealed and signing — the proof
/// `Recover` uses, and the only one a single key can offer.
test t157_n6_retire_with_the_recovery_key_accepts() {
  retireWith(recoveryReveal, [recoveryKey])
}

/// Or a distinct-member quorum (`LT02`).
test t157_n6_retire_with_the_quorum_accepts() {
  retireWith(#"", [fixtures.member1, fixtures.member2])
}

/// Below the threshold (`LT03`).
test t157_n6_retire_below_the_quorum_refuses() fail {
  retireWith(#"", [fixtures.member1])
}

/// **The current control key alone does not end a name** (D-TERMINATE,
/// want-ledger R1). A thief holding Alice's current key can change where
/// her name pays until she recovers; they cannot end it, because the
/// recovery key is the one thing they do not have. `LT01` is retired as a
/// row precisely here.
test t157_n6_retire_with_the_control_key_alone_refuses() fail {
  retireWith(#"", [fixtures.controller])
}

/// A reveal that is not the preimage of the stored commitment proves
/// nothing (`LR02`'s shape, at the retirement boundary).
test t157_n6_retire_with_a_wrong_reveal_refuses() fail {
  retireWith(fixtures.altered_control, [recoveryKey])
}

/// F-003, the audit's counterexample: authority plus a custody output,
/// with no `updateTerminal` approval minted. Retirement is not a
/// two-step promise — the transaction that ends a name mints the
/// approval that completes it, or it is not that transaction.
test t157_n6_retire_without_approval_mint_refuses() fail {
  retireShaped(recoveryReveal, [recoveryKey], False, True)
}

/// F-003, the other half: the approval minted with no completion
/// request to carry it. An approval nobody can spend certifies nothing.
test t157_n6_retire_without_completion_request_refuses() fail {
  retireShaped(recoveryReveal, [recoveryKey], True, False)
}

/// F-002, the audit's counterexample: a permissive FOREIGN script input
/// carrying a `Retire`-shaped redeemer. Scanning redeemers for a shape
/// proves nothing about who was retired — the governing input has to be
/// the record itself, at the application's own address, carrying this
/// key's active token.
test t157_n6_foreign_script_retire_spoof_refuses() fail {
  let spoofRedeemer: Data = Retire { key: registryKey, revealed_control: #"" }
  let spoofRef =
    OutputReference { transaction_id: #"53504f4f46", output_index: 0 }
  certify(
    3,
    registryKey,
    controllerKey,
    noDestination(),
    Transaction {
      ..mintTx(
        3,
        registryKey,
        controllerKey,
        noDestination(),
        [recoveryKey],
        [
          Input {
            output_reference: spoofRef,
            output: Output {
              address: address.from_script(
                #"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
              ),
              value: from_lovelace(2_000_000),
              datum: NoDatum,
              reference_script: None,
            },
          },
        ],
        [fixtures.state_input()],
        [],
      ),
      redeemers: [Pair(Spend(spoofRef), spoofRedeemer)],
    },
  )
}

/// The terminate approval cannot be minted on its own: the transaction
/// that certifies the end of a name must be the `Retire` that proves it.
test t157_n6_terminate_approval_without_a_retire_refuses() fail {
  certify(
    3,
    registryKey,
    controllerKey,
    noDestination(),
    mintTx(
      3,
      registryKey,
      controllerKey,
      noDestination(),
      [recoveryKey],
      [],
      [],
      [],
    ),
  )
}

// ============================================================================
// N7 — the record the fold creates carries its datum and its one token
// ============================================================================

/// The fold created this record at the destination the approval bound,
/// with the bound datum and exactly the active token: the application
/// spends it like any record.
test t157_n7_record_with_its_single_active_token_accepts() {
  retireWith(recoveryReveal, [recoveryKey])
}

/// A record carrying a second asset is not a record.
test t157_n7_record_with_a_second_asset_refuses() fail {
  application.application.spend(
    Some(fixtures.as_datum(retirementRecord())),
    Retire { key: registryKey, revealed_control: recoveryReveal },
    fixtures.self_ref,
    retireTx(
      [recoveryKey],
      add(recordValue(), terminalPolicy, otherKey, 1),
    ),
  )
}

// ============================================================================
// N9 — maintenance and recovery never touch the trie
// ============================================================================

fn maintainRecord() -> NamingRecord {
  NamingRecord {
    control_address: fixtures.control,
    payment_destination: naming.NoDestination,
    next_control_commitment: recoveryCommitment(),
    retirement_quorum: RetirementQuorum {
      threshold: 2,
      members: [fixtures.member1, fixtures.member2, fixtures.member3],
    },
  }
}

fn maintainTx(inputs: List<Input>) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    inputs,
    outputs: [
      Output {
        address: address.from_script(appPolicy),
        value: recordValue(),
        datum: InlineDatum(
          fixtures.as_datum(
            naming.NamingRecord {
              ..maintainRecord(),
              payment_destination: naming.SomeDestination(fixtures.destination),
            },
          ),
        ),
        reference_script: None,
      },
    ],
    extra_signatories: [fixtures.controller],
  }
}

fn maintain(inputs: List<Input>) -> Bool {
  application.application.spend(
    Some(fixtures.as_datum(maintainRecord())),
    Maintain,
    fixtures.self_ref,
    maintainTx(inputs),
  )
}

test t157_n9_maintain_without_the_registry_accepts() {
  maintain([recordInput(recordValue())])
}

/// NM2: a `Maintain` that SPENDS the registry state is not maintenance —
/// it is a fold wearing maintenance's clothes, and the root is not
/// maintenance's to move.
test t157_n9_maintain_spending_the_registry_refuses() fail {
  maintain([recordInput(recordValue()), fixtures.state_input()])
}

/// Recovery is the same: it moves control, never the trie.
test t157_n9_recover_without_the_registry_accepts() {
  application.application.spend(
    Some(fixtures.as_datum(maintainRecord())),
    Recover { revealed_control: recoveryReveal, registry: appPolicy },
    fixtures.self_ref,
    Transaction {
      ..transaction.placeholder,
      inputs: [recordInput(recordValue())],
      outputs: [
        Output {
          address: address.from_script(appPolicy),
          value: recordValue(),
          datum: InlineDatum(
            fixtures.as_datum(
              naming.NamingRecord {
                ..maintainRecord(),
                control_address: recoveryReveal,
                next_control_commitment: fixtures.tampered_commitment,
              },
            ),
          ),
          reference_script: None,
        },
      ],
      extra_signatories: [recoveryKey],
    },
  )
}

// ============================================================================
// P1, P2 — the three token policies
// ============================================================================

fn foldRedeemers() -> Pairs<transaction.ScriptPurpose, Data> {
  let modify: Data = naming.MirrorModify([naming.MAUpdate([])])
  [Pair(Spend(fixtures.state_ref), modify)]
}

/// A movement under one witness policy, with or without the fold around
/// it.
fn moveWitness(kind: Int, quantity: Int, inFold: Bool) -> Bool {
  let policy =
    if kind == 0 {
      absentPolicy
    } else if kind == 1 {
      activePolicy
    } else {
      terminalPolicy
    }
  let redeemer: Data = #""
  witness.witness.mint(
    kind,
    registryId(),
    redeemer,
    policy,
    Transaction {
      ..transaction.placeholder,
      mint: add(zero, policy, registryKey, quantity),
      inputs: if inFold {
        [fixtures.state_input()]
      } else {
        []
      },
      redeemers: if inFold {
        foldRedeemers()
      } else {
        []
      },
    },
  )
}

test t157_p1_absent_mint_outside_a_fold_refuses() fail {
  moveWitness(0, 1, False)
}

test t157_p1_active_mint_outside_a_fold_refuses() fail {
  moveWitness(1, 1, False)
}

test t157_p1_terminal_mint_outside_a_fold_refuses() fail {
  moveWitness(2, 1, False)
}

test t157_p1_absent_mint_inside_a_fold_accepts() {
  moveWitness(0, 1, True)
}

test t157_p1_active_mint_inside_a_fold_accepts() {
  moveWitness(1, 1, True)
}

test t157_p1_terminal_mint_inside_a_fold_accepts() {
  moveWitness(2, 1, True)
}

/// Every kind needs the fold to MINT; only the terminal kind may burn
/// without one.
test t157_p1_prop_minting_always_needs_the_fold(
  kind via fuzz.int_between(0, 2),
) {
  !moveWitness(kind, 1, False) && moveWitness(kind, 1, True)
}

/// W3: a terminal witness says a name is over, forever. Letting its
/// holder destroy their own copy costs the registry nothing.
test t157_p2_terminal_burn_without_a_fold_accepts() {
  moveWitness(2, -1, False)
}

test t157_p2_active_burn_without_a_fold_refuses() fail {
  moveWitness(1, -1, False)
}

test t157_p2_absent_burn_without_a_fold_refuses() fail {
  moveWitness(0, -1, False)
}
