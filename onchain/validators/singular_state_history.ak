//// Generated worlds of the Singular state validator, for the history statements.
////
//// A world is a set of unspent outputs, the registries created in it and the
//// requests that wait for a fold. A step proposes one transaction against it,
//// the ledger rules and the real handlers of `singular_state` decide, and an
//// accepted transaction becomes the next world: its inputs leave the unspent
//// set and its outputs enter it with fresh references. A refused proposal
//// leaves the world as it was.
////
//// What the statements read is the world itself. The live supply of a key's
//// token is counted over every unspent output; the leaf of a key is read from
//// the leaves the world keeps for its registry, which the state output of the last
//// world of a run must commit to, with the root the trie library computes; a burn
//// or a mint is read from the mint of the transaction.
////
//// The proposals are the rules' own transactions (a registry is created, a request
//// is made, a termination is booked, a holding moves, a batch of requests is
//// folded) and, beside them, the transactions an attacker would try: the ones
//// that break exactly one rule of a fold.
////
//// Not modelled: lovelace. Every proposal conserves every other asset, which
//// is what the supply of a token depends on, and the world checks it.

use aiken/collection/list
use aiken/primitive/bytearray
use aiken/primitive/string
use cardano/address.{Script, from_script}
use cardano/assets.{
  AssetName, Value, add, flatten, from_asset, from_lovelace, merge, policies,
  quantity_of, without_lovelace, zero,
}
use cardano/transaction.{
  Input, NoDatum, Output, OutputReference, Transaction, TransactionId,
}
use singular_state/fold.{
  Change, Fold, Register, StateSpend, Terminate, application_datum, leaf_active,
}
use singular_state/genesis.{Folded, Genesis, StateMint}
use singular_state/preimage.{
  RegistryIdentity, active_token_name, state_token_name,
}
use singular_state_fixtures.{
  application_policy, genuine_output, ordinary_output, root_datum, spent,
  state_policy,
}
use singular_state_fold_fixtures.{
  Registration, approval_of, holding_output, holding_script_b, key_a, key_b,
  key_c, registry_of, request_input, state_lovelace,
}
use singular_state_termination_fixtures.{
  Held, Mixed, Registering, Step, Terminating, Termination, built_root_of,
  held_after, key_t, key_v, minted_mixed, redeemer_mixed, registering,
  root_of_held, termination_approval_of, termination_input,
}

// ---------------------------------------------------------------------------
// The world
// ---------------------------------------------------------------------------

/// What a trie says about a key.
pub type Leaf {
  Active
  Terminal
  Absent
}

/// A registry of the world: the seed that names it, the output that carries
/// its state token now, the leaves its trie holds, and the name of the token of
/// each key, as the producer names it, found once when the registry is created.
pub type Registry {
  seed: OutputReference,
  state: OutputReference,
  held: List<Held>,
  names: List<(ByteArray, AssetName)>,
}

/// A request that waits for a fold, with the index of the registry it names.
pub type Pending {
  registry: Int,
  step: Step,
}

/// The unspent outputs, the registries, the requests waiting and the number of
/// transactions accepted so far.
pub type World {
  unspent: List<Input>,
  registries: List<Registry>,
  pending: List<Pending>,
  used: Int,
}

const initial_transaction: TransactionId =
  #"c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0"

/// The output the registry at `index` is created from: plain outputs the world
/// starts with, the first ones, one for each registry the world can create.
fn seed_reference(index: Int) -> OutputReference {
  OutputReference { transaction_id: initial_transaction, output_index: index }
}

/// The registration of `key` in the registry created from the seed at `index`
/// that the world starts with a request for.
fn first_registration(
  index: Int,
  position: Int,
  key: ByteArray,
  copy: Int,
) -> Registration {
  let number =
    ( copy * most_registries + index ) * list.length(universe()) + position
  Registration {
    ..registering(key, number),
    request: OutputReference {
      transaction_id: initial_transaction,
      output_index: 100 + number,
    },
  }
}

/// The requests the world starts with: for each registry it can create, one
/// registration of each key, and a second one of the first key that stays
/// behind once the first is folded, so a registration of a key that is active or
/// terminal is there to be tried. The application made them before any registry
/// existed; they carry tokens of its own policy only.
fn first_requests() -> List<Pending> {
  list.flat_map(
    list.range(0, most_registries - 1),
    fn(index) {
      list.flat_map(
        list.indexed_map(
          universe(),
          fn(position, key) {
            list.map(
              if position < 1 {
                [0, 1]
              } else {
                [0]
              },
              fn(copy) {
                Pending {
                  registry: index,
                  step: Registering(
                    first_registration(index, position, key, copy),
                  ),
                }
              },
            )
          },
        ),
        fn(requests) { requests },
      )
    },
  )
}

/// The world before anything is created: plain outputs, and for each registry the
/// world can create one registration request of each key and a second one of the
/// first key.
pub fn initial_world() -> World {
  World {
    unspent: list.concat(
      list.map(list.range(0, 2), fn(index) { spent(seed_reference(index)) }),
      list.map(
        first_requests(),
        fn(each) {
          when each.step is {
            Registering(registration) ->
              request_input(
                registry_of(seed_reference(each.registry)),
                registration,
              )
            Terminating(_) -> fail
          }
        },
      ),
    ),
    registries: [],
    pending: first_requests(),
    used: 0,
  }
}

/// The keys the proposals draw on: `key_a` and `key_t` share the first nibble of
/// their hashes, `key_t` and `key_v` share three, and `key_b` and `key_c` share
/// none with them, so the tries of a run have nodes below the root, and proofs of
/// several steps with leaf steps among them.
pub fn universe() -> List<ByteArray> {
  [key_a, key_t, key_v, key_b, key_c]
}

/// The most registries a world creates.
const most_registries: Int = 2

fn fresh_id(world: World) -> TransactionId {
  bytearray.from_int_big_endian(world.used + 1, 32)
}

/// The registry of the world at `index`.
pub fn registry_at(world: World, index: Int) -> Registry {
  expect Some(registry) = list.at(world.registries, index)
  registry
}

