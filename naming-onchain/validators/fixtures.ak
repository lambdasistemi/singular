use aiken/crypto.{VerificationKeyHash}
use cardano/address
use cardano/assets.{add, from_lovelace, zero, Value}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, ScriptPurpose, Spend, Transaction,
}
use naming.{
  NamingDatum,
  NamingRecord, NoDestination, PaymentDestination, RetirementQuorum,
  SomeDestination,
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
  #"0a92d14aa73db354d7468f0f09352cfedb6169adf32ea74e82666954"

pub const custody_address = address.from_script(custody_hash)

/// Test stand-in for the compiled application script hash.
pub const app_policy = "application_policy"

/// Test stand-in for the compiled representative policy hash.
pub const rep_policy = "representative_policy"

pub const app_address = address.from_script(app_policy)

pub const refund_output_address = address.from_verification_key(refund_hash)

pub const redirected_output_address =
  address.from_verification_key(redirected_hash)

pub const self_ref =
  OutputReference { transaction_id: "1234567890abcdef", output_index: 3 }

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
