use aiken/collection/dict.{Dict, get, keys}
use booking.{applicationTagName, pureBurn}
use cardano/assets.{PolicyId, tokens}
use cardano/transaction.{Transaction}
use lib.{edgeUpdateTerminal}
use types.{Approve, ApproveRegistration, OpenRedeemer}

/// The open application (#173 I1, A-001 row 1).
///
/// **Parameterless by design.** The open registry is the application
/// that protects nobody: anyone may mint a fresh application tag for any
/// registration at any time. So there is no registry identity to apply the
/// policy to — one policy id, one blueprint, no applied hash to derive, and
/// the compiled hash of this validator IS the policy the registry pins.
///
/// Cross-registry separation is a **named non-goal**, not an omission.
/// Replaying a tag into a second registry that pins this same policy grants
/// nothing that registry did not already grant everyone, because everyone
/// could mint the same tag there directly. Separation is a property of an
/// application WITH authorization; this one has none, and promising it here
/// would be an invented requirement.
///
/// What the policy does decide is the **binding** of a registration booking:
/// the asset name is `booking.applicationTagName` over the request's key,
/// refund address, destination and nonce — the same function the request
/// policy's booking judgement recomputes — so a tag cannot be pointed at a
/// request it was not minted for. Nothing else about the transaction is this
/// policy's business: the request policy judges the booking and the fold
/// burns the tag.
///
/// **Retired.** The edge-numbered `Approve` of the old fold admitted a legacy
/// edge-only request that no fold consumes any more. The constructor stays for
/// the wire shape and is refused for every edge (`approval-retired`; the
/// termination edge keeps its own name, `approval-termination-retired`, since
/// a termination is booked by the application's spend and the request policy's
/// mint, not by an approval).
validator open {
  mint(redeemer: Data, policy_id: PolicyId, tx: Transaction) {
    let moved = tokens(tx.mint, policy_id)
    if pureBurn(moved) {
      // A tag is EVIDENCE, never a consumable to protect: the fold burns the
      // tag of every registration it folds under this policy (the burn needs
      // no redeemer and no binding), and destroying your own copy costs the
      // registry nothing.
      True
    } else {
      expect typed: OpenRedeemer = redeemer
      when typed is {
        Approve { edge, .. } ->
          if edge == edgeUpdateTerminal {
            trace @"approval-termination-retired"
            False
          } else {
            trace @"approval-retired"
            False
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
