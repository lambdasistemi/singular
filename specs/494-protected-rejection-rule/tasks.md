# Tasks: protected rejection in the Lean model

Tasks are grouped by slice and named by what they achieve. A task is checked only by the ticket
owner, after the slice is accepted, in the commit that stamps the slice. Each task names the
requirements of the [specification](spec.md) it serves. The [gate](gate.md) is the proof; no task
adds a check of its own.

## Story

As the coder given a slice, I read the tasks of that slice as the whole of my work and the
terminal condition at its end as the only reason to stop, so that I neither stop early nor wander
into a neighbouring ticket.

## Slice one: one booked clock

- [x] `booked-time-on-request` — a request records its booked submission time, serialized, zero
  when absent from older input. (one-booked-clock)
- [x] `window-reads-booked-time` — the retraction window, its admission and the restated window
  statements read the request's time and ignore the witness's legacy field. (one-booked-clock)
- [x] `retract-question-carries-booked-time` — the transport and the harness give a retraction
  question the booked time read from the request datum; a fold question is unchanged.
  (one-booked-clock, admission-changes-no-effect)
- [x] `protocol-seven` — the driver's protocol version moves to 7 and the surface digest pin follows.
  (consumers-state-the-rule)
- [x] `regenerate-after-slice-one` — corpora, theorem register and digests, simulator mirror,
  application corpus and the coverage record are regenerated from the model, with a published
  restatement table for every changed identity. (consumers-state-the-rule, unmet-stays-unmet)
- [x] `amendment-opened` — constitution version 1.16.0 is opened with the retraction row restated.
  (consumers-state-the-rule)

Terminal condition: every command of slice one's gate exits as the gate states, on a clean
committed head; or a question is filed; or capacity is reached with a handoff.

## Slice two: rejection needs evidence

- [x] `historical-scenario-accepted-on-base` — the unguarded-rejection scenario is ported to the
  base API and run against the base model before any change; it reports the rejection accepted.
  This is the failing control. (rejection-needs-evidence, foldable-request-is-protected)
- [x] `registry-identity` — a configuration and a request carry the abstract registry identity;
  every step preserves it. (evidence-is-bound)
- [x] `evidence-types` — reason, evidence and witness exist as the data model states them.
  (evidence-is-bound, two-grounds-only)
- [x] `rejection-admission` — admission refuses in the stated order and admits exactly the two
  grounds; the exit admission takes the state. (all requirements of rejection)
- [x] `rejection-statements` — the statements named in the functions model for this slice are stated
  and proved over the two-edge model. (every requirement named there)
- [x] `all-reject-batch-witnesses` — an all-reject batch carries one witness per request and one
  shared interval and judges each request in order. (batch-judged-action-by-action)
- [x] `rejection-corpus` — the corpus exports the truth table cell by cell for the two admitted
  edges, one row per excluded tag, the three time positions, each refusal reason, unknown against
  Absent, and the historical scenario. (consumers-state-the-rule)
- [x] `historical-scenario-refused-after` — the same scenario against the changed model reports the
  rejection refused. (foldable-request-is-protected)
- [x] `transport-decodes-evidence` — a rejection question without its booked metadata is refused at
  decode; evidence attached to another exit is refused. (evidence-is-bound)
- [x] `harness-supplies-evidence` — the harness allocates the registry identity while acting, reads
  the booked time from the request datum, and builds expiry and mismatch evidence.
  (evidence-is-bound)
- [x] `lawful-rows-rebased` — the running book, the refund controls, the generic rows and the batch
  harness place their rejects after both windows with expiry evidence. (unmet-stays-unmet)
- [x] `regenerate-after-slice-two` — as slice one's regeneration. (consumers-state-the-rule)
- [x] `amendment-reject-row` — the rejection row, the outcome-class row and the reconciliation are
  restated. (consumers-state-the-rule)

Terminal condition as slice one. The in-window row is expected red at this head and is slice three.

## Slice three: the in-window rows

- [x] `in-window-rows-per-ruling` — the dedicated early-rejection row and the generic session's standing
  unmet row, with their workflow assertions, say what decision B directs: the dedicated row becomes
  a lawful mismatch rejection that both sides accept inside the windows; the unmet row books a
  foldable `insertActive` request for a key not yet registered and records its three steps as the
  divergences they now are, so that it stops matching the day the chain refuses.
  (unmet-stays-unmet)
- [x] `consumer-record-updated` — the consumer conformance record, the book and the evidence page
  say the same, including the history of ticket 320's early rejection, without editing the history
  itself. (unmet-stays-unmet)

Terminal condition as slice one. The slice follows decision B and is independent of slice four.

## Slice four: mixed batches

Withdrawn on 14 October 2026, with the economic design: a rejection never spends the registry state output and never shares a transaction with a fold, so no batch holds both. Its tasks stay unchecked and are not done; the protection of a fold against a rejection ordered before it is statement 3 of the [economics plan](economics-plan.md), carried by slice eight.

- [ ] `action-engine` — the ordered action engine exists and the all-reject batch runs on it, the
  slice-two loop deleted in the same change. (batch-judged-action-by-action)
- [ ] `mixed-batch` — the mixed-batch function refuses an empty batch, an empty interval and a
  net-mint mismatch. (batch-judged-action-by-action)
- [ ] `batch-statements` — the batch statements named in the functions model are stated and proved.
  (batch-judged-action-by-action, foldable-request-is-protected)