/// The names of the tokens of the keys of the universe in the registry the seed
/// creates.
fn names_for(seed: OutputReference) -> List<(ByteArray, AssetName)> {
  let identity = registry_of(seed)
  list.map(universe(), fn(key) { (key, active_token_name(identity, key)) })
}

/// The name of the token of `key` in `registry`.
fn name_in(registry: Registry, key: ByteArray) -> AssetName {
  expect Some((_, name)) =
    list.find(registry.names, fn(pair) { pair.1st == key })
  name
}

/// The identity of the registry the seed names.
pub fn identity_of(registry: Registry) -> RegistryIdentity {
  registry_of(registry.seed)
}

/// What the trie of `registry` says about `key`.
pub fn leaf_of(registry: Registry, key: ByteArray) -> Leaf {
  when list.find(registry.held, fn(each) { each.key == key }) is {
    Some(Held { leaf, .. }) ->
      if leaf == leaf_active {
        Active
      } else {
        Terminal
      }
    None -> Absent
  }
}

fn input_at(world: World, reference: OutputReference) -> Input {
  expect Some(input) =
    list.find(world.unspent, fn(each) { each.output_reference == reference })
  input
}

fn is_plain(input: Input) -> Bool {
  and {
    input.output.datum == NoDatum,
    list.length(policies(input.output.value)) == 1,
  }
}

/// The output that pays for a transaction: a plain output that is not the seed
/// of a registry still to be created.
fn funding_of(world: World) -> Input {
  expect Some(input) =
    list.find(
      world.unspent,
      fn(input) {
        and {
          is_plain(input),
          !is_seed(input.output_reference),
        }
      },
    )
  input
}

fn is_seed(reference: OutputReference) -> Bool {
  list.any(
    list.range(0, most_registries - 1),
    fn(index) { seed_reference(index) == reference },
  )
}

/// Every token of the state policy in the unspent outputs: its name, its
/// quantity and the output that holds it. One pass over the unspent set serves
/// every lookup of a step.
fn state_tokens(world: World) -> List<(AssetName, Int, Input)> {
  list.flat_map(
    world.unspent,
    fn(input) {
      list.filter_map(
        flatten(input.output.value),
        fn(entry) {
          if entry.1st == state_policy {
            Some((entry.2nd, entry.3rd, input))
          } else {
            None
          }
        },
      )
    },
  )
}

/// The first unspent output that carries the token of `key` in `registry`.
fn holder_in(
  tokens: List<(AssetName, Int, Input)>,
  registry: Registry,
  key: ByteArray,
) -> Option<Input> {
  let name = name_in(registry, key)
  when list.find(tokens, fn(entry) { entry.1st == name }) is {
    Some((_, _, input)) -> Some(input)
    None -> None
  }
}

fn key_of_step(step: Step) -> ByteArray {
  when step is {
    Registering(registration) -> registration.key
    Terminating(termination) -> termination.key
  }
}

fn request_of_step(step: Step) -> OutputReference {
  when step is {
    Registering(registration) -> registration.request
    Terminating(termination) -> termination.request
  }
}

fn is_pending(world: World, index: Int, key: ByteArray) -> Bool {
  list.any(
    world.pending,
    fn(each) { each.registry == index && key_of_step(each.step) == key },
  )
}

/// Whether a termination of `key` waits in the registry at `index`.
fn is_terminating(world: World, index: Int, key: ByteArray) -> Bool {
  list.any(
    world.pending,
    fn(each) {
      and {
        each.registry == index,
        key_of_step(each.step) == key,
        !is_registration(each.step),
      }
    },
  )
}

/// Whether the request can be folded now: a registration for a key that is
/// absent, a termination for a key that is active.
fn is_foldable(registry: Registry, step: Step) -> Bool {
  when step is {
    Registering(registration) -> leaf_of(registry, registration.key) == Absent
    Terminating(termination) -> leaf_of(registry, termination.key) == Active
  }
}

/// The requests of the registry at `index` that can be folded now, in the
/// order they were made; of two requests for one key, the earlier.
fn waiting(world: World, index: Int) -> List<Step> {
  let registry = registry_at(world, index)
  list.foldl(
    world.pending,
    [],
    fn(each, kept) {
      if each.registry == index && is_foldable(registry, each.step) && !list.any(
        kept,
        fn(step) { key_of_step(step) == key_of_step(each.step) },
      ) {
        list.concat(kept, [each.step])
      } else {
        kept
      }
    },
  )
}

fn registrations_waiting(world: World, index: Int) -> List<Step> {
  list.filter(
    waiting(world, index),
    fn(step) {
      when step is {
        Registering(_) -> True
        Terminating(_) -> False
      }
    },
  )
}

// ---------------------------------------------------------------------------
// Proposals
// ---------------------------------------------------------------------------

/// What a proposal is. The first five follow the rules; the others are the
/// transactions an attacker tries, each one breaking one rule of the fold.
pub type Kind {
  CreateRegistry
  RequestRegistration
  BookTermination
  MoveHolding
  FoldBatch
  TerminateKeepingToken
  RegisterWithTwoTokens
  RegisterActiveKey
  RegisterTerminalKey
  BurnOutsideFold
  BurnBesideRegistration
  MintTerminalKeyThroughAnotherRegistry
}

/// Whether the kind is an attack.
pub fn is_attack(kind: Kind) -> Bool {
  when kind is {
    CreateRegistry -> False
    RequestRegistration -> False
    BookTermination -> False
    MoveHolding -> False
    FoldBatch -> False
    _ -> True
  }
}

/// The name of a kind, for the tables the property runs print.
pub fn name_of(kind: Kind) -> String {
  when kind is {
    CreateRegistry -> @"create a registry"
    RequestRegistration -> @"request a registration"
    BookTermination -> @"book a termination"
    MoveHolding -> @"move a holding"
    FoldBatch -> @"fold a batch of requests"
    TerminateKeepingToken -> @"terminate a key and keep its token"
    RegisterWithTwoTokens -> @"register a key with two tokens"
    RegisterActiveKey -> @"register a key that is active"
    RegisterTerminalKey -> @"register a key that is terminal"
    BurnOutsideFold -> @"burn a token outside a fold"
    BurnBesideRegistration -> @"burn a token in a registration fold"
    MintTerminalKeyThroughAnotherRegistry ->
      @"mint a terminal key's token in another registry's fold"
  }
}

