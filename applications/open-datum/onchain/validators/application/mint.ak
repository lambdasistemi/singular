//// The mint of the application policy.
////
//// ## Responsibility
//// Decides a transaction's mint under the application policy from the actions
//// its redeemer lists: each action is accepted by its own rule, no positive
//// quantity is minted that no action brings into being, burning is open, and
//// the transaction donates nothing to the treasury.
////
//// ## Dependencies
//// `application/births`, `application/configuration`, `application/held` and
//// `application/registration`; `singular_state/preimage`; the Aiken standard
//// library.
////
//// ## Assumptions
//// Booking a termination and a live update belong to other rules; their actions
//// are not listed here, so no approval for them can be minted. The spend of a
//// pending registration is decided by `application/spend`.
////
//// ## Invariants
//// Everything minted under the policy is either burned or accounted for by an
//// accepted action; two actions never create the same output.

use aiken/collection/list
use application/births.{positive_mints_are_births}
use application/configuration.{configuration_asset, configuration_create}
use application/held.{TokenId}
use application/registration.{
  registration_asset, registration_at, registration_book,
}
use cardano/assets.{PolicyId}
use cardano/transaction.{Output, OutputReference, Transaction}
use singular_state/preimage.{RegistryIdentity}

/// The actions of the model's `ApplicationAction` that take part in a mint.
/// The registry of a configuration creation is named by its state policy and
/// its state token name as plain byte strings. A redeemer built from
/// `RegistryIdentity` would put the aliases `PolicyId` and `AssetName` into the
/// blueprint, which then defines `ByteArray` with a title the registry's
/// blueprint does not give it, and the merged deployment blueprint refuses two
/// definitions that differ.
pub type ApplicationAction {
  ConfigurationCreate {
    state_policy: ByteArray,
    state_name: ByteArray,
    seed: OutputReference,
    output_index: Int,
  }
  BookRegistration { output_index: Int }
  ApprovalBurn
}

/// Model `birth`: the asset an action brings into being, when it does.
pub fn birth(
  application_policy: PolicyId,
  outputs: List<Output>,
  action: ApplicationAction,
) -> Option<TokenId> {
  when action is {
    ConfigurationCreate { state_policy, state_name, .. } ->
      Some(
        configuration_asset(
          application_policy,
          RegistryIdentity { policy: state_policy, name: state_name },
        ),
      )
    BookRegistration { output_index } ->
      when registration_at(outputs, output_index) is {
        Some((_, registration)) ->
          Some(registration_asset(application_policy, registration))
        None -> None
      }
    ApprovalBurn -> None
  }
}

/// The assets the actions bring into being, in the order of the actions.
pub fn births_of(
  application_policy: PolicyId,
  outputs: List<Output>,
  actions: List<ApplicationAction>,
) -> List<TokenId> {
  list.filter_map(
    actions,
    fn(action) { birth(application_policy, outputs, action) },
  )
}

/// The output an action creates, when it creates one.
fn birth_position(action: ApplicationAction) -> Option<Int> {
  when action is {
    ConfigurationCreate { output_index, .. } -> Some(output_index)
    BookRegistration { output_index } -> Some(output_index)
    ApprovalBurn -> None
  }
}

/// Model conjunct `birthCoverage`: no two actions create the output at one
/// index.
pub fn birth_positions_are_distinct(actions: List<ApplicationAction>) -> Bool {
  let positions = list.filter_map(actions, birth_position)
  list.length(list.unique(positions)) == list.length(positions)
}

/// Model `applicationAction` for the actions of a mint.
pub fn action_accepted(
  application_policy: PolicyId,
  tx: Transaction,
  births: List<TokenId>,
  action: ApplicationAction,
) -> Bool {
  when action is {
    ConfigurationCreate { state_policy, state_name, seed, output_index } ->
      configuration_create(
        application_policy,
        RegistryIdentity { policy: state_policy, name: state_name },
        seed,
        output_index,
        tx,
        births,
      )
    BookRegistration { output_index } ->
      registration_book(application_policy, output_index, tx, births)
    ApprovalBurn -> True
  }
}

/// Model conjunct `moneyTreasury` for a transaction with no termination
/// booking: the treasury donation is `required`.
pub fn donation_is(tx: Transaction, required: Int) -> Bool {
  when tx.treasury_donation is {
    None -> required == 0
    Some(donation) -> donation == required
  }
}

/// The model's `applicationStep` for the mint handler of the application
/// policy.
pub fn application_mint(
  application_policy: PolicyId,
  actions: List<ApplicationAction>,
  tx: Transaction,
) -> Bool {
  let births = births_of(application_policy, tx.outputs, actions)
  and {
    birth_positions_are_distinct(actions),
    list.all(
      actions,
      fn(action) { action_accepted(application_policy, tx, births, action) },
    ),
    positive_mints_are_births(application_policy, tx.mint, births),
    donation_is(tx, 0),
  }
}