- [ ] `mixed-batch-question` — the driver's mixed-batch question, its corpus rows (fold then reject
  of the same fresh key accepted, the reverse refused, an empty batch refused) and the transport
  support. (consumers-state-the-rule)
- [ ] `regenerate-after-slice-four` — as slice one's regeneration. (consumers-state-the-rule)
- [ ] `amendment-completed` — the mixed-batch row is added and the 1.16.0 entry is complete.
  (consumers-state-the-rule)

Terminal condition as slice one.

## Slices five to ten: the economic model

Planned in the [economics plan](economics-plan.md) on the decided [design](economics-design.md); started after the plan is cleared; run in place of the withdrawn slice four, by the
operator's order of 13 October 2026. The paper is not a slice of this list: it is written afterwards, from the finished model. Every slice begins with its failing
controls and ends with the list of its statements, each with its fully qualified name and its axiom line.

### Slice five: parameters and the transaction vocabulary

- [ ] `failing-controls-five` — a fold that changes a parameter, a reference to a spent output and an unbalanced transaction fail on the branch as it stands, for the intended reason.
- [ ] `registry-parameters` — the registration cost, minimum tip and maximum booking width exist in the configuration, default to zero in old input and are preserved by every fold; the width is below the processing window.
- [ ] `transaction-vocabulary` — output references and the unspent set, reference inputs, the validity interval, the fee and the donation (a zero donation omitted), the exact state token identity and the balance relation exist.
- [ ] `statements-five` — statement 1 and the supporting statements of the plan are proved from the standard axioms.
- [ ] `protocol-eight` — the driver protocol version moves where a declared question changed and the surface digest follows.
- [ ] `regenerate-after-slice-five` — corpora, register and digests, theorem page, simulator mirror, application corpus, coverage record and restatement table follow. (consumers-state-the-rule)
- [ ] `names-and-receipts-five` — the slice's statements are listed with fully qualified name and axiom line at the final revision.

### Slice six: registrations

- [ ] `failing-controls-six` — a dirty request, hidden surplus, a forged syntax tag, a backdated booking and a booking wider than the maximum fail on the branch as it stands.
- [ ] `registration-request-and-pool` — the registration request, the exact-contents rule, the pending pool and the world exist.
- [ ] `registration-booking` — a booking is admitted only inside an interval no wider than the maximum, with the booked time its upper end and the syntax tag minted once.
- [ ] `statements-six` — the four supporting statements of slice six are proved.
- [ ] `regenerate-after-slice-six` — as slice five. (consumers-state-the-rule)
- [ ] `names-and-receipts-six` — as slice five.

### Slice seven: terminations

- [ ] `failing-controls-seven` — a forged singular tag or application tag, a second pending termination and a token not in custody fail on the branch as it stands.
- [ ] `termination-request-and-booking` — the termination request and its booking exist; the token moves from custody into the request.
- [ ] `supply-counts-pending-requests` — the supply laws count tokens held by pending requests.
- [ ] `statements-seven` — statement 9 and the two supporting statements are proved.
- [ ] `regenerate-after-slice-seven` — as slice five. (consumers-state-the-rule)
- [ ] `names-and-receipts-seven` — as slice five.

### Slice eight: rejection reads the state

- [ ] `failing-controls-eight` — the old state-spending path, a fake, foreign or stale state, an overlapping state spend, a live member in a batch and a repeated input fail or are refused wrongly on the branch as it stands.
- [ ] `rejection-reads-the-state` — the accepted rejection judgement exists over a transaction, the rejection arm leaves the fold, and slices two and three are restated on it.
- [ ] `statements-eight` — statements 2, 3, 4, 5 and 8 and the supporting statement are proved.
- [ ] `regenerate-after-slice-eight` — as slice five. (consumers-state-the-rule)
- [ ] `names-and-receipts-eight` — as slice five.

### Slice nine: refunds

- [ ] `failing-controls-nine` — a reused refund and a refund short of held minus tip fail on the branch as it stands.
- [ ] `refund-obligations` — rejection and retraction owe what the plan states, summed per refund address, and the registration cost comes back.
- [ ] `statements-nine` — statement 6, the second half of statement 7 and the supporting statement are proved.
- [ ] `regenerate-after-slice-nine` — as slice five. (consumers-state-the-rule)
- [ ] `names-and-receipts-nine` — as slice five.

### Slice ten: folds

- [ ] `failing-controls-ten` — a termination stranded by a fold-time check, one donation counted for many keys, a forged application tag and an unbalanced fold fail on the branch as it stands.
- [ ] `fold-obligations` — a registration folds inside its window and routes the cost, tip and carrier; a termination folds at any later time, burns the token and the application tag and donates held minus tip.
- [ ] `statements-ten` — statements 7 (first half), 10, 11 and 12 and the supporting statement are proved.
- [ ] `amendment-economics` — the 1.16.0 entry of the constitution states the economic rows in the translation (one release, one entry).
- [ ] `regenerate-after-slice-ten` — as slice five. (consumers-state-the-rule)
- [ ] `names-and-receipts-ten` — as slice five, and the full list of the thirteen statements with their status.

## Closing the ticket

- [ ] `release-record` — the contract's release record is filled with the model revision, statement
  digests, corpus rows, constitution version and remaining limits. (consumers-state-the-rule)
- [ ] `pull-request-body` — the body states the story, the exact model revision, the mapping from
  requirement to statement to check, and the limits: no validator, no builder, no live acceptance.
  (unmet-stays-unmet)
