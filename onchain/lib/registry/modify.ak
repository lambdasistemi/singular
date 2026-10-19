//// The `Modify` decision: whether a fold of the registry's state is valid,
//// and if not, the one reason why (Lean `Economics/Fold.lean` and
//// `Economics/FoldRouting.lean`).
////
//// ## Responsibility
////
//// `validFold` checks, in this order: the continuation output
//// (`continuation-address`, `state-token`, `fold-state-mismatch`,
//// `state-drain`, `fold-state-value-mismatch`) and the preserved pins
//// (`pins-altered`); then the transaction's inputs
//// (`request-observation-mismatch`, `empty-fold`, `rejected-retired`, the
//// fold interval and each member's timing, `fold-unrecognized-input`); then
//// the trie (`registry/fold`: the trie faults, `missing-action`,
//// `surplus-actions`, `root`); then the routing of value (`fold-state-missing`,
//// `fold-tag-not-burned`, the carrier, `fold-singular-mismatch`,
//// `fold-foreign-asset`, `fold-donation-mismatch`, `fold-fee-funding-short`,
//// `fold-unbalanced`). The first failing check is the answer.
////
//// ## Dependencies
////
//// Imports `registry/fold`, `lib` (exact quantity, the destination match),
//// `shared` (the processing window) and `types`. Imported by
//// `registry/admission`, whose `validModify` the state's spend handler and
//// `modifyRefusal` call. Nothing below imports it.
////
//// ## Assumptions
////
//// - `input` is the state input being spent, carrying `pins`, and
////   `policyId` and `tokenId` are its script and the one state token it
////   holds, as `state` establishes before calling.
//// - The transaction's first output is the continuation and carries an
////   inline state datum; otherwise the decision crashes rather than
////   refusing.
//// - The ledger guarantees distinct inputs, disjoint reference inputs and
////   conservation of every asset; the decision judges the lovelace allocation
////   of the fold itself and the assets the fold moves.
////
//// ## Invariants
////
//// - The answer is `None` or exactly one reason, so the spend handler traces
////   exactly one user-defined trace for a refused fold.
//// - Every member is an output at the request address holding exactly what
////   its datum declares; both of its tags are burned exactly once, nothing
////   but the members' singular tags moves under the active policy, no output
////   holds a request or application tag and no other asset moves.
//// - A registration is delivered to its booked destination, datum and
////   carrier lovelace in exactly one output; a termination delivers nothing.
//// - The donation is the registration costs plus, for each termination, the
////   held value less its tip; the tips stay in ordinary value, so the
////   ordinary outputs plus the fee equal the ordinary inputs plus the tips.

use aiken/collection/dict
use aiken/collection/list.{foldl, head}
use aiken/interval.{Finite, Interval}
use aiken/merkle_patricia_forestry as mpf
use booking.{applicationTagName, terminationTrieReadyTagName, trieReadyTagName}
use cardano/assets.{
  AssetName, PolicyId, Value, from_asset, lovelace_of, policies, quantity_of,
  tokens, without_lovelace,
}
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use lib.{destinationMatches, exactQuantity}
use registry/fold.{
  Member, Registering, Sorted, Terminating, evolve, rejects, sortInputs,
}
use shared.{in_phase1}
use types.{RegistrationRequest, RequestAction, State, StateDatum, TokenId}

