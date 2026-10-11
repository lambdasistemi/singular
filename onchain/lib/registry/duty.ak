//// What an admitted request still owes the transaction (#157 token-destinations-and-refunds).
////
//// ## Responsibility
////
//// The `Duty` a fold collects for each admitted edge, read off the edge and
//// the request (`dutiesOf`), and the accumulation of those duties over a
//// batch (`pushDuties`, `pushDuty`). Collecting duties during the fold and
//// discharging them after it keeps the trie walk and the value walk apart,
//// each with its own refusal reasons.
////
//// ## Dependencies
////
//// Imports `types` (the pinned `State`) and `lib` (the edge numbers).
//// Imported by `registry/fold`, which collects duties, and by
//// `registry/discharge` and `registry/settlement`, which discharge them.
//// It decides nothing about the transaction and names no refusal.
////
//// ## Assumptions
////
//// - `dutiesOf` is called only for an edge the fold admitted (tags 1 and 3) and
////   that is not a rejected row; every other tag creates no duties and is refused by admission.
//// - `floor` is the request's deposit: its lovelace less the pinned tip.
////
//// ## Invariants
////
//// - A duty is derived from the edge table and the request alone, never from
////   anything the folder declares.
//// - Two deliveries of the same `(policy, key)` merge into one `DeliverToken`
////   whose `count` and `floor` are the sums and whose `agreed` is false unless
////   every merged request named the same destination: one asset cannot sit
////   in two outputs, so a second deposit cannot be pocketed.
//// - Every other duty is prepended unmerged, so none is lost or combined.

use aiken/crypto.{VerificationKeyHash}
use cardano/assets.{PolicyId}
use lib.{edgeInsertActive, edgeUpdateTerminal}
use types.{State}

/// What one consumed request still owes the transaction once its edge is
/// admitted (#157 token-destinations-and-refunds). Collected during the fold, discharged after it, so
/// the trie walk and the value walk stay separate and each names its own
/// reason.
pub type Duty {
  /// A minted active token must land in exactly one output,
  /// the one the request named, holding at least `floor` lovelace.
  ///
  /// Two requests in one batch can mint the same `(policy, key)` — repeated deliveries — and one asset cannot be in two
  /// outputs at once, so their duties MERGE rather than stack: `count`
  /// is how many tokens the single carrier must hold and `floor` the SUM
  /// of the deposits it owes, so a folder cannot return one deposit and
  /// pocket the other. `agreed` is false when the merged requests named
  /// different destinations, which no single output can satisfy.
  DeliverToken {
    policy: PolicyId,
    key: ByteArray,
    destination: (ByteArray, Option<Data>),
    floor: Int,
    count: Int,
    agreed: Bool,
  }
  /// A burned active token must actually be an input; the cage does not
  /// care where it came from — the application's custody does.
  ///
  /// Exactly one input must carry exactly one unit of the active witness.
  /// With the pinned burn of one, ledger conservation leaves none in outputs.
  BurnFromInput { policy: PolicyId, key: ByteArray }
  /// Lovelace owed to an owner's key (#253): the deposit of a fold that
  /// delivers nothing (termination) and the refund of a rejected
  /// row. `payeeOwed` sums them per key, and each key is settled with every
  /// other obligation to it
  ///  on the summed lovelace of the outputs
  /// paying it (`payeeFault`): one output cannot pay two obligations.
  ReturnDeposit { owner: VerificationKeyHash, floor: Int }
}

/// The duties an admitted edge creates (#157 token-destinations-and-refunds). Read off the edge and
/// the request, never off anything the folder declares. An edge that
/// delivers no token (3) owes its deposit to the request's owner
/// (#253); the others owe it with the token they deliver.
pub fn dutiesOf(
  pins: State,
  edge: Int,
  owner: VerificationKeyHash,
  key: ByteArray,
  destination: (ByteArray, Option<Data>),
  floor: Int,
) -> List<Duty> {
  if edge == edgeInsertActive {
    [
      DeliverToken {
        policy: pins.active_policy,
        key,
        destination,
        floor,
        count: 1,
        agreed: True,
      },
    ]
  } else if edge == edgeUpdateTerminal {
    [
      BurnFromInput { policy: pins.active_policy, key },
      ReturnDeposit { owner, floor },
    ]
  } else {
    []
  }
}

/// Add one edge's duties to the accumulated list, merging a delivery
/// into an existing one for the same `(policy, key)`: one asset cannot
/// sit in two outputs, so two requests minting it owe ONE carrier, with
/// both tokens and both deposits in it.
pub fn pushDuties(existing: List<Duty>, fresh: List<Duty>) -> List<Duty> {
  when fresh is {
    [] -> existing
    [duty, ..rest] -> pushDuties(pushDuty(existing, duty), rest)
  }
}

/// Add one duty to the accumulated list: a `DeliverToken` merges into an
/// existing delivery of the same `(policy, key)`, any other duty is
/// prepended.
pub fn pushDuty(existing: List<Duty>, duty: Duty) -> List<Duty> {
  when duty is {
    DeliverToken { policy, key, destination, floor, count, agreed } ->
      mergeDeliver(existing, policy, key, destination, floor, count, agreed)
    _ -> [duty, ..existing]
  }
}

fn mergeDeliver(
  existing: List<Duty>,
  policy: PolicyId,
  key: ByteArray,
  destination: (ByteArray, Option<Data>),
  floor: Int,
  count: Int,
  agreed: Bool,
) -> List<Duty> {
  when existing is {
    [] -> [DeliverToken { policy, key, destination, floor, count, agreed }]
    [head, ..rest] ->
      when head is {
        DeliverToken {
          policy: heldPolicy,
          key: heldKey,
          destination: heldDestination,
          floor: heldFloor,
          count: heldCount,
          agreed: heldAgreed,
        } ->
          if heldPolicy == policy && heldKey == key {
            [
              DeliverToken {
                policy,
                key,
                destination: heldDestination,
                floor: heldFloor + floor,
                count: heldCount + count,
                agreed: heldAgreed && agreed && heldDestination == destination,
              },
              ..rest
            ]
          } else {
            [
              head,
              ..mergeDeliver(
                rest,
                policy,
                key,
                destination,
                floor,
                count,
                agreed,
              )
            ]
          }
        _ ->
          [
            head,
            ..mergeDeliver(rest, policy, key, destination, floor, count, agreed)
          ]
      }
  }
}
