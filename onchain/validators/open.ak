use aiken/collection/dict
use aiken/collection/dict.{get, keys}
use cardano/assets.{PolicyId, tokens}
use cardano/transaction.{Transaction}
use lib
use lib.{approvalName}
use types.{Approve, OpenRedeemer}

/// The open application (#173 I1, A-001 row 1).
///
/// **Parameterless by design.** The open registry is the application
/// that protects nobody: anyone may mint a fresh approval for any
/// `(edge, key, owner, destination)` at any time. So there is no
/// registry identity to apply the policy to — one policy id, one
/// blueprint, no applied hash to derive, and the compiled hash of this
/// validator IS the policy the registry pins.
///
/// Cross-registry separation is a **named non-goal**, not an omission.
/// Replaying an approval into a second registry that pins this same
/// policy grants nothing that registry did not already grant everyone,
/// because everyone could mint the same approval there directly.
/// Separation is a property of an application WITH authorization; this
/// one has none, and promising it here would be an invented requirement.
///
/// What the policy does decide is the **binding**. The asset name is
/// `lib.approvalName` over the whole scoping tuple — the same function
/// the cage recomputes at fold time (D-APPROVAL) — so an approval cannot
/// be pointed at a request it was not minted for. Nothing else about the
/// transaction is this policy's business: the cage decides how many
/// tokens move and where they go.
validator open {
  mint(redeemer: Data, policy_id: PolicyId, tx: Transaction) {
    let moved = tokens(tx.mint, policy_id)
    if pureBurn(moved) {
      // An approval is EVIDENCE, never a consumable: the fold burns
      // nothing and reads nothing back. Destroying your own copy
      // therefore costs the registry nothing, so it needs no redeemer
      // and no binding.
      True
    } else {
      expect Approve { edge, key, owner, destination }: OpenRedeemer = redeemer
      if !isTreeEdge(edge) {
        // `witnessTerminal` (edge 6) needs no approval at all — the
        // model admits it unconditionally — so minting one would be a
        // token that certifies nothing. Edge 7 is not an edge.
        trace @"approval-edge"
        False
      } else {
        when keys(moved) is {
          [name] ->
            if get(moved, name) != Some(1) {
              // Quantity is part of the binding: one approval certifies
              // the ONE request it names. Widening it would let a single
              // mint certify a batch.
              trace @"approval-quantity"
              False
            } else if name != approvalName(edge, key, owner, destination) {
              trace @"approval-binding"
              False
            } else {
              True
            }
          // Zero names is nothing to admit; two or more is the same
          // widening by another route — one redeemer cannot bind two
          // tuples.
          _ -> {
            trace @"approval-quantity"
            False
          }
        }
      }
    }
  }

  else(_) {
    fail
  }
}

/// The six TREE edges, the ones `admitsFor` requires an approval for.
/// `witnessTerminal` is deliberately outside: it is admitted without
/// one.
fn isTreeEdge(edge: Int) -> Bool {
  edge >= lib.edgeInsertAbsent && edge <= lib.edgeDeleteActive
}

/// Every movement under this policy in this transaction is a burn, and
/// there is at least one. A mint hiding beside a burn is not a pure
/// burn and is held to the binding rule like any other mint.
fn pureBurn(moved: dict.Dict<ByteArray, Int>) -> Bool {
  when keys(moved) is {
    [] -> False
    names -> allBurns(moved, names)
  }
}

fn allBurns(moved: dict.Dict<ByteArray, Int>, names: List<ByteArray>) -> Bool {
  when names is {
    [] -> True
    [name, ..rest] ->
      when get(moved, name) is {
        Some(quantity) -> quantity < 0 && allBurns(moved, rest)
        None -> False
      }
  }
}
