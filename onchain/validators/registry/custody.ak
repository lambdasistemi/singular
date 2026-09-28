//// The cage's own custody of absent tokens (#157 D-CUSTODY).
////
//// ## Responsibility
////
//// Everything the state validator knows about an `AbsentCustody` UTxO: its
//// one spending path (`validCustodySpend`, dispatched by `state` for a
//// custody datum), and reading a custody UTxO's identity, refund address and
//// lovelace for the fold that consumes it (`custodyKeyOf`, `custodyDatumIs`,
//// `custodyInput`).
////
//// ## Dependencies
////
//// Imports `types` (datum shapes), `lib` (edge numbers, token and address
//// helpers) and `registry/refusal`. Imported by `state`, and by
//// `registry/discharge` and `registry/settlement`, which read the custody a
//// fold locks or consumes. It imports no fold owner: the custody spend does
//// not run the fold, it requires the fold's state input to be spent with
//// `Modify` in the same transaction, which makes the ledger run the state
//// validator's fold on it.
////
//// ## Assumptions
////
//// - A custody UTxO carries exactly one non-ADA asset, at quantity one, and
////   an inline `AbsentCustody` datum naming the refund address; anything
////   else is not interpreted as custody for any key.
//// - The ledger runs the state validator on every input it spends, so a
////   state input spent with `Modify` is validated by the fold whatever this
////   module concludes.
////
//// ## Invariants
////
//// - A custody UTxO is spent only beside exactly one input at its own
////   address that holds a state datum and is spent with `Modify`; its asset's
////   policy is that state's absent policy; a request of that state's cage
////   token, for its key, with edge 2 (`updateActive`) or edge 4
////   (`deleteAbsent`) is an input; and an output pays its refund address at
////   least its lovelace. Every other spend refuses `custody-spend`.
//// - Which datum or redeemer arm a neighbouring UTxO carries is decided on
////   the constructor tag alone, never by decoding its payload.

use aiken/collection/list.{filter}
use aiken/collection/pairs
use cardano/address
use cardano/address.{Address}
use cardano/assets
use cardano/assets.{PolicyId, Value, lovelace_of}
use cardano/transaction.{
  Spend, Datum, InlineDatum, Input, OutputReference, Transaction,
}
use lib.{edgeDeleteAbsent, edgeUpdateActive, paysAddress, tokenFromPolicy}
use registry/refusal.{traceFalse}
use types.{AbsentCustody, CageDatum, RequestDatum, StateDatum, TokenId}

/// The cage's own spending path for a custody UTxO: spent in a `Modify`
/// of THIS registry that consumes a request for ITS key with edge 2
/// (`updateActive`) or edge 4 (`deleteAbsent`), and nothing else. A plain
/// spend, a fold for another key, a fold whose request for this key is a
/// read, and a fold of another registry sharing the state script all
/// refuse here. The refund leg is the fold's duty (`refund`), checked by
/// `validModify` on the same transaction.
pub fn validCustodySpend(
  refund: ByteArray,
  self: Input,
  tx: Transaction,
) -> Bool {
  when (custodyKeyOf(self.output.value), foldAuthenticated(self.output.address, tx)) is {
    (Some((custodyPolicy, key)), Some((cageToken, absentPolicy))) ->
      if custodyPolicy != absentPolicy {
        traceFalse(@"custody-spend")
      } else if filter(
        tx.inputs,
        fn(i) { consumesAbsent(i.output.datum, key, cageToken) },
      ) == [] {
        traceFalse(@"custody-spend")
      } else if !paysAddressSomewhere(refund, self, tx) {
        traceFalse(@"custody-spend")
      } else {
        True
      }
    _ ->
      // The fold itself, authenticated: the registry's own state token,
      // at the cage's own address, SPENT with `Modify`. Without it a
      // request-shaped neighbour would be enough, and custody would be
      // spendable outside the fold that is supposed to consume it.
      traceFalse(@"custody-spend")
  }
}

/// Is this transaction a fold of the registry this custody belongs to,
/// and if so, which registry (#157 F-001, NOTE-004)?
///
/// Exactly one input at the cage's OWN address, carrying the state datum,
/// SPENT with `Modify` — and the answer is that state's own cage token.
/// The `Modify` is not a label a caller can assert: the ledger cannot let
/// such an input be spent without executing this very validator on it,
/// and `validModify` then proves the state token, the preserved pins, the
/// new root and the minted deltas. Answering the token, rather than a
/// bare yes, is what stops one registry's fold from authorizing another's
/// custody when both are held by this same script: the caller must then
/// show a request bound to the very registry whose fold it rode in on.
fn foldAuthenticated(
  cageAddress: Address,
  tx: Transaction,
) -> Option<(TokenId, PolicyId)> {
  when
    filter(
      tx.inputs,
      fn(i) {
        i.output.address == cageAddress && holdsState(i.output.datum) && spentModifying(
          i.output_reference,
          tx,
        )
      },
    )
  is {
    [stateIn] ->
      when cageAddress.payment_credential is {
        address.Script(policyId) ->
          when
            (
              tokenFromPolicy(policyId, stateIn.output.value),
              stateAbsentPolicy(stateIn.output.datum),
            )
          is {
            (Some(cageToken), Some(absentPolicy)) ->
              Some((cageToken, absentPolicy))
            _ -> None
          }
        _ -> None
      }
    _ -> None
  }
}

