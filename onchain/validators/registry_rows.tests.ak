//// Active M1 fold controls: registration, permanent termination, approvals,
//// continuation pins, value destinations, request exits and carried datums.
//// Raw excluded-edge and mixed-batch refusal controls live in permanent_boundary.

use aiken/collection/list
use aiken/fuzz
use aiken/merkle_patricia_forestry.{Proof}
use aiken/merkle_patricia_forestry as mpf
use cardano/assets.{Value, from_asset, from_lovelace, merge, zero}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, Spend, Transaction,
}
use lib
use registry/trie
use registry_fixtures as fx
use request
use state
use types.{Modify, RequestAction, StateDatum, UpdateAction}

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

fn foldOne(
  root: ByteArray,
  nextRoot: ByteArray,
  key: ByteArray,
  edge: Int,
  owner: ByteArray,
  destination: (ByteArray, Option<Data>),
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
    [fx.requestInput(0, key, edge, owner, destination, carried, lovelace)],
    extraInputs,
    outputs,
    mint,
    [UpdateAction(proof)],
  )
}

fn insertActive(mint: Value, outputs: List<Output>) -> Bool {
  foldOne(
    fx.emptyRoot(),
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.keyA,
    1,
    fx.bookerKey,
    fx.bookingDestination(),
    fx.approval(1, fx.keyA, fx.bookerKey, fx.bookingDestination()),
    fx.requestLovelace,
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

fn updateTerminal(mint: Value, outputs: List<Output>, held: List<Input>) -> Bool {
  foldOne(
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.oneLeaf(fx.keyA, fx.terminalLeaf),
    fx.keyA,
    3,
    fx.bookerKey,
    fx.noDestination(),
    fx.approval(3, fx.keyA, fx.bookerKey, fx.noDestination()),
    fx.requestLovelace,
    [],
    held,
    outputs,
    mint,
  )
}

fn activeHeld() -> List<Input> {
  [fx.tokenInput(0, fx.activePolicy, fx.keyA)]
}

fn bookerPaid() -> List<Output> {
  [fx.paymentOutput(fx.bookerAddress, fx.deposit)]
}

test insert_active_accepts() {
  insertActive(
    fx.mintOf(fx.activePolicy, fx.keyA, 1),
    bookingOutputs(fx.activePolicy),
  )
}

test update_active_to_terminal_accepts() {
  updateTerminal(
    fx.mintOf(fx.activePolicy, fx.keyA, -1),
    bookerPaid(),
    activeHeld(),
  )
}

test insert_active_delta_off_refuses() fail {
  insertActive(zero, bookingOutputs(fx.activePolicy))
}

test update_active_to_terminal_delta_off_refuses() fail {
  updateTerminal(
    fx.mintOf(fx.activePolicy, fx.keyA, -2),
    bookerPaid(),
    activeHeld(),
  )
}

test prop_delta_reads_off_the_edge(edge via fuzz.int_between(-2, 9)) {
  let delta = lib.deltaOf(edge)
  let admitted = edge == 1 || edge == 3
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

test an_unadmitted_tag_never_walks_the_trie() fail {
  foldOne(
    fx.oneLeaf(fx.keyA, fx.activeLeaf),
    fx.emptyRoot(),
    fx.keyA,
    7,
    fx.bookerKey,
    fx.noDestination(),
    fx.approval(7, fx.keyA, fx.bookerKey, fx.noDestination()),
    fx.requestLovelace,
    [],
    activeHeld(),
    [],
    zero,
  )
}

test zero_consumed_requests_refuses() fail {
  fold(fx.emptyRoot(), fx.emptyRoot(), [], [], [], zero, [UpdateAction([])])
}

fn edgeOwner(_edge: Int) -> ByteArray {
  fx.bookerKey
}

fn edgeDestination(edge: Int) -> (ByteArray, Option<Data>) {
  if edge == 1 {
    fx.bookingDestination()
  } else {
    fx.noDestination()
  }
}

fn edgeApproval(edge: Int) -> Value {
  fx.approval(edge, fx.keyA, edgeOwner(edge), edgeDestination(edge))
}

fn edgeRoot(edge: Int) -> ByteArray {
  if edge == 1 {
    fx.emptyRoot()
  } else {
    fx.oneLeaf(fx.keyA, fx.activeLeaf)
  }
}

fn edgeNextRoot(edge: Int) -> ByteArray {
  if edge == 1 {
    fx.oneLeaf(fx.keyA, fx.activeLeaf)
  } else {
    fx.oneLeaf(fx.keyA, fx.terminalLeaf)
  }
}

fn edgeMint(edge: Int) -> Value {
  fx.mintOf(
    fx.activePolicy,
    fx.keyA,
    if edge == 1 {
      1
    } else {
      -1
    },
  )
}

fn edgeOutputs(edge: Int) -> List<Output> {
  if edge == 1 {
    bookingOutputs(fx.activePolicy)
  } else {
    bookerPaid()
  }
}

fn edgeInputs(edge: Int) -> List<Input> {
  if edge == 3 {
    activeHeld()
  } else {
    []
  }
}

fn edgeProof(edge: Int) -> Proof {
  []
}

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
    edge,
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

fn foldEdge(edge: Int) -> Bool {
  foldEdgeWith(
    edge,
    edgeApproval(edge),
    fx.requestLovelace,
    edgeInputs(edge),
    edgeOutputs(edge),
    edgeMint(edge),
  )
}

fn foldEdgeMinting(edge: Int, mint: Value) -> Bool {
  foldEdgeWith(
    edge,
    edgeApproval(edge),
    fx.requestLovelace,
    edgeInputs(edge),
    edgeOutputs(edge),
    mint,
  )
}

fn foldEdgeOutputs(edge: Int, outputs: List<Output>) -> Bool {
  foldEdgeWith(
    edge,
    edgeApproval(edge),
    fx.requestLovelace,
    edgeInputs(edge),
    outputs,
    edgeMint(edge),
  )
}

fn foldEdgeCarrying(edge: Int, carried: Value) -> Bool {
  foldEdgeWith(
    edge,
    carried,
    fx.requestLovelace,
    edgeInputs(edge),
    edgeOutputs(edge),
    edgeMint(edge),
  )
}

test insert_active_without_approval_refuses() fail {
  foldEdgeCarrying(1, zero)
}

test update_terminal_without_approval_refuses() fail {
  foldEdgeCarrying(3, zero)
}

test insert_active_with_approval_accepts() {
  foldEdge(1)
}

test update_terminal_with_approval_accepts() {
  foldEdge(3)
}

test wrong_edge_approval_refuses() fail {
  foldEdgeCarrying(1, fx.approval(2, fx.keyA, edgeOwner(1), edgeDestination(1)))
}

test wrong_key_approval_refuses() fail {
  foldEdgeCarrying(1, fx.approval(1, fx.keyB, edgeOwner(1), edgeDestination(1)))
}

test wrong_owner_approval_refuses() fail {
  foldEdgeCarrying(
    1,
    fx.approval(1, fx.keyA, fx.inserterKey, edgeDestination(1)),
  )
}

test wrong_destination_approval_refuses() fail {
  foldEdgeCarrying(
    1,
    fx.approval(1, fx.keyA, edgeOwner(1), fx.readDestination()),
  )
}

test bound_approval_accepts() {
  foldEdge(1)
}

test prop_approval_name_binds_the_key(
  pair via fuzz.tuple(
    fuzz.bytearray_between(1, 8),
    fuzz.bytearray_between(1, 8),
  ),
) {
  let (left, right) = pair
  let nameOf =
    fn(key) {
      lib.approvalName(
        1,
        key,
        fx.bookerKey,
        lib.approvalDestination(fx.bookingDestination()),
      )
    }
  if left == right {
    nameOf(left) == nameOf(right)
  } else {
    nameOf(left) != nameOf(right)
  }
}

test foreign_policy_approval_refuses() fail {
  foldEdgeCarrying(
    1,
    from_asset(
      fx.foreignPolicy,
      lib.approvalName(
        1,
        fx.keyA,
        fx.bookerKey,
        lib.approvalDestination(fx.bookingDestination()),
      ),
      1,
    ),
  )
}

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
          1,
          edgeOwner(1),
          edgeDestination(1),
          edgeApproval(1),
          fx.requestLovelace,
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

test altered_tip_refuses() fail {
  foldAltering(types.State { ..nextState(), tip: fx.tip + 1 })
}

test altered_process_time_refuses() fail {
  foldAltering(types.State { ..nextState(), process_time: fx.processTime + 1 })
}

test altered_retract_time_refuses() fail {
  foldAltering(types.State { ..nextState(), retract_time: fx.retractTime + 1 })
}

test altered_application_policy_refuses() fail {
  foldAltering(
    types.State { ..nextState(), application_policy: fx.foreignPolicy },
  )
}

test altered_active_policy_refuses() fail {
  foldAltering(types.State { ..nextState(), active_policy: fx.foreignPolicy })
}

test altered_absent_policy_refuses() fail {
  foldAltering(types.State { ..nextState(), absent_policy: fx.foreignPolicy })
}

test altered_terminal_policy_refuses() fail {
  foldAltering(types.State { ..nextState(), terminal_policy: fx.foreignPolicy })
}

test all_seven_preserved_accepts() {
  foldAltering(nextState())
}

test two_active_tokens_for_one_key_refuses() fail {
  foldEdgeMinting(1, fx.mintOf(fx.activePolicy, fx.keyA, 2))
}

test active_token_for_another_key_refuses() fail {
  foldEdgeMinting(
    1,
    merge(
      fx.mintOf(fx.activePolicy, fx.keyA, 1),
      fx.mintOf(fx.activePolicy, fx.keyB, 1),
    ),
  )
}

test exactly_one_active_token_accepts() {
  foldEdge(1)
}

test absent_mint_on_active_leaf_refuses() fail {
  foldEdgeMinting(
    3,
    merge(
      fx.mintOf(fx.activePolicy, fx.keyA, -1),
      fx.mintOf(fx.absentPolicy, fx.keyA, 1),
    ),
  )
}

test stray_terminal_mint_refuses() fail {
  foldEdgeMinting(
    1,
    merge(
      fx.mintOf(fx.activePolicy, fx.keyA, 1),
      fx.mintOf(fx.terminalPolicy, fx.keyB, 1),
    ),
  )
}

test token_named_other_than_the_key_refuses() fail {
  foldEdgeMinting(1, fx.mintOf(fx.activePolicy, #"7a7a7a7a", 1))
}

test key_named_token_accepts() {
  foldEdge(1)
}

test active_token_at_another_address_refuses() fail {
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

test active_token_with_another_datum_refuses() fail {
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

test active_token_in_two_outputs_refuses() fail {
  foldEdgeWith(
    1,
    edgeApproval(1),
    fx.requestLovelace,
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

test named_output_accepts() {
  foldEdge(1)
}

test destination_carrying_the_residual_accepts() {
  foldEdge(1)
}

fn bookingCarrier(lovelace: Int) -> List<Output> {
  [
    fx.deliveryOutput(
      fx.activePolicy,
      fx.keyA,
      fx.recordAddress,
      InlineDatum(fx.recordDatum()),
      lovelace,
    ),
  ]
}

fn bookingRefusal(outputs: List<Output>) -> Option<String> {
  let root = edgeRoot(1)
  state.modifyRefusal(
    fx.stateOf(root),
    [UpdateAction(edgeProof(1))],
    fx.stateInput(root),
    fx.foldTx(
      root,
      edgeNextRoot(1),
      [
        fx.requestInput(
          0,
          fx.keyA,
          1,
          edgeOwner(1),
          edgeDestination(1),
          edgeApproval(1),
          fx.requestLovelace,
        ),
      ],
      edgeInputs(1),
      outputs,
      edgeMint(1),
    ),
  )
}

fn refusesDepositReturned(outputs: List<Output>) -> Bool {
  bookingRefusal(outputs) == Some(@"deposit-returned") && !foldEdgeOutputs(
    1,
    outputs,
  )
}

test folder_keeping_the_residual_refuses() {
  refusesDepositReturned(bookingCarrier(0))
}

test underfunded_destination_refuses() {
  refusesDepositReturned(bookingCarrier(fx.deposit - 1))
}

test carrier_at_another_address_refuses() {
  let stray =
    [
      fx.deliveryOutput(
        fx.activePolicy,
        fx.keyA,
        fx.strangerAddress,
        InlineDatum(fx.recordDatum()),
        fx.deposit,
      ),
    ]
  bookingRefusal(stray) == Some(@"destination") && !foldEdgeOutputs(1, stray)
}

test funded_carrier_has_no_refusal() {
  bookingRefusal(bookingCarrier(fx.deposit)) == None && foldEdgeOutputs(
    1,
    bookingCarrier(fx.deposit),
  )
}

test request_below_its_tip_refuses() fail {
  foldEdgeWith(
    1,
    edgeApproval(1),
    fx.tip - 1,
    edgeInputs(1),
    edgeOutputs(1),
    edgeMint(1),
  )
}

test funded_request_accepts() {
  foldEdge(1)
}

fn retract(edge: Int, signer: ByteArray) -> Bool {
  let root = fx.oneLeaf(fx.keyA, fx.terminalLeaf)
  let redeemer: Data = types.Retract(fx.stateRef)
  request.request.spend(
    fx.cagePolicy,
    fx.cageTokenName(),
    Some(fx.requestDatum(fx.keyA, edge, fx.bookerKey, fx.readDestination())),
    types.Retract(fx.stateRef),
    fx.requestRef(0),
    Transaction {
      ..transaction.placeholder,
      validity_range: fx.phase2(),
      extra_signatories: [signer],
      redeemers: [Pair(Spend(fx.requestRef(0)), redeemer)],
      outputs: [
        Output {
          address: fx.addressOf(fx.bookerAddress),
          value: from_lovelace(fx.requestLovelace),
          datum: InlineDatum(fx.requestRef(0)),
          reference_script: None,
        },
      ],
      reference_inputs: [fx.stateInput(root)],
      inputs: [
        fx.requestInput(
          0,
          fx.keyA,
          edge,
          fx.bookerKey,
          fx.readDestination(),
          zero,
          fx.requestLovelace,
        ),
      ],
    },
  )
}

test read_retracted_by_its_owner_accepts() {
  retract(6, fx.bookerKey)
}

test read_retracted_by_a_stranger_refuses() fail {
  retract(6, fx.inserterKey)
}

test update_retract_refuses() fail {
  retract(3, fx.bookerKey)
}

fn foldEdgeDestined(
  edge: Int,
  destination: (ByteArray, Option<Data>),
  outputs: List<Output>,
) -> Bool {
  foldOne(
    edgeRoot(edge),
    edgeNextRoot(edge),
    fx.keyA,
    edge,
    edgeOwner(edge),
    destination,
    fx.approval(edge, fx.keyA, edgeOwner(edge), destination),
    fx.requestLovelace,
    edgeProof(edge),
    edgeInputs(edge),
    outputs,
    edgeMint(edge),
  )
}

test active_token_with_the_carried_datum_accepts() {
  foldEdgeDestined(
    1,
    (fx.recordAddress, Some(fx.recordDatum())),
    [
      fx.deliveryOutput(
        fx.activePolicy,
        fx.keyA,
        fx.recordAddress,
        InlineDatum(fx.recordDatum()),
        fx.deposit,
      ),
    ],
  )
}

test active_token_with_another_than_the_carried_datum_refuses() fail {
  foldEdgeDestined(
    1,
    (fx.recordAddress, Some(fx.recordDatum())),
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

test active_token_with_a_datum_where_none_is_carried_refuses() fail {
  foldEdgeDestined(
    1,
    (fx.recordAddress, None),
    [
      fx.deliveryOutput(
        fx.activePolicy,
        fx.keyA,
        fx.recordAddress,
        InlineDatum(fx.recordDatum()),
        fx.deposit,
      ),
    ],
  )
}

test active_token_without_the_carried_datum_refuses() fail {
  foldEdgeDestined(
    1,
    (fx.recordAddress, Some(fx.recordDatum())),
    [
      fx.deliveryOutput(
        fx.activePolicy,
        fx.keyA,
        fx.recordAddress,
        NoDatum,
        fx.deposit,
      ),
    ],
  )
}

test carried_datum_hash_is_the_named_hash() {
  and {
    lib.destinationDatumHash(Some(fx.recordDatum())) == fx.datumHashOf(
      fx.recordDatum(),
    ),
    lib.destinationDatumHash(None) == #"",
  }
}
