//// The fold: one pass over the transaction's inputs that admits each request
//// of this registry and walks the trie (#157 C1–C5, C8; #183).
////
//// ## Responsibility
////
//// `mkAction` is the step `foldl` runs over the transaction's inputs, in
//// order. For each request of this registry it pops the next action, checks
//// the request's carriage (`tip-coverage`, `deposit-mismatch`), then either
//// books a rejected row's refund or admits an update: the phase, the edge tag
//// (`edge-inadmissible`), the approval (`admitted`) and the trie move with
//// its mint delta and duties (`applyEdge`). The `Fold` accumulator carries
//// the trie, the remaining actions, the consumed count, the minted delta, the
//// collected duties and the rejected rows' refunds.
////
//// ## Dependencies
////
//// Imports `registry/duty` (collecting duties), `registry/trie` (the trie's
//// refusals), `shared` (phase windows), `lib` (the edge table, approval name,
//// mint delta), `types` and the Merkle Patricia Forestry library. Imported by
//// `registry/modify`, which seeds the fold and judges its result. It checks nothing about outputs: that is the discharge owners'.
////
//// ## Assumptions
////
//// - The caller seeds `Fold` with the state's own root, its actions, zero
////   consumed, a zero mint and no duties or refunds, and folds the inputs in
////   transaction order.
//// - The caller refuses an empty fold and surplus actions, and compares the
////   final root and minted delta; this module does not.
////
//// ## Invariants
////
//// - `refusal` latches the first refusal's reason and every later step is
////   skipped, so one reason is reported however many rules the transaction
////   breaks.
//// - Only requests naming this registry's cage token are folded; any other
////   input passes through untouched.
//// - Every refusal raised here is checked before the library call that would
////   otherwise crash on the same fact: carriage before actions, the edge tag
////   before approval and proofs, trie faults before `mpf.insert` or
////   `mpf.update`. A wrong leaf that no named refusal covers still fails
////   inside the library, as a crash rather than a reason.
//// - The trie move and its leaf bytes come from the edge table, never from
////   request bytes; a read leaves the root exactly as it found it.

use aiken/collection/dict
use aiken/collection/list.{foldl}
use aiken/crypto.{VerificationKeyHash}
use aiken/merkle_patricia_forestry.{MerklePatriciaForestry}
use aiken/merkle_patricia_forestry as mpf
use cardano/assets
use cardano/assets.{PolicyId, Value, from_asset, lovelace_of}
use cardano/transaction.{InlineDatum, Input}
use lib.{
  approvalName, deltaOf, edgeDeleteAbsent, edgeDeleteActive, edgeInsertAbsent,
  edgeInsertActive, edgeUpdateActive, edgeUpdateTerminal, edgeWitnessTerminal,
  kindAbsent, kindActive, leafAbsent, leafActive, leafTerminal,
}
use registry/duty.{Duty, ReturnDeposit, dutiesOf, pushDuties, pushDuty}
use registry/trie.{readFault, terminalEdgeRefusal, terminalFault}
use shared.{in_phase1, is_rejectable}
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

/// The policy that mints a token of this kind, read off the pins's pins.
fn policyOfKind(pins: State, kind: Int) -> PolicyId {
  if kind == kindAbsent {
    pins.absent_policy
  } else if kind == kindActive {
    pins.active_policy
  } else {
    pins.terminal_policy
  }
}

