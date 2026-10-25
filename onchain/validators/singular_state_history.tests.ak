//// The history of a registry against the model's `HistoryStatements`: the live
//// supply of a key's token is one exactly when its leaf is active and never
//// more than one (`supply_in_step`, `one_live_token`), a token is burned only
//// by a fold of its registry that terminates the key
//// (`burn_only_terminating_fold`), and the token of a terminal key is never
//// minted again, by a fold of its registry or of another
//// (`no_remint_after_terminal`).
////
//// The statements quantify over every reachable world, so one property runs over
//// generated sequences of transactions against the real handlers of the state
//// validator, and reads all four statements in each world. A sequence opens with the creation of both registries, the registration of two
//// keys and the termination of one, then is a list of choices; each choice selects one
//// proposal of the world it finds (a registry is created, a request is made,
//// a termination is booked, a holding moves, requests are folded, or an
//// attacker's transaction that breaks one rule of the fold), the ledger rules
//// and the handlers decide, and an accepted proposal becomes the next world.
//// The supply, the burns and the mints are read after every accepted step, over
//// every registry and key; the last world of each run is read against the trie
//// library, and for the most live tokens of a key, which the supply of each step
//// implies. The
//// keys are three, with different first nibbles.
////
//// Each statement is also shown able to fail. A control runs a hand-written
//// sequence against a validator that waives its rules for one kind of attack,
//// and the statement the attack breaks must then fail; beside it the real
//// validator refuses the same attack and every statement holds. The scripted
//// runs also show the shapes the generator reaches: a fold that mixes
//// registrations and terminations, and the refusal of a registration of a
//// terminal key with the registration of the same key in a fresh registry
//// accepted.

use aiken/collection/list
use aiken/crypto.{blake2b_256}
use aiken/fuzz
use aiken/merkle_patricia_forestry/helpers.{nibble}
use cardano/transaction.{OutputReference, Transaction}
use singular_state
use singular_state/fold.{StateSpend}
use singular_state/genesis.{StateMint}
use singular_state_fixtures.{application_policy, state_policy}
use singular_state_fold_fixtures.{key_a, key_b, key_c}
use singular_state_history.{
  Active, BookTermination, BurnBesideRegistration, BurnOutsideFold,
  CreateRegistry, FoldBatch, Kind, MintTerminalKeyThroughAnotherRegistry,
  Outcome, Proposal, RegisterActiveKey, RegisterTerminalKey,
  RegisterWithTwoTokens, RequestRegistration, Terminal, TerminateKeepingToken,
  Want, allowed_attacks, at_most_one_live_token,
  burns_belong_to_terminating_folds, changes_of, choose, describe,
  folds_registrations, folds_terminations, initial_world, is_mixed_fold, leaf_of,
  live_supply, registry_at, rules_are_followed, run, run_script,
  runs_end_committed, scripts_accept, supply_follows_leaves,
  terminal_keys_are_never_minted_again, universe,
}

/// The mint handler of the state validator, run as the ledger runs it.
fn mint_handler(redeemer: StateMint, tx: Transaction) -> Bool {
  singular_state.singular_state.mint(
    application_policy,
    redeemer,
    state_policy,
    tx,
  )
}

/// The spend handler of the state validator, run as the ledger runs it.
fn spend_handler(
  datum: Option<Data>,
  redeemer: StateSpend,
  reference: OutputReference,
  tx: Transaction,
) -> Bool {
  singular_state.singular_state.spend(
    application_policy,
    datum,
    redeemer,
    reference,
    tx,
  )
}

/// The scripts of the proposal, run by the real handlers.
fn scripts(proposal: Proposal) -> Bool {
  scripts_accept(mint_handler, spend_handler, proposal)
}

/// A validator that waives its rules for one kind of proposal: its scripts
/// accept that kind whatever it carries.
fn waiving(kind: Kind) -> fn(Proposal) -> Bool {
  fn(proposal: Proposal) { proposal.kind == kind || scripts(proposal) }
}

fn sequences() -> Fuzzer<List<Int>> {
  fuzz.list_between(fuzz.int_between(0, 9999), 4, 4)
}

