//// ## Responsibility
//// Settle permanent-retirement deposits and rejected-request refunds.
////
//// ## Dependencies
//// Uses duty, refusal, lib and ledger types; called by registry/modify.
////
//// ## Assumptions
//// Admission, trie moves and token duties have already held. Rejected
//// rows carry positional refund floors in consumed-request order.
////
//// ## Invariants
//// Refund positions and per-payee sums both hold. Token carriers and the
//// state continuation cannot also settle an owner's separate obligation.

use aiken/collection/list.{foldl}
use aiken/collection/pairs
use aiken/crypto.{VerificationKeyHash}
use cardano/address.{Address, PaymentCredential}
use cardano/assets.{PolicyId, lovelace_of, quantity_of}
use cardano/transaction.{Output}
use lib
use registry/duty.{DeliverToken, Duty, ReturnDeposit}
use registry/refusal.{depositReturned}

/// Why an owner's summed floor is not paid, or `None`. Outputs eligible
/// under `settlesOf` count once toward their payment credential; short,
/// misdirected or missing payments return `deposit-returned`.
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
          if output.address.payment_credential == address.VerificationKey(owner) && lovelace_of(
            output.value,
          ) >= owed {
            refundFault(remaining, rest)
          } else {
            depositReturned()
          }
        [] -> depositReturned()
      }
  }
}

/// Permanent-retirement deposit floors, summed per owner payment key.
pub fn payeeOwed(duties: List<Duty>) -> Pairs<PaymentCredential, Int> {
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
}

/// Can this output settle an obligation of the fold? Off the cage's own
/// payment credential (the continuation sits there) and
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
