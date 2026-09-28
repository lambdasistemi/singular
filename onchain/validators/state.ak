use aiken/collection/dict
use aiken/collection/pairs
use aiken/collection/list
use aiken/collection/list.{filter, find, foldl, head}
use aiken/crypto.{VerificationKeyHash}
use aiken/merkle_patricia_forestry.{MerklePatriciaForestry, empty, root}
use aiken/merkle_patricia_forestry as mpf
use aiken/option.{is_some}
use cardano/address
use cardano/address.{Address, PaymentCredential}
use cardano/assets
use cardano/assets.{PolicyId, Value, from_asset, lovelace_of, quantity_of}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, find_input,
}
use lib.{
  approvalName, assetName, deltaOf, destinationMatches,
  edgeDeleteAbsent, edgeDeleteActive, edgeInsertAbsent, edgeInsertActive,
  edgeUpdateActive, edgeUpdateTerminal, edgeWitnessTerminal, exactQuantity,
  kindAbsent, kindActive, leafAbsent, leafActive, leafTerminal,
  tokenFromPolicy,
}
use registry/custody.{validCustodySpend}
use registry/discharge.{dutiesFault}
use registry/duty.{
  Duty, ReturnDeposit, dutiesOf, pushDuties, pushDuty,
}
use registry/refusal.{refundShort, traceFalse}
use registry/settlement.{
  custodyFault, custodyOwedOf, payeeFault, payeeOwed, refundFault, settlesOf,
}
use shared.{in_phase1, is_rejectable}
use types.{
  AbsentCustody, Burning, CageDatum, End, Migrating,
  MintRedeemer, Minting, Modify, Rejected, Request,
  RequestAction, RequestDatum, State, StateDatum, TokenId,
  UpdateAction, UpdateRedeemer,
}

// ============================================================================
// The cage, in registry mode (#157)
// ============================================================================
//
// The cage IS the registry. There is no pinned consumer script and no
// mandatory withdrawal: every rule the application used to re-walk beside
// the fold is checked here, once, from the transaction's own evidence.
//
// What a `Modify` must satisfy:
//
// - **C1/C2 admissibility** — the request's tag is one of the seven C2
//   edges (`0..6`), admitted before approval and before any proof is
//   checked; anything else refuses `edge-inadmissible`. The trie move
//   and its leaf bytes come from the edge table, never from request bytes.
// - **C3 the read** — edge 6 is verified with the existing verifier
//   at its own position in the batch, so its proof is checked against the
//   intermediate root there. The leaf is unchanged.
// - **C4 admission** — a request whose edge changes the trie is
//   folded only if its UTxO carries exactly one asset under the pins's
//   `application_policy` whose asset name is the approval binding of that
//   request. No application script runs at fold time; the cage recomputes
//   the name rather than trusting it. A read carries none and needs none.
// - **C5 the delta** — the cage sums the token column of C2 over the
//   requests it consumed, per key, and the transaction's mint under the
//   three pinned token policies must equal that sum exactly. Nothing else
//   may move under them.
// - **C6 destinations** — each minted active or terminal token lands in
//   exactly one output, the one its request named, carrying the datum it
//   named and at least the request's value minus the tip. An absent token
//   lands in the cage's own custody beside the inserter's refund address;
//   a consumed absent token pays that address back. An edge that delivers
//   no token (3, 4, 5) and a rejected row pay the request's deposit to
//   `requestOwner`'s key. Every lovelace obligation of a fold is settled
//   once per payee, on the summed lovelace of the outputs paying it (#253).
// - **C7 the pins** — the seven non-root fields are equal before and
//   after every fold.
// - **C8 coverage** — every consumed request carries at least its tip.
//
// Every refusal this file names RETURNS FALSE after emitting exactly one
// user-defined trace, rather than crashing: a script that dies inside a
// library cannot tell anyone why, and each row of Gate S is bound to the
// single trace its refusal emits.