/// Why the cage refuses this fold of the state `input` carrying `pins`, or
/// `None` when it is valid.
pub fn validFold(
  pins: State,
  input: Input,
  policyId: PolicyId,
  tokenId: TokenId,
  tx: Transaction,
  actions: List<RequestAction>,
) -> Option<String> {
  let Transaction { outputs, .. } = tx
  expect Some(output) = head(outputs)
  expect InlineDatum(outState) = output.datum
  expect StateDatum(next) = outState
  if output.address.payment_credential != input.output.address.payment_credential {
    // The continuation is the cage's own UTxO, at the cage's own
    // address: a fold that hands the registry to another script is not a
    // fold. Checked before anything the batch says, because everything
    // after it is about a state that would not be the registry's.
    Some(@"continuation-address")
  } else if !exactQuantity(policyId, output.value, tokenId, 1) {
    Some(@"state-token")
  } else if !continuationBare(policyId, tokenId, outputs) {
    // The continuation holds the state token and lovelace only, and no other
    // output holds a state token.
    Some(@"fold-state-mismatch")
  } else if lovelace_of(output.value) < lovelace_of(input.output.value) {
    // No-drain rule (NOTE-017): the state UTxO's own lovelace may not fall.
    Some(@"state-drain")
  } else if lovelace_of(output.value) > lovelace_of(input.output.value) {
    // The tip stays in ordinary value: the state keeps its lovelace exactly.
    Some(@"fold-state-value-mismatch")
  } else if !pinsPreserved(pins, next) {
    // state-datum-fields: the ten non-root fields are registry configuration — genesis
    // sets them, every fold preserves them. A fold altering any of them
    // refuses here, before any root, delta or destination check.
    Some(@"pins-altered")
  } else {
    foldInputs(pins, policyId, tokenId, tx, actions, next)
  }
}

/// The inputs, then the trie, then the routing of value.
fn foldInputs(
  pins: State,
  policyId: PolicyId,
  tokenId: TokenId,
  tx: Transaction,
  actions: List<RequestAction>,
  next: State,
) -> Option<String> {
  let sorted = sortInputs(pins, policyId, tokenId, tx.inputs)
  if sorted.mismatched {
    // An input states a request of this registry but holds something else
    // than what the request declares: the datum alone makes no member.
    Some(@"request-observation-mismatch")
  } else if list.is_empty(sorted.members) {
    Some(@"empty-fold")
  } else if rejects(actions) {
    // The state-spending rejection is retired for every request: the model's
    // fold has no such action.
    Some(@"rejected-retired")
  } else {
    when bounds(tx.validity_range) is {
      None -> Some(@"fold-interval-missing")
      Some((lower, upper)) ->
        if lower >= upper {
          Some(@"fold-interval-empty")
        } else if !list.all(
          sorted.members,
          fn(member) { timely(pins, tx.validity_range, lower, member) },
        ) {
          Some(@"not-phase1")
        } else if sorted.stranger {
          Some(@"fold-unrecognized-input")
        } else {
          let evolved =
            evolve(mpf.from_root(pins.root), actions, sorted.members)
          if evolved.refusal != None {
            evolved.refusal
          } else if mpf.root(evolved.trie) != next.root {
            Some(@"root")
          } else {
            routing(pins, policyId, sorted, tx)
          }
        }
    }
  }
}

/// A registration folds only inside its processing window and not before it
/// was booked; a termination has no window.
fn timely(pins: State, range: Interval<Int>, lower: Int, member: Member) -> Bool {
  when member.pending is {
    Registering(r) ->
      lower >= r.submitted_at && in_phase1(
        range,
        r.submitted_at,
        pins.process_time,
      )
    Terminating(_) -> True
  }
}

fn bounds(range: Interval<Int>) -> Option<(Int, Int)> {
  when (range.lower_bound.bound_type, range.upper_bound.bound_type) is {
    (Finite(lower), Finite(upper)) -> Some((lower, upper))
    _ -> None
  }
}

/// The continuation holds the state token and lovelace, and it is the only
/// output holding a state-policy token.
fn continuationBare(
  policyId: PolicyId,
  tokenId: TokenId,
  outputs: List<Output>,
) -> Bool {
  expect [first, ..rest] = outputs
  without_lovelace(first.value) == from_asset(policyId, tokenId.assetName, 1) && list.all(
    rest,
    fn(o) { dict.is_empty(tokens(o.value, policyId)) },
  )
}

// ----------------------------------------------------------------------------
// The routing of value
// ----------------------------------------------------------------------------

