# Tasks: traced refusal reasons

Dependency order top to bottom. Tier in brackets (plan.md schedule). Each slice
opens with its RED bundle and closes with its acceptance line; each is a
`review checkpoint` checkpoint for the persistent auditor.

```mermaid
flowchart LR
    T001[Pinned ledger replay seam] --> R1[Traced validator build]
    R1 --> R2[Capture and replay]
    R2 --> R3[Comparison, receipts and controls]
    R3 --> R4[Generated book]
    Q1[Receipt-format ruling] --> R3
```

## Setup

- [x] read-pinned-cardano-node-clients-offchain [local checks] Read the pinned cardano-node-clients (`offchain/cabal.project`
  tag `0e73121d`) and ledger sources: name the value that carries one
  purpose's script and ledger-built arguments on a validation failure and how
  to evaluate other bytes on it with logs. Record `path:line` in the coder's
  intake; a missing seam is a placement challenge (modules-model conformance-run-replay).

## traced-build — traced build (traced-validator-build, toolchain-correspondence)

- [x] red-correspondence-check-fails-on-base [builds] RED: the correspondence check (build-traced-registry-blueprint-from-onchain-build) fails on the base because the
  output does not exist; and, once present, fails when fed a build that differs
  from the deployed recipe by a compiler input other than the trace flags.
- [x] traced-blueprint-output-from-onchain-packages [builds] Traced blueprint output from `../onchain`, packages staged as the
  deployed recipe stages them, flags `--trace-filter user-defined --trace-level verbose`.
- [x] correspondence-check-untraced-rebuild-reproduces-onchain [builds] Correspondence check: untraced rebuild reproduces every
  `onchain/script-identity.json` hash; traced and untraced name the same
  validators and parameter schemas; provenance file (tracedprovenance-output-read-by).
- [x] carrier-conformance-app-sets-registry-traced [builds] Carrier: the conformance app sets `REGISTRY_TRACED_BLUEPRINT`
  by default, as it sets `NAMING_BLUEPRINT`.
- [x] ci-step-for-ci-change-in-this CI step for toolchain-correspondence-check (CI change in this ticket). Acceptance: conformance-suite, conformance-format, conformance-lint,
  toolchain-correspondence-check green; `onchain/` untouched; deployed-hashes-unchanged green.

## capture-replay — capture and replay (capture-refused-transaction, matching-script-parameters–separate-evidence-classes)

- [x] red-table-driven-unit-cases-for [local checks] RED: table-driven unit cases for `admitReason` and
  `compareReason` over every replayclass cause and reasoncomparison outcome, failing against a stub.
- [x] conformance-replay-turns-green [local checks] `Conformance.Replay` (conformance-replay) turns red-table-driven-unit-cases-for green.
- [x] capturecapsule-at-validator-rejection-driver-steps [local checks] `captureCapsule` at every validator rejection, driver steps and
  attribution rows, before the next submission; incomplete resolution is
  `capture-incomplete` (unit RED on a transaction whose reference input is
  left unresolved).
- [x] purposearguments-from-capsule-through-seam [local checks] `purposeArguments` from the capsule through the read-pinned-cardano-node-clients-offchain seam.
- [x] applydeployedparameters-parameters-mismatch-untraced-application-does [local checks] `applyDeployedParameters`; `parameters-mismatch` when the
  untraced application does not hash to the failing hash (unit RED with a
  wrong parameter value).
- [x] evaluatebytes-replayrefusal-capsule-files-per-contracts [local checks] `evaluateBytes` and `replayRefusal`; capsule files per
  `contracts/replay-evidence.md`.
- [x] premise-run-on-retract-outside-window [devnet] Premise run on retract-outside-window: record the deployed replay's logs. If the
  deployed bytes emit the named user trace, stop and file `BLOCKED` (the
  traced build would be unnecessary; the ticket owner escalates).
- [x] run-retire-active-key-reject-retract [devnet] Run retire-active-key, reject-and-retract-refund-controls, retract-outside-window and the generic session with capture on;
  report each rejection's class from `replay/index.json`. Acceptance: conformance-suite, conformance-format,
  conformance-lint green; no receipt or comparison change yet; every class observed is
  admitted or its cause named.
- [x] from-receipts-replay-index-discover-complete [local checks] From the run-retire-active-key-reject-retract receipts and replay index, discover the complete
  refusal extent. Refusals with an executed model reason are class A by fact.
  Classify each remaining refusal against Lean clauses and executing consumers
  into the committed B/C/D table in `extent.md` (the ticket owner commits it);
  return every C or D as a user story to the ticket owner, with receipt and
  trace.

