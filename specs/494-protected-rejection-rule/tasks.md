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

- [ ] `in-window-rows-per-ruling` — the dedicated early-rejection row and the generic session's standing
  unmet row, with their workflow assertions, say what decision B directs: the dedicated row becomes
  a lawful mismatch rejection that both sides accept inside the windows; the unmet row books a
  foldable `insertActive` request for a key not yet registered and records its three steps as the
  divergences they now are, so that it stops matching the day the chain refuses.
  (unmet-stays-unmet)
- [ ] `consumer-record-updated` — the consumer conformance record, the book and the evidence page
  say the same, including the history of ticket 320's early rejection, without editing the history
  itself. (unmet-stays-unmet)

Terminal condition as slice one. The slice follows decision B and is independent of slice four.

## Slice four: mixed batches

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

## Closing the ticket

- [ ] `release-record` — the contract's release record is filled with the model revision, statement
  digests, corpus rows, constitution version and remaining limits. (consumers-state-the-rule)
- [ ] `pull-request-body` — the body states the story, the exact model revision, the mapping from
  requirement to statement to check, and the limits: no validator, no builder, no live acceptance.
  (unmet-stays-unmet)
