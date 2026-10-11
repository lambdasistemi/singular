//// ## Responsibility
//// Enforce the permanent M1 contract's two allowed registry edges before fold execution.
////
//// ## Dependencies
//// Uses the canonical modify decision for state, approvals, proofs, tokens and refunds.
//// Request/action matching follows registry/fold's matching order exactly.
////
//// ## Assumptions
//// Missing or excess actions and malformed data are refused by the fold decision.
//// Reject actions retain the original request exit and do not change a leaf.
////
//// ## Invariants
//// Every updating member is registration or termination, including mixed batches.
//// Nothing in State, a parameter or a redeemer can widen this fixed admission set.

use cardano/assets.{PolicyId}
use cardano/transaction.{InlineDatum, Input, Transaction}
use lib.{edgeInsertActive, edgeUpdateTerminal}
use registry/modify.{validFold}
use types.{CageDatum, RequestAction, RequestDatum, State, TokenId, UpdateAction}

/// Check fixed admission first, then all remaining fold obligations.
pub fn validModify(
  pins: State,
  input: Input,
  policyId: PolicyId,
  tokenId: TokenId,
  tx: Transaction,
  actions: List<RequestAction>,
) -> Option<String> {
  if boundary(tx.inputs, tokenId, actions) {
    validFold(pins, input, policyId, tokenId, tx, actions)
  } else {
    Some(@"edge-inadmissible")
  }
}

fn boundary(
  inputs: List<Input>,
  tokenId: TokenId,
  actions: List<RequestAction>,
) -> Bool {
  when inputs is {
    [] -> True
    [input, ..rest] ->
      when input.output.datum is {
        InlineDatum(datum) ->
          if datum is RequestDatum(request): CageDatum {
            if request.requestToken == tokenId {
              when actions is {
                [] -> True
                // The fold decision refuses missing actions.
                [action, ..tail] ->
                  when action is {
                    UpdateAction(_) ->
                      (
                        request.edge == edgeInsertActive || request.edge == edgeUpdateTerminal
                      ) && boundary(rest, tokenId, tail)
                    _ -> boundary(rest, tokenId, tail)
                  }
              }
            } else {
              boundary(rest, tokenId, actions)
            }
          } else {
            boundary(rest, tokenId, actions)
          }
        _ -> boundary(rest, tokenId, actions)
      }
  }
}
