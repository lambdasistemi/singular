use aiken/collection/list.{has}
use aiken/collection/pairs
use cardano/address.{VerificationKey}
use cardano/assets.{AssetName, PolicyId, lovelace_of, policies}
use cardano/transaction.{
  InlineDatum, Input, OutputReference, Spend, Transaction,
}
use lib.{edgeInsertAbsent, edgeInsertActive, edgeWitnessTerminal}
use shared.{
  carriesStateToken, in_phase1, in_phase2, inputByRef, inputOrReferenceByRef,
  readState,
}
use types.{
  CageDatum, Contribute, Modify, Rejected, Request, RequestAction, RequestDatum,
  Retract, State, Sweep, TokenId, UpdateRedeemer,
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
        validateContribute(
          statePolicyId,
          cageToken,
          request,
          self,
          stateRef,
          tx,
        )
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

/// A request spent by `Contribute` is admitted inside its processing window,
/// whatever its action, as before; or in any window when the state's fold
/// pairs it with `Rejected`: a reject carries no admission (Lean
/// `exitAdmission .reject = none`, #320). Outside the processing window, a
/// request the fold pairs with an update, or with no action, is refused.
fn validateContribute(
  statePolicyId: PolicyId,
  cageToken: TokenId,
  request: Request,
  self: OutputReference,
  stateRef: OutputReference,
  tx: Transaction,
) {
  let Request { requestToken, submitted_at, .. } = request
  expect requestToken == cageToken
  let stateInput = inputByRef(stateRef, tx)
  expect carriesStateToken(statePolicyId, cageToken, stateInput)
  expect Some(actions) = foldActions(stateRef, tx)
  let State { process_time, .. } = readState(stateInput)
  let Transaction { validity_range, inputs, .. } = tx
  expect
    in_phase1(validity_range, submitted_at, process_time) || when
      matchingAction(cageToken, self, inputs, actions)
    is {
      Some(Rejected) -> True
      _ -> False
    }
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

/// The action the state's fold pairs with the input `self`. The fold
/// (`registry/fold` `mkAction`) pops one action for each input, in
/// transaction input order, that carries an inline request datum for this
/// cage token. `None` when `self` is not such an input, or the actions run
/// out before it.
fn matchingAction(
  cageToken: TokenId,
  self: OutputReference,
  inputs: List<Input>,
  actions: List<RequestAction>,
) -> Option<RequestAction> {
  when inputs is {
    [] -> None
    [input, ..rest] ->
      if folded(cageToken, input) {
        when actions is {
          [] -> None
          [action, ..tail] ->
            if input.output_reference == self {
              Some(action)
            } else {
              matchingAction(cageToken, self, rest, tail)
            }
        }
      } else if input.output_reference == self {
        None
      } else {
        matchingAction(cageToken, self, rest, actions)
      }
  }
}

/// Whether the fold pairs this input with an action: the same test as
/// `registry/fold` `mkAction`.
fn folded(cageToken: TokenId, input: Input) -> Bool {
  when input.output.datum is {
    InlineDatum(datum) ->
      if datum is RequestDatum(pending): CageDatum {
        pending.requestToken == cageToken
      } else {
        False
      }
    _ -> False
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
