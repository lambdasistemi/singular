use aiken/crypto.{VerificationKeyHash}
use cardano/address
use cardano/assets.{add, from_lovelace, zero, Value}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, ScriptPurpose, Spend, Transaction,
}
use naming.{
  NamingDatum,
  NamingRecord, NoDestination, PaymentDestination, RetirementQuorum,
  SomeDestination, mpfs_state_hash,
}

/// Shared fixtures for the naming validators, taken from the accepted
/// v0.2.0 corpus rows (`LM01..LM04`, `LC01..LC06`) so the tests execute
/// the contract's own bytes, not invented ones.
///
/// - `control` is the LM rows' control address: enterprise payment-key,
///   network 1, payment hash `01..1c`.
/// - `destination` is the LM rows' payment destination (`55..70`).
/// - `commitment` is the LM rows' next-control commitment digest.
/// - `tampered_commitment` is `LM03`'s tampered digest.
/// - The quorum members are the LM rows' three 28-byte members.
pub const control =
  #"610102030405060708090a0b0c0d0e0f101112131415161718191a1b1c"

pub const controller =
  #"0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c"

pub const altered_control =
  #"610102030405060708090a0b0c0d0e0f101112131415161718191a1b1d"

pub const script_credential_control =
  #"710102030405060708090a0b0c0d0e0f101112131415161718191a1b1c"

pub const bad_header_address =
  #"450102030405060708090a0b0c0d0e0f101112131415161718191a1b1c"

pub const base_payment_address =
  #"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c00000000000000000000000000000000000000000000000000000000"

pub const destination =
  #"6155565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f70"

pub const destination_hash =
  #"55565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f70"

pub const commitment =
  #"c2db4cf74eaf41d05ff3f0d2ba190c482dbd285e5615ab6885c05286c4c23cbe"

pub const tampered_commitment =
  #"1561c15b4980857fb06e4ab35cc9bcecaf090b0aa8bdef19f6331565a333204f"

pub const member1 =
  #"0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c"

pub const member2 =
  #"1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738"

pub const member3 =
  #"393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f5051525354"

pub const short_member =
  #"0102030405060708090a0b0c0d0e0f1011121314151617181a1b"

pub const refund_destination =
  #"61a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbc"

pub const refund_hash =
  #"a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbc"

pub const redirected_refund =
  #"61d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebeced"

pub const redirected_hash =
  #"d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebeced"

pub const representative_name = #"5265700102030405060708090a0b0c0d"

/// The retirement custody script hash (issue #66): matches
/// `application.retirement_custody_hash` — the address a `Retire` may
/// place the representative at.
pub const custody_hash =
  #"c2337e05bb6a705adeb8bb8fb20155309a85d7c4cda174f9e8afa2d6"

pub const custody_address = address.from_script(custody_hash)

/// Test stand-in for the compiled application script hash.
pub const app_policy = "application_policy"

/// Test stand-in for the compiled representative policy hash.
pub const rep_policy = "representative_policy"

/// Test stand-in for the pinned consumer script hash (NOTE-013/NOTE-019,
/// sixth field): 28 bytes. Fixture state datums carry it; the naming side
/// decodes but never enforces it (the generic hook does).
pub const consumer_pin = "consumer_pin__________123456"

pub const app_address = address.from_script(app_policy)

pub const refund_output_address = address.from_verification_key(refund_hash)

pub const redirected_output_address =
  address.from_verification_key(redirected_hash)

pub const self_ref =
  OutputReference { transaction_id: "1234567890abcdef", output_index: 3 }

/// Distinct out-ref for the mock registry state input (issue #77, E-001):
/// never equal to `self_ref`, so claim and state inputs coexist.
pub const state_ref =
  OutputReference { transaction_id: "73746174650000000000000000000000", output_index: 0 }

/// Mock cage token name (NOTE-007): the registry identity the mock state
/// authenticates. Mirrors in tests recompute representative names over
/// exactly these bytes with `mpfs_state_hash`, so mock folds and retires
/// exercise the registry-bound equation rather than a fixed string.
pub const mock_registry_token = #"6d6f636b2d746f6b656e"

/// Second mock cage token (NOTE-009 §3 control): a state UTxO carrying two
/// tokens under the state policy is not the registry and must be refused
/// at the authentication boundary itself.
pub const second_mock_token = #"7365636f6e642d6d6f636b2d746f6b656e"

/// Foreign registry token for negative tests (NOTE-007): names bound to it
/// mismatch the mock registry above, isolating the association check from
/// the policy check (which uses `foreign_policy` as the mint/value policy).
pub const foreign_registry_token = #"666f726569676e2d746f6b656e"

/// Mock registry state datum (issue #77, E-001): a spent state at the MPFS
/// address carrying the expected representative policy — the `rep_policy`
/// placeholder, matching test mints and values. Built by the naming
/// module's single construction site (no mirror drift).
pub fn state_datum() -> Data {
  naming.mpfs_state_datum(rep_policy, consumer_pin)
}

/// Attach spent-or-reference registry inputs to a built transaction
/// (NOTE-014 item A1 tests): record update keeps every other field.
pub fn with_state_reference(base: Transaction, state_ref_input: Input) -> Transaction {
  Transaction { ..base, reference_inputs: [state_ref_input] }
}

