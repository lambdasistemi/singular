//// ## Responsibility
//// Fold the pending requests a booking left behind, whatever their kind: sort
//// the transaction's inputs into authenticated pending requests, ordinary
//// value and strangers, and carry the trie through the registrations and
//// terminations in input order.
////
//// ## Dependencies
//// `booking` for the canonical tag names, `registry/trie` for the trie faults,
//// `lib` for the leaves and the occupied-key reason, `types` for the wire.
//// Imported by registry/modify, the single active fold implementation.
////
//// ## Assumptions
//// The caller checks the continuation, the pins, the routing and the
//// settlement. The pending requests are those the request policy authenticated
//// at booking: an output at the request address holding exactly the declared
//// lovelace and the tags its datum commits to.
////
//// ## Invariants
//// A pending request is a member only when its output holds exactly what its
//// datum declares (lovelace, trie-ready tag, and the application tag of a
//// registration or the key's singular tag of a termination) at the request
//// address; an input whose datum states a request but whose output does not
//// match is a mismatch, never ordinary value. An input holding any tag or
//// state token that is not a member is a stranger. Only registration and
//// termination advance the trie, one per member, in input order; the first
//// refusal stops the walk.

use aiken/collection/dict
use aiken/collection/list
use aiken/merkle_patricia_forestry.{MerklePatriciaForestry}
use aiken/merkle_patricia_forestry as mpf
use booking.{applicationTagName, terminationTrieReadyTagName, trieReadyTagName}
use cardano/address.{Script}
use cardano/assets.{
  PolicyId, Value, flatten, lovelace_of, quantity_of, tokens, without_lovelace,
}
use cardano/transaction.{InlineDatum, Input}
use lib.{leafActive, leafTerminal}
use registry/trie.{terminalFault}
use types.{
  CageDatum, RegistrationDatum, RegistrationRequest, Rejected, RequestAction,
  State, TerminationDatum, TerminationRequest, TokenId, UpdateAction,
}

/// What a member asks of the registry.
pub type Pending {
  Registering(RegistrationRequest)
  Terminating(TerminationRequest)
}

/// A pending request together with the output it rides in.
pub type Member {
  input: Input,
  pending: Pending,
}

/// The transaction's inputs, sorted. `members` is in input order.
pub type Sorted {
  /// An input states a request of this registry but does not hold what the
  /// request declares.
  mismatched: Bool,
  /// An input that is neither a member, nor the state, nor ordinary value.
  stranger: Bool,
  /// Inputs holding a state token (the spent state itself among them).
  holders: Int,
  members: List<Member>,
  ordinary: List<Input>,
}

/// Sort the inputs. The state input is `stateRef`; every other input is a
/// member, a mismatch, a stranger, another state-token holder or ordinary
/// value, decided by what its output holds and states, never by its address
/// alone.
pub fn sortInputs(
  pins: State,
  statePolicyId: PolicyId,
  tokenId: TokenId,
  inputs: List<Input>,
) -> Sorted {
  let sorted =
    list.foldl(
      inputs,
      Sorted {
        mismatched: False,
        stranger: False,
        holders: 0,
        members: [],
        ordinary: [],
      },
      fn(input, acc) { sortOne(pins, statePolicyId, tokenId, input, acc) },
    )
  Sorted {
    ..sorted,
    members: list.reverse(sorted.members),
    ordinary: list.reverse(sorted.ordinary),
  }
}

fn sortOne(
  pins: State,
  statePolicyId: PolicyId,
  tokenId: TokenId,
  input: Input,
  acc: Sorted,
) -> Sorted {
  let value = input.output.value
  if holds(value, statePolicyId) {
    Sorted { ..acc, holders: acc.holders + 1 }
  } else {
    when statedRequest(tokenId, input) is {
      Some(pending) ->
        if observes(pins, input, pending) {
          Sorted { ..acc, members: [Member { input, pending }, ..acc.members] }
        } else {
          Sorted { ..acc, mismatched: True }
        }
      None ->
        if holds(value, pins.request_policy) || holds(
          value,
          pins.application_policy,
        ) || holds(value, pins.active_policy) {
          Sorted { ..acc, stranger: True }
        } else {
          Sorted { ..acc, ordinary: [input, ..acc.ordinary] }
        }
    }
  }
}

