use aiken/collection/list
use aiken/fuzz
use aiken/merkle_patricia_forestry.{Proof}
use aiken/merkle_patricia_forestry as mpf
use cardano/assets.{Value, from_asset, from_lovelace, merge, zero}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, Transaction,
}
use lib
use request
use state
use cardano/transaction
use t157_fixtures as fx
use types.{
  Delete, Insert, Modify, Operation, Read, RequestAction, StateDatum, Update,
  UpdateAction,
}

/// Registry-mode rows for the cage (#157 Gate S): codec, admissibility,
/// the read, batches and the terminal leaf.
///
/// Every refusal row returns False through a single named trace, so the
/// gate's mutation pass can read that trace back and bind the row to the
/// one reason the cage gave. A row that crashed would say only that the
/// validator died.

// ----------------------------------------------------------------------------
// The driver
// ----------------------------------------------------------------------------

fn fold(
  root: ByteArray,
  nextRoot: ByteArray,
  requests: List<Input>,
  extraInputs: List<Input>,
  outputs: List<Output>,
  mint: Value,
  actions: List<RequestAction>,
) -> Bool {
  state.state.spend(
    Some(StateDatum(fx.stateOf(root))),
    Modify(actions),
    fx.stateRef,
    fx.foldTx(root, nextRoot, requests, extraInputs, outputs, mint),
  )
}

/// One request, one action — the shape almost every row takes.
fn foldOne(
  root: ByteArray,
  nextRoot: ByteArray,
  key: ByteArray,
  operation: Operation,
  owner: ByteArray,
  destination: (ByteArray, ByteArray),
  carried: Value,
  lovelace: Int,
  proof: Proof,
  extraInputs: List<Input>,
  outputs: List<Output>,
  mint: Value,
) -> Bool {
  fold(
    root,
    nextRoot,
    [fx.requestInput(0, key, operation, owner, destination, carried, lovelace)],
    extraInputs,
    outputs,
    mint,
    [UpdateAction(proof)],
  )
}

// ----------------------------------------------------------------------------
// The seven admitted rows of C2, each as a complete accepting fold
// ----------------------------------------------------------------------------

/// `Insert(0x00)`: the absence witness. The token goes to the cage's own
/// custody with the inserter's refund address beside it.
fn insertAbsent(mint: Value, outputs: List<Output>) -> Bool {
  foldOne(
    fx.emptyRoot(),
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    fx.keyA,
    Insert(fx.absentLeaf),
    fx.inserterKey,
    fx.refundDestination(),
    fx.approval(0, fx.keyA, fx.inserterKey, fx.refundDestination()),
    fx.requestValue,
    [],
    [],
    outputs,
    mint,
  )
}

fn insertAbsentOutputs() -> List<Output> {
  [fx.custodyOutput(fx.keyA, fx.inserterAddress, fx.deposit)]
}

/// `Insert(0x01)`: a booking on a key nobody has witnessed.
fn insertActive(mint: Value, outputs: List<Output>) -> Bool {
  foldOne(
    fx.emptyRoot(),
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.keyA,
    Insert(fx.activeLeaf),
    fx.bookerKey,
    fx.bookingDestination(),
    fx.approval(1, fx.keyA, fx.bookerKey, fx.bookingDestination()),
    fx.requestValue,
    [],
    [],
    outputs,
    mint,
  )
}

fn bookingOutputs(policy: ByteArray) -> List<Output> {
  [
    fx.deliveryOutput(
      policy,
      fx.keyA,
      fx.recordAddress,
      InlineDatum(fx.recordDatum()),
      fx.deposit,
    ),
  ]
}

/// `Update(0x00, 0x01)`: booking a key somebody witnessed absent. The
/// custody UTxO is spent and its lovelace goes back to the inserter.
fn updateActive(mint: Value, outputs: List<Output>, custody: List<Input>) -> Bool {
  foldOne(
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.keyA,
    Update(fx.absentLeaf, fx.activeLeaf),
    fx.bookerKey,
    fx.bookingDestination(),
    fx.approval(2, fx.keyA, fx.bookerKey, fx.bookingDestination()),
    fx.requestValue,
    [],
    custody,
    outputs,
    mint,
  )
}

fn updateActiveCustody() -> List<Input> {
  [fx.custodyInput(0, fx.keyA, fx.inserterAddress, fx.deposit)]
}

fn updateActiveOutputs() -> List<Output> {
  list.concat(
    bookingOutputs(fx.activePolicy),
    [fx.paymentOutput(fx.inserterAddress, fx.deposit)],
  )
}

/// `Update(0x01, 0x02)`: the name is over. The active token rides an
/// input and burns.
fn updateTerminal(mint: Value, outputs: List<Output>, held: List<Input>) -> Bool {
  foldOne(
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.keyA,
    Update(fx.activeLeaf, fx.terminalLeaf),
    fx.bookerKey,
    fx.noDestination(),
    fx.approval(3, fx.keyA, fx.bookerKey, fx.noDestination()),
    fx.requestValue,
    [],
    held,
    outputs,
    mint,
  )
}

fn activeHeld() -> List<Input> {
  [fx.tokenInput(0, fx.activePolicy, fx.keyA)]
}

/// `Delete(0x00)`: the inserter takes their witness back.
fn deleteAbsent(mint: Value, outputs: List<Output>, custody: List<Input>) -> Bool {
  foldOne(
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    fx.emptyRoot(),
    fx.keyA,
    Delete(fx.absentLeaf),
    fx.inserterKey,
    fx.noDestination(),
    fx.approval(4, fx.keyA, fx.inserterKey, fx.noDestination()),
    fx.requestValue,
    [],
    custody,
    outputs,
    mint,
  )
}

