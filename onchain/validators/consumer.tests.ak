use aiken/builtin
use aiken/crypto.{blake2b_224}
use aiken/interval
use aiken/primitive/bytearray
use cardano/address.{Script, from_script}
use cardano/assets.{Value, from_asset, from_lovelace, merge, zero}
use cardano/transaction.{InlineDatum, Input, Output, OutputReference, Transaction}
use consumer.{Hook}
use lib.{TokenId}
use types.{
  CageDatum, Insert, Request, RequestDatum, State, StateDatum,
}

// ============================================================================
// Fixtures (MPFS side uses the REAL validator types — mirror drift
// refuses here, not on ledger)
// ============================================================================

const cage_token = TokenId { assetName: "cage_token" }

const state_policy_hash = "state_policy____________1234"

const rep_policy_hash = "rep_policy______________1234"

const consumer_pin_hash = "consumer_pin____________1234"

const test_state =
  State {
    root: #"00",
    tip: 500_000,
    process_time: 10_000,
    retract_time: 10_000,
    representative_policy: rep_policy_hash,
    consumer_pin: consumer_pin_hash,
  }

const state_value =
  from_lovelace(3_000_000)
    |> merge(from_asset(state_policy_hash, "cage_token", 1))

const state_input =
  Input {
    output_reference: OutputReference {
      transaction_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      output_index: 0,
    },
    output: Output {
      address: from_script(state_policy_hash),
      value: state_value,
      datum: InlineDatum(StateDatum(test_state)),
      reference_script: None,
    },
  }

fn funded_request(value: Int, tip: Int, op) -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      output_index: 0,
    },
    output: Output {
      address: from_script("request_policy"),
      value: from_lovelace(value),
      datum: InlineDatum(
        RequestDatum(
          Request {
            requestToken: cage_token,
            requestOwner: "requester_key",
            requestKey: "42",
            requestValue: op,
            tip: tip,
            submitted_at: 0,
          },
        ),
      ),
      reference_script: None,
    },
  }
}

// ---- Naming envelope, hand-encoded per contract (naming.ak shape):
// envelope Constr 0 [record]; record Constr 0 [control, destination,
// commitment, quorum]; NoDestination Constr 0 []; quorum Constr 0
// [threshold, members]. ----

