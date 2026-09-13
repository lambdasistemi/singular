use aiken/collection/list.{has}
use aiken/collection/pairs
use cardano/assets.{AssetName, PolicyId}
use cardano/transaction.{OutputReference, Spend, Transaction}
use lib.{TokenId}
use shared.{
  carriesStateToken, in_phase1, in_phase2, inputByRef, inputOrReferenceByRef,
  is_rejectable, readState,
}
use types.{
  CageDatum, Contribute, Insert, Modify, Request, RequestDatum, Retract, State, Sweep,
  UpdateRedeemer,
}

validator request(statePolicyId: PolicyId, cageTokenName: AssetName) {
  spend(
    maybeDatum: Option<CageDatum>,
    redeemer: UpdateRedeemer,
    _self: OutputReference,
    tx: Transaction,
  ) {
    let cageToken = TokenId { assetName: cageTokenName }
    when redeemer is {
      Contribute(stateRef) -> {
        expect Some(RequestDatum(request)) = maybeDatum
        validateContribute(statePolicyId, cageToken, request, stateRef, tx)
      }
      Retract(stateRef) -> {
        expect Some(RequestDatum(request)) = maybeDatum
        validateRetract(statePolicyId, cageToken, request, stateRef, tx)
      }
      // Ownerless registry (operator ruling NOTE-028/A-003, issue #77
      // repair): seizure is refused for every party — there is no
      // registry-owner role, creator or otherwise. The constructor stays
      // for the wire shape.
      Sweep(_) -> fail
      _ -> fail
    }
  }

  else(_) {
    fail
  }
}

fn validateContribute(
  statePolicyId: PolicyId,
  cageToken: TokenId,
  request: Request,
  stateRef: OutputReference,
  tx: Transaction,
) {
  let Request { requestToken, submitted_at, .. } = request
  expect requestToken == cageToken
  let stateInput = inputByRef(stateRef, tx)
  expect carriesStateToken(statePolicyId, cageToken, stateInput)
  expect stateSpentWithModify(stateRef, tx)
  let State { root: _root, tip: _tip, process_time, retract_time, .. } = readState(stateInput)
  let Transaction { validity_range, .. } = tx
  expect
    in_phase1(validity_range, submitted_at, process_time) || is_rejectable(
      validity_range,
      submitted_at,
      process_time,
      retract_time,
    )
  True
}

fn stateSpentWithModify(stateRef: OutputReference, tx: Transaction) -> Bool {
  let Transaction { redeemers, .. } = tx
  when pairs.get_first(redeemers, Spend(stateRef)) is {
    Some(redeemer) -> {
      expect typed: UpdateRedeemer = redeemer
      when typed is {
        Modify(_) -> True
        _ -> False
      }
    }
    None -> False
  }
}

fn validateRetract(
  statePolicyId: PolicyId,
  cageToken: TokenId,
  request: Request,
  stateRef: OutputReference,
  tx: Transaction,
) {
  let Request { requestOwner, requestToken, requestValue, submitted_at, .. } =
    request
  let Transaction { extra_signatories, validity_range, .. } = tx
  expect requestToken == cageToken
  // Insert-only retraction (issue #79, Defect 2): Lean `step .withdraw`
  // throws `withdraw-insert-only` for any non-insert request, and
  // `step .escape` throws `completion-only-custody`. An Update (retirement)
  // or Delete request must NOT be retractable. Owner sig, phase-2 window
  // and state-token binding below are retained.
  expect when requestValue is {
    Insert(_) -> True
    _ -> False
  }
  expect has(extra_signatories, requestOwner)
  let stateInput = inputOrReferenceByRef(stateRef, tx)
  expect carriesStateToken(statePolicyId, cageToken, stateInput)
  let State { root: _root, tip: _tip, process_time, retract_time, .. } = readState(stateInput)
  expect in_phase2(validity_range, submitted_at, process_time, retract_time)
  True
}
