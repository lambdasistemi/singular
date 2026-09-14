use cardano/address
use aiken/primitive/bytearray
use application.{Cancel, Fold, Retire}
use cardano/assets.{add, zero}
use cardano/transaction.{Input, NoDatum, Output}
use fixtures.{
  app_policy, claim_input, controller, custody_address, record_value, rep_policy,
  representative_name, self_ref, source_record, spend_redeemer_data, state_input,
  tx,
}
use naming.{NamingDatum}
use representative.{BurnRepresentative, MintRepresentative}

fn canonical_registry() -> ByteArray {
  bytearray.concat(naming.mpfs_state_hash, fixtures.mock_registry_token)
}

// The application spend whose redeemer authorizes the representative
// movement: a claim at the application address.
fn app_spend_tx(mint, app_redeemer: Data) {
  tx(
    [claim_input(NamingDatum(source_record()), record_value), state_input()],
    [],
    [],
    mint,
    spend_redeemer_data(app_redeemer),
  )
}

fn mint_one() {
  add(zero, rep_policy, representative_name, 1)
}

fn burn_one() {
  add(zero, rep_policy, representative_name, -1)
}

/// A fold mints the named representative exactly once.
test fold_mints_named_representative_accepts() {
  representative.representative.mint(
    app_policy,
    canonical_registry(),
    MintRepresentative,
    rep_policy,
    app_spend_tx(mint_one(), Fold { representatives: [representative_name] }),
  )
}

/// Negation: no application spend, no mint.
test mint_without_application_spend_refuses() fail {
  representative.representative.mint(
    app_policy,
    canonical_registry(),
    MintRepresentative,
    rep_policy,
    tx([state_input()], [], [], mint_one(), []),
  )
}

/// Negation: the application spend's redeemer must be the fold — a
/// cancel or maintain riding the same transaction authorizes nothing.
test mint_authorized_by_cancel_redeemer_refuses() fail {
  representative.representative.mint(
    app_policy,
    canonical_registry(),
    MintRepresentative,
    rep_policy,
    app_spend_tx(
      mint_one(),
      Cancel {
        presented_refund: #"61a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbc",
      },
    ),
  )
}

