//// Open-datum application bound to the permanent state identity.
//// Booking and payload update retain the existing application law; release is retired with the state-spending rejection.

use aiken/collection/dict.{get, keys}
use aiken/collection/list
use aiken/primitive/bytearray
use application/envelope.{
  BookInsert, BookTerminate, BookTermination, Control, Envelope, OpenDatumMint,
  OpenDatumSpend, Release, Update, envelopeHash, envelopeVersion, registryBytes,
}
use cardano/address.{Address, Script}
use cardano/assets.{
  PolicyId, Value, from_asset, lovelace_of, quantity_of, tokens,
  without_lovelace,
}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction, find_input,
}
use lib.{approvalName, decodeAddress, destinationDatumHash, edgeInsertActive}
use registry/refusal.{traceFalse}
use registry_pin.{registryStateHash}
use types.{
  CageDatum, Request, RequestDatum, State, StateDatum, TerminationDatum,
  TerminationRequest,
}

/// The open-datum application (#299, #310): a key's live value is an
/// output at this script holding the key's active token under an inline
/// `Envelope` — a protected control and a free payload.
///
/// One parameter, `registry`: the full state asset (state policy ‖
/// state token name) of the one registry this instance serves. The same
/// compiled hash is the approval policy the registry pins and the
/// address the live outputs sit at.
///
/// **Mint** certifies exactly two bookings, each the model's booking
/// guards in the model's order (`OpenDatumApplication.Model`
/// `bookInsertStep`, `bookTerminateStep`), read against the actual
/// registry state presented as a reference input:
///
/// - `insertActive`: the envelope names this registry, its active policy,
///   the key and the controller as owner; the controller signs; the
///   request's destination is this script with this envelope's hash; the
///   protected deposit is the request's.
/// - `updateTerminal`: the live output for the key, read as a reference
///   input, sits here with the key's one active token and an envelope
///   bound to this registry and key; its controller owns the request and
///   signs it; the request names no destination.
///
/// **Spend** has two paths and refuses everything else:
///
/// - `Update`: the controller signs; exactly one output carries the key's
///   token, at this same address, with the same control and non-ada
///   assets and at least the protected deposit. The payload is free.
/// - `BookTermination`: the live output is the custody of a termination
///   booking (below).
///
/// `Release`, the old fold-side retirement paying the controller, is retired
/// with the state-spending rejection and the deposit returned to the
/// controller: it is refused for every transaction.
/// Why this spend is not a lawful termination booking of the live output, or
/// `None` when it is: Lean `bookTerminateStep`, in the model's order where
/// the observation allows it (`app-registry-asset`, `app-not-pinned`,
/// `app-terminate-token`, `app-terminate-binding`, `app-controller-signature`,
/// `app-terminate-destination`, `app-termination-value`; `app-custody-snapshot`
/// is the representation invariant that the spent output is the registered
/// holding). The spent output is the custody: nothing but lovelace and the
/// key's one active token. The transaction carries one termination request
/// output holding exactly the custody's lovelace plus `ordinary_added`, a
/// natural number (the model's `ordinaryAdded`), so all of the custody enters
/// the request and none of it is refunded; other ordinary outputs, such as a
/// payment to the controller funded from ordinary inputs, are not read. The
/// request policy's mint judges the request itself and its tag, so the
/// booking must mint under that policy for that judgement to run: without a
/// minted tag the model's `trieReadyTagsMinted` is not the request's tag
/// (`forged-trie-ready-tag`).
pub fn bookTerminationRefusal(
  registry: ByteArray,
  control: Control,
  custody: Input,
  ordinary_added: Int,
  tx: Transaction,
) -> Option<String> {
  when actualState(registry, tx.reference_inputs) is {
    None -> Some(@"app-registry-asset")
    Some(state) -> {
      let Output { address, value, .. } = custody.output
      when address.payment_credential is {
        Script(own) ->
          if state.application_policy != own {
            Some(@"app-not-pinned")
          } else {
            when bookedTermination(tx.outputs, state.request_policy) is {
              None -> Some(@"app-termination-value")
              Some((requested, request)) ->
                if without_lovelace(value) != from_asset(
                  state.active_policy,
                  request.key,
                  1,
                ) {
                  Some(@"app-terminate-token")
                } else if control.key != request.key || registryBytes(
                  control.registry,
                ) != registry || control.activePolicy != state.active_policy {
                  Some(@"app-terminate-binding")
                } else if !list.has(tx.extra_signatories, control.controller) {
                  Some(@"app-controller-signature")
                } else if request.destination != #"" {
                  Some(@"app-terminate-destination")
                } else if ordinary_added < 0 || lovelace_of(requested.value) != lovelace_of(
                  value,
                ) + ordinary_added {
                  Some(@"app-termination-value")
                } else if !mintsUnder(tx.mint, state.request_policy) {
                  Some(@"forged-trie-ready-tag")
                } else {
                  None
                }
            }
          }
        _ -> Some(@"app-terminate-token")
      }
    }
  }
}

