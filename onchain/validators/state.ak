use aiken/collection/list
use aiken/collection/list.{find, foldl, head}
use aiken/merkle_patricia_forestry.{empty, root}
use aiken/merkle_patricia_forestry as mpf
use aiken/option.{is_some}
use cardano/address
use cardano/assets
use cardano/assets.{PolicyId, Value, lovelace_of}
use cardano/transaction.{
  InlineDatum, Input, OutputReference, Transaction, find_input,
}
use lib.{assetName, exactQuantity, tokenFromPolicy}
use registry/custody.{validCustodySpend}
use registry/discharge.{dutiesFault}
use registry/fold.{Fold, mkAction}
use registry/refusal.{refundShort, traceFalse}
use registry/settlement.{
  custodyFault, custodyOwedOf, payeeFault, payeeOwed, refundFault, settlesOf,
}
use types.{
  AbsentCustody, Burning, CageDatum, End, Migrating, MintRedeemer, Minting,
  Modify, RequestAction, State, StateDatum, TokenId, UpdateRedeemer,
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
