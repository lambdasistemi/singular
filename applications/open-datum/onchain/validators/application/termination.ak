//// The model's terminationShape and terminationBook. Booking moves the
//// genuine token out of a live holding; the state policy takes no part.

use aiken/collection/list
use application/births.{fresh_asset}
use application/held.{ProtectedControl, TokenId}
use application/live.{live_shape}
use cardano/address.{Script}
use cardano/assets.{PolicyId, flatten, without_lovelace}
use cardano/transaction.{NoDatum, Output, Transaction}
use singular_state/preimage.{
  RegistryIdentity, active_token_name, approval_name, termination_preimage,
}

pub fn termination_approval(
  application_policy: PolicyId,
  registry: RegistryIdentity,
  key: ByteArray,
) -> TokenId {
  TokenId {
    policy: application_policy,
    name: approval_name(termination_preimage(key, registry)),
  }
}

pub fn termination_shape(
  application_policy: PolicyId,
  output: Output,
  registry: RegistryIdentity,
  key: ByteArray,
) -> Bool {
  let approval = termination_approval(application_policy, registry, key)
  let expected =
    [
      (registry.policy, active_token_name(registry, key), 1),
      (approval.policy, approval.name, 1),
    ]
  let actual = flatten(without_lovelace(output.value))
  and {
    output.address.payment_credential == Script(application_policy),
    output.datum == NoDatum,
    list.length(actual) == 2,
    list.all(expected, fn(asset) { list.has(actual, asset) }),
  }
}

pub fn termination_book(
  application_policy: PolicyId,
  input: Output,
  control: ProtectedControl,
  output_index: Int,
  tx: Transaction,
  births: List<TokenId>,
) -> Bool {
  and {
    live_shape(application_policy, input, control),
    list.has(tx.extra_signatories, control.controller),
    when list.at(tx.outputs, output_index) is {
      Some(output) ->
        termination_shape(
          application_policy,
          output,
          control.registry,
          control.key,
        )
      None -> False
    },
    fresh_asset(
      tx.mint,
      births,
      termination_approval(application_policy, control.registry, control.key),
    ),
  }
}
