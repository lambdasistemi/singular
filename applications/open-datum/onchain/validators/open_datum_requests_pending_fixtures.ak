//// Shared fixtures of the tests that spend a pending registration.
////
//// A perfect transaction is built for each of the three actions from the
//// registration alone; a row changes one fact of it and expects a refusal, and
//// every refusal row has the perfect transaction as its passing control.
//// Every token name and every deadline comes from the producer at run time:
//// the approval and the active token from `application/registration` and
//// `singular_state/preimage`, the deadlines from the registration the booking
//// fixtures build.

use aiken/collection/list
use aiken/interval.{Finite, Interval, IntervalBound}
use application/held.{RegistrationData, TokenId}
use application/phases.{
  Cleanup, Processing, Reclaim, Refused, RegistrationPhase,
}
use application/registration.{registration_asset}
use application/spend.{
  ExpiredCleanup, OwnerReclaim, RegistrationFold, SpendAction,
}
use cardano/address.{Address, from_verification_key}
use cardano/assets.{Value, add, from_asset, from_lovelace, merge}
use cardano/transaction.{
  Datum, InlineDatum, Input, NoDatum, Output, OutputReference, Spend,
  Transaction,
}
use open_datum_requests_fixtures.{
  active_asset_of, application_policy, keys, pending_output, range,
  registration_a, registration_of, registries, spent, wallet_address,
}

const pending_transaction: ByteArray =
  #"c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1"

const funding_transaction: ByteArray =
  #"f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2f2"

/// The reference of the `n`th pending registration spent by a transaction.
pub fn pending_reference_n(n: Int) -> OutputReference {
  OutputReference { transaction_id: pending_transaction, output_index: n }
}

/// The reference of the single pending registration of the one-spend
/// transactions.
pub fn pending_reference() -> OutputReference {
  pending_reference_n(0)
}

pub fn funding_reference() -> OutputReference {
  OutputReference { transaction_id: funding_transaction, output_index: 0 }
}

/// One spent pending registration and the action that spends it.
pub type Spending {
  reference: OutputReference,
  registration: RegistrationData,
  action: SpendAction,
}

pub fn pending_input(
  registration: RegistrationData,
  reference: OutputReference,
) -> Input {
  Input { output_reference: reference, output: pending_output(registration) }
}

/// The lovelace the request holds: the deposit and the rest the folder or the
/// cleaner may take.
pub fn request_lovelace(registration: RegistrationData) -> Int {
  assets.lovelace_of(pending_output(registration).value)
}

/// The surplus above the deposit.
pub fn surplus(registration: RegistrationData) -> Int {
  request_lovelace(registration) - registration.deposit
}

// ---------------------------------------------------------------------------
// Ranges
// ---------------------------------------------------------------------------

/// A range inside the processing phase, ending at the deadline.
pub fn processing_range(registration: RegistrationData) -> Interval<Int> {
  range(registration.process_deadline - 600_000, registration.process_deadline)
}

/// The whole reclaim window.
pub fn reclaim_range(registration: RegistrationData) -> Interval<Int> {
  range(registration.process_deadline, registration.reclaim_end)
}

/// A range inside the cleanup phase, starting at the end of the window.
pub fn cleanup_range(registration: RegistrationData) -> Interval<Int> {
  range(registration.reclaim_end, registration.reclaim_end + 600_000)
}

/// A range with the given lower bound included and upper bound excluded.
pub fn between(lower: Int, upper: Int) -> Interval<Int> {
  range(lower, upper)
}

/// A range whose bounds carry the flags given.
pub fn bounded(
  lower: Int,
  lower_included: Bool,
  upper: Int,
  upper_included: Bool,
) -> Interval<Int> {
  Interval {
    lower_bound: IntervalBound {
      bound_type: Finite(lower),
      is_inclusive: lower_included,
    },
    upper_bound: IntervalBound {
      bound_type: Finite(upper),
      is_inclusive: upper_included,
    },
  }
}

/// What a validity range is measured from.
pub type Anchor {
  Epoch
  ProcessingDeadline
  ReclaimEnd
}

/// A validity range described by distances from the deadlines of a
/// registration, with the phase the model classifies it in. The table is the
/// model's `classifyPhase` written out case by case, not computed.
pub type Case {
  lower_anchor: Anchor,
  lower_offset: Int,
  upper_anchor: Anchor,
  upper_offset: Int,
  expected: RegistrationPhase,
}

fn at(registration: RegistrationData, anchor: Anchor, offset: Int) -> Int {
  let base =
    when anchor is {
      Epoch -> 0
      ProcessingDeadline -> registration.process_deadline
      ReclaimEnd -> registration.reclaim_end
    }
  base + offset
}

