use aiken/fuzz
use cardano/assets.{merge, zero}
use cardano/transaction.{InlineDatum, NoDatum, Transaction}
use registry_fixtures as fx
use state as m1
use types.{End, Modify, StateDatum, UpdateAction}

/// Independently constructed complete legacy folds, including a valid approval
/// for every tree-changing edge. Absent and terminal roots are component
/// fixtures, not evidence that the registry can reach those states. The two
/// edges the old fold admitted were accepted by it; since CP2 each of the seven
/// is refused as a fold with no member.
fn edgeTransaction(edge: Int) -> (ByteArray, Transaction) {
  let root =
    if edge == 0 || edge == 1 {
      fx.emptyRoot()
    } else if edge == 2 || edge == 4 {
      fx.oneLeaf(fx.keyA, fx.absentLeaf)
    } else if edge == 6 {
      fx.oneLeaf(fx.keyA, fx.terminalLeaf)
    } else {
      fx.oneLeaf(fx.keyA, fx.activeLeaf)
    }
  let next =
    if edge == 0 {
      fx.oneLeaf(fx.keyA, fx.absentLeaf)
    } else if edge == 1 || edge == 2 {
      fx.oneLeaf(fx.keyA, fx.activeLeaf)
    } else if edge == 3 || edge == 6 {
      fx.oneLeaf(fx.keyA, fx.terminalLeaf)
    } else {
      fx.emptyRoot()
    }
  let destination =
    if edge == 0 {
      fx.refundDestination()
    } else if edge == 1 || edge == 2 {
      fx.bookingDestination()
    } else if edge == 6 {
      fx.readDestination()
    } else {
      fx.noDestination()
    }
  let owner =
    if edge == 0 || edge == 4 {
      fx.inserterKey
    } else {
      fx.bookerKey
    }
  let carried =
    if edge == 6 || edge < 0 || edge > 6 {
      zero
    } else {
      fx.approval(edge, fx.keyA, owner, destination)
    }
  let inputs =
    if edge == 2 || edge == 4 {
      [fx.custodyInput(0, fx.keyA, fx.inserterAddress, fx.deposit)]
    } else if edge == 3 || edge == 5 {
      [fx.tokenInput(0, fx.activePolicy, fx.keyA)]
    } else {
      []
    }
  let outputs =
    if edge == 0 {
      [fx.custodyOutput(fx.keyA, fx.inserterAddress, fx.deposit)]
    } else if edge == 1 || edge == 2 {
      let delivery =
        fx.deliveryOutput(
          fx.activePolicy,
          fx.keyA,
          fx.recordAddress,
          InlineDatum(fx.recordDatum()),
          fx.deposit,
        )
      if edge == 2 {
        [delivery, fx.paymentOutput(fx.inserterAddress, fx.deposit)]
      } else {
        [delivery]
      }
    } else if edge == 6 {
      [
        fx.deliveryOutput(
          fx.terminalPolicy,
          fx.keyA,
          fx.bookerAddress,
          NoDatum,
          fx.deposit,
        ),
      ]
    } else if edge == 4 {
      [fx.paymentOutput(fx.inserterAddress, fx.deposit * 2)]
    } else {
      [fx.paymentOutput(fx.bookerAddress, fx.deposit)]
    }
  let mint =
    if edge == 0 {
      fx.mintOf(fx.absentPolicy, fx.keyA, 1)
    } else if edge == 1 {
      fx.mintOf(fx.activePolicy, fx.keyA, 1)
    } else if edge == 2 {
      merge(
        fx.mintOf(fx.absentPolicy, fx.keyA, -1),
        fx.mintOf(fx.activePolicy, fx.keyA, 1),
      )
    } else if edge == 4 {
      fx.mintOf(fx.absentPolicy, fx.keyA, -1)
    } else if edge == 6 {
      fx.mintOf(fx.terminalPolicy, fx.keyA, 1)
    } else {
      fx.mintOf(fx.activePolicy, fx.keyA, -1)
    }
  let requests =
    [
      fx.requestInput(
        0,
        fx.keyA,
        edge,
        owner,
        destination,
        carried,
        fx.requestLovelace,
      ),
    ]
  (root, fx.foldTx(root, next, requests, inputs, outputs, mint))
}

