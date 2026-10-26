//// A controller books a termination, moving its genuine token to an empty
//// request and donating the protected deposit. Component checks for
//// bookTermination_inversion, booking_authority_and_parameters and treasury_at_booking.

use aiken/collection/list
use application/held.{Live, ProtectedControl}
use application/mint.{ApplicationAction}
use application/spend.{spend_action_of}
use cardano/address.{from_script}
use cardano/assets.{add, from_lovelace}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Spend, Transaction,
}
use open_datum_requests
use open_datum_requests_fixtures as f
use open_datum_requests_termination_fixtures as t

test the_controller_books_a_termination_without_a_registry_fold() {
  booked(t.booking())
}

test the_booking_mint_and_spend_both_require_the_controller() {
  let tx = t.booking()
  let unsigned = Transaction { ..tx, extra_signatories: [] }
  and {
    booked(tx),
    !mint_at(unsigned, f.seed_a, 0),
    !spend_at(unsigned, f.seed_a, 0),
  }
}

test the_booking_request_holds_exactly_the_active_token_and_the_approval() {
  let tx = t.booking()
  let c = t.control(f.key_a)
  let output = t.request(c)
  let a = t.approval(c)
  list.all(
    [
      add(output.value, f.other_policy, #"01", 1),
      add(output.value, c.active_asset.policy, c.active_asset.name, -1),
      add(output.value, a.policy, a.name, -1),
      add(output.value, a.policy, a.name, 1),
    ],
    fn(value) {
      let bad = Transaction { ..tx, outputs: [Output { ..output, value }] }
      and {
        booked(tx),
        !mint_at(bad, f.seed_a, 0),
        !spend_at(bad, f.seed_a, 0),
      }
    },
  )
}

test the_booking_request_has_no_datum() {
  let tx = t.booking()
  let output = t.request(t.control(f.key_a))
  let bad =
    Transaction { ..tx, outputs: [Output { ..output, datum: InlineDatum(0) }] }
  and {
    booked(tx),
    !mint_at(bad, f.seed_a, 0),
    !spend_at(bad, f.seed_a, 0),
  }
}

test the_booking_donation_is_exactly_the_protected_deposit() {
  let tx = t.booking()
  list.all(
    [None, Some(0), Some(f.deposit - 1), Some(f.deposit + 1)],
    fn(donation) {
      let bad = Transaction { ..tx, treasury_donation: donation }
      and {
        booked(tx),
        !mint_at(bad, f.seed_a, 0),
        !spend_at(bad, f.seed_a, 0),
      }
    },
  )
}

test the_booking_does_not_mint_a_second_approval() {
  let tx = t.booking()
  let a = t.approval(t.control(f.key_a))
  let bad = Transaction { ..tx, mint: add(tx.mint, a.policy, a.name, 1) }
  and {
    booked(tx),
    !mint_at(bad, f.seed_a, 0),
    !spend_at(bad, f.seed_a, 0),
  }
}

test the_booking_request_stays_at_the_application_credential() {
  let tx = t.booking()
  let output = t.request(t.control(f.key_a))
  let bad =
    Transaction {
      ..tx,
      outputs: [Output { ..output, address: from_script(f.other_script) }],
    }
  and {
    booked(tx),
    !mint_at(bad, f.seed_a, 0),
    !spend_at(bad, f.seed_a, 0),
  }
}

test the_booking_approval_names_the_full_registry_and_key() {
  let tx = t.booking()
  let c = t.control(f.key_a)
  list.all(
    [
      t.approval(t.control(f.key_b)),
      t.approval(ProtectedControl { ..c, registry: f.registry_of(f.seed_b) }),
    ],
    fn(other) {
      let a = t.approval(c)
      let bad =
        Transaction {
          ..tx,
          mint: tx.mint
            |> add(a.policy, a.name, -1)
            |> add(other.policy, other.name, 1),
        }
      and {
        booked(tx),
        !mint_at(bad, f.seed_a, 0),
        !spend_at(bad, f.seed_a, 0),
      }
    },
  )
}

test the_booking_consumes_a_genuine_funded_live_holding() {
  let tx = t.booking()
  let c = t.control(f.key_a)
  let output = t.holding(c)
  list.all(
    [
      Output { ..output, value: from_lovelace(c.deposit) },
      Output { ..output, value: add(output.value, #"", #"", -1) },
      Output {
        ..output,
        datum: InlineDatum(
          Live {
            control: ProtectedControl {
              ..c,
              active_asset: f.active_asset_of(f.registry_a(), f.key_b),
            },
            payload: f.payload,
          },
        ),
      },
    ],
    fn(bad_input) {
      let bad =
        Transaction {
          ..tx,
          inputs: [Input { output_reference: f.seed_a, output: bad_input }],
        }
      and {
        booked(tx),
        !mint_at(bad, f.seed_a, 0),
        !spend_at(bad, f.seed_a, 0),
      }
    },
  )
}

test the_booking_donation_sums_two_distinct_holdings() {
  let tx = t.booking()
  let second = t.control(f.key_b)
  let second_approval = t.approval(second)
  let two =
    Transaction {
      ..tx,
      inputs: [
        Input { output_reference: f.seed_b, output: t.holding(second) },
        ..tx.inputs
      ],
      outputs: list.concat(tx.outputs, [t.request(second)]),
      mint: add(tx.mint, second_approval.policy, second_approval.name, 1),
      treasury_donation: Some(f.deposit + second.deposit),
      redeemers: [Pair(Spend(f.seed_b), t.spend_action(1)), ..tx.redeemers],
    }
  and {
    mint_actions(two, [t.mint_action(f.seed_a, 0), t.mint_action(f.seed_b, 1)]),
    spend_at(two, f.seed_a, 0),
    spend_at(two, f.seed_b, 1),
    !spend_at(
      Transaction { ..two, treasury_donation: Some(f.deposit) },
      f.seed_a,
      0,
    ),
    !spend_at(
      Transaction { ..two, treasury_donation: Some(f.deposit) },
      f.seed_b,
      1,
    ),
  }
}

fn mint_at(tx: Transaction, reference: OutputReference, index: Int) -> Bool {
  mint_actions(tx, [t.mint_action(reference, index)])
}

fn mint_actions(tx: Transaction, raw_actions: List<Data>) -> Bool {
  let raw: Data = raw_actions
  if raw is actions: List<ApplicationAction> {
    open_datum_requests.open_datum_requests.mint(
      actions,
      f.application_policy,
      tx,
    )
  } else {
    False
  }
}

fn spend_at(tx: Transaction, reference: OutputReference, index: Int) -> Bool {
  when spend_action_of(t.spend_action(index)) is {
    Some(action) ->
      open_datum_requests.open_datum_requests.spend(None, action, reference, tx)
    None -> False
  }
}

fn booked(tx: Transaction) -> Bool {
  and {
    mint_at(tx, f.seed_a, 0),
    spend_at(tx, f.seed_a, 0),
  }
}
