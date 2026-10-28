//// Spending the records at the application address.
////
//// ## Responsibility
//// Decides the spend of a pending registration from the action of its
//// redeemer: a fold delivers the genuine token into the new holding before
//// the processing deadline, the refund address reclaims the whole request
//// inside the reclaim window, and anyone cleans the request up after the
//// window, returning the deposit to the refund address. Every spend burns the
//// approval it consumes. A live holding is updated or booked for termination
//// by its controller. An empty termination request spends only with both
//// token burns, without a signer or a clock.
////
//// ## Dependencies
//// `application/held` for the records, `application/phases` for the phase of
//// the validity range, `application/payments` for what the transaction pays;
//// `application/registration` for the approval of a registration;
//// `singular_state/preimage` for the active token name; the Aiken standard
//// library.
////
//// ## Assumptions
//// The ledger runs the spend handler once for every input at the address of
//// the script, with that input's redeemer, so every application input has
//// exactly one action, and `transaction.redeemers` lists the redeemer of every
//// spent input as the ledger hands it to that input's handler. The Singular
//// state script decides which token is the genuine active token of a
//// registration; this script checks that exactly one is minted and that the
//// holding carries it.
////
//// ## Invariants
//// Before the processing deadline only a fold spends a pending registration.
//// Whoever spends one burns its approval, so an approval is good for one
//// spend. The payments the spent registrations of a transaction require are
//// covered together, so one output does not satisfy two spends.

use aiken/collection/list
use aiken/crypto.{VerificationKeyHash}
use application/held.{Live, Registration, RegistrationData, TokenId, held_datum}
use application/live.{live_update}
use application/payments.{Payment, payments_covered}
use application/phases.{Cleanup, Processing, Reclaim, classify_phase}
use application/registration.{
  registration_asset, registration_funding, registration_shape,
}
use application/termination.{
  termination_approval, termination_book, termination_shape,
}
use cardano/address.{Script, VerificationKey}
use cardano/assets.{PolicyId, Value, lovelace_of, quantity_of}
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Spend, Transaction,
}
use singular_state/preimage.{RegistryIdentity, active_token_name}

/// The actions of the model's `ApplicationAction` that spend an application
/// input. The reference of the input is the one the ledger hands the
/// handler.
pub type SpendAction {
  RegistrationFold { holding_index: Int }
  OwnerReclaim
  ExpiredCleanup
  LiveUpdate { successor_index: Int }
  BookTermination { output_index: Int }
  TerminationFold {
    state_policy: ByteArray,
    state_name: ByteArray,
    key: ByteArray,
  }
}

/// Model `requestInput`: the output that `reference` spends, when exactly one
/// input spends it.
pub fn request_input(
  inputs: List<Input>,
  reference: OutputReference,
) -> Option<Output> {
  when
    list.filter(inputs, fn(input) { input.output_reference == reference })
  is {
    [input] -> Some(input.output)
    _ -> None
  }
}

/// Model `approvalBurned`: the transaction burns at least as many of
/// `approval` as its inputs hold.
pub fn approval_burned(tx: Transaction, approval: TokenId) -> Bool {
  let consumed =
    list.foldr(
      tx.inputs,
      0,
      fn(input, total) {
        total + quantity_of(input.output.value, approval.policy, approval.name)
      },
    )
  quantity_of(tx.mint, approval.policy, approval.name) <= -consumed
}

/// The genuine active token of a registration: under the state policy of its
/// registry, named from the registry and the key.
fn active_token(registration: RegistrationData) -> TokenId {
  let registry = registration.registry
  TokenId {
    policy: registry.policy,
    name: active_token_name(registry, registration.key),
  }
}