// Ownerless registry (operator ruling NOTE-028/A-003, issue #77 repair):
// the pins validator takes no parameters. The former `previousPolicies`
// migration allowlist is gone with migration itself.
validator state() {
  mint(redeemer: MintRedeemer, policyId: PolicyId, tx: Transaction) {
    when redeemer is {
      Minting(seed) -> validateMint(seed, policyId, tx)
      // Ownerless registry (operator ruling NOTE-028/A-003, issue #77
      // repair): migration and burning destroy or re-policy the registry
      // with no ownerless justification. Both refuse for every party;
      // the constructors stay for the wire shape.
      Migrating(_) -> fail
      Burning(_) -> fail
    }
  }

  spend(
    maybeDatum: Option<CageDatum>,
    redeemer: UpdateRedeemer,
    self: OutputReference,
    tx: Transaction,
  ) {
    expect Some(datum) = maybeDatum
    expect Some(input) = find(tx.inputs, fn(i) { i.output_reference == self })
    when datum is {
      // The cage's own custody of an absent token (#157 D-CUSTODY): one
      // spending path and nothing else. The redeemer is not what
      // authorizes it — the shape of the fold around it is.
      AbsentCustody { refund } -> validCustodySpend(refund, input, tx)
      StateDatum(pins) -> {
        let (policyId, cageToken) = stateIdentity(input)
        when redeemer is {
          // Permissionless fold (issue #79, Defect 1): `Modify` requires
          // no owner — there is no registry-owner role (operator ruling
          // NOTE-028/A-003).
          Modify(actions) ->
            when validModify(pins, input, policyId, cageToken, tx, actions) is {
              None -> True
              Some(reason) -> traceFalse(reason)
            }
          // Ownerless registry: termination is refused for every party.
          // The constructor stays for the wire shape.
          End -> fail
          _ -> fail
        }
      }
      _ -> fail
    }
  }

  else(_) {
    fail
  }
}

// ----------------------------------------------------------------------------
// The fold
// ----------------------------------------------------------------------------