/// A choice among the proposals a world allows: the kind, the registry it is
/// about, the key it is about, the registry that holds the terminal key when
/// the proposal mints its token elsewhere, and, of a fold, the keys of the
/// requests it folds.
pub type Candidate {
  kind: Kind,
  registry: Int,
  key: ByteArray,
  other: Int,
  keys: List<ByteArray>,
}

/// What an accepted proposal does to the registries and the requests waiting.
pub type Effect {
  Unchanged
  Created(Registry)
  Advanced(Int, List<Held>)
  Requested(Pending)
}

/// A transaction proposed against a world, with the redeemers the ledger
/// would hand the state script and what it does if the ledger accepts it.
pub type Proposal {
  kind: Kind,
  tx: Transaction,
  mint_redeemer: Option<StateMint>,
  state_spends: List<(OutputReference, StateSpend)>,
  effect: Effect,
}

fn candidate(kind: Kind, registry: Int, key: ByteArray, other: Int) -> Candidate {
  Candidate { kind, registry, key, other, keys: [] }
}

fn registry_indices(world: World) -> List<Int> {
  list.range(0, list.length(world.registries) - 1)
}

/// The keys of the universe `registry` is active for, with the output that
/// holds the token, when no request names them.
fn held_keys(
  world: World,
  tokens: List<(AssetName, Int, Input)>,
  index: Int,
) -> List<ByteArray> {
  let registry = registry_at(world, index)
  list.filter(
    universe(),
    fn(key) {
      and {
        leaf_of(registry, key) == Active,
        !is_terminating(world, index, key),
        holder_in(tokens, registry, key) != None,
      }
    },
  )
}

