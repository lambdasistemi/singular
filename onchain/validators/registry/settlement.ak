//// Settling the lovelace a fold owes its payees (#253, NOTE-014, NOTE-017).
////
//// ## Responsibility
////
//// After every duty is discharged, the fold's lovelace obligations are
//// settled: custody refunds summed per refund address (`custodyOwedOf`,
//// `custodyFault`), rejected rows' refunds paid positionally
//// (`refundFault`), and every obligation to one payment credential paid
//// once on the summed lovelace of the outputs paying it (`payeeOwed`,
//// `payeeFault`). `settlesOf` decides which outputs may settle anything.
////
//// ## Dependencies
////
//// Imports `registry/duty` (the duties), `registry/custody` (reading the
//// spent custody UTxO), `registry/refusal` (`deposit-returned`, `refund`),
//// `types` and `lib`. Imported by the `Modify` decision in `state`.
////
//// ## Assumptions
////
//// - Every duty has already been discharged (`registry/discharge`), so each
////   delivered token sits in its one carrier and each custody spent here is
////   the one its `SpendCustody` names.
//// - The refund outputs `refundFault` reads are the outputs after the state
////   continuation, and the refunds are in the order the rows were consumed.
////
//// ## Invariants
////
//// - In the summed checks an output counts toward a payee only if it is off
////   the cage's payment credential and carries none of the tokens the fold
////   delivers, and it counts once: one output never pays two obligations.
//// - Custody refunds to one address are summed, so two custodies refunding
////   one address are not paid by one output holding the larger; a short sum
////   refuses `refund`. A consumed custody that is not spent here, or records
////   an address that decodes to nothing, has no owed sum (`custodyOwedOf`
////   answers `None`), which the `Modify` decision also refuses `refund`.
//// - A short, misdirected or missing payment to an owner's key refuses
////   `deposit-returned`, whether positional or summed.

use aiken/collection/list
use aiken/collection/list.{foldl}
use aiken/collection/pairs
use aiken/crypto.{VerificationKeyHash}
use cardano/address
use cardano/address.{Address, PaymentCredential}
use cardano/assets.{PolicyId, lovelace_of, quantity_of}
use cardano/transaction.{Input, Output}
use lib
use registry/custody.{custodyInput}
use registry/duty.{DeliverToken, Duty, ReturnDeposit, SpendCustody}
use registry/refusal.{depositReturned, refundShort}
use types.{State}

/// Why a payee of this fold is not paid what the fold owes it, or `None`
/// (#253, DM-C2). `owed` is one floor per payment credential: the
/// deposits of the edges that deliver nothing (3, 4, 5) and the refunds
/// of rejected rows, at the owner's key, and the custody refunds, at the
/// payment credential of the address each custody recorded — summed.
///
/// A payee is paid the summed lovelace of the outputs that can settle (`settlesOf`)
/// whose payment credential is theirs, so each output counts once and
/// one output never pays two obligations. A short, misdirected or
/// missing payment is `deposit-returned`: the lovelace one output owes
/// cannot be told apart by obligation once they share a payee, and every
/// one of them is a deposit going back — a custody refund is the
/// inserter's own deposit, held since edge 0.
pub fn payeeFault(
  outputs: List<Output>,
  settles: fn(Output) -> Bool,
  owed: Pairs<PaymentCredential, Int>,
) -> Option<String> {
  if settled(
    outputs,
    settles,
    owed,
    fn(payee, out) { out.address.payment_credential == payee },
  ) {
    None
  } else {
    depositReturned()
  }
}

/// The summed lovelace of the outputs `pays` selects.
fn paidWhere(outputs: List<Output>, pays: fn(Output) -> Bool) -> Int {
  foldl(
    outputs,
    0,
    fn(out, total) {
      if pays(out) {
        total + lovelace_of(out.value)
      } else {
        total
      }
    },
  )
}

/// Add `amount` to what `payee` is owed.
fn owe(owed: Pairs<k, Int>, payee: k, amount: Int) -> Pairs<k, Int> {
  when owed is {
    [] -> [Pair(payee, amount)]
    [Pair(held, floor), ..rest] ->
      if held == payee {
        [Pair(held, floor + amount), ..rest]
      } else {
        [Pair(held, floor), ..owe(rest, payee, amount)]
      }
  }
}

/// Is every payee paid at least what it is owed, counting the outputs
/// `pays` assigns to it that can settle an obligation (`settles`)? The
/// payee is matched first, so only its own outputs are checked further.
fn settled(
  outputs: List<Output>,
  settles: fn(Output) -> Bool,
  owed: Pairs<k, Int>,
  pays: fn(k, Output) -> Bool,
) -> Bool {
  list.all(
    owed,
    fn(entry) {
      let Pair(payee, floor) = entry
      paidWhere(outputs, fn(out) { pays(payee, out) && settles(out) }) >= floor
    },
  )
}