fn envelope_data(control: ByteArray) -> Data {
  builtin.constr_data(
    0,
    [builtin.constr_data(
      0,
      [builtin.b_data(control),
       builtin.constr_data(0, []),
       builtin.b_data(#"cccccccccccccccccccccccccccccccc"),
       builtin.constr_data(
        0,
        [builtin.i_data(1),
         builtin.list_data([builtin.b_data(#"dddddddddddddddddddddddddddd")])],
      )],
    )],
  )
}

fn claim_input(control: ByteArray) -> Input {
  Input {
    output_reference: OutputReference {
      transaction_id: "cccccccccccccccccccccccccccccccc",
      output_index: 0,
    },
    output: Output {
      address: from_script("app_policy"),
      value: from_lovelace(2_000_000),
      datum: InlineDatum(envelope_data(control)),
      reference_script: None,
    },
  }
}

/// Independent recomputation per the NOTE-009 rule (stdlib primitives
/// directly — not via the consumer's copy — so the accept test pins
/// the rule, not the implementation).
fn expected_rep_name(control: ByteArray) -> ByteArray {
  bytearray.concat(
    bytearray.concat(
      #"526570",
      blake2b_224(
        bytearray.concat(
          bytearray.concat(state_policy_hash, "cage_token"),
          control,
        ),
      ),
    ),
    #"00",
  )
}

const control_a = #"60aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

const control_b = #"60bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

/// 57-byte base payment-key control (kind 0) with the SAME payment hash
/// as `control_a` plus a zero stake part (NOTE-022: both address forms
/// yield the identical 28-byte preimage hash).
const control_a_base = #"00aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa00000000000000000000000000000000000000000000000000000000"

/// 29-byte enterprise SCRIPT control (kind 7): decodes, but its payment
/// credential is not a key (NOTE-022: script controls refuse).
const control_script_ent = #"70aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

/// 57-byte base script control (kind 1: script payment part): refuses.
const control_script_base = #"10aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa00000000000000000000000000000000000000000000000000000000"

/// 30-byte malformed control: no supported form decodes it.
const control_bad_len = #"60aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa00"

fn consumer_tx(inputs: List<Input>, mint: Value) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    validity_range: interval.between(0, 5_000),
    outputs: [],
    extra_signatories: [],
    inputs: inputs,
    mint: mint,
  }
}

fn withdraw(tx: Transaction) -> Bool {
  consumer.consumer.withdraw(Hook, Script("stake_credential"), tx)
}

// ============================================================================
// R1: request value coverage
// ============================================================================

/// Honest funded request (2M carries the 0.5M tip): passes with no mint
/// and no naming evidence (pure-MPFS batch).
test r1_funded_request_accepts() {
  expect withdraw(
    consumer_tx([state_input, funded_request(2_000_000, 500_000, Insert("v"))], zero),
  )
  True
}

/// Costless fabrication (0.1M carries a 0.5M tip): refuses. The tip
/// mechanism is consensus-enforced here, not honor-system.
test r1_unfunded_request_refuses() fail {
  withdraw(
    consumer_tx([state_input, funded_request(100_000, 500_000, Insert("v"))], zero),
  )
}

/// Foreign-token request: out of scope (its own cage's consumer governs
/// it). A low-value foreign request does not trip this cage's rule.
test r1_foreign_token_skipped() {
  let foreign =
    Input {
      output_reference: OutputReference {
        transaction_id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        output_index: 1,
      },
      output: Output {
        address: from_script("request_policy"),
        value: from_lovelace(100_000),
        datum: InlineDatum(
          RequestDatum(
            Request {
              requestToken: TokenId { assetName: "other_token" },
              requestOwner: "requester_key",
              requestKey: "42",
              requestValue: Insert("v"),
              tip: 500_000,
              submitted_at: 0,
            },
          ),
        ),
        reference_script: None,
      },
    }
  expect withdraw(consumer_tx([state_input, foreign], zero))
  True
}

// ============================================================================
// R2: representative-mint binding
// ============================================================================

/// Coherent connected fold: the minted rep was requested (Insert value)
/// and equals the registry-bound recomputation over the spent state's
/// token and the spent claim's control. Passes no matter who submits
/// (no signatures anywhere in this transaction).
test r2_bound_requested_mint_accepts() {
  let rep = expected_rep_name(bytearray.drop(control_a, 1))
  let mint_value =
    from_asset(rep_policy_hash, rep, 1)
  expect withdraw(
    consumer_tx(
      [state_input,
       funded_request(2_000_000, 500_000, Insert(rep)),
       claim_input(control_a)],
      mint_value,
    ),
  )
  True
}

/// Request theft: the victim's paid request is consumed but a DIFFERENT
/// representative is minted (valid name, wrong request). Refuses even
/// though the minted name is correctly bound to its own control.
test r2_unrequested_mint_refuses() fail {
  let victim_rep = expected_rep_name(bytearray.drop(control_a, 1))
  let thief_rep = expected_rep_name(bytearray.drop(control_b, 1))
  let mint_value =
    from_asset(rep_policy_hash, thief_rep, 1)
  withdraw(
    consumer_tx(
      [state_input,
       funded_request(2_000_000, 500_000, Insert(victim_rep)),
       claim_input(control_b)],
      mint_value,
    ),
  )
}

/// Misbound mint: the minted name was requested but does not match the
/// registry recomputation over the spent claim's control (folded claim
/// and minted rep disagree). Refuses.
test r2_misbound_mint_refuses() fail {
  let requested = expected_rep_name(bytearray.drop(control_b, 1))
  let mint_value =
    from_asset(rep_policy_hash, requested, 1)
  withdraw(
    consumer_tx(
      [state_input,
       funded_request(2_000_000, 500_000, Insert(requested)),
       claim_input(control_a)],
      mint_value,
    ),
  )
}

// ============================================================================
// NOTE-022: the naming address codec — both forms, same preimage hash
// ============================================================================

/// Base payment-key control (kind 0, 57 bytes) carrying the SAME payment
/// hash as the enterprise `control_a`: the recomputed name is identical
/// and the coherent batch accepts. Representative preimage identity is
/// the 28-byte payment hash for both address forms.
test r2_base_address_same_hash_accepts() {
  let rep = expected_rep_name(bytearray.drop(control_a, 1))
  let mint_value =
    from_asset(rep_policy_hash, rep, 1)
  expect withdraw(
    consumer_tx(
      [state_input,
       funded_request(2_000_000, 500_000, Insert(rep)),
       claim_input(control_a_base)],
      mint_value,
    ),
  )
  True
}

/// Enterprise script control (kind 7, 29 bytes): decodes, but the payment
/// credential is not a key. Refuses — script credentials are never
/// control keys.
test r2_script_enterprise_control_refuses() fail {
  let rep = expected_rep_name(bytearray.drop(control_a, 1))
  let mint_value =
    from_asset(rep_policy_hash, rep, 1)
  withdraw(
    consumer_tx(
      [state_input,
       funded_request(2_000_000, 500_000, Insert(rep)),
       claim_input(control_script_ent)],
      mint_value,
    ),
  )
}

/// Base script control (kind 1, 57 bytes: script payment part): refuses
/// on the same key-kind rule as the enterprise script form.
test r2_script_base_control_refuses() fail {
  let rep = expected_rep_name(bytearray.drop(control_a, 1))
  let mint_value =
    from_asset(rep_policy_hash, rep, 1)
  withdraw(
    consumer_tx(
      [state_input,
       funded_request(2_000_000, 500_000, Insert(rep)),
       claim_input(control_script_base)],
      mint_value,
    ),
  )
}

/// Malformed control (30 bytes: no supported form decodes it): refuses.
test r2_malformed_control_refuses() fail {
  let rep = expected_rep_name(bytearray.drop(control_a, 1))
  let mint_value =
    from_asset(rep_policy_hash, rep, 1)
  withdraw(
    consumer_tx(
      [state_input,
       funded_request(2_000_000, 500_000, Insert(rep)),
       claim_input(control_bad_len)],
      mint_value,
    ),
  )
}
