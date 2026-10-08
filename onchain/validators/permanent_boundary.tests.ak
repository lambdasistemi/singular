use aiken/cbor
use aiken/collection/list
use aiken/fuzz
use aiken/primitive/bytearray
use aiken/primitive/int
use aiken/primitive/string
use cardano/address
use cardano/assets.{from_asset, from_lovelace, merge, zero}
use cardano/script_context.{Minting, ScriptContext, Spending}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, Spend, Transaction,
}
use permanent_state as m1
use permanent_witness
use registry_fixtures as fx
use request
use state
use types.{Contribute, End, Modify, Rejected, StateDatum, UpdateAction}

/// Independently constructed complete folds, including a valid approval for
/// every tree-changing edge. Absent and terminal roots are component fixtures,
/// not evidence that M1 can reach those states. The broader validator must
/// accept each control before its bounded counterpart's refusal is credited.
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

test permanent_boundary(edge via fuzz.int_between(0, 6)) {
  let (root, tx) = edgeTransaction(edge)
  let actions = [UpdateAction([])]
  let datum = Some(StateDatum(fx.stateOf(root)))
  and {
    state.state.spend(datum, Modify(actions), fx.stateRef, tx),
    m1.state.spend(datum, Modify(actions), fx.stateRef, tx) == (
      edge == 1 || edge == 3
    ),
  }
}

test excluded_reason_before_approval_or_proof(edge via fuzz.int_between(0, 6)) {
  let (root, tx) = edgeTransaction(edge)
  if edge == 1 || edge == 3 {
    True
  } else {
    m1.modifyRefusal(
      fx.stateOf(root),
      [UpdateAction([])],
      fx.stateInput(root),
      tx,
    ) == Some(@"edge-inadmissible")
  }
}

test ownerless_end_stays_refused() fail {
  let (root, tx) = edgeTransaction(1)
  m1.state.spend(Some(StateDatum(fx.stateOf(root))), End, fx.stateRef, tx)
}

test excluded_request_can_still_be_rejected() {
  let root = fx.emptyRoot()
  let request =
    fx.requestInput(
      0,
      fx.keyA,
      6,
      fx.bookerKey,
      fx.readDestination(),
      zero,
      fx.requestLovelace,
    )
  let tx =
    fx.foldTx(
      root,
      root,
      [request],
      [],
      [fx.paymentOutput(fx.bookerAddress, fx.deposit)],
      zero,
    )
  m1.state.spend(
    Some(StateDatum(fx.stateOf(root))),
    Modify([Rejected]),
    fx.stateRef,
    tx,
  )
}

/// Fixture export only: the checker evaluates these contexts against the
/// blueprint's actual compiled bytes, separately from Aiken unit evaluation.
test export_compiled_contexts() {
  list.all(
    list.range(0, 6),
    fn(edge) {
      let (root, tx) = edgeTransaction(edge)
      let datum: Data = StateDatum(fx.stateOf(root))
      let redeemer: Data = Modify([UpdateAction([])])
      let context: Data =
        ScriptContext {
          transaction: tx,
          redeemer,
          info: Spending { output: fx.stateRef, datum: Some(datum) },
        }
      trace string.join(
        [
          @"M1-CONTEXT",
          int.to_string(edge),
          bytearray.to_hex(cbor.serialise(context)),
        ],
        @":",
      )
      True
    },
  )
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
  and {
    state.state.spend(datum, Modify(mixedActions()), fx.stateRef, tx),
    !m1.state.spend(datum, Modify(mixedActions()), fx.stateRef, tx),
  }
}

fn exportExtra(label: Int, root: ByteArray, tx: Transaction, redeemer: Data) {
  let datum: Data = StateDatum(fx.stateOf(root))
  let context: Data =
    ScriptContext {
      transaction: tx,
      redeemer,
      info: Spending { output: fx.stateRef, datum: Some(datum) },
    }
  trace string.join(
    [
      @"M1-EXTRA",
      int.to_string(label),
      bytearray.to_hex(cbor.serialise(context)),
    ],
    @":",
  )
  True
}

