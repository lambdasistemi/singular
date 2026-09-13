use retirement_custody
use application
use aiken/interval
use aiken/merkle_patricia_forestry as mpf
use cardano/address.{Script, from_script, from_verification_key}
use cardano/assets.{PolicyId, from_asset, from_lovelace, merge, zero}
use cardano/transaction.{InlineDatum, Input, NoDatum, Output, OutputReference, Spend, Transaction}
use consumer.{Hook}
use lib.{TokenId, assetName}
use naming
use request
use state
use types.{Contribute, Modify, Request, RequestDatum, State, StateDatum, Update, UpdateAction}

const state_policy = naming.mpfs_state_hash
const request_policy = #"22222222222222222222222222222222222222222222222222222222"
const real_rep_policy = #"33333333333333333333333333333333333333333333333333333333"
const foreign_policy = #"66666666666666666666666666666666666666666666666666666666"
const consumer_pin = #"44444444444444444444444444444444444444444444444444444444"
const owner = #"55555555555555555555555555555555555555555555555555555555"
const state_ref = OutputReference {
  transaction_id: #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  output_index: 0,
}
const creator_tx = #"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
const custody_ref = OutputReference { transaction_id: creator_tx, output_index: 0 }
const request_ref = OutputReference { transaction_id: creator_tx, output_index: 1 }
const token = TokenId { assetName: assetName(state_ref) }
const key = #"616c696365"

fn rep_name() -> ByteArray {
  consumer.consumer_representative_name(owner, state_policy, token.assetName)
}

fn old_state() -> State {
  State {
    root: mpf.root(mpf.insert(mpf.empty, key, rep_name(), [])),
    tip: 500_000,
    process_time: 10_000,
    retract_time: 10_000,
    representative_policy: real_rep_policy,
    consumer_pin,
  }
}

fn new_state() -> State {
  let before = old_state()
  State {
    ..before,
    root:
      mpf.root(
        mpf.update(
          mpf.from_root(before.root),
          key,
          [],
          rep_name(),
          naming.over_marker_for(rep_name()),
        ),
      ),
  }
}

fn retirement_request() -> Request {
  Request {
    requestToken: token,
    requestOwner: owner,
    requestKey: key,
    requestValue: Update(rep_name(), naming.over_marker_for(rep_name())),
    tip: 500_000,
    submitted_at: 0,
  }
}

fn state_input() -> Input {
  Input {
    output_reference: state_ref,
    output: Output {
      address: from_script(state_policy),
      value:
        merge(
          from_lovelace(3_000_000),
          from_asset(state_policy, token.assetName, 1),
        ),
      datum: InlineDatum(StateDatum(old_state())),
      reference_script: None,
    },
  }
}

fn request_input() -> Input {
  Input {
    output_reference: request_ref,
    output: Output {
      address: from_script(request_policy),
      value: from_lovelace(3_000_000),
      datum: InlineDatum(RequestDatum(retirement_request())),
      reference_script: None,
    },
  }
}

fn completion_context(
  held_policy: PolicyId,
  held_name: ByteArray,
  burn: Bool,
  hook: Bool,
) -> Transaction {
  let state_in = state_input()
  let held = from_asset(held_policy, held_name, 1)
  let custody_in = Input {
    output_reference: custody_ref,
    output: Output {
      address: from_script(application.retirement_custody_hash),
      value: merge(from_lovelace(3_000_000), held),
      datum: NoDatum,
      reference_script: None,
    },
  }
  let state_out = Output {
    address: state_in.output.address,
    value: state_in.output.value,
    datum: InlineDatum(StateDatum(new_state())),
    reference_script: None,
  }
  let change = Output {
    address: from_verification_key(owner),
    value: from_lovelace(5_500_000),
    datum: NoDatum,
    reference_script: None,
  }
  let modify: Data = Modify([UpdateAction([])])
  Transaction {
    ..transaction.placeholder,
    inputs: [state_in, request_input(), custody_in],
    outputs: [state_out, change],
    fee: 500_000,
    mint: if burn { from_asset(held_policy, held_name, -1) } else { zero },
    validity_range: interval.between(1_000, 5_000),
    withdrawals: if hook { [Pair(Script(consumer_pin), 0)] } else { [] },
    redeemers: [Pair(Spend(state_ref), modify)],
    extra_signatories: [],
  }
}

fn all_four(tx: Transaction) -> Bool {
  let action = Modify([UpdateAction([])])
  expect state.state.spend(Some(StateDatum(old_state())), action, state_ref, tx)
  expect
    request.request.spend(
      state_policy,
      token.assetName,
      Some(RequestDatum(retirement_request())),
      Contribute(state_ref),
      request_ref,
      tx,
    )
  expect consumer.consumer.withdraw(Hook, Script(consumer_pin), tx)
  let custody_redeemer: Data = 0
  retirement_custody.retirement_custody.spend(
    None,
    custody_redeemer,
    custody_ref,
    tx,
  )
}

test rootforeign_real_policy_positive_all_four_accept() {
  all_four(completion_context(real_rep_policy, rep_name(), True, True))
}

// The current bug witness: the authentic representative is under
// real_rep_policy, but every executing handler accepts a lookalike held and
// burned under an unrelated policy. No real representative-policy script runs.
test rootforeign_foreign_policy_lookalike_all_four_accept() {
  all_four(completion_context(foreign_policy, rep_name(), True, True))
}

test rootforeign_wrong_name_still_refuses() fail {
  all_four(completion_context(foreign_policy, #"7777", True, True))
}

test rootforeign_missing_burn_still_refuses() fail {
  all_four(completion_context(foreign_policy, rep_name(), False, True))
}

test rootforeign_missing_hook_still_refuses_at_state() fail {
  let tx = completion_context(foreign_policy, rep_name(), True, False)
  state.state.spend(
    Some(StateDatum(old_state())),
    Modify([UpdateAction([])]),
    state_ref,
    tx,
  )
}
