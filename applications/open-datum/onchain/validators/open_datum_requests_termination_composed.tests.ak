//// A booked termination is consumed by a public fold through both validators.
//// This composed consumer runs in the assembled test project.

use aiken/builtin
use aiken/collection/list
use application/mint as held_mint
use application/spend as held_spend
use cardano/assets.{from_asset, from_lovelace}
use cardano/transaction.{Input, Output, Transaction}
use open_datum_requests as held_requests
use open_datum_requests_fixtures as held_fx
use open_datum_requests_termination_fixtures as termination_fx
use singular_state as held_state
use singular_state/genesis.{Folded}
use singular_state_fold_fixtures as fold_fx
use singular_state_termination_fixtures as termination_fold_fx

// The public fold fixture consumes the actual output accepted by booking.
// No controller signature, private preimage file or application reference
// input enters the fold. This is connected component execution, not ledger
// or builder acceptance.
test application_held_no_stuck_termination_from_a_booked_request() {
  let booking = termination_fx.booking()
  let mint_raw = termination_fx.mint_action(held_fx.seed_a, 0)
  expect mint_action: held_mint.ApplicationAction = mint_raw
  expect Some(booking_action) =
    held_spend.spend_action_of(termination_fx.spend_action(0))
  expect [booked] = booking.outputs
  let c = termination_fx.control(held_fx.key_a)
  let approval = termination_fx.approval(c)
  let pending =
    termination_fold_fx.Termination {
      key: c.key,
      request: held_fx.seed_c,
      request_lovelace: assets.lovelace_of(booked.value),
    }
  let public =
    termination_fold_fx.Mixed {
      seed: held_fx.seed_a,
      before: [termination_fold_fx.active(c.key)],
      steps: [termination_fold_fx.Terminating(pending)],
    }
  let built = termination_fold_fx.transaction_mixed(public)
  let inputs =
    list.map(
      built.inputs,
      fn(input) {
        if input.output_reference == pending.request {
          Input { ..input, output: booked }
        } else {
          input
        }
      },
    )
  let funding =
    list.foldl(
      inputs,
      0,
      fn(input, total) {
        if input.output_reference != pending.request && input.output_reference != fold_fx.state_reference {
          total + assets.lovelace_of(input.output.value)
        } else {
          total
        }
      },
    )
  expect [reward, continuation] = built.outputs
  let tx =
    Transaction {
      ..built,
      inputs,
      outputs: [
        Output {
          ..reward,
          value: from_lovelace(funding + pending.request_lovelace),
        },
        continuation,
      ],
      mint: from_asset(c.active_asset.policy, c.active_asset.name, -1)
        |> assets.add(approval.policy, approval.name, -1),
    }
  expect [paid, _continuation] = tx.outputs
  let fold_raw =
    builtin.constr_data(
      5,
      [
        builtin.b_data(c.registry.policy),
        builtin.b_data(c.registry.name),
        builtin.b_data(c.key),
      ],
    )
  when held_spend.spend_action_of(fold_raw) is {
    Some(fold_action) -> and {
        held_requests.open_datum_requests.mint(
          [mint_action],
          held_fx.application_policy,
          booking,
        ),
        held_requests.open_datum_requests.spend(
          None,
          booking_action,
          held_fx.seed_a,
          booking,
        ),
        held_state.singular_state.mint(
          held_fx.application_policy,
          Folded,
          held_fx.state_policy,
          tx,
        ),
        held_state.singular_state.spend(
          held_fx.application_policy,
          None,
          termination_fold_fx.redeemer_mixed(public),
          fold_fx.state_reference,
          tx,
        ),
        held_requests.open_datum_requests.mint(
          [held_mint.ApprovalBurn],
          held_fx.application_policy,
          tx,
        ),
        held_requests.open_datum_requests.spend(
          None,
          fold_action,
          pending.request,
          tx,
        ),
        tx.extra_signatories == [],
        paid.address == reward.address,
        assets.lovelace_of(paid.value) == funding + pending.request_lovelace,
        tx.treasury_donation == None,
      }
    None -> False
  }
}