fn routing(
  pins: State,
  policyId: PolicyId,
  sorted: Sorted,
  tx: Transaction,
) -> Option<String> {
  let Transaction { inputs, outputs, mint, fee, treasury_donation, .. } = tx
  let members = sorted.members
  if sorted.holders != 1 {
    Some(@"fold-state-missing")
  } else if !tagsBurned(pins, members, mint, outputs) {
    Some(@"fold-tag-not-burned")
  } else {
    when carrierRefusal(pins, members, outputs) is {
      Some(reason) -> Some(reason)
      None ->
        if !singularMatches(pins, members, mint, outputs) {
          Some(@"fold-singular-mismatch")
        } else if !bare(pins, policyId, mint, inputs, outputs) {
          Some(@"fold-foreign-asset")
        } else if donationOf(treasury_donation) != owedDonation(members) {
          Some(@"fold-donation-mismatch")
        } else if foldl(
          sorted.ordinary,
          0,
          fn(i, total) { total + lovelace_of(i.output.value) },
        ) < fee {
          Some(@"fold-fee-funding-short")
        } else if lovelaceOf(inputs) != lovelaceOfOutputs(outputs) + donationOf(
          treasury_donation,
        ) + fee {
          Some(@"fold-unbalanced")
        } else {
          None
        }
    }
  }
}

fn donationOf(donation: Option<Int>) -> Int {
  when donation is {
    Some(amount) -> amount
    None -> 0
  }
}

fn lovelaceOf(inputs: List<Input>) -> Int {
  foldl(inputs, 0, fn(i, total) { total + lovelace_of(i.output.value) })
}

fn lovelaceOfOutputs(outputs: List<Output>) -> Int {
  foldl(outputs, 0, fn(o, total) { total + lovelace_of(o.value) })
}

/// What the fold donates: a registration its cost, a termination the held
/// value less its tip.
fn owedDonation(members: List<Member>) -> Int {
  foldl(
    members,
    0,
    fn(member, total) {
      when member.pending is {
        Registering(r) -> total + r.registration_cost
        Terminating(t) ->
          total + lovelace_of(member.input.output.value) - t.declared_tip
      }
    },
  )
}

/// Every pending request's tags are burned exactly once, nothing else moves
/// under the request or the application policy, and no output holds one.
fn tagsBurned(
  pins: State,
  members: List<Member>,
  mint: Value,
  outputs: List<Output>,
) -> Bool {
  tokens(mint, pins.request_policy) == burns(
    list.map(members, fn(member) { trieReadyNameOf(member) }),
  ) && tokens(mint, pins.application_policy) == burns(
    list.filter_map(members, fn(member) { applicationNameOf(member) }),
  ) && list.all(
    outputs,
    fn(o) {
      dict.is_empty(tokens(o.value, pins.request_policy)) && dict.is_empty(
        tokens(o.value, pins.application_policy),
      )
    },
  )
}

fn trieReadyNameOf(member: Member) -> AssetName {
  when member.pending is {
    Registering(r) -> trieReadyTagName(r)
    Terminating(t) -> terminationTrieReadyTagName(t)
  }
}

fn applicationNameOf(member: Member) -> Option<AssetName> {
  when member.pending is {
    Registering(r) ->
      Some(applicationTagName(r.key, r.refund_address, r.destination, r.nonce))
    Terminating(_) -> None
  }
}

/// The quantities a burn of these tags is: minus one per occurrence.
fn burns(names: List<AssetName>) -> dict.Dict<AssetName, Int> {
  tally(names, -1)
}

fn tally(names: List<AssetName>, each: Int) -> dict.Dict<AssetName, Int> {
  foldl(
    names,
    dict.empty,
    fn(name, acc) {
      dict.insert_with(acc, name, each, fn(_k, old, new) { Some(old + new) })
    },
  )
}

