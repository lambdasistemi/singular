use aiken/collection/list.{find, has}
use aiken/collection/pairs
use aiken/interval
use cardano/address.{Script}
use cardano/assets.{PolicyId}
use cardano/transaction.{InlineDatum, Input, OutputReference, Transaction}
use lib.{TokenId, exactQuantity}
use types.{CageDatum, Request, State, StateDatum}

/// Validate that the state owner has signed the transaction.
pub fn validateOwnership(state: State, tx: Transaction) {
  let Transaction { extra_signatories, withdrawals, .. } = tx
  let State { owner, stake_script, .. } = state
  when stake_script is {
    None -> {
      expect has(extra_signatories, owner)
      True
    }
    Some(script) -> {
      expect has(extra_signatories, owner)
      expect pairs.has_key(withdrawals, Script(script))
      True
    }
  }
}

/// Read the State from a transaction input's inline datum.
pub fn readState(input: Input) -> State {
  when input.output.datum is {
    InlineDatum(datum) ->
      if datum is StateDatum(state): CageDatum {
        state
      } else {
        fail
      }
    _ -> fail
  }
}

/// Find an input by reference in regular transaction inputs.
pub fn inputByRef(ref: OutputReference, tx: Transaction) -> Input {
  expect Some(input) =
    find(tx.inputs, fn(input) { input.output_reference == ref })
  input
}

/// Find an input by reference in regular inputs first, then reference inputs.
pub fn inputOrReferenceByRef(ref: OutputReference, tx: Transaction) -> Input {
  when find(tx.inputs, fn(input) { input.output_reference == ref }) is {
    Some(input) -> input
    None -> {
      expect Some(input) =
        find(tx.reference_inputs, fn(input) { input.output_reference == ref })
      input
    }
  }
}

/// Authenticate that an input carries exactly one cage token under the global
/// state policy id.
pub fn carriesStateToken(
  statePolicyId: PolicyId,
  cageToken: TokenId,
  input: Input,
) -> Bool {
  exactQuantity(statePolicyId, input.output.value, cageToken, 1)
}

/// Check if the validity range is entirely within Phase 1.
pub fn in_phase1(validity_range, submitted_at, process_time) -> Bool {
  interval.is_entirely_before(validity_range, submitted_at + process_time)
}

/// Check if the validity range is entirely within Phase 2.
pub fn in_phase2(
  validity_range,
  submitted_at,
  process_time,
  retract_time,
) -> Bool {
  interval.is_entirely_after(validity_range, submitted_at + process_time - 1) && interval.is_entirely_before(
    validity_range,
    submitted_at + process_time + retract_time,
  )
}

/// Check if a request is rejectable: Phase 3 or dishonest future timestamp.
pub fn is_rejectable(
  validity_range,
  submitted_at,
  process_time,
  retract_time,
) -> Bool {
  interval.is_entirely_after(
    validity_range,
    submitted_at + process_time + retract_time - 1,
  ) || interval.is_entirely_before(validity_range, submitted_at)
}

/// A request is protected from owner sweep only when it can be processed by
/// state Modify. Matching token alone is not enough: mismatched-tip or
/// underfunded spam would otherwise be locked at the request address forever.
pub fn processableRequest(
  request: Request,
  cageToken: TokenId,
  state: State,
  input: Input,
) -> Bool {
  let Request { requestToken, tip, .. } = request
  let State { tip: stateTip, .. } = state
  requestToken == cageToken && tip == stateTip && assets.lovelace_of(
    input.output.value,
  ) >= stateTip
}