/// `Delete(0x01)`: the key returns to absence from a live registration.
fn deleteActive(mint: Value, outputs: List<Output>, held: List<Input>) -> Bool {
  foldOne(
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.emptyRoot(),
    fx.keyA,
    Delete(fx.activeLeaf),
    fx.bookerKey,
    fx.noDestination(),
    fx.approval(5, fx.keyA, fx.bookerKey, fx.noDestination()),
    fx.requestValue,
    [],
    held,
    outputs,
    mint,
  )
}

/// `Read(0x02)`: the sole operation a terminal leaf admits. It carries
/// no approval, leaves the leaf alone and mints the terminal witness.
fn readTerminal(mint: Value, outputs: List<Output>) -> Bool {
  foldOne(
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.keyA,
    Read(fx.terminalLeaf),
    fx.bookerKey,
    fx.readDestination(),
    zero,
    fx.requestValue,
    [],
    [],
    outputs,
    mint,
  )
}

fn readOutputs() -> List<Output> {
  [
    fx.deliveryOutput(
      fx.terminalPolicy,
      fx.keyA,
      fx.bookerAddress,
      NoDatum,
      fx.deposit,
    ),
  ]
}

// ============================================================================
// G1 — the leaf codec
// ============================================================================

/// Any value byte that is not `0x00`, `0x01` or `0x02` has no leaf at
/// all, and the request is refused before any proof is checked.
fn noncodec(operation: Operation) -> Bool {
  foldOne(
    fx.emptyRoot(),
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    fx.keyA,
    operation,
    fx.inserterKey,
    fx.refundDestination(),
    fx.approval(0, fx.keyA, fx.inserterKey, fx.refundDestination()),
    fx.requestValue,
    [],
    [],
    insertAbsentOutputs(),
    fx.mintOf(fx.absentPolicy, fx.keyA, 1),
  )
}

