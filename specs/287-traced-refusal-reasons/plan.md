# Plan: traced refusal reasons

## Status

- Final delivery (2026-10-02): the branch merges main `13f2b2e` (#320's
  validators and reject-before-deadline-consumer-requirement `unmet-by-ruling`, #344's batch questions, #326's node
  capabilities) without rewriting its history, and narrows acceptance by the
  operator's rulings of 2026-10-02 (spec.md, "Narrowed acceptance"). traced-build–book are
  done; the final slice (tasks merge-main-into-branch-as-merge-commit–re-render-conformance-book-md-its-generator) compares the batch refusals through
  `foldBatch` and `rejectBatch`, publishes fold-against-superseded-root, surplus-fold-actions and wrong-redeemer-constructor-index as unmet model
  comparisons (lambdasistemi/singular#346, #345, #347) and runs reject-inside-processing-and-retraction-windows under the
  same replay and extent checks. The gate is the ticket owner's frozen final
  gate; CI on the pushed head is its evidence.

Earlier status, kept as history:

- Completed: team setup; root baseline `nix develop --quiet -c just ci` at
  `3f04e50` exit 0 (211 s, runtime `receipts/baseline-001`); research; this
  mandate.
- Current (2026-10-01): traced-build and capture-replay closed as slices; R3a gate GREEN at 0287727
  (review pending). Operator rulings: one self-contained receipt (self-contained-replay-receipt, R3b
  released on its sealed packet); reject-before-deadline-consumer-requirement keeps Lean and the validator is repaired
  in a separate predecessor, after which #287 rebinds its build correspondence.
  Spend by receipts: C47, N43, D14 of C150/N55/D18.
- Blockers: operator question (Q-001) (receipt fit) at the operator holds comparison-receipt-controls-ci-done-released-by's receipt part
  (receipt-replay-object-data-model-written, extend-retire-active-key-reject-retract-refund-extent-over-receipt-non-empty-guard-refusal). operator question (Q-002) answered (operator answer (A-002)): fence holds, residual-after-evidence residual
  after evidence (prepare-residual-for-epic-from-evidence). operator question (Q-003) (reject-before-deadline-consumer-requirement phase-1 reject, Lean vs chain) holds only
  reject-before-deadline-consumer-requirement's classification; operator answer (A-003) records it as comparison-unmet, an epic-owned
  affected-acceptance hold (not a waiver), so the every-row comparison stays
  unmet while it stands. Denominator: every live refusal, classified in
  `extent.md` (epic operator note (NOTE-001)); a class-A comparison alone is not completion.

## Binding

Final delivery: integrated with main `13f2b2e`, constitution 1.12.0; the
traced/untraced correspondence (toolchain-correspondence) is checked against #320's
`onchain/script-identity.json` at the head. The original binding follows.

Issue #287, epic #209, branch `fix/287-traced-refusal-reasons`, base
`3f04e50d293b80360a3234ebf3114abc8172d851`, constitution 1.11.0, Lean and
`lean/driver-corpus.json` unchanged. Carried gates: independent #304 Lean
readback, E301/root-model compatibility, #288 format-control review — held by
the epic, not by this ticket.

## Constitution check

- I/II: Lean's refusal names are the oracle; no model or expected-result edit.
  A traced reason that differs from Lean's fails its row; it is never relabelled.
- III: the traced re-evaluation is script-execution evidence on captured ledger
  context, distinct from the chain's execution of the deployed bytes; the
  deployed replay (deployed-refusal-reproduction) links the two and the book names both hashes.
- IV: unobserved reasons stay visible (compare-observed-refusal-reasons, book-states-observation-limits); the wrong-reason control
  (wrong-reason-control) shows the comparison can fail.
- VI: state from receipts; the extent is counted, not listed (discovered-refusal-extent); harness
  evidence (capsules, controls) in the appendix.
- Translation table rows `retract`, `settle` state "not observed (#287)"; a
  constitution edit is outside this ticket (operator question (Q-002)).

## Strategy

1. **Build.** A test-owned output in `conformance/flake.nix` builds the registry
   blueprint from `../onchain` with the deployed recipe's staged packages and
   `--trace-filter user-defined --trace-level verbose`, plus a check that the
   same toolchain untraced reproduces `onchain/script-identity.json` and that
   both blueprints name the same validators and parameter schemas (traced-validator-build, toolchain-correspondence).
   The conformance app carries it to the runner by `--set-default`, as it
   carries the naming blueprint.
2. **Capture.** On each live phase-2 validator rejection the runner writes a
   replay capsule before its next submission (capture-refused-transaction; `contracts/replay-evidence.md`).
3. **Replay.** From the capsule, obtain the ledger's script arguments for each
   failing purpose; run the deployed applied bytes (must fail as a validator,
   deployed-refusal-reproduction), then the traced applied bytes with the same parameters (matching-script-parameters,
   matching-ledger-context) under the maximum per-transaction budget, and classify (single-observed-trace, separate-evidence-classes).
4. **Compare.** A refused-refused step agrees only on equal reasons (compare-observed-refusal-reasons);
   attribution rows fill their existing branch field (classify-refusal-comparison-extent).
5. **Publish.** Receipt fields per operator question (Q-001) (self-contained-replay-receipt); CI jq counts the extent
   (discovered-refusal-extent); the book generator restates the limit (book-states-observation-limits).

Model rows: `modules-model.md`, `data-model.md`, `functions-model.md`.

## Slices (bisect-safe, each ships alone)

| Slice | Content | Tasks | Needs |
|---|---|---|---|
| traced-build | traced build + toolchain correspondence check + carrier; no runner change | red-correspondence-check-fails-on-base–ci-step-for-ci-change-in-this | — |
| capture-replay | capture + replay + classification, recorded in replay capsules beside receipts; no receipt or comparison change | red-table-driven-unit-cases-for–from-receipts-replay-index-discover-complete | traced-build |
| comparison-receipt-controls-ci-done-released-by | reason comparison, receipt fields, attribution branch, wrong-reason and accepting controls, CI jq extent | red-refused-refused-step-differing-admitted–extent-over-receipt-non-empty-guard-refusal | capture-replay, operator question (Q-001) |
| book | book limit restated by its generator, BOOK.md regenerated, usage test | restate-limit-in-conformance-book-method–prepare-residual-for-epic-from-evidence | comparison-receipt-controls-ci-done-released-by green in CI |

read-pinned-cardano-node-clients-offchain (seam at the pin) precedes traced-build. premise-run-on-retract-outside-window, capture-replay's first devnet run, is the
premise check: if the deployed bytes already emit the named trace, stop and
escalate, since the traced build would be unnecessary.

## Owned paths (frozen for implementation)

`conformance/flake.nix`; `conformance/conformance.cabal` (module lists and
dependencies already in the lock only); `conformance/lib/Conformance/**`;
`conformance/app/Conformance/**`; `conformance/test/**`; `conformance/BOOK.md`
(generator output only); `.github/workflows/conformance.yml` (steps and jq of
the conformance job). Everything else is forbidden, including `offchain/`,
`onchain/`, `naming-onchain/`, `applications/`, `lean/`, `docs/`,
`.specify/`, all flake locks. A needed change elsewhere is a placement
challenge to the ticket owner.

Final delivery adds, by the ticket owner's brief: `.github/scripts/ci_generic_rows.sh`
(main moved the generic rows step there), `tools/node-confinement.allow` (the
replay module reads the node beside the composition module that opens it,
#326), and this directory's `spec.md`, `plan.md`, `tasks.md`, `extent.md`
with their speech companions.

## Execution schedule

Unit: one invocation of the named tool, one receipt written by
`gate-script/scripts/run-receipt` under `coder-1/receipts/<tier>-NNN.log`;
the tally is the file count, checked before each invocation.

| Tier | What | Ceiling | Per-invocation limit |
|---|---|---|---|
| C cheap | `cabal build`/`cabal test`/`ghci` inside an entered conformance shell, fourmolu/hlint on files, jq over existing receipts | 150 | 10 min |
| N nix | any `nix build`/`nix run`/`nix develop -c` without a devnet: traced blueprint, check, `.#conformance-tests`, format/hlint apps, root `just ci` | 30 | 40 min |
| D devnet | `nix run .#conformance -- run <rows>` | 10 | 25 min |

Aggregate wall clock: none supplied by the operator; none invented. Order:
C before N before D; a D run needs the latest N `conformance-tests` green.
Premise and first capture use retract-outside-window (two refusals, one accepting control).
Exhausting a tier stops that tier and journals `BLOCKED` with the tally;
receipts carry exit, duration and hashes.

Failure attribution for every red: implementation (coder) / contract (ticket
owner mandate or gate) / environment (Nix, devnet, host) / supervision. A setup
failure is logged and not charged as a semantic RED.

## Gate (verbatim CI commands; synthesized by the ticket owner — no gate-author seat in the approved team)

| Row | Acceptance | Command (workflow line) | Exit |
|---|---|---|---|
| root-checks | root CI | `nix develop --quiet -c just ci` (justfile `ci`) | 0 |
| conformance-suite | unit suite incl. classifier, comparison, book | `nix run --quiet .#conformance-tests` in `conformance` (conformance.yml:144-146) | 0 |
| conformance-format | format | `nix run --quiet .#format-check` in `conformance` (:85-86) | 0 |
| conformance-lint | lint | `nix run --quiet .#hlint-check` in `conformance` (:89-90) | 0 |
| deployed-hashes-unchanged | deployed hashes unchanged | `nix build --quiet .#build-gate` and `nix shell --quiet nixpkgs#jq nixpkgs#diffutils -c bash offchain/deployment-identity-check.sh` (ci.yml:33,45) | 0 |
| retirement-refund-window-reasons | retire-active-key/reject-and-retract-refund-controls/retract-outside-window reasons observed and equal | the three dedicated row steps with extended jq (conformance.yml:163,235,296) — CI change in this ticket | 0 |
| registration-and-attribution-reasons | register-active-key + attribution rows | generic rows step (:337) and serialization step (:585), extended jq — CI change in this ticket | as asserted there |
| toolchain-correspondence-check | toolchain correspondence | new step building the correspondence check — CI change in this ticket | 0 |
| wrong-reason-failing-control | wrong-reason control | new step: altered run fails naming both reasons; unaltered passes — CI change in this ticket | ≠0 / 0 |
| complete-refusal-extent | discovered extent | new jq over all receipts: refusal count > 0, each once in the replay index with reason or cause and class, every refusal with a model reason recorded as class A and agreeing or uncompared with a cause, every other refusal listed as B, C or D in `extent.md` (unclassified fails), and for every refusing role an accepting-control entry with both runs succeeded (accepting-replay-control) — CI change in this ticket | 0 |

Falsification: retirement-refund-window-reasons/registration-and-attribution-reasons/complete-refusal-extent by the current red (base has no reasons); wrong-reason-failing-control by its
own altered leg; toolchain-correspondence-check by a mismatched build input in a unit or flake test.

## Risks

- A reject's refund: the chain judges it by position, the model by the owner's
  summed outputs; the compared rejects agree for their fixtures' shape only, and
  reject-before-deadline-consumer-requirement records the divergence on the devnet, never as a pass
  (lambdasistemi/singular#361; extent.md, spec.md limit).
- Seam unverified at the cardano-node-clients pin (read-pinned-cardano-node-clients-offchain); a missing seam is a
  placement challenge, not a license to re-derive the context.
- reject-and-retract-refund-controls receipt margin (14745 bytes) with new fields — operator question (Q-001).
- Traced cost exceeds declared units; replay uses the protocol maximum.
