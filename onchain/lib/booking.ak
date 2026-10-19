//// ## Responsibility
//// Registration and termination bookings: the canonical tag names and the two
//// judgements the request policy's mint handler enforces, one per kind of
//// booking. Pure values; no application policy logic.
////
//// ## Dependencies
//// `types` for the datum vocabulary, `shared` and `lib` for the state-token
//// test, and the Aiken standard library for the hash and the data encoding.
////
//// ## Assumptions
//// The ledger supplies the executing policy id, the transaction and its
//// validity range as presented: a finite range arrives with its lower end
//// included and its upper end excluded, and the handler does not read the
//// inclusion flags. The application policy owns its own authorization rule;
//// this module checks only that its tag is present, exactly named and
//// minted in the same booking.
////
//// ## Invariants
//// A registration is born authenticated: the request output holds exactly
//// the declared cost, tip and carrier, one correctly named application tag
//// and one correctly named trie-ready tag, both minted with it, and its
//// booked time is the finite upper end of a bounded interval. A tag name
//// commits to every declared field and the nonce; neither name commits to
//// the delivered datum, the registry or the booked time.
////
//// A termination is born authenticated the same way: its request output holds
//// exactly the declared tip and carrier, the key's one singular tag and one
//// correctly named trie-ready tag minted with it, and the spent input that
//// holds the singular tag is the custody whose whole value moves into the
//// request (the application's own address, envelope and controller checks
//// belong to the application, not to this module).

use aiken/builtin
use aiken/collection/dict.{Dict}
use aiken/collection/list
use aiken/crypto.{VerificationKeyHash, blake2b_256}
use aiken/interval.{Finite, Interval}
use aiken/primitive/bytearray
use cardano/address.{Script}
use cardano/assets.{
  PolicyId, Value, from_asset, lovelace_of, policies, quantity_of, tokens,
  without_lovelace,
}
use cardano/transaction.{InlineDatum, Input, Output, Transaction}
use shared.{carriesStateToken}
use types.{
  CageDatum, RegistrationDatum, RegistrationRequest, State, StateDatum,
  TerminationDatum, TerminationRequest, TokenId,
}

/// The name a list of data fields hashes to: `blake2b_256` of the data
/// encoding of the list. Integers stay integers and bytes stay bytes, so the
/// encoding is canonical and separates its fields.
fn nameOf(fields: List<Data>) -> ByteArray {
  blake2b_256(builtin.serialise_data(builtin.list_data(fields)))
}

/// The application tag name of a registration: the hash of the list
/// `[0, 1, key, refund_address, destination, nonce]`, the list the Lean model
/// hashes (`applicationTagAssetName`).
pub fn applicationTagName(
  key: ByteArray,
  refund_address: VerificationKeyHash,
  destination: ByteArray,
  nonce: Int,
) -> ByteArray {
  nameOf(
    [
      builtin.i_data(0),
      builtin.i_data(1),
      builtin.b_data(key),
      builtin.b_data(refund_address),
      builtin.b_data(destination),
      builtin.i_data(nonce),
    ],
  )
}

/// The trie-ready tag name of a registration: the hash of the list
/// `[1, 0, key, refund_address, destination, cost, tip, carrier, nonce]`
/// (`trieReadyTagAssetName` of a registration operation).
pub fn trieReadyTagName(request: RegistrationRequest) -> ByteArray {
  nameOf(
    [
      builtin.i_data(1),
      builtin.i_data(0),
      builtin.b_data(request.key),
      builtin.b_data(request.refund_address),
      builtin.b_data(request.destination),
      builtin.i_data(request.registration_cost),
      builtin.i_data(request.declared_tip),
      builtin.i_data(request.carrier_ada),
      builtin.i_data(request.nonce),
    ],
  )
}

/// The trie-ready tag name of a termination: the hash of the list
/// `[1, 1, key, destination, nonce]` (`trieReadyTagAssetName` of a
/// termination operation). A representation function, not a judgement.
pub fn terminationTrieReadyTagName(request: TerminationRequest) -> ByteArray {
  nameOf(
    [
      builtin.i_data(1),
      builtin.i_data(1),
      builtin.b_data(request.key),
      builtin.b_data(request.destination),
      builtin.i_data(request.nonce),
    ],
  )
}

/// Whether the booking states a termination: an output holding a tag of the
/// request policy carries an inline `TerminationDatum`. The request mint
/// judges such a booking by `terminationBookingRefusal` and every other one
/// by `registrationBookingRefusal`; a transaction that mixes the two kinds is
/// judged as a termination and refused there, because it has more than one
/// tagged request output.
pub fn carriesTermination(policyId: PolicyId, outputs: List<Output>) -> Bool {
  list.any(
    outputs,
    fn(output) {
      !dict.is_empty(tokens(output.value, policyId)) && when output.datum is {
        InlineDatum(datum) ->
          if datum is TerminationDatum(_): CageDatum {
            True
          } else {
            False
          }
        _ -> False
      }
    },
  )
}

