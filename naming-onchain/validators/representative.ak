use aiken/collection/dict.{get, keys}
use aiken/collection/list.{all, find, foldl, length}
use aiken/collection/pairs
use cardano/address
use cardano/assets.{tokens, PolicyId, Value}
use application.{ApplicationRedeemer}
use cardano/transaction.{Spend, Transaction}

/// The representative minting policy (issue #52): one representative
/// per naming record; `assetScope` is the record's incarnation, so
/// reuse mints a fresh representative under the same policy.
///
/// The policy is parameterized by the application validator's script
/// hash — with the application validator itself carrying zero
/// parameters, the pinned application hash is the parameter value. The
/// policy never moves an asset on its own authority: every mint or burn
/// must ride a transaction that spends a naming record or claim at the
/// application validator, and the application spend's own redeemer must
/// name exactly the representatives moved.
///
/// - `Fold` (a claim folds into a record) mints each named
///   representative exactly once (`LC`/claim rows, `representativeMint`).
/// - `Retire` (a record is retired or reused) burns each named
///   representative exactly once.
pub type RepresentativeRedeemer {
  MintRepresentative
  BurnRepresentative
}

validator representative(application_policy: PolicyId) {
  mint(redeemer: RepresentativeRedeemer, policy_id: PolicyId, tx: Transaction) {
    let app_redeemer = application_spend_redeemer(application_policy, tx)
    when redeemer is {
      MintRepresentative -> {
        expect
          application.Fold { representatives }: ApplicationRedeemer =
          app_redeemer
        expect exact_movement(tx.mint, policy_id, representatives, 1)
        True
      }
      BurnRepresentative -> {
        expect
          application.Retire { representatives }: ApplicationRedeemer =
          app_redeemer
        expect exact_movement(tx.mint, policy_id, representatives, -1)
        True
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