/// The lower and upper instants of a case for a registration.
pub fn case_range(registration: RegistrationData, case: Case) -> Interval<Int> {
  range(
    at(registration, case.lower_anchor, case.lower_offset),
    at(registration, case.upper_anchor, case.upper_offset),
  )
}

/// The table of ranges around the two deadlines. A range is in a phase when it
/// lies wholly inside it; a range that crosses a deadline, or is empty, is in
/// none.
pub fn cases() -> List<Case> {
  [
    // Processing: the range ends at or before the deadline.
    Case(ProcessingDeadline, -600_000, ProcessingDeadline, 0, Processing),
    Case(ProcessingDeadline, -600_000, ProcessingDeadline, -1, Processing),
    Case(ProcessingDeadline, -2, ProcessingDeadline, -1, Processing),
    Case(Epoch, 0, Epoch, 1, Processing),
    // Straddling the processing deadline.
    Case(ProcessingDeadline, -1, ProcessingDeadline, 1, Refused),
    Case(ProcessingDeadline, -600_000, ProcessingDeadline, 1, Refused),
    Case(ProcessingDeadline, -1, ReclaimEnd, 0, Refused),
    // Reclaim: the range lies inside the window.
    Case(ProcessingDeadline, 0, ProcessingDeadline, 1, Reclaim),
    Case(ProcessingDeadline, 0, ReclaimEnd, 0, Reclaim),
    Case(ProcessingDeadline, 1, ReclaimEnd, -1, Reclaim),
    Case(ReclaimEnd, -2, ReclaimEnd, 0, Reclaim),
    // Straddling the end of the window.
    Case(ProcessingDeadline, 0, ReclaimEnd, 1, Refused),
    Case(ReclaimEnd, -1, ReclaimEnd, 1, Refused),
    Case(ProcessingDeadline, 1, ReclaimEnd, 1, Refused),
    Case(ProcessingDeadline, -1, ReclaimEnd, 1, Refused),
    // Cleanup: the range starts at or after the end of the window.
    Case(ReclaimEnd, 0, ReclaimEnd, 1, Cleanup),
    Case(ReclaimEnd, 0, ReclaimEnd, 600_000, Cleanup),
    Case(ReclaimEnd, 5, ReclaimEnd, 9, Cleanup),
    Case(ReclaimEnd, 1_000_000, ReclaimEnd, 2_000_000, Cleanup),
    // Empty and reversed ranges are in no phase, wherever they sit.
    Case(ProcessingDeadline, -5, ProcessingDeadline, -5, Refused),
    Case(ProcessingDeadline, 5, ProcessingDeadline, 5, Refused),
    Case(ReclaimEnd, 0, ReclaimEnd, 0, Refused),
    Case(ReclaimEnd, 7, ReclaimEnd, 7, Refused),
    Case(ProcessingDeadline, 9, ProcessingDeadline, 1, Refused),
    Case(ReclaimEnd, 9, ReclaimEnd, 1, Refused),
    Case(Epoch, 5, Epoch, 5, Refused),
  ]
}

// ---------------------------------------------------------------------------
// Values and outputs
// ---------------------------------------------------------------------------

/// The approval a registration is spent with.
pub fn approval_of(registration: RegistrationData) -> TokenId {
  registration_asset(application_policy, registration)
}

/// The genuine active token of a registration.
pub fn active_of(registration: RegistrationData) -> TokenId {
  active_asset_of(registration.registry, registration.key)
}

/// A mint that burns the approval of each registration once.
pub fn burn_of(registrations: List<RegistrationData>) -> Value {
  list.foldr(
    registrations,
    assets.zero,
    fn(registration, mint) {
      let approval = approval_of(registration)
      merge(mint, from_asset(approval.policy, approval.name, -1))
    },
  )
}

/// A mint that creates the active token of each registration once.
pub fn active_mint_of(registrations: List<RegistrationData>) -> Value {
  list.foldr(
    registrations,
    assets.zero,
    fn(registration, mint) {
      let active = active_of(registration)
      merge(mint, from_asset(active.policy, active.name, 1))
    },
  )
}

/// The holding a fold delivers: the committed address, the committed datum,
/// exactly the deposit in lovelace and the genuine active token.
pub fn holding_of(registration: RegistrationData) -> Output {
  let active = active_of(registration)
  Output {
    address: registration.holding_address,
    value: from_lovelace(registration.deposit)
      |> add(active.policy, active.name, 1),
    datum: InlineDatum(registration.initial_datum),
    reference_script: None,
  }
}

/// An output of `amount` lovelace to `address` with no datum.
pub fn payment_to(address: Address, amount: Int) -> Output {
  Output {
    address,
    value: from_lovelace(amount),
    datum: NoDatum,
    reference_script: None,
  }
}