/// A registration is delivered in exactly one output: the key's singular tag
/// alone with the declared carrier lovelace, at the booked address, with the
/// booked datum inline (or none). `None` when every registration is.
fn carrierRefusal(
  pins: State,
  members: List<Member>,
  outputs: List<Output>,
) -> Option<String> {
  when members is {
    [] -> None
    [member, ..rest] -> {
      let own =
        when member.pending is {
          Terminating(_) -> None
          Registering(r) -> carrierOf(pins, r, outputs)
        }
      if own == None {
        carrierRefusal(pins, rest, outputs)
      } else {
        own
      }
    }
  }
}

fn carrierOf(
  pins: State,
  r: RegistrationRequest,
  outputs: List<Output>,
) -> Option<String> {
  when
    list.filter(
      outputs,
      fn(o) { quantity_of(o.value, pins.active_policy, r.key) > 0 },
    )
  is {
    [carrier] ->
      if !destinationMatches((r.destination, r.datum), carrier) {
        Some(@"fold-destination-mismatch")
      } else if lovelace_of(carrier.value) != r.carrier_ada {
        Some(@"destination-carrier-mismatch")
      } else if without_lovelace(carrier.value) != from_asset(
        pins.active_policy,
        r.key,
        1,
      ) {
        Some(@"fold-destination-mismatch")
      } else {
        None
      }
    _ -> Some(@"fold-destination-mismatch")
  }
}

/// The active policy moves exactly one singular tag per member (minted for a
/// registration, burned for a termination), and the singular tags in the
/// outputs are exactly the registrations' carriers.
fn singularMatches(
  pins: State,
  members: List<Member>,
  mint: Value,
  outputs: List<Output>,
) -> Bool {
  let minted =
    foldl(
      members,
      dict.empty,
      fn(member, acc) {
        when member.pending is {
          Registering(r) ->
            dict.insert_with(
              acc,
              r.key,
              1,
              fn(_k, old, new) { Some(old + new) },
            )
          Terminating(t) ->
            dict.insert_with(
              acc,
              t.key,
              -1,
              fn(_k, old, new) { Some(old + new) },
            )
        }
      },
    )
  let delivered =
    tally(
      list.filter_map(
        members,
        fn(member) {
          when member.pending is {
            Registering(r) -> Some(r.key)
            Terminating(_) -> None
          }
        },
      ),
      1,
    )
  let held =
    foldl(
      outputs,
      dict.empty,
      fn(o, acc) {
        foldl(
          dict.to_pairs(tokens(o.value, pins.active_policy)),
          acc,
          fn(Pair(name, quantity), inner) {
            dict.insert_with(
              inner,
              name,
              quantity,
              fn(_k, old, new) { Some(old + new) },
            )
          },
        )
      },
    )
  tokens(mint, pins.active_policy) == minted && held == delivered
}

/// Nothing outside the registry's own assets moves or is spent: the mint
/// carries only the request, application and active policies, and every input
/// and output holds only lovelace and those policies (and the state token).
fn bare(
  pins: State,
  policyId: PolicyId,
  mint: Value,
  inputs: List<Input>,
  outputs: List<Output>,
) -> Bool {
  let known =
    [
      #"",
      policyId,
      pins.request_policy,
      pins.application_policy,
      pins.active_policy,
    ]
  list.all(policies(mint), fn(p) { list.has(known, p) }) && list.all(
    inputs,
    fn(i) { list.all(policies(i.output.value), fn(p) { list.has(known, p) }) },
  ) && list.all(
    outputs,
    fn(o) { list.all(policies(o.value), fn(p) { list.has(known, p) }) },
  )
}

/// state-datum-fields: every field but the root survives the fold unchanged.
fn pinsPreserved(before: State, after: State) -> Bool {
  and {
    before.tip == after.tip,
    before.process_time == after.process_time,
    before.retract_time == after.retract_time,
    before.application_policy == after.application_policy,
    before.active_policy == after.active_policy,
    before.absent_policy == after.absent_policy,
    before.terminal_policy == after.terminal_policy,
    before.registration_cost == after.registration_cost,
    before.booking_width == after.booking_width,
    before.request_policy == after.request_policy,
  }
}
