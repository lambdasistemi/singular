//// Anyone spends a booked termination when both tokens burn. These component
//// checks execute terminationFold_inversion and termination_burn. The
//// connected real-state-validator check lives in open_datum.tests because
//// dependent Aiken projects cannot import their dependency's validators.

use aiken/builtin
use application/spend.{spend_action_of}
use cardano/assets.{add, from_asset}
use cardano/transaction.{Input, Transaction}
use open_datum_requests
use open_datum_requests_fixtures as f
use open_datum_requests_termination_fixtures as t

fn folded() -> Transaction {
  let c = t.control(f.key_a)
  let a = t.approval(c)
  Transaction {
    ..transaction.placeholder,
    inputs: [Input { output_reference: f.seed_c, output: t.request(c) }],
    mint: from_asset(c.active_asset.policy, c.active_asset.name, -1)
      |> add(a.policy, a.name, -1),
  }
}

fn run(tx: Transaction) -> Bool {
  let c = t.control(f.key_a)
  let raw =
    builtin.constr_data(
      5,
      [
        builtin.b_data(c.registry.policy),
        builtin.b_data(c.registry.name),
        builtin.b_data(c.key),
      ],
    )
  when spend_action_of(raw) is {
    Some(action) ->
      open_datum_requests.open_datum_requests.spend(None, action, f.seed_c, tx)
    None -> False
  }
}

test anyone_spends_the_request_when_both_tokens_burn_without_a_signature() {
  run(folded())
}

test a_termination_request_cannot_be_spent_without_the_active_token_burn() {
  let tx = folded()
  let c = t.control(f.key_a)
  and {
    run(tx),
    !run(
      Transaction {
        ..tx,
        mint: add(tx.mint, c.active_asset.policy, c.active_asset.name, 1),
      },
    ),
  }
}

test a_termination_request_cannot_be_spent_without_the_approval_burn() {
  let tx = folded()
  let a = t.approval(t.control(f.key_a))
  and {
    run(tx),
    !run(Transaction { ..tx, mint: add(tx.mint, a.policy, a.name, 1) }),
  }
}

test a_termination_request_requires_the_genuine_policy_and_key() {
  let tx = folded()
  let c = t.control(f.key_a)
  let bad =
    Transaction {
      ..tx,
      mint: tx.mint
        |> add(c.active_asset.policy, c.active_asset.name, 1)
        |> add(f.other_policy, c.active_asset.name, -1),
    }
  and {
    run(tx),
    !run(bad),
  }
}

test a_termination_request_burns_exactly_one_active_token() {
  let tx = folded()
  let c = t.control(f.key_a)
  and {
    run(tx),
    !run(
      Transaction {
        ..tx,
        mint: add(tx.mint, c.active_asset.policy, c.active_asset.name, -1),
      },
    ),
  }
}