/// The fold's accumulator. `refusal` latches the first refusal's reason
/// and every later step is skipped, so exactly one reason is reported
/// however many later rules the same transaction would also break.
type Fold {
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
fn mkAction(pins: State, tokenId: TokenId, validity_range) {
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
                  // A read carries no approval and needs none (C4).
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

// ----------------------------------------------------------------------------
// What the trie refuses
// ----------------------------------------------------------------------------

/// Why the trie refuses this `updateTerminal`, or `None` when the leaf
/// it binds is the `Active` one the edge moves (#177 I177-CHAIN).
///
/// The subject is the leaf the trie ACTUALLY binds — established here,
/// against this request's own proof, with the MPF library's own TOTAL
/// checks. `miss` and `has` answer for every input instead of crashing,
/// so a wrong leaf becomes an attributable refusal rather than a death
/// inside `mpf.update`, which says only that the script died.
///
/// It is NOT a leaf the request states — edge-only requests state none:
/// a claim by the requester says nothing about the trie.
///
/// One construction site, so a test asserting a reason asserts the
/// value this validator traces rather than a helper nothing calls
/// (#173 A-006, applied to this edge). The names are Lean's, from
/// `update_terminal_transaction_row`.
///
/// `None` is the residue, and it is also where an INVALID proof lands:
/// a proof matching no root matches none of the three checks either.
/// That case then dies in `mpf.update` exactly as it does on every
/// other edge. The three leaves Lean names are what this classifies.
pub fn terminalFault(
  trie: MerklePatriciaForestry,
  key: ByteArray,
  proof: mpf.Proof,
) -> Option<String> {
  if mpf.miss(trie, key, proof) {
    Some(@"key-unknown")
  } else if mpf.has(trie, key, leafAbsent, proof) {
    Some(@"not-booked")
  } else if mpf.has(trie, key, leafTerminal, proof) {
    Some(@"terminal-immutable")
  } else {
    None
  }
}

/// The reason a tree-changing edge whose key binds `Terminal` is refused
/// (#183 slice b, N10). The terminal leaf admits the read and nothing
/// else, and the fault is one of the TRIE: the request states no bytes
/// to be wrong about.
///
/// Own site, so a test asserting the reason asserts the value the cage
/// traces rather than a string a helper nobody calls happens to hold
/// (A-006 pattern, as `occupiedRefusal`).
pub fn terminalEdgeRefusal() -> Option<String> {
  Some(@"edge-from-terminal")
}

/// Why a read whose key does NOT bind `Terminal` refuses (#183 slice b, M3). The read carries no value
/// byte, so the fault is read off the TRIE against the action's own
/// proof, with the MPF library's own TOTAL checks: a terminal leaf
/// proceeds (verified by the caller), anything else names its fact.
/// A key the trie does not bind at all is `key-unknown` — neither
/// `read-absent` (bound `Absent`) nor `read-non-terminal` (bound live).
///
/// Own site, so a test asserting a reason asserts the value the cage
/// traces (A-006 pattern).
pub fn readFault(
  trie: MerklePatriciaForestry,
  key: ByteArray,
  proof: mpf.Proof,
) -> Option<String> {
  if mpf.has(trie, key, leafAbsent, proof) {
    Some(@"read-absent")
  } else if mpf.has(trie, key, leafActive, proof) {
    Some(@"read-non-terminal")
  } else {
    Some(@"key-unknown")
  }
}

// ----------------------------------------------------------------------------
// `Modify`
// ----------------------------------------------------------------------------

/// The script and cage token of a state input: the one state token, at
/// quantity one, under the policy of the script that holds it.
fn stateIdentity(input: Input) -> (PolicyId, TokenId) {
  expect address.Script(policyId) = input.output.address.payment_credential
  expect Some(cageToken) = tokenFromPolicy(policyId, input.output.value)
  expect exactQuantity(policyId, input.output.value, cageToken, 1)
  (policyId, cageToken)
}

/// Why the cage refuses this `Modify` of the state `input` carrying
/// `pins`, or `None` when it folds. The spend handler traces exactly this
/// reason and returns False, so a test asserting it asserts the one trace
/// the whole transaction emits — not merely that it was refused.
pub fn modifyRefusal(
  pins: State,
  actions: List<RequestAction>,
  input: Input,
  tx: Transaction,
) -> Option<String> {
  let (policyId, cageToken) = stateIdentity(input)
  validModify(pins, input, policyId, cageToken, tx, actions)
}

fn validModify(
  pins: State,
  input: Input,
  policyId: PolicyId,
  tokenId: TokenId,
  tx: Transaction,
  actions: List<RequestAction>,
) -> Option<String> {
  let Transaction { outputs, inputs, validity_range, mint, .. } = tx
  expect Some(output) = head(outputs)
  expect InlineDatum(outState) = output.datum
  expect StateDatum(next) = outState
  if output.address.payment_credential != input.output.address.payment_credential {
    // The continuation is the cage's own UTxO, at the cage's own
    // address: a fold that hands the registry to another script is not a
    // fold. Checked before anything the batch says, because everything
    // after it is about a state that would not be the registry's.
    Some(@"continuation-address")
  } else if !exactQuantity(policyId, output.value, tokenId, 1) {
    Some(@"state-token")
  } else if lovelace_of(output.value) < lovelace_of(input.output.value) {
    // No-drain rule (NOTE-017): the state UTxO's own lovelace may not
    // fall. Processed value routes to the destinations below; ledger
    // conservation plus the rejected-row floors close the rest.
    Some(@"state-drain")
  } else if !pinsPreserved(pins, next) {
    // C7: the seven non-root fields are registry configuration — genesis
    // sets them, every fold preserves them. A fold altering any of them
    // refuses here, before any root, delta or destination check.
    Some(@"pins-altered")
  } else {
    let folded =
      foldl(
        inputs,
        Fold {
          refusal: None,
          trie: mpf.from_root(pins.root),
          actions,
          consumed: 0,
          minted: assets.zero,
          duties: [],
          refunds: [],
        },
        mkAction(pins, tokenId, validity_range),
      )
    if folded.refusal != None {
      folded.refusal
    } else if folded.consumed <= 0 {
      // Exact request/action pairing (NOTE-020, A001/root 071): empty
      // processing refuses — no matching request consumed, no batch.
      Some(@"empty-fold")
    } else if folded.actions != [] {
      // Surplus unconsumed actions refuse: every supplied action must
      // pair with an actual matching request, and missing actions
      // already refused at `missing-action`.
      Some(@"surplus-actions")
    } else if mpf.root(folded.trie) != next.root {
      Some(@"root")
    } else if !mintMatches(pins, folded.minted, mint) {
      // C5: the transaction's mint under the three pinned token policies
      // equals the summed C2 column exactly — asset by asset, quantity
      // by quantity — and nothing else moves under them. A mint that
      // adds, omits, doubles or renames one asset is one delta mismatch.
      //
      // The NAME of that refusal comes from `lib.mintRefusal`, the one
      // construction site, so a test asserting the reason asserts the
      // value this validator actually traces (#173 A-006).
      lib.mintRefusal()
    } else {
      // `outputs` is non-empty: its head is the continuation read above.
      expect [_, ..refundOutputs] = outputs
      let cageAddress = input.output.address
      when dutiesFault(pins, cageAddress, folded.duties, tx) is {
        None ->
          when custodyOwedOf(pins, cageAddress, folded.duties, inputs) is {
            None -> refundShort()
            Some(custodyOwed) -> {
              let owed = payeeOwed(folded.duties, custodyOwed)
              if custodyOwed == [] && owed == [] {
                // A fold that owes no lovelace settles nothing.
                None
              } else {
                let settles =
                  settlesOf(cageAddress.payment_credential, folded.duties)
                when custodyFault(outputs, settles, custodyOwed) is {
                  None ->
                    when refundFault(refundOutputs, list.reverse(folded.refunds)) is {
                      None -> payeeFault(outputs, settles, owed)
                      refusal -> refusal
                    }
                  refusal -> refusal
                }
              }
            }
          }
        refusal -> refusal
      }
    }
  }
}

/// C7: every field but the root survives the fold unchanged.
fn pinsPreserved(before: State, after: State) -> Bool {
  and {
    before.tip == after.tip,
    before.process_time == after.process_time,
    before.retract_time == after.retract_time,
    before.application_policy == after.application_policy,
    before.active_policy == after.active_policy,
    before.absent_policy == after.absent_policy,
    before.terminal_policy == after.terminal_policy,
  }
}

/// C5: the mint under each of the three pinned token policies equals the
/// summed delta exactly. Both sides are compared as the ledger's own
/// normalized token maps, so a zero net movement must be absent rather
/// than present-at-zero.
fn mintMatches(pins: State, expected: Value, mint: Value) -> Bool {
  and {
    assets.tokens(expected, pins.absent_policy) == assets.tokens(
      mint,
      pins.absent_policy,
    ),
    assets.tokens(expected, pins.active_policy) == assets.tokens(
      mint,
      pins.active_policy,
    ),
    assets.tokens(expected, pins.terminal_policy) == assets.tokens(
      mint,
      pins.terminal_policy,
    ),
  }
}

// ----------------------------------------------------------------------------
// Genesis
// ----------------------------------------------------------------------------

/// Genesis (#157 C7): the four policies are set here and preserved by
/// every fold. Boot is permissionless — there is no owner — so the mint
/// authorizes no particular choice of them; preservation is what gives
/// them their force, not mint-time approval. The consumer pin and its
/// width check are gone with `consumer.ak`.
pub fn validateMint(seed: OutputReference, policyId: PolicyId, tx: Transaction) {
  let Transaction { outputs, mint, inputs, .. } = tx
  let tokenId = TokenId { assetName: assetName(seed) }
  expect is_some(find_input(inputs, seed))
  expect exactQuantity(policyId, mint, tokenId, 1)
  expect Some(output) = head(outputs)
  expect address.Script(targetScriptHash) = output.address.payment_credential
  expect targetScriptHash == policyId
  expect InlineDatum(tokenState) = output.datum
  expect StateDatum(State { root: tokenRoot, .. }) = tokenState
  expect tokenRoot == root(empty)
  expect exactQuantity(policyId, output.value, tokenId, 1)
  True
}

// #183 slice b: `insertEdgeOf` is gone with the `Operation` wire —
// an insert names its edge in the request's own tag.
