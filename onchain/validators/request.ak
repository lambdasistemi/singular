use aiken/collection/list.{has}
use aiken/collection/pairs
use cardano/address.{VerificationKey}
use cardano/assets.{AssetName, PolicyId, lovelace_of, policies}
use cardano/transaction.{InlineDatum, OutputReference, Spend, Transaction}
use lib.{edgeInsertAbsent, edgeInsertActive, edgeWitnessTerminal}
use shared.{
  carriesStateToken, in_phase1, in_phase2, inputByRef, inputOrReferenceByRef,
  is_rejectable, readState,
}
use types.{
  CageDatum, Contribute, Modify, Request, RequestDatum, Retract, State, Sweep,
  TokenId, UpdateRedeemer,
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
        when
          retractRefusal(statePolicyId, cageToken, request, self, stateRef, tx)
        is {
          None -> True
          Some(reason) -> {
            trace reason
            False
          }
        }
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
  let State { root: _root, tip: _tip, process_time, retract_time, .. } =
    readState(stateInput)
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

/// The spend handler emits this refusal verbatim. Admission is checked before
/// payment, so a refund cannot authorize a forbidden retraction.
pub fn retractRefusal(
  statePolicyId: PolicyId,
  cageToken: TokenId,
  request: Request,
  self: OutputReference,
  stateRef: OutputReference,
  tx: Transaction,
) -> Option<String> {
  let Request { requestOwner, requestToken, edge, submitted_at, .. } = request
  let Transaction { extra_signatories, validity_range, .. } = tx
  expect requestToken == cageToken
  // Insert-and-read retraction (issue #79 Defect 2; #157 C9, D-RETRACT):
  // Lean `step .withdraw` throws `withdraw-insert-only` for any request
  // that is neither, and `step .escape` throws
  // `completion-only-custody`. An update (retirement) or delete request
  // must NOT be retractable — the completion-only custody binds them.
  // A read carries no custody argument at all, so it retracts exactly
  // as an insert does, and is the only new retractable class. Owner sig,
  // phase-2 window and state-token binding below are retained.
  // (#183 slice b: edges, not value bytes — 0/1 insert, 6 read.)
  let retractable =
    edge == edgeInsertAbsent || edge == edgeInsertActive || edge == edgeWitnessTerminal
  if !retractable {
    Some(@"withdraw-insert-only")
  } else if !has(extra_signatories, requestOwner) {
    Some(@"retract-owner")
  } else {
    let stateInput = inputOrReferenceByRef(stateRef, tx)
    expect carriesStateToken(statePolicyId, cageToken, stateInput)
    let State { root: _root, tip: _tip, process_time, retract_time, .. } =
      readState(stateInput)
    if !in_phase2(validity_range, submitted_at, process_time, retract_time) {
      Some(@"not-phase2")
    } else if list.any(
      // The state policy is common to all registries. References are allowed;
      // consuming any of its tokens alongside a retraction is not.
      tx.inputs,
      fn(input) { has(policies(input.output.value), statePolicyId) },
    ) {
      Some(@"retract-state-spent")
    } else {
      let held = lovelace_of(inputByRef(self, tx).output.value)
      let boundRef: Data = self
      // One sufficient owner output belongs to exactly this consumed request.
      // Its reference binding prevents reuse within and across registries.
      if list.any(
        tx.outputs,
        fn(output) {
          output.address.payment_credential == VerificationKey(requestOwner) && output.datum == InlineDatum(
            boundRef,
          ) && lovelace_of(output.value) >= held
        },
      ) {
        None
      } else {
        Some(@"deposit-returned")
      }
    }
  }
}
