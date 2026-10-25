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
/// numbered as the model's `Preimage`. The termination constructor is declared
/// to keep that numbering; nothing builds it in this line yet.
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

fn role_name(preimage: Preimage) -> AssetName {
  blake2b_256(cbor.serialise(preimage))
}

/// The name of the state token of the registry created by spending `seed`:
/// the blake2b-256 hash of the Plutus Data serialisation of its preimage.
pub fn state_token_name(seed: OutputReference) -> AssetName {
  role_name(State { seed })
}

/// The name of the token that stands for `key` in `registry`.
pub fn active_token_name(
  registry: RegistryIdentity,
  key: ByteArray,
) -> AssetName {
  role_name(Active { registry, key })
}

/// The name of the token of the configuration record of `registry`.
pub fn configuration_token_name(registry: RegistryIdentity) -> AssetName {
  role_name(ApplicationConfiguration { registry })
}

/// The Plutus Data serialisation of the registration approval preimage: the
/// registry, the key, the address the holding sits at, the hash of the
/// holding's initial datum and the deposit the holding holds.
pub fn registration_preimage(
  key: ByteArray,
  registry: RegistryIdentity,
  holding_address: Address,
  datum_hash: ByteArray,
  deposit: Int,
) -> ByteArray {
  cbor.serialise(
    RegistrationApproval {
      registry,
      key,
      holding_address,
      initial_datum: datum_hash,
      deposit,
    },
  )
}

/// The Plutus Data serialisation of the termination approval preimage: the
/// registry and the key.
pub fn termination_preimage(
  _key: ByteArray,
  _registry: RegistryIdentity,
) -> ByteArray {
  #""
}

/// The name of the registration approval token whose preimage is `preimage`.
pub fn approval_name(preimage: ByteArray) -> AssetName {
  blake2b_256(preimage)
}

/// The hash of a holding's initial datum, as the registration approval
/// commits it.
pub fn initial_datum_hash(datum: Data) -> ByteArray {
  blake2b_256(cbor.serialise(datum))
}