/// Model guard `registrationDelivery`: the output at `holding_index` is the
/// holding the registration committed, carries the genuine active token, and
/// the transaction mints exactly one.
pub fn registration_delivery(
  registration: RegistrationData,
  outputs: List<Output>,
  mint: Value,
  holding_index: Int,
) -> Bool {
  let active = active_token(registration)
  when list.at(outputs, holding_index) is {
    Some(holding) -> and {
        holding.address == registration.holding_address,
        holding.datum == InlineDatum(registration.initial_datum),
        lovelace_of(holding.value) == registration.deposit,
        quantity_of(holding.value, active.policy, active.name) == 1,
        quantity_of(mint, active.policy, active.name) == 1,
      }
    None -> False
  }
}

/// Model `reclaimPhase`, signature part: the refund address signs, when its
/// payment credential is a verification key that is among the required
/// signers. A script cannot sign.
pub fn refund_signature(
  registration: RegistrationData,
  signatories: List<VerificationKeyHash>,
) -> Bool {
  let refund = registration.refund_address
  when refund.payment_credential is {
    VerificationKey(hash) -> list.has(signatories, hash)
    Script(_) -> False
  }
}

/// The action a redeemer carries, when it carries one.
pub fn spend_action_of(redeemer: Data) -> Option<SpendAction> {
  if redeemer is RegistrationFold { holding_index }: SpendAction {
    Some(RegistrationFold { holding_index })
  } else if redeemer is OwnerReclaim: SpendAction {
    Some(OwnerReclaim)
  } else if redeemer is ExpiredCleanup: SpendAction {
    Some(ExpiredCleanup)
  } else if redeemer is LiveUpdate { successor_index }: SpendAction {
    Some(LiveUpdate { successor_index })
  } else if redeemer is BookTermination { output_index }: SpendAction {
    Some(BookTermination { output_index })
  } else if redeemer is TerminationFold { state_policy, state_name, key }: SpendAction {
    Some(TerminationFold { state_policy, state_name, key })
  } else {
    None
  }
}

/// The payment the action requires of the transaction that spends `input`, the
/// pending registration `registration`: a fold pays the deposit at the holding
/// address, a reclaim pays everything the request holds and a cleanup pays the
/// deposit, both at the refund address.
fn payment_of(
  action: SpendAction,
  input: Output,
  registration: RegistrationData,
) -> Option<Payment> {
  when action is {
    RegistrationFold { .. } ->
      Some(
        Payment {
          address: registration.holding_address,
          amount: registration.deposit,
        },
      )
    OwnerReclaim ->
      Some(
        Payment {
          address: registration.refund_address,
          amount: lovelace_of(input.value),
        },
      )
    ExpiredCleanup ->
      Some(
        Payment {
          address: registration.refund_address,
          amount: registration.deposit,
        },
      )
    LiveUpdate { .. } | BookTermination { .. } | TerminationFold { .. } -> None
  }
}

/// The payment that the spend of the input at `reference` requires, when that
/// input is a pending registration at the address of this script and the
/// redeemer is an action.
fn payment_for(
  application_policy: PolicyId,
  reference: OutputReference,
  redeemer: Data,
  inputs: List<Input>,
) -> Option<Payment> {
  when list.find(inputs, fn(input) { input.output_reference == reference }) is {
    Some(Input { output, .. }) ->
      if output.address.payment_credential == Script(application_policy) {
        when (held_datum(output), spend_action_of(redeemer)) is {
          (Some(Registration { registration }), Some(action)) ->
            payment_of(action, output, registration)
          _ -> None
        }
      } else {
        None
      }
    None -> None
  }
}

/// Model `requiredPayments`: the payments the spent registrations of the
/// transaction require, one per spent registration, read from the redeemer of
/// each spent input at the address of this script.
pub fn required_payments(
  application_policy: PolicyId,
  tx: Transaction,
) -> List<Payment> {
  list.filter_map(
    tx.redeemers,
    fn(Pair(purpose, redeemer)) {
      when purpose is {
        Spend(reference) ->
          payment_for(application_policy, reference, redeemer, tx.inputs)
        _ -> None
      }
    },
  )
}