/// `CageDatum`'s constructor tags, with the payloads left as `Data`
/// (#157 F-001). Which arm a neighbouring UTxO carries is all this needs
/// to know, and deciding it on the tag costs a fraction of decoding the
/// eight-field state a second time.
type DatumTag {
  RequestTag(Data)
  StateTag(Data)
  CustodyTag(Data)
}

fn stateAbsentPolicy(datum: Datum) -> Option<PolicyId> {
  when datum is {
    InlineDatum(inline) ->
      if inline is StateDatum(pins): CageDatum {
        Some(pins.absent_policy)
      } else {
        None
      }
    _ -> None
  }
}

/// `UpdateRedeemer`'s constructor tags, likewise: the real redeemer
/// carries the batch's whole MPF proofs, and this asks only which arm it
/// is.
type RedeemerTag {
  EndTag
  ContributeTag(Data)
  ModifyTag(Data)
  RetractTag(Data)
  SweepTag(Data)
}

fn holdsState(datum: Datum) -> Bool {
  when datum is {
    InlineDatum(inline) ->
      if inline is StateTag(_): DatumTag {
        True
      } else {
        False
      }
    _ -> False
  }
}

fn spentModifying(reference: OutputReference, tx: Transaction) -> Bool {
  when pairs.get_first(tx.redeemers, Spend(reference)) is {
    Some(data) ->
      if data is ModifyTag(_): RedeemerTag {
        True
      } else {
        False
      }
    None -> False
  }
}

/// A request datum of THIS registry, for this key, whose edge consumes
/// the absent token: edge 2 (`updateActive`) or edge 4 (`deleteAbsent`;
/// #183 slice b).
///
/// The `requestToken` binding (NOTE-004) is what makes the authenticated
/// fold above conclusive rather than circumstantial: `validModify`
/// processes only the requests naming its own cage token, so a request
/// carrying this token is one that fold must have processed. Without it a
/// second registry on the same script could lend its `Modify` to a
/// request it will never touch.
fn consumesAbsent(datum: Datum, key: ByteArray, cageToken: TokenId) -> Bool {
  when datum is {
    InlineDatum(inline) ->
      if inline is RequestDatum(request): CageDatum {
        request.requestKey == key && request.requestToken == cageToken && (
          request.edge == edgeUpdateActive || request.edge == edgeDeleteAbsent
        )
      } else {
        False
      }
    _ -> False
  }
}

fn paysAddressSomewhere(refund: ByteArray, self: Input, tx: Transaction) -> Bool {
  let owed = lovelace_of(self.output.value)
  filter(
    tx.outputs,
    fn(out) { paysAddress(refund, out) && lovelace_of(out.value) >= owed },
  ) != []
}

/// The custody identity encoded by the complete non-ADA value extent.
/// Exactly one asset at quantity one is admissible; zero, extra, wrong-policy
/// and wrong-quantity extents cannot be interpreted as custody for a key.
pub fn custodyKeyOf(value: Value) -> Option<(PolicyId, ByteArray)> {
  when
    filter(
      assets.flatten(value),
      fn(entry) {
        let (policy, _, _) = entry
        policy != #""
      },
    )
  is {
    [(policy, key, 1)] -> Some((policy, key))
    _ -> None
  }
}

fn custodyRefundOf(datum: Datum) -> Option<ByteArray> {
  when datum is {
    InlineDatum(inline) ->
      if inline is AbsentCustody { refund }: CageDatum {
        Some(refund)
      } else {
        None
      }
    _ -> None
  }
}

/// Does this output datum inline an `AbsentCustody` that records exactly
/// `refund`? A datum hash, no datum or another arm answers `False`.
pub fn custodyDatumIs(datum: Datum, refund: ByteArray) -> Bool {
  when datum is {
    InlineDatum(inline) ->
      if inline is AbsentCustody { refund: heldRefund }: CageDatum {
        heldRefund == refund
      } else {
        False
      }
    _ -> False
  }
}

/// The custody UTxO for this key among the spent inputs, with the refund
/// address it recorded and the lovelace it holds.
pub fn custodyInput(
  cageAddress: Address,
  policy: PolicyId,
  key: ByteArray,
  inputs: List<Input>,
) -> Option<(ByteArray, Int)> {
  when
    filter(
      inputs,
      fn(i) {
        i.output.address == cageAddress && custodyKeyOf(i.output.value) == Some((
          policy,
          key,
        ))
      },
    )
  is {
    [held] -> {
      expect Some(refund) = custodyRefundOf(held.output.datum)
      Some((refund, lovelace_of(held.output.value)))
    }
    _ -> None
  }
}
