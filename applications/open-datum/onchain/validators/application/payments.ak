//// What a transaction owes the addresses of the registrations it spends.
////
//// ## Responsibility
//// Counts the lovelace a transaction pays to an address and decides whether
//// it covers the payments the spent registrations require, summing the
//// payments owed to one address before comparing.
////
//// ## Dependencies
//// The Aiken standard library.
////
//// ## Assumptions
//// An address is paid by the outputs whose address is equal to it, the stake
//// part included.
////
//// ## Invariants
//// Several payments owed to one address are covered together: one output
//// does not satisfy two payments.

use cardano/address.{Address}
use cardano/transaction.{Output}

/// A payment a spent registration requires: `amount` lovelace to `address`.
pub type Payment {
  address: Address,
  amount: Int,
}

/// Model `paidTo`: the lovelace the outputs pay to `address`.
pub fn paid_to(_outputs: List<Output>, _address: Address) -> Int {
  0
}

/// Model conjunct `moneyOutputs` of `requestValueSplit`: for every payment,
/// all the payments owed to its address, together, are within what the
/// outputs pay to that address.
pub fn payments_covered(
  _payments: List<Payment>,
  _outputs: List<Output>,
) -> Bool {
  False
}