/// Model `registrationSpend`: the decision on the spend of `input`, the
/// pending registration `registration`, by `action`.
pub fn registration_spend(
  application_policy: PolicyId,
  action: SpendAction,
  input: Output,
  registration: RegistrationData,
  tx: Transaction,
) -> Bool {
  and {
    registration_shape(application_policy, input, registration),
    registration_funding(input, registration),
    approval_burned(tx, registration_asset(application_policy, registration)),
    when action is {
      RegistrationFold { holding_index } -> and {
          classify_phase(registration, tx.validity_range) == Processing,
          registration_delivery(
            registration,
            tx.outputs,
            tx.mint,
            holding_index,
          ),
        }
      OwnerReclaim -> and {
          classify_phase(registration, tx.validity_range) == Reclaim,
          refund_signature(registration, tx.extra_signatories),
        }
      ExpiredCleanup ->
        classify_phase(registration, tx.validity_range) == Cleanup
      LiveUpdate { .. } | BookTermination { .. } | TerminationFold { .. } ->
        False
    },
  }
}

/// Model `applicationAction` for the spend of the input at `own_reference`.
pub fn application_spend(
  action: SpendAction,
  own_reference: OutputReference,
  tx: Transaction,
) -> Bool {
  when request_input(tx.inputs, own_reference) is {
    Some(input) ->
      when input.address.payment_credential is {
        Script(application_policy) -> and {
            donation_matches(application_policy, tx),
            when held_datum(input) is {
              Some(Registration { registration }) -> and {
                  registration_spend(
                    application_policy,
                    action,
                    input,
                    registration,
                    tx,
                  ),
                  payments_covered(
                    required_payments(application_policy, tx),
                    tx.outputs,
                  ),
                }
              Some(Live { control, .. }) ->
                when action is {
                  LiveUpdate { successor_index } ->
                    live_update(
                      application_policy,
                      input,
                      control,
                      successor_index,
                      tx,
                    )
                  BookTermination { output_index } ->
                    termination_book(
                      application_policy,
                      input,
                      control,
                      output_index,
                      tx,
                      [
                        termination_approval(
                          application_policy,
                          control.registry,
                          control.key,
                        ),
                      ],
                    )
                  _ -> False
                }
              _ ->
                when action is {
                  TerminationFold { state_policy, state_name, key } ->
                    termination_spend(
                      application_policy,
                      input,
                      RegistryIdentity {
                        policy: state_policy,
                        name: state_name,
                      },
                      key,
                      tx,
                    )
                  _ -> False
                }
            },
          }
        _ -> False
      }
    None -> False
  }
}

/// Model terminationSpend: no signature or clock. A nonzero mint under the
/// active policy invokes that policy by ledger rules; its validator decides
/// whether the burn belongs to a fold of this registry.
pub fn termination_spend(
  application_policy: PolicyId,
  input: Output,
  registry: RegistryIdentity,
  key: ByteArray,
  tx: Transaction,
) -> Bool {
  and {
    termination_shape(application_policy, input, registry, key),
    approval_burned(tx, termination_approval(application_policy, registry, key)),
    quantity_of(tx.mint, registry.policy, active_token_name(registry, key)) == -1,
  }
}

/// Model requiredTreasury, read from the complete ledger-supplied spend
/// redeemers: each termination booking contributes its protected deposit.
pub fn required_treasury(application_policy: PolicyId, tx: Transaction) -> Int {
  list.foldl(
    tx.redeemers,
    0,
    fn(Pair(purpose, redeemer), total) {
      when purpose is {
        Spend(reference) ->
          when
            (request_input(tx.inputs, reference), spend_action_of(redeemer))
          is {
            (Some(input), Some(BookTermination { .. })) ->
              if input.address.payment_credential == Script(application_policy) {
                when held_datum(input) is {
                  Some(Live { control, .. }) -> total + control.deposit
                  _ -> total
                }
              } else {
                total
              }
            _ -> total
          }
        _ -> total
      }
    },
  )
}

pub fn donation_matches(application_policy: PolicyId, tx: Transaction) -> Bool {
  let required = required_treasury(application_policy, tx)
  when tx.treasury_donation is {
    None -> required == 0
    Some(donation) -> donation == required
  }
}
