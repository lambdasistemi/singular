# Focused Opus re-review: #494 protected-rejection repair

This was one read-only pass over `repair.diff` and the definitions it depends on. I did not build, prove, replay, run mutants or recompute hashes. All execution results below are the author's.

## Remaining blockers

**None** under the brief's rulings. One new issue needs to be stated explicitly before external review:

### N1: Medium. The F1 fix newly breaks the existing live retraction comparison
- **Where:** the decoder now requires booking metadata on retraction requests (`candidate/conformance/lean/DriverTransport.lean:194-195`). Retraction now reads `r.submittedAt` (`candidate/lean/Singular/Model.lean:1291`).
- **Who is affected:** the live harness builds the request in `candidate/conformance/app/Conformance/Run/Live.hs:2192-2206`. It sends no `submittedAt` or `registryId`; the booking time travels only in the witness (`Live.hs:1960-1967`). `askModel` (`Live.hs:3220-3236`) sends that request with exit `retract`.
- **Trigger:** any live retraction story, including the retract-outside-window receipt. Its question now fails decoding. If the decoder were loosened instead, the request time would default to 0 and a chain-accepted retraction would be answered `not-phase2`.
- **What the documents claim:** the constitution's `retract` row still describes the live witness as carrying `submitted_at` and points to the live retract receipt. The general limit ("Live protocol-6 callers require explicit migration", constitution lines 26-28) covers this only implicitly. README:99-110 and the review-followup F2 entry talk about reject callers, not the previously working retraction path.
- **Ruling:** the brief defers live caller migration, so this does not block. But this change breaks a live comparison that #494 never touched before, and no document says so.
- **Fix (either):**
  - add to README and review-followup that live retraction comparisons are held until the request encoder is migrated; or
  - make the small consumer change: emit `submittedAt` (already computed by `requestDatumOf`) and `registryId` in the `Live.hs` request object.

## Prior findings

| # | Disposition | Source check |
|---|---|---|
| **F1** two submission times | **Resolved** | `inPhase2 c r w` reads only `r.submittedAt` (`Model.lean:1279-1281`). `RetractWitness.submittedAt` is not read anywhere in admission. `retract_admitted_iff` and `retract_refusal_first_failing` now quantify over `r.submittedAt`. `expiry_after_reclaim` (Statements diff 395-404) follows from the two characterizations over the same `s`, giving `rw.validTo ≤ jw.validFrom` with no extra premise. Edges never change `processTime` or `retractTime`, so tying both admissions to one `s` is enough. Both new rows are discriminating against the timestamp mutant: with booked time 10000 and witness time 11000, the window [12000,12001) is outside [11000,11500] (refused); with witness time 0, the window [11000,11500) is accepted. |
| **F2** live harness not migrated | **Declared limit, accepted per brief.** N1 is a further consequence. | |
| **F3** zero defaults | **Resolved on the protected paths** | Explicit checks cover: request time and identity on single reject and retract; `start.config.registryId` on reject, rejectBatch and processBatch-reject; and the evidence's `registry.registryId`, `request.submittedAt`, `request.registryId` and top-level `registryId` (`DriverTransport.lean:93-110, 194-197, 273-275, 290-291`). `fromJson? : Nat` fails on null, so null is refused as well as absence. The checks are needed: `Config`'s `FromJson` still defaults `registryId` to 0 (`Model.lean:213-215`), and `toRequest` still uses `optionalNat`, both correctly kept for fold and setup. |
| **F4** no batch theorem | **Resolved** | `process_actions_split` handles an arbitrary prefix by induction. `process_actions_reject_admitted` and `process_batch_reject_admitted` give admission at the prefix's actual state, with the witness rebuilt exactly as `processAction` builds it (`Model.lean:1387-1393`). `process_batch_live_compatible_protected` lifts the single-request theorem and covers `e = none`; its `hp` premise is not vacuous. `rejectBatchStep` now delegates to `processActions` (`Driver.lean:473-479`), and `runRejectBatch` calls it (`Driver.lean:540`). `reject_batch_execution` is only an unfolding, but it is the right binding. Combined with `process_actions_reject_admitted`, it gives per-position admission for all-reject batches; no named corollary does this, which is cosmetic. Behaviour is unchanged: the common interval equals every witness's interval after the `eraseDups` check, `combineResults` still concatenates `paid` left to right, and an empty list still gives `emptyResult`. |
| **F5** Boolean equality | **Resolved** | Admission uses `decide (… ≠ …)` (`Model.lean:1328, 1330`), and `rejection_admitted_iff` states `=`. Whatever the `DecidableEq` instance is, `decide` is sound, so structural equality really is proved. |
| **F6** coverage | **Addressed within stated bounds** | New controls exist for a request from another registry, a mixed-batch mint mismatch, and mutants for request-registry identity, the booked retraction time and the mixed mint claim. The mutant search strings match the candidate source verbatim (`Model.lean:1291, 1327-1328, 1412`), and each new row discriminates on hand evaluation. README now says the Python oracle uses tables parsed from the same model and assumes legal fold inputs. Still true: no transport or `rejectBatchStep` mutants (disclosed). |
| **F7** ignored witness | **Resolved** | A `rejection` on any non-reject exit now raises an error (`DriverTransport.lean:199-202`), and `check_transport.py` exercises this. |

## Minor notes (not blockers)
- The 14 metadata controls in `check_transport.py` accept any stderr containing "expected", "not found" or "unknown field". So they show that decoding fails, not which check failed. That is acceptable, because the explicit `require*` calls run before the field defaults could apply.
- The simulator mirror has the same new signatures and definitions at the points I grepped (`simulator/formal/Model.lean:1279, 1328`, `Driver.lean:473-479`, `Statements.lean:2093-2164`). I did not diff the whole mirror.

## Ready for external review?
**Yes, for the model-only slice,** provided N1 is disclosed or the live encoder is fixed. In the source I read, every requested property holds:
- the booked timestamp decides both exits;
- `expiry_after_reclaim`;
- protection after an arbitrary prefix;
- the all-reject batch shares the same engine;
- structural evidence binding;
- missing or null metadata is refused.

## Coverage and limits
- **Read:** `brief.md`, `prior-review.md`, all of `repair.diff`; the candidate `Model.lean` definitions for `Result`, `Config` JSON decoding, retraction, rejection, `processAction(s)` and `processBatch`; `Driver.lean:455-555`; the `rejection_admitted_iff` and `live_compatible_request_protected` proofs; `DriverTransport.lean:30-310`; the README limits; the constitution's sync report; the `DriverMain` fixtures; and the retraction and model-question paths in `Live.hs`.
- **Not read:** `AGENTS.md`, `decisions.md` beyond the diff, the corpus JSON bodies, `manifest.json` hashes, and hosted CI configuration.
- **Not executed:** anything. Whether `grind`, `simp_all` and `omega` close the goals rests on the author's green `lake build` and their 79-declaration standard-axiom audit. Pass counts for the mutants, the 83 rows and the 14 controls are the author's receipts.
- **Not inferred:** merge, CI or live acceptance. #361, #500 and the declared non-goals are out of scope.