/// Every run opens the same way: both registries are created through genesis, the
/// first one folds the registrations of two keys, and the termination of one of
/// them is booked and folded. The steps a run has go to what the statements are
/// about, terminations, mints and burns, and an attack on a terminal key, in its
/// registry or through the other, has what it needs.
fn opening() -> List<Outcome> {
  run_script(
    scripts,
    initial_world(),
    [
      create(0),
      create(1),
      fold(0, [key_a, key_b]),
      book(0, key_a),
      fold(0, [key_a]),
    ],
  )
}

/// The opening, then the steps the choices select from the world it left.
fn history(choices: List<Int>) -> List<Outcome> {
  let started = opening()
  expect Some(last) = list.last(started)
  list.concat(started, run(scripts, last.after, choices))
}

/// Labels every step of a run, and the shape of every accepted fold, so the
/// table of a property run says what the sequences did.
fn labelled(outcomes: List<Outcome>) -> Bool {
  list.for_each(
    outcomes,
    fn(outcome) {
      fuzz.label(describe(outcome))
      fuzz.label_if(
        @"an accepted fold of registrations only",
        outcome.accepted && outcome.proposal.kind == FoldBatch && folds_registrations(
          outcome.proposal,
        ) && !folds_terminations(outcome.proposal),
      )
      fuzz.label_if(
        @"an accepted fold of terminations only",
        outcome.accepted && outcome.proposal.kind == FoldBatch && folds_terminations(
          outcome.proposal,
        ) && !folds_registrations(outcome.proposal),
      )
      fuzz.label_if(
        @"an accepted fold of both kinds",
        outcome.accepted && outcome.proposal.kind == FoldBatch && is_mixed_fold(
          outcome.proposal,
        ),
      )
    },
  )
  True
}

// ---------------------------------------------------------------------------
// The statements over generated sequences
// ---------------------------------------------------------------------------

fn supply(outcome: Outcome) -> Bool {
  supply_follows_leaves(outcome)
}

fn one_token(outcome: Outcome) -> Bool {
  at_most_one_live_token(outcome)
}

fn burns(outcome: Outcome) -> Bool {
  burns_belong_to_terminating_folds(outcome)
}

fn remint(outcome: Outcome) -> Bool {
  terminal_keys_are_never_minted_again(outcome)
}

fn all_statements(outcome: Outcome) -> Bool {
  and {
    supply(outcome),
    one_token(outcome),
    burns(outcome),
    remint(outcome),
  }
}

test prop_the_history_statements_hold_over_generated_worlds(
  choices via sequences(),
) {
  let outcomes = history(choices)
  and {
    labelled(outcomes),
    rules_are_followed(outcomes)?,
    list.all(outcomes, supply)?,
    list.all(outcomes, burns)?,
    list.all(outcomes, remint)?,
    runs_end_committed(outcomes)?,
  }
}

/// The keys the generator draws on begin with different nibbles, so every proof it
/// builds for a registration or a termination is one step long.
test the_keys_the_generator_draws_on_begin_with_different_nibbles() {
  let first = list.map(universe(), fn(key) { nibble(blake2b_256(key), 0) })
  list.length(first) >= 3 && list.length(list.unique(first)) == list.length(
    first,
  )
}

// ---------------------------------------------------------------------------
// Runs written by hand
// ---------------------------------------------------------------------------

fn want(kind: Kind, registry: Int, key: ByteArray) -> Want {
  Want { kind, registry, keys: [key] }
}

fn create(registry: Int) -> Want {
  Want { kind: CreateRegistry, registry, keys: [] }
}

fn request(registry: Int, key: ByteArray) -> Want {
  want(RequestRegistration, registry, key)
}

fn book(registry: Int, key: ByteArray) -> Want {
  want(BookTermination, registry, key)
}

/// A fold of the requests for these keys.
fn fold(registry: Int, keys: List<ByteArray>) -> Want {
  Want { kind: FoldBatch, registry, keys }
}

/// A registry that holds `key_a`.
fn registered() -> List<Want> {
  [create(0), fold(0, [key_a])]
}

