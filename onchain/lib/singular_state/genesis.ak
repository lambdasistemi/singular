//// Genesis of a registry state.
////
//// ## Responsibility
//// The decision sites of the model's `genesis`: one function per guard, and
//// `genesis`, which conjoins them for the mint handler of the state script.
////
//// ## Dependencies
//// `singular_state/state` for recognition and the mint comparison;
//// `singular_state/preimage` for the state token name.
////
//// ## Assumptions
//// The ledger runs the mint handler only when the state policy is among the
//// minted policies, and spends an input at most once.
////
//// ## Invariants
//// A registry state is created only by spending its seed once, minting
//// exactly one state token named from that seed and nothing else under the
//// state policy, into exactly one recognised state output with the empty
//// root.

use aiken/collection/list
use aiken/merkle_patricia_forestry.{empty, root}
use cardano/assets.{PolicyId, Value, policies, quantity_of}
use cardano/transaction.{
  Datum, InlineDatum, Input, Output, OutputReference, Transaction,
}
use singular_state/preimage.{state_token_name}
use singular_state/state.{StateDatum, policy_delta, recognize_state}

/// The redeemer of the state policy.
pub type StateMint {
  Genesis { seed: OutputReference }
}

/// Model guard `genesisSeed`: the seed is spent by exactly one input.
pub fn genesis_seed(seed: OutputReference, inputs: List<Input>) -> Bool {
  list.count(inputs, fn(input) { input.output_reference == seed }) == 1
}

/// Model guard `genesisInvocation`: the state policy is among the minted
/// policies.
pub fn genesis_invocation(state_policy: PolicyId, mint: Value) -> Bool {
  list.has(policies(mint), state_policy)
}

/// Model guard `genesisMint`: the whole state-policy mint is exactly one
/// state token named from the seed.
pub fn genesis_mint(
  state_policy: PolicyId,
  seed: OutputReference,
  mint: Value,
) -> Bool {
  policy_delta(mint, state_policy, [Pair(state_token_name(seed), 1)])
}

/// The outputs that carry the state token named from `seed`.
pub fn state_candidates(
  state_policy: PolicyId,
  seed: OutputReference,
  outputs: List<Output>,
) -> List<Output> {
  let name = state_token_name(seed)
  list.filter(
    outputs,
    fn(output) { quantity_of(output.value, state_policy, name) > 0 },
  )
}

/// Model guard `genesisOutput`: exactly one candidate, and it is a
/// recognised state.
pub fn genesis_output(
  state_policy: PolicyId,
  seed: OutputReference,
  candidates: List<Output>,
) -> Bool {
  and {
    list.length(candidates) == 1,
    list.all(
      candidates,
      fn(output) { recognize_state(state_policy, seed, output) },
    ),
  }
}

/// Model guard `genesisEmpty`: every candidate carries the empty root.
pub fn genesis_empty(candidates: List<Output>) -> Bool {
  list.all(candidates, fn(output) { output.datum == empty_root_datum })
}

const empty_root_datum: Datum = InlineDatum(StateDatum { root: root(empty) })

/// The model's `genesis` for the state script `state_policy`.
pub fn genesis(
  seed: OutputReference,
  state_policy: PolicyId,
  tx: Transaction,
) -> Bool {
  let candidates = state_candidates(state_policy, seed, tx.outputs)
  and {
    genesis_seed(seed, tx.inputs),
    genesis_invocation(state_policy, tx.mint),
    genesis_mint(state_policy, seed, tx.mint),
    genesis_output(state_policy, seed, candidates),
    genesis_empty(candidates),
  }
}
