use retirement_custody
use representative.{BurnRepresentative}
use naming
use application
use aiken/interval
use aiken/merkle_patricia_forestry as mpf
use cardano/address.{Script, from_script, from_verification_key}
use cardano/assets.{from_asset, from_lovelace, merge, quantity_of, zero}
use cardano/transaction.{InlineDatum, Input, NoDatum, Output, OutputReference, Spend, Transaction}
use consumer.{Hook}
use lib.{TokenId, assetName}
use request
use state
use types.{Contribute, Insert, Modify, Rejected, Request, RequestDatum, State, StateDatum, Update}

const state_policy = naming.mpfs_state_hash
const request_policy = #"22222222222222222222222222222222222222222222222222222222"
const rep_policy = #"33333333333333333333333333333333333333333333333333333333"
const consumer_pin = #"44444444444444444444444444444444444444444444444444444444"
const owner = #"55555555555555555555555555555555555555555555555555555555"
const state_ref = OutputReference { transaction_id: #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", output_index: 0 }
const request_ref = OutputReference { transaction_id: #"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", output_index: 0 }
const token = TokenId { assetName: assetName(state_ref) }
const key = #"616c696365"
fn active_value() -> ByteArray { rep_name() }
const over_value = #"02"

fn rep_name() -> ByteArray { consumer.consumer_representative_name(owner, state_policy, token.assetName) }
fn cage_state() -> State {
  State { root: mpf.root(mpf.insert(mpf.empty, key, active_value(), [])), tip: 500_000, process_time: 10_000, retract_time: 10_000, representative_policy: rep_policy, consumer_pin: consumer_pin }
}
fn pending(terminal: Bool) -> Request {
  Request { requestToken: token, requestOwner: owner, requestKey: key, requestValue: if terminal { Update(active_value(), over_value) } else { Insert(active_value()) }, tip: 500_000, submitted_at: 0 }
}
fn context(terminal: Bool) -> Transaction {
  let state_value = merge(from_lovelace(3_000_000), from_asset(state_policy, token.assetName, 1))
  let held = if terminal { from_asset(rep_policy, rep_name(), 1) } else { zero }
  let state_output = Output { address: from_script(state_policy), value: state_value, datum: InlineDatum(StateDatum(cage_state())), reference_script: None }
  let request_output = Output { address: from_script(request_policy), value: merge(from_lovelace(3_000_000), held), datum: InlineDatum(RequestDatum(pending(terminal))), reference_script: None }
  let refund = Output { address: from_verification_key(owner), value: merge(from_lovelace(2_500_000), held), datum: NoDatum, reference_script: None }
  let modify: Data = Modify([Rejected])
  Transaction { ..transaction.placeholder, inputs: [Input { output_reference: state_ref, output: state_output }, Input { output_reference: request_ref, output: request_output }], outputs: [state_output, refund], fee: 500_000, mint: zero, validity_range: interval.between(20_000, 25_000), withdrawals: [Pair(Script(consumer_pin), 0)], redeemers: [Pair(Spend(state_ref), modify)], extra_signatories: [] }
}
fn all_three(terminal: Bool) -> Bool {
  let tx = context(terminal)
  expect state.state.spend(Some(StateDatum(cage_state())), Modify([Rejected]), state_ref, tx)
  expect request.request.spend(state_policy, token.assetName, Some(RequestDatum(pending(terminal))), Contribute(state_ref), request_ref, tx)
  expect consumer.consumer.withdraw(Hook, Script(consumer_pin), tx)
  True
}
test retained_root_insert_reject_refund_all_three_accept() { all_three(False) }
test retained_root_terminal_reject_returns_rep_all_three_accept() {
  expect all_three(True)
  expect [_, refund] = context(True).outputs
  expect refund.address == from_verification_key(owner)
  quantity_of(refund.value, rep_policy, rep_name()) == 1
}
test retained_root_terminal_without_consumer_is_refused() fail {
  let tx = context(True)
  state.state.spend(Some(StateDatum(cage_state())), Modify([Rejected]), state_ref, Transaction { ..tx, withdrawals: [] })
}

const custody_policy = application.retirement_custody_hash
const custody_ref = OutputReference { transaction_id: #"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", output_index: 0 }
fn separate_custody_context(burn: Bool) -> Transaction {
  let base = context(True)
  expect [state_input, request_input] = base.inputs
  expect [state_output, request_refund] = base.outputs
  let held = from_asset(rep_policy, rep_name(), 1)
  let custody_input = Input { output_reference: custody_ref, output: Output { address: from_script(custody_policy), value: merge(from_lovelace(3_000_000), held), datum: NoDatum, reference_script: None } }
  let plain_request = Input { ..request_input, output: Output { ..request_input.output, value: from_lovelace(3_000_000) } }
  let plain_refund = Output { ..request_refund, value: from_lovelace(2_500_000) }
  let custody_return = Output { address: from_verification_key(owner), value: merge(from_lovelace(3_000_000), if burn { zero } else { held }), datum: NoDatum, reference_script: None }
  Transaction { ..base, inputs: [state_input, plain_request, custody_input], outputs: [state_output, plain_refund, custody_return], mint: if burn { from_asset(rep_policy, rep_name(), -1) } else { zero } }
}
test retained_root_named_custody_prevents_redirect_after_three_handlers_accept() fail {
  let tx = separate_custody_context(False)
  expect state.state.spend(Some(StateDatum(cage_state())), Modify([Rejected]), state_ref, tx)
  expect request.request.spend(state_policy, token.assetName, Some(RequestDatum(pending(True))), Contribute(state_ref), request_ref, tx)
  expect consumer.consumer.withdraw(Hook, Script(consumer_pin), tx)
  let red: Data = 0
  retirement_custody.retirement_custody.spend(None, red, custody_ref, tx)
}
test retained_root_custody_exact_burn_accepts_component_only() {
  let red: Data = 0
  retirement_custody.retirement_custody.spend(None, red, custody_ref, separate_custody_context(True))
}


// Five actual production handlers consume ONE identical context. The
// real Update-shaped retirement request is rejected after expiry; the
// representative burns, but the registry output keeps its Active root.
test rootfive_rejected_retirement_burns_while_registry_stays_active() {
  let tx = separate_custody_context(True)
  expect [old_state, _, _] = tx.inputs
  expect [new_state, _, _] = tx.outputs
  expect old_state.output.datum == new_state.datum
  expect quantity_of(tx.mint, rep_policy, rep_name()) == -1
  expect tx.extra_signatories == []
  expect state.state.spend(Some(StateDatum(cage_state())), Modify([Rejected]), state_ref, tx)
  expect request.request.spend(state_policy, token.assetName, Some(RequestDatum(pending(True))), Contribute(state_ref), request_ref, tx)
  expect consumer.consumer.withdraw(Hook, Script(consumer_pin), tx)
  let red: Data = 0
  expect retirement_custody.retirement_custody.spend(None, red, custody_ref, tx)
  representative.representative.mint(#"77777777777777777777777777777777777777777777777777777777", BurnRepresentative, rep_policy, tx)
}

test rootfive_no_burn_still_refused_at_custody() fail {
  let tx = separate_custody_context(False)
  expect state.state.spend(Some(StateDatum(cage_state())), Modify([Rejected]), state_ref, tx)
  expect request.request.spend(state_policy, token.assetName, Some(RequestDatum(pending(True))), Contribute(state_ref), request_ref, tx)
  expect consumer.consumer.withdraw(Hook, Script(consumer_pin), tx)
  let red: Data = 0
  retirement_custody.retirement_custody.spend(None, red, custody_ref, tx)
}

test rootfive_missing_registry_now_refuses() fail {
  let tx = separate_custody_context(True)
  expect [_, req, custody] = tx.inputs
  let red: Data = 0
  retirement_custody.retirement_custody.spend(None, red, custody_ref, Transaction { ..tx, inputs: [req, custody] })
}

test rootfive_missing_consumer_still_refuses_at_state() fail {
  let tx = separate_custody_context(True)
  state.state.spend(Some(StateDatum(cage_state())), Modify([Rejected]), state_ref, Transaction { ..tx, withdrawals: [] })
}

test rootfive_legitimate_rejection_without_custody_spend_accepts() {
  let base = separate_custody_context(False)
  expect [st, req, _] = base.inputs
  expect [out, refund, _] = base.outputs
  let tx = Transaction { ..base, inputs: [st, req], outputs: [out, refund], mint: zero }
  expect state.state.spend(Some(StateDatum(cage_state())), Modify([Rejected]), state_ref, tx)
  expect request.request.spend(state_policy, token.assetName, Some(RequestDatum(pending(True))), Contribute(state_ref), request_ref, tx)
  consumer.consumer.withdraw(Hook, Script(consumer_pin), tx)
}