/// The termination of `key_a` is booked.
fn booked() -> List<Want> {
  list.concat(registered(), [book(0, key_a)])
}

/// `key_a` is terminal.
fn terminated() -> List<Want> {
  list.concat(booked(), [fold(0, [key_a])])
}

/// The script ran to its end, and every proposal before the last was accepted.
fn run_of(
  decide: fn(Proposal) -> Bool,
  prefix: List<Want>,
  attack: Want,
) -> (List<Outcome>, Outcome) {
  let wants = list.concat(prefix, [attack])
  let outcomes = run_script(decide, initial_world(), wants)
  expect Some(last) = list.last(outcomes)
  expect list.length(outcomes) == list.length(wants)
  expect
    list.all(
      list.take(outcomes, list.length(prefix)),
      fn(outcome) { outcome.accepted },
    )
  (list.take(outcomes, list.length(prefix)), last)
}

/// The proposal carries the changes the attack is about: a termination for the
/// attack on a termination, registrations for the attacks on a registration, and
/// none for the burn outside a fold. A control whose attack is built over another
/// change would pass for the wrong reason.
fn is_the_attack_it_names(proposal: Proposal) -> Bool {
  when proposal.kind is {
    TerminateKeepingToken ->
      folds_terminations(proposal) && !folds_registrations(proposal)
    BurnOutsideFold -> changes_of(proposal) == []
    _ -> folds_registrations(proposal) && !folds_terminations(proposal)
  }
}

/// The world allows the attack, the real validator refuses it, the ledger's
/// rules held for it, and every statement holds before and after.
fn refused(prefix: List<Want>, attack: Want) -> Bool {
  let (before, last) = run_of(scripts, prefix, attack)
  and {
    list.has(allowed_attacks(last.before), attack.kind),
    is_the_attack_it_names(last.proposal),
    !last.accepted,
    last.lawful,
    list.all(before, all_statements),
    all_statements(last),
  }
}

/// A validator that waives its rules for the attack accepts it, the statement
/// held until then, and the statement fails.
fn waived(
  prefix: List<Want>,
  attack: Want,
  statement: fn(Outcome) -> Bool,
) -> Bool {
  let (before, last) = run_of(waiving(attack.kind), prefix, attack)
  and {
    is_the_attack_it_names(last.proposal),
    last.accepted,
    list.all(before, statement),
    !statement(last),
  }
}

// A fold that terminates a key burns its token.

test a_termination_that_keeps_the_token_is_refused() {
  refused(booked(), want(TerminateKeepingToken, 0, key_a))
}

test a_termination_that_keeps_the_token_breaks_the_supply_when_the_burn_is_waived() {
  waived(booked(), want(TerminateKeepingToken, 0, key_a), supply)
}

// A key has at most one token.

test a_registration_that_mints_two_tokens_is_refused() {
  refused([create(0)], want(RegisterWithTwoTokens, 0, key_a))
}

test a_registration_that_mints_two_tokens_leaves_two_live_when_the_mint_is_waived() {
  waived([create(0)], want(RegisterWithTwoTokens, 0, key_a), one_token)
}

test a_registration_of_a_key_that_is_active_is_refused() {
  refused(registered(), want(RegisterActiveKey, 0, key_a))
}

test a_registration_of_a_key_that_is_active_leaves_two_live_when_the_absence_is_waived() {
  waived(registered(), want(RegisterActiveKey, 0, key_a), one_token)
}

// A burn is a termination of a fold.

test a_burn_outside_a_fold_is_refused() {
  refused(registered(), want(BurnOutsideFold, 0, key_a))
}

test a_burn_outside_a_fold_is_a_burn_of_no_fold_when_the_mint_is_waived() {
  waived(registered(), want(BurnOutsideFold, 0, key_a), burns)
}

test a_burn_in_a_fold_that_terminates_nothing_is_refused() {
  refused(registered(), want(BurnBesideRegistration, 0, key_a))
}

test a_burn_in_a_fold_that_terminates_nothing_is_a_burn_of_no_termination_when_the_mint_is_waived() {
  waived(registered(), want(BurnBesideRegistration, 0, key_a), burns)
}

