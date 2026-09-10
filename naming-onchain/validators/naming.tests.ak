use aiken/builtin.{constr_data}
use fixtures.{
  bad_header_address, base_payment_address, commitment, control, destination,
  member1, member2, member3, script_credential_control, short_member,
  tampered_commitment,
}
use naming.{
  decode, decode_address, expect_naming, NamingDatum, NamingRecord,
  NoDestination, RetirementQuorum, SomeDestination,
}

// ===========================================================================
// Address decoding — the contract's decodeAddress
// ===========================================================================

test enterprise_payment_key_address_decodes() {
  when decode_address(control) is {
    Some(shape) -> shape.payment_key
    None -> False
  }
}

test base_payment_key_address_decodes() {
  when decode_address(base_payment_address) is {
    Some(shape) -> shape.payment_key
    None -> False
  }
}

test bad_header_address_refuses() {
  decode_address(bad_header_address) == None
}

// ===========================================================================
// Datum decoding — the four-field datum in the accepted encoding and
// nothing else (no fifth field)
// ===========================================================================

fn quorum() {
  RetirementQuorum {
    threshold: 2,
    members: [member1, member2, member3],
  }
}

fn canonical_record() {
  NamingRecord {
    control_address: control,
    payment_destination: SomeDestination(destination),
    next_control_commitment: commitment,
    retirement_quorum: quorum(),
  }
}

test canonical_datum_decodes() {
  decode(NamingDatum(canonical_record())) == canonical_record()
}

test canonical_record_is_well_formed() {
  let record = expect_naming(NamingDatum(canonical_record()))
  record == canonical_record()
}

// A fifth field breaks the inner arity the encoding fixes: decode must
// refuse.
test fifth_field_refuses() fail {
  let control_data: Data = control
  let destination_data: Data = SomeDestination(destination)
  let commitment_data: Data = commitment
  let quorum_data: Data = quorum()
  let fifth: Data = #"0000ff"
  expect _ = decode(constr_data(0, [
    constr_data(0, [
      control_data,
      destination_data,
      commitment_data,
      quorum_data,
      fifth,
    ]),
  ]))
  True
}

test wrong_outer_index_refuses() fail {
  let inner: Data = NamingDatum(canonical_record())
  expect _ = decode(constr_data(1, [inner]))
  True
}

test wrong_inner_arity_refuses() fail {
  let control_data: Data = control
  let destination_data: Data = SomeDestination(destination)
  let commitment_data: Data = commitment
  expect _ = decode(constr_data(0, [
    constr_data(0, [control_data, destination_data, commitment_data]),
  ]))
  True
}

// The payment destination option admits only constr(0,[]) and
// constr(1,[bytes]).
test destination_wrong_constructor_refuses() fail {
  let control_data: Data = control
  let destination_data: Data = constr_data(2, [])
  let commitment_data: Data = commitment
  let quorum_data: Data = quorum()
  expect _ = decode(constr_data(0, [
    constr_data(0, [
      control_data,
      destination_data,
      commitment_data,
      quorum_data,
    ]),
  ]))
  True
}

// ===========================================================================
// Well-formedness — the contract's wellFormedFixture
// ===========================================================================

fn record_with(commitment_bytes: ByteArray, q: RetirementQuorum) {
  NamingRecord {
    control_address: control,
    payment_destination: NoDestination,
    next_control_commitment: commitment_bytes,
    retirement_quorum: q,
  }
}

fn with_destination(record: NamingRecord, destination) {
  NamingRecord { ..record, payment_destination: destination }
}

fn with_control(record: NamingRecord, next) {
  NamingRecord { ..record, control_address: next }
}

// A 28-byte commitment is not a 32-byte digest.
test short_commitment_refuses() fail {
  refuses(NamingDatum(record_with(member1, quorum())))
}

// The LM03 tamper is a well-formed but different digest: its refusal
// comes from maintenance preservation, not from decoding.
test tampered_commitment_is_well_formed() {
  let decoded =
    expect_naming(NamingDatum(record_with(tampered_commitment, quorum())))
  decoded.next_control_commitment == tampered_commitment
}

test short_member_refuses() fail {
  refuses(NamingDatum(record_with(
    commitment,
    RetirementQuorum {
      threshold: 2,
      members: [member1, short_member],
    },
  )))
}

test zero_threshold_refuses() fail {
  refuses(NamingDatum(record_with(
    commitment,
    RetirementQuorum {
      threshold: 0,
      members: [member1, member2],
    },
  )))
}

test threshold_above_members_refuses() fail {
  refuses(NamingDatum(record_with(
    commitment,
    RetirementQuorum {
      threshold: 3,
      members: [member1, member2],
    },
  )))
}

// Two distinct members carried three times: the contract's nub bound
// counts distinct members, so a threshold of 3 refuses.
test threshold_over_duplicate_members_refuses() fail {
  refuses(NamingDatum(record_with(
    commitment,
    RetirementQuorum {
      threshold: 3,
      members: [member1, member1, member2],
    },
  )))
}

test duplicate_members_within_bound_accepts() {
  expect _ =
    expect_naming(NamingDatum(record_with(
      commitment,
      RetirementQuorum {
        threshold: 2,
        members: [member1, member1, member2],
      },
    )))
  True
}

test destination_equal_to_control_refuses() fail {
  refuses(NamingDatum(with_destination(
    canonical_record(),
    SomeDestination(control),
  )))
}

test script_credential_control_refuses() fail {
  refuses(NamingDatum(with_control(
    canonical_record(),
    script_credential_control,
  )))
}

test bad_header_control_refuses() fail {
  refuses(NamingDatum(with_control(
    canonical_record(),
    bad_header_address,
  )))
}

test base_form_destination_accepts() {
  expect _ =
    expect_naming(NamingDatum(with_destination(
      canonical_record(),
      SomeDestination(base_payment_address),
    )))
  True
}

test non_canonical_destination_refuses() fail {
  refuses(NamingDatum(with_destination(
    canonical_record(),
    SomeDestination(bad_header_address),
  )))
}

test no_destination_accepts() {
  expect _ =
    expect_naming(NamingDatum(with_destination(
      canonical_record(),
      NoDestination,
    )))
  True
}

/// The full validator-side acceptance (decode + well-formedness) as a
/// Bool, for fail-tests: the call must error for the test to pass.
fn refuses(d: Data) -> Bool {
  expect _ = expect_naming(d)
  True
}
