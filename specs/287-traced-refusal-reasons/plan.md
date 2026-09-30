# Plan: traced refusal reasons

## Status

- Completed: team setup; root baseline `nix develop --quiet -c just ci` at
  `3f04e50` exit 0 (211 s, runtime `receipts/baseline-001`); research; this
  mandate.
- Current: planning review; no behavior edit; implementation not released.
- Blockers: Q-001 (receipt fit) at the operator holds R3's receipt part
  (T032, T035-T038). Q-002 answered (A-002): fence holds, D287-DOC residual
  after evidence (T043). Q-003 (CG09 phase-1 reject, Lean vs chain) holds only
  CG09's classification; A-003 records it as D287-REJECT, an epic-owned
  affected-acceptance hold (not a waiver), so the every-row comparison stays
  unmet while it stands. Denominator: every live refusal, classified in
  `extent.md` (epic NOTE-001); a class-A comparison alone is not completion.

## Binding

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
  deployed replay (FR-06) links the two and the book names both hashes.
- IV: unobserved reasons stay visible (FR-09, FR-15); the wrong-reason control
  (FR-12) shows the comparison can fail.
- VI: state from receipts; the extent is counted, not listed (FR-14); harness
  evidence (capsules, controls) in the appendix.
- Translation table rows `retract`, `settle` state "not observed (#287)"; a
  constitution edit is outside this ticket (Q-002).

## Strategy

1. **Build.** A test-owned output in `conformance/flake.nix` builds the registry
   blueprint from `../onchain` with the deployed recipe's staged packages and
   `--trace-filter user-defined --trace-level verbose`, plus a check that the
   same toolchain untraced reproduces `onchain/script-identity.json` and that
   both blueprints name the same validators and parameter schemas (FR-02, FR-03).
   The conformance app carries it to the runner by `--set-default`, as it
   carries the naming blueprint.
2. **Capture.** On each live phase-2 validator rejection the runner writes a
   replay capsule before its next submission (FR-01; `contracts/replay-evidence.md`).
3. **Replay.** From the capsule, obtain the ledger's script arguments for each
   failing purpose; run the deployed applied bytes (must fail as a validator,
   FR-06), then the traced applied bytes with the same parameters (FR-04,
   FR-05) under the maximum per-transaction budget, and classify (FR-07, FR-08).
4. **Compare.** A refused-refused step agrees only on equal reasons (FR-09);
   attribution rows fill their existing branch field (FR-10).
5. **Publish.** Receipt fields per Q-001 (FR-11); CI jq counts the extent
   (FR-14); the book generator restates the limit (FR-15).

Model rows: `modules-model.md`, `data-model.md`, `functions-model.md`.

## Slices (bisect-safe, each ships alone)

| Slice | Content | Tasks | Needs |
|---|---|---|---|
| R1 | traced build + toolchain correspondence check + carrier; no runner change | T010–T014 | — |
| R2 | capture + replay + classification, recorded in replay capsules beside receipts; no receipt or comparison change | T020–T028 | R1 |
| R3 | reason comparison, receipt fields, attribution branch, wrong-reason and accepting controls, CI jq extent | T030–T038 | R2, Q-001 |
| R4 | book limit restated by its generator, BOOK.md regenerated, usage test | T040–T043 | R3 green in CI |

T001 (seam at the pin) precedes R1. T026, R2's first devnet run, is the
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
Premise and first capture use CG07 (two refusals, one accepting control).
Exhausting a tier stops that tier and journals `BLOCKED` with the tally;
receipts carry exit, duration and hashes.

Failure attribution for every red: implementation (coder) / contract (ticket
owner mandate or gate) / environment (Nix, devnet, host) / supervision. A setup
failure is logged and not charged as a semantic RED.

## Gate (verbatim CI commands; synthesized by the ticket owner — no gate-author seat in the approved team)

| Row | Acceptance | Command (workflow line) | Exit |
|---|---|---|---|
| G1 | root CI | `nix develop --quiet -c just ci` (justfile `ci`) | 0 |
| G2 | unit suite incl. classifier, comparison, book | `nix run --quiet .#conformance-tests` in `conformance` (conformance.yml:144-146) | 0 |
| G3 | format | `nix run --quiet .#format-check` in `conformance` (:85-86) | 0 |
| G4 | lint | `nix run --quiet .#hlint-check` in `conformance` (:89-90) | 0 |
| G5 | deployed hashes unchanged | `nix build --quiet .#build-gate` and `nix shell --quiet nixpkgs#jq nixpkgs#diffutils -c bash offchain/deployment-identity-check.sh` (ci.yml:33,45) | 0 |
| G6 | CG22/CG23/CG07 reasons observed and equal | the three dedicated row steps with extended jq (conformance.yml:163,235,296) — CI change in this ticket | 0 |
| G7 | CG21 + attribution rows | generic rows step (:337) and serialization step (:585), extended jq — CI change in this ticket | as asserted there |
| G8 | toolchain correspondence | new step building the correspondence check — CI change in this ticket | 0 |
| G9 | wrong-reason control | new step: altered run fails naming both reasons; unaltered passes — CI change in this ticket | ≠0 / 0 |
| G10 | discovered extent | new jq over all receipts: refusal count > 0, each once in the replay index with reason or cause and class, every class-A step agreed, and for every refusing role an accepting-control entry with both runs succeeded (FR-13) — CI change in this ticket | 0 |

Falsification: G6/G7/G10 by the current red (base has no reasons); G9 by its
own altered leg; G8 by a mismatched build input in a unit or flake test.

## Risks

- Seam unverified at the cardano-node-clients pin (T001); a missing seam is a
  placement challenge, not a license to re-derive the context.
- CG23 receipt margin (14745 bytes) with new fields — Q-001.
- Traced cost exceeds declared units; replay uses the protocol maximum.
