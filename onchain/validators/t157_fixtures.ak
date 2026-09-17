use aiken/cbor
use aiken/collection/list
use aiken/crypto.{blake2b_256}
use aiken/interval
use aiken/merkle_patricia_forestry.{Branch, Leaf, Proof, ProofStep}
use aiken/merkle_patricia_forestry as mpf
use aiken/merkle_patricia_forestry/helpers.{combine, nibble, suffix}
use aiken/merkle_patricia_forestry/merkling.{null_hash}
use aiken/primitive/bytearray
use cardano/address
use cardano/assets.{Value, from_asset, from_lovelace, merge, zero}
use cardano/transaction.{
  Datum, InlineDatum, Input, NoDatum, Output, OutputReference, Transaction,
}
use cardano/transaction
use lib
use lib.{approvalName}
use types.{
  AbsentCustody, CageDatum, Operation, Request, RequestDatum, State,
  StateDatum, TokenId,
}

/// Registry-mode fixtures (#157): the shared vocabulary the cage's row
/// tests are written in.
///
/// Everything here is BUILT, never pasted. The tries are built by the
/// library's own `insert`, and the proofs are built from the library's
/// own `combine`/`nibble`/`suffix` primitives, so a fixture that does
/// not describe a real trie fails loudly at construction instead of
/// quietly proving nothing. A hand-typed root would agree with itself
/// forever.

// ----------------------------------------------------------------------------
// Registry configuration
// ----------------------------------------------------------------------------

pub const cagePolicy: ByteArray = "policy_id"

pub const appPolicy: ByteArray =
  #"a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9"

pub const activePolicy: ByteArray =
  #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

pub const absentPolicy: ByteArray =
  #"b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"

pub const terminalPolicy: ByteArray =
  #"c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0"

pub const foreignPolicy: ByteArray =
  #"f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0"

pub const processTime: Int = 10_000

pub const retractTime: Int = 10_000

pub const tip: Int = 1_000_000

/// The deposit a request rides with, over and above the tip. The fold
/// returns it to the destination (#157 T6, want-ledger R4).
pub const deposit: Int = 2_000_000

pub const requestValue: Int = tip + deposit

pub const stateLovelace: Int = 5_000_000

// ----------------------------------------------------------------------------
// Keys, leaves and addresses
// ----------------------------------------------------------------------------

/// Registry keys. Under each token policy the asset name IS the key
/// (#157 D-ASSET), so these double as asset names.
pub const keyA: ByteArray = #"6b657941"

pub const keyB: ByteArray = #"6b657942"

pub const keyC: ByteArray = #"6b657943"

pub const keyD: ByteArray = #"6b657944"

pub const absentLeaf: ByteArray = #"00"

pub const activeLeaf: ByteArray = #"01"

pub const terminalLeaf: ByteArray = #"02"

/// Binary addresses, as the request's `destination` carries them
/// (#157 D-DEST). `0x60` is an enterprise payment-key address, `0x70`
/// an enterprise script address, `0x00` a base address with both
/// credentials.
pub const bookerAddress: ByteArray =
  #"60d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1"

pub const inserterAddress: ByteArray =
  #"60d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2"

pub const strangerAddress: ByteArray =
  #"60d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3"

pub const recordAddress: ByteArray =
  #"70d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4"

pub const bookerKey: ByteArray =
  #"d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1"

pub const inserterKey: ByteArray =
  #"d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2"

pub fn addressOf(bytes: ByteArray) -> address.Address {
  expect Some(decoded) = lib.decodeAddress(bytes)
  decoded
}

/// The record datum a booking's destination binds, and its hash.
pub fn recordDatum() -> Data {
  let datum: Data = #"5265636f7264"
  datum
}

pub fn otherDatum() -> Data {
  let datum: Data = #"4f74686572"
  datum
}

pub fn datumHashOf(datum: Data) -> ByteArray {
  blake2b_256(cbor.serialise(datum))
}

/// A booking's destination: the record address plus the hash of the
/// datum the receiving output must carry.
pub fn bookingDestination() -> (ByteArray, ByteArray) {
  (recordAddress, datumHashOf(recordDatum()))
}

