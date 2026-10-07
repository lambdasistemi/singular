use aiken/collection/dict.{get, keys}
use aiken/collection/list
use aiken/collection/pairs
use aiken/primitive/bytearray
use application/envelope.{
  BookInsert, BookTerminate, Control, Envelope, OpenDatumMint, OpenDatumSpend,
  Release, Update, envelopeHash, envelopeVersion, registryBytes,
}
use cardano/address.{Address, Script, VerificationKey}
use cardano/assets.{
  PolicyId, Value, lovelace_of, quantity_of, tokens, without_lovelace,
}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Spend, Transaction, find_input,
}
use lib.{
  approvalName, decodeAddress, destinationDatumHash, edgeInsertActive,
  edgeUpdateTerminal, edgeWitnessTerminal,
}
use registry/duty.{Duty, ReturnDeposit, dutiesOf, pushDuties, pushDuty}
use registry/refusal.{traceFalse}
use registry/settlement.{custodyOwedOf, payeeOwed, settlesOf}
use types.{
  CageDatum, Modify, Rejected, Request, RequestAction, RequestDatum, State,
  StateDatum, UpdateAction, UpdateRedeemer,
}
use witness.{registryStateHash}

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
/// - `Release`: inside the fold of this registry that terminates this key
///   for its controller and burns exactly this token, with the controller
///   paid, on the summed lovelace of the outputs at their key, every
///   obligation of this registry's fold to them plus every deposit this
///   instance releases to them (the model's additive `settleFold`). A
///   second registry cannot fold in the same transaction: every fold's
///   continuation is the transaction's first output, which holds exactly
///   one state token (`registry/modify` `state-token`), so no other fold's
///   obligations or any other instance's releases can share the payment.
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
                    BookTerminate { key, owner, holding } ->
                      bookTerminate(
                        registry,
                        policy_id,
                        state,
                        name,
                        key,
                        owner,
                        holding,
                        tx,
                      )
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
      Release -> validRelease(registry, control, self.output, tx)
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

/// `bookTerminateStep`: the live output for the key is read as a
/// reference input and bound to this registry, the actual state's active
/// policy, the key and its controller; the request names no destination.
fn bookTerminate(
  registry: ByteArray,
  policy_id: PolicyId,
  state: State,
  name: ByteArray,
  key: ByteArray,
  owner: ByteArray,
  holding: OutputReference,
  tx: Transaction,
) -> Bool {
  when find_input(tx.reference_inputs, holding) is {
    None -> traceFalse(@"no-application-output")
    Some(live) -> {
      let Output { address, value, datum, .. } = live.output
      if address.payment_credential != Script(policy_id) || quantity_of(
        value,
        state.active_policy,
        key,
      ) != 1 {
        traceFalse(@"app-terminate-token")
      } else {
        when liveControl(datum) is {
          None -> traceFalse(@"app-terminate-binding")
          Some(control) ->
            if control.key != key || registryBytes(control.registry) != registry || control.activePolicy != state.active_policy {
              traceFalse(@"app-terminate-binding")
            } else if owner != control.controller {
              traceFalse(@"app-owner")
            } else if !list.has(tx.extra_signatories, control.controller) {
              traceFalse(@"app-controller-signature")
            } else if name != approvalName(
              edgeUpdateTerminal,
              key,
              owner,
              noDestination,
            ) {
              // The name binds the empty destination, so a request that
              // names any destination cannot fold with this approval.
              traceFalse(@"app-terminate-destination")
            } else {
              True
            }
        }
      }
    }
  }
}