test t157_g1_insert_noncodec_byte_refuses() fail {
  noncodec(Insert(#"03"))
}

test t157_g1_insert_empty_value_refuses() fail {
  noncodec(Insert(#""))
}

test t157_g1_update_over_marker_refuses() fail {
  noncodec(Update(fx.absentLeaf, #"6f766572"))
}

test t157_g1_delete_spelling_bytes_refuses() fail {
  noncodec(
    Delete(#"0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"),
  )
}

/// The codec is total and admits exactly three bytes: for any other
/// byte string the decoder says `None`, whatever its length.
test t157_g1_prop_codec_admits_three_bytes(
  bytes via fuzz.bytearray_between(0, 4),
) {
  let decoded = lib.decodeState(bytes)
  if bytes == fx.absentLeaf || bytes == fx.activeLeaf || bytes == fx.terminalLeaf {
    decoded != None
  } else {
    decoded == None
  }
}

// ============================================================================
// G2 — the seven rows accept, and each refuses with its delta off by one
// ============================================================================

test t157_g2_insert_absent_accepts() {
  insertAbsent(fx.mintOf(fx.absentPolicy, fx.keyA, 1), insertAbsentOutputs())
}

test t157_g2_insert_active_accepts() {
  insertActive(
    fx.mintOf(fx.activePolicy, fx.keyA, 1),
    bookingOutputs(fx.activePolicy),
  )
}

test t157_g2_update_absent_to_active_accepts() {
  updateActive(
    merge(
      fx.mintOf(fx.absentPolicy, fx.keyA, -1),
      fx.mintOf(fx.activePolicy, fx.keyA, 1),
    ),
    updateActiveOutputs(),
    updateActiveCustody(),
  )
}

test t157_g2_update_active_to_terminal_accepts() {
  updateTerminal(fx.mintOf(fx.activePolicy, fx.keyA, -1), [], activeHeld())
}

test t157_g2_delete_absent_accepts() {
  deleteAbsent(
    fx.mintOf(fx.absentPolicy, fx.keyA, -1),
    [fx.paymentOutput(fx.inserterAddress, fx.deposit)],
    updateActiveCustody(),
  )
}

test t157_g2_delete_active_accepts() {
  deleteActive(fx.mintOf(fx.activePolicy, fx.keyA, -1), [], activeHeld())
}

test t157_g2_read_terminal_accepts() {
  readTerminal(fx.mintOf(fx.terminalPolicy, fx.keyA, 1), readOutputs())
}

test t157_g2_insert_absent_delta_off_refuses() fail {
  insertAbsent(fx.mintOf(fx.absentPolicy, fx.keyA, 2), insertAbsentOutputs())
}

test t157_g2_insert_active_delta_off_refuses() fail {
  insertActive(zero, bookingOutputs(fx.activePolicy))
}

test t157_g2_update_absent_to_active_delta_off_refuses() fail {
  updateActive(
    merge(
      fx.mintOf(fx.absentPolicy, fx.keyA, -1),
      fx.mintOf(fx.activePolicy, fx.keyA, 2),
    ),
    updateActiveOutputs(),
    updateActiveCustody(),
  )
}

test t157_g2_update_active_to_terminal_delta_off_refuses() fail {
  updateTerminal(fx.mintOf(fx.activePolicy, fx.keyA, -2), [], activeHeld())
}

test t157_g2_delete_absent_delta_off_refuses() fail {
  deleteAbsent(
    zero,
    [fx.paymentOutput(fx.inserterAddress, fx.deposit)],
    updateActiveCustody(),
  )
}

test t157_g2_delete_active_delta_off_refuses() fail {
  deleteActive(fx.mintOf(fx.activePolicy, fx.keyA, 1), [], activeHeld())
}

test t157_g2_read_terminal_delta_off_refuses() fail {
  readTerminal(fx.mintOf(fx.terminalPolicy, fx.keyA, 2), readOutputs())
}

/// The token column of C2 is read off the edge and nothing else: every
/// admitted edge moves at most two kinds, and every quantity is exactly
/// one token in or one token out.
test t157_g2_prop_delta_reads_off_the_edge(edge via fuzz.int_between(-2, 9)) {
  let delta = lib.deltaOf(edge)
  let admitted = edge >= 0 && edge <= 6
  and {
    list.length(delta) <= 2,
    list.all(
      delta,
      fn(entry) {
        let (kind, quantity) = entry
        ( quantity == 1 || quantity == -1 ) && kind >= 0 && kind <= 2
      },
    ),
    if admitted {
      delta != []
    } else {
      delta == []
    },
  }
}

// ============================================================================
// G3 — every other (operation, bytes) shape refuses, before the proof
// ============================================================================

/// The edge is judged before the approval and before the proof, so these
/// rows carry neither: what refuses them is the shape itself.
fn refuseShape(root: ByteArray, operation: Operation) -> Bool {
  foldOne(
    root,
    root,
    fx.keyA,
    operation,
    fx.bookerKey,
    fx.noDestination(),
    zero,
    fx.requestValue,
    [],
    [],
    [],
    zero,
  )
}

test t157_g3_insert_terminal_refuses() fail {
  refuseShape(fx.emptyRoot(), Insert(fx.terminalLeaf))
}

test t157_g3_update_absent_to_absent_refuses() fail {
  refuseShape(fx.oneLeaf(fx.keyA, fx.absentLeaf), Update(fx.absentLeaf, fx.absentLeaf))
}

test t157_g3_update_active_to_absent_refuses() fail {
  refuseShape(fx.oneLeaf(fx.keyA, fx.activeLeaf), Update(fx.activeLeaf, fx.absentLeaf))
}

test t157_g3_update_absent_to_terminal_refuses() fail {
  refuseShape(
    fx.oneLeaf(fx.keyA, fx.absentLeaf),
    Update(fx.absentLeaf, fx.terminalLeaf),
  )
}

test t157_g3_update_active_to_active_refuses() fail {
  refuseShape(fx.oneLeaf(fx.keyA, fx.activeLeaf), Update(fx.activeLeaf, fx.activeLeaf))
}

test t157_g3_update_from_terminal_refuses() fail {
  refuseShape(
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    Update(fx.terminalLeaf, fx.activeLeaf),
  )
}

test t157_g3_delete_terminal_refuses() fail {
  refuseShape(fx.oneLeaf(fx.keyA, fx.terminalLeaf), Delete(fx.terminalLeaf))
}

test t157_g3_read_absent_refuses() fail {
  refuseShape(fx.oneLeaf(fx.keyA, fx.absentLeaf), Read(fx.absentLeaf))
}

test t157_g3_read_active_refuses() fail {
  refuseShape(fx.oneLeaf(fx.keyA, fx.activeLeaf), Read(fx.activeLeaf))
}

// ============================================================================
// G4 — the read is verified at its own position in the batch
// ============================================================================

/// `[Insert keyB, Read keyA 0x02, Insert keyC]` over a trie that already
/// holds `keyA -> 0x02`. The read's proof is the one that verifies
/// against the MIDDLE root — the trie as it stands after the first
/// insert — and the final root is the two inserts.
fn readInBatch(readProof: Proof) -> Bool {
  let start = fx.oneLeaf(fx.keyA, fx.terminalLeaf)
  let middle = fx.twoLeaves(fx.keyA, fx.terminalLeaf, fx.keyB, fx.absentLeaf)
  let thirdProof =
    fx.thirdLeafProof(
      fx.keyA,
      fx.terminalLeaf,
      fx.keyB,
      fx.absentLeaf,
      fx.keyC,
    )
  let final =
    mpf.root(
      mpf.insert(mpf.from_root(middle), fx.keyC, fx.absentLeaf, thirdProof),
    )
  fold(
    start,
    final,
    [
      fx.requestInput(
        0,
        fx.keyB,
        Insert(fx.absentLeaf),
        fx.inserterKey,
        fx.refundDestination(),
        fx.approval(0, fx.keyB, fx.inserterKey, fx.refundDestination()),
        fx.requestValue,
      ),
      fx.requestInput(
        1,
        fx.keyA,
        Read(fx.terminalLeaf),
        fx.bookerKey,
        fx.readDestination(),
        zero,
        fx.requestValue,
      ),
      fx.requestInput(
        2,
        fx.keyC,
        Insert(fx.absentLeaf),
        fx.inserterKey,
        fx.refundDestination(),
        fx.approval(0, fx.keyC, fx.inserterKey, fx.refundDestination()),
        fx.requestValue,
      ),
    ],
    [],
    [
      fx.custodyOutput(fx.keyB, fx.inserterAddress, fx.deposit),
      fx.custodyOutput(fx.keyC, fx.inserterAddress, fx.deposit),
      fx.deliveryOutput(
        fx.terminalPolicy,
        fx.keyA,
        fx.bookerAddress,
        NoDatum,
        fx.deposit,
      ),
    ],
    merge(
      merge(
        fx.mintOf(fx.absentPolicy, fx.keyB, 1),
        fx.mintOf(fx.absentPolicy, fx.keyC, 1),
      ),
      fx.mintOf(fx.terminalPolicy, fx.keyA, 1),
    ),
    [
      UpdateAction(fx.siblingProof(fx.keyA, fx.terminalLeaf, fx.keyB)),
      UpdateAction(readProof),
      UpdateAction(
        fx.thirdLeafProof(
          fx.keyA,
          fx.terminalLeaf,
          fx.keyB,
          fx.absentLeaf,
          fx.keyC,
        ),
      ),
    ],
  )
}

/// The proof of `keyA` against the middle root: its sibling there is the
/// leaf the first insert just created.
fn middleProof() -> Proof {
  fx.siblingProof(fx.keyB, fx.absentLeaf, fx.keyA)
}

test t157_g4_read_verifies_against_the_middle_root() {
  readInBatch(middleProof())
}

/// The same read proved against the root the batch STARTED from: at the
/// read's position that root is already gone.
test t157_g4_read_against_initial_root_refuses() fail {
  readInBatch([])
}

/// And against the root the batch ENDS at, which does not exist yet when
/// the read is folded.
test t157_g4_read_against_final_root_refuses() fail {
  readInBatch(
    [
      fx.branchStep(
        [
          fx.slotOf(fx.keyA, fx.terminalLeaf),
          fx.slotOf(fx.keyB, fx.absentLeaf),
          fx.slotOf(fx.keyC, fx.absentLeaf),
        ],
        fx.keyA,
      ),
    ],
  )
}

// ============================================================================
// G5 — a batch of only reads
// ============================================================================

/// Two reads of one terminal name. Reads do not move the trie, so the
/// root is unchanged; each mints its own terminal witness, and because
/// one asset cannot sit in two outputs they share a carrier that holds
/// both tokens and both deposits.
fn twoReads(mint: Value, outputs: List<Output>) -> Bool {
  let root = fx.oneLeaf(fx.keyA, fx.terminalLeaf)
  fold(
    root,
    root,
    [
      fx.requestInput(
        0,
        fx.keyA,
        Read(fx.terminalLeaf),
        fx.bookerKey,
        fx.readDestination(),
        zero,
        fx.requestValue,
      ),
      fx.requestInput(
        1,
        fx.keyA,
        Read(fx.terminalLeaf),
        fx.bookerKey,
        fx.readDestination(),
        zero,
        fx.requestValue,
      ),
    ],
    [],
    outputs,
    mint,
    [UpdateAction([]), UpdateAction([])],
  )
}

test t157_g5_batch_of_only_reads_accepts() {
  twoReads(
    fx.mintOf(fx.terminalPolicy, fx.keyA, 2),
    [
      fx.deliveryOutputN(
        fx.terminalPolicy,
        fx.keyA,
        2,
        fx.bookerAddress,
        NoDatum,
        fx.deposit * 2,
      ),
    ],
  )
}

/// A `Modify` that consumes no request at all is not a batch.
test t157_g5_zero_consumed_requests_refuses() fail {
  fold(fx.emptyRoot(), fx.emptyRoot(), [], [], [], zero, [UpdateAction([])])
}

// ============================================================================
// M3 — only a terminal leaf may be read
// ============================================================================

test t157_m3_read_of_active_leaf_refuses() fail {
  refuseShape(fx.oneLeaf(fx.keyA, fx.activeLeaf), Read(fx.activeLeaf))
}

test t157_m3_read_of_terminal_leaf_accepts() {
  readTerminal(fx.mintOf(fx.terminalPolicy, fx.keyA, 1), readOutputs())
}

// ============================================================================
// N10 — a terminal leaf admits the read and nothing else
// ============================================================================

/// Every tree-changing request for a key whose leaf is `0x02`, with any
/// value, is refused; `Read(0x02)` is the one operation that is not.
fn onTerminal(operation: Operation) -> Bool {
  refuseShape(fx.oneLeaf(fx.keyA, fx.terminalLeaf), operation)
}

test t157_n10_update_terminal_to_absent_refuses() fail {
  onTerminal(Update(fx.terminalLeaf, fx.absentLeaf))
}

test t157_n10_update_terminal_to_active_refuses() fail {
  onTerminal(Update(fx.terminalLeaf, fx.activeLeaf))
}

test t157_n10_update_terminal_to_terminal_refuses() fail {
  onTerminal(Update(fx.terminalLeaf, fx.terminalLeaf))
}

test t157_n10_delete_terminal_refuses() fail {
  onTerminal(Delete(fx.terminalLeaf))
}

test t157_n10_insert_terminal_refuses() fail {
  onTerminal(Insert(fx.terminalLeaf))
}

test t157_n10_update_terminal_to_noncodec_refuses() fail {
  onTerminal(Update(fx.terminalLeaf, #"03"))
}

test t157_n10_update_terminal_to_empty_refuses() fail {
  onTerminal(Update(fx.terminalLeaf, #""))
}

/// The accepting half: the terminal read is the sole operation a `0x02`
/// leaf admits, it leaves the leaf exactly where it is, and it mints the
/// `+1 terminal` the model promises (A-001).
test t157_n10_read_terminal_accepts() {
  readTerminal(fx.mintOf(fx.terminalPolicy, fx.keyA, 1), readOutputs())
}

// ============================================================================
// The generic edge driver: one canonical accepting fold per C2 row, with
// every part of it open to a row's single mutation
// ============================================================================

fn edgeOperation(edge: Int) -> Operation {
  if edge == 0 {
    Insert(fx.absentLeaf)
  } else if edge == 1 {
    Insert(fx.activeLeaf)
  } else if edge == 2 {
    Update(fx.absentLeaf, fx.activeLeaf)
  } else if edge == 3 {
    Update(fx.activeLeaf, fx.terminalLeaf)
  } else if edge == 4 {
    Delete(fx.absentLeaf)
  } else if edge == 5 {
    Delete(fx.activeLeaf)
  } else {
    Read(fx.terminalLeaf)
  }
}

fn edgeOwner(edge: Int) -> ByteArray {
  if edge == 0 || edge == 4 {
    fx.inserterKey
  } else {
    fx.bookerKey
  }
}

fn edgeDestination(edge: Int) -> (ByteArray, ByteArray) {
  if edge == 0 {
    fx.refundDestination()
  } else if edge == 1 || edge == 2 {
    fx.bookingDestination()
  } else if edge == 6 {
    fx.readDestination()
  } else {
    fx.noDestination()
  }
}

/// The approval the application minted for exactly this request. The
/// read (edge 6) carries none and needs none.
fn edgeApproval(edge: Int) -> Value {
  if edge == 6 {
    zero
  } else {
    fx.approval(edge, fx.keyA, edgeOwner(edge), edgeDestination(edge))
  }
}

fn edgeRoot(edge: Int) -> ByteArray {
  if edge == 0 || edge == 1 {
    fx.emptyRoot()
  } else if edge == 2 || edge == 4 {
    fx.oneLeaf(fx.keyA, fx.absentLeaf)
  } else if edge == 6 {
    fx.oneLeaf(fx.keyA, fx.terminalLeaf)
  } else {
    fx.oneLeaf(fx.keyA, fx.activeLeaf)
  }
}

fn edgeNextRoot(edge: Int) -> ByteArray {
  if edge == 0 {
    fx.oneLeaf(fx.keyA, fx.absentLeaf)
  } else if edge == 1 || edge == 2 {
    fx.oneLeaf(fx.keyA, fx.activeLeaf)
  } else if edge == 3 {
    fx.oneLeaf(fx.keyA, fx.terminalLeaf)
  } else if edge == 6 {
    fx.oneLeaf(fx.keyA, fx.terminalLeaf)
  } else {
    fx.emptyRoot()
  }
}

/// The token column of C2, as a mint.
fn edgeMint(edge: Int) -> Value {
  if edge == 0 {
    fx.mintOf(fx.absentPolicy, fx.keyA, 1)
  } else if edge == 1 {
    fx.mintOf(fx.activePolicy, fx.keyA, 1)
  } else if edge == 2 {
    merge(
      fx.mintOf(fx.absentPolicy, fx.keyA, -1),
      fx.mintOf(fx.activePolicy, fx.keyA, 1),
    )
  } else if edge == 3 || edge == 5 {
    fx.mintOf(fx.activePolicy, fx.keyA, -1)
  } else if edge == 4 {
    fx.mintOf(fx.absentPolicy, fx.keyA, -1)
  } else {
    fx.mintOf(fx.terminalPolicy, fx.keyA, 1)
  }
}

/// The outputs the edge's duties demand.
fn edgeOutputs(edge: Int) -> List<Output> {
  if edge == 0 {
    [fx.custodyOutput(fx.keyA, fx.inserterAddress, fx.deposit)]
  } else if edge == 1 {
    bookingOutputs(fx.activePolicy)
  } else if edge == 2 {
    updateActiveOutputs()
  } else if edge == 4 {
    [fx.paymentOutput(fx.inserterAddress, fx.deposit)]
  } else if edge == 6 {
    readOutputs()
  } else {
    []
  }
}

/// The inputs the edge needs beside its request: the custody UTxO an
/// absent consumption spends, the record the active burn comes from.
fn edgeInputs(edge: Int) -> List<Input> {
  if edge == 2 || edge == 4 {
    updateActiveCustody()
  } else if edge == 3 || edge == 5 {
    activeHeld()
  } else {
    []
  }
}

fn edgeProof(edge: Int) -> Proof {
  []
}

/// A complete fold of one edge, every part overridable by the row that
/// mutates it.
fn foldEdgeWith(
  edge: Int,
  carried: Value,
  lovelace: Int,
  extraInputs: List<Input>,
  outputs: List<Output>,
  mint: Value,
) -> Bool {
  foldOne(
    edgeRoot(edge),
    edgeNextRoot(edge),
    fx.keyA,
    edgeOperation(edge),
    edgeOwner(edge),
    edgeDestination(edge),
    carried,
    lovelace,
    edgeProof(edge),
    extraInputs,
    outputs,
    mint,
  )
}

/// The canonical accepting fold of one edge.
fn foldEdge(edge: Int) -> Bool {
  foldEdgeWith(
    edge,
    edgeApproval(edge),
    fx.requestValue,
    edgeInputs(edge),
    edgeOutputs(edge),
    edgeMint(edge),
  )
}

/// The same fold with only its mint replaced.
fn foldEdgeMinting(edge: Int, mint: Value) -> Bool {
  foldEdgeWith(
    edge,
    edgeApproval(edge),
    fx.requestValue,
    edgeInputs(edge),
    edgeOutputs(edge),
    mint,
  )
}

/// The same fold with only its outputs replaced.
fn foldEdgeOutputs(edge: Int, outputs: List<Output>) -> Bool {
  foldEdgeWith(
    edge,
    edgeApproval(edge),
    fx.requestValue,
    edgeInputs(edge),
    outputs,
    edgeMint(edge),
  )
}

/// The same fold with only the approval its request carries replaced.
fn foldEdgeCarrying(edge: Int, carried: Value) -> Bool {
  foldEdgeWith(
    edge,
    carried,
    fx.requestValue,
    edgeInputs(edge),
    edgeOutputs(edge),
    edgeMint(edge),
  )
}

// ============================================================================
// A1 — a tree edge is folded only with its approval
// ============================================================================

test t157_a1_insert_absent_without_approval_refuses() fail {
  foldEdgeCarrying(0, zero)
}

test t157_a1_insert_active_without_approval_refuses() fail {
  foldEdgeCarrying(1, zero)
}

test t157_a1_update_active_without_approval_refuses() fail {
  foldEdgeCarrying(2, zero)
}

test t157_a1_update_terminal_without_approval_refuses() fail {
  foldEdgeCarrying(3, zero)
}

test t157_a1_delete_absent_without_approval_refuses() fail {
  foldEdgeCarrying(4, zero)
}

test t157_a1_delete_active_without_approval_refuses() fail {
  foldEdgeCarrying(5, zero)
}

test t157_a1_insert_absent_with_approval_accepts() {
  foldEdge(0)
}

test t157_a1_insert_active_with_approval_accepts() {
  foldEdge(1)
}

test t157_a1_update_active_with_approval_accepts() {
  foldEdge(2)
}

test t157_a1_update_terminal_with_approval_accepts() {
  foldEdge(3)
}

test t157_a1_delete_absent_with_approval_accepts() {
  foldEdge(4)
}

test t157_a1_delete_active_with_approval_accepts() {
  foldEdge(5)
}

// ============================================================================
// A2 — the approval's name binds this edge, key, owner and destination
// ============================================================================

test t157_a2_wrong_edge_approval_refuses() fail {
  foldEdgeCarrying(
    1,
    fx.approval(2, fx.keyA, edgeOwner(1), edgeDestination(1)),
  )
}

test t157_a2_wrong_key_approval_refuses() fail {
  foldEdgeCarrying(
    1,
    fx.approval(1, fx.keyB, edgeOwner(1), edgeDestination(1)),
  )
}

test t157_a2_wrong_owner_approval_refuses() fail {
  foldEdgeCarrying(
    1,
    fx.approval(1, fx.keyA, fx.inserterKey, edgeDestination(1)),
  )
}

test t157_a2_wrong_destination_approval_refuses() fail {
  foldEdgeCarrying(
    1,
    fx.approval(1, fx.keyA, edgeOwner(1), fx.readDestination()),
  )
}

test t157_a2_bound_approval_accepts() {
  foldEdge(1)
}

/// The binding is a function of all four components: with the owner and
/// the destination fixed, two different keys never share an approval
/// name, and the same key always produces the same one.
test t157_a2_prop_approval_name_binds_the_key(
  pair via fuzz.tuple(
    fuzz.bytearray_between(1, 8),
    fuzz.bytearray_between(1, 8),
  ),
) {
  let (left, right) = pair
  let nameOf =
    fn(key) {
      lib.approvalName(1, key, fx.bookerKey, fx.bookingDestination())
    }
  if left == right {
    nameOf(left) == nameOf(right)
  } else {
    nameOf(left) != nameOf(right)
  }
}

// ============================================================================
// A3 — a read needs no approval; a foreign policy is no approval
// ============================================================================

test t157_a3_read_without_approval_accepts() {
  foldEdge(6)
}

test t157_a3_foreign_policy_approval_refuses() fail {
  foldEdgeCarrying(
    1,
    from_asset(
      fx.foreignPolicy,
      lib.approvalName(1, fx.keyA, fx.bookerKey, fx.bookingDestination()),
      1,
    ),
  )
}

// ============================================================================
// A4 — every field but the root survives the fold
// ============================================================================

/// A fold whose continuation alters exactly one pinned field.
fn foldAltering(altered: types.State) -> Bool {
  state.state.spend(
    Some(StateDatum(fx.stateOf(edgeRoot(1)))),
    Modify([UpdateAction([])]),
    fx.stateRef,
    fx.foldTxWith(
      edgeRoot(1),
      fx.stateOutputOf(altered),
      [
        fx.requestInput(
          0,
          fx.keyA,
          edgeOperation(1),
          edgeOwner(1),
          edgeDestination(1),
          edgeApproval(1),
          fx.requestValue,
        ),
      ],
      [],
      edgeOutputs(1),
      edgeMint(1),
    ),
  )
}

fn nextState() -> types.State {
  fx.stateOf(edgeNextRoot(1))
}

test t157_a4_altered_tip_refuses() fail {
  foldAltering(types.State { ..nextState(), tip: fx.tip + 1 })
}

test t157_a4_altered_process_time_refuses() fail {
  foldAltering(types.State { ..nextState(), process_time: fx.processTime + 1 })
}

test t157_a4_altered_retract_time_refuses() fail {
  foldAltering(types.State { ..nextState(), retract_time: fx.retractTime + 1 })
}

test t157_a4_altered_application_policy_refuses() fail {
  foldAltering(
    types.State { ..nextState(), application_policy: fx.foreignPolicy },
  )
}

test t157_a4_altered_active_policy_refuses() fail {
  foldAltering(types.State { ..nextState(), active_policy: fx.foreignPolicy })
}

test t157_a4_altered_absent_policy_refuses() fail {
  foldAltering(types.State { ..nextState(), absent_policy: fx.foreignPolicy })
}

test t157_a4_altered_terminal_policy_refuses() fail {
  foldAltering(types.State { ..nextState(), terminal_policy: fx.foreignPolicy })
}

test t157_a4_all_seven_preserved_accepts() {
  foldAltering(nextState())
}

// ============================================================================
// M1-M5, P3 — the mint equals the summed C2 column, exactly
// ============================================================================

test t157_m1_two_active_tokens_for_one_key_refuses() fail {
  foldEdgeMinting(1, fx.mintOf(fx.activePolicy, fx.keyA, 2))
}

test t157_m1_active_token_for_another_key_refuses() fail {
  foldEdgeMinting(
    1,
    merge(
      fx.mintOf(fx.activePolicy, fx.keyA, 1),
      fx.mintOf(fx.activePolicy, fx.keyB, 1),
    ),
  )
}

test t157_m1_exactly_one_active_token_accepts() {
  foldEdge(1)
}

/// There is no C2 row that mints an absent witness for a live key, so a
/// fold that does is a delta the edges do not entail.
test t157_m2_absent_mint_on_active_leaf_refuses() fail {
  foldEdgeMinting(
    3,
    merge(
      fx.mintOf(fx.activePolicy, fx.keyA, -1),
      fx.mintOf(fx.absentPolicy, fx.keyA, 1),
    ),
  )
}

test t157_m2_insert_absent_on_unknown_key_accepts() {
  foldEdge(0)
}

test t157_m4_update_active_without_absent_burn_refuses() fail {
  foldEdgeMinting(2, fx.mintOf(fx.activePolicy, fx.keyA, 1))
}

test t157_m4_update_active_with_both_legs_accepts() {
  foldEdge(2)
}

/// Nothing else may move under the three pinned policies: a stray
/// terminal mint no consumed request entails is the same refusal.
test t157_m5_stray_terminal_mint_refuses() fail {
  foldEdgeMinting(
    1,
    merge(
      fx.mintOf(fx.activePolicy, fx.keyA, 1),
      fx.mintOf(fx.terminalPolicy, fx.keyB, 1),
    ),
  )
}

/// Under each token policy the asset name IS the registry key (D-ASSET):
/// a correctly-sized mint under the right policy with any other name is
/// a delta mismatch.
test t157_p3_token_named_other_than_the_key_refuses() fail {
  foldEdgeMinting(1, fx.mintOf(fx.activePolicy, #"7a7a7a7a", 1))
}

test t157_p3_key_named_token_accepts() {
  foldEdge(1)
}

// ============================================================================
// T1, T2 — the minted token lands where the request named, and nowhere else
// ============================================================================

test t157_t1_active_token_at_another_address_refuses() fail {
  foldEdgeOutputs(
    1,
    [
      fx.deliveryOutput(
        fx.activePolicy,
        fx.keyA,
        fx.strangerAddress,
        InlineDatum(fx.recordDatum()),
        fx.deposit,
      ),
    ],
  )
}

test t157_t1_active_token_with_another_datum_refuses() fail {
  foldEdgeOutputs(
    1,
    [
      fx.deliveryOutput(
        fx.activePolicy,
        fx.keyA,
        fx.recordAddress,
        InlineDatum(fx.otherDatum()),
        fx.deposit,
      ),
    ],
  )
}

/// One asset in two outputs is not "exactly one output carrying it",
/// even when both sit at the named destination.
test t157_t1_active_token_in_two_outputs_refuses() fail {
  foldEdgeWith(
    1,
    edgeApproval(1),
    fx.requestValue,
    [fx.tokenInput(0, fx.activePolicy, fx.keyA)],
    [
      fx.deliveryOutput(
        fx.activePolicy,
        fx.keyA,
        fx.recordAddress,
        InlineDatum(fx.recordDatum()),
        fx.deposit,
      ),
      fx.deliveryOutput(
        fx.activePolicy,
        fx.keyA,
        fx.recordAddress,
        InlineDatum(fx.recordDatum()),
        fx.deposit,
      ),
    ],
    edgeMint(1),
  )
}

test t157_t1_named_output_accepts() {
  foldEdge(1)
}

test t157_t2_terminal_token_elsewhere_refuses() fail {
  foldEdgeOutputs(
    6,
    [
      fx.deliveryOutput(
        fx.terminalPolicy,
        fx.keyA,
        fx.strangerAddress,
        NoDatum,
        fx.deposit,
      ),
    ],
  )
}

test t157_t2_read_destination_accepts() {
  foldEdge(6)
}

// ============================================================================
// T3 — the absent token's only home is the cage's own custody
// ============================================================================

test t157_t3_absent_token_in_a_wallet_refuses() fail {
  foldEdgeOutputs(0, [fx.strayCustodyOutput(fx.keyA, fx.deposit)])
}

test t157_t3_custody_naming_another_key_refuses() fail {
  foldEdgeOutputs(
    0,
    [
      fx.custodyOutputMismatched(
        fx.keyA,
        fx.keyB,
        fx.inserterAddress,
        fx.deposit,
        zero,
      ),
    ],
  )
}

test t157_t3_custody_with_another_refund_refuses() fail {
  foldEdgeOutputs(
    0,
    [fx.custodyOutput(fx.keyA, fx.strangerAddress, fx.deposit)],
  )
}

test t157_t3_custody_carrying_an_extra_asset_refuses() fail {
  foldEdgeOutputs(
    0,
    [
      fx.custodyOutputMismatched(
        fx.keyA,
        fx.keyA,
        fx.inserterAddress,
        fx.deposit,
        from_asset(fx.foreignPolicy, fx.keyB, 1),
      ),
    ],
  )
}

test t157_t3_exact_custody_output_accepts() {
  foldEdge(0)
}

// ============================================================================
// T4 — consuming an absent witness pays its inserter back
// ============================================================================

/// The booker is not the inserter: Alice books the name Carol witnessed
/// absent, and Carol's deposit goes back to Carol.
test t157_t4_booking_over_custody_refunds_the_inserter() {
  foldEdge(2)
}

test t157_t4_deleting_custody_refunds_the_inserter() {
  foldEdge(4)
}

test t157_t4_refund_below_the_held_lovelace_refuses() fail {
  foldEdgeOutputs(
    2,
    list.concat(
      bookingOutputs(fx.activePolicy),
      [fx.paymentOutput(fx.inserterAddress, fx.deposit - 1)],
    ),
  )
}

test t157_t4_refund_to_the_booker_instead_refuses() fail {
  foldEdgeOutputs(
    2,
    list.concat(
      bookingOutputs(fx.activePolicy),
      [fx.paymentOutput(fx.bookerAddress, fx.deposit)],
    ),
  )
}

test t157_t4_custody_left_unspent_refuses() fail {
  foldEdgeWith(
    2,
    edgeApproval(2),
    fx.requestValue,
    [],
    edgeOutputs(2),
    edgeMint(2),
  )
}

// ============================================================================
// T5 — the cage's own spending path for a custody UTxO
// ============================================================================

fn spendCustody(
  key: ByteArray,
  refund: ByteArray,
  otherInputs: List<Input>,
  outputs: List<Output>,
) -> Bool {
  state.state.spend(
    Some(types.AbsentCustody { key, refund }),
    Modify([]),
    fx.custodyRef(0),
    Transaction {
      ..transaction.placeholder,
      validity_range: fx.phase1(),
      inputs: list.concat(
        [fx.custodyInput(0, key, refund, fx.deposit)],
        otherInputs,
      ),
      outputs,
    },
  )
}

fn consumingRequest(key: ByteArray, operation: Operation) -> Input {
  fx.requestInput(
    0,
    key,
    operation,
    fx.bookerKey,
    fx.bookingDestination(),
    zero,
    fx.requestValue,
  )
}

test t157_t5_plain_custody_spend_refuses() fail {
  spendCustody(
    fx.keyA,
    fx.inserterAddress,
    [],
    [fx.paymentOutput(fx.inserterAddress, fx.deposit)],
  )
}

test t157_t5_fold_for_another_key_refuses() fail {
  spendCustody(
    fx.keyA,
    fx.inserterAddress,
    [consumingRequest(fx.keyB, Update(fx.absentLeaf, fx.activeLeaf))],
    [fx.paymentOutput(fx.inserterAddress, fx.deposit)],
  )
}

test t157_t5_fold_whose_request_is_a_read_refuses() fail {
  spendCustody(
    fx.keyA,
    fx.inserterAddress,
    [consumingRequest(fx.keyA, Read(fx.terminalLeaf))],
    [fx.paymentOutput(fx.inserterAddress, fx.deposit)],
  )
}

test t157_t5_fold_consuming_this_key_accepts() {
  spendCustody(
    fx.keyA,
    fx.inserterAddress,
    [consumingRequest(fx.keyA, Update(fx.absentLeaf, fx.activeLeaf))],
    [fx.paymentOutput(fx.inserterAddress, fx.deposit)],
  )
}

// ============================================================================
// T6 — the deposit that rode the request comes back
// ============================================================================

test t157_t6_destination_carrying_the_residual_accepts() {
  foldEdge(1)
}

test t157_t6_folder_keeping_the_residual_refuses() fail {
  foldEdgeOutputs(
    1,
    [
      fx.deliveryOutput(
        fx.activePolicy,
        fx.keyA,
        fx.recordAddress,
        InlineDatum(fx.recordDatum()),
        0,
      ),
    ],
  )
}

test t157_t6_underfunded_destination_refuses() fail {
  foldEdgeOutputs(
    1,
    [
      fx.deliveryOutput(
        fx.activePolicy,
        fx.keyA,
        fx.recordAddress,
        InlineDatum(fx.recordDatum()),
        fx.deposit - 1,
      ),
    ],
  )
}

// ============================================================================
// V1 — every consumed request carries at least its tip
// ============================================================================

test t157_v1_request_below_its_tip_refuses() fail {
  foldEdgeWith(
    1,
    edgeApproval(1),
    fx.tip - 1,
    edgeInputs(1),
    edgeOutputs(1),
    edgeMint(1),
  )
}

test t157_v1_funded_request_accepts() {
  foldEdge(1)
}

// ============================================================================
// V2 — reads retract, exactly as inserts do
// ============================================================================

fn retract(operation: Operation, signer: ByteArray) -> Bool {
  let root = fx.oneLeaf(fx.keyA, fx.terminalLeaf)
  request.request.spend(
    fx.cagePolicy,
    fx.cageTokenName(),
    Some(fx.requestDatum(fx.keyA, operation, fx.bookerKey, fx.readDestination())),
    types.Retract(fx.stateRef),
    fx.requestRef(0),
    Transaction {
      ..transaction.placeholder,
      validity_range: fx.phase2(),
      extra_signatories: [signer],
      inputs: [
        fx.stateInput(root),
        fx.requestInput(
          0,
          fx.keyA,
          operation,
          fx.bookerKey,
          fx.readDestination(),
          zero,
          fx.requestValue,
        ),
      ],
    },
  )
}

test t157_v2_read_retracted_by_its_owner_accepts() {
  retract(Read(fx.terminalLeaf), fx.bookerKey)
}

test t157_v2_read_retracted_by_a_stranger_refuses() fail {
  retract(Read(fx.terminalLeaf), fx.inserterKey)
}

/// The completion-only custody still binds updates: they do not retract.
test t157_v2_update_retract_refuses() fail {
  retract(Update(fx.activeLeaf, fx.terminalLeaf), fx.bookerKey)
}
