//// Witness policies bound to the permanent M1 state identity.
//// The state's fixed fold boundary controls every mint and active burn.
//// Pure terminal burns retain the broader model rule and enable no edge.

use aiken/collection/dict.{get, keys}
use aiken/collection/list.{find, length}
use aiken/collection/pairs
use aiken/primitive/bytearray
use cardano/address
use cardano/assets.{PolicyId, Value, tokens}
use cardano/transaction.{Input, Spend, Transaction}
use registry_pin.{registryStateHash}
use types.{Modify, UpdateRedeemer}

/// The three token policies of a registry instance (#157 N1).
///
/// One parametrised minting script, instantiated three times — kind `0`
/// absent, `1` active, `2` terminal — to give the three policy ids the
/// registry pins at genesis. Under each of them the asset name is the
/// registry key itself (token-name-is-registry-key); this script never looks at names or
/// quantities, because it does not decide them.
///
/// **Its whole rule is co-presence.** A mint or a burn under this policy
/// is accepted only in a transaction that spends the registry's state
/// token with `Modify` — that is, inside a fold. The cage is what
/// computes how many tokens move and where they go (mint-matches-edge-deltas, token-destinations-and-refunds); this policy
/// only refuses to let anything move when the cage is not there to say
/// so. Splitting it that way is the point: two scripts cannot disagree
/// about a quantity neither of them invents twice.
///
/// **Terminal witnessing is excluded by the permanent state contract.**
/// The kind `2` policy representation remains defined, but a `witnessTerminal`
/// request cannot pass the co-present permanent state validator. Co-presence
/// alone in this policy is not transaction acceptance: the state validator
/// refuses that edge, including beside an allowed request in a mixed batch.
/// The terminal instance retains the broader pure-burn rule, which changes
/// no leaf. Terminal holdings cannot arise from this contract's genesis;
/// a fixture seeded with one establishes the burn rule, not reachability.
///
/// The `registry` parameter is the full native asset identity of the
/// cage token — the state policy id followed by the token name — so an
/// instance is bound to one registry and cannot be reused against
/// another.
///
/// This policy retains the broader witness decision table and decodes
/// `types.UpdateRedeemer`. Its distinct fixed state pin supplies the permanent
/// admission boundary; it does not enable broader witness operations.
validator witness(kind: Int, registry: ByteArray) {
  mint(_redeemer: Data, policy_id: PolicyId, tx: Transaction) {
    if kind == 2 && pureBurn(policy_id, tx.mint) {
      // terminal-witnesses-plural: a terminal witness is the holder's to destroy.
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
        Some(redeemer) -> modifyActionCount(redeemer) >= 0
        None -> False
      }
    None -> False
  }
}

/// How many per-request actions the spend redeemer carries, or `-1` when
/// the redeemer is not a `Modify` at all. A `Modify` with an empty
/// action list still counts as a fold here: how many requests a fold may
/// carry is the cage's rule (it refuses an empty one), not this policy's,
/// and re-deciding it in two scripts is exactly the disagreement the
/// split exists to prevent.
fn modifyActionCount(redeemer_data: Data) -> Int {
  if redeemer_data is Modify(actions): UpdateRedeemer {
    length(actions)
  } else {
    -1
  }
}

/// The registry state input: the cage's own script address, carrying
/// exactly one token under the cage policy, whose full asset identity is
/// this instance's parameter.
fn isRegistry(registry: ByteArray, input: Input) -> Bool {
  when input.output.address.payment_credential is {
    address.Script(hash) ->
      hash == registryStateHash && when
        keys(tokens(input.output.value, registryStateHash))
      is {
        [name] ->
          get(tokens(input.output.value, registryStateHash), name) == Some(1) && bytearray.concat(
            registryStateHash,
            name,
          ) == registry
        _ -> False
      }
    _ -> False
  }
}
