//// Shared fixtures of the Singular state validator tests.
////
//// Every expected token name is obtained from `state_token_name`, the
//// producer, at run time. The seeds differ in the transaction id, in the
//// output index, and in the high byte of the output index, so no two of them
//// agree on any part a name could be taken from.

use aiken/fuzz
use aiken/merkle_patricia_forestry.{empty, root}
use cardano/address.{from_script, from_verification_key}
use cardano/assets.{AssetName, PolicyId, Value, add, from_asset, from_lovelace}
use cardano/transaction.{
  Datum, InlineDatum, Input, NoDatum, Output, OutputReference, Transaction,
}
use singular_state/preimage.{state_token_name}
use singular_state/state.{StateDatum}

pub const application_policy: PolicyId =
  #"a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9"

pub const state_policy: PolicyId =
  #"5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a"

pub const other_script: PolicyId =
  #"6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b"

pub const other_policy: PolicyId =
  #"7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c"

const transaction_a: ByteArray =
  #"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

const transaction_b: ByteArray =
  #"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

pub const seed_a: OutputReference =
  OutputReference { transaction_id: transaction_a, output_index: 0 }

pub const seed_b: OutputReference =
  OutputReference { transaction_id: transaction_a, output_index: 1 }

pub const seed_c: OutputReference =
  OutputReference { transaction_id: transaction_b, output_index: 0 }

pub const seed_d: OutputReference =
  OutputReference { transaction_id: transaction_a, output_index: 256 }

/// Four seeds, pairwise different in every part.
pub const seeds: List<OutputReference> = [seed_a, seed_b, seed_c, seed_d]

/// The datum genesis must write: the root of the empty trie.
pub const empty_root_datum: Datum =
  InlineDatum(StateDatum { root: root(empty) })

pub fn root_datum(root: ByteArray) -> Datum {
  InlineDatum(StateDatum { root })
}

pub fn token_value(policy: PolicyId, name: AssetName, quantity: Int) -> Value {
  from_lovelace(2_000_000) |> add(policy, name, quantity)
}

/// The state output genesis writes for `seed`.
pub fn genuine_output(policy: PolicyId, seed: OutputReference) -> Output {
  Output {
    address: from_script(policy),
    value: token_value(policy, state_token_name(seed), 1),
    datum: empty_root_datum,
    reference_script: None,
  }
}

/// An ordinary output that carries no state token.
pub const ordinary_output: Output =
  Output {
    address: from_verification_key(
      #"0101010101010101010101010101010101010101010101010101010101",
    ),
    value: from_lovelace(3_000_000),
    datum: NoDatum,
    reference_script: None,
  }

/// An input that spends `reference`.
pub fn spent(reference: OutputReference) -> Input {
  Input {
    output_reference: reference,
    output: Output {
      address: from_verification_key(
        #"0202020202020202020202020202020202020202020202020202020202",
      ),
      value: from_lovelace(5_000_000),
      datum: NoDatum,
      reference_script: None,
    },
  }
}

/// The transaction that creates the registry state of `seed` under `policy`.
pub fn genesis_transaction(
  policy: PolicyId,
  seed: OutputReference,
) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    inputs: [spent(seed)],
    outputs: [genuine_output(policy, seed)],
    mint: from_asset(policy, state_token_name(seed), 1),
  }
}

/// Any seed: a 32-byte transaction id and any 16-bit output index.
pub fn seed_fuzzer() -> Fuzzer<OutputReference> {
  fuzz.map2(
    fuzz.bytearray_fixed(32),
    fuzz.int_between(0, 65535),
    fn(transaction_id, output_index) {
      OutputReference { transaction_id, output_index }
    },
  )
}
