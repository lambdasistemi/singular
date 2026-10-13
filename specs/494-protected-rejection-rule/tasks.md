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

Runs after slice eight, by the operator's order of 13 October 2026.

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

## Slices five to ten: the economic model and the paper

Planned in the [economics plan](economics-plan.md); started after slice three and after the desk reviewed that plan (it did, with returned lines folded in); slices five to eight run before slice four, by the operator's order of 13 October 2026, and the paper (nine and ten) is written in parallel.

### Slice five: parameters and fields

- [ ] `registry-parameters` — the bond, the processor split and the termination fee exist in the registry configuration, default to zero in old input and are preserved by every fold.
- [ ] `request-economic-fields` — a request carries its bond, the termination fee it carries and the root it recorded at booking, each serialized and zero when absent.
- [ ] `booking-admission` — the booking rule exists as a defined admission with a refusal reason per failure: the bond is at least the registry bond, a terminate request carries at least the registry fee, and the recorded root equals the root of the state read at booking; the request-tag mint must enforce exactly it.
- [ ] `donation-field` — a transaction carries a treasury donation amount, zero when absent.
- [ ] `protocol-eight` — the driver protocol version moves and the surface digest follows.
- [ ] `regenerate-after-slice-five` — corpora, register and digests, simulator mirror, application corpus, coverage record and the restatement table follow.
- [ ] `amendment-economics` — the 1.16.0 entry of the constitution states the economic fields in the translation (one release, one entry).

### Slice six: outcomes and transfers

- [ ] `outcomes-and-transfers` — the five outcomes and the transfer table exist as definitions.
- [ ] `bond-returned-without-fault` — a fold, a retraction and a rejection without proof or on expiry owe the owner the bond.
- [ ] `treasury-recipient` — the treasury is a recipient and its donation is settled against the transaction field.
- [ ] `zero-donation-omitted` — an owed amount of zero imposes no donation.
- [ ] `regenerate-after-slice-six` — as slice five.

### Slice seven: fault proof, forfeit and termination fee

- [ ] `booking-proof-in-evidence` — rejection evidence may carry the map that commits to the recorded booking root.
- [ ] `forfeit-and-split` — a mismatch rejection with a valid booking proof owes the treasury the bond minus the processor share and the owner the deposit.
- [ ] `expiry-and-no-proof-return-bond` — a rejection on expiry or without a valid booking proof forfeits nothing.
- [ ] `termination-fee-owed` — a fold that terminates a key owes the treasury at least the fee per terminated key.
- [ ] `refusals-name-bond-and-fee` — a transaction that does not donate what is owed is refused with a reason naming the bond or the fee.
- [ ] `regenerate-after-slice-seven` — as slice five.

### Slice eight: theorems and counterexamples

- [ ] `economic-theorems` — the proved statements of the economics plan are stated and proved from standard axioms.
- [ ] `counterexamples-kept` — each statement expected to fail has a Lean example that exhibits the counterexample.
- [ ] `audit-report-covers-economics` — the audit report lists every economic statement with its axioms.
- [ ] `regenerate-after-slice-eight` — as slice five.

### Slice nine: the paper builds and its first sections

- [ ] `paper-builds-into-site` — the paper builds in a Nix derivation into the documentation site.
- [ ] `paper-page-and-table` — a documentation page carries the abstract, the theorem-to-Lean table generated from the audit report and the PDF link.
- [ ] `paper-sections-one-to-four` — system model, adversary and cost model, mechanism and properties are written, each claim citing its Lean statement.

### Slice ten: the paper is complete

- [ ] `paper-sections-five-to-ten` — parameter constraints, related work, limitations and the appendix are written.
- [ ] `paper-appendix-from-audit` — the appendix maps every theorem to its Lean name, file, line and pinned commit with the axioms printed and the trusted base stated.
- [ ] `paper-claims-checked-against-lean` — an audit confirms that no claim of the paper goes beyond the statement it cites.

## Closing the ticket

- [ ] `release-record` — the contract's release record is filled with the model revision, statement
  digests, corpus rows, constitution version and remaining limits. (consumers-state-the-rule)
- [ ] `pull-request-body` — the body states the story, the exact model revision, the mapping from
  requirement to statement to check, and the limits: no validator, no builder, no live acceptance.
  (unmet-stays-unmet)
