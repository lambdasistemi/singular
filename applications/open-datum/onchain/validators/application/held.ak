//// The records held at the address of the open-datum request validator.
////
//// ## Responsibility
//// Declares what an output at the application address can carry, in the
//// words of the model's `ApplicationParameters`, `RegistrationData`,
//// `ProtectedControl` and `ApplicationDatum`, and reads such an output's
//// datum without failing: a datum of another shape is no record.
////
//// ## Dependencies
//// `singular_state/preimage` for the identity of a registry; the Aiken
//// standard library.
////
//// ## Assumptions
//// The datum of an output is read from the output itself, inline. A datum
//// that is only a hash is no record.
////
//// ## Invariants
//// The three records are one sum type, so an output carries at most one of
//// them, and the tag of a live holding is neither the tag of the state datum
//// of the Singular state script nor the tag of a registration.

use aiken/crypto.{VerificationKeyHash}
use cardano/address.{Address}
use cardano/assets.{AssetName, PolicyId}
use cardano/transaction.{InlineDatum, Output}
use singular_state/preimage.{RegistryIdentity}

/// A token by policy and name.
pub type TokenId {
  policy: PolicyId,
  name: AssetName,
}

/// The five request parameters of a registry, fixed when it is created.
pub type ApplicationParameters {
  registration_cost: Int,
  minimum_tip: Int,
  process_time: Int,
  retract_time: Int,
  booking_width: Int,
}

/// The part of a live holding no update may change.
pub type ProtectedControl {
  registry: RegistryIdentity,
  active_asset: TokenId,
  key: ByteArray,
  controller: VerificationKeyHash,
  deposit: Int,
}

/// A booked registration, decoded from the datum of a pending registration.
pub type RegistrationData {
  registry: RegistryIdentity,
  key: ByteArray,
  controller: VerificationKeyHash,
  refund_address: Address,
  holding_address: Address,
  initial_datum: Data,
  deposit: Int,
  booked_at: Int,
  process_deadline: Int,
  reclaim_end: Int,
}

/// The datum of an output at the application address.
pub type HeldDatum {
  Configuration { parameters: ApplicationParameters }
  Registration { registration: RegistrationData }
  Live { control: ProtectedControl, payload: Data }
}

/// The record a datum carries, when it carries one.
pub fn held_datum_of(datum: Data) -> Option<HeldDatum> {
  if datum is Configuration { parameters }: HeldDatum {
    Some(Configuration { parameters })
  } else if datum is Registration { registration }: HeldDatum {
    Some(Registration { registration })
  } else if datum is Live { control, payload }: HeldDatum {
    Some(Live { control, payload })
  } else {
    None
  }
}

/// The record `output` carries inline, when it carries one.
pub fn held_datum(output: Output) -> Option<HeldDatum> {
  when output.datum is {
    InlineDatum(datum) -> held_datum_of(datum)
    _ -> None
  }
}