/// Negation: a representative minted beyond the named set refuses.
test mint_unbound_name_refuses() fail {
  let extra = add(mint_one(), rep_policy, #"ffff", 1)
  representative.representative.mint(
    app_policy,
    canonical_registry(),
    MintRepresentative,
    rep_policy,
    app_spend_tx(extra, Fold { representatives: [representative_name] }),
  )
}

/// Negation: a named representative that never mints refuses.
test mint_missing_name_refuses() fail {
  representative.representative.mint(
    app_policy,
    canonical_registry(),
    MintRepresentative,
    rep_policy,
    app_spend_tx(
      add(zero, rep_policy, #"ffff", 1),
      Fold { representatives: [representative_name] },
    ),
  )
}

/// Negation: the fold mints exactly one of each name.
test mint_wrong_quantity_refuses() fail {
  let double = add(mint_one(), rep_policy, representative_name, 1)
  representative.representative.mint(
    app_policy,
    canonical_registry(),
    MintRepresentative,
    rep_policy,
    app_spend_tx(double, Fold { representatives: [representative_name] }),
  )
}

/// A retire burns the named representative exactly once.
test retire_burns_named_representative_accepts() {
  representative.representative.mint(
    app_policy,
    canonical_registry(),
    BurnRepresentative,
    rep_policy,
    app_spend_tx(
      burn_one(),
      Retire { representatives: [representative_name], key: "alice" },
    ),
  )
}

/// Negation: a retire that fails to burn refuses.
test retire_without_burn_refuses() fail {
  representative.representative.mint(
    app_policy,
    canonical_registry(),
    BurnRepresentative,
    rep_policy,
    app_spend_tx(
      zero,
      Retire { representatives: [representative_name], key: "alice" },
    ),
  )
}

/// Negation: burning must be exact — a spurious extra burn under the
/// representative policy refuses.
test burn_unbound_name_refuses() fail {
  let extra = add(burn_one(), rep_policy, #"ffff", -1)
  representative.representative.mint(
    app_policy,
    canonical_registry(),
    BurnRepresentative,
    rep_policy,
    app_spend_tx(
      extra,
      Retire { representatives: [representative_name], key: "alice" },
    ),
  )
}

/// The custody-held representative: what a genuine `Retire` placed at
/// the completion-only script (matches `application
/// .retirement_custody_hash` via `fixtures.custody_address`).
fn custody_input(value) {
  Input {
    output_reference: self_ref,
    output: Output {
      address: custody_address,
      value,
      datum: NoDatum,
      reference_script: None,
    },
  }
}

fn custody_held_value() {
  add(zero, rep_policy, representative_name, 1)
}

/// Completion burns the custody-held representative exactly once with
/// no application spend in the transaction (issue #74: permissionless
/// completion) — riding a genuine registry transition (NOTE-028: the
/// spent state input).
test completion_burn_rides_custody_accepts() {
  representative.representative.mint(
    app_policy,
    canonical_registry(),
    BurnRepresentative,
    rep_policy,
    tx(
      [custody_input(custody_held_value()), state_input()],
      [],
      [],
      burn_one(),
      [],
    ),
  )
}

/// Negation (NOTE-028): a custody-carried burn with no registry state
/// input refuses — the burn must ride a transition, never a standalone
/// custody spend.
test completion_burn_without_registry_transition_refuses() fail {
  representative.representative.mint(
    app_policy,
    canonical_registry(),
    BurnRepresentative,
    rep_policy,
    tx([custody_input(custody_held_value())], [], [], burn_one(), []),
  )
}

/// Negation: a burn with neither a naming `Retire` spend nor a custody
/// carrier refuses.
test completion_burn_without_carrier_refuses() fail {
  representative.representative.mint(
    app_policy,
    canonical_registry(),
    BurnRepresentative,
    rep_policy,
    tx([state_input()], [], [], burn_one(), []),
  )
}

/// Negation: the custody carrier must hold the burned asset — a burn
/// naming an asset custody does not hold refuses.
test completion_burn_wrong_custody_asset_refuses() fail {
  let wrong = add(zero, rep_policy, #"ffff", 1)
  representative.representative.mint(
    app_policy,
    canonical_registry(),
    BurnRepresentative,
    rep_policy,
    tx([custody_input(wrong), state_input()], [], [], burn_one(), []),
  )
}

/// Negation: the carrier is exactly one custody input — two custody
/// inputs carrying the burn refuse.
test completion_burn_two_custody_inputs_refuses() fail {
  representative.representative.mint(
    app_policy,
    canonical_registry(),
    BurnRepresentative,
    rep_policy,
    tx(
      [custody_input(custody_held_value()), custody_input(custody_held_value())],
      [],
      [],
      burn_one(),
      [],
    ),
  )
}

/// A policy scoped to the canonical registry cannot mint without that state.
test mint_without_registry_state_refuses() fail {
  representative.representative.mint(
    app_policy,
    canonical_registry(),
    MintRepresentative,
    rep_policy,
    tx(
      [claim_input(NamingDatum(source_record()), record_value)],
      [],
      [],
      mint_one(),
      spend_redeemer_data(Fold { representatives: [representative_name] }),
    ),
  )
}

/// The same state credential with a different registry token is not authority.
test completion_foreign_registry_refuses() fail {
  let canonical = state_input()
  let foreign =
    Input {
      ..canonical,
      output: Output {
        ..canonical.output,
        value: add(
          zero,
          naming.mpfs_state_hash,
          fixtures.foreign_registry_token,
          1,
        ),
      },
    }
  representative.representative.mint(
    app_policy,
    canonical_registry(),
    BurnRepresentative,
    rep_policy,
    tx([custody_input(custody_held_value()), foreign], [], [], burn_one(), []),
  )
}

/// The application and policy both select spent state before reference state.
/// A canonical reference cannot disguise a spend from a foreign registry.
test mint_foreign_spend_with_canonical_reference_refuses() fail {
  let canonical = state_input()
  let foreign =
    Input {
      ..canonical,
      output: Output {
        ..canonical.output,
        value: add(
          zero,
          naming.mpfs_state_hash,
          fixtures.foreign_registry_token,
          1,
        ),
      },
    }
  let base =
    app_spend_tx(mint_one(), Fold { representatives: [representative_name] })
  representative.representative.mint(
    app_policy,
    canonical_registry(),
    MintRepresentative,
    rep_policy,
    transaction.Transaction {
      ..base,
      inputs: [claim_input(NamingDatum(source_record()), record_value), foreign],
      reference_inputs: [canonical],
    },
  )
}

/// A reference to the canonical registry supplies the same binding.
test mint_canonical_reference_accepts() {
  let base =
    app_spend_tx(mint_one(), Fold { representatives: [representative_name] })
  representative.representative.mint(
    app_policy,
    canonical_registry(),
    MintRepresentative,
    rep_policy,
    transaction.Transaction {
      ..base,
      inputs: [claim_input(NamingDatum(source_record()), record_value)],
      reference_inputs: [state_input()],
    },
  )
}

test withdraw_canonical_registry_accepts() {
  representative.representative.withdraw(
    app_policy, canonical_registry(), #"", address.Script(rep_policy),
    fixtures.with_state_reference(tx([], [], [], zero, []), state_input()),
  )
}

test withdraw_without_registry_reference_refuses() fail {
  representative.representative.withdraw(
    app_policy, canonical_registry(), #"", address.Script(rep_policy),
    tx([state_input()], [], [], zero, []),
  )
}
