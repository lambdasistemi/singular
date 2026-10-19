use aiken/collection/dict.{Dict, get, keys}
use booking.{applicationTagName, pureBurn}
use cardano/assets.{PolicyId, tokens}
use cardano/transaction.{Transaction}
use lib.{approvalName, edgeUpdateTerminal}
use types.{Approve, ApproveRegistration, OpenRedeemer}

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
/// the cage recomputes at fold time (approval-asset-binding) — so an approval cannot
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
      expect typed: OpenRedeemer = redeemer
      when typed is {
        Approve { edge, key, owner, destination } ->
          if edge == edgeUpdateTerminal {
            // The model has no application approval for a termination: the
            // booking is the application's spend plus the request policy's
            // mint, so this policy certifies no termination.
            trace @"approval-termination-retired"
            False
          } else if !isTreeEdge(edge) {
            // `witnessTerminal` (edge 6) needs no approval at all — the
            // model admits it unconditionally — so minting one would be a
            // token that certifies nothing. Edge 7 is not an edge.
            trace @"approval-edge"
            False
          } else {
            approves(moved, approvalName(edge, key, owner, destination))
          }
        // One registration booking: the name binds the key, the refund
        // address, the destination and the request's nonce (Lean
        // `applicationTagAssetName`).
        ApproveRegistration { key, refund_address, destination, nonce } ->
          approves(
            moved,
            applicationTagName(key, refund_address, destination, nonce),
          )
      }
    }
  }

  else(_) {
    fail
  }
}

/// The mint moves exactly one name, at quantity one, and it is the bound
/// name. Quantity is part of the binding: widening it would let a single
/// mint certify a batch, and two names are the same widening by another
/// route — one redeemer cannot bind two tuples.
fn approves(moved: Dict<ByteArray, Int>, expected: ByteArray) -> Bool {
  when keys(moved) is {
    [name] ->
      if get(moved, name) != Some(1) {
        trace @"approval-quantity"
        False
      } else if name != expected {
        trace @"approval-binding"
        False
      } else {
        True
      }
    _ -> {
      trace @"approval-quantity"
      False
    }
  }
}

/// The six TREE edges, the ones `admitsFor` requires an approval for.
/// `witnessTerminal` is deliberately outside: it is admitted without
/// one.
fn isTreeEdge(edge: Int) -> Bool {
  edge >= lib.edgeInsertAbsent && edge <= lib.edgeDeleteActive
}