/// Why this transaction is not an authenticated termination booking, or
/// `None` when it is: Lean `terminationBookingRefusal`, in the model's order
/// (`dirty-request`, `hidden-surplus`, `forged-singular-tag`,
/// `forged-trie-ready-tag`, `singular-tag-not-in-custody`, then
/// `forged-singular-tag` again for the custody equality). The observation
/// extent is one tagged request output and the spent inputs: untagged
/// outputs at the request address are not read, so they cannot change a
/// verdict. That the key is active in the trie is not observable here; it is
/// the representation invariant that the singular token exists exactly while
/// the key is active, and the spent input holding it is the custody.
pub fn terminationBookingRefusal(
  statePolicyId: PolicyId,
  cageToken: TokenId,
  policyId: PolicyId,
  tx: Transaction,
) -> Option<String> {
  let Transaction { reference_inputs, inputs, outputs, mint, .. } = tx
  when authenticatedState(statePolicyId, cageToken, reference_inputs) is {
    None -> Some(@"booking-state-unauthenticated")
    Some(pins) ->
      if pins.request_policy != policyId {
        Some(@"booking-request-policy-pin")
      } else {
        when
          list.filter(
            outputs,
            fn(output) { !dict.is_empty(tokens(output.value, policyId)) },
          )
        is {
          [output] ->
            when output.datum is {
              InlineDatum(datum) ->
                if datum is TerminationDatum(request): CageDatum {
                  judgeTermination(
                    pins,
                    cageToken,
                    policyId,
                    output,
                    request,
                    inputs,
                    mint,
                  )
                } else {
                  Some(@"dirty-request")
                }
              _ -> Some(@"dirty-request")
            }
          _ -> Some(@"dirty-request")
        }
      }
  }
}

/// The model's termination judgement over the one request output and the
/// spent inputs.
fn judgeTermination(
  pins: State,
  cageToken: TokenId,
  policyId: PolicyId,
  output: Output,
  request: TerminationRequest,
  inputs: List<Input>,
  mint: Value,
) -> Option<String> {
  let held = lovelace_of(output.value)
  let declared = request.declared_tip + request.carrier_ada
  let trieReadyName = terminationTrieReadyTagName(request)
  if !terminationShape(pins, policyId, output, request) || held < declared {
    Some(@"dirty-request")
  } else if declared < held {
    Some(@"hidden-surplus")
  } else if request.registry != cageToken || !only(
    tokens(output.value, pins.active_policy),
    request.key,
  ) {
    Some(@"forged-singular-tag")
  } else if !(only(tokens(output.value, policyId), trieReadyName) && only(
    tokens(mint, policyId),
    trieReadyName,
  )) {
    Some(@"forged-trie-ready-tag")
  } else {
    when
      list.filter(
        inputs,
        fn(input) {
          quantity_of(input.output.value, pins.active_policy, request.key) > 0
        },
      )
    is {
      [] -> Some(@"singular-tag-not-in-custody")
      [custody] ->
        // The universal layer, for custody an application does not guard
        // (generic open, a wallet, keri-stub): the singleton spent input
        // carries exactly one genuine tag, and its whole value is the
        // transferred custody, so the request holds all of its lovelace (the
        // model's H = V + A with A at least zero) and nothing the request
        // cannot carry stays behind in it.
        if quantity_of(custody.output.value, pins.active_policy, request.key) != 1 {
          Some(@"forged-singular-tag")
        } else if without_lovelace(custody.output.value) != from_asset(
          pins.active_policy,
          request.key,
          1,
        ) || held < lovelace_of(custody.output.value) {
          Some(@"custody-value-not-transferred")
        } else {
          None
        }
      _ -> Some(@"forged-singular-tag")
    }
  }
}

/// The non-value shape of a termination request: at its own request address,
/// a tip at least the pinned minimum, natural carrier and nonce (the model's
/// are natural numbers; the wire carries integers), and no asset beyond the
/// request policy and the registry's active policy. The refund address, the
/// booking clock, a delivered datum and an application tag have no field or
/// no admitted policy here, as in the model.
fn terminationShape(
  pins: State,
  policyId: PolicyId,
  output: Output,
  request: TerminationRequest,
) -> Bool {
  and {
    output.address.payment_credential == Script(policyId),
    request.declared_tip >= pins.tip,
    request.carrier_ada >= 0,
    request.nonce >= 0,
    list.all(
      policies(output.value),
      fn(policy) {
        policy == #"" || policy == policyId || policy == pins.active_policy
      },
    ),
  }
}

/// Every movement under one policy is a burn, and there is at least one. A
/// mint beside a burn is not a pure burn.
pub fn pureBurn(moved: Dict<ByteArray, Int>) -> Bool {
  let quantities = dict.values(moved)
  !list.is_empty(quantities) && list.all(quantities, fn(q) { q < 0 })
}