fn creations(world: World) -> List<Candidate> {
  if list.length(world.registries) < most_registries {
    [candidate(CreateRegistry, list.length(world.registries), #"", 0)]
  } else {
    []
  }
}

fn requests(world: World) -> List<Candidate> {
  list.flat_map(
    registry_indices(world),
    fn(index) {
      list.filter_map(
        universe(),
        fn(key) {
          if is_pending(world, index, key) {
            None
          } else {
            Some(candidate(RequestRegistration, index, key, 0))
          }
        },
      )
    },
  )
}

/// What the proposals of one registry depend on, found once for a step: the
/// keys whose token sits in an output no request names, the requests that can
/// be folded now, and the keys that are terminal.
type Facts {
  index: Int,
  holdable: List<ByteArray>,
  waiting: List<Step>,
  terminal: List<ByteArray>,
}

fn facts_of(world: World, tokens: List<(AssetName, Int, Input)>) -> List<Facts> {
  list.map(
    registry_indices(world),
    fn(index) {
      let registry = registry_at(world, index)
      Facts {
        index,
        holdable: held_keys(world, tokens, index),
        waiting: waiting(world, index),
        terminal: list.filter(
          universe(),
          fn(key) { leaf_of(registry, key) == Terminal },
        ),
      }
    },
  )
}

fn bookings(facts: List<Facts>) -> List<Candidate> {
  list.flat_map(
    facts,
    fn(each) {
      list.map(
        each.holdable,
        fn(key) { candidate(BookTermination, each.index, key, 0) },
      )
    },
  )
}

fn moves(facts: List<Facts>) -> List<Candidate> {
  list.flat_map(
    facts,
    fn(each) {
      list.map(
        each.holdable,
        fn(key) { candidate(MoveHolding, each.index, key, 0) },
      )
    },
  )
}

/// The batches a registry can fold: the first registrations that wait, the first
/// terminations that wait, and, when both wait, the first of each kind and all of
/// each kind.
fn folds(facts: List<Facts>) -> List<Candidate> {
  list.flat_map(
    facts,
    fn(each) {
      let registrations = list.filter(each.waiting, is_registration)
      let terminations =
        list.filter(each.waiting, fn(step) { !is_registration(step) })
      let batches =
        list.concat(
          list.map(
            list.range(1, list.length(registrations)),
            fn(take) { list.take(registrations, take) },
          ),
          list.concat(
            list.map(
              list.range(1, list.length(terminations)),
              fn(take) { list.take(terminations, take) },
            ),
            if registrations != [] && terminations != [] {
              [
                list.concat(
                  list.take(registrations, 1),
                  list.take(terminations, 1),
                ),
                list.concat(registrations, list.take(terminations, 1)),
                list.concat(list.take(registrations, 1), terminations),
                list.concat(registrations, terminations),
              ]
            } else {
              []
            },
          ),
        )
      list.map(
        batches,
        fn(batch) {
          Candidate {
            ..candidate(FoldBatch, each.index, #"", 0),
            keys: list.map(batch, key_of_step),
          }
        },
      )
    },
  )
}

fn attacks(world: World, facts: List<Facts>) -> List<Candidate> {
  list.concat(
    list.flat_map(
      list.filter(
        world.pending,
        fn(each) { each.registry < list.length(world.registries) },
      ),
      fn(each) { attacks_on_request(world, each) },
    ),
    list.flat_map(facts, fn(each) { attacks_on_registry(each, facts) }),
  )
}

fn attacks_on_request(world: World, each: Pending) -> List<Candidate> {
  let registry = registry_at(world, each.registry)
  let key = key_of_step(each.step)
  when each.step is {
    Terminating(_) ->
      if leaf_of(registry, key) == Active {
        [candidate(TerminateKeepingToken, each.registry, key, 0)]
      } else {
        []
      }
    Registering(_) ->
      when leaf_of(registry, key) is {
        Absent -> [candidate(RegisterWithTwoTokens, each.registry, key, 0)]
        Active -> [candidate(RegisterActiveKey, each.registry, key, 0)]
        Terminal -> [candidate(RegisterTerminalKey, each.registry, key, 0)]
      }
  }
}

fn attacks_on_registry(each: Facts, all: List<Facts>) -> List<Candidate> {
  let registering = list.any(each.waiting, is_registration)
  if registering {
    list.concat(
      list.flat_map(
        each.holdable,
        fn(key) {
          [
            candidate(BurnOutsideFold, each.index, key, 0),
            candidate(BurnBesideRegistration, each.index, key, 0),
          ]
        },
      ),
      list.flat_map(
        list.filter(all, fn(other) { other.index != each.index }),
        fn(other) {
          list.map(
            other.terminal,
            fn(key) {
              candidate(
                MintTerminalKeyThroughAnotherRegistry,
                each.index,
                key,
                other.index,
              )
            },
          )
        },
      ),
    )
  } else {
    list.map(
      each.holdable,
      fn(key) { candidate(BurnOutsideFold, each.index, key, 0) },
    )
  }
}

fn is_registration(step: Step) -> Bool {
  when step is {
    Registering(_) -> True
    Terminating(_) -> False
  }
}

/// The proposals the world allows that follow the rules, grouped by what they
/// are; the groups that hold nothing are left out. A booking and a fold weigh
/// twice a request, so a run reaches terminal keys within its length.
fn rule_groups(world: World, facts: List<Facts>) -> List<List<Candidate>> {
  let booked = bookings(facts)
  let folded = folds(facts)
  list.filter(
    [
      creations(world),
      requests(world),
      booked,
      booked,
      moves(facts),
      folded,
      folded,
    ],
    fn(group) { group != [] },
  )
}

/// The attacks the world allows, grouped by kind; the groups that hold nothing
/// are left out. The two ways to mint a terminal key's token again weigh twice:
/// they need a key to have ended first, which a run reaches late.
fn attack_groups(world: World, facts: List<Facts>) -> List<List<Candidate>> {
  let all = attacks(world, facts)
  list.filter(
    list.map(
      [
        TerminateKeepingToken, RegisterWithTwoTokens, RegisterActiveKey,
        RegisterTerminalKey, BurnOutsideFold, BurnBesideRegistration,
        MintTerminalKeyThroughAnotherRegistry,
      ],
      fn(kind) { list.filter(all, fn(each) { each.kind == kind }) },
    ),
    fn(group) { group != [] },
  )
}

/// Every proposal the world allows, grouped by what it is.
pub fn groups(world: World) -> List<List<Candidate>> {
  let facts = facts_of(world, state_tokens(world))
  list.concat(rule_groups(world, facts), attack_groups(world, facts))
}

/// The proposal a choice selects. One choice in three is an attack when the
/// world allows one; the others follow the rules. Within the class the choice
/// names a group, then a member of it, so a kind with many members does not
/// crowd out the others.
pub fn choose(world: World, choice: Int) -> Option<Candidate> {
  let facts = facts_of(world, state_tokens(world))
  let pool =
    if choice % 3 == 0 {
      let attacking = attack_groups(world, facts)
      if attacking != [] {
        attacking
      } else {
        rule_groups(world, facts)
      }
    } else {
      let rules = rule_groups(world, facts)
      if rules != [] {
        rules
      } else {
        attack_groups(world, facts)
      }
    }
  let count = list.length(pool)
  if count == 0 {
    None
  } else {
    let pick = choice / 3
    expect Some(group) = list.at(pool, pick % count)
    list.at(group, pick / count % list.length(group))
  }
}

// ---------------------------------------------------------------------------
// Building the proposals
// ---------------------------------------------------------------------------

/// The proposal for a candidate of the world.
pub fn build(world: World, chosen: Candidate) -> Proposal {
  when chosen.kind is {
    CreateRegistry -> create_registry(world)
    RequestRegistration ->
      request_registration(world, chosen.registry, chosen.key)
    BookTermination -> book_termination(world, chosen.registry, chosen.key)
    MoveHolding -> move_holding(world, chosen.registry, chosen.key)
    FoldBatch ->
      fold_batch(
        world,
        chosen.registry,
        list.filter(
          waiting(world, chosen.registry),
          fn(step) { list.has(chosen.keys, key_of_step(step)) },
        ),
      )
    TerminateKeepingToken ->
      terminate_keeping_token(world, chosen.registry, chosen.key)
    RegisterWithTwoTokens ->
      register_with_two_tokens(world, chosen.registry, chosen.key)
    RegisterActiveKey ->
      register_not_absent(RegisterActiveKey, world, chosen.registry, chosen.key)
    RegisterTerminalKey ->
      register_not_absent(
        RegisterTerminalKey,
        world,
        chosen.registry,
        chosen.key,
      )
    BurnOutsideFold -> burn_outside_fold(world, chosen.registry, chosen.key)
    BurnBesideRegistration ->
      burn_beside_registration(world, chosen.registry, chosen.key)
    MintTerminalKeyThroughAnotherRegistry ->
      mint_through_another_registry(
        world,
        chosen.registry,
        chosen.key,
        chosen.other,
      )
  }
}

fn output_reference(world: World, index: Int) -> OutputReference {
  OutputReference { transaction_id: fresh_id(world), output_index: index }
}

/// A transaction that pays the change of the funding output into an ordinary
/// output, first, then spends and creates what the proposal names.
fn transaction_of(
  world: World,
  inputs: List<Input>,
  outputs: List<Output>,
  mint: Value,
) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    id: fresh_id(world),
    inputs: [funding_of(world), ..inputs],
    outputs: [ordinary_output, ..outputs],
    mint,
  }
}

fn neutral(kind: Kind, tx: Transaction, effect: Effect) -> Proposal {
  Proposal { kind, tx, mint_redeemer: None, state_spends: [], effect }
}

fn create_registry(world: World) -> Proposal {
  let seed = seed_reference(list.length(world.registries))
  let seed_input = input_at(world, seed)
  Proposal {
    kind: CreateRegistry,
    tx: Transaction {
      ..transaction.placeholder,
      id: fresh_id(world),
      inputs: [seed_input],
      outputs: [genuine_output(state_policy, seed)],
      mint: from_asset(state_policy, state_token_name(seed), 1),
    },
    mint_redeemer: Some(Genesis { seed }),
    state_spends: [],
    effect: Created(
      Registry {
        seed,
        state: output_reference(world, 0),
        held: [],
        names: names_for(seed),
      },
    ),
  }
}

fn request_registration(world: World, index: Int, key: ByteArray) -> Proposal {
  let identity = identity_of(registry_at(world, index))
  let registration =
    Registration {
      ..registering(key, 100 + world.used),
      request: output_reference(world, 1),
    }
  neutral(
    RequestRegistration,
    transaction_of(
      world,
      [],
      [request_input(identity, registration).output],
      zero |> add(application_policy, approval_of(identity, registration), 1),
    ),
    Requested(Pending { registry: index, step: Registering(registration) }),
  )
}

fn book_termination(world: World, index: Int, key: ByteArray) -> Proposal {
  let registry = registry_at(world, index)
  let identity = identity_of(registry)
  expect Some(holder) = holder_in(state_tokens(world), registry, key)
  let termination =
    Termination {
      key,
      request: output_reference(world, 1),
      request_lovelace: 3_000_000 + world.used * 100_000,
    }
  neutral(
    BookTermination,
    transaction_of(
      world,
      [holder],
      [termination_input(identity, termination).output],
      zero
        |> add(application_policy, termination_approval_of(identity, key), 1),
    ),
    Requested(Pending { registry: index, step: Terminating(termination) }),
  )
}

fn move_holding(world: World, index: Int, key: ByteArray) -> Proposal {
  expect Some(holder) =
    holder_in(state_tokens(world), registry_at(world, index), key)
  neutral(
    MoveHolding,
    transaction_of(
      world,
      [holder],
      [Output { ..holder.output, address: from_script(holding_script_b) }],
      zero,
    ),
    Unchanged,
  )
}

/// The state output of the registry created from `seed` whose trie holds `held`,
/// with the root the proof builder computes from the leaves. The statements
/// compare it with the root the trie library computes from the same leaves.
fn state_output(seed: OutputReference, held: List<Held>) -> Output {
  Output {
    address: from_script(state_policy),
    value: from_lovelace(state_lovelace)
      |> add(state_policy, state_token_name(seed), 1),
    datum: root_datum(built_root_of(held)),
    reference_script: None,
  }
}

/// The fold of `steps` into the registry at `index`, as the fixtures build it,
/// spending the outputs the world holds.
fn fold_transaction(world: World, index: Int, steps: List<Step>) -> Transaction {
  let registry = registry_at(world, index)
  Transaction {
    ..transaction.placeholder,
    id: fresh_id(world),
    inputs: [
      funding_of(world),
      input_at(world, registry.state),
      ..list.map(steps, fn(step) { input_at(world, request_of_step(step)) })
    ],
    outputs: [
      ordinary_output,
      state_output(registry.seed, held_after(registry.held, steps)),
      ..list.filter_map(
        steps,
        fn(step) {
          when step is {
            Registering(registration) ->
              Some(holding_output(identity_of(registry), registration))
            Terminating(_) -> None
          }
        },
      )
    ],
    mint: minted_mixed(
      Mixed { seed: registry.seed, before: registry.held, steps },
    ),
  }
}

fn fold_proposal(
  kind: Kind,
  world: World,
  index: Int,
  steps: List<Step>,
  tx: Transaction,
) -> Proposal {
  let registry = registry_at(world, index)
  Proposal {
    kind,
    tx,
    mint_redeemer: Some(Folded),
    state_spends: [
      (
        registry.state,
        redeemer_mixed(
          Mixed { seed: registry.seed, before: registry.held, steps },
        ),
      ),
    ],
    effect: Advanced(index, held_after(registry.held, steps)),
  }
}

fn fold_batch(world: World, index: Int, steps: List<Step>) -> Proposal {
  fold_proposal(
    FoldBatch,
    world,
    index,
    steps,
    fold_transaction(world, index, steps),
  )
}

fn step_for(world: World, index: Int, key: ByteArray, registering: Bool) -> Step {
  expect Some(each) =
    list.find(
      world.pending,
      fn(each) {
        and {
          each.registry == index,
          key_of_step(each.step) == key,
          is_registration(each.step) == registering,
        }
      },
    )
  each.step
}

/// `value` with one more of the token `name` of the state policy.
fn with_token(value: Value, name: AssetName, quantity: Int) -> Value {
  value |> add(state_policy, name, quantity)
}

fn token_name(world: World, index: Int, key: ByteArray) -> AssetName {
  name_in(registry_at(world, index), key)
}

/// An output at a script address that holds nothing but the token `name`: where
/// the token goes when a fold does not burn it, or mints it for a key it does not
/// register.
fn token_output(name: AssetName) -> Output {
  Output {
    address: from_script(holding_script_b),
    value: with_token(from_lovelace(2_000_000), name, 1),
    datum: NoDatum,
    reference_script: None,
  }
}

/// A termination whose fold does not burn the token: the token goes to an output
/// of its own instead.
fn terminate_keeping_token(world: World, index: Int, key: ByteArray) -> Proposal {
  let steps = [step_for(world, index, key, False)]
  let base = fold_transaction(world, index, steps)
  let name = token_name(world, index, key)
  fold_proposal(
    TerminateKeepingToken,
    world,
    index,
    steps,
    Transaction {
      ..base,
      mint: with_token(base.mint, name, 1),
      outputs: list.concat(base.outputs, [token_output(name)]),
    },
  )
}

/// A registration that mints two tokens for the key and delivers both to the
/// holding.
fn register_with_two_tokens(
  world: World,
  index: Int,
  key: ByteArray,
) -> Proposal {
  let steps = [step_for(world, index, key, True)]
  let base = fold_transaction(world, index, steps)
  let name = token_name(world, index, key)
  expect [change, state, holding, ..rest] = base.outputs
  fold_proposal(
    RegisterWithTwoTokens,
    world,
    index,
    steps,
    Transaction {
      ..base,
      mint: with_token(base.mint, name, 1),
      outputs: [
        change,
        state,
        Output { ..holding, value: with_token(holding.value, name, 1) },
        ..rest
      ],
    },
  )
}

/// The registration of a key that is not absent, the one the fold builds when
/// it is shown the trie without the key.
fn register_not_absent(
  kind: Kind,
  world: World,
  index: Int,
  key: ByteArray,
) -> Proposal {
  let steps = [step_for(world, index, key, True)]
  fold_proposal(
    kind,
    world,
    index,
    steps,
    fold_transaction(world, index, steps),
  )
}

/// A transaction that burns a token and folds nothing.
fn burn_outside_fold(world: World, index: Int, key: ByteArray) -> Proposal {
  let registry = registry_at(world, index)
  expect Some(holder) = holder_in(state_tokens(world), registry, key)
  Proposal {
    kind: BurnOutsideFold,
    tx: transaction_of(
      world,
      [holder],
      [],
      with_token(zero, token_name(world, index, key), -1),
    ),
    mint_redeemer: Some(Folded),
    state_spends: [],
    effect: Unchanged,
  }
}

/// A registration fold that also spends the holding of an active key and
/// burns its token.
fn burn_beside_registration(
  world: World,
  index: Int,
  key: ByteArray,
) -> Proposal {
  let registry = registry_at(world, index)
  expect Some(holder) = holder_in(state_tokens(world), registry, key)
  expect [first, ..] = registrations_waiting(world, index)
  let steps = [first]
  let base = fold_transaction(world, index, steps)
  fold_proposal(
    BurnBesideRegistration,
    world,
    index,
    steps,
    Transaction {
      ..base,
      inputs: list.concat(base.inputs, [holder]),
      mint: with_token(base.mint, token_name(world, index, key), -1),
    },
  )
}

/// A registration fold of one registry that also mints the token a terminal
/// key has in another.
fn mint_through_another_registry(
  world: World,
  index: Int,
  key: ByteArray,
  other: Int,
) -> Proposal {
  expect [first, ..] = registrations_waiting(world, index)
  let steps = [first]
  let base = fold_transaction(world, index, steps)
  let name = token_name(world, other, key)
  fold_proposal(
    MintTerminalKeyThroughAnotherRegistry,
    world,
    index,
    steps,
    Transaction {
      ..base,
      mint: with_token(base.mint, name, 1),
      outputs: list.concat(base.outputs, [token_output(name)]),
    },
  )
}

// ---------------------------------------------------------------------------
// The ledger and the scripts
// ---------------------------------------------------------------------------

/// The rules of the ledger the statements rest on: every input is an unspent
/// output of the world, none is spent twice, and every asset but lovelace is
/// conserved: what the inputs and the mint bring is what the outputs carry.
/// The input is the unspent output of the world that has its reference.
fn is_unspent(world: World, input: Input) -> Bool {
  when
    list.find(
      world.unspent,
      fn(each) { each.output_reference == input.output_reference },
    )
  is {
    Some(each) -> each == input
    None -> False
  }
}

pub fn ledger_accepts(proposal: Proposal, world: World) -> Bool {
  let tx = proposal.tx
  let references = list.map(tx.inputs, fn(input) { input.output_reference })
  let entering =
    list.foldl(
      tx.inputs,
      tx.mint,
      fn(input, all) { merge(all, input.output.value) },
    )
  let leaving =
    list.foldl(tx.outputs, zero, fn(output, all) { merge(all, output.value) })
  and {
    list.all(tx.inputs, fn(input) { is_unspent(world, input) }),
    list.length(list.unique(references)) == list.length(references),
    flatten(without_lovelace(entering)) == flatten(without_lovelace(leaving)),
  }
}

fn spends_state(input: Input) -> Bool {
  input.output.address.payment_credential == Script(state_policy)
}

/// The scripts the ledger would run for the proposal, run by the handlers of the
/// state validator that the test module hands in (a module that imports the
/// validator cannot export anything): the mint handler when the
/// state policy is minted, the spend handler for each input at the state
/// script. A script the transaction brings no redeemer for fails.
pub fn scripts_accept(
  mint: fn(StateMint, Transaction) -> Bool,
  spend: fn(Option<Data>, StateSpend, OutputReference, Transaction) -> Bool,
  proposal: Proposal,
) -> Bool {
  let tx = proposal.tx
  and {
    if list.has(policies(tx.mint), state_policy) {
      when proposal.mint_redeemer is {
        Some(redeemer) -> mint(redeemer, tx)
        None -> False
      }
    } else {
      True
    },
    list.all(
      list.filter(tx.inputs, spends_state),
      fn(input) {
        when
          list.find(
            proposal.state_spends,
            fn(spend) { spend.1st == input.output_reference },
          )
        is {
          Some((_, redeemer)) ->
            spend(
              application_datum(input.output.datum),
              redeemer,
              input.output_reference,
              tx,
            )
          None -> False
        }
      },
    ),
  }
}

// ---------------------------------------------------------------------------
// Runs
// ---------------------------------------------------------------------------

/// One step of a run: the proposal, whether it was accepted, whether the
/// ledger's rules held for it whatever the scripts said, and the world before
/// and after.
pub type Outcome {
  proposal: Proposal,
  accepted: Bool,
  lawful: Bool,
  before: World,
  after: World,
}

/// The world after an accepted proposal.
pub fn advance(world: World, proposal: Proposal) -> World {
  let tx = proposal.tx
  let consumed = list.map(tx.inputs, fn(input) { input.output_reference })
  let created =
    list.indexed_map(
      tx.outputs,
      fn(index, output) {
        Input {
          output_reference: OutputReference {
            transaction_id: tx.id,
            output_index: index,
          },
          output,
        }
      },
    )
  World {
    unspent: list.concat(
      list.filter(
        world.unspent,
        fn(input) { !list.has(consumed, input.output_reference) },
      ),
      created,
    ),
    registries: when proposal.effect is {
      Created(registry) -> list.concat(world.registries, [registry])
      Advanced(index, held) ->
        list.indexed_map(
          world.registries,
          fn(at, registry) {
            if at == index {
              Registry {
                ..registry,
                state: OutputReference {
                  transaction_id: tx.id,
                  output_index: 1,
                },
                held,
              }
            } else {
              registry
            }
          },
        )
      _ -> world.registries
    },
    pending: when proposal.effect is {
      Requested(request) ->
        list.concat(without_requests(world.pending, consumed), [request])
      _ -> without_requests(world.pending, consumed)
    },
    used: world.used + 1,
  }
}

fn without_requests(
  pending: List<Pending>,
  consumed: List<OutputReference>,
) -> List<Pending> {
  list.filter(
    pending,
    fn(each) { !list.has(consumed, request_of_step(each.step)) },
  )
}

/// A proposal decided: the ledger's rules, then the scripts, and the world that
/// follows.
fn settle(
  scripts: fn(Proposal) -> Bool,
  world: World,
  proposal: Proposal,
) -> Outcome {
  let lawful = ledger_accepts(proposal, world)
  let accepted = lawful && scripts(proposal)
  Outcome {
    proposal,
    accepted,
    lawful,
    before: world,
    after: if accepted {
      advance(world, proposal)
    } else {
      world
    },
  }
}

/// The steps of a run: each choice selects a proposal of the world it finds,
/// the ledger's rules and the scripts decide, and an accepted proposal makes the
/// next world.
pub fn run(
  scripts: fn(Proposal) -> Bool,
  world: World,
  choices: List<Int>,
) -> List<Outcome> {
  when choices is {
    [] -> []
    [choice, ..rest] ->
      when choose(world, choice) is {
        None -> []
        Some(chosen) -> {
          let outcome = settle(scripts, world, build(world, chosen))
          [outcome, ..run(scripts, outcome.after, rest)]
        }
      }
  }
}

// ---------------------------------------------------------------------------
// Scripted runs
// ---------------------------------------------------------------------------

/// A proposal named by what it is, for a run written by hand.
pub type Want {
  kind: Kind,
  registry: Int,
  keys: List<ByteArray>,
}

/// The candidate that is what the world is asked for. A fold names the keys of
/// the requests it folds; any other proposal names its key, or none when the
/// kind has none. A proposal that follows the rules is built as named, and fails
/// to build when the world does not allow it; an attack is looked for among the
/// attacks the world allows, and a world that allows none leaves the run short.
fn resolve(world: World, want: Want) -> Option<Candidate> {
  let key =
    when want.keys is {
      [first, ..] -> first
      [] -> #""
    }
  if want.kind == FoldBatch {
    Some(
      Candidate {
        ..candidate(FoldBatch, want.registry, #"", 0),
        keys: want.keys,
      },
    )
  } else if !is_attack(want.kind) {
    Some(candidate(want.kind, want.registry, key, 0))
  } else {
    list.head(
      list.filter(
        list.flat_map(groups(world), fn(group) { group }),
        fn(each) {
          and {
            each.kind == want.kind,
            each.registry == want.registry,
            want.keys == [] || list.has(want.keys, each.key),
          }
        },
      ),
    )
  }
}

/// A run written by hand. It stops at the first proposal the world does not
/// allow.
pub fn run_script(
  scripts: fn(Proposal) -> Bool,
  world: World,
  wants: List<Want>,
) -> List<Outcome> {
  when wants is {
    [] -> []
    [want, ..rest] ->
      when resolve(world, want) is {
        None -> []
        Some(chosen) -> {
          let outcome = settle(scripts, world, build(world, chosen))
          [outcome, ..run_script(scripts, outcome.after, rest)]
        }
      }
  }
}

// ---------------------------------------------------------------------------
// What the statements read
// ---------------------------------------------------------------------------

/// The live supply of the token of `key` in `registry` among the tokens of the
/// state policy: its quantity over every unspent output.
fn supply_in(
  tokens: List<(AssetName, Int, Input)>,
  registry: Registry,
  key: ByteArray,
) -> Int {
  let name = name_in(registry, key)
  list.foldl(
    tokens,
    0,
    fn(entry, total) {
      if entry.1st == name {
        total + entry.2nd
      } else {
        total
      }
    },
  )
}

/// The live supply of the token of `key` in `registry`: its quantity over every
/// unspent output.
pub fn live_supply(world: World, registry: Registry, key: ByteArray) -> Int {
  supply_in(state_tokens(world), registry, key)
}

/// Every quantity of the state policy over every unspent output: the state
/// tokens and the tokens of keys.
fn state_policy_supply(tokens: List<(AssetName, Int, Input)>) -> Int {
  list.foldl(tokens, 0, fn(entry, total) { total + entry.2nd })
}

fn active_keys(world: World) -> Int {
  list.foldl(
    world.registries,
    0,
    fn(registry, total) {
      total + list.count(registry.held, fn(each) { each.leaf == leaf_active })
    },
  )
}

/// The state output of the registry carries the token of its seed once and the
/// root of the leaves the world holds for it.
fn commits_to_its_leaves(world: World, registry: Registry) -> Bool {
  when
    list.find(
      world.unspent,
      fn(input) { input.output_reference == registry.state },
    )
  is {
    Some(Input { output, .. }) -> and {
        output.datum == root_datum(root_of_held(registry.held)),
        quantity_of(output.value, state_policy, state_token_name(registry.seed)) == 1,
      }
    None -> False
  }
}

/// The last world of a run is read as a whole: no key has more than one live
/// token (a corollary of the supply of each step), and the state output of every
/// registry commits to the leaves the world holds for it, with the root the trie
/// library computes from them: the outputs the folds wrote carry the root of the
/// proof builder.
pub fn runs_end_committed(outcomes: List<Outcome>) -> Bool {
  when list.last(outcomes) is {
    Some(last) -> and {
        has_at_most_one_live_token(last.after),
        list.all(
          last.after.registries,
          fn(registry) { commits_to_its_leaves(last.after, registry) },
        ),
      }
    None -> True
  }
}

/// History statement `supply_in_step`: after an accepted step, for every
/// registry and key, the live supply of the key's token is one when its leaf is
/// active and zero otherwise. The tokens of the whole policy are counted too, so
/// a token of a key the world does not know is a violation.
pub fn supply_follows_leaves(outcome: Outcome) -> Bool {
  let world = outcome.after
  let tokens = state_tokens(world)
  if outcome.accepted {
    and {
      list.all(
        world.registries,
        fn(registry) {
          list.all(
            universe(),
            fn(key) {
              supply_in(tokens, registry, key) == if leaf_of(registry, key) == Active {
                1
              } else {
                0
              }
            },
          )
        },
      ),
      state_policy_supply(tokens) == list.length(world.registries) + active_keys(
        world,
      ),
    }
  } else {
    True
  }
}

/// History statement `one_live_token`: at most one token of a key is live.
pub fn at_most_one_live_token(outcome: Outcome) -> Bool {
  !outcome.accepted || has_at_most_one_live_token(outcome.after)
}

fn has_at_most_one_live_token(world: World) -> Bool {
  let tokens = state_tokens(world)
  list.all(
    world.registries,
    fn(registry) {
      list.all(universe(), fn(key) { supply_in(tokens, registry, key) <= 1 })
    },
  )
}

fn minted_of(tx: Transaction, registry: Registry, key: ByteArray) -> Int {
  quantity_of(tx.mint, state_policy, name_in(registry, key))
}

fn burned_by(tx: Transaction) -> Int {
  list.count(
    flatten(tx.mint),
    fn(entry) { entry.1st == state_policy && entry.3rd < 0 },
  )
}

/// The registries and keys whose token the transaction burns.
fn burns_of(world: World, tx: Transaction) -> List<(Int, ByteArray)> {
  list.flat_map(
    registry_indices(world),
    fn(index) {
      list.filter_map(
        universe(),
        fn(key) {
          if minted_of(tx, registry_at(world, index), key) < 0 {
            Some((index, key))
          } else {
            None
          }
        },
      )
    },
  )
}

/// The transaction spends the state of the registry and folds a termination of
/// the key into it.
fn terminates(outcome: Outcome, index: Int, key: ByteArray) -> Bool {
  let registry = registry_at(outcome.before, index)
  and {
    list.any(
      outcome.proposal.tx.inputs,
      fn(input) { input.output_reference == registry.state },
    ),
    list.any(
      outcome.proposal.state_spends,
      fn(spend) {
        let Fold { changes, .. } = spend.2nd
        spend.1st == registry.state && list.any(
          changes,
          fn(change) {
            when change is {
              Terminate { key: terminated, .. } -> terminated == key
              _ -> False
            }
          },
        )
      },
    ),
    leaf_of(registry_at(outcome.after, index), key) == Terminal,
  }
}

/// History statement `burn_only_terminating_fold`: an accepted transaction
/// burns the token of a key only in a fold of its registry that terminates the
/// key, whose final leaf is terminal; and every burn of the state policy is the
/// token of a key of a registry of the world.
pub fn burns_belong_to_terminating_folds(outcome: Outcome) -> Bool {
  if outcome.accepted && burned_by(outcome.proposal.tx) > 0 {
    let burned = burns_of(outcome.before, outcome.proposal.tx)
    and {
      list.length(burned) == burned_by(outcome.proposal.tx),
      list.all(burned, fn(pair) { terminates(outcome, pair.1st, pair.2nd) }),
    }
  } else {
    True
  }
}

/// History statement `no_remint_after_terminal`: an accepted transaction mints
/// no token of a key that is terminal in a registry, in a fold of that
/// registry or of another, and the key stays terminal.
pub fn terminal_keys_are_never_minted_again(outcome: Outcome) -> Bool {
  if outcome.accepted {
    list.all(
      registry_indices(outcome.before),
      fn(index) {
        let registry = registry_at(outcome.before, index)
        list.all(
          universe(),
          fn(key) {
            if leaf_of(registry, key) == Terminal {
              and {
                minted_of(outcome.proposal.tx, registry, key) <= 0,
                leaf_of(registry_at(outcome.after, index), key) == Terminal,
              }
            } else {
              True
            }
          },
        )
      },
    )
  } else {
    True
  }
}

/// The changes of the folds a proposal carries.
pub fn changes_of(proposal: Proposal) -> List<Change> {
  list.flat_map(
    proposal.state_spends,
    fn(spend) {
      let Fold { changes, .. } = spend.2nd
      changes
    },
  )
}

/// Whether the proposal folds a registration.
pub fn folds_registrations(proposal: Proposal) -> Bool {
  list.any(
    changes_of(proposal),
    fn(change) {
      when change is {
        Register { .. } -> True
        Terminate { .. } -> False
      }
    },
  )
}

/// Whether the proposal folds a termination.
pub fn folds_terminations(proposal: Proposal) -> Bool {
  list.any(
    changes_of(proposal),
    fn(change) {
      when change is {
        Register { .. } -> False
        Terminate { .. } -> True
      }
    },
  )
}

/// Whether the proposal folds registrations and terminations together.
pub fn is_mixed_fold(proposal: Proposal) -> Bool {
  folds_registrations(proposal) && folds_terminations(proposal)
}

/// The kinds of attack the world allows.
pub fn allowed_attacks(world: World) -> List<Kind> {
  let facts = facts_of(world, state_tokens(world))
  list.unique(
    list.map(
      attack_groups(world, facts),
      fn(group) {
        expect [first, ..] = group
        first.kind
      },
    ),
  )
}

/// Whether a run has the accepted proposals the rules produce: every proposal
/// that is not an attack is accepted, and every one is lawful for the ledger.
pub fn rules_are_followed(outcomes: List<Outcome>) -> Bool {
  list.all(
    outcomes,
    fn(outcome) {
      outcome.lawful && ( is_attack(outcome.proposal.kind) || outcome.accepted )
    },
  )
}

/// The name of an outcome, for the tables the property runs print.
pub fn describe(outcome: Outcome) -> String {
  string.concat(
    if outcome.accepted {
      @"accepted: "
    } else {
      @"refused: "
    },
    name_of(outcome.proposal.kind),
  )
}