/// The ordinary change the folder or the cleaner collects.
pub fn change(amount: Int) -> Output {
  payment_to(wallet_address(), amount)
}

/// The refund address the fixture registrations commit.
pub fn refund_address_of(registration: RegistrationData) -> Address {
  registration.refund_address
}

/// Another wallet address, unrelated to any fixture registration.
pub fn stranger() -> Address {
  from_verification_key(
    #"0909090909090909090909090909090909090909090909090909090909",
  )
}

// ---------------------------------------------------------------------------
// Transactions
// ---------------------------------------------------------------------------

/// A transaction that spends each pending registration of `spendings` by its
/// action, with the redeemers the ledger would list for them.
pub fn transaction_of(
  spendings: List<Spending>,
  outputs: List<Output>,
  mint: Value,
  validity: Interval<Int>,
  signers: List<ByteArray>,
) -> Transaction {
  Transaction {
    ..transaction.placeholder,
    inputs: [
      spent(funding_reference()),
      ..list.map(
        spendings,
        fn(spending) {
          pending_input(spending.registration, spending.reference)
        },
      )
    ],
    outputs,
    mint,
    validity_range: validity,
    extra_signatories: signers,
    redeemers: list.map(
      spendings,
      fn(spending) {
        let redeemer: Data = spending.action
        Pair(Spend(spending.reference), redeemer)
      },
    ),
  }
}

pub fn fold_action() -> SpendAction {
  RegistrationFold { holding_index: 0 }
}

/// The transaction that folds `registration` before its deadline: the holding
/// at output 0, the folder keeping the rest.
pub fn fold_transaction(registration: RegistrationData) -> Transaction {
  transaction_of(
    [Spending(pending_reference(), registration, fold_action())],
    [holding_of(registration), change(surplus(registration))],
    merge(burn_of([registration]), active_mint_of([registration])),
    processing_range(registration),
    [],
  )
}

/// The transaction that reclaims `registration` inside its window: everything
/// returns to the refund address, which signs.
pub fn reclaim_transaction(registration: RegistrationData) -> Transaction {
  transaction_of(
    [Spending(pending_reference(), registration, OwnerReclaim)],
    [payment_to(registration.refund_address, request_lovelace(registration))],
    burn_of([registration]),
    reclaim_range(registration),
    [refund_signer(registration)],
  )
}

/// The transaction that cleans `registration` up after its window: the deposit
/// goes to the refund address and the cleaner keeps the rest.
pub fn cleanup_transaction(registration: RegistrationData) -> Transaction {
  transaction_of(
    [Spending(pending_reference(), registration, ExpiredCleanup)],
    [
      payment_to(registration.refund_address, registration.deposit),
      change(surplus(registration)),
    ],
    burn_of([registration]),
    cleanup_range(registration),
    [],
  )
}

/// The verification key hash of the refund address of a registration whose
/// refund address is a key.
pub fn refund_signer(registration: RegistrationData) -> ByteArray {
  let refund = registration.refund_address
  when refund.payment_credential is {
    address.VerificationKey(hash) -> hash
    address.Script(hash) -> hash
  }
}

// ---------------------------------------------------------------------------
// Variants
// ---------------------------------------------------------------------------

/// The same registration booked at three times, with three window lengths.
pub fn registrations_over_time() -> List<RegistrationData> {
  let base = registration_a()
  [
    base,
    RegistrationData {
      ..base,
      booked_at: 5_000,
      process_deadline: 3_005_000,
      reclaim_end: 3_005_010,
    },
    RegistrationData {
      ..base,
      booked_at: 1_800_000_000_000,
      process_deadline: 1_800_000_001_000,
      reclaim_end: 1_800_086_401_000,
    },
  ]
}

/// Every registration of every key in every registry the fixtures know.
pub fn registrations() -> List<RegistrationData> {
  list.flat_map(
    registries(),
    fn(registry) { list.map(keys, fn(key) { registration_of(registry, key) }) },
  )
}

/// The transaction with the output the pending registration is spent from
/// replaced.
pub fn with_pending_output(tx: Transaction, output: Output) -> Transaction {
  Transaction {
    ..tx,
    inputs: list.map(
      tx.inputs,
      fn(input) {
        if input.output_reference == pending_reference() {
          Input { ..input, output }
        } else {
          input
        }
      },
    ),
  }
}

/// The pending output of `registration` with its datum replaced.
pub fn pending_with_datum(
  registration: RegistrationData,
  datum: Datum,
) -> Output {
  Output { ..pending_output(registration), datum }
}

/// The pending output of `registration` with its value replaced.
pub fn pending_with_value(
  registration: RegistrationData,
  value: Value,
) -> Output {
  Output { ..pending_output(registration), value }
}
