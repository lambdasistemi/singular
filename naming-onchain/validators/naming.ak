use aiken/collection/list.{all, foldl, has, length}
use aiken/primitive/bytearray.{at, length as byte_length, slice}
use cardano/address.{Credential, Script, VerificationKey}

/// The four-field naming datum and the address/datum rules the naming
/// application validator enforces.
///
/// Everything here is transcribed from the accepted epic-15 contract's
/// codec (`offchain/naming/src/Naming/Datum.hs` and `Naming/Wire.hs`,
/// themselves mirrors of v0.2.0's `naming-wire.mjs`, commit
/// `13231f58833b8feb57f4b0f9b1117bfcfba0c07d`). The datum has exactly
/// four fields, in this order: control address; payment destination as
/// an option; the next-control commitment digest; the retirement
/// quorum. There is no fifth field and none may be added. Where this
/// module and the codec disagree, the codec is right and this module is
/// wrong.

/// The payment destination option: none is `constr(0,[])`, some is
/// `constr(1,[bytes])` — the contract's own encoding.
pub type PaymentDestination {
  NoDestination
  SomeDestination(ByteArray)
}

/// `constr(0,[threshold, members])`: a threshold between 1 and the
/// number of distinct members, every member a 28-byte key hash.
pub type RetirementQuorum {
  RetirementQuorum { threshold: Int, members: List<ByteArray> }
}

/// The four-field record: `constr(0,[control, destination, commitment,
/// quorum])`.
pub type NamingRecord {
  NamingRecord {
    control_address: ByteArray,
    payment_destination: PaymentDestination,
    next_control_commitment: ByteArray,
    retirement_quorum: RetirementQuorum,
  }
}

/// The accepted encoding wraps the record once more: outer
/// `constr(0,[inner])`. The double wrap is the contract's; a datum
/// without it is refused.
pub type NamingEnvelope {
  NamingDatum(NamingRecord)
}

/// What the contract's `decodeAddress` recovers from an address: the
/// payment credential kind and the 28-byte payment key hash.
pub type AddressShape {
  AddressShape { payment_key: Bool, payment_hash: ByteArray }
}

/// Mirror of the contract's `decodeAddress`: header kinds 6-7 are
/// enterprise addresses (header + 28-byte hash), kinds 0-3 are base
/// addresses (header + 28-byte payment hash + 28-byte stake hash);
/// everything else is refused. Any network nibble is accepted, exactly
/// as the codec does.
pub fn decode_address(bytes: ByteArray) -> Option<AddressShape> {
  let n = byte_length(bytes)
  if n < 1 {
    None
  } else {
    let header = at(bytes, 0)
    let kind = header / 16
    if (kind == 6 || kind == 7) && n == 29 {
      Some(AddressShape {
        payment_key: kind == 6,
        payment_hash: slice(bytes, 1, 28),
      })
    } else if kind < 4 && n == 57 {
      Some(AddressShape {
        payment_key: kind == 0 || kind == 2,
        payment_hash: slice(bytes, 1, 28),
      })
    } else {
      None
    }
  }
}

/// The contract's canonical address: one `decodeAddress` accepts.
pub fn canonical_address(bytes: ByteArray) -> Bool {
  when decode_address(bytes) is {
    Some(_) -> True
    None -> False
  }
}

/// Mirror of `wellFormedFixture`'s control-address clause: the control
/// address is canonical and its payment credential is a payment key.
pub fn control_is_payment_key(bytes: ByteArray) -> Bool {
  when decode_address(bytes) is {
    Some(shape) -> shape.payment_key
    None -> False
  }
}

/// The control address's payment key hash — the signatory the
/// maintenance path requires.
pub fn control_hash(record: NamingRecord) -> ByteArray {
  let NamingRecord { control_address, .. } = record
  expect Some(shape) = decode_address(control_address)
  expect shape.payment_key
  shape.payment_hash
}

/// A canonical address's payment credential, for comparing refund
/// outputs against the stored refund destination.
pub fn payment_credential(bytes: ByteArray) -> Credential {
  expect Some(shape) = decode_address(bytes)
  if shape.payment_key {
    VerificationKey(shape.payment_hash)
  } else {
    Script(shape.payment_hash)
  }
}

/// Decode an untyped datum into the four-field naming record. Only the
/// accepted encoding decodes: a fifth field, a wrong constructor index
/// or a wrong arity is refused by the pattern itself — the structural
/// half of the contract's `decodeNamingDatum`.
pub fn decode(d: Data) -> NamingRecord {
  expect NamingDatum(record) = d
  record
}

/// Decode and well-formedness in one: what the validator accepts.
pub fn expect_naming(d: Data) -> NamingRecord {
  let record = decode(d)
  expect well_formed(record)
  record
}

/// Does this raw datum decode to exactly this record?
pub fn is_same_record(d: Data, record: NamingRecord) -> Bool {
  if d is NamingDatum(candidate): NamingEnvelope {
    candidate == record
  } else {
    False
  }
}

/// Mirror of the contract's `wellFormedFixture`: the control address is
/// a canonical payment-key address; the payment destination is
/// canonical and never equal to the control address; the commitment is
/// 32 bytes; the threshold is between 1 and the number of distinct
/// members, every member 28 bytes.
pub fn well_formed(record: NamingRecord) -> Bool {
  let NamingRecord {
    control_address,
    payment_destination,
    next_control_commitment,
    retirement_quorum,
  } = record
  let RetirementQuorum { threshold, members } = retirement_quorum
  and {
    control_is_payment_key(control_address),
    destination_ok(payment_destination, control_address),
    byte_length(next_control_commitment) == 32,
    threshold > 0,
    threshold <= distinct_count(members),
    all(members, fn(member) { byte_length(member) == 28 }),
  }
}

fn destination_ok(
  destination: PaymentDestination,
  control: ByteArray,
) -> Bool {
  when destination is {
    NoDestination -> True
    SomeDestination(bytes) ->
      canonical_address(bytes) && bytes != control
  }
}

/// Count distinct members — the contract's `nub` bound on the
/// threshold.
pub fn distinct_count(members: List<ByteArray>) -> Int {
  length(foldl(
    members,
    [],
    fn(member: ByteArray, acc: List<ByteArray>) {
      if has(acc, member) {
        acc
      } else {
        [member, ..acc]
      }
    },
  ))
}
