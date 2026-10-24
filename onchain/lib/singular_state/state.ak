//// The registry state output of the new Singular line.
////
//// ## Responsibility
//// Defines the root-only state datum, decides whether an output is the state
//// of the registry created from a given seed, and compares the whole mint of
//// a policy with the mint a rule expects.
////
//// ## Dependencies
//// `singular_state/preimage` for the state token name; the Aiken standard
//// library.
////
//// ## Assumptions
//// The state policy is the hash of the state script, which is also the
//// credential of the state address.
////
//// ## Invariants
//// An output is a state only when it sits at the state script, holds the one
//// state token named from the supplied seed at quantity one and nothing else
//// but ADA, and carries a root datum.

use aiken/collection/dict
use aiken/collection/list
use aiken/collection/pairs
use cardano/address.{Script}
use cardano/assets.{
  AssetName, PolicyId, Value, flatten, quantity_of, tokens, without_lovelace,
}
use cardano/transaction.{Datum, InlineDatum, Output, OutputReference}
use singular_state/preimage.{state_token_name}

/// The datum of a state output: the root of the registry's trie.
pub type StateDatum {
  StateDatum { root: ByteArray }
}

/// Whether `output` is the state of the registry created by spending `seed`
/// under `state_policy`.
///
/// Its value holds one non-ADA entry, which is the state token: under the
/// state policy, named from `seed`, at quantity one.
pub fn recognize_state(
  state_policy: PolicyId,
  seed: OutputReference,
  output: Output,
) -> Bool {
  when flatten(without_lovelace(output.value)) is {
    [(policy, name, quantity)] -> and {
        output.address.payment_credential == Script(state_policy),
        policy == state_policy,
        quantity == 1,
        state_root(output.datum) != None,
        name == state_token_name(seed),
      }
    _ -> False
  }
}

/// Whether the whole mint of `policy` in `mint` is exactly `expected`.
pub fn policy_delta(
  mint: Value,
  policy: PolicyId,
  expected: Pairs<AssetName, Int>,
) -> Bool {
  and {
    list.all(
      dict.to_pairs(tokens(mint, policy)),
      fn(Pair(name, quantity)) { quantity == expected_quantity(expected, name) },
    ),
    list.all(
      expected,
      fn(Pair(name, _)) {
        quantity_of(mint, policy, name) == expected_quantity(expected, name)
      },
    ),
  }
}

fn expected_quantity(expected: Pairs<AssetName, Int>, name: AssetName) -> Int {
  list.foldl(
    pairs.get_all(expected, name),
    0,
    fn(quantity, total) { quantity + total },
  )
}

/// The root a state output's datum carries, when it carries one.
pub fn state_root(datum: Datum) -> Option<ByteArray> {
  when datum is {
    InlineDatum(data) ->
      if data is StateDatum { root }: StateDatum {
        Some(root)
      } else {
        None
      }
    _ -> None
  }
}
