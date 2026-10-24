//// What the application policy may bring into being in one transaction.
////
//// ## Responsibility
//// The accounting of the application policy's mint: an asset is fresh when
//// its minted quantity is exactly the number of actions that bring it into
//// being, and no positive quantity under the policy is minted without such
//// an action. Burning is not restricted.
////
//// ## Dependencies
//// `application/held` for the token type; the Aiken standard library.
////
//// ## Assumptions
//// The ledger runs the mint handler whenever the policy appears in the mint.
////
//// ## Invariants
//// Nothing is minted under the application policy that an action of the
//// transaction does not account for, so a burn grants nothing.

use aiken/collection/list
use application/held.{TokenId}
use cardano/assets.{PolicyId, Value, quantity_of}

/// Model guard `freshApproval`: the minted quantity of `asset` is exactly the
/// number of its births, and there is at least one.
pub fn fresh_asset(mint: Value, births: List<TokenId>, asset: TokenId) -> Bool {
  let born = list.count(births, fn(birth) { birth == asset })
  and {
    quantity_of(mint, asset.policy, asset.name) == born,
    born > 0,
  }
}

/// Model conjunct of `applicationStep` on the mint: every entry under the
/// application policy is a burn, or an asset one of the actions brings into
/// being.
pub fn positive_mints_are_births(
  _application_policy: PolicyId,
  _mint: Value,
  _births: List<TokenId>,
) -> Bool {
  False
}