## capture-replay repairs (Epic #209 operator answer (A-006), operator answer (A-007))

- [x] retire-active-key-exclusion-proof-via [local checks] retire-active-key: exclusion proof via the fallback of `storyProofs`.
  Live evidence (D-006) shows it does not reach the story's path; superseded
  by retire-active-key-on-executed-per and kept only if retire-active-key-on-executed-per makes it the route, else removed as dead.
- [x] reject-before-deadline-consumer-requirement-declares [devnet] reject-before-deadline-consumer-requirement declares the accepting control's units; new refused
  transaction captured, budget-refused predecessor kept (D-006).
- [x] witness-route-witness-witness-replayed-captured [local checks] Witness route: `witness.witness` replayed with the captured
  registry id and kind; admitted only when the untraced application hashes to
  the failing witness policy. replayclass split into `no-replay-route`,
  `parameters-mismatch`, `unidentified-script`, each produced by an executed
  unit case through the classifier, spellings equal to replayclass. An offline
  `replay-capsule` run replays the retained wrong-redeemer-constructor-index capsule through the same core
  from its saved transaction, outputs, protocol parameters and era data,
  recomputes its captureId, and writes its outcome beside, never over, the
  original. A candidate-hash test alone does not show the captured script was
  replayed.
- [x] retire-active-key-on-executed-per [devnet] retire-active-key on the executed per-request speculative path: for a
  non-insertion on a key the speculative trie does not hold, the exclusion
  proof is computed without walking or mutating that key; a unit case on that
  executed path; one live `run retire-active-key` shows a non-empty proof in the rebuilt
  redeemer, deployed replay `validator-failure`, traced admitted exactly
  `key-unknown`.

## comparison-receipt-controls-ci-done-released-by — comparison, receipt, controls, CI (compare-observed-refusal-reasons–discovered-refusal-extent) — R3a done; R3b (receipt-replay-object-data-model-written, extend-retire-active-key-reject-retract-refund–extent-over-receipt-non-empty-guard-refusal) released by the operator question (Q-001) ruling

- [x] red-refused-refused-step-differing-admitted [local checks] RED: a refused-refused step with a differing admitted reason
  compares `differs`, and one with an unobserved reason `uncompared`. Then wire
  reasoncomparison at the sites that today decide and throw: `compareStep`
  (`conformance/app/Conformance/Run/Live.hs:2599`, failure at `:2635`) and
  the rows that require `agrees` before writing their receipt (retract-outside-window
  `CgRows.hs:470-479`, register-active-key `:1602-1611`, retire-active-key `:1677-1689`, reject-and-retract-refund-controls `:1745`):
  the index entry with `modelReason` and comparison is written first;
  `differs` fails the row; `uncompared` keeps outcome agreement and the row
  writes its receipt. Unit RED: a `differs` run leaves the index entry.
- [x] attribution-rows-fill-branch-from-admitted [local checks] Attribution rows fill `branch` from an admitted reason and keep
  the limit otherwise; every refusal carries its extent class (classify-refusal-comparison-extent).
- [x] receipt-replay-object-data-model-written [local checks] Receipt replay object (self-contained-replay-receipt, data-model): written by every
  refusal path, step and attribution; loader accepts legacy receipts without
  it, rejects an incomplete or contradicting one (unit REDs: a missing
  `tracedHash` with `reason`; `reason` and `cause` both; a `trace` disagreeing
  with `replay.reason`); size: measure the largest live receipt with the
  object, set `maxReceiptBytes` and the CI margins from that measurement with
  stated headroom, and keep a negative control over the cap. A permissive
  decoder is not evidence a consumer receives the data: the book/report path
  reads it in a test.
- [x] wrong-reason-control-mode-unit-red [local checks] Wrong-reason control mode (wrong-reason-control-one-row-one-step); unit RED that the altered step
  cannot compare `agrees`.
- [x] accepting-control-per-refusing-script-role [devnet] Accepting control: per refusing script role one accepted
  step's transaction replays on deployed and traced bytes and is written as an
  `accepting-control` index entry (accepting-replay-control); complete-refusal-extent fails when either run does not
  succeed or a refusing role has no entry (unit RED on a fixture index).
