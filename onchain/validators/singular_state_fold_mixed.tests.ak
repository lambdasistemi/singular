//// A fold that carries registrations and terminations of distinct keys, against
//// the model's `batch_inversion`, `batch_effects` and `fold_untouched_keys`: the
//// changes apply in order to the trie before, the whole mint of the state policy
//// is one token for each registration and the burn of one for each termination,
//// no key is named twice, and every key outside the changes keeps its leaf.
////
//// The accepted folds cover both orders and several sizes, and a generated scan
//// draws distinct keys in any order over every starting state of a key. A key
//// named twice, in any pair of kinds, is refused.

use aiken/builtin
use aiken/collection/list
use aiken/fuzz
use aiken/merkle_patricia_forestry as mpf
use aiken/primitive/int
use cardano/assets.{quantity_of}
use cardano/transaction.{Output, Transaction}
use singular_state
use singular_state/fold.{StateSpend, change_batch, fold_whole_policy}
use singular_state/genesis.{Folded}
use singular_state/preimage.{RegistryIdentity, active_token_name}
use singular_state_fixtures.{
  application_policy, root_datum, seed_a, state_policy,
}
use singular_state_fold_fixtures.{
  key_a, key_b, key_c, key_d, key_e, key_f, registration_a, registration_b,
  registration_c, registration_d, registry_of, state_reference,
}
use singular_state_termination_fixtures.{
  Held, Mixed, Registering, Step, Terminating, Termination, active,
  after_termination, changes_of_mixed, held_after, key_n, key_o, key_t, key_u,
  key_v, key_w, key_x, key_y, key_z, proof_for, redeemer_mixed, registering,
  registration_e, registration_f, root_of_held, terminal, terminating,
  termination_a, termination_b, termination_c, termination_d, termination_e,
  termination_f, transaction_mixed, trie_of_held,
}

fn registry() -> RegistryIdentity {
  registry_of(seed_a)
}

fn spend(redeemer: StateSpend, tx: Transaction) -> Bool {
  singular_state.singular_state.spend(
    application_policy,
    Some(builtin.i_data(0)),
    redeemer,
    state_reference,
    tx,
  )
}

/// The verdict of the ledger on the fold: the mint handler accepts the fold's
/// mint and the spend handler accepts the fold.
fn folds(mixed: Mixed) -> Bool {
  singular_state.singular_state.mint(
    application_policy,
    Folded,
    state_policy,
    transaction_mixed(mixed),
  ) && spend(redeemer_mixed(mixed), transaction_mixed(mixed))
}

fn fold_of(before: List<Held>, steps: List<Step>) -> Mixed {
  Mixed { seed: seed_a, before, steps }
}

// ---------------------------------------------------------------------------
// mixed-batch: the accepted folds
// ---------------------------------------------------------------------------

/// A trie whose keys share prefixes: three levels of nodes, two children at
/// some and more at others.
fn deep_before() -> List<Held> {
  [
    active(key_t),
    active(key_v),
    active(key_w),
    active(key_x),
    active(key_u),
    active(key_y),
    active(key_z),
  ]
}

/// Terminations and registrations of keys whose paths share prefixes with each
/// other and with the keys already held; the second registration lands beside
/// the first.
fn deep_steps() -> List<Step> {
  [
    Terminating(terminating(key_t, 1)),
    Registering(registering(key_n, 2)),
    Terminating(terminating(key_w, 3)),
    Registering(registering(key_o, 4)),
    Terminating(terminating(key_z, 5)),
  ]
}

fn orders() -> List<Mixed> {
  [
    fold_of(deep_before(), deep_steps()),
    fold_of(deep_before(), list.reverse(deep_steps())),
    fold_of(
      [active(key_a)],
      [Terminating(termination_a()), Registering(registration_e())],
    ),
    fold_of(
      [active(key_a)],
      [Registering(registration_e()), Terminating(termination_a())],
    ),
    fold_of(
      [active(key_a), active(key_b)],
      [
        Registering(registration_c()),
        Registering(registration_e()),
        Terminating(termination_a()),
        Terminating(termination_b()),
      ],
    ),
    fold_of(
      [active(key_a), active(key_b)],
      [
        Terminating(termination_a()),
        Terminating(termination_b()),
        Registering(registration_c()),
        Registering(registration_e()),
      ],
    ),
    fold_of(
      [active(key_a), active(key_b), active(key_d)],
      [
        Terminating(termination_a()),
        Registering(registration_c()),
        Terminating(termination_b()),
        Registering(registration_e()),
        Terminating(termination_d()),
      ],
    ),
    fold_of(
      [active(key_a), terminal(key_b), active(key_d)],
      [
        Registering(registration_f()),
        Terminating(termination_d()),
        Registering(registration_c()),
      ],
    ),
  ]
}

