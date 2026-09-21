# #196 — Simulator test quality: control mapping and verification record

Story: as a simulator contributor, I run its checks and observe a failure when
mint or refund effects are wrong, with coverage that identifies what was
actually exercised.

Model binding (implementation intake, base `ba788d0fd19ed3d2388335436594d3318ff9c80d`,
review baseline `e19ca5efacb23acdbef51110f003dddc35ad592c`):

- `lean/corpus.json` `modelSha256 343f7e23a13c05f814a66c9d3d55fe2486a23ce0c4f8cb842b0e96626bcde853`,
  `statementsSha256 b0f8867e…22acab`, `theoremManifestSha256 bbc2cdf9…9aef6c`.
- The observable result of an admitted transition is the whole
  `Singular.Model.Result` `{state, mint, paid}`:
  `Singular.Model.applyEdge` returns `mint := assetDelta a` (the R2 delta of
  the edge) and `paid := [(c.refundAddress, c.value)]` for `updateActive` /
  `deleteAbsent` over the request key's custody entry (R-ADA); `step` is
  `refusal` or `applyEdge`. The gate now compares all three observables.
- Keyed mint evidence rows are exports of
  `Singular.Statements.fold_batch_claimed_mint_by_kind_key`; the transcription
  predicate they are inspected with is `core.mjs` `assetSame`
  (transcription of `Singular.Model.assetSame`).
- No Lean file, corpus export, or expected result was changed by this slice.

## Before/after mapping of the checks

| Control (failure name) | Before: what it observed | After: what it observes |
|---|---|---|
| `corpus verdict/<id>` | accepted/refused verdict per exported case | unchanged |
| `corpus state/<id>` | accepted case end-state vs Lean `result.state` | unchanged |
| `corpus mint/<id>` (new) | — nothing | the admitted case's `value.mint` equals the R2 delta of the case's own edge |
| `corpus refund/<id>` (new) | — nothing | the admitted case's `value.paid` equals the custody refund (destination **and** amount) the case's own `before` state requires |
| `no corpus case observes a refund` (new) | — nothing | guards the refund observation against silent vacuity |
| `ada destination/<id>` | refund destination only | replaced by `ada refund/<id>`: destination **and** the fixture's deposited amount |
| `fold mint/two booked keys`, `fold paid/two booked keys` (new) | — nothing (fold mint was never compared) | the fold's own observable mint/paid, not just its refusal behavior |
| `law never exhibited: <name>` | `exhibited` counted every accepted row, including vacuous passes | replaced by `law with no applicable example: <name>` — the count is rows whose hypotheses are active |
| `law not exercised: <name>` (new) | — nothing | a controlled law must be exercised; vacuous passes cannot hold it up |
| theorem table columns | `exhibited / held` | `applicable / vacuous / held / exercised` |
| naming receipt | `{discovered, executed}` — rows reported as "executed" while nothing ran | `{discovered, inspected, executed: 0, boundary: 'evidence'}`; gate asserts `executed === 0` |
| naming row validation | only duplicate ids and conditional expected/actual disagreement; a fabricated `{id}` row passed, six times over | id type, per-section required observations, boolean verdicts, resolved-spelling keys, resolve rows checked against the supply biconditional, kind exclusion and terminal attestation soundness; duplicates still rejected |
| lifecycle receipt | `{executed}` — inspection labeled as execution | `{inspected, executed: 0, boundary: 'evidence'}`; validation unchanged (already rejected id-less/verdict-less rows) |
| page/browser labels | "naming corpus rows … replayed", lifecycle prose "replayed" | "inspected · Lean evidence, not replayed"; browser-check pins the inspected wording |
| exported section report (new) | — nothing; `keyedMintRows` and `transactions` were not consumed and nothing said so | every array section the corpus exports is enumerated in the gate report as `behavior`, `evidence`, or `uncovered`; an unclassified section fails `unclassified exported corpus sections` |
| `fold evidence/<id>`, `keyed mint evidence/<id>`, `transaction evidence/<profile>` (new) | fold rows only fed the refusal vocabulary; keyed/transaction rows unused | evidence rows inspected against the transcription's own predicates (`assetSame`, per-kind totals, refusal vocabulary, claimed-mint identity); never executed |
| selftest | 6 legs | 13 legs: adds dropped-mint, zeroed-refund, unclassified-section, id-only-row, supply-sync-contradiction controls and the live positive control that stripping occupancy's applicable examples stops the law being reported as exercised |