/// A read's destination: a plain wallet output with no datum.
pub fn readDestination() -> (ByteArray, ByteArray) {
  (bookerAddress, #"")
}

/// An absence witness's destination: its first component is the refund
/// address, and it names no datum (the token goes to custody).
pub fn refundDestination() -> (ByteArray, ByteArray) {
  (inserterAddress, #"")
}

pub fn noDestination() -> (ByteArray, ByteArray) {
  (#"", #"")
}

// ----------------------------------------------------------------------------
// Tries and proofs — built, never pasted
// ----------------------------------------------------------------------------

/// The number of nibbles two paths share, which is exactly the `skip` a
/// proof step at the top of the trie carries.
fn commonPrefix(left: ByteArray, right: ByteArray, cursor: Int) -> Int {
  if nibble(left, cursor) == nibble(right, cursor) {
    commonPrefix(left, right, cursor + 1)
  } else {
    cursor
  }
}

/// The one-step proof for `myKey` against a trie holding exactly
/// `otherKey -> otherValue`: the sibling leaf, with the skip the two
/// paths actually share.
pub fn leafStep(
  otherKey: ByteArray,
  otherValue: ByteArray,
  myKey: ByteArray,
) -> ProofStep {
  Leaf {
    skip: commonPrefix(blake2b_256(myKey), blake2b_256(otherKey), 0),
    key: blake2b_256(otherKey),
    value: blake2b_256(otherValue),
  }
}

/// The digest a leaf contributes to the 16-way node just below the root.
fn leafDigest(key: ByteArray, value: ByteArray) -> ByteArray {
  combine(suffix(blake2b_256(key), 1), blake2b_256(value))
}

/// The sixteen slots of the root node of a trie whose leaves all fork at
/// nibble 0, in slot order.
fn slotsOf(entries: List<(Int, ByteArray)>) -> List<ByteArray> {
  list.map(
    list.range(0, 15),
    fn(slot) {
      when list.find(entries, fn(entry) { entry.1st == slot }) is {
        Some(entry) -> entry.2nd
        None -> null_hash
      }
    },
  )
}

fn pairUp(digests: List<ByteArray>) -> List<ByteArray> {
  when digests is {
    [left, right, ..rest] -> [combine(left, right), ..pairUp(rest)]
    _ -> []
  }
}

fn sibling(index: Int) -> Int {
  if index % 2 == 0 {
    index + 1
  } else {
    index - 1
  }
}

fn nth(digests: List<ByteArray>, index: Int) -> ByteArray {
  expect Some(digest) = list.at(digests, index)
  digest
}

/// The `Branch` step for `myKey` against a trie whose root node holds
/// the given occupied slots: the four sibling digests on `myKey`'s path
/// through the node's binary merkle tree, in the order the library
/// reads them (`neighbor_8 ‖ neighbor_4 ‖ neighbor_2 ‖ neighbor_1`).
pub fn branchStep(entries: List<(Int, ByteArray)>, myKey: ByteArray) -> ProofStep {
  let level0 = slotsOf(entries)
  let level1 = pairUp(level0)
  let level2 = pairUp(level1)
  let level3 = pairUp(level2)
  let branch = nibble(blake2b_256(myKey), 0)
  Branch {
    skip: 0,
    neighbors: nth(level3, sibling(branch / 8))
      |> bytearray.concat(nth(level2, sibling(branch / 4)))
      |> bytearray.concat(nth(level1, sibling(branch / 2)))
      |> bytearray.concat(nth(level0, sibling(branch))),
  }
}

/// The slot entry a leaf occupies in the root node.
pub fn slotOf(key: ByteArray, value: ByteArray) -> (Int, ByteArray) {
  (nibble(blake2b_256(key), 0), leafDigest(key, value))
}

pub fn emptyRoot() -> ByteArray {
  mpf.root(mpf.empty)
}

/// The root of a trie holding exactly one leaf.
pub fn oneLeaf(key: ByteArray, value: ByteArray) -> ByteArray {
  mpf.root(mpf.insert(mpf.empty, key, value, []))
}

/// The root of a trie holding exactly two leaves.
pub fn twoLeaves(
  keyOne: ByteArray,
  valueOne: ByteArray,
  keyTwo: ByteArray,
  valueTwo: ByteArray,
) -> ByteArray {
  mpf.root(
    mpf.insert(
      mpf.from_root(oneLeaf(keyOne, valueOne)),
      keyTwo,
      valueTwo,
      [leafStep(keyOne, valueOne, keyTwo)],
    ),
  )
}

/// The proof that inserts a third leaf into a two-leaf trie.
pub fn thirdLeafProof(
  keyOne: ByteArray,
  valueOne: ByteArray,
  keyTwo: ByteArray,
  valueTwo: ByteArray,
  myKey: ByteArray,
) -> Proof {
  [branchStep([slotOf(keyOne, valueOne), slotOf(keyTwo, valueTwo)], myKey)]
}

/// The inclusion proof of `myKey` in a two-leaf trie whose other leaf is
/// `otherKey -> otherValue`.
pub fn siblingProof(
  otherKey: ByteArray,
  otherValue: ByteArray,
  myKey: ByteArray,
) -> Proof {
  [leafStep(otherKey, otherValue, myKey)]
}

// ----------------------------------------------------------------------------
// The registry state
// ----------------------------------------------------------------------------

pub const cageToken: TokenId = TokenId { assetName: #"636167652d746f6b656e" }

pub const stateRef: OutputReference =
  OutputReference { transaction_id: #"5354415445", output_index: 0 }

pub fn cageAddress() -> address.Address {
  address.from_script(cagePolicy)
}

pub fn stateValue() -> Value {
  from_asset(cagePolicy, cageToken.assetName, 1)
    |> merge(from_lovelace(stateLovelace))
}

pub fn stateOf(root: ByteArray) -> State {
  State {
    root,
    tip,
    process_time: processTime,
    retract_time: retractTime,
    application_policy: appPolicy,
    active_policy: activePolicy,
    absent_policy: absentPolicy,
    terminal_policy: terminalPolicy,
  }
}

pub fn stateInput(root: ByteArray) -> Input {
  Input {
    output_reference: stateRef,
    output: Output {
      address: cageAddress(),
      value: stateValue(),
      datum: InlineDatum(StateDatum(stateOf(root))),
      reference_script: None,
    },
  }
}

pub fn stateOutput(root: ByteArray) -> Output {
  Output {
    address: cageAddress(),
    value: stateValue(),
    datum: InlineDatum(StateDatum(stateOf(root))),
    reference_script: None,
  }
}

/// The continuation carrying a state whose datum was tampered with.
pub fn stateOutputOf(state: State) -> Output {
  Output {
    address: cageAddress(),
    value: stateValue(),
    datum: InlineDatum(StateDatum(state)),
    reference_script: None,
  }
}

// ----------------------------------------------------------------------------
// Requests and approvals
// ----------------------------------------------------------------------------

/// The approval the application minted for this edge (#157 C4,
/// D-APPROVAL): one asset under the application policy whose name is the
/// binding of exactly this request.
pub fn approval(
  edge: Int,
  key: ByteArray,
  owner: ByteArray,
  destination: (ByteArray, ByteArray),
) -> Value {
  from_asset(appPolicy, approvalName(edge, key, owner, destination), 1)
}

pub fn requestRef(index: Int) -> OutputReference {
  OutputReference { transaction_id: #"52455155455354", output_index: index }
}

pub fn requestDatum(
  key: ByteArray,
  operation: Operation,
  owner: ByteArray,
  destination: (ByteArray, ByteArray),
) -> CageDatum {
  RequestDatum(
    Request {
      requestToken: cageToken,
      requestOwner: owner,
      requestKey: key,
      requestValue: operation,
      tip,
      submitted_at: 0,
      destination,
    },
  )
}

/// A request UTxO carrying its approval and its deposit.
pub fn requestInput(
  index: Int,
  key: ByteArray,
  operation: Operation,
  owner: ByteArray,
  destination: (ByteArray, ByteArray),
  carried: Value,
  lovelace: Int,
) -> Input {
  Input {
    output_reference: requestRef(index),
    output: Output {
      address: cageAddress(),
      value: merge(from_lovelace(lovelace), carried),
      datum: InlineDatum(requestDatum(key, operation, owner, destination)),
      reference_script: None,
    },
  }
}

// ----------------------------------------------------------------------------
// Outputs the fold owes
// ----------------------------------------------------------------------------

/// The output a minted active or terminal token must land in.
pub fn deliveryOutput(
  policy: ByteArray,
  key: ByteArray,
  destinationAddress: ByteArray,
  datum: Datum,
  lovelace: Int,
) -> Output {
  deliveryOutputN(policy, key, 1, destinationAddress, datum, lovelace)
}

/// The same, carrying `quantity` of the token: two requests minting one
/// `(policy, key)` in a batch owe a single carrier holding both.
pub fn deliveryOutputN(
  policy: ByteArray,
  key: ByteArray,
  quantity: Int,
  destinationAddress: ByteArray,
  datum: Datum,
  lovelace: Int,
) -> Output {
  Output {
    address: addressOf(destinationAddress),
    value: merge(from_lovelace(lovelace), from_asset(policy, key, quantity)),
    datum,
    reference_script: None,
  }
}

/// The cage's own custody of a minted absent token.
pub fn custodyOutput(key: ByteArray, refund: ByteArray, lovelace: Int) -> Output {
  Output {
    address: cageAddress(),
    value: merge(from_lovelace(lovelace), from_asset(absentPolicy, key, 1)),
    datum: InlineDatum(AbsentCustody { key, refund }),
    reference_script: None,
  }
}

pub fn custodyRef(index: Int) -> OutputReference {
  OutputReference { transaction_id: #"435553544f4459", output_index: index }
}

/// A custody UTxO as a spent input.
pub fn custodyInput(
  index: Int,
  key: ByteArray,
  refund: ByteArray,
  lovelace: Int,
) -> Input {
  Input {
    output_reference: custodyRef(index),
    output: custodyOutput(key, refund, lovelace),
  }
}

/// A plain payment to an address, the refund leg of custody.
pub fn paymentOutput(destinationAddress: ByteArray, lovelace: Int) -> Output {
  Output {
    address: addressOf(destinationAddress),
    value: from_lovelace(lovelace),
    datum: NoDatum,
    reference_script: None,
  }
}

/// An input holding an active token, the burn a terminal update needs.
pub fn tokenInput(index: Int, policy: ByteArray, key: ByteArray) -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: #"544f4b454e",
      output_index: index,
    },
    output: Output {
      address: addressOf(recordAddress),
      value: merge(from_lovelace(deposit), from_asset(policy, key, 1)),
      datum: InlineDatum(recordDatum()),
      reference_script: None,
    },
  }
}

// ----------------------------------------------------------------------------
// Mints
// ----------------------------------------------------------------------------

pub fn mintOf(policy: ByteArray, key: ByteArray, quantity: Int) -> Value {
  from_asset(policy, key, quantity)
}

pub fn noMint() -> Value {
  zero
}

// ----------------------------------------------------------------------------
// Time
// ----------------------------------------------------------------------------

pub fn phase1() -> interval.Interval<Int> {
  interval.between(0, 5_000)
}

pub fn phase2() -> interval.Interval<Int> {
  interval.between(10_000, 15_000)
}

pub fn phase3() -> interval.Interval<Int> {
  interval.between(20_000, 25_000)
}

/// The fold transaction: the state input first, then the requests and
/// whatever else the row needs; the continuation output first, then the
/// outputs the fold owes.
pub fn foldTx(
  root: ByteArray,
  nextRoot: ByteArray,
  requests: List<Input>,
  extraInputs: List<Input>,
  outputs: List<Output>,
  mint: Value,
) -> Transaction {
  foldTxWith(root, stateOutput(nextRoot), requests, extraInputs, outputs, mint)
}

/// The same, with the continuation supplied: the rows that tamper with a
/// pinned field build their own.
pub fn foldTxWith(
  root: ByteArray,
  continuation: Output,
  requests: List<Input>,
  extraInputs: List<Input>,
  outputs: List<Output>,
  mint: Value,
) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    validity_range: phase1(),
    inputs: list.concat([stateInput(root)], list.concat(requests, extraInputs)),
    outputs: list.concat([continuation], outputs),
    mint,
  }
}

/// A custody UTxO whose datum names a different key than the token it
/// actually carries, and the extra-asset variant: the shapes T3 refuses.
pub fn custodyOutputMismatched(
  tokenKey: ByteArray,
  datumKey: ByteArray,
  refund: ByteArray,
  lovelace: Int,
  extra: Value,
) -> Output {
  Output {
    address: cageAddress(),
    value: merge(
      merge(from_lovelace(lovelace), from_asset(absentPolicy, tokenKey, 1)),
      extra,
    ),
    datum: InlineDatum(AbsentCustody { key: datumKey, refund }),
    reference_script: None,
  }
}

/// A custody token sitting in a wallet output instead of the cage's own
/// custody.
pub fn strayCustodyOutput(key: ByteArray, lovelace: Int) -> Output {
  Output {
    address: addressOf(inserterAddress),
    value: merge(from_lovelace(lovelace), from_asset(absentPolicy, key, 1)),
    datum: NoDatum,
    reference_script: None,
  }
}

/// The cage token's asset name. A function, not a field access on the
/// constant: a module-qualified constant cannot be projected further.
pub fn cageTokenName() -> ByteArray {
  cageToken.assetName
}

/// A SECOND registry held by the same state script (#157 NOTE-004): the
/// same address, the same policy, a different cage token. Two registries
/// can share a script — the script hash is the policy, and the token name
/// is what tells them apart — so a fold of this one must not authorize a
/// custody spend belonging to the other.
pub const foreignCageToken: TokenId =
  TokenId { assetName: #"666f726569676e2d746f6b656e" }

pub const foreignStateRef: OutputReference =
  OutputReference { transaction_id: #"464f524549474e", output_index: 0 }

pub fn foreignStateInput(root: ByteArray) -> Input {
  Input {
    output_reference: foreignStateRef,
    output: Output {
      address: cageAddress(),
      value: from_asset(cagePolicy, foreignCageToken.assetName, 1)
        |> merge(from_lovelace(stateLovelace)),
      datum: InlineDatum(StateDatum(stateOf(root))),
      reference_script: None,
    },
  }
}