/// Admission by approval (#157 C4, D-APPROVAL): the request's UTxO must
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
        request.destination,
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
/// `Request.edge`). The tag IS the edge: admitted `0..6` before approval
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
  let Request { requestOwner, requestKey, edge: tag, submitted_at, destination, deposit, .. } =
    request
  let held = lovelace_of(input.output.value)
  if held < pins.tip {
    // C8 (was the pinned consumer's R1): the cage checks carriage now.
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
          Rejected ->
            if !is_rejectable(
              validity_range,
              submitted_at,
              pins.process_time,
              pins.retract_time,
            ) {
              halt(popped, @"not-rejectable")
            } else {
              // Refund rows (NOTE-014 item A2 as corrected by NOTE-017):
              // only REJECTED rows are owed refunds, at `input − tip`.
              // Each is owed twice over: positionally (`refundFault`),
              // and with every other obligation to the owner's key
              // (`payeeFault`), so a refund output cannot also pay a
              // deposit or a custody refund of the same payee (#253).
              Fold {
                ..popped,
                refunds: [Pair(requestOwner, held - pins.tip), ..popped.refunds],
                duties: pushDuty(
                  popped.duties,
                  ReturnDeposit { owner: requestOwner, floor: held - pins.tip },
                ),
              }
            }
          UpdateAction(proof) ->
            if !in_phase1(validity_range, submitted_at, pins.process_time) {
              halt(popped, @"not-phase1")
            } else if tag < 0 || tag > edgeWitnessTerminal {
              // The tag is the whole shape: outside `0..6` there is no
              // edge to admit, approve, or walk.
              halt(popped, @"edge-inadmissible")
            } else {
              let checked =
                if tag == edgeWitnessTerminal {
                  // A read does not require an approval and does not check
                  // its absence (C4).
                  popped
                } else {
                  admitted(popped, pins, tag, request, input.output.value)
                }
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

/// Walk the trie one step and record what the edge owes (#157 C3, C5,
/// C6). The read is verified where it sits in the batch, against the
/// intermediate root, and leaves the leaf exactly as it found it.
fn applyEdge(
  acc: Fold,
  pins: State,
  edge: Int,
  owner: VerificationKeyHash,
  key: ByteArray,
  destination: (ByteArray, ByteArray),
  floor: Int,
  proof: mpf.Proof,
) -> Fold {
  // #173 A-006/A-009: an insert on a key the trie already binds is a
  // fault of the TRIE, refused `key-exists` BEFORE any mint arithmetic
  // runs.
  //
  // `mpf.miss` is the library's own TOTAL exclusion check, so an
  // occupied key is an attributable refusal instead of a crash inside
  // `mpf.insert` — and a crash says only that the script died, never
  // that it refused.
  let inserting =
    edge == lib.edgeInsertAbsent || edge == lib.edgeInsertActive
  // #177 I177-CHAIN: the same shape, one edge later. A retirement is a
  // fault of the TRIE when the leaf it names is not `Active`, and the
  // three ways that happens are the three reasons Lean gives. Read
  // BEFORE `mpf.update`, because `mpf.update` CRASHES on a leaf that is
  // not the one the edge moves — and a crash says only that the
  // script died, never which fact it refused for.
  //
  // #183 slice b: the leaf bytes come from the edge table in `types.ak`,
  // never from request bytes. A tree-changing edge on a terminal leaf
  // is refused `edge-from-terminal`: the terminal leaf admits the read
  // and nothing else (N10). Both trie faults answer the same question —
  // "is the leaf this edge needs the leaf the trie has?" — so they
  // share one decision and one halt, and the advance below runs only
  // when neither fires.
  when
    if edge == edgeUpdateTerminal {
      terminalFault(acc.trie, key, proof)
    } else if inserting && !mpf.miss(acc.trie, key, proof) {
      lib.occupiedRefusal()
    } else if edge == edgeWitnessTerminal && !mpf.has(acc.trie, key, leafTerminal, proof) {
      readFault(acc.trie, key, proof)
    } else if (edge == edgeUpdateActive || edge == edgeDeleteAbsent || edge == edgeDeleteActive) && mpf.has(
      acc.trie,
      key,
      leafTerminal,
      proof,
    ) {
      terminalEdgeRefusal()
    } else {
      None
    }
  is {
    Some(reason) -> halt(acc, reason)
    None -> {
  let advanced =
    if edge == edgeWitnessTerminal {
      // C3: no new proof code. `mpf.has` is the library's own inclusion
      // check and is total, so a proof against the wrong root is an
      // attributable refusal rather than a crash inside the library —
      // and `readFault` above has already run it and halted with the
      // fact when it answered false, so inclusion holds here (#183
      // slice b). The mandated `update(root, key, proof, v, v) == root`
      // then runs on the verified proof and must leave the root alone.
      let after = mpf.update(acc.trie, key, proof, leafTerminal, leafTerminal)
      if mpf.root(after) == mpf.root(acc.trie) {
        Some(acc.trie)
      } else {
        None
      }
    } else {
      // The trie move named by the edge, with the edge table's own leaf
      // bytes (`types.ak`): no value bytes travel with the request.
      Some(
        if edge == edgeInsertAbsent {
          mpf.insert(acc.trie, key, leafAbsent, proof)
        } else if edge == edgeInsertActive {
          mpf.insert(acc.trie, key, leafActive, proof)
        } else if edge == edgeUpdateActive {
          mpf.update(acc.trie, key, proof, leafAbsent, leafActive)
        } else if edge == edgeUpdateTerminal {
          mpf.update(acc.trie, key, proof, leafActive, leafTerminal)
        } else if edge == edgeDeleteAbsent {
          mpf.delete(acc.trie, key, leafAbsent, proof)
        } else {
          // `edgeDeleteActive`: admitted `0..6` above and the read is
          // handled in its own branch, so only edge 5 reaches here.
          mpf.delete(acc.trie, key, leafActive, proof)
        },
      )
    }
  when advanced is {
    None -> halt(acc, @"read-root")
    Some(trie) ->
      Fold {
        ..acc,
        trie,
        minted: foldl(
          deltaOf(edge),
          acc.minted,
          fn(entry, value) {
            let (kind, quantity) = entry
            assets.merge(value, from_asset(policyOfKind(pins, kind), key, quantity))
          },
        ),
        duties: pushDuties(
          acc.duties,
          dutiesOf(pins, edge, owner, key, destination, floor),
        ),
      }
  }
    }
  }
}
