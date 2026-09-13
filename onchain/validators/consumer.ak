use aiken/collection/list.{any, filter_map, has}
use aiken/crypto.{blake2b_224}
use aiken/primitive/bytearray
use cardano/address
use cardano/assets.{PolicyId, flatten, lovelace_of}
use cardano/transaction.{InlineDatum, Input, Transaction}

/// The scoped exhibit consumer, v2 (NOTE-021): evidence-derived
/// obligations, no appointed operator, no caller-supplied payout list.
///
/// The consumer authenticates every `Modify` batch from the
/// transaction's own evidence — never from a declaration:
///
/// R1 — request value coverage: every spent MPFS request addressed to
/// this cage's token carries lovelace at least its datum-stated tip.
/// Builder convention locks tip-plus-buffer into every request; the
/// cage never checks carriage, so costless fabricated requests would
/// fold for free (trie spam at zero price). Anyone's funded request
/// passes; permissionless, no keys.
///
/// R2 — representative-mint binding: every positive mint under the
/// registry's representative policy must be (i) requested — some
/// consumed request commits it as an `Insert` value — and (ii)
/// correctly bound — it equals the registry-bound recomputation over
/// the spent state's own token and some spent claim's control. A folder
/// that consumes a victim's paid request but mints its own
/// representative (request theft) refuses; coherent batches pass no
/// matter who submits them.
///
/// What it is not: not allocation policy (processed value routes
/// wherever conservation puts it — epic 18 owns checkpoint/Mr/tip
/// semantics); not a naming re-verdict (claim validity stays the
/// naming validator's job); not KERI (no key-event verification
/// anywhere in naming).
///
/// Mirrors below duplicate the MPFS `State`/`Request` and naming
/// `NamingEnvelope` shapes field-for-field (cross-partition imports
/// are impossible; the MPFS mirrors are drift-guarded by unit tests
/// decoding REAL validator types in `consumer.tests.ak`, the naming
/// mirror by hand-encoded envelope vectors plus devnet agreement —
/// any drift refuses honest batches LOUDLY on ledger).

pub type ConsumerRedeemer {
  Hook
}

// ---- MPFS mirrors (onchain/validators/types.ak) ----

pub type CTokenId {
  CTokenId { assetName: ByteArray }
}

pub type COperation {
  CInsert(ByteArray)
  CDelete(ByteArray)
  CUpdate(ByteArray, ByteArray)
}

pub type CRequest {
  CRequest {
    requestToken: CTokenId,
    requestOwner: ByteArray,
    requestKey: ByteArray,
    requestValue: COperation,
    tip: Int,
    submitted_at: Int,
  }
}

pub type CState {
  CState {
    root: ByteArray,
    tip: Int,
    process_time: Int,
    retract_time: Int,
    representative_policy: PolicyId,
    consumer_pin: ByteArray,
  }
}

pub type CCageDatum {
  CRequestDatum(CRequest)
  CStateDatum(CState)
}

// ---- Naming mirrors (naming-onchain/validators/naming.ak) ----

pub type CQuorum {
  CQuorum { threshold: Int, members: List<ByteArray> }
}

pub type CDestination {
  CNoDestination
  CSomeDestination(ByteArray)
}

pub type CNamingRecord {
  CNamingRecord {
    control_address: ByteArray,
    payment_destination: CDestination,
    next_control_commitment: ByteArray,
    retirement_quorum: CQuorum,
  }
}

pub type CNamingEnvelope {
  CNamingEnvelope(CNamingRecord)
}

/// What the contract's `decodeAddress` recovers: the payment
/// credential kind and the 28-byte payment key hash. Transcribed
/// identically from naming-onchain/validators/naming.ak (the package
/// fence blocks import): header kinds 6-7 are enterprise (header +
/// 28-byte hash), kinds 0-3 are base (header + 28-byte payment hash +
/// 28-byte stake hash); everything else refuses. Any network nibble
/// accepted, exactly as the codec does.
pub type CAddressShape {
  CAddressShape { payment_key: Bool, payment_hash: ByteArray }
}

pub fn c_decode_address(bytes: ByteArray) -> Option<CAddressShape> {
  let n = bytearray.length(bytes)
  if n < 1 {
    None
  } else {
    let header = bytearray.at(bytes, 0)
    let kind = header / 16
    if (kind == 6 || kind == 7) && n == 29 {
      Some(CAddressShape {
        payment_key: kind == 6,
        payment_hash: bytearray.slice(bytes, 1, 28),
      })
    } else if kind < 4 && n == 57 {
      Some(CAddressShape {
        payment_key: kind == 0 || kind == 2,
        payment_hash: bytearray.slice(bytes, 1, 28),
      })
    } else {
      None
    }
  }
}

validator consumer() {
  withdraw(_redeemer: ConsumerRedeemer, _credential, tx: Transaction) {
    expect check_requests(tx)
    expect check_rep_mints(tx)
    True
  }

  else(_) {
    fail
  }
}

// ---- Evidence readers ----

/// Inline datum bytes of an input, if any.
fn datum_data(input: Input) -> Option<Data> {
  when input.output.datum is {
    InlineDatum(d) -> Some(d)
    _ -> None
  }
}

/// Try-decode an input's datum as an MPFS cage datum (total: `None`
/// for anything else — claims, lovelace-only inputs, foreign shapes).
fn decode_cage(input: Input) -> Option<CCageDatum> {
  when datum_data(input) is {
    Some(d) ->
      if d is CRequestDatum(request): CCageDatum {
        Some(CRequestDatum(request))
      } else if d is CStateDatum(state): CCageDatum {
        Some(CStateDatum(state))
      } else {
        None
      }
    None -> None
  }
}

