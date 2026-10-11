//// The open-datum application's wire types (#299, #310).
////
//// The datum an open-datum output carries is its `Envelope`: a protected
//// `Control` the application checks, and a `payload` it never inspects.
//// The payload is any Plutus `Data` — a constructor, map, list, integer
//// or byte string, nested to any depth — and is bound as `Data`, never
//// cast to a shape, so no payload is refused for what it says.
////
//// On the wire:
////
//// ```
//// Envelope = Constr 0 [control, payload]
//// Control  = Constr 0 [ Int version
////                     , Constr 0 [Bytes statePolicy, Bytes stateName]
////                     , Bytes activePolicy, Bytes key
////                     , Bytes controller, Int deposit ]
//// ```
////
//// The model (`OpenDatumApplication.Model`) states these fields over
//// abstract numbers and a stand-in hash; the correspondence is this
//// representation mapping, checked by the golden vectors both codecs
//// share, not a proof.

use aiken/cbor
use aiken/crypto.{blake2b_256}
use aiken/primitive/bytearray
use cardano/transaction.{OutputReference}

/// The only envelope version this application admits.
pub const envelopeVersion: Int = 1

/// The registry an envelope names: the full native asset of its state
/// token.
pub type StateAsset {
  statePolicy: ByteArray,
  stateName: ByteArray,
}

/// The protected part of an envelope. Nothing an update does may change
/// it.
pub type Control {
  version: Int,
  registry: StateAsset,
  activePolicy: ByteArray,
  key: ByteArray,
  controller: ByteArray,
  deposit: Int,
}

/// An open-datum output's inline datum.
pub type Envelope {
  control: Control,
  payload: Data,
}

/// The mint redeemer: which booking the minted approval certifies.
///
/// `BookInsert` certifies an `insertActive` request whose destination is
/// this script's address at `address`, carrying this `envelope` inline.
/// `BookTerminate` certifies an `updateTerminal` request for the live
/// output at `holding`, which the transaction reads as a reference input.
/// The edge is the constructor; a terminate names no destination.
pub type OpenDatumMint {
  BookInsert {
    key: ByteArray,
    owner: ByteArray,
    address: ByteArray,
    envelope: Envelope,
  }
  BookTerminate { key: ByteArray, owner: ByteArray, holding: OutputReference }
}

/// The spend redeemer: an update of the payload, or the release of the
/// output inside the fold that terminates its key.
pub type OpenDatumSpend {
  Update
  Release
}

/// The registry identity bytes an envelope names: state policy followed
/// by state token name, the form the validator's parameter takes.
pub fn registryBytes(asset: StateAsset) -> ByteArray {
  bytearray.concat(asset.statePolicy, asset.stateName)
}

/// The BLAKE2b-256 of an envelope's serialised CBOR: the datum hash a
/// request names for the output that will carry it inline.
pub fn envelopeHash(envelope: Envelope) -> ByteArray {
  blake2b_256(cbor.serialise(envelope))
}
