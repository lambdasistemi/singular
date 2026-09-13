use aiken/collection/list.{all, foldl, has, length}
use aiken/primitive/bytearray.{at, concat, length as byte_length, slice}
use cardano/address.{Credential, Script, VerificationKey}
use cardano/assets.{PolicyId}

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

/// The MPFS registry state hash (issue #77, E-001 repair): the spent state
/// input's address. Regenerated from the MPFS blueprint; never hand-typed.
/// Source: onchain/script-identity.json state.state hash — regen via
/// `just script-identity-regen` in onchain, then update this constant.
/// Lives here (not in the application validator) so both the validator and
/// test fixtures share one source with no library→validator import edge.
pub const mpfs_state_hash =
  #"3f62792585903776fc69059588783c7ca67ee9d24886c8722ebf8b2a"

/// Mirror of the MPFS `State` datum (issue #77, E-001 repair; sixth field
/// NOTE-013/NOTE-019): the registry configuration carrying the expected
/// representative policy and the pinned consumer script hash. Field order
/// matches onchain/validators/types.ak `State` byte-for-byte (the policy
/// was appended fifth, the pin sixth). The first arm is a unit placeholder
/// so `StateDatum` keeps constr index 1 — folds and retires only decode
/// spent states, never requests (a request datum does not match
/// `MpfsStateDatum` and refuses).
pub type MpfsState {
  MpfsState {
    root: ByteArray,
    tip: Int,
    process_time: Int,
    retract_time: Int,
    representative_policy: PolicyId,
    consumer_pin: ByteArray,
  }
}

pub type MpfsCageDatum {
  MpfsRequest
  MpfsStateDatum(MpfsState)
}

/// Decode a spent registry state datum to its expected representative policy
/// (issue #77, E-001 repair). Same-module `expect` on the mirror above —
/// callers in other modules use this helper and never pattern-match the
/// mirror across a module boundary.
pub fn mpfs_state_policy(datum: Data) -> PolicyId {
  expect MpfsStateDatum(state) = datum
  state.representative_policy
}

/// Decode a registry state datum to its trie root (NOTE-029): the
/// completion correspondence compares the spent root against the
/// continuation root — a genuine transition changes it (Rejected
/// preserves it). Same-module `expect`, same boundary rule as above.
pub fn mpfs_state_root(datum: Data) -> ByteArray {
  expect MpfsStateDatum(state) = datum
  state.root
}

/// Mirror of the MPFS request datum (NOTE-031): field order mirrors
/// onchain request bytes exactly (token, owner, key, value, fee,
/// submitted-at); variant order mirrors the operation
/// (`Insert`, `Delete`, `Update`). Cross-check `consumer.ak`
/// `CRequest`/`COperation` mirrors on drift — same shapes, same
/// positions. Only `Update` requests complete retirements; the other
/// arms exist so decoding is total over the wire shape.
pub type MTokenId {
  MTokenId { assetName: ByteArray }
}

pub type MOperation {
  MInsert(ByteArray)
  MDelete(ByteArray)
  MUpdate(ByteArray, ByteArray)
}

pub type MRequest {
  MRequest {
    requestToken: MTokenId,
    requestOwner: ByteArray,
    requestKey: ByteArray,
    requestValue: MOperation,
    tip: Int,
    submitted_at: Int,
  }
}

pub type MRequestDatum {
  MRequestDatum(MRequest)
}

/// Decode a request datum to its typed mirror (NOTE-031). Framework
/// deserialization only — anything else crashes (custody calls this
/// where crash refuses). A state datum does not decode here (its
/// second field is an `Int` tip where a request carries owner bytes)
/// and vice versa; both directions are pinned by unit tests.
pub fn mrequest(datum: Data) -> MRequest {
  expect MRequestDatum(request) = datum
  request
}

/// The Over marker for a burned representative (NOTE-031): the Update
/// value a genuine retirement request writes. Constant "over" prefix
/// (distinct from insert values, which are bare representative names)
/// committing to the exact held asset — the completion checks the
/// folded request moves `burned` to `over_marker_for(burned)`. The
/// prefix is ASCII "over" (hex 6f766572), distinct from insert values
/// (bare representative names).
pub fn over_marker_for(burned: ByteArray) -> ByteArray {
  concat(#"6f766572", burned)
}

/// Mirror of the MPFS `UpdateRedeemer` action list (NOTE-029): variant
/// order and field counts match onchain/validators/types.ak
/// (`End`, `Contribute`, `Modify`, `Retract`, `Sweep`) and the MPF
/// proof steps (`Branch`, `Fork`, `Leaf`, `Neighbor`). The
/// correspondence counts actions and checks singleton-ness; it never
/// interprets proofs (a singleton action plus a changed root is
/// exactly one genuine `UpdateAction`).
pub type MirrorRedeemer {
  MirrorEnd
  MirrorContribute(Data)
  MirrorModify(List<MirrorAction>)
  MirrorRetract(Data)
  MirrorSweep(Data)
}

/// Mirror of `RequestAction` (see above): `UpdateAction` = constr 0,
/// `Rejected` = constr 1.
pub type MirrorAction {
  MAUpdate(List<MirrorStep>)
  MARejected
}

/// Mirror of the MPF `ProofStep` (see above).
pub type MirrorStep {
  MBranch { skip: Int, neighbors: ByteArray }
  MFork { skip: Int, neighbor: MirrorNeighbor }
  MLeaf { skip: Int, key: ByteArray, value: ByteArray }
}

/// Mirror of the MPF `Neighbor` (see above).
pub type MirrorNeighbor {
  MirrorNeighbor { nibble: Int, prefix: ByteArray, root: ByteArray }
}

/// The action count of a state-spend redeemer, or -1 unless it decodes
/// as a `Modify` (NOTE-029). Framework deserialization only (`is`
/// check, same shape as the generic layer's own datum narrowing) —
/// anything else is -1, never a crash.
pub fn modify_action_count(redeemer_data: Data) -> Int {
  if redeemer_data is MirrorModify(actions): MirrorRedeemer {
    length(actions)
  } else {
    -1
  }
}

/// Build a mock registry state datum carrying the given root,
/// representative policy and consumer pin (test fixtures). Single
/// construction site for the mirror shape (NOTE-029: completion tests
/// need continuations with a changed root).
pub fn mpfs_state_datum(rep_policy: PolicyId, consumer_pin: ByteArray) -> Data {
  mpfs_state_datum_with_root(#"00", rep_policy, consumer_pin)
}

pub fn mpfs_state_datum_with_root(
  root: ByteArray,
  rep_policy: PolicyId,
  consumer_pin: ByteArray,
) -> Data {
  let datum: Data =
    MpfsStateDatum(MpfsState {
      root,
      tip: 0,
      process_time: 0,
      retract_time: 0,
      representative_policy: rep_policy,
      consumer_pin: consumer_pin,
    })
  datum
}