- [x] extend-retire-active-key-reject-retract-refund retirement-refund-window-reasons: extend the retire-active-key, reject-and-retract-refund-controls, retract-outside-window steps' jq (CI change in this ticket). The jq
  requires, per refused step with a model reason, `replay.reason` equal to
  `model.reason`, the two hashes, the `captureId`, and the receipt's
  `replayCorrespondence`.
- [x] retention-at-ci-boundary-e209-note-recut Retention at the CI boundary (Epic #209 operator note (NOTE-003) recut of review 003):
  each dedicated retract-outside-window, retire-active-key and reject-and-retract-refund-controls step publishes its receipts path to the
  workflow's always-run `conformance-receipts` upload before invoking the row;
  on the row's non-zero exit the step keeps that exit status and leaves a
  durable replay index with the `differs` or `uncompared` entry for the
  upload. A control executes the committed step's own script (the same
  wrapper and path resolution CI runs) with a failing row invocation and
  asserts both the original non-zero exit and the retained index at the
  published path; the control is falsified by disabling the path publication
  or the retention and observing it fail. Reviewed with the comparison-receipt-controls-ci-done-released-by implementation
  checkpoint and its real control receipt, not as a separate prose round.
- [x] extend-generic-serialization-steps-jq registration-and-attribution-reasons: extend generic and serialization steps' jq.
- [x] insert-occupied-key-executing-consumer-e209 [local checks] insert-occupied-key executing consumer (Epic #209 operator answer (A-011)): insert-occupied-key runs as a story through the
  generic interpreter (new `conformance/lib/Conformance/Edge/Occupied.hs`,
  `runInsertOccupiedKey` → the shared live runner): its occupied starting state is created
  by real accepted connected actions and readbacks, the original occupied-insert
  case is kept (insertAbsent on the occupied key), and the actual setup,
  config and request reach the generic Lean question. Accepted control and the
  refused insert reach deployed replay, traced replay, Lean comparison and the
  receipt replay object. No new oracle, adapter, typed expected reason, Lean,
  driver or rows.json change. Evidence: the R3b generic-session run, after the
  insert-occupied-key checkpoint review; the generic step's CI assertions read the story
  receipt (refused step model `key-exists`, trace `key-exists`, comparison
  agrees, connected accepted control).
- [x] wrong-redeemer-constructor-index-offline-compiler [local checks] wrong-redeemer-constructor-index offline compiler diagnostic (Epic #209 operator answer (A-012)): a second test-owned
  build of the same registry source, compiler and pins with
  `--trace-filter all --trace-level verbose`, checked against the same untraced
  twin; offline only, from the retained wrong-redeemer-constructor-index capsule, with the captured
  arguments, the deployed parameters (reproducing the captured deployed hashes)
  and the declared budget; deployed reproduction still required; evaluated only
  for purposes the user-defined replay left `no-user-trace`; written to
  `replay-diagnostic/<txid>/outcome.json` with `kind: compiler-diagnostic`
  beside the untouched `replay-offline` outcome; never admitted, never a reason,
  never compared, never in a receipt or the index. Controls: a mismatched
  blueprint or parameter set is refused before any diagnostic; a successful,
  budget-failing, silent or generic diagnostic keeps its category.
- [x] control-step-altered-leg-non-zero-naming wrong-reason-failing-control: control step, altered leg non-zero naming both reasons, restored leg zero.
- [x] extent-over-receipt-non-empty-guard-refusal complete-refusal-extent: extent over every receipt, non-empty guard, each refusal once
  in `replay/index.json`; a refusal with a model reason not class A, or not
  agreeing or uncompared with a cause, fails; a refusal without one absent from
  the committed B/C/D table fails as unclassified (unit RED: a driver refusal
  relabelled B, and an unlisted attribution refusal). Acceptance: extend-retire-active-key-reject-retract-refund–extent-over-receipt-non-empty-guard-refusal each seen red on the
  base or the altered leg, then green locally [D ≤ 4 runs].

## book — book (book-states-observation-limits)

- [x] restate-limit-in-conformance-book-method [local checks] Restate the limit in `Conformance.Book`: method, both hashes,
  deployed bytes carry no traces, remaining unobserved refusals by row.
- [x] insert-occupied-key-in-book-e209 [local checks] insert-occupied-key in the book (Epic #209 operator answer (A-013)): the book run executes and renders the
  occupied-key story beside the five existing chapters and the sequence, from one
  declared book-story extent used for execution, rendering and completeness;
  `conformance/app/Main.hs` changes only in `runBook`'s row selection, receipt
  filter, required-row completeness and count, and the directly needed Book
  import(s). Negative witnesses: a missing story receipt is rejected; a renderer
  that omits the occupied-key refusal fails. wrong-redeemer-constructor-index stays a limits row with its
  appendix diagnostic; no constructor story.
- [x] regenerate-conformance-book-md-its-generator [builds] Regenerate `conformance/BOOK.md` with its generator only.
- [x] update-conformance-story-usage-restated-text [local checks] Update `Conformance.Story.Usage` to the restated text.
- [ ] prepare-residual-for-epic-from-evidence [local checks] Prepare the residual-after-evidence residual for the epic from premise-run-on-retract-outside-window/run-retire-active-key-reject-retract
  evidence (operator answer (A-002)): stale wording, path, revision, reader claim, evidence,
  proposed repair, authority needed. No edit outside the fence. Acceptance: root-checks–complete-refusal-extent green at the head (pre-push checkpoint).

## Final delivery (narrowed acceptance, 2026-10-02)

Integrated with main `13f2b2e`; acceptance narrowed by the operator's rulings of
2026-10-02 (spec.md). prepare-residual-for-epic-from-evidence's documentation residual is tracked by
lambdasistemi/singular#321, outside this branch.

- [x] merge-main-into-branch-as-merge-commit Merge main `13f2b2e` into the branch as a merge commit, its history
  unrewritten; the replay capture moves behind `Conformance.Run.Node`, the one
  module that opens the harness's node (#326), and the replay module joins the
  node-confinement allowlist with its reason.
- [x] rebind-traced-untraced-correspondence-s-validators-check Rebind the traced/untraced correspondence to #320's validators: the
  toolchain-correspondence check at the head reproduces the new `onchain/script-identity.json`.
- [x] batch-model-s-batch-questions-answer-compared A batch the model's batch questions answer is compared on its reason
  too: the refused batch's traced reason for the state script meets the model's,
  recorded in the replay index first, failing the row naming both when it
  differs; a reject batch carries the refunds through which the chain settles
  what it owes, judged by `settle`.
- [x] story-language-s-fold-batch-takes-tamper The story language's fold batch takes a tamper, `mint-on-first-key`;
  the registration chapter folds two registrations minting both at the first
  key, refused by the chain and the model for the same reason.
- [x] empty-fold-s-empty-fold-in-registry empty-fold's empty fold, in a registry of its own, and request-value-and-refund-routing's crossed
  refunds are compared with `foldBatch` and `rejectBatch`; their receipts carry
  the batch records, which the loader validates.
- [x] reject-before-deadline-consumer-requirement-s-short reject-before-deadline-consumer-requirement's short reject control and request-value-and-refund-routing's rejected-floor control are
  compared with the reject batch; their owners are wallets other than the one a
  fold returns its change to.
- [x] reject-inside-processing-retraction-windows-runs-through reject-inside-processing-and-retraction-windows runs through the dedicated-row wrapper, its refused steps carry
  their traced replay, and its receipts join the extent.
- [x] fold-against-superseded-root-surplus-fold-actions fold-against-superseded-root, surplus-fold-actions and wrong-redeemer-constructor-index are published as unmet model comparisons with
  their traced evidence (lambdasistemi/singular#346, #345, #347): the extent
  table, the book's limits and the rows' narration, surplus-fold-actions no longer said to agree
  with the model.
- [x] re-render-conformance-book-md-its-generator Re-render `conformance/BOOK.md` with its generator from a book run at
  the integrated head; restamp this directory's speech companions.

## Rulings of 2026-10-02 on the escalations (operator answer (A-001))

- [x] reject-refund-record-now-later-reject-before Reject refund, "Record now, fix later": reject-before-deadline-consumer-requirement submits a reject paying
  its owner one lovelace short at the refund's position and the remainder in
  another output at the owner's key; the chain refuses it `deposit-returned`,
  the model accepts, and the row records the disagreement in its receipt, never
  as a pass (extent class D; book, spec and plan limits;
  lambdasistemi/singular#361).
- [x] fold-against-superseded-root-surplus-fold-actions fold-against-superseded-root, surplus-fold-actions and wrong-redeemer-constructor-index receipts carry the verdict `unmet-by-ruling`,
  naming lambdasistemi/singular#346, #345 and #347, in the non-passing debt
  report beside reject-before-deadline-consumer-requirement; the serialization session reports its unmet row like the registry-operations
  session; CI's verdict and debt assertions move with them.
