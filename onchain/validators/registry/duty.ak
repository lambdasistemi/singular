//// What an admitted request still owes the transaction (#157 C6).
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
//// - `dutiesOf` is called only for an edge the fold admitted (`0..6`) and
////   that is not a rejected row; any edge outside the ones it names is
////   treated as `deleteActive` (edge 5).
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
use lib.{
  edgeDeleteAbsent, edgeInsertAbsent, edgeInsertActive, edgeUpdateActive,
  edgeUpdateTerminal, edgeWitnessTerminal,
}
use types.{State}

/// What one consumed request still owes the transaction once its edge is
/// admitted (#157 C6). Collected during the fold, discharged after it, so
/// the trie walk and the value walk stay separate and each names its own
/// reason.
pub type Duty {
  /// A minted active or terminal token must land in exactly one output,
  /// the one the request named, holding at least `floor` lovelace.
  ///
  /// Two requests in one batch can mint the same `(policy, key)` — two
  /// reads of one terminal name — and one asset cannot be in two
  /// outputs at once, so their duties MERGE rather than stack: `count`
  /// is how many tokens the single carrier must hold and `floor` the SUM
  /// of the deposits it owes, so a folder cannot return one deposit and
  /// pocket the other. `agreed` is false when the merged requests named
  /// different destinations, which no single output can satisfy.
  DeliverToken {
    policy: PolicyId,
    key: ByteArray,
    destination: (ByteArray, ByteArray),
    floor: Int,
    count: Int,
    agreed: Bool,
  }
  /// A minted absent token must land in the cage's own custody, beside
  /// its key and the refund address the request named.
  LockCustody { key: ByteArray, refund: ByteArray, floor: Int }
  /// A consumed absent token's custody UTxO must be spent here, and its
  /// lovelace paid to the address that custody recorded — summed with
  /// every other custody refund to that address, and with every other
  /// obligation to its payment credential (#253, `payeeFault`).
  SpendCustody { key: ByteArray }
  /// A burned active token must actually be an input; the cage does not
  /// care where it came from — the application's custody does.
  ///
  /// `sole` is what #177 added, and it is the difference between the
  /// two burning edges. `deleteActive` (edge 5) asks only that SOME
  /// input carries the asset, and traces `burn-from-input`; the
  /// RETIREMENT asks that the transaction present THIS key's one
  /// witness — exactly one input carrying exactly one — and traces
  /// Lean's `token-missing`. Sharing one constructor keeps edge 5's
  /// decision table and trace exactly where they were.
  ///
  /// That one fact also settles the Lean row's `kindCount t.state
  /// .active r.key = 0`: with one unit on an input and the mint pinned
  /// at `-1` by C5, ledger conservation leaves the outputs carrying
  /// none. No separate output rule is added for the two to disagree
  /// over.
  BurnFromInput { policy: PolicyId, key: ByteArray, sole: Bool }
  /// Lovelace owed to an owner's key (#253): the deposit of a fold that
  /// delivers nothing (edges 3, 4 and 5) and the refund of a rejected
  /// row. `payeeOwed` sums them per key, and each key is settled with every
  /// other obligation to it
  /// — custody refunds included — on the summed lovelace of the outputs
  /// paying it (`payeeFault`): one output cannot pay two obligations.
  ReturnDeposit { owner: VerificationKeyHash, floor: Int }
}

/// The duties an admitted edge creates (#157 C6). Read off the edge and
/// the request, never off anything the folder declares. An edge that
/// delivers no token (3, 4, 5) owes its deposit to the request's owner
/// (#253); the others owe it with the token they deliver.
pub fn dutiesOf(
  pins: State,
  edge: Int,
  owner: VerificationKeyHash,
  key: ByteArray,
  destination: (ByteArray, ByteArray),
  floor: Int,
) -> List<Duty> {
  let (refund, _) = destination
  // Note: the merge fields start at one duty; `pushDuties` folds a second
  // request for the same token into the same carrier.
  if edge == edgeInsertAbsent {
    [LockCustody { key, refund, floor }]
  } else if edge == edgeInsertActive {
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
  } else if edge == edgeUpdateActive {
    [
      SpendCustody { key },
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
      BurnFromInput { policy: pins.active_policy, key, sole: True },
      ReturnDeposit { owner, floor },
    ]
  } else if edge == edgeDeleteAbsent {
    [SpendCustody { key }, ReturnDeposit { owner, floor }]
  } else if edge == edgeWitnessTerminal {
    [
      DeliverToken {
        policy: pins.terminal_policy,
        key,
        destination,
        floor,
        count: 1,
        agreed: True,
      },
    ]
  } else {
    // `deleteActive` (edge 5) burns the active token the request names;
    // the cage requires it as an input, exactly as the terminal update
    // does.
    [
      BurnFromInput { policy: pins.active_policy, key, sole: False },
      ReturnDeposit { owner, floor },
    ]
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
  destination: (ByteArray, ByteArray),
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
