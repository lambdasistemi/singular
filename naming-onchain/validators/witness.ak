use aiken/collection/dict
use aiken/collection/dict.{get, keys}
use aiken/primitive/bytearray
use aiken/collection/list.{find}
use aiken/collection/pairs
use cardano/address
use cardano/assets.{PolicyId, Value, tokens}
use cardano/transaction.{Input, Spend, Transaction}
use naming.{modify_action_count, mpfs_state_hash}

/// The three token policies of a registry instance (#157 N1).
///
/// One parametrised minting script, instantiated three times — kind `0`
/// absent, `1` active, `2` terminal — to give the three policy ids the
/// registry pins at genesis. Under each of them the asset name is the
/// registry key itself (D-ASSET); this script never looks at names or
/// quantities, because it does not decide them.
///
/// **Its whole rule is co-presence.** A mint or a burn under this policy
/// is accepted only in a transaction that spends the registry's state
/// token with `Modify` — that is, inside a fold. The cage is what
/// computes how many tokens move and where they go (C5, C6); this policy
/// only refuses to let anything move when the cage is not there to say
/// so. Splitting it that way is the point: two scripts cannot disagree
/// about a quantity neither of them invents twice.
///
/// **The terminal instance is freely burnable** (W3). A terminal witness
/// says a name is over, forever; letting its holder destroy their own
/// copy costs the registry nothing, and the leaf it attests to does not
/// move. Minting one still needs the fold, because that is where the
/// read is verified.
///
/// The `registry` parameter is the full native asset identity of the
/// cage token — the state policy id followed by the token name — so an
/// instance is bound to one registry and cannot be reused against
/// another.
validator witness(kind: Int, registry: ByteArray) {
  mint(_redeemer: Data, policy_id: PolicyId, tx: Transaction) {
    if kind == 2 && pureBurn(policy_id, tx.mint) {
      // W3: a terminal witness is the holder's to destroy.
      True
    } else if foldPresent(registry, tx) {
      True
    } else {
      trace @"no-fold"
      False
    }
  }

  else(_) {
    fail
  }
}

/// Every movement under this policy in this transaction is a burn, and
/// there is at least one. A mint hiding beside a burn is not a pure
/// burn and needs the fold like any other mint.
fn pureBurn(policy_id: PolicyId, mint: Value) -> Bool {
  let moved = tokens(mint, policy_id)
  when keys(moved) is {
    [] -> False
    names -> allBurns(moved, names)
  }
}

fn allBurns(moved: dict.Dict<ByteArray, Int>, names: List<ByteArray>) -> Bool {
  when names is {
    [] -> True
    [name, ..rest] ->
      when get(moved, name) is {
        Some(quantity) -> quantity < 0 && allBurns(moved, rest)
        None -> False
      }
  }
}

/// The registry this instance is bound to is spent in this transaction
/// with a `Modify` redeemer: the fold is here, and it is the fold of OUR
/// registry, not of some other one that happens to be folding today.
fn foldPresent(registry: ByteArray, tx: Transaction) -> Bool {
  when find(tx.inputs, fn(input) { isRegistry(registry, input) }) is {
    Some(state) ->
      when pairs.get_first(tx.redeemers, Spend(state.output_reference)) is {
        Some(redeemer) -> modify_action_count(redeemer) >= 0
        None -> False
      }
    None -> False
  }
}

/// The registry state input: the cage's own script address, carrying
/// exactly one token under the cage policy, whose full asset identity is
/// this instance's parameter.
fn isRegistry(registry: ByteArray, input: Input) -> Bool {
  when input.output.address.payment_credential is {
    address.Script(hash) ->
      hash == mpfs_state_hash && when keys(
        tokens(input.output.value, mpfs_state_hash),
      ) is {
        [name] ->
          get(tokens(input.output.value, mpfs_state_hash), name) == Some(1) && bytearray.concat(
            mpfs_state_hash,
            name,
          ) == registry
        _ -> False
      }
    _ -> False
  }
}