test export_mixed_and_malformed_contexts() {
  let (mixedRoot, mixed) = mixedTransaction()
  let (root, tx) = edgeTransaction(1)
  let mixedRedeemer: Data = Modify(mixedActions())
  let unknown: Data = 7
  let alternate: Data = Contribute(fx.stateRef)
  let end: Data = End
  let missing: Data = Modify([])
  let unknownEdge: Data = Modify([UpdateAction([])])
  let (unknownRoot, unknownTx) = edgeTransaction(7)
  let (negativeRoot, negativeTx) = edgeTransaction(-1)
  and {
    exportExtra(0, mixedRoot, mixed, mixedRedeemer),
    exportExtra(1, root, tx, unknown),
    exportExtra(2, root, tx, alternate),
    exportExtra(3, root, tx, end),
    exportExtra(4, root, tx, missing),
    exportExtra(5, unknownRoot, unknownTx, unknownEdge),
    exportExtra(6, negativeRoot, negativeTx, unknownEdge),
  }
}

/// Request and witness components are subordinate to the state's decision.
/// They intentionally admit co-present folds; the state must still refuse every
/// excluded edge. Policy IDs below are fixture pins, not a ledger claim.
test export_request_and_mint_routes() {
  list.all(
    list.range(0, 6),
    fn(edge) {
      let (root, original) = edgeTransaction(edge)
      let pin = permanent_witness.registryStateHash
      let state = fx.stateInput(root)
      let value =
        merge(
          from_lovelace(fx.stateLovelace),
          from_asset(pin, fx.cageTokenName(), 1),
        )
      let bound =
        Input {
          ..state,
          output: Output {
            ..state.output,
            address: address.from_script(pin),
            value,
          },
        }
      expect [_, ..others] = original.inputs
      expect [continuation, ..outputs] = original.outputs
      let modify: Data = Modify([UpdateAction([])])
      let tx =
        Transaction {
          ..original,
          inputs: [bound, ..others],
          outputs: [
            Output { ..continuation, address: address.from_script(pin), value },
            ..outputs
          ],
          redeemers: [Pair(Spend(fx.stateRef), modify)],
        }
      expect [pending, .._] = others
      expect InlineDatum(datum) = pending.output.datum
      expect requestDatum: types.CageDatum = datum
      let contribute: Data = Contribute(fx.stateRef)
      let context: Data =
        ScriptContext {
          transaction: tx,
          redeemer: contribute,
          info: Spending { output: fx.requestRef(0), datum: Some(datum) },
        }
      let statePolicy: Data = pin
      let token: Data = fx.cageTokenName()
      let requestBundle: Data = [statePolicy, token, context]
      trace string.join(
        [
          @"M1-REQUEST",
          int.to_string(edge),
          bytearray.to_hex(cbor.serialise(requestBundle)),
        ],
        @":",
      )
      let kind =
        if edge == 0 || edge == 2 || edge == 4 {
          0
        } else if edge == 6 {
          2
        } else {
          1
        }
      let policy =
        if kind == 0 {
          fx.absentPolicy
        } else if kind == 1 {
          fx.activePolicy
        } else {
          fx.terminalPolicy
        }
      let mintRedeemer: Data = #""
      let mintContext: Data =
        ScriptContext {
          transaction: tx,
          redeemer: mintRedeemer,
          info: Minting(policy),
        }
      let kindData: Data = kind
      let registryData: Data = bytearray.concat(pin, fx.cageTokenName())
      let mintBundle: Data = [kindData, registryData, mintContext]
      trace string.join(
        [
          @"M1-MINT",
          int.to_string(edge),
          bytearray.to_hex(cbor.serialise(mintBundle)),
        ],
        @":",
      )
      // Complete state-spend component on the same transaction.
      let stateDatum: Data = StateDatum(fx.stateOf(root))
      let stateContext: Data =
        ScriptContext {
          transaction: tx,
          redeemer: modify,
          info: Spending { output: fx.stateRef, datum: Some(stateDatum) },
        }
      trace string.join(
        [
          @"M1-JOINED",
          int.to_string(edge),
          bytearray.to_hex(cbor.serialise(stateContext)),
        ],
        @":",
      )
      and {
        request.request.spend(
          pin,
          fx.cageTokenName(),
          Some(requestDatum),
          Contribute(fx.stateRef),
          fx.requestRef(0),
          tx,
        ),
        permanent_witness.witness.mint(
          kind,
          bytearray.concat(pin, fx.cageTokenName()),
          mintRedeemer,
          policy,
          tx,
        ),
        m1.state.spend(
          Some(StateDatum(fx.stateOf(root))),
          Modify([UpdateAction([])]),
          fx.stateRef,
          tx,
        ) == ( edge == 1 || edge == 3 ),
      }
    },
  )
}