/// Try-decode an input's datum as a naming envelope (total).
fn decode_naming(input: Input) -> Option<CNamingRecord> {
  when datum_data(input) is {
    Some(d) ->
      if d is CNamingEnvelope(record): CNamingEnvelope {
        Some(record)
      } else {
        None
      }
    None -> None
  }
}

/// Spent registry states: inputs decoding as `StateDatum`, each with
/// its script hash (the state policy bytes — read from the address the
/// state lives at, never from a parameter).
fn spent_states(tx: Transaction) -> List<(Input, CState)> {
  let states =
    list.filter_map(
      tx.inputs,
      fn(input) {
        when decode_cage(input) is {
          Some(CStateDatum(state)) -> Some((input, state))
          _ -> None
        }
      },
    )
  states
}

/// The state script hash an input lives at (fail-closed: states always
/// live at their own script address).
fn state_policy_bytes(input: Input) -> ByteArray {
  when input.output.address.payment_credential is {
    address.Script(hash) -> hash
    _ -> fail
  }
}

/// The cage NFT asset name in a state input's value: exactly one
/// non-ADA asset (the cage enforces the same via `exactQuantity`, so
/// this never fires honestly — defense in depth, not a new rule).
fn cage_token_name(input: Input) -> ByteArray {
  let assets =
    list.filter(
      flatten(input.output.value),
      fn(t) {
        when t is {
          (policy, _, _) -> policy != ""
        }
      },
    )
  expect [(_, name, _)] = assets
  name
}

// ---- R1: request value coverage ----

/// Every spent request addressed to this cage's token carries at least
/// its stated tip. Requests for other cages (different token name) are
/// out of scope — their own cage's consumer governs them.
fn check_requests(tx: Transaction) -> Bool {
  let states = spent_states(tx)
  expect states != []
  list.all(
    states,
    fn(s) {
      when s is {
        (input, _) -> {
          let token_name = cage_token_name(input)
          list.all(
            tx.inputs,
            fn(candidate) {
              when decode_cage(candidate) is {
                Some(CRequestDatum(request)) ->
                  if request.requestToken.assetName == token_name {
                    lovelace_of(candidate.output.value) >= request.tip
                  } else {
                    True
                  }
                _ -> True
              }
            },
          )
        }
      }
    },
  )
}

// ---- R2: representative-mint binding ----

/// Registry-bound recomputation (NOTE-009 rule, duplicated from the
/// application validator — the two implementations cross-check on
/// devnet; the rule's authority is the operator-approved preimage, not
/// either copy).
pub fn consumer_representative_name(
  control_hash: ByteArray,
  state_policy_bytes: ByteArray,
  token_name: ByteArray,
) -> ByteArray {
  expect bytearray.length(control_hash) == 28
  bytearray.concat(
    bytearray.concat(
      #"526570",
      blake2b_224(
        bytearray.concat(
          consumer_registry_asset_id(state_policy_bytes, token_name),
          control_hash,
        ),
      ),
    ),
    #"00",
  )
}

pub fn consumer_registry_asset_id(
  state_policy_bytes: ByteArray,
  token_name: ByteArray,
) -> ByteArray {
  expect bytearray.length(state_policy_bytes) == 28
  bytearray.concat(state_policy_bytes, token_name)
}

/// Claim control as recompute input: the SAME supported address
/// forms, key-kind validation, and exact 28-byte payment-key
/// extraction as the authoritative codec (NOTE-022) — enterprise
/// 29-byte and base 57-byte payment-key addresses yield the identical
/// preimage hash; script credentials and malformed lengths refuse.
fn claim_control_hash(record: CNamingRecord) -> ByteArray {
  expect Some(shape) = c_decode_address(record.control_address)
  expect shape.payment_key
  shape.payment_hash
}

/// Insert-committed values across spent requests for this cage's token.
fn requested_names(
  tx: Transaction,
  token_name: ByteArray,
) -> List<ByteArray> {
  list.filter_map(
    tx.inputs,
    fn(candidate) {
      when decode_cage(candidate) is {
        Some(CRequestDatum(request)) ->
          if request.requestToken.assetName == token_name {
            when request.requestValue is {
              CInsert(value) -> Some(value)
              _ -> None
            }
          } else {
            None
          }
        _ -> None
      }
    },
  )
}

/// Spent claim/record controls pooled across the batch (existential
/// matching — no ordering assumptions between requests, claims, mints).
fn claim_controls(tx: Transaction) -> List<ByteArray> {
  list.filter_map(
    tx.inputs,
    fn(candidate) {
      when decode_naming(candidate) is {
        Some(record) -> Some(claim_control_hash(record))
        None -> None
      }
    },
  )
}

/// Every positive mint under this registry's representative policy is
/// requested and correctly bound. No mint under the policy: vacuous
/// (claim validity without mints stays the naming validator's job).
fn check_rep_mints(tx: Transaction) -> Bool {
  let states = spent_states(tx)
  expect states != []
  list.all(
    states,
    fn(s) {
      when s is {
        (input, state) -> {
          let policy_bytes = state_policy_bytes(input)
          let token_name = cage_token_name(input)
          let minted =
            list.filter_map(
              flatten(tx.mint),
              fn(t) {
                when t is {
                  (policy, name, quantity) ->
                    if policy == state.representative_policy && quantity > 0 {
                      Some(name)
                    } else {
                      None
                    }
                }
              },
            )
          list.all(
            minted,
            fn(rep) {
              expect has(requested_names(tx, token_name), rep)
              expect
                any(
                  claim_controls(tx),
                  fn(control) {
                    rep
                      == consumer_representative_name(
                        control,
                        policy_bytes,
                        token_name,
                      )
                  },
                )
              True
            },
          )
        }
      }
    },
  )
}