test a_fold_of_registrations_and_terminations_of_distinct_keys_is_accepted_in_either_order() {
  list.all(orders(), folds)
}

test the_state_policy_mint_is_one_token_for_each_registration_and_the_burn_of_one_for_each_termination() {
  list.all(
    orders(),
    fn(mixed) {
      let tx = transaction_mixed(mixed)
      let changes = changes_of_mixed(mixed)
      fold_whole_policy(registry(), changes, tx.mint) && list.all(
        mixed.steps,
        fn(step) {
          when step is {
            Registering(registration) ->
              quantity_of(
                tx.mint,
                registry().policy,
                active_token_name(registry(), registration.key),
              ) == 1
            Terminating(termination) ->
              quantity_of(
                tx.mint,
                registry().policy,
                active_token_name(registry(), termination.key),
              ) == -1
          }
        },
      )
    },
  )
}

test a_fold_that_carries_both_kinds_changes_only_the_leaves_it_names() {
  list.all(
    orders(),
    fn(mixed) {
      let tx = transaction_mixed(mixed)
      let changes = changes_of_mixed(mixed)
      let after = held_after(mixed.before, mixed.steps)
      when
        change_batch(
          application_policy,
          registry(),
          tx,
          trie_of_held(mixed.before),
          changes,
        )
      is {
        Some(trie) ->
          mpf.root(trie) == root_of_held(after) && list.all(
            after,
            fn(each) {
              mpf.has(trie, each.key, each.leaf, proof_for(after, each.key))
            },
          ) && list.all(
            mixed.before,
            fn(each) { named(mixed.steps, each.key) || list.has(after, each) },
          )
        None -> False
      }
    },
  )
}

fn named(steps: List<Step>, key: ByteArray) -> Bool {
  list.any(
    steps,
    fn(step) {
      when step is {
        Registering(registration) -> registration.key == key
        Terminating(termination) -> termination.key == key
      }
    },
  )
}

// ---------------------------------------------------------------------------
// mixed-batch: a key named twice is refused
// ---------------------------------------------------------------------------

fn again(termination: Termination) -> Termination {
  Termination {
    ..termination,
    request: singular_state_fold_fixtures.request_reference(30),
  }
}

test the_same_key_terminated_twice_is_refused() {
  folds(fold_of([active(key_a), active(key_b)], [Terminating(termination_a())])) && !folds(
    fold_of(
      [active(key_a), active(key_b)],
      [Terminating(termination_a()), Terminating(again(termination_a()))],
    ),
  )
}

test a_key_registered_and_terminated_in_one_fold_is_refused() {
  folds(
    fold_of(
      [active(key_a)],
      [Registering(registration_e()), Terminating(termination_a())],
    ),
  ) && !folds(
    fold_of(
      [active(key_a)],
      [Registering(registration_e()), Terminating(termination_e())],
    ),
  )
}

test a_key_terminated_and_registered_in_one_fold_is_refused() {
  folds(
    fold_of(
      [active(key_a)],
      [Terminating(termination_a()), Registering(registration_e())],
    ),
  ) && !folds(
    fold_of(
      [active(key_a)],
      [Terminating(termination_a()), Registering(registration_a())],
    ),
  )
}

test a_key_named_twice_is_refused_among_changes_of_other_keys() {
  let others = [Registering(registration_c()), Terminating(termination_b())]
  let before = [active(key_a), active(key_b)]
  folds(fold_of(before, list.concat(others, [Terminating(termination_a())]))) && !folds(
    fold_of(
      before,
      list.concat(
        others,
        [Terminating(termination_a()), Terminating(again(termination_a()))],
      ),
    ),
  ) && !folds(
    fold_of(
      before,
      list.concat(
        [Terminating(termination_a())],
        list.concat(others, [Registering(registration_a())]),
      ),
    ),
  )
}

// ---------------------------------------------------------------------------
// mixed-batch: every key outside the changes keeps its leaf
// ---------------------------------------------------------------------------

fn with_state_root(tx: Transaction, root: ByteArray) -> Transaction {
  Transaction {
    ..tx,
    outputs: list.indexed_map(
      tx.outputs,
      fn(at, output) {
        if at == 1 {
          Output { ..output, datum: root_datum(root) }
        } else {
          output
        }
      },
    ),
  }
}