fn holds(value: Value, policyId: PolicyId) -> Bool {
  !dict.is_empty(tokens(value, policyId))
}

/// The request an input's inline datum states for this registry, if any.
fn statedRequest(tokenId: TokenId, input: Input) -> Option<Pending> {
  when input.output.datum is {
    InlineDatum(datum) ->
      if datum is RegistrationDatum(request): CageDatum {
        if request.registry == tokenId {
          Some(Registering(request))
        } else {
          None
        }
      } else if datum is TerminationDatum(request): CageDatum {
        if request.registry == tokenId {
          Some(Terminating(request))
        } else {
          None
        }
      } else {
        None
      }
    _ -> None
  }
}

/// The output holds exactly what its request declares, at the request
/// address: the declared lovelace and the tags the booking minted into it, and
/// nothing else. The value is read from the output, never from the datum.
fn observes(pins: State, input: Input, pending: Pending) -> Bool {
  let value = input.output.value
  input.output.address.payment_credential == Script(pins.request_policy) && when
    pending
  is {
    Registering(r) ->
      lovelace_of(value) == r.registration_cost + r.declared_tip + r.carrier_ada && exactly(
        value,
        [
          (pins.request_policy, trieReadyTagName(r)),
          (
            pins.application_policy,
            applicationTagName(r.key, r.refund_address, r.destination, r.nonce),
          ),
        ],
      )
    Terminating(t) ->
      lovelace_of(value) == t.declared_tip + t.carrier_ada && exactly(
        value,
        [
          (pins.request_policy, terminationTrieReadyTagName(t)),
          (pins.active_policy, t.key),
        ],
      )
  }
}

/// Besides lovelace the value is exactly these assets, one unit each.
pub fn exactly(value: Value, assets: List<(PolicyId, ByteArray)>) -> Bool {
  list.length(flatten(without_lovelace(value))) == list.length(assets) && list.all(
    assets,
    fn((policyId, name)) { quantity_of(value, policyId, name) == 1 },
  )
}

// ----------------------------------------------------------------------------
// The trie
// ----------------------------------------------------------------------------

/// The trie after the walk, or the first refusal.
pub type Evolved {
  refusal: Option<String>,
  trie: MerklePatriciaForestry,
}

/// Whether any action is the retired state-spending rejection.
pub fn rejects(actions: List<RequestAction>) -> Bool {
  list.any(
    actions,
    fn(action) {
      when action is {
        Rejected -> True
        _ -> False
      }
    },
  )
}

/// Carry the trie through the members in input order, one action each: a
/// registration inserts its key as active, a termination moves its key from
/// active to terminal. A missing action, a surplus action and a retired
/// rejection each refuse.
pub fn evolve(
  trie: MerklePatriciaForestry,
  actions: List<RequestAction>,
  members: List<Member>,
) -> Evolved {
  when members is {
    [] ->
      if list.is_empty(actions) {
        Evolved { refusal: None, trie }
      } else {
        Evolved { refusal: Some(@"surplus-actions"), trie }
      }
    [member, ..rest] ->
      when actions is {
        [] -> Evolved { refusal: Some(@"missing-action"), trie }
        [Rejected, ..] -> Evolved { refusal: Some(@"rejected-retired"), trie }
        [UpdateAction(proof), ..tail] -> {
          let stepped = step(trie, member.pending, proof)
          if stepped.refusal == None {
            evolve(stepped.trie, tail, rest)
          } else {
            stepped
          }
        }
      }
  }
}

fn step(
  trie: MerklePatriciaForestry,
  pending: Pending,
  proof: mpf.Proof,
) -> Evolved {
  when pending is {
    Registering(r) ->
      if mpf.miss(trie, r.key, proof) {
        Evolved {
          refusal: None,
          trie: mpf.insert(trie, r.key, leafActive, proof),
        }
      } else {
        Evolved { refusal: lib.occupiedRefusal(), trie }
      }
    Terminating(t) ->
      when terminalFault(trie, t.key, proof) is {
        None ->
          Evolved {
            refusal: None,
            trie: mpf.update(trie, t.key, proof, leafActive, leafTerminal),
          }
        fault -> Evolved { refusal: fault, trie }
      }
  }
}
