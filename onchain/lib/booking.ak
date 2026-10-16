//// ## Responsibility
//// Registration booking: the two canonical tag names and the one judgement
//// the request policy's mint handler enforces. Pure values; no application
//// policy logic.
////
//// ## Dependencies
//// `types` only for the datum vocabulary; the Aiken standard library for
//// the hash and the data encoding.
////
//// ## Assumptions
//// The ledger supplies the executing policy id, the transaction and its
//// validity range as presented. The application policy owns its own
//// authorization rule; this module checks only that its tag is present,
//// exactly named and minted in the same booking.
////
//// ## Invariants
//// A registration is born authenticated: the request output holds exactly
//// the declared cost, tip and carrier, one correctly named application tag
//// and one correctly named trie-ready tag, both minted with it, and its
//// booked time is the finite upper end of a bounded interval.

use aiken/crypto.{VerificationKeyHash}
use cardano/assets.{PolicyId}
use cardano/transaction.{Transaction}
use types.{RegistrationRequest, TokenId}

/// The application tag name of a registration: `blake2b_256` of the data
/// encoding of `[0, 1, key, refund_address, destination, nonce]`, the list
/// the Lean model hashes (`applicationTagAssetName`).
pub fn applicationTagName(
  _key: ByteArray,
  _refund_address: VerificationKeyHash,
  _destination: ByteArray,
  _nonce: Int,
) -> ByteArray {
  #""
}

/// The trie-ready tag name of a registration: `blake2b_256` of the data
/// encoding of `[1, 0, key, refund_address, destination, cost, tip,
/// carrier, nonce]` (`trieReadyTagAssetName` of a registration operation).
pub fn trieReadyTagName(_request: RegistrationRequest) -> ByteArray {
  #""
}

/// Why this transaction is not an authenticated registration booking, or
/// `None` when it is. The reasons are the model's, in the model's order.
pub fn registrationBookingRefusal(
  _statePolicyId: PolicyId,
  _cageToken: TokenId,
  _policyId: PolicyId,
  _tx: Transaction,
) -> Option<String> {
  Some(@"unimplemented")
}