/// The one request output of a termination booking: the only output holding
/// a tag of the request policy, under an inline `TerminationDatum`.
fn bookedTermination(
  outputs: List<Output>,
  requestPolicy: PolicyId,
) -> Option<(Output, TerminationRequest)> {
  when
    list.filter(
      outputs,
      fn(out) { !dict.is_empty(tokens(out.value, requestPolicy)) },
    )
  is {
    [carrier] ->
      when carrier.datum is {
        InlineDatum(inline) ->
          if inline is TerminationDatum(request): CageDatum {
            Some((carrier, request))
          } else {
            None
          }
        _ -> None
      }
    _ -> None
  }
}

/// Some quantity of this policy is minted.
fn mintsUnder(mint: Value, policy: PolicyId) -> Bool {
  list.any(dict.values(tokens(mint, policy)), fn(quantity) { quantity > 0 })
}

validator open_datum(registry: ByteArray) {
  mint(redeemer: OpenDatumMint, policy_id: PolicyId, tx: Transaction) {
    let moved = tokens(tx.mint, policy_id)
    if pureBurn(moved) {
      // An approval is evidence, never a consumable (approval-asset-binding):
      // destroying your own copy costs the registry nothing.
      True
    } else {
      when keys(moved) is {
        [name] ->
          if get(moved, name) != Some(1) {
            traceFalse(@"approval-quantity")
          } else {
            when actualState(registry, tx.reference_inputs) is {
              None -> traceFalse(@"app-registry-asset")
              Some(state) ->
                if state.application_policy != policy_id {
                  traceFalse(@"app-not-pinned")
                } else {
                  when redeemer is {
                    BookInsert { key, owner, address, envelope } ->
                      bookInsert(
                        registry,
                        policy_id,
                        state,
                        name,
                        key,
                        owner,
                        address,
                        envelope,
                        tx,
                      )
                    // The model has no application approval for a termination:
                    // the booking is this script's `BookTermination` spend plus
                    // the request policy's mint, so no approval is certified.
                    BookTerminate { .. } ->
                      traceFalse(@"app-terminate-approval-retired")
                  }
                }
            }
          }
        _ -> traceFalse(@"approval-quantity")
      }
    }
  }

  spend(
    datum: Option<Data>,
    redeemer: OpenDatumSpend,
    own: OutputReference,
    tx: Transaction,
  ) {
    expect Some(self) = find_input(tx.inputs, own)
    expect Some(raw) = datum
    expect envelope: Envelope = raw
    let control = envelope.control
    when redeemer is {
      Update -> validUpdate(control, self.output, tx)
      // The old release folded the live output away in the registry's fold,
      // paying its controller; the accepted model has no such route. A key
      // is terminated by booking (`BookTermination`) and a permissionless fold
      // of the pending request. The constructor stays for the wire shape.
      Release -> traceFalse(@"release-retired")
      BookTermination { ordinary_added } ->
        when
          bookTerminationRefusal(registry, control, self, ordinary_added, tx)
        is {
          None -> True
          Some(reason) -> traceFalse(reason)
        }
    }
  }

  else(_) {
    fail
  }
}

// ---------------------------------------------------------------------
// The actual registry state
// ---------------------------------------------------------------------

/// The registry this instance serves, as the transaction presents it: an
/// input at the state script's own address holding exactly one state
/// token, whose full asset is the parameter, under an inline state datum.
/// Carrying the asset anywhere else is not the registry.
fn stateOf(registry: ByteArray, input: Input) -> Option<State> {
  let Output { address, value, datum, .. } = input.output
  when address.payment_credential is {
    Script(hash) ->
      if hash == registryStateHash && holdsRegistry(registry, value) {
        when datum is {
          InlineDatum(inline) ->
            if inline is StateDatum(state): CageDatum {
              Some(state)
            } else {
              None
            }
          _ -> None
        }
      } else {
        None
      }
    _ -> None
  }
}

fn holdsRegistry(registry: ByteArray, value: Value) -> Bool {
  let held = tokens(value, registryStateHash)
  when keys(held) is {
    [name] ->
      get(held, name) == Some(1) && bytearray.concat(registryStateHash, name) == registry
    _ -> False
  }
}

/// The one reference input that is this registry's actual state.
fn actualState(registry: ByteArray, references: List<Input>) -> Option<State> {
  when list.filter_map(references, fn(input) { stateOf(registry, input) }) is {
    [state] -> Some(state)
    _ -> None
  }
}

// ---------------------------------------------------------------------
// Booking
// ---------------------------------------------------------------------

