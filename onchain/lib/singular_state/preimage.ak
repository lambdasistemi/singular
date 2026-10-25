//// The hashed names of the new Singular line.
////
//// ## Responsibility
//// Holds the structured preimages whose Plutus Data serialisation is hashed
//// into a token name, and the one function that names the state token.
////
//// ## Dependencies
//// The Aiken standard library only.
////
//// ## Assumptions
//// The hash is collision free over the preimages in use, so two different
//// preimages never name the same token.
////
//// ## Invariants
//// One constructor per role, numbered as the model's `Preimage`, so a name
//// of one role is never the name of another.

use aiken/cbor
use aiken/crypto.{blake2b_256}
use cardano/assets.{AssetName}
use cardano/transaction.{OutputReference}

/// The structured value hashed into a token name, one constructor per role.
pub type Preimage {
  State { seed: OutputReference }
}

/// The name of the state token of the registry created by spending `seed`:
/// the blake2b-256 hash of the Plutus Data serialisation of its preimage.
pub fn state_token_name(seed: OutputReference) -> AssetName {
  blake2b_256(cbor.serialise(State { seed }))
}
