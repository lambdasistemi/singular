//// Discharging each collected duty against the transaction (#157 token-destinations-and-refunds, #177).
////
//// ## Responsibility
////
//// Once the fold has walked every request, `dutiesFault` checks each
//// collected `Duty` in order against the transaction's outputs and inputs:
//// a delivered active token sits in the output its request named with its
//// deposit, and a retirement consumes its one active witness. Lovelace
//// owed to payees is settled by `registry/settlement` after duties hold.
////
//// ## Dependencies
////
//// Imports `registry/duty` (the duties), `registry/refusal` (`deposit-returned`), `types` and
//// `lib`. Imported by `registry/modify`, and by the Aiken suite for the
//// `token-missing` reason.
////
//// ## Assumptions
////
//// - The fold has already refused anything its trie walk, admission or mint
////   check refuses; duties are discharged only for a fold that reached here.
//// - `cageAddress` is the address of the state input being spent.
////
//// ## Invariants
////
//// - Duties are checked in list order and the first failing duty's reason is
////   the answer, so exactly one reason is reported.
//// - A delivered token's carrier is the only output holding that asset, holds
////   exactly the merged count, matches the named destination and holds at
////   least the summed deposit; otherwise `destination` or `deposit-returned`.
//// - Retirement requires exactly one input carrying exactly one active
////   witness (`token-missing`).
//// - `ReturnDeposit` is settled by `registry/settlement`.

use aiken/collection/list.{filter}
use cardano/address.{Address}
use cardano/assets.{PolicyId, lovelace_of, quantity_of}
use cardano/transaction.{Output, Transaction}
use lib.{destinationMatches}
use registry/duty.{BurnFromInput, DeliverToken, Duty, ReturnDeposit}
use registry/refusal.{depositReturned}
use types.{State}

/// Why the transaction does not discharge the fold's collected `duties`, or
/// `None` when every one holds. Checked in order; the first fault is the
/// reason, and `ReturnDeposit` always pass here.
pub fn dutiesFault(
  pins: State,
  cageAddress: Address,
  duties: List<Duty>,
  tx: Transaction,
) -> Option<String> {
  when duties is {
    [] -> None
    [duty, ..rest] ->
      when dutyFault(pins, cageAddress, duty, tx) is {
        None -> dutiesFault(pins, cageAddress, rest, tx)
        refusal -> refusal
      }
  }
}

fn dutyFault(
  pins: State,
  cageAddress: Address,
  duty: Duty,
  tx: Transaction,
) -> Option<String> {
  when duty is {
    DeliverToken { policy, key, destination, floor, count, agreed } ->
      deliveryFault(tx.outputs, policy, key, destination, floor, count, agreed)
    BurnFromInput { policy, key } -> {
      // A retirement consumes exactly one active witness.
      let carriers =
        filter(
          tx.inputs,
          fn(i) { quantity_of(i.output.value, policy, key) != 0 },
        )
      when carriers is {
        [source] ->
          if quantity_of(source.output.value, policy, key) == 1 {
            None
          } else {
            Some(tokenMissingRefusal())
          }
        _ -> Some(tokenMissingRefusal())
      }
    }

    // Settled per payee after every other duty and the positional
    // refunds (`payeeFault`), so every earlier refusal keeps its reason.
    ReturnDeposit { .. } -> None
  }
}

/// Why a minted active or terminal token's delivery fails, or `None`
/// (#157 token-destinations-and-refunds, active-token-requested-destination, request-deposit-returned).
///
/// `deposit-returned` is request-deposit-returned / the deposit-return requirement: no folder incentive exists
/// in this version, so the deposit that rode the request returns with
/// the token. The folder earns the tip and nothing else. `floor` is the
/// SUM over the requests that share this carrier, so a second deposit
/// cannot be pocketed.
fn deliveryFault(
  outputs: List<Output>,
  policy: PolicyId,
  key: ByteArray,
  destination: (ByteArray, Option<Data>),
  floor: Int,
  count: Int,
  agreed: Bool,
) -> Option<String> {
  when carriersOf(outputs, policy, key) is {
    [carrier] ->
      if !agreed || quantity_of(carrier.value, policy, key) != count || !destinationMatches(
        destination,
        carrier,
      ) {
        Some(@"destination")
      } else if lovelace_of(carrier.value) < floor {
        depositReturned()
      } else {
        None
      }
    _ -> Some(@"destination")
  }
}

fn carriersOf(
  outputs: List<Output>,
  policy: PolicyId,
  key: ByteArray,
) -> List<Output> {
  filter(outputs, fn(out) { quantity_of(out.value, policy, key) != 0 })
}

/// Why a retirement whose key IS `Active` still refuses: the
/// transaction does not present that key's one active witness for the
/// burn to destroy (#177 I177-CHAIN). Lean: `token-missing`.
///
pub fn tokenMissingRefusal() -> String {
  @"token-missing"
}