/// Why a refund address is not paid every custody refund of the fold that
/// names it, summed, or `None` (#253): two custodies refunding one address
/// are not paid by one output holding the larger of them.
pub fn custodyFault(
  outputs: List<Output>,
  settles: fn(Output) -> Bool,
  custodyOwed: Pairs<Address, Int>,
) -> Option<String> {
  if settled(
    outputs,
    settles,
    custodyOwed,
    fn(refund, out) { out.address == refund },
  ) {
    None
  } else {
    refundShort()
  }
}

/// Why the rejected rows' refunds are not paid positionally, or `None`
/// (NOTE-014 item A2): the outputs after the state continuation, in the
/// order the rows were consumed, each paying that row's owner key at
/// least what is owed. Unequal crossed allocations fail here even when
/// every credential passes and every total matches. A short, misdirected
/// or missing refund is `deposit-returned`, as for every other payment
/// the fold owes an owner (#253).
pub fn refundFault(
  outputs: List<Output>,
  owners: Pairs<VerificationKeyHash, Int>,
) -> Option<String> {
  when owners is {
    [] -> None
    [Pair(owner, owed), ..rest] ->
      when outputs is {
        [output, ..remaining] ->
          if output.address.payment_credential == address.VerificationKey(
            owner,
          ) && lovelace_of(output.value) >= owed {
            refundFault(remaining, rest)
          } else {
            depositReturned()
          }
        [] -> depositReturned()
      }
  }
}

/// The floors a fold owes its payees, one per payment credential (DM-C2):
/// each owner's deposits and reject refunds at their key, plus every
/// custody refund to an address with that key. A credential owed custody
/// refunds alone is left out: the per-address sums (`custodyFault`)
/// already hold there, since outputs at distinct addresses are distinct.
pub fn payeeOwed(
  duties: List<Duty>,
  custodyOwed: Pairs<Address, Int>,
) -> Pairs<PaymentCredential, Int> {
  let owners =
    foldl(
      duties,
      [],
      fn(duty, owed) {
        when duty is {
          ReturnDeposit { owner, floor } ->
            owe(owed, address.VerificationKey(owner), floor)
          _ -> owed
        }
      },
    )
  foldl(
    custodyOwed,
    owners,
    fn(entry, owed) {
      let Pair(refund, amount) = entry
      let payee = refund.payment_credential
      if pairs.has_key(owed, payee) {
        owe(owed, payee, amount)
      } else {
        owed
      }
    },
  )
}

/// The custody refunds a fold owes, summed per decoded refund address:
/// the lovelace of every custody UTxO its `SpendCustody` duties consume.
/// `None` when a consumed absent token's custody is not spent here, or
/// records an address that decodes to nothing: no output can pay it.
pub fn custodyOwedOf(
  pins: State,
  cageAddress: Address,
  duties: List<Duty>,
  inputs: List<Input>,
) -> Option<Pairs<Address, Int>> {
  foldl(
    duties,
    Some([]),
    fn(duty, found) {
      when (duty, found) is {
        (SpendCustody { key }, Some(owed)) ->
          when custodyInput(cageAddress, pins.absent_policy, key, inputs) is {
            Some((refund, value)) ->
              when lib.decodeAddress(refund) is {
                Some(address) -> Some(owe(owed, address, value))
                None -> None
              }
            None -> None
          }
        _ -> found
      }
    },
  )
}

/// Can this output settle an obligation of the fold? Off the cage's own
/// payment credential (the continuation and custody sit there) and
/// carrying none of the tokens the fold delivers, which owe their own
/// deposits. Each output counts once toward its payee.
pub fn settlesOf(
  cageCredential: PaymentCredential,
  duties: List<Duty>,
) -> fn(Output) -> Bool {
  let carried = carriedOf(duties)
  fn(out: Output) {
    out.address.payment_credential != cageCredential && !list.any(
      carried,
      fn(asset) {
        let (policy, key) = asset
        quantity_of(out.value, policy, key) != 0
      },
    )
  }
}

/// The `(policy, key)` of every token this fold delivers.
fn carriedOf(duties: List<Duty>) -> List<(PolicyId, ByteArray)> {
  list.foldr(
    duties,
    [],
    fn(duty, carried) {
      when duty is {
        DeliverToken { policy, key, .. } -> [(policy, key), ..carried]
        _ -> carried
      }
    },
  )
}
