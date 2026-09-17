use aiken/collection/dict
use aiken/collection/pairs
use aiken/collection/list
use aiken/collection/list.{filter, find, foldl, head}
use aiken/crypto.{VerificationKeyHash}
use aiken/merkle_patricia_forestry.{MerklePatriciaForestry, empty, root}
use aiken/merkle_patricia_forestry as mpf
use aiken/option.{is_some}
use cardano/address
use cardano/address.{Address}
use cardano/assets
use cardano/assets.{PolicyId, Value, from_asset, lovelace_of, quantity_of}
use cardano/transaction.{
  Spend,
  Datum, InlineDatum, Input, Output, OutputReference, Transaction, find_input,
}
use lib.{
  approvalName, assetName, decodeState, deltaOf, destinationMatches,
  edgeDeleteAbsent, edgeInsertAbsent, edgeInsertActive, edgeOf,
  edgeUpdateActive, edgeUpdateTerminal, edgeWitnessTerminal, exactQuantity,
  kindAbsent, kindActive, kindTerminal, leafTerminal, paysAddress,
  statedBefore, tokenFromPolicy,
}
use shared.{in_phase1, is_rejectable}
use types.{
  AbsentCustody, Burning, CageDatum, Delete, End, Insert, Migrating,
  MintRedeemer, Minting, Modify, Operation, Read, Rejected, Request,
  RequestAction, RequestDatum, State, StateDatum, TokenId, Update,
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
// - **C1/C2 admissibility** — the value of every known leaf is one codec
//   byte, and only the seven `(operation, before-leaf)` rows change or
//   read the trie. Every other shape refuses with its own trace, before
//   any proof is checked.
// - **C3 the read** — `Read(0x02)` is verified with the existing verifier
//   at its own position in the batch, so its proof is checked against the
//   intermediate root there. The leaf is unchanged.
// - **C4 admission** — a request whose operation changes the trie is
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
//   a consumed absent token pays that address back.
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
      AbsentCustody { key, refund } ->
        validCustodySpend(key, refund, input, tx)
      StateDatum(pins) -> {
        expect address.Script(policyId) =
          input.output.address.payment_credential
        expect Some(cageToken) = tokenFromPolicy(policyId, input.output.value)
        expect exactQuantity(policyId, input.output.value, cageToken, 1)
        when redeemer is {
          // Permissionless fold (issue #79, Defect 1): `Modify` requires
          // no owner — there is no registry-owner role (operator ruling
          // NOTE-028/A-003).
          Modify(actions) ->
            validModify(pins, input, policyId, cageToken, tx, actions)
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

/// What one consumed request still owes the transaction once its edge is
/// admitted (#157 C6). Collected during the fold, discharged after it, so
/// the trie walk and the value walk stay separate and each names its own
/// reason.
type Duty {
  /// A minted active or terminal token must land in exactly one output,
  /// the one the request named, holding at least `floor` lovelace.
  ///
  /// Two requests in one batch can mint the same `(policy, key)` — two
  /// reads of one terminal name — and one asset cannot be in two
  /// outputs at once, so their duties MERGE rather than stack: `count`
  /// is how many tokens the single carrier must hold and `floor` the SUM
  /// of the deposits it owes, so a folder cannot return one deposit and
  /// pocket the other. `agreed` is false when the merged requests named
  /// different destinations, which no single output can satisfy.
  DeliverToken {
    policy: PolicyId,
    key: ByteArray,
    destination: (ByteArray, ByteArray),
    floor: Int,
    count: Int,
    agreed: Bool,
  }
  /// A minted absent token must land in the cage's own custody, beside
  /// its key and the refund address the request named.
  LockCustody { key: ByteArray, refund: ByteArray, floor: Int }
  /// A consumed absent token's custody UTxO must be spent here, and its
  /// lovelace paid to the address that custody recorded.
  SpendCustody { key: ByteArray }
  /// A burned active token must actually be an input; the cage does not
  /// care where it came from — the application's custody does.
  BurnFromInput { policy: PolicyId, key: ByteArray }
}

/// The fold's accumulator. `ok` latches false on the first refusal and
/// every later step is skipped, so exactly one trace is emitted however
/// many later rules the same transaction would also break.
type Fold {
  ok: Bool,
  trie: MerklePatriciaForestry,
  actions: List<RequestAction>,
  consumed: Int,
  minted: Value,
  duties: List<Duty>,
  refunds: List<Pair<VerificationKeyHash, Int>>,
}

/// Emit this refusal's single trace and latch the fold closed.
fn halt(acc: Fold, reason: String) -> Fold {
  trace reason
  Fold { ..acc, ok: False }
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

/// Does every value byte this operation names decode as a leaf (#157
/// C1)? Checked before the edge and before any proof: a request whose
/// bytes are not a codec byte has no leaf at all.
fn codecOk(op: Operation) -> Bool {
  when op is {
    Insert(value) -> is_some(decodeState(value))
    Delete(value) -> is_some(decodeState(value))
    Update(old, new) -> is_some(decodeState(old)) && is_some(decodeState(new))
    Read(value) -> is_some(decodeState(value))
  }
}

/// The reason this `(operation, before-leaf)` is not one of the seven
/// rows (#157 C2, G3, N10). Total over the codec domain, and each arm is
/// one trace: `edgeOf` says no, this says why.
fn refuseEdge(acc: Fold, op: Operation, before: Option<Int>) -> Fold {
  when op is {
    Insert(_) -> halt(acc, @"insert-terminal")
    Read(_) ->
      // Lean distinguishes the facts (`read-absent` vs `read-active`), so
      // the cage does too: G3 keeps the traces pairwise distinct where
      // R3 says the facts differ, and M3 keeps its own named trace for
      // the read of a LIVE name.
      if before == Some(kindAbsent) {
        halt(acc, @"read-absent")
      } else {
        halt(acc, @"read-non-terminal")
      }
    Delete(_) ->
      if before == Some(kindTerminal) {
        halt(acc, @"edge-from-terminal")
      } else {
        halt(acc, @"edge-inadmissible")
      }
    Update(old, new) ->
      if before == Some(kindTerminal) {
        halt(acc, @"edge-from-terminal")
      } else if decodeState(new) == Some(kindAbsent) {
        halt(acc, @"update-to-absent")
      } else if decodeState(old) == Some(kindAbsent) && decodeState(new) == Some(
        kindTerminal,
      ) {
        halt(acc, @"update-absent-to-terminal")
      } else if decodeState(old) == Some(kindActive) && decodeState(new) == Some(
        kindActive,
      ) {
        halt(acc, @"update-active-to-active")
      } else {
        halt(acc, @"edge-inadmissible")
      }
  }
}

/// The duties an admitted edge creates (#157 C6). Read off the edge and
/// the request, never off anything the folder declares.
fn dutiesOf(
  pins: State,
  edge: Int,
  key: ByteArray,
  destination: (ByteArray, ByteArray),
  floor: Int,
) -> List<Duty> {
  let (refund, _) = destination
  // Note: the merge fields start at one duty; `pushDuties` folds a second
  // request for the same token into the same carrier.
  if edge == edgeInsertAbsent {
    [LockCustody { key, refund, floor }]
  } else if edge == edgeInsertActive {
    [DeliverToken {
        policy: pins.active_policy,
        key,
        destination,
        floor,
        count: 1,
        agreed: True,
      }]
  } else if edge == edgeUpdateActive {
    [
      SpendCustody { key },
      DeliverToken {
        policy: pins.active_policy,
        key,
        destination,
        floor,
        count: 1,
        agreed: True,
      },
    ]
  } else if edge == edgeUpdateTerminal {
    [BurnFromInput { policy: pins.active_policy, key }]
  } else if edge == edgeDeleteAbsent {
    [SpendCustody { key }]
  } else if edge == edgeWitnessTerminal {
    [DeliverToken {
      policy: pins.terminal_policy,
      key,
      destination,
      floor,
      count: 1,
      agreed: True,
    }]
  } else {
    // `deleteActive` (edge 5) burns the active token the request names;
    // the cage requires it as an input, exactly as the terminal update
    // does.
    [BurnFromInput { policy: pins.active_policy, key }]
  }
}


/// Add one edge's duties to the accumulated list, merging a delivery
/// into an existing one for the same `(policy, key)`: one asset cannot
/// sit in two outputs, so two requests minting it owe ONE carrier, with
/// both tokens and both deposits in it.
fn pushDuties(existing: List<Duty>, fresh: List<Duty>) -> List<Duty> {
  when fresh is {
    [] -> existing
    [duty, ..rest] -> pushDuties(pushDuty(existing, duty), rest)
  }
}

fn pushDuty(existing: List<Duty>, duty: Duty) -> List<Duty> {
  when duty is {
    DeliverToken { policy, key, destination, floor, count, agreed } ->
      mergeDeliver(existing, policy, key, destination, floor, count, agreed)
    _ -> [duty, ..existing]
  }
}

fn mergeDeliver(
  existing: List<Duty>,
  policy: PolicyId,
  key: ByteArray,
  destination: (ByteArray, ByteArray),
  floor: Int,
  count: Int,
  agreed: Bool,
) -> List<Duty> {
  when existing is {
    [] -> [DeliverToken { policy, key, destination, floor, count, agreed }]
    [head, ..rest] ->
      when head is {
        DeliverToken {
          policy: heldPolicy,
          key: heldKey,
          destination: heldDestination,
          floor: heldFloor,
          count: heldCount,
          agreed: heldAgreed,
        } ->
          if heldPolicy == policy && heldKey == key {
            [
              DeliverToken {
                policy,
                key,
                destination: heldDestination,
                floor: heldFloor + floor,
                count: heldCount + count,
                agreed: heldAgreed && agreed && heldDestination == destination,
              },
              ..rest
            ]
          } else {
            [
              head,
              ..mergeDeliver(rest, policy, key, destination, floor, count, agreed)
            ]
          }
        _ ->
          [head, ..mergeDeliver(rest, policy, key, destination, floor, count, agreed)]
      }
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
    if !acc.ok {
      acc
    } else {
      when input.output.datum is {
        InlineDatum(datum) ->
          if datum is RequestDatum(request): CageDatum {
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

fn stepRequest(
  acc: Fold,
  pins: State,
  request: Request,
  input: Input,
  validity_range,
) -> Fold {
  let Request { requestOwner, requestKey, requestValue, tip, submitted_at, destination, .. } =
    request
  let held = lovelace_of(input.output.value)
  if tip != pins.tip {
    halt(acc, @"tip-mismatch")
  } else if held < tip {
    // C8 (was the pinned consumer's R1): the cage checks carriage now,
    // beside `tip == pins.tip`. Costless fabricated requests would
    // otherwise fold for free — trie spam at zero price.
    halt(acc, @"tip-coverage")
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
              Fold {
                ..popped,
                refunds: [Pair(requestOwner, held - tip), ..popped.refunds],
              }
            }
          UpdateAction(proof) ->
            if !in_phase1(validity_range, submitted_at, pins.process_time) {
              halt(popped, @"not-phase1")
            } else if !codecOk(requestValue) {
              halt(popped, @"leaf-codec")
            } else {
              let before =
                when statedBefore(requestValue) is {
                  None -> None
                  Some(bytes) -> decodeState(bytes)
                }
              when edgeOf(requestValue, before) is {
                None -> refuseEdge(popped, requestValue, before)
                Some(edge) -> {
                  let checked =
                    if edge == edgeWitnessTerminal {
                      // A read carries no approval and needs none (C4).
                      popped
                    } else {
                      admitted(popped, pins, edge, request, input.output.value)
                    }
                  if !checked.ok {
                    checked
                  } else {
                    applyEdge(
                      checked,
                      pins,
                      edge,
                      requestKey,
                      requestValue,
                      destination,
                      held - tip,
                      proof,
                    )
                  }
                }
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
  key: ByteArray,
  op: Operation,
  destination: (ByteArray, ByteArray),
  floor: Int,
  proof: mpf.Proof,
) -> Fold {
  let advanced =
    if edge == edgeWitnessTerminal {
      // C3: no new proof code. `mpf.has` is the library's own inclusion
      // check and is total, so a proof against the wrong root is an
      // attributable refusal rather than a crash inside the library;
      // the mandated `update(root, key, proof, v, v) == root` then runs
      // on the verified proof and must leave the root alone.
      if !mpf.has(acc.trie, key, leafTerminal, proof) {
        None
      } else {
        let after = mpf.update(acc.trie, key, proof, leafTerminal, leafTerminal)
        if mpf.root(after) == mpf.root(acc.trie) {
          Some(acc.trie)
        } else {
          None
        }
      }
    } else {
      Some(
        when op is {
          Insert(value) -> mpf.insert(acc.trie, key, value, proof)
          Delete(value) -> mpf.delete(acc.trie, key, value, proof)
          Update(old, new) -> mpf.update(acc.trie, key, proof, old, new)
          // Unreachable: the read is handled above and `edgeOf` admits
          // nothing else.
          Read(_) -> acc.trie
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
          dutiesOf(pins, edge, key, destination, floor),
        ),
      }
  }
}

// ----------------------------------------------------------------------------
// Discharging the duties
// ----------------------------------------------------------------------------

fn dutiesSatisfied(
  pins: State,
  cageAddress: Address,
  duties: List<Duty>,
  tx: Transaction,
) -> Bool {
  when duties is {
    [] -> True
    [duty, ..rest] ->
      if dutyOk(pins, cageAddress, duty, tx) {
        dutiesSatisfied(pins, cageAddress, rest, tx)
      } else {
        False
      }
  }
}

fn dutyOk(
  pins: State,
  cageAddress: Address,
  duty: Duty,
  tx: Transaction,
) -> Bool {
  when duty is {
    DeliverToken { policy, key, destination, floor, count, agreed } -> {
      let carriers = carriersOf(tx.outputs, policy, key)
      when carriers is {
        [carrier] ->
          if !agreed || quantity_of(carrier.value, policy, key) != count || !destinationMatches(
            destination,
            carrier,
          ) {
            traceFalse(@"destination")
          } else if lovelace_of(carrier.value) < floor {
            // T6 / want-ledger R4: no folder incentive exists in this
            // version, so the deposit that rode the request returns to
            // the requester. The folder earns the tip and nothing else.
            // `floor` is the SUM over the requests that share this
            // carrier, so a second deposit cannot be pocketed.
            traceFalse(@"deposit-returned")
          } else {
            True
          }
        _ -> traceFalse(@"destination")
      }
    }
    LockCustody { key, refund, floor } -> {
      let carriers = carriersOf(tx.outputs, pins.absent_policy, key)
      when carriers is {
        [carrier] ->
          if quantity_of(carrier.value, pins.absent_policy, key) != 1 || carrier.address != cageAddress || !custodyDatumIs(
            carrier.datum,
            key,
            refund,
          ) || !onlyAsset(carrier.value, pins.absent_policy, key) {
            traceFalse(@"absent-custody")
          } else if lovelace_of(carrier.value) < floor {
            traceFalse(@"deposit-returned")
          } else {
            True
          }
        _ -> traceFalse(@"absent-custody")
      }
    }
    SpendCustody { key } ->
      when custodyInput(cageAddress, key, tx.inputs) is {
        None -> traceFalse(@"refund")
        Some((refund, owed)) ->
          if filter(
            tx.outputs,
            fn(out) { paysAddress(refund, out) && lovelace_of(out.value) >= owed },
          ) == [] {
            traceFalse(@"refund")
          } else {
            True
          }
      }
    BurnFromInput { policy, key } ->
      if find(
        tx.inputs,
        fn(i) { quantity_of(i.output.value, policy, key) >= 1 },
      ) == None {
        traceFalse(@"burn-from-input")
      } else {
        True
      }
  }
}

fn traceFalse(reason: String) -> Bool {
  trace reason
  False
}

fn carriersOf(
  outputs: List<Output>,
  policy: PolicyId,
  key: ByteArray,
) -> List<Output> {
  filter(outputs, fn(out) { quantity_of(out.value, policy, key) != 0 })
}

/// The output carries this absent token and nothing else besides ADA
/// (#157 C6: "No other asset in that output").
fn onlyAsset(value: Value, policy: PolicyId, key: ByteArray) -> Bool {
  filter(
    assets.flatten(value),
    fn(entry) {
      let (entryPolicy, name, _) = entry
      entryPolicy != #"" && !(entryPolicy == policy && name == key)
    },
  ) == []
}

fn custodyDatumIs(datum: Datum, key: ByteArray, refund: ByteArray) -> Bool {
  when datum is {
    InlineDatum(inline) ->
      if inline is AbsentCustody { key: heldKey, refund: heldRefund }: CageDatum {
        heldKey == key && heldRefund == refund
      } else {
        False
      }
    _ -> False
  }
}

/// The custody UTxO for this key among the spent inputs, with the refund
/// address it recorded and the lovelace it holds.
fn custodyInput(
  cageAddress: Address,
  key: ByteArray,
  inputs: List<Input>,
) -> Option<(ByteArray, Int)> {
  when
    filter(
      inputs,
      fn(i) {
        i.output.address == cageAddress && custodyKeyOf(i.output.datum) == Some(
          key,
        )
      },
    )
  is {
    [held] -> {
      expect Some(refund) = custodyRefundOf(held.output.datum)
      Some((refund, lovelace_of(held.output.value)))
    }
    _ -> None
  }
}

fn custodyKeyOf(datum: Datum) -> Option<ByteArray> {
  when datum is {
    InlineDatum(inline) ->
      if inline is AbsentCustody { key, refund: _ }: CageDatum {
        Some(key)
      } else {
        None
      }
    _ -> None
  }
}

fn custodyRefundOf(datum: Datum) -> Option<ByteArray> {
  when datum is {
    InlineDatum(inline) ->
      if inline is AbsentCustody { key: _, refund }: CageDatum {
        Some(refund)
      } else {
        None
      }
    _ -> None
  }
}

// ----------------------------------------------------------------------------
// Rejected-row refunds (unchanged)
// ----------------------------------------------------------------------------

fn sumRefunds(
  outputs: List<Output>,
  owners: List<Pair<VerificationKeyHash, Int>>,
) -> Bool {
  when owners is {
    [] -> True
    [Pair(owner, owed), ..rest] -> {
      expect [output, ..remaining] = outputs
      expect address.VerificationKey(vkh) = output.address.payment_credential
      expect vkh == owner
      // Per-owner no-underpayment (NOTE-014 item A2): this row's output
      // carries at least exactly what is owed. Unequal crossed
      // allocations fail here even when every credential passes and
      // every total matches.
      expect lovelace_of(output.value) >= owed
      sumRefunds(remaining, rest)
    }
  }
}

// ----------------------------------------------------------------------------
// `Modify`
// ----------------------------------------------------------------------------

fn validModify(
  pins: State,
  input: Input,
  policyId: PolicyId,
  tokenId: TokenId,
  tx: Transaction,
  actions: List<RequestAction>,
) -> Bool {
  let Transaction { outputs, inputs, validity_range, mint, .. } = tx
  expect Some(output) = head(outputs)
  expect InlineDatum(outState) = output.datum
  expect StateDatum(next) = outState
  if output.address.payment_credential != input.output.address.payment_credential {
    // The continuation is the cage's own UTxO, at the cage's own
    // address: a fold that hands the registry to another script is not a
    // fold. Checked before anything the batch says, because everything
    // after it is about a state that would not be the registry's.
    traceFalse(@"continuation-address")
  } else if !exactQuantity(policyId, output.value, tokenId, 1) {
    traceFalse(@"state-token")
  } else if lovelace_of(output.value) < lovelace_of(input.output.value) {
    // No-drain rule (NOTE-017): the state UTxO's own lovelace may not
    // fall. Processed value routes to the destinations below; ledger
    // conservation plus the rejected-row floors close the rest.
    traceFalse(@"state-drain")
  } else if !pinsPreserved(pins, next) {
    // C7: the seven non-root fields are registry configuration — genesis
    // sets them, every fold preserves them. A fold altering any of them
    // refuses here, before any root, delta or destination check.
    traceFalse(@"pins-altered")
  } else {
    let folded =
      foldl(
        inputs,
        Fold {
          ok: True,
          trie: mpf.from_root(pins.root),
          actions,
          consumed: 0,
          minted: assets.zero,
          duties: [],
          refunds: [],
        },
        mkAction(pins, tokenId, validity_range),
      )
    if !folded.ok {
      False
    } else if folded.consumed <= 0 {
      // Exact request/action pairing (NOTE-020, A001/root 071): empty
      // processing refuses — no matching request consumed, no batch.
      traceFalse(@"empty-fold")
    } else if folded.actions != [] {
      // Surplus unconsumed actions refuse: every supplied action must
      // pair with an actual matching request, and missing actions
      // already refused at `missing-action`.
      traceFalse(@"surplus-actions")
    } else if mpf.root(folded.trie) != next.root {
      traceFalse(@"root")
    } else if !mintMatches(pins, folded.minted, mint) {
      // C5: the transaction's mint under the three pinned token policies
      // equals the summed C2 column exactly — asset by asset, quantity
      // by quantity — and nothing else moves under them. A mint that
      // adds, omits, doubles or renames one asset is one delta mismatch.
      traceFalse(@"delta-mismatch")
    } else if !dutiesSatisfied(pins, input.output.address, folded.duties, tx) {
      False
    } else {
      when folded.refunds is {
        [] -> True
        _ -> {
          expect [_, ..refundOutputs] = outputs
          sumRefunds(refundOutputs, list.reverse(folded.refunds))
        }
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
// The custody spending path (#157 C6, T5)
// ----------------------------------------------------------------------------

/// The cage's own spending path for a custody UTxO: spent in a `Modify`
/// that consumes a request for ITS key with `Update(0x00, 0x01)` or
/// `Delete(0x00)`, and nothing else. A plain spend, a fold for another
/// key, and a fold whose request for this key is a read all refuse here.
/// The refund leg is the fold's duty (`refund`), checked by `validModify`
/// on the same transaction.
fn validCustodySpend(
  key: ByteArray,
  refund: ByteArray,
  self: Input,
  tx: Transaction,
) -> Bool {
  if !foldAuthenticated(self.output.address, tx) {
    // The fold itself, authenticated: the registry's own state token,
    // at the cage's own address, SPENT with `Modify`. Without it a
    // request-shaped neighbour would be enough, and custody would be
    // spendable outside the fold that is supposed to consume it.
    traceFalse(@"custody-spend")
  } else if filter(
    tx.inputs,
    fn(i) {
      i.output.address == self.output.address && consumesAbsent(i.output.datum, key)
    },
  ) == [] {
    traceFalse(@"custody-spend")
  } else if !paysAddressSomewhere(refund, self, tx) {
    traceFalse(@"custody-spend")
  } else {
    True
  }
}

/// Is this transaction a fold of the registry this custody belongs to?
/// Exactly one input at the cage's own address carries a state datum and
/// exactly one token under the cage's own policy, and that input is spent
/// with `Modify`. The state validator then runs and judges the batch; a
/// redeemer label alone would be a caller's claim, but the ledger cannot
/// let this input be spent without executing the script that owns it.
fn foldAuthenticated(cageAddress: Address, tx: Transaction) -> Bool {
  when
    filter(
      tx.inputs,
      fn(i) { i.output.address == cageAddress && carriesState(i) },
    )
  is {
    [stateIn] ->
      when pairs.get_first(tx.redeemers, Spend(stateIn.output_reference)) is {
        Some(data) ->
          if data is Modify(_): UpdateRedeemer {
            True
          } else {
            False
          }
        None -> False
      }
    _ -> False
  }
}

/// A state UTxO: a state datum and exactly one token under the policy of
/// the script that holds it.
fn carriesState(input: Input) -> Bool {
  when input.output.datum is {
    InlineDatum(datum) ->
      if datum is StateDatum(_): CageDatum {
        when input.output.address.payment_credential is {
          address.Script(policyId) ->
            when tokenFromPolicy(policyId, input.output.value) is {
              Some(token) ->
                exactQuantity(policyId, input.output.value, token, 1)
              None -> False
            }
          _ -> False
        }
      } else {
        False
      }
    _ -> False
  }
}

/// A request datum for this key whose operation consumes the absent
/// token: `Update(0x00, 0x01)` or `Delete(0x00)`.
fn consumesAbsent(datum: Datum, key: ByteArray) -> Bool {
  when datum is {
    InlineDatum(inline) ->
      if inline is RequestDatum(request): CageDatum {
        request.requestKey == key && when request.requestValue is {
          Update(old, new) ->
            decodeState(old) == Some(kindAbsent) && decodeState(new) == Some(
              kindActive,
            )
          Delete(old) -> decodeState(old) == Some(kindAbsent)
          _ -> False
        }
      } else {
        False
      }
    _ -> False
  }
}

fn paysAddressSomewhere(refund: ByteArray, self: Input, tx: Transaction) -> Bool {
  let owed = lovelace_of(self.output.value)
  filter(
    tx.outputs,
    fn(out) { paysAddress(refund, out) && lovelace_of(out.value) >= owed },
  ) != []
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
