//// ## Responsibility
//// Boot an ownerless registry and admit only registration and permanent termination.
//// Rejects retain their original exit.
////
//// ## Dependencies
//// `registry/genesis` validates creation; `registry/admission` and `registry/modify`
//// validate the two supported operations and their settlement obligations.
////
//// ## Assumptions
//// The state input carries its datum and exactly one state token under this script.
//// Legacy redeemer and datum encodings remain available for refusal controls.
////
//// ## Invariants
//// Admission is fixed for the lifetime of an instance. No parameter or redeemer
//// can widen it; custody, migration and registry destruction have no spending path.

use aiken/collection/list.{find}
use cardano/address
use cardano/assets.{PolicyId}
use cardano/transaction.{Input, OutputReference, Transaction}
use lib.{exactQuantity, tokenFromPolicy}
use registry/admission.{validModify}
use registry/genesis.{validateMint}
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
///   transaction's inputs, or the script crashes. A legacy `AbsentCustody`
///   UTxO is refused for every redeemer. The state UTxO, whose
///   script and one state token `stateIdentity` must establish (it crashes
///   otherwise), is spent only with `Modify`: `True` when
///   `registry/admission` admits registration or termination and
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
      // Legacy custody datums have no spending path in M1.
      AbsentCustody { .. } -> fail
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
