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
//// Booking a termination, a live update and the spend paths of a pending
//// registration belong to other rules; their actions are not listed here, so
//// no approval for them can be minted.
////
//// ## Invariants
//// Everything minted under the policy is either burned or accounted for by an
//// accepted action; two actions never create the same output.

use application/held.{TokenId}
use cardano/assets.{PolicyId}
use cardano/transaction.{Output, OutputReference, Transaction}

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
  _application_policy: PolicyId,
  _outputs: List<Output>,
  _action: ApplicationAction,
) -> Option<TokenId> {
  None
}

/// The assets the actions bring into being, in the order of the actions.
pub fn births_of(
  _application_policy: PolicyId,
  _outputs: List<Output>,
  _actions: List<ApplicationAction>,
) -> List<TokenId> {
  []
}

/// Model conjunct `birthCoverage`: no two actions create the output at one
/// index.
pub fn birth_positions_are_distinct(_actions: List<ApplicationAction>) -> Bool {
  False
}

/// Model `applicationAction` for the actions of a mint.
pub fn action_accepted(
  _application_policy: PolicyId,
  _tx: Transaction,
  _births: List<TokenId>,
  _action: ApplicationAction,
) -> Bool {
  False
}

/// Model conjunct `moneyTreasury` for a transaction with no termination
/// booking: the treasury donation is `required`.
pub fn donation_is(_tx: Transaction, _required: Int) -> Bool {
  False
}

/// The model's `applicationStep` for the mint handler of the application
/// policy.
pub fn application_mint(
  _application_policy: PolicyId,
  _actions: List<ApplicationAction>,
  _tx: Transaction,
) -> Bool {
  False
}