/// `bookInsertStep`: every guard, in the model's order, then the binding
/// of the minted name to the request the approval certifies.
fn bookInsert(
  registry: ByteArray,
  policy_id: PolicyId,
  state: State,
  name: ByteArray,
  key: ByteArray,
  owner: ByteArray,
  address: ByteArray,
  envelope: Envelope,
  tx: Transaction,
) -> Bool {
  let control = envelope.control
  let datumHash = envelopeHash(envelope)
  let destination = (address, datumHash)
  if control.version != envelopeVersion {
    traceFalse(@"app-envelope-version")
  } else if registryBytes(control.registry) != registry {
    traceFalse(@"app-registry")
  } else if control.activePolicy != state.active_policy {
    traceFalse(@"app-active-policy")
  } else if control.key != key {
    traceFalse(@"app-key")
  } else if control.controller != owner {
    traceFalse(@"app-owner")
  } else if !list.has(tx.extra_signatories, control.controller) {
    traceFalse(@"app-controller-signature")
  } else if decodeAddress(address) != Some(
    Address { payment_credential: Script(policy_id), stake_credential: None },
  ) {
    traceFalse(@"app-destination")
  } else {
    when bookedRequest(tx.outputs, policy_id, name) is {
      None -> traceFalse(@"app-request")
      Some(request) -> {
        let (requestAddress, requestDatum) = request.destination
        if request.edge != edgeInsertActive || request.requestKey != key || request.requestOwner != owner {
          traceFalse(@"app-request")
        } else if requestAddress != address {
          traceFalse(@"app-destination")
        } else if requestDatum == None {
          // The request carries no datum, so the fold would deliver the
          // token to an output carrying none: the model's
          // `app-envelope-datum`.
          traceFalse(@"app-envelope-datum")
        } else if destinationDatumHash(requestDatum) != datumHash {
          traceFalse(@"app-destination")
        } else if request.deposit != control.deposit {
          traceFalse(@"app-deposit")
        } else if name != approvalName(
          edgeInsertActive,
          key,
          owner,
          destination,
        ) {
          traceFalse(@"approval-binding")
        } else {
          True
        }
      }
    }
  }
}

/// The control of a live output's inline envelope, when it states one.
fn liveControl(datum) -> Option<Control> {
  when datum is {
    InlineDatum(inline) ->
      if inline is envelope: Envelope {
        Some(envelope.control)
      } else {
        None
      }
    _ -> None
  }
}

/// The booked request: the one output carrying the minted approval, under
/// an inline request datum.
fn bookedRequest(
  outputs: List<Output>,
  policy_id: PolicyId,
  name: ByteArray,
) -> Option<Request> {
  when
    list.filter(
      outputs,
      fn(out) { quantity_of(out.value, policy_id, name) == 1 },
    )
  is {
    [carrier] ->
      when carrier.datum is {
        InlineDatum(inline) ->
          if inline is RequestDatum(request): CageDatum {
            Some(request)
          } else {
            None
          }
        _ -> None
      }
    _ -> None
  }
}

// ---------------------------------------------------------------------
// Update
// ---------------------------------------------------------------------

/// The output being spent is a live holding: it carries exactly one of
/// its own key's active token. An envelope at this address without that
/// token, or with more than one, is not the key's live value, so neither
/// path may treat it as one.
fn holdsItsToken(control: Control, self: Output) -> Bool {
  quantity_of(self.value, control.activePolicy, control.key) == 1
}

/// `updateStep`: the controller signs; exactly one output carries the
/// key's token, here, with the same control and assets and at least the
/// protected deposit. The payload is not read.
fn validUpdate(control: Control, self: Output, tx: Transaction) -> Bool {
  if !holdsItsToken(control, self) {
    traceFalse(@"update-holding-token")
  } else if !list.has(tx.extra_signatories, control.controller) {
    traceFalse(@"update-controller-signature")
  } else {
    when
      list.filter(
        tx.outputs,
        fn(out) {
          quantity_of(out.value, control.activePolicy, control.key) != 0
        },
      )
    is {
      [next] ->
        if next.address != self.address {
          traceFalse(@"update-escape")
        } else if liveControl(next.datum) != Some(control) {
          traceFalse(@"update-control")
        } else if without_lovelace(next.value) != without_lovelace(self.value) {
          traceFalse(@"update-assets")
        } else if lovelace_of(next.value) < control.deposit {
          traceFalse(@"update-deposit")
        } else {
          True
        }
      _ -> traceFalse(@"update-token")
    }
  }
}

// ---------------------------------------------------------------------
// Burns
// ---------------------------------------------------------------------

fn pureBurn(moved: dict.Dict<ByteArray, Int>) -> Bool {
  when keys(moved) is {
    [] -> False
    names -> list.all(names, fn(name) { get(moved, name) |> isBurn })
  }
}

fn isBurn(quantity: Option<Int>) -> Bool {
  when quantity is {
    Some(q) -> q < 0
    None -> False
  }
}

validator closed_datum(registry: ByteArray) {
  mint(redeemer: OpenDatumMint, policy_id: PolicyId, tx: Transaction) {
    open_datum.mint(registry, redeemer, policy_id, tx)
  }

  spend(
    datum: Option<Data>,
    redeemer: OpenDatumSpend,
    own: OutputReference,
    tx: Transaction,
  ) {
    when redeemer is {
      Update -> traceFalse(@"closed-datum-update")
      Release -> traceFalse(@"release-retired")
      BookTermination { ordinary_added } ->
        open_datum.spend(
          registry,
          datum,
          BookTermination { ordinary_added },
          own,
          tx,
        )
    }
  }

  else(_) {
    fail
  }
}