// The token of a terminal key is never minted again.

test a_registration_of_a_terminal_key_is_refused() {
  refused(terminated(), want(RegisterTerminalKey, 0, key_a))
}

test a_registration_of_a_terminal_key_is_a_remint_when_the_absence_is_waived() {
  waived(terminated(), want(RegisterTerminalKey, 0, key_a), remint)
}

test the_token_of_a_terminal_key_is_not_minted_in_the_fold_of_another_registry() {
  refused(
    list.concat(terminated(), [create(1)]),
    want(MintTerminalKeyThroughAnotherRegistry, 1, key_a),
  )
}

test the_token_of_a_terminal_key_is_a_remint_in_the_fold_of_another_registry_when_the_mint_is_waived() {
  waived(
    list.concat(terminated(), [create(1)]),
    want(MintTerminalKeyThroughAnotherRegistry, 1, key_a),
    remint,
  )
}

/// The control beside the refusal of a registration of a terminal key: the
/// same key registered in a fresh registry is accepted, and it is a token of
/// that registry's own. The key stays terminal in the registry that ended it.
test the_key_a_registry_ended_is_registered_in_a_fresh_registry() {
  let wants = list.concat(terminated(), [create(1), fold(1, [key_a])])
  let outcomes = run_script(scripts, initial_world(), wants)
  expect Some(last) = list.last(outcomes)
  let world = last.after
  and {
    list.length(outcomes) == list.length(wants),
    list.all(outcomes, fn(outcome) { outcome.accepted }),
    list.all(outcomes, all_statements),
    runs_end_committed(outcomes),
    leaf_of(registry_at(world, 0), key_a) == Terminal,
    leaf_of(registry_at(world, 1), key_a) == Active,
    live_supply(world, registry_at(world, 0), key_a) == 0,
    live_supply(world, registry_at(world, 1), key_a) == 1,
  }
}

/// A fold that terminates one key and registers another in one batch, over a
/// registry that holds a third: every key outside the changes keeps its token.
test a_fold_that_mixes_terminations_and_a_registration_keeps_every_other_token() {
  let wants =
    [
      create(0),
      fold(0, [key_a, key_b]),
      book(0, key_a),
      fold(0, [key_a, key_c]),
    ]
  let outcomes = run_script(scripts, initial_world(), wants)
  expect Some(last) = list.last(outcomes)
  let world = last.after
  let registry = registry_at(world, 0)
  and {
    list.length(outcomes) == list.length(wants),
    list.all(outcomes, fn(outcome) { outcome.accepted }),
    list.all(outcomes, all_statements),
    runs_end_committed(outcomes),
    is_mixed_fold(last.proposal),
    leaf_of(registry, key_a) == Terminal,
    leaf_of(registry, key_b) == Active,
    leaf_of(registry, key_c) == Active,
    live_supply(world, registry, key_a) == 0,
    live_supply(world, registry, key_b) == 1,
    live_supply(world, registry, key_c) == 1,
  }
}

/// A choice selects every kind of attack the world allows: the choices that name
/// the groups of attacks reach every kind, so the attacks the scripted worlds
/// allow are the attacks the generator proposes.
test a_choice_selects_every_kind_of_attack_the_world_allows() {
  let wants =
    [
      create(0),
      create(1),
      fold(0, [key_a, key_b]),
      book(0, key_a),
      fold(0, [key_a]),
      request(0, key_b),
      book(0, key_b),
    ]
  let outcomes = run_script(scripts, initial_world(), wants)
  expect Some(last) = list.last(outcomes)
  let world = last.after
  let allowed = allowed_attacks(world)
  let chosen =
    list.filter_map(
      list.range(0, 2 * list.length(allowed)),
      fn(pick) {
        when choose(world, pick * 3) is {
          Some(candidate) -> Some(candidate.kind)
          None -> None
        }
      },
    )
  and {
    list.length(outcomes) == list.length(wants),
    list.length(allowed) >= 5,
    list.length(list.unique(chosen)) == list.length(allowed),
    list.all(chosen, fn(kind) { list.has(allowed, kind) }),
  }
}