// ----------------------------------------------------------------------------
// No legacy edge folds any more
// ----------------------------------------------------------------------------
//
// CP2: the registry admits the registrations and terminations its pending
// requests (`RegistrationDatum`, `TerminationDatum`) carry, nothing else. The
// seven-edge request of the old fold, with its approval, is no member of the
// fold for any edge: the two edges the old fold admitted (insert active, update
// terminal) are refused with the five it never admitted, each as a fold with
// no member (`empty-fold`). Their accepting controls and the edge-inadmissible
// reason are retired with the route: the tagged folds are in
// `tagged_fold.tests.ak`.
//
// Retired with the seven-edge boundary:
//
// - `permanent_boundary` (edges 1 and 3 accepted, the rest refused) and
//   `excluded_reason_before_approval_or_proof` (`edge-inadmissible`) are
//   `permanent_boundary_no_legacy_edge_folds` below;
// - `excluded_request_can_still_be_rejected` is
//   `tagged_fold_retires_rejected_*` and the legacy rows of
//   `deposit_exits.tests.ak`;
// - `mixed_batch_refuses_the_excluded_member` stays, as a legacy batch with no
//   member, and its tagged counterpart is
//   `tagged_fold_refuses_a_legacy_request_beside_a_tagged_member`;
// - the three context exports for the external checker
//   (`export_compiled_contexts`, `export_mixed_and_malformed_contexts`,
//   `export_request_and_mint_routes`) described the legacy edges; the contexts
//   of the tagged folds are exported with the compiled identities, once, after
//   the accepted GREEN.

test permanent_boundary_no_legacy_edge_folds(edge via fuzz.int_between(0, 6)) {
  let (root, tx) = edgeTransaction(edge)
  let actions = [UpdateAction([])]
  let datum = Some(StateDatum(fx.stateOf(root)))
  m1.state.spend(datum, Modify(actions), fx.stateRef, tx) == False && m1.modifyRefusal(
    fx.stateOf(root),
    actions,
    fx.stateInput(root),
    tx,
  ) == Some(@"empty-fold")
}

test ownerless_end_stays_refused() fail {
  let (root, tx) = edgeTransaction(1)
  m1.state.spend(Some(StateDatum(fx.stateOf(root))), End, fx.stateRef, tx)
}

fn mixedTransaction() -> (ByteArray, Transaction) {
  let root = fx.oneLeaf(fx.keyB, fx.terminalLeaf)
  let next = fx.twoLeaves(fx.keyA, fx.activeLeaf, fx.keyB, fx.terminalLeaf)
  let requests =
    [
      fx.requestInput(
        0,
        fx.keyA,
        1,
        fx.bookerKey,
        fx.bookingDestination(),
        fx.approval(1, fx.keyA, fx.bookerKey, fx.bookingDestination()),
        fx.requestLovelace,
      ),
      fx.requestInput(
        1,
        fx.keyB,
        6,
        fx.bookerKey,
        fx.readDestination(),
        zero,
        fx.requestLovelace,
      ),
    ]
  let outputs =
    [
      fx.deliveryOutput(
        fx.activePolicy,
        fx.keyA,
        fx.recordAddress,
        InlineDatum(fx.recordDatum()),
        fx.deposit,
      ),
      fx.deliveryOutput(
        fx.terminalPolicy,
        fx.keyB,
        fx.bookerAddress,
        NoDatum,
        fx.deposit,
      ),
    ]
  (
    root,
    fx.foldTx(
      root,
      next,
      requests,
      [],
      outputs,
      merge(
        fx.mintOf(fx.activePolicy, fx.keyA, 1),
        fx.mintOf(fx.terminalPolicy, fx.keyB, 1),
      ),
    ),
  )
}

fn mixedActions() {
  [
    UpdateAction([fx.leafStep(fx.keyB, fx.terminalLeaf, fx.keyA)]),
    UpdateAction([fx.leafStep(fx.keyA, fx.activeLeaf, fx.keyB)]),
  ]
}

test mixed_batch_refuses_the_excluded_member() {
  let (root, tx) = mixedTransaction()
  let datum = Some(StateDatum(fx.stateOf(root)))
  !m1.state.spend(datum, Modify(mixedActions()), fx.stateRef, tx)
}
