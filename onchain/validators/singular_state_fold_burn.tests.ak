//// The burn of an active token under the state policy, against the model's
//// `burn_only_terminating_fold` and `termination_inversion`: the active token
//// of a key is burned only by a fold of the registry it belongs to that
//// terminates that key.
////
//// The ledger runs the mint handler once for the state policy and the spend
//// handler once for each state input the transaction spends; a transaction is
//// valid when all of them accept. Each refusal row is a transaction whose
//// handlers do not all accept, beside the accepted termination fold that
//// differs from it in the one part named.

use aiken/builtin
use aiken/collection/list
use cardano/assets.{add, from_lovelace, merge}
use cardano/transaction.{Input, Output, OutputReference, Transaction}
use singular_state
use singular_state/fold.{StateSpend}
use singular_state/genesis.{Folded, Genesis, StateMint}
use singular_state/preimage.{RegistryIdentity, active_token_name}
use singular_state_fixtures.{
  application_policy, genesis_transaction, ordinary_output, seed_a, seed_b,
  state_policy,
}
use singular_state_fold_fixtures.{
  funding_reference, key_a, key_b, key_c, key_d, key_e, registration_c,
  registry_of, state_reference,
}
use singular_state_termination_fixtures.{
  Held, Mixed, Registering, Terminating, active, redeemer_mixed, state_input_of,
  termination_a, termination_b, termination_c, termination_input,
  transaction_mixed,
}

fn registry_a() -> RegistryIdentity {
  registry_of(seed_a)
}

const state_reference_b: OutputReference =
  OutputReference {
    transaction_id: #"5354415445420000000000000000000000000000000000000000000000000000",
    output_index: 4,
  }

fn spend(
  redeemer: StateSpend,
  own_reference: OutputReference,
  tx: Transaction,
) -> Bool {
  singular_state.singular_state.spend(
    application_policy,
    Some(builtin.i_data(0)),
    redeemer,
    own_reference,
    tx,
  )
}

fn mint(redeemer: StateMint, tx: Transaction) -> Bool {
  singular_state.singular_state.mint(
    application_policy,
    redeemer,
    state_policy,
    tx,
  )
}

/// The verdict of the ledger on a transaction that mints under the state
/// policy and spends the state of registry A with `redeemer_a`: the mint handler
/// accepts the `Folded` redeemer and the spend handler accepts the fold.
fn ledger_accepts(redeemer_a: StateSpend, tx: Transaction) -> Bool {
  mint(Folded, tx) && spend(redeemer_a, state_reference, tx)
}

// ---------------------------------------------------------------------------
// The accepted burn
// ---------------------------------------------------------------------------

fn before_a() -> List<Held> {
  [active(key_a), active(key_b), active(key_d)]
}

fn terminate_a() -> Mixed {
  Mixed {
    seed: seed_a,
    before: before_a(),
    steps: [Terminating(termination_a())],
  }
}

fn terminate_b() -> Mixed {
  Mixed {
    seed: seed_a,
    before: before_a(),
    steps: [Terminating(termination_b())],
  }
}

test the_active_token_is_burned_by_the_fold_of_its_registry_that_terminates_its_key() {
  ledger_accepts(
    redeemer_mixed(terminate_a()),
    transaction_mixed(terminate_a()),
  )
}

// ---------------------------------------------------------------------------
// burn-only-in-own-fold: a burn in a transaction that spends no state of the
// registry
// ---------------------------------------------------------------------------

fn without_state_input(tx: Transaction) -> Transaction {
  Transaction {
    ..tx,
    inputs: list.filter(
      tx.inputs,
      fn(input) { input.output_reference != state_reference },
    ),
  }
}

test a_burn_in_a_transaction_that_spends_no_state_is_refused() {
  let tx = transaction_mixed(terminate_a())
  ledger_accepts(redeemer_mixed(terminate_a()), tx) && !mint(
    Folded,
    without_state_input(tx),
  )
}

/// A transaction that spends the seed of registry A and creates its state, the
/// shape of genesis, and burns the active token of `key_a` held in an input.
fn genesis_that_burns() -> Transaction {
  let tx = genesis_transaction(state_policy, seed_a)
  let holder = termination_input(registry_a(), termination_a())
  Transaction {
    ..tx,
    inputs: list.concat(tx.inputs, [holder]),
    mint: add(tx.mint, state_policy, active_token_name(registry_a(), key_a), -1),
  }
}

test a_burn_in_a_genesis_transaction_is_refused() {
  mint(Genesis { seed: seed_a }, genesis_transaction(state_policy, seed_a)) && !mint(
    Genesis { seed: seed_a },
    genesis_that_burns(),
  ) && !mint(Folded, genesis_that_burns())
}

