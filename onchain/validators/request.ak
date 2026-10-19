use aiken/collection/list.{has}
use aiken/collection/pairs
use booking.{
  carriesTermination, pureBurn, registrationBookingRefusal,
  terminationBookingRefusal,
}
use cardano/address.{VerificationKey}
use cardano/assets.{AssetName, PolicyId, lovelace_of, policies, tokens}
use cardano/transaction.{
  InlineDatum, Input, OutputReference, Spend, Transaction,
}
use lib.{edgeInsertAbsent, edgeInsertActive, edgeWitnessTerminal}
use registry/refusal.{traceFalse}
use shared.{
  carriesStateToken, in_phase2, inputByRef, inputOrReferenceByRef, readState,
}
use types.{
  CageDatum, Contribute, Modify, RegistrationDatum, Request, RequestAction,
  RequestDatum, Retract, State, Sweep, TerminationDatum, TokenId, UpdateRedeemer,
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
      // A pending request is spendable only inside a fold of the registry it
      // names: its state is spent in this transaction with `Modify`, which
      // judges every input, this one among them. The legacy edge-only request
      // is no member of the fold and is not spent here: no compatibility
      // route survives (it can only be retracted).
      Contribute(stateRef) ->
        when maybeDatum is {
          Some(RegistrationDatum(booked)) ->
            validateContribute(
              statePolicyId,
              cageToken,
              booked.registry,
              stateRef,
              tx,
            )
          Some(TerminationDatum(booked)) ->
            validateContribute(
              statePolicyId,
              cageToken,
              booked.registry,
              stateRef,
              tx,
            )
          _ -> fail
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

  // The booking policy: its own applied hash is the request address's
  // payment credential. A pure burn is accepted without reading the
  // redeemer, a state or an output; anything else is a booking: a
  // termination (a tagged request output stating a `TerminationDatum`) is
  // judged by `booking.terminationBookingRefusal` and every other one by
  // `booking.registrationBookingRefusal`.
  mint(_redeemer: Data, policy_id: PolicyId, tx: Transaction) {
    if pureBurn(tokens(tx.mint, policy_id)) {
      True
    } else {
      let cageToken = TokenId { assetName: cageTokenName }
      let refusal =
        if carriesTermination(policy_id, tx.outputs) {
          terminationBookingRefusal(statePolicyId, cageToken, policy_id, tx)
        } else {
          registrationBookingRefusal(statePolicyId, cageToken, policy_id, tx)
        }
      when refusal is {
        None -> True
        Some(reason) -> traceFalse(reason)
      }
    }
  }

  else(_) {
    fail
  }
}

/// A pending request spent by `Contribute` is consumed by a fold of its own
/// registry: the request is for this cage token, the state input holds that
/// token, and the state is spent with `Modify`. The state validator judges the
/// whole fold, every input, the request itself, and the timing of a
/// registration among them.
fn validateContribute(
  statePolicyId: PolicyId,
  cageToken: TokenId,
  registry: TokenId,
  stateRef: OutputReference,
  tx: Transaction,
) {
  expect registry == cageToken
  let stateInput = inputByRef(stateRef, tx)
  expect carriesStateToken(statePolicyId, cageToken, stateInput)
  expect Some(_) = foldActions(stateRef, tx)
  True
}

/// The actions of the state's `Modify`, when the state is spent with one.
fn foldActions(
  stateRef: OutputReference,
  tx: Transaction,
) -> Option<List<RequestAction>> {
  let Transaction { redeemers, .. } = tx
  when pairs.get_first(redeemers, Spend(stateRef)) is {
    Some(redeemer) -> {
      expect typed: UpdateRedeemer = redeemer
      when typed is {
        Modify(actions) -> Some(actions)
        _ -> None
      }
    }
    None -> None
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
  // Insert-and-read retraction (issue #79 Defect 2; #157 owner-retraction, D-RETRACT):
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