/// Mock spent registry state input for insert-fold and retire tests: at the
/// MPFS state address with the mock state datum above. Included so
/// `expected_rep_policy` resolves to `rep_policy`; tests without it refuse
/// on missing state (same script, unattributed at the node-text layer).
pub fn state_input() -> Input {
  Input {
    output_reference: state_ref,
    output: Output {
      address: address.from_script(mpfs_state_hash),
      value: add(
        from_lovelace(deposit),
        mpfs_state_hash,
        mock_registry_token,
        1,
      ),
      datum: InlineDatum(state_datum()),
      reference_script: None,
    },
  }
}

/// Boundary control input (NOTE-009 §3): same address and datum as the mock
/// state but TWO cage tokens — the predicate must refuse it there.
pub fn state_input_two_tokens() -> Input {
  Input {
    output_reference: state_ref,
    output: Output {
      address: address.from_script(mpfs_state_hash),
      value: add(
        add(from_lovelace(deposit), mpfs_state_hash, mock_registry_token, 1),
        mpfs_state_hash,
        second_mock_token,
        1,
      ),
      datum: InlineDatum(state_datum()),
      reference_script: None,
    },
  }
}

/// Mock registry state datum carrying a foreign representative policy with
/// an honest cage token (NOTE-014 item A1 control): the datum lies, the
/// token does not. A retire referencing it must refuse on the policy
/// mismatch between the declared expected policy and the carried value.
pub fn foreign_state_datum() -> Data {
  naming.mpfs_state_datum("foreign_policy", consumer_pin)
}

/// Reference input carrying the foreign datum above under the honest cage
/// token (NOTE-014 item A1 control).
pub fn state_input_foreign_datum() -> Input {
  Input {
    output_reference: state_ref,
    output: Output {
      address: address.from_script(mpfs_state_hash),
      value: add(
        from_lovelace(deposit),
        mpfs_state_hash,
        mock_registry_token,
        1,
      ),
      datum: InlineDatum(foreign_state_datum()),
      reference_script: None,
    },
  }
}
/// token — requests and forgeries at the address carry none and must refuse.
pub fn state_input_no_token() -> Input {
  Input {
    output_reference: state_ref,
    output: Output {
      address: address.from_script(mpfs_state_hash),
      value: from_lovelace(deposit),
      datum: InlineDatum(state_datum()),
      reference_script: None,
    },
  }
}

pub const deposit = 5_000_000

pub const record_value = from_lovelace(deposit)

/// The LM rows' source record: destination `Some(destination)`, quorum
/// of three, threshold 2.
pub fn source_record() -> NamingRecord {
  NamingRecord {
    control_address: control,
    payment_destination: SomeDestination(destination),
    next_control_commitment: commitment,
    retirement_quorum: RetirementQuorum {
      threshold: 2,
      members: [member1, member2, member3],
    },
  }
}

/// The LM01 candidate: only the payment destination is maintained (to
/// none); control, commitment and quorum are as they were.
pub fn maintained_record() -> NamingRecord {
  NamingRecord {
    control_address: control,
    payment_destination: NoDestination,
    next_control_commitment: commitment,
    retirement_quorum: RetirementQuorum {
      threshold: 2,
      members: [member1, member2, member3],
    },
  }
}

pub fn with_destination(
  record: NamingRecord,
  destination: PaymentDestination,
) -> NamingRecord {
  NamingRecord { ..record, payment_destination: destination }
}

pub fn with_commitment(record: NamingRecord, next: ByteArray) -> NamingRecord {
  NamingRecord { ..record, next_control_commitment: next }
}

pub fn with_control(record: NamingRecord, next: ByteArray) -> NamingRecord {
  NamingRecord { ..record, control_address: next }
}

pub fn with_quorum(
  record: NamingRecord,
  quorum: RetirementQuorum,
) -> NamingRecord {
  NamingRecord { ..record, retirement_quorum: quorum }
}

pub fn claim_input(datum: Data, value: Value) -> Input {
  Input {
    output_reference: self_ref,
    output: Output {
      address: app_address,
      value,
      datum: InlineDatum(datum),
      reference_script: None,
    },
  }
}

pub fn continuation_output(datum: Data, value: Value) -> Output {
  Output {
    address: app_address,
    value,
    datum: InlineDatum(datum),
    reference_script: None,
  }
}

pub fn tx(
  inputs: List<Input>,
  outputs: List<Output>,
  signatories: List<VerificationKeyHash>,
  mint: Value,
  redeemers: List<Pair<ScriptPurpose, Data>>,
) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    inputs,
    outputs,
    extra_signatories: signatories,
    mint,
    redeemers,
  }
}

/// A spend redeemer payload as raw data — what a minting policy reads
/// back out of `tx.redeemers`.
pub fn spend_redeemer_data(redeemer: Data) -> List<Pair<ScriptPurpose, Data>> {
  [Pair(Spend(self_ref), redeemer)]
}

pub const no_mint = zero

/// The claim's value carrying its withdraw approval: the asset name is
/// the stored refund destination.
pub fn claim_value_with_approval(value: Value) -> Value {
  add(value, app_policy, refund_destination, 1)
}

pub fn burn_approval() -> Value {
  add(zero, app_policy, refund_destination, -1)
}

/// Upcast a naming record to the raw datum bytes the validator decodes.
pub fn as_datum(record: NamingRecord) -> Data {
  let data: Data = NamingDatum(record)
  data
}
