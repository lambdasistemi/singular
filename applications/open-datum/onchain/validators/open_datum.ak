//// Open-datum application bound to the permanent state identity.
//// Booking and payload update retain the existing application law; release is retired with the state-spending rejection.

use aiken/collection/dict.{get, keys}
use aiken/collection/list
use aiken/primitive/bytearray
use application/envelope.{
  BookInsert, BookTerminate, BookTermination, Control, Envelope, OpenDatumMint,
  OpenDatumSpend, Release, Update, envelopeVersion, registryBytes,
}
use booking.{applicationTagName, trieReadyTagName}
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
  CageDatum, RegistrationDatum, RegistrationRequest, State, StateDatum,
  TerminationDatum, TerminationRequest, TokenId,
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
/// **Mint** certifies one booking, the registration, read against the actual
/// registry state presented as a reference input (`OpenDatumApplication.Model`
/// `insertionBinding`, `bookInsertStep`, composed with the root registration
/// booking): the mint creates the application tag of one registration request.
///
/// - The state is this registry's (the full state asset), and pins this script
///   as its application policy; the envelope is of the current version and
///   names this registry, its active policy, the key and the controller, and
///   the controller signs.
/// - The tagged request output is the one holding the minted tag. It is at the
///   request policy the state pins, holds that request's trie-ready tag, minted
///   in the same booking, so the pinned request policy judges the same booking;
///   its `RegistrationDatum` is for this registry, names the key, the
///   controller as refund address, this script as destination and the
///   complete envelope as the carried datum, and its carrier lovelace is the
///   envelope's deposit. The payload is not read.
/// - The minted name is `applicationTagName` over the key, the refund address,
///   the destination and the nonce the request carries, at quantity one: the
///   redeemer has no nonce field, the request is the only source of it.
///
/// The termination is booked by `BookTermination` (below) and the request
/// policy's mint; `BookTerminate` is a kept constructor that certifies nothing.
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
  // The redeemer arrives as raw data. A pure burn accepts any bytes: the
  // permissionless fold burns the application tag under one fixed redeemer
  // that knows nothing of this application's arms, and an approval is
  // evidence, never a consumable (approval-asset-binding): destroying your
  // own copy costs the registry nothing. Only a mint is read as an
  // `OpenDatumMint`, and a redeemer that does not decode as one authorizes
  // nothing.
  mint(raw: Data, policy_id: PolicyId, tx: Transaction) {
    let moved = tokens(tx.mint, policy_id)
    if pureBurn(moved) {
      True
    } else {
      expect redeemer: OpenDatumMint = raw
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

/// `bookInsertStep`: every guard, in the model's order, then the binding of
/// the minted name to the tagged request it certifies. The booked request is
/// the one output holding the minted application tag, under an inline
/// `RegistrationDatum`; the nonce comes from it.
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
      Some((output, request)) -> {
        let carried: Data = envelope
        // The wire request.registry, the request's address at the request
        // policy this state pins and the state this script consulted agree on
        // one registry: a request of another registry names another token and
        // sits under another request policy.
        if request.registry != TokenId { assetName: registryName(registry) } || request.key != key || request.refund_address != owner || output.address.payment_credential != Script(
          state.request_policy,
        ) {
          traceFalse(@"app-request")
        } else if request.destination != address {
          traceFalse(@"app-destination")
        } else if request.datum != Some(carried) {
          traceFalse(@"app-envelope-datum")
        } else if request.carrier_ada != control.deposit {
          traceFalse(@"app-deposit")
        } else if !holdsMintedTag(
          output,
          tx.mint,
          state.request_policy,
          request,
        ) {
          // The pinned request policy must judge this same booking: the
          // request holds its trie-ready tag and the tag is minted now.
          traceFalse(@"forged-trie-ready-tag")
        } else if name != applicationTagName(key, owner, address, request.nonce) {
          traceFalse(@"approval-binding")
        } else {
          True
        }
      }
    }
  }
}

/// The registry's state token name: the registry identity is the state policy
/// followed by it.
fn registryName(registry: ByteArray) -> ByteArray {
  bytearray.drop(registry, bytearray.length(registryStateHash))
}

/// The request output holds the request's own trie-ready tag under the pinned
/// request policy, and exactly that tag is minted.
fn holdsMintedTag(
  output: Output,
  mint: Value,
  requestPolicy: PolicyId,
  request: RegistrationRequest,
) -> Bool {
  let tag = trieReadyTagName(request)
  quantity_of(output.value, requestPolicy, tag) == 1 && quantity_of(
    mint,
    requestPolicy,
    tag,
  ) == 1
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

/// The booked request: the one output carrying the minted application tag,
/// under an inline registration request.
fn bookedRequest(
  outputs: List<Output>,
  policy_id: PolicyId,
  name: ByteArray,
) -> Option<(Output, RegistrationRequest)> {
  when
    list.filter(
      outputs,
      fn(out) { quantity_of(out.value, policy_id, name) == 1 },
    )
  is {
    [carrier] ->
      when carrier.datum is {
        InlineDatum(inline) ->
          if inline is RegistrationDatum(request): CageDatum {
            Some((carrier, request))
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
  // Raw data, forwarded as it is: the shared handler checks the pure burn
  // first and reads a redeemer only on a mint.
  mint(raw: Data, policy_id: PolicyId, tx: Transaction) {
    open_datum.mint(registry, raw, policy_id, tx)
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
