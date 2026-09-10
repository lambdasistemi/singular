use aiken/collection/list.{find, has}
use aiken/collection/pairs
use cardano/assets.{AssetName, PolicyId}
use cardano/transaction.{OutputReference, Spend, Transaction}
use lib.{TokenId}
use shared.{
  carriesStateToken, in_phase1, in_phase2, inputByRef, inputOrReferenceByRef,
  is_rejectable, processableRequest, readState,
}
use types.{
  CageDatum, Contribute, Modify, Request, RequestDatum, Retract, State, Sweep,
  UpdateRedeemer,
}

validator request(statePolicyId: PolicyId, cageTokenName: AssetName) {
  spend(
    maybeDatum: Option<CageDatum>,
    redeemer: UpdateRedeemer,
    self: OutputReference,
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
      Sweep(stateRef) ->
        validateSweep(statePolicyId, cageToken, maybeDatum, stateRef, self, tx)
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
  let State { process_time, retract_time, .. } = readState(stateInput)
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
  let Request { requestOwner, requestToken, submitted_at, .. } = request
  let Transaction { extra_signatories, validity_range, .. } = tx
  expect requestToken == cageToken
  expect has(extra_signatories, requestOwner)
  let stateInput = inputOrReferenceByRef(stateRef, tx)
  expect carriesStateToken(statePolicyId, cageToken, stateInput)
  let State { process_time, retract_time, .. } = readState(stateInput)
  expect in_phase2(validity_range, submitted_at, process_time, retract_time)
  True
}

fn validateSweep(
  statePolicyId: PolicyId,
  cageToken: TokenId,
  maybeDatum: Option<CageDatum>,
  stateRef: OutputReference,
  self: OutputReference,
  tx: Transaction,
) {
  let Transaction { inputs, extra_signatories, .. } = tx
  let stateInput = inputOrReferenceByRef(stateRef, tx)
  expect carriesStateToken(statePolicyId, cageToken, stateInput)
  let State { owner, .. } as state = readState(stateInput)
  expect has(extra_signatories, owner)
  expect Some(spent) =
    find(inputs, fn(input) { input.output_reference == self })
  let protected =
    when maybeDatum is {
      Some(RequestDatum(request)) ->
        processableRequest(request, cageToken, state, spent)
      _ -> False
    }
  expect !protected
  True
}
