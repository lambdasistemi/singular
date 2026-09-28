//// Discharging each collected duty against the transaction (#157 C6, #177).
////
//// ## Responsibility
////
//// Once the fold has walked every request, `dutiesFault` checks each
//// collected `Duty` in order against the transaction's outputs and inputs:
//// a delivered token sits in the one output its request named with its
//// deposit, an absent token sits in the cage's own custody, and a burned
//// active token is an input. Lovelace owed to payees and custody refunds is
//// not settled here but by `registry/settlement`, after every duty holds.
////
//// ## Dependencies
////
//// Imports `registry/duty` (the duties), `registry/custody` (reading a
//// custody output), `registry/refusal` (`deposit-returned`), `types` and
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
//// - An absent token's carrier is the only output holding it, at the cage's
////   address, with exactly that one asset and a custody datum recording the
////   request's refund address; otherwise `absent-custody` or
////   `deposit-returned`.
//// - `deleteActive` requires some input carrying the burned asset
////   (`burn-from-input`); a retirement requires exactly one input carrying
////   exactly one (`token-missing`).
//// - `SpendCustody` and `ReturnDeposit` are always discharged here without a
////   check; their lovelace is settled by `registry/settlement`.

use aiken/collection/list.{filter}
use cardano/address.{Address}
use cardano/assets.{PolicyId, lovelace_of, quantity_of}
use cardano/transaction.{Output, Transaction}
use lib.{destinationMatches}
use registry/custody.{custodyDatumIs, custodyKeyOf}
use registry/duty.{
  BurnFromInput, DeliverToken, Duty, LockCustody, ReturnDeposit, SpendCustody,
}
use registry/refusal.{depositReturned}
use types.{State}

/// Why the transaction does not discharge the fold's collected `duties`, or
/// `None` when every one holds. Checked in order; the first fault is the
/// reason, and `SpendCustody` and `ReturnDeposit` always pass here.
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
    LockCustody { key, refund, floor } -> {
      let carriers = carriersOf(tx.outputs, pins.absent_policy, key)
      when carriers is {
        [carrier] ->
          if custodyKeyOf(carrier.value) != Some((pins.absent_policy, key)) || carrier.address != cageAddress || !custodyDatumIs(
            carrier.datum,
            refund,
          ) {
            Some(@"absent-custody")
          } else if lovelace_of(carrier.value) < floor {
            depositReturned()
          } else {
            None
          }
        _ -> Some(@"absent-custody")
      }
    }
    // Found and settled with the fold's other custody refunds to the same
    // address once every other duty holds (`custodyOwedOf`, #253).
    SpendCustody { .. } -> None
    BurnFromInput { policy, key, sole } -> {
      // #177 I177-CHAIN. `sole` is the whole difference between the two
      // burning edges, and the reason each gives.
      //
      // `deleteActive` (edge 5) asks only that SOME input carries the
      // asset, and traces `burn-from-input`. The RETIREMENT asks that
      // the transaction present THIS key's ONE witness — exactly one
      // input carrying exactly one — and traces Lean's `token-missing`.
      // Sharing one constructor keeps edge 5's decision table and trace
      // exactly where they were.
      //
      // The strict form is what settles the Lean row's
      // `kindCount t.state .active r.key = 0`: with one unit on an
      // input and the mint pinned at `-1` by C5, ledger conservation
      // leaves the outputs carrying none. No separate output rule is
      // added for the two to disagree over.
      //
      // Both ways of failing the strict form are the same fact about an
      // unreachable state: under `Reachable`,
      // `biconditional_supply_sync` makes a `Known Active` leaf and
      // exactly one outstanding active token the same thing, so neither
      // zero witnesses nor two is a story a user can tell.
      let carriers =
        filter(
          tx.inputs,
          fn(i) { quantity_of(i.output.value, policy, key) != 0 },
        )
      if !sole {
        if carriers != [] {
          None
        } else {
          Some(@"burn-from-input")
        }
      } else {
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
    }
    // Settled per payee after every other duty and the positional
    // refunds (`payeeFault`), so every earlier refusal keeps its reason.
    ReturnDeposit { .. } -> None
  }
}

/// Why a minted active or terminal token's delivery fails, or `None`
/// (#157 C6, T1, T6).
///
/// `deposit-returned` is T6 / want-ledger R4: no folder incentive exists
/// in this version, so the deposit that rode the request returns with
/// the token. The folder earns the tip and nothing else. `floor` is the
/// SUM over the requests that share this carrier, so a second deposit
/// cannot be pocketed.
fn deliveryFault(
  outputs: List<Output>,
  policy: PolicyId,
  key: ByteArray,
  destination: (ByteArray, ByteArray),
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
/// Its own site, distinct from `deleteActive`'s generic
/// `burn-from-input`, so edge 5's trace keeps meaning what it meant.
pub fn tokenMissingRefusal() -> String {
  @"token-missing"
}