/// Why this transaction is not an authenticated registration booking, or
/// `None` when it is. The reasons are the model's, in the model's order; a
/// transaction that does not even carry an authenticated registry state or a
/// single tagged request is refused before any of them.
pub fn registrationBookingRefusal(
  statePolicyId: PolicyId,
  cageToken: TokenId,
  policyId: PolicyId,
  tx: Transaction,
) -> Option<String> {
  let Transaction { reference_inputs, outputs, mint, validity_range, .. } = tx
  when authenticatedState(statePolicyId, cageToken, reference_inputs) is {
    None -> Some(@"booking-state-unauthenticated")
    Some(pins) ->
      if pins.request_policy != policyId {
        Some(@"booking-request-policy-pin")
      } else {
        // The observation extent of this judgement is one tagged request
        // output: an output holding any asset of this policy.
        when
          list.filter(
            outputs,
            fn(output) { !dict.is_empty(tokens(output.value, policyId)) },
          )
        is {
          [output] ->
            when output.datum is {
              InlineDatum(datum) ->
                if datum is RegistrationDatum(request): CageDatum {
                  judge(
                    pins,
                    cageToken,
                    policyId,
                    output,
                    request,
                    mint,
                    validity_range,
                  )
                } else {
                  Some(@"dirty-request")
                }
              _ -> Some(@"dirty-request")
            }
          _ -> Some(@"dirty-request")
        }
      }
  }
}

/// The registry's pins, read from the reference input that holds exactly its
/// one state token at its own script address with an inline state datum.
fn authenticatedState(
  statePolicyId: PolicyId,
  cageToken: TokenId,
  inputs: List<Input>,
) -> Option<State> {
  when
    list.find(
      inputs,
      fn(input) { carriesStateToken(statePolicyId, cageToken, input) },
    )
  is {
    None -> None
    Some(input) ->
      if input.output.address.payment_credential == Script(statePolicyId) {
        when input.output.datum is {
          InlineDatum(datum) ->
            if datum is StateDatum(pins): CageDatum {
              Some(pins)
            } else {
              None
            }
          _ -> None
        }
      } else {
        None
      }
  }
}

/// The model's registration judgement over the one request output.
fn judge(
  pins: State,
  cageToken: TokenId,
  policyId: PolicyId,
  output: Output,
  request: RegistrationRequest,
  mint: Value,
  validity_range: Interval<Int>,
) -> Option<String> {
  let held = lovelace_of(output.value)
  let declared =
    request.registration_cost + request.declared_tip + request.carrier_ada
  let applicationName =
    applicationTagName(
      request.key,
      request.refund_address,
      request.destination,
      request.nonce,
    )
  let trieReadyName = trieReadyTagName(request)
  if !contentsShape(pins, cageToken, policyId, output, request, applicationName) || held < declared {
    Some(@"dirty-request")
  } else if declared < held {
    Some(@"hidden-surplus")
  } else if !(only(tokens(output.value, policyId), trieReadyName) && only(
    tokens(mint, policyId),
    trieReadyName,
  )) {
    Some(@"forged-trie-ready-tag")
  } else if !only(tokens(mint, pins.application_policy), applicationName) {
    Some(@"dirty-request")
  } else {
    when
      (
        validity_range.lower_bound.bound_type,
        validity_range.upper_bound.bound_type,
      )
    is {
      (Finite(lower), Finite(upper)) ->
        if lower >= upper {
          Some(@"invalid-booking-interval")
        } else if request.submitted_at != upper {
          Some(@"backdated-booking")
        } else if upper - lower > pins.booking_width {
          Some(@"booking-too-wide")
        } else {
          None
        }
      _ -> Some(@"invalid-booking-interval")
    }
  }
}

/// The non-value shape of the request: this registry, at its own request
/// address, the pinned cost, a tip at least the pinned minimum, naturals and
/// a 28-byte refund hash, no asset beyond the two tag policies, and exactly
/// one application tag of the right name.
fn contentsShape(
  pins: State,
  cageToken: TokenId,
  policyId: PolicyId,
  output: Output,
  request: RegistrationRequest,
  applicationName: ByteArray,
) -> Bool {
  and {
    output.address.payment_credential == Script(policyId),
    request.registry == cageToken,
    request.registration_cost == pins.registration_cost,
    request.declared_tip >= pins.tip,
    request.carrier_ada >= 0,
    request.nonce >= 0,
    bytearray.length(request.refund_address) == 28,
    list.all(
      policies(output.value),
      fn(policy) {
        policy == #"" || policy == policyId || policy == pins.application_policy
      },
    ),
    only(tokens(output.value, pins.application_policy), applicationName),
  }
}

/// The tokens of one policy are exactly this one name at quantity one.
fn only(moved: Dict<ByteArray, Int>, name: ByteArray) -> Bool {
  dict.to_pairs(moved) == [Pair(name, 1)]
}
