//// Component fixtures for controller booking and permissionless termination.
//// Asset names are obtained from the state library's production encoders.

use aiken/builtin
use application/held.{Live, ProtectedControl, TokenId}
use cardano/address.{from_script}
use cardano/assets.{add, from_asset, from_lovelace}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Spend, Transaction,
}
use open_datum_requests_fixtures as f
use singular_state/preimage.{approval_name, termination_preimage}

pub fn control(key: ByteArray) -> ProtectedControl {
  f.control_of(f.registry_a(), key, f.controller, f.deposit)
}

pub fn approval(c: ProtectedControl) -> TokenId {
  TokenId {
    policy: f.application_policy,
    name: approval_name(termination_preimage(c.key, c.registry)),
  }
}

pub fn holding(c: ProtectedControl) -> Output {
  Output {
    address: from_script(f.application_policy),
    value: from_lovelace(c.deposit)
      |> add(c.active_asset.policy, c.active_asset.name, 1),
    datum: InlineDatum(Live { control: c, payload: f.payload }),
    reference_script: None,
  }
}

pub fn request(c: ProtectedControl) -> Output {
  let a = approval(c)
  Output {
    address: from_script(f.application_policy),
    value: from_lovelace(2_000_000)
      |> add(c.active_asset.policy, c.active_asset.name, 1)
      |> add(a.policy, a.name, 1),
    datum: NoDatum,
    reference_script: None,
  }
}

pub fn spend_action(index: Int) -> Data {
  builtin.constr_data(4, [builtin.i_data(index)])
}

pub fn mint_action(reference: OutputReference, index: Int) -> Data {
  let ref: Data = reference
  builtin.constr_data(3, [ref, builtin.i_data(index)])
}

pub fn booking() -> Transaction {
  let c = control(f.key_a)
  let a = approval(c)
  Transaction {
    ..transaction.placeholder,
    inputs: [Input { output_reference: f.seed_a, output: holding(c) }],
    outputs: [request(c)],
    mint: from_asset(a.policy, a.name, 1),
    extra_signatories: [c.controller],
    treasury_donation: Some(c.deposit),
    redeemers: [Pair(Spend(f.seed_a), spend_action(0))],
  }
}