/// A termination delivers nothing: the model's `r.output = 0`.
const noDestination: (ByteArray, ByteArray) = (#"", #"")

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
// Release
// ---------------------------------------------------------------------

/// The fold's requests paired with their actions, in input order, exactly
/// as the registry pairs them: every input carrying a request for this
/// registry's token takes the next action.
fn foldRows(
  state_name: ByteArray,
  inputs: List<Input>,
  actions: List<RequestAction>,
) -> List<(Request, Int, RequestAction)> {
  when inputs is {
    [] -> []
    [input, ..rest] ->
      when requestOf(state_name, input) is {
        Some(request) ->
          when actions is {
            [action, ..tail] ->
              [
                (request, lovelace_of(input.output.value), action),
                ..foldRows(state_name, rest, tail)
              ]
            [] -> []
          }
        None -> foldRows(state_name, rest, actions)
      }
  }
}

fn requestOf(state_name: ByteArray, input: Input) -> Option<Request> {
  when input.output.datum is {
    InlineDatum(inline) ->
      if inline is RequestDatum(request): CageDatum {
        if request.requestToken.assetName == state_name {
          Some(request)
        } else {
          None
        }
      } else {
        None
      }
    _ -> None
  }
}

/// The duties the registry's own fold owes for these rows (`registry/fold`
/// `stepRequest`): a rejected row its refund, a processed row its edge's
/// duties. Read with the registry's own `dutiesOf`, so the two scripts
/// sum the same obligations.
fn rowDuties(
  state: State,
  rows: List<(Request, Int, RequestAction)>,
) -> List<Duty> {
  list.foldl(
    rows,
    [],
    fn(row, duties) {
      let (request, held, action) = row
      let floor = held - state.tip
      when action is {
        Rejected ->
          pushDuty(duties, ReturnDeposit { owner: request.requestOwner, floor })
        UpdateAction(_) ->
          if request.edge < 0 || request.edge > edgeWitnessTerminal {
            duties
          } else {
            pushDuties(
              duties,
              dutiesOf(
                state,
                request.edge,
                request.requestOwner,
                request.requestKey,
                request.destination,
                floor,
              ),
            )
          }
      }
    },
  )
}

/// Any registry's state as an input presents it: at the state script's
/// address, holding exactly one state token (whichever registry's), under
/// an inline state datum. Returns that registry's state token name.
fn anyStateOf(input: Input) -> Option<(ByteArray, State)> {
  let Output { address, value, datum, .. } = input.output
  if address.payment_credential != Script(registryStateHash) {
    None
  } else {
    let held = tokens(value, registryStateHash)
    when keys(held) is {
      [name] ->
        if get(held, name) != Some(1) {
          None
        } else {
          when datum is {
            InlineDatum(inline) ->
              if inline is StateDatum(state): CageDatum {
                Some((name, state))
              } else {
                None
              }
            _ -> None
          }
        }
      _ -> None
    }
  }
}

/// Every registry fold in the transaction, whichever registry: a state
/// spent with `Modify`, with its token name, state and actions.
fn foldsIn(
  tx: Transaction,
) -> List<(Input, ByteArray, State, List<RequestAction>)> {
  list.filter_map(
    tx.inputs,
    fn(input) {
      when anyStateOf(input) is {
        Some((name, state)) ->
          when pairs.get_first(tx.redeemers, Spend(input.output_reference)) is {
            Some(raw) ->
              if raw is Modify(actions): UpdateRedeemer {
                Some((input, name, state, actions))
              } else {
                None
              }
            None -> None
          }
        None -> None
      }
    },
  )
}

/// This instance's registry among the folds: exactly one.
fn ownFold(
  registry: ByteArray,
  folds: List<(Input, ByteArray, State, List<RequestAction>)>,
) -> Option<(Input, ByteArray, State, List<RequestAction>)> {
  when
    list.filter(
      folds,
      fn(fold) {
        let (_, name, _, _) = fold
        bytearray.concat(registryStateHash, name) == registry
      },
    )
  is {
    [fold] -> Some(fold)
    _ -> None
  }
}

/// What the given registry folds owe one payee, summed, and the duties
/// they create together (#253, DM-seven-admitted-edges):
/// each fold's deposits, reject refunds and custody refunds to that key,
/// read with the registry's own `dutiesOf`, `custodyOwedOf` and
/// `payeeOwed`. `None` when a fold's custody refunds cannot be read.
fn registryOwed(
  folds: List<(Input, ByteArray, State, List<RequestAction>)>,
  payee: address.PaymentCredential,
  tx: Transaction,
) -> Option<(Int, List<Duty>)> {
  list.foldl(
    folds,
    Some((0, [])),
    fn(fold, acc) {
      when acc is {
        None -> None
        Some((owed, allDuties)) -> {
          let (input, name, state, actions) = fold
          let duties = rowDuties(state, foldRows(name, tx.inputs, actions))
          when
            custodyOwedOf(state, input.output.address, duties, tx.inputs)
          is {
            None -> None
            Some(custodyOwed) -> {
              let floor =
                when pairs.get_first(payeeOwed(duties, custodyOwed), payee) is {
                  Some(amount) -> amount
                  None -> 0
                }
              Some((owed + floor, list.concat(allDuties, duties)))
            }
          }
        }
      }
    },
  )
}

/// What the transaction releases to one controller at this instance: the
/// protected deposit of every output at this script spent with `Release`
/// whose control names that controller.
fn releasedTo(script: ByteArray, controller: ByteArray, tx: Transaction) -> Int {
  list.foldl(
    tx.inputs,
    0,
    fn(input, total) {
      if input.output.address.payment_credential != Script(script) {
        total
      } else {
        when pairs.get_first(tx.redeemers, Spend(input.output_reference)) is {
          Some(raw) ->
            if raw is Release: OpenDatumSpend {
              when liveControl(input.output.datum) is {
                Some(control) ->
                  if control.controller == controller {
                    total + control.deposit
                  } else {
                    total
                  }
                None -> total
              }
            } else {
              total
            }
          None -> total
        }
      }
    },
  )
}

/// The fold of this registry terminates this key for its controller and
/// burns exactly this token; the controller's key is paid, on the summed
/// lovelace of the outputs at that key, every obligation of this registry's
/// fold to it plus every deposit this instance releases to it.
fn validRelease(
  registry: ByteArray,
  control: Control,
  self: Output,
  tx: Transaction,
) -> Bool {
  expect Script(script) = self.address.payment_credential
  if !holdsItsToken(control, self) {
    traceFalse(@"release-holding-token")
  } else if registryBytes(control.registry) != registry {
    traceFalse(@"release-registry")
  } else {
    when ownFold(registry, foldsIn(tx)) is {
      None -> traceFalse(@"release-no-fold")
      Some(fold) -> {
        let (_, name, state, actions) = fold
        let terminating =
          list.filter(
            foldRows(name, tx.inputs, actions),
            fn(row) {
              let (request, _, action) = row
              action != Rejected && request.edge == edgeUpdateTerminal && request.requestKey == control.key
            },
          )
        if state.application_policy != script {
          traceFalse(@"release-not-pinned")
        } else if control.activePolicy != state.active_policy {
          traceFalse(@"release-active-policy")
        } else {
          when terminating is {
            [(request, _, _)] ->
              if request.requestOwner != control.controller {
                traceFalse(@"release-controller")
              } else if quantity_of(tx.mint, control.activePolicy, control.key) != -1 {
                traceFalse(@"release-burn")
              } else {
                let payee = VerificationKey(control.controller)
                when registryOwed([fold], payee, tx) is {
                  None -> traceFalse(@"release-settlement")
                  Some((owed, duties)) -> {
                    let settles = settlesOf(Script(registryStateHash), duties)
                    let paid =
                      list.foldl(
                        tx.outputs,
                        0,
                        fn(out, total) {
                          if out.address.payment_credential == payee && settles(
                            out,
                          ) {
                            total + lovelace_of(out.value)
                          } else {
                            total
                          }
                        },
                      )
                    if paid < owed + releasedTo(script, control.controller, tx) {
                      traceFalse(@"release-additive")
                    } else {
                      True
                    }
                  }
                }
              }
            _ -> traceFalse(@"release-no-termination")
          }
        }
      }
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
