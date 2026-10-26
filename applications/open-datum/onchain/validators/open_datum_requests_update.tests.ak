//// A controller updates a live holding without a registry fold. These
//// component checks execute liveUpdate's signature, control, asset and
//// deposit clauses, with a passing control beside each refusal.

use aiken/builtin
use aiken/collection/list
use aiken/fuzz
use application/held.{Live, ProtectedControl}
use application/spend.{spend_action_of}
use cardano/address.{from_script}
use cardano/assets.{add, from_lovelace}
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use open_datum_requests
use open_datum_requests_fixtures as f

fn control() -> ProtectedControl {
  f.control_of(f.registry_a(), f.key_a, f.controller, f.deposit)
}

fn holding(c: ProtectedControl, payload: Data) -> Output {
  Output {
    address: from_script(f.application_policy),
    value: from_lovelace(c.deposit)
      |> add(c.active_asset.policy, c.active_asset.name, 1),
    datum: InlineDatum(Live { control: c, payload }),
    reference_script: None,
  }
}

fn transaction() -> Transaction {
  Transaction {
    ..transaction.placeholder,
    inputs: [
      Input {
        output_reference: f.seed_a,
        output: holding(control(), f.payload),
      },
    ],
    outputs: [holding(control(), #"6e6577")],
    extra_signatories: [f.controller],
  }
}

// Wire constructor 3 appends liveUpdate to the existing three spend actions.
// Decoding through the production decoder makes the missing base action an
// executable refusal rather than a test compilation error.
fn run(tx: Transaction) -> Bool {
  let raw = builtin.constr_data(3, [builtin.i_data(0)])
  when spend_action_of(raw) is {
    Some(action) ->
      open_datum_requests.open_datum_requests.spend(None, action, f.seed_a, tx)
    None -> False
  }
}

test the_controller_updates_a_payload_without_a_registry_fold() {
  run(transaction())
}

test an_update_without_the_controller_signature_is_refused() {
  let tx = transaction()
  and {
    run(tx),
    !run(Transaction { ..tx, extra_signatories: [] }),
  }
}

test an_update_cannot_change_any_protected_control_field() {
  let tx = transaction()
  let c = control()
  list.all(
    [
      ProtectedControl { ..c, registry: f.registry_of(f.seed_b) },
      ProtectedControl { ..c, key: f.key_b },
      ProtectedControl { ..c, controller: f.other_key },
      ProtectedControl { ..c, deposit: c.deposit - 1 },
      ProtectedControl {
        ..c,
        active_asset: f.active_asset_of(f.registry_a(), f.key_b),
      },
    ],
    fn(changed) {
      let next = holding(c, f.payload)
      and {
        run(tx),
        !run(
          Transaction {
            ..tx,
            outputs: [
              Output {
                ..next,
                datum: InlineDatum(
                  Live { control: changed, payload: f.payload },
                ),
              },
            ],
          },
        ),
      }
    },
  )
}

test an_update_cannot_add_or_drop_a_token() {
  let tx = transaction()
  let next = holding(control(), f.payload)
  list.all(
    [
      add(next.value, f.other_policy, #"01", 1),
      add(
        next.value,
        control().active_asset.policy,
        control().active_asset.name,
        -1,
      ),
    ],
    fn(value) {
      and {
        run(tx),
        !run(Transaction { ..tx, outputs: [Output { ..next, value }] }),
      }
    },
  )
}

test an_update_preserves_every_extra_token_the_input_holds() {
  let tx = transaction()
  let input = holding(control(), f.payload)
  let value = add(input.value, f.other_policy, #"01", 2)
  let with_extra =
    Transaction {
      ..tx,
      inputs: [
        Input { output_reference: f.seed_a, output: Output { ..input, value } },
      ],
      outputs: [Output { ..input, value }],
    }
  and {
    run(with_extra),
    !run(Transaction { ..with_extra, outputs: tx.outputs }),
  }
}

test an_update_cannot_leave_less_than_the_deposit() {
  let tx = transaction()
  let next = holding(control(), f.payload)
  and {
    run(tx),
    !run(
      Transaction {
        ..tx,
        outputs: [Output { ..next, value: add(next.value, #"", #"", -1) }],
      },
    ),
  }
}

test an_update_may_keep_surplus_or_add_lovelace() {
  let tx = transaction()
  let next = holding(control(), f.payload)
  run(
    Transaction {
      ..tx,
      outputs: [Output { ..next, value: add(next.value, #"", #"", 99) }],
    },
  )
}

test an_update_stays_at_the_application_credential() {
  let tx = transaction()
  let next = holding(control(), f.payload)
  and {
    run(tx),
    !run(
      Transaction {
        ..tx,
        outputs: [Output { ..next, address: from_script(f.other_script) }],
      },
    ),
  }
}

test an_update_requires_a_genuine_funded_input_holding() {
  let tx = transaction()
  let input = holding(control(), f.payload)
  list.all(
    [
      add(
        input.value,
        control().active_asset.policy,
        control().active_asset.name,
        -1,
      ),
      add(input.value, #"", #"", -1),
    ],
    fn(value) {
      and {
        run(tx),
        !run(
          Transaction {
            ..tx,
            inputs: [
              Input {
                output_reference: f.seed_a,
                output: Output { ..input, value },
              },
            ],
          },
        ),
      }
    },
  )
}

test an_update_donates_nothing_without_a_termination_booking() {
  let tx = transaction()
  and {
    run(tx),
    !run(Transaction { ..tx, treasury_donation: Some(1) }),
  }
}

fn updates_from(current: Output, payloads: List<ByteArray>) -> Bool {
  when payloads is {
    [] -> True
    [payload, ..rest] -> {
      let next =
        Output {
          ..current,
          datum: InlineDatum(Live { control: control(), payload }),
        }
      let tx =
        Transaction {
          ..transaction(),
          inputs: [Input { output_reference: f.seed_a, output: current }],
          outputs: [next],
        }
      and {
        run(tx),
        !run(Transaction { ..tx, extra_signatories: [] }),
        updates_from(next, rest),
      }
    }
  }
}

test the_controller_updates_generated_payload_histories(
  payloads via fuzz.list_between(fuzz.bytearray_between(0, 64), 2, 8),
) {
  updates_from(holding(control(), f.payload), payloads)
}