test a_fold_whose_root_changes_the_leaf_of_a_key_it_does_not_name_is_refused() {
  let mixed =
    fold_of(
      [active(key_a), active(key_b), active(key_d)],
      [Terminating(termination_a()), Registering(registration_c())],
    )
  let tx = transaction_mixed(mixed)
  let redeemer = redeemer_mixed(mixed)
  let expected = held_after(mixed.before, mixed.steps)
  spend(redeemer, tx) && list.all(
    [
      // an untouched key terminated as well
      list.map(
        expected,
        fn(each) {
          if each.key == key_b {
            terminal(key_b)
          } else {
            each
          }
        },
      ),
      // an untouched key dropped
      list.filter(expected, fn(each) { each.key != key_d }),
      // an untouched key bound to a leaf of no meaning
      list.map(
        expected,
        fn(each) {
          if each.key == key_d {
            Held { key: key_d, leaf: #"03" }
          } else {
            each
          }
        },
      ),
      // the key registered now left terminal
      // and the key terminated now left active
      after_termination(expected, key_c),
      list.map(
        expected,
        fn(each) {
          if each.key == key_a {
            active(key_a)
          } else {
            each
          }
        },
      ),
    ],
    fn(held) { !spend(redeemer, with_state_root(tx, root_of_held(held))) },
  )
}

// ---------------------------------------------------------------------------
// mixed-batch: generated folds of distinct keys
// ---------------------------------------------------------------------------

/// What happens to each of the six keys: it is absent and stays absent, it is
/// active and stays active, it is terminal and stays terminal, it is absent and
/// registered now, or it is active and terminated now.
type Fate {
  Absent
  Stays
  Ended
  Registered
  Terminated
}

fn fate_fuzzer() -> Fuzzer<Fate> {
  fuzz.one_of([Absent, Stays, Ended, Registered, Terminated])
}

fn keys() -> List<ByteArray> {
  [key_a, key_b, key_c, key_d, key_e, key_f]
}

fn registration_for(key: ByteArray) -> Step {
  expect Some(registration) =
    list.find(
      [
        registration_a(),
        registration_b(),
        registration_c(),
        registration_d(),
        registration_e(),
        registration_f(),
      ],
      fn(registration) { registration.key == key },
    )
  Registering(registration)
}

fn termination_for(key: ByteArray) -> Step {
  expect Some(termination) =
    list.find(
      [
        termination_a(),
        termination_b(),
        termination_c(),
        termination_d(),
        termination_e(),
        termination_f(),
      ],
      fn(termination) { termination.key == key },
    )
  Terminating(termination)
}

fn before_of(key: ByteArray, fate: Fate) -> List<Held> {
  when fate is {
    Absent -> []
    Stays -> [active(key)]
    Ended -> [terminal(key)]
    Registered -> []
    Terminated -> [active(key)]
  }
}

fn step_of(key: ByteArray, fate: Fate) -> List<Step> {
  when fate is {
    Registered -> [registration_for(key)]
    Terminated -> [termination_for(key)]
    _ -> []
  }
}

/// The weighted changes in the order of their weights.
fn ordered(weighted: List<(Int, List<Step>)>) -> List<Step> {
  list.flat_map(
    list.sort(weighted, fn(left, right) { int.compare(left.1st, right.1st) }),
    fn(each) { each.2nd },
  )
}

fn zip3(
  keys: List<ByteArray>,
  fates: List<Fate>,
  weights: List<Int>,
) -> List<(ByteArray, Fate, Int)> {
  when (keys, fates, weights) is {
    ([key, ..more_keys], [fate, ..more_fates], [weight, ..more_weights]) ->
      [(key, fate, weight), ..zip3(more_keys, more_fates, more_weights)]
    _ -> []
  }
}

fn mixed_from(fates: List<Fate>, weights: List<Int>) -> Mixed {
  let cases = zip3(keys(), fates, weights)
  fold_of(
    list.flat_map(cases, fn(each) { before_of(each.1st, each.2nd) }),
    ordered(
      list.map(cases, fn(each) { (each.3rd, step_of(each.1st, each.2nd)) }),
    ),
  )
}

test prop_a_fold_of_distinct_keys_in_any_order_is_accepted(
  case via fuzz.tuple(
    fuzz.list_between(fate_fuzzer(), 6, 6),
    fuzz.list_between(fuzz.int_between(0, 1000), 6, 6),
  ),
) {
  let (fates, weights) = case
  let mixed = mixed_from(fates, weights)
  mixed.steps == [] || folds(mixed)
}

test prop_a_fold_that_names_a_key_twice_is_refused(
  case via fuzz.tuple(
    fuzz.list_between(fate_fuzzer(), 6, 6),
    fuzz.list_between(fuzz.int_between(0, 1000), 6, 6),
  ),
) {
  let (fates, weights) = case
  let mixed = mixed_from(fates, weights)
  when mixed.steps is {
    [] -> True
    [first, ..rest] -> {
      let doubled = list.concat([first], list.concat([first], rest))
      folds(mixed) && !folds(Mixed { ..mixed, steps: doubled })
    }
  }
}