// ---------------------------------------------------------------------------
// burn-only-in-own-fold: a burn in the fold of another registry
// ---------------------------------------------------------------------------

/// An input of the burner that holds the active token of `key` in `registry`.
fn holder_of(registry: RegistryIdentity, key: ByteArray, index: Int) -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: #"484f4c4445520000000000000000000000000000000000000000000000000000",
      output_index: index,
    },
    output: Output {
      ..ordinary_output,
      value: from_lovelace(2_000_000)
        |> add(registry.policy, active_token_name(registry, key), 1),
    },
  }
}

fn burning(
  tx: Transaction,
  registry: RegistryIdentity,
  key: ByteArray,
) -> Transaction {
  Transaction {
    ..tx,
    inputs: list.concat(tx.inputs, [holder_of(registry, key, 0)]),
    mint: add(tx.mint, registry.policy, active_token_name(registry, key), -1),
  }
}

/// A fold of registry B: the state of B is spent at the reference of A's state in
/// these fixtures, so the fold is built for the seed of B and spent as the state
/// input of the transaction.
fn fold_of_b() -> Mixed {
  Mixed {
    seed: seed_b,
    before: [active(key_c), active(key_e)],
    steps: [Terminating(termination_c())],
  }
}

test a_burn_of_a_token_of_another_registry_in_a_fold_is_refused() {
  let tx = transaction_mixed(fold_of_b())
  let redeemer = redeemer_mixed(fold_of_b())
  ledger_accepts(redeemer, tx) && !ledger_accepts(
    redeemer,
    burning(tx, registry_a(), key_a),
  )
}

fn both_registries() -> Transaction {
  let a = transaction_mixed(terminate_a())
  let b = transaction_mixed(fold_of_b())
  let state_b = state_input_of(seed_b, [active(key_c), active(key_e)])
  Transaction {
    ..a,
    inputs: list.concat(
      a.inputs,
      [
        Input { ..state_b, output_reference: state_reference_b },
        ..list.filter(
          b.inputs,
          fn(input) {
            input.output_reference != funding_reference && input.output_reference != state_reference
          },
        )
      ],
    ),
    outputs: list.concat(
      a.outputs,
      list.filter(b.outputs, fn(output) { output != ordinary_output }),
    ),
    mint: merge(a.mint, b.mint),
  }
}

test two_folds_of_two_registries_in_one_transaction_are_refused() {
  let tx = both_registries()
  let redeemer_a = redeemer_mixed(terminate_a())
  let redeemer_b = redeemer_mixed(fold_of_b())
  ledger_accepts(redeemer_a, transaction_mixed(terminate_a())) && ledger_accepts(
    redeemer_b,
    transaction_mixed(fold_of_b()),
  ) && !(mint(Folded, tx) && spend(redeemer_a, state_reference, tx) && spend(
    redeemer_b,
    state_reference_b,
    tx,
  ))
}

// ---------------------------------------------------------------------------
// burn-only-in-own-fold: a burn in a fold whose changes do not terminate the key
// ---------------------------------------------------------------------------

test a_fold_that_terminates_another_key_does_not_burn_this_one() {
  let tx = transaction_mixed(terminate_b())
  let redeemer = redeemer_mixed(terminate_b())
  ledger_accepts(redeemer, tx) && !ledger_accepts(
    redeemer,
    burning(tx, registry_a(), key_a),
  )
}

fn registers_c() -> Mixed {
  Mixed {
    seed: seed_a,
    before: before_a(),
    steps: [Registering(registration_c())],
  }
}

test a_fold_that_registers_a_key_does_not_burn_another() {
  let tx = transaction_mixed(registers_c())
  let redeemer = redeemer_mixed(registers_c())
  ledger_accepts(redeemer, tx) && !ledger_accepts(
    redeemer,
    burning(tx, registry_a(), key_a),
  )
}

test a_fold_that_terminates_a_key_does_not_burn_a_second_token_of_it() {
  let tx = transaction_mixed(terminate_a())
  let redeemer = redeemer_mixed(terminate_a())
  ledger_accepts(redeemer, tx) && !ledger_accepts(
    redeemer,
    burning(tx, registry_a(), key_a),
  )
}

test a_fold_that_names_the_key_but_does_not_burn_its_token_is_refused() {
  let tx = transaction_mixed(terminate_a())
  let redeemer = redeemer_mixed(terminate_a())
  ledger_accepts(redeemer, tx) && !ledger_accepts(
    redeemer,
    Transaction {
      ..tx,
      mint: add(
        tx.mint,
        registry_a().policy,
        active_token_name(registry_a(), key_a),
        1,
      ),
    },
  )
}
