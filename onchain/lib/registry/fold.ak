//// ## Responsibility
//// Fold permanent M1 registration and termination requests in input order.
////
//// ## Dependencies
//// Reuses the original approval binding, trie fault, duty and refund owners.
//// Imported by registry/modify, the single active fold implementation.
////
//// ## Assumptions
//// The caller checks state continuation, fixed pins, net mint and settlement.
//// Requests carry their own public datum and per-request proof.
////
//// ## Invariants
//// Only insertActive and updateTerminal advance the trie; no dispatch exists
//// for the excluded edges. Rejected requests retain original refund obligations.
//// The first refusal latches and successful actions advance the intermediate root.

use aiken/collection/dict
use aiken/collection/list.{foldl}
use aiken/crypto.{VerificationKeyHash}
use aiken/merkle_patricia_forestry.{MerklePatriciaForestry}
use aiken/merkle_patricia_forestry as mpf
use cardano/assets.{PolicyId, Value, from_asset, lovelace_of}
use cardano/transaction.{InlineDatum, Input}
use lib.{
  approvalDestination, approvalName, edgeInsertActive, edgeUpdateTerminal,
  leafActive, leafTerminal,
}
use registry/duty.{Duty, ReturnDeposit, dutiesOf, pushDuties, pushDuty}
use registry/trie.{terminalFault}
use shared.{in_phase1}
use types.{
  CageDatum, Rejected, Request, RequestAction, RequestDatum, State, TokenId,
  UpdateAction,
}

/// The fold's accumulator. `refusal` latches the first refusal's reason
/// and every later step is skipped, so exactly one reason is reported
/// however many later rules the same transaction would also break.
pub type Fold {
  refusal: Option<String>,
  trie: MerklePatriciaForestry,
  actions: List<RequestAction>,
  consumed: Int,
  minted: Value,
  duties: List<Duty>,
  refunds: List<Pair<VerificationKeyHash, Int>>,
}

/// Latch the fold closed on this refusal's reason.
fn halt(acc: Fold, reason: String) -> Fold {
  Fold { ..acc, refusal: Some(reason) }
}

/// Admission by approval (#157 tree-edge-admission-by-approval, approval-asset-binding): the request's UTxO must
/// carry exactly one asset under the pins's application policy, at
/// quantity 1, whose asset name is the approval binding of THIS request.
/// The cage recomputes the name; a folder cannot substitute another
/// owner's, another key's, another edge's or another destination's
/// approval. The approval is not burned — no application script runs
/// here — and leaves with the request's residual value.
fn admitted(
  acc: Fold,
  pins: State,
  edge: Int,
  request: Request,
  value: Value,
) -> Fold {
  let carried = assets.tokens(value, pins.application_policy)
  when dict.keys(carried) is {
    [name] ->
      if dict.get(carried, name) != Some(1) {
        halt(acc, @"no-approval")
      } else if name != approvalName(
        edge,
        request.requestKey,
        request.requestOwner,
        approvalDestination(request.destination),
      ) {
        halt(acc, @"approval-binding")
      } else {
        acc
      }
    _ -> halt(acc, @"no-approval")
  }
}

/// One step of the fold, over the transaction's own inputs in order.
pub fn mkAction(pins: State, tokenId: TokenId, validity_range) {
  fn(input: Input, acc: Fold) -> Fold {
    if acc.refusal != None {
      acc
    } else {
      when input.output.datum is {
        InlineDatum(datum) ->
          if datum is RequestDatum(request): CageDatum {
            // #183 slice b: the edge-only request is the only request.
            // The dual-codec checkpoint stands in history (reviews 002–005).
            if request.requestToken == tokenId {
              stepRequest(acc, pins, request, input, validity_range)
            } else {
              // A request for another cage token is not ours to fold.
              acc
            }
          } else {
            acc
          }
        _ -> acc
      }
    }
  }
}

