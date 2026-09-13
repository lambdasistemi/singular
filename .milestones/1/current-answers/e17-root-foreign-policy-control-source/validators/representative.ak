use aiken/collection/dict.{get, keys}
use aiken/collection/list.{all, filter, find, foldl, length}
use aiken/collection/pairs
use cardano/address
use cardano/assets.{tokens, PolicyId, Value}
use application.{ApplicationRedeemer, retirement_custody_hash}
use cardano/transaction.{Input, Spend, Transaction}
use naming.{mpfs_state_hash}

/// The representative minting policy (issue #52): one representative
/// per naming record; `assetScope` is the record's incarnation, so
/// reuse mints a fresh representative under the same policy.
///
/// The policy is parameterized by the application validator's script
/// hash — with the application validator itself carrying zero
/// parameters, the pinned application hash is the parameter value. The
/// policy never moves an asset on its own authority: every mint or burn
/// must ride a transaction that spends a naming record or claim at the
/// application validator, or spends retirement custody holding the burned
/// asset — and the spend's own redeemer (application side) or the custody
/// script itself (completion side) must authorize exactly the movement.
///
/// - `Fold` (a claim folds into a record) mints each named
///   representative exactly once (`LC`/claim rows, `representativeMint`).
/// - `Retire` (a record is retired or reused) burns each named
///   representative exactly once — either in the retire transaction
///   itself (named by the `Retire` redeemer) or later, permissionlessly,
///   by spending the completion-only custody the retire filled (issue
///   #74: the custody script enforces the burn, and only an authorized
///   `Retire` can place an asset into custody, so the custody-authorized
///   burn grants no new authority).
pub type RepresentativeRedeemer {
  MintRepresentative
  BurnRepresentative
}

validator representative(application_policy: PolicyId) {
  mint(redeemer: RepresentativeRedeemer, policy_id: PolicyId, tx: Transaction) {
    when redeemer is {
      MintRepresentative -> {
        expect
          application.Fold { representatives }: ApplicationRedeemer =
          application_spend_redeemer(application_policy, tx)
        expect exact_movement(tx.mint, policy_id, representatives, 1)
        True
      }
      BurnRepresentative -> {
        // Completion first (total — False when the shape is absent):
        // a permissionless custody spend carrying the burn. Otherwise
        // the legacy retire path, verbatim: an application `Retire`
        // spend names the burned representatives. The legacy path keeps
        // its exact verdicts (including multi-name retires); only a
        // custody-carried burn is newly accepted.
        if burn_carried_by_custody(policy_id, tx) {
          True
        } else {
          expect
            application.Retire { representatives, key_hash: _ }: ApplicationRedeemer =
            application_spend_redeemer(application_policy, tx)
          expect exact_movement(tx.mint, policy_id, representatives, -1)
          True
        }
      }
    }
  }

  else(_) {
    fail
  }
}

/// The redeemer of the application validator's spend in this
/// transaction. There must be exactly one: a transaction that moves
/// representatives spends a naming record at the application address,
/// and that spend's redeemer names the representatives.
fn application_spend_redeemer(application_policy: PolicyId, tx: Transaction) -> Data {
  expect Some(record_input) =
    find(tx.inputs, fn(input) {
      when input.output.address.payment_credential is {
        address.Script(hash) -> hash == application_policy
        _ -> False
      }
    })
  expect Some(redeemer) =
    pairs.get_first(tx.redeemers, Spend(record_input.output_reference))
  redeemer
}

/// The completion path (issue #74 precedent, NOTE-028 contract):
/// exactly one live input sits at the retirement-custody script, it
/// holds exactly one asset at quantity 1 under this policy, the mint
/// field burns exactly that asset once under this policy, AND the
/// transaction spends the registry state (a genuine registry
/// transition — a standalone custody spend with no state input is
/// False here, so a burn-only completion refuses). Total: any other
/// shape is False, never a crash — the legacy retire path must still
/// be tried. Grants
/// no new authority: the custody script's only spending path requires
/// every held non-lovelace asset to burn, and only an
/// application-authorized `Retire` can place an asset into custody — so
/// this arm fires only inside a genuine completion, which the custody
/// script independently enforces.
fn burn_carried_by_custody(policy_id: PolicyId, tx: Transaction) -> Bool {
  let custody_credential = address.Script(retirement_custody_hash)
  let carriers =
    filter(tx.inputs, fn(input) {
      input.output.address.payment_credential == custody_credential
    })
  when carriers is {
    [carrier] ->
      held_is_exact_burn(carrier.output.value, tx.mint, policy_id)
        && has_spent_registry_state(tx)
    _ -> False
  }
}

/// A spent registry-state input is present (NOTE-028): the burn must
/// ride a genuine registry transition — reference inputs do not
/// count (a transition spends). Total: absence is False, so the
/// legacy retire path is still tried. Authentication shape mirrors the
/// application validator's `is_registry_state` (script hash plus the
/// single cage token).
fn has_spent_registry_state(tx: Transaction) -> Bool {
  when find(tx.inputs, is_spent_registry_state) is {
    Some(_) -> True
    None -> False
  }
}

fn is_spent_registry_state(input: Input) -> Bool {
  when input.output.address.payment_credential is {
    address.Script(hash) ->
      hash == mpfs_state_hash && has_single_cage_token(input.output.value)
    _ -> False
  }
}

fn has_single_cage_token(value: Value) -> Bool {
  let policy_tokens = tokens(value, mpfs_state_hash)
  when keys(policy_tokens) is {
    [name] -> get(policy_tokens, name) == Some(1)
    _ -> False
  }
}

/// The single custody carrier holds exactly one asset at quantity 1
/// under the policy and the mint field burns exactly that asset once
/// under the policy. Total: any other shape is False — the legacy
/// retire path is still tried for burns that ride no custody carrier.
fn held_is_exact_burn(
  held_value: Value,
  mint: Value,
  policy_id: PolicyId,
) -> Bool {
  let held = tokens(held_value, policy_id)
  let burned = tokens(mint, policy_id)
  when keys(held) is {
    [name] ->
      get(held, name) == Some(1)
        && keys(burned) == [name]
        && get(burned, name) == Some(-1)
    _ -> False
  }
}

/// The mint field under this policy is exactly the named
/// representatives, each at exactly `quantity`, nothing else.
fn exact_movement(
  mint: Value,
  policy_id: PolicyId,
  representatives: List<ByteArray>,
  quantity: Int,
) -> Bool {
  let policy_tokens = tokens(mint, policy_id)
  // every named representative moves by exactly `quantity` …
  all(representatives, fn(name) {
    get(policy_tokens, name) == Some(quantity)
  })
    // … and nothing else moves under this policy (duplicates in the
    // redeemer list would not add names, so the counts must agree on
    // distinct names).
    && length(keys(policy_tokens)) == length(distinct(representatives))
}

/// Distinct members of a list — the set the count is quantified over.
fn distinct(names: List<ByteArray>) -> List<ByteArray> {
  foldl(
    names,
    [],
    fn(name: ByteArray, acc: List<ByteArray>) {
      if contains(acc, name) {
        acc
      } else {
        [name, ..acc]
      }
    },
  )
}

fn contains(names: List<ByteArray>, name: ByteArray) -> Bool {
  when names is {
    [] -> False
    [head, ..tail] -> head == name || contains(tail, name)
  }
}
