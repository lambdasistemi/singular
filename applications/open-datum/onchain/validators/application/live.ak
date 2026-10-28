//// Live holdings: the model's liveShape and liveUpdate. The ledger supplies
//// the spent input; the controller supplies the signature. Payloads are free.

use aiken/collection/list
use application/held.{Live, ProtectedControl, TokenId, held_datum}
use cardano/address.{Script}
use cardano/assets.{PolicyId, lovelace_of, quantity_of, without_lovelace}
use cardano/transaction.{Output, Transaction}
use singular_state/preimage.{active_token_name}

pub fn live_shape(
  application_policy: PolicyId,
  input: Output,
  control: ProtectedControl,
) -> Bool {
  and {
    input.address.payment_credential == Script(application_policy),
    control.deposit >= 0,
    control.active_asset == TokenId {
      policy: control.registry.policy,
      name: active_token_name(control.registry, control.key),
    },
    quantity_of(
      input.value,
      control.active_asset.policy,
      control.active_asset.name,
    ) == 1,
    lovelace_of(input.value) >= control.deposit,
  }
}

pub fn live_update(
  application_policy: PolicyId,
  input: Output,
  control: ProtectedControl,
  successor_index: Int,
  tx: Transaction,
) -> Bool {
  and {
    live_shape(application_policy, input, control),
    list.has(tx.extra_signatories, control.controller),
    when list.at(tx.outputs, successor_index) is {
      Some(successor) -> and {
          successor.address.payment_credential == Script(application_policy),
          when held_datum(successor) is {
            Some(Live { control: next, .. }) -> next == control
            _ -> False
          },
          without_lovelace(successor.value) == without_lovelace(input.value),
          lovelace_of(successor.value) >= control.deposit,
        }
      None -> False
    },
  }
}
