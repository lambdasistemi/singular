//// The `Modify` decision: whether a fold of the registry's state is valid,
//// and if not, the one reason why (#157 C1–C8, #253).
////
//// ## Responsibility
////
//// `validModify` checks, in this order: the continuation output
//// (`continuation-address`, `state-token`, `state-drain`) and the preserved
//// pins (`pins-altered`); then runs the fold over the transaction's inputs
//// (`registry/fold`) and judges its result (`empty-fold`, `surplus-actions`,
//// `root`, the mint delta); then discharges the collected duties
//// (`registry/discharge`) and settles the lovelace they owe
//// (`registry/settlement`). The first failing check is the answer.
////
//// ## Dependencies
////
//// Imports `registry/fold`, `registry/discharge`, `registry/settlement`,
//// `registry/refusal`, `lib` (exact quantity, the mint refusal) and `types`.
//// Imported by `state`, whose spend handler and `modifyRefusal` identify the
//// state input and call it. Nothing below imports it.
////
//// ## Assumptions
////
//// - `input` is the state input being spent, carrying `pins`, and
////   `policyId` and `tokenId` are its script and the one state token it
////   holds, as `state` establishes before calling.
//// - The transaction's first output is the continuation and carries an
////   inline state datum; otherwise the decision crashes rather than
////   refusing.
////
//// ## Invariants
////
//// - The answer is `None` or exactly one reason, so the spend handler traces
////   exactly one user-defined trace for a refused fold.
//// - Continuation and pin checks precede everything the batch says; the
////   fold's own refusal precedes the batch-level checks; every duty is
////   discharged before any lovelace is settled; custody refunds are settled
////   before positional refunds, and both before the per-payee sums.
//// - The seven non-root state fields are equal before and after every fold,
////   and the mint under the three pinned token policies equals the summed
////   edge deltas exactly.

use aiken/collection/list
use aiken/collection/list.{foldl, head}
use aiken/merkle_patricia_forestry as mpf
use cardano/assets
use cardano/assets.{PolicyId, Value, lovelace_of}
use cardano/transaction.{InlineDatum, Input, Transaction}
use lib.{exactQuantity}
use registry/discharge.{dutiesFault}
use registry/fold.{Fold, mkAction}
use registry/refusal.{refundShort}
use registry/settlement.{
  custodyFault, custodyOwedOf, payeeFault, payeeOwed, refundFault, settlesOf,
}
use types.{RequestAction, State, StateDatum, TokenId}

/// Why the cage refuses this fold of the state `input` carrying `pins`, or
/// `None` when it is valid: the continuation, the pins, the fold, the mint
/// delta, the duties and the payees, checked in that order, first failure
/// answering.
pub fn validModify(
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
