//// The hashed names of the new Singular line.
////
//// ## Responsibility
//// Holds the structured preimages whose Plutus Data serialisation is hashed
//// into a token name, and one function per role that names the token.
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
use cardano/address.{Address}
use cardano/assets.{AssetName, PolicyId}
use cardano/transaction.{OutputReference}

/// The identity of a registry: its state token.
pub type RegistryIdentity {
  policy: PolicyId,
  name: AssetName,
}

/// The structured value hashed into a token name, one constructor per role,
/// numbered as the model's `Preimage`. The configuration and termination
/// constructors are declared to keep that numbering; nothing builds them in
/// this line yet.
pub type Preimage {
  State { seed: OutputReference }
  Active { registry: RegistryIdentity, key: ByteArray }
  ApplicationConfiguration { registry: RegistryIdentity }
  RegistrationApproval {
    registry: RegistryIdentity,
    key: ByteArray,
    holding_address: Address,
    initial_datum: ByteArray,
    deposit: Int,
  }
  TerminationApproval { registry: RegistryIdentity, key: ByteArray }
}

/// The name of the state token of the registry created by spending `seed`:
/// the blake2b-256 hash of the Plutus Data serialisation of its preimage.
pub fn state_token_name(seed: OutputReference) -> AssetName {
  blake2b_256(cbor.serialise(State { seed }))
}

/// The name of the token that stands for `key` in `registry`.
pub fn active_token_name(
  _registry: RegistryIdentity,
  _key: ByteArray,
) -> AssetName {
  #""
}

/// The Plutus Data serialisation of the registration approval preimage: the
/// registry, the key, the address the holding sits at, the hash of the
/// holding's initial datum and the deposit the holding holds.
pub fn registration_preimage(
  _key: ByteArray,
  _registry: RegistryIdentity,
  _holding_address: Address,
  _datum_hash: ByteArray,
  _deposit: Int,
) -> ByteArray {
  #""
}

/// The name of the registration approval token whose preimage is `preimage`.
pub fn approval_name(_preimage: ByteArray) -> AssetName {
  #""
}

/// The hash of a holding's initial datum, as the registration approval
/// commits it.
pub fn initial_datum_hash(_datum: Data) -> ByteArray {
  #""
}