Preserved unchanged: identity/manifest checks, refusal-vocabulary coverage,
edge-table complement, empty-batch and keyed fold controls, stories, boundary
refusals, page build identity, the Over witness journey (behavior), lifecycle
by-id rows and retirement-reason checks. The handwritten fold controls remain
behavioral controls, not a coverage catalogue; no second catalogue was added.

## Verification record

Commands and results (all run from the worktree root):

- `nix run --quiet .#simulator-check` — baseline exit 0; candidate exit 0
  (mirror PASS, build identity PASS, gate PASS, selftest PASS with the new
  legs). Two of the three permitted invocations used; no repair run needed.
- `nix run --quiet .#browser-check` — baseline exit 0 (25 checks); candidate
  failed once on my own redundant negative label assertion ("replayed"
  matched inside "not replayed"); repaired by pinning the exact inspected
  wording; repair run exit 0 (26 checks). All three permitted invocations
  used.
- RED controls (base `ba788d0`, temporary copies, `node`-level):
  - `return {accepted:true,value:{...value,mint:[]}}` in `step` — build,
    build --check, gate, gate --selftest all exit 0 (defect survived).
  - `value:entry.value` → `value:0` (both refund sites) — same, all exit 0.
  - six fabricated `{id}` rows — naming checker accepted all six, 30/30
    "executed".
  - `theoremReport` — `termination` exhibited=10 while only 2 of 10 accepted
    rows have a terminal before-leaf (8 vacuous passes counted as exhibited).
- GREEN controls (candidate, temporary copies):
  - dropped-mint mutant — `node simulator/gate.mjs` exit 1,
    `corpus mint/GA01-insert-absent-accepted`.
  - zeroed-refund mutant — exit 1, `corpus refund/GA03-update-active-accepted`.
  - `build`/`build --check` still exit 0 on both mutants: expected and honest,
    they check page-build identity, not behavior. The gate is the detector.
  - fabricated id-only, duplicate, missing-observation, contradictory-verdict
    and contradictory-resolve rows — all rejected; the 24 valid exported rows
    pass with `executed: 0, boundary: 'evidence'`.
- Report on the candidate: 38 corpus cases (4 observing refunds), 7 codec,
  2 ada, 28 complement pairs (21 refused), 20 story steps, 7 controlled laws
  (each applicable>0, held===applicable), sections classified
  `ada/cases/codec: behavior`, `folds/keyedMintRows/transactions: evidence`,
  24 naming + 21 lifecycle rows inspected, model `343f7e23a13c`.

## Limits

- The corpus-level refund observation rests on the 4 accepted cases that pay;
  the ada rows add the destination-named control. If the Lean corpus ever
  stops exporting a refund case, `no corpus case observes a refund at all`
  fails rather than passing quietly.
- Mint expectations are derived from the transcription's R2 delta table; the
  table itself is anchored to Lean through the accepted cases' end states, the
  keyed evidence rows, and the fold controls — not re-proved here.
- `folds`/`keyedMintRows`/`transactions` are inspected as exported evidence;
  the gate does not claim to execute them, and the report says so.
- Transaction evidence checks cover the mint/claim identity and named-refusal
  fields; they do not re-derive the wire bytes.
- Local candidate only: no push, PR, audit, or acceptance claim. Parent owns
  publication and further staffing.