/// One step of the fold over an edge-only request (#183 slice b, Lean
/// `Request.edge`). The tag IS the edge: only tags 1 and 3 pass before approval
/// and before any proof, then the same admission and MPF walk every edge
/// takes. No `tip` field (`tip-mismatch` retired): `held >= state.tip`
/// (`tip-coverage`) plus `deposit == held - state.tip` (`deposit-mismatch`).
fn stepRequest(
  acc: Fold,
  pins: State,
  request: Request,
  input: Input,
  validity_range,
) -> Fold {
  let Request {
    requestOwner,
    requestKey,
    edge: tag,
    submitted_at,
    destination,
    deposit,
    ..
  } = request
  let held = lovelace_of(input.output.value)
  if held < pins.tip {
    // request-covers-tip (was the pinned consumer's R1): the cage checks carriage now.
    // Costless fabricated requests would otherwise fold for free —
    // trie spam at zero price.
    halt(acc, @"tip-coverage")
  } else if deposit != held - pins.tip {
    halt(acc, @"deposit-mismatch")
  } else {
    when acc.actions is {
      [] -> halt(acc, @"missing-action")
      [action, ..tail] -> {
        let popped = Fold { ..acc, actions: tail, consumed: acc.consumed + 1 }
        when action is {
          // A reject carries no admission, in any window (Lean
          // `exitAdmission .reject = none`, #320): it reads no time.
          // Refund rows (NOTE-014 item A2 as corrected by NOTE-017): only
          // REJECTED rows are owed refunds, at `input − tip`. Each is owed
          // twice over: positionally (`refundFault`), and with every other
          // obligation to the owner's key (`payeeFault`), so a refund output
          // cannot also pay a deposit or a custody refund of the same payee
          // (#253).
          Rejected ->
            Fold {
              ..popped,
              refunds: [Pair(requestOwner, held - pins.tip), ..popped.refunds],
              duties: pushDuty(
                popped.duties,
                ReturnDeposit { owner: requestOwner, floor: held - pins.tip },
              ),
            }
          // An update is folded in the processing window only: current
          // validator behaviour, with no counterpart in Lean.
          UpdateAction(proof) ->
            if !in_phase1(validity_range, submitted_at, pins.process_time) {
              halt(popped, @"not-phase1")
            } else if tag != edgeInsertActive && tag != edgeUpdateTerminal {
              // A fixed admission set: only registration and termination.
              halt(popped, @"edge-inadmissible")
            } else {
              let checked =
                admitted(popped, pins, tag, request, input.output.value)
              if checked.refusal != None {
                checked
              } else {
                applyEdge(
                  checked,
                  pins,
                  tag,
                  requestOwner,
                  requestKey,
                  destination,
                  held - pins.tip,
                  proof,
                )
              }
            }
        }
      }
    }
  }
}

/// Apply only the two M1 trie transitions. No absent, delete or read code is
/// reachable through this dispatch, even after a caller supplies arbitrary tags.
fn applyEdge(
  acc: Fold,
  pins: State,
  edge: Int,
  owner: VerificationKeyHash,
  key: ByteArray,
  destination: (ByteArray, Option<Data>),
  floor: Int,
  proof: mpf.Proof,
) -> Fold {
  let inserting = edge == edgeInsertActive
  let fault =
    if inserting && !mpf.miss(acc.trie, key, proof) {
      lib.occupiedRefusal()
    } else if !inserting {
      terminalFault(acc.trie, key, proof)
    } else {
      None
    }
  when fault is {
    Some(reason) -> halt(acc, reason)
    None ->
      Fold {
        ..acc,
        trie: if inserting {
          mpf.insert(acc.trie, key, leafActive, proof)
        } else {
          mpf.update(acc.trie, key, proof, leafActive, leafTerminal)
        },
        minted: assets.merge(
          acc.minted,
          from_asset(
            pins.active_policy,
            key,
            if inserting {
              1
            } else {
              -1
            },
          ),
        ),
        duties: pushDuties(
          acc.duties,
          dutiesOf(pins, edge, owner, key, destination, floor),
        ),
      }
  }
}
