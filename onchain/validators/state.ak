//// The registry's state validator: the cage, in registry mode (#157).
////
//// The cage IS the registry. There is no pinned consumer script and no
//// mandatory withdrawal: every rule the application used to re-walk beside
//// the fold is checked by this validator, once, from the transaction's own
//// evidence. This module is its dispatch; the rules live in the
//// `registry/*` owners named below.
////
//// ## Responsibility
////
//// Route each script purpose to the owner of its rule: a `Minting` mint to
//// `registry/genesis`, a spend of an `AbsentCustody` UTxO to
//// `registry/custody`, and a `Modify` spend of the state UTxO to
//// `registry/modify`, after identifying the state input's script and token
//// (`stateIdentity`). The custody arm does not read the spend redeemer:
//// `registry/custody` decides that spend whatever redeemer it carries. Only
//// the state UTxO's arm restricts the redeemer, to `Modify`. Every other
//// mint redeemer, state-UTxO spend redeemer, datum and purpose fails.
//// `modifyRefusal` exposes the same `Modify` decision to the
//// Aiken suite, so a test asserting a reason asserts the one this validator
//// traces.
////
//// ## Dependencies
////
//// Imports `registry/genesis`, `registry/custody`, `registry/modify` and
//// `registry/refusal`, with `lib` and `types`. No registry owner imports
//// `state`. The owners depend on each other in one direction only:
////
//// - `registry/modify` imports `registry/fold`, `registry/discharge`,
////   `registry/settlement` and `registry/refusal`;
//// - `registry/fold` imports `registry/duty` and `registry/trie`;
//// - `registry/discharge` and `registry/settlement` import `registry/duty`,
////   `registry/custody` and `registry/refusal`;
//// - `registry/custody` imports `registry/refusal`;
//// - `registry/genesis`, `registry/duty`, `registry/trie` and
////   `registry/refusal` import no registry owner.
////
//// ## Assumptions
////
//// - The validator takes no parameters (the ownerless registry of operator
////   ruling NOTE-028/A-003): one script holds every registry, and a registry
////   is told apart by its state token.
//// - The ledger runs this validator for every input it spends at its address
////   and for every mint under its policy, so the custody path may rely on the
////   same transaction's state input being judged by `registry/modify`.
////
//// ## Invariants
////
//// What a `Modify` must satisfy, and the owner that checks it:
////
//// - **C1/C2 admissibility** — the request's tag is one of the seven C2
////   edges (`0..6`), admitted before approval and before any proof is
////   checked; anything else refuses `edge-inadmissible`. The trie move and
////   its leaf bytes come from the edge table, never from request bytes.
////   (`registry/fold`)
//// - **C3 the read** — edge 6 is verified with the existing verifier at its
////   own position in the batch, so its proof is checked against the
////   intermediate root there. The leaf is unchanged. (`registry/fold`,
////   `registry/trie`)
//// - **C4 admission** — a request whose edge changes the trie is folded only
////   if its UTxO carries exactly one asset under the pins's
////   `application_policy` whose asset name is the approval binding of that
////   request. No application script runs at fold time; the cage recomputes
////   the name rather than trusting it. A read requires no approval: its
////   admission is skipped, and an approval asset it carries is not checked.
////   (`registry/fold`)
//// - **C5 the delta** — the cage sums the token column of C2 over the
////   requests it consumed, per key, and the transaction's mint under the
////   three pinned token policies must equal that sum exactly. Nothing else
////   may move under them. (`registry/fold` sums, `registry/modify` compares)
//// - **C6 destinations** — each minted active or terminal token lands in
////   exactly one output, the one its request named, carrying the datum it
////   named and at least the request's value minus the tip. An absent token
////   lands in the cage's own custody beside the inserter's refund address; a
////   consumed absent token pays that address back. An edge that delivers no
////   token (3, 4, 5) and a rejected row pay the request's deposit to
////   `requestOwner`'s key. Every lovelace obligation of a fold is settled
////   once per payee, on the summed lovelace of the outputs paying it (#253).
////   (`registry/duty`, `registry/discharge`, `registry/settlement`)
//// - **C7 the pins** — the seven non-root fields are equal before and after
////   every fold. (`registry/modify`; genesis sets them)
//// - **C8 coverage** — every consumed request carries at least its tip.
////   (`registry/fold`)
////
//// Every refusal the `Modify` decision and the custody path name RETURNS
//// FALSE after emitting exactly one user-defined trace, rather than
//// crashing: a script that dies inside a library cannot tell anyone why,
//// and each row of Gate S is bound to the single trace its refusal emits.
//// That holds for the named refusals only. Genesis, `End`, `Migrating`,
//// `Burning` and every unmatched arm fail without a reason, and a `Modify`
//// still crashes on a malformed continuation output or on a wrong leaf or
//// invalid proof that no named refusal covers.

use aiken/collection/list.{find}
use cardano/address
use cardano/assets.{PolicyId}
use cardano/transaction.{Input, OutputReference, Transaction}
use lib.{exactQuantity, tokenFromPolicy}
use registry/custody.{validCustodySpend}
use registry/genesis.{validateMint}
use registry/modify.{validModify}
use registry/refusal.{traceFalse}
use types.{
  AbsentCustody, Burning, CageDatum, End, Migrating, MintRedeemer, Minting,
  Modify, RequestAction, State, StateDatum, TokenId, UpdateRedeemer,
}

/// The state validator (no parameters).
///
/// - `mint`: `Minting(seed)` boots a registry under `registry/genesis`'s
///   rule. `Migrating` and `Burning` fail for every party: migration and
///   burning destroy or re-policy an ownerless registry with no
///   justification; the constructors stay for the wire shape.
/// - `spend`: the datum must be present and the spent input found among the
///   transaction's inputs, or the script crashes. An `AbsentCustody` UTxO is
///   spent only under `registry/custody`'s rule, which does not read the
///   redeemer: any redeemer reaches it. The state UTxO, whose
///   script and one state token `stateIdentity` must establish (it crashes
///   otherwise), is spent only with `Modify`: `True` when
///   `registry/modify` finds no refusal, else its one reason is traced and
///   the handler answers `False`. The fold is permissionless — there is no
///   registry-owner role. On the state UTxO, `End` and every other redeemer
///   fail for every party; a spend of any other datum fails.
/// - `else`: every other purpose fails.
validator state {
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
// The state input and the `Modify` decision
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
