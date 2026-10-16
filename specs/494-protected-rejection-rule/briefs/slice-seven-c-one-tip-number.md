# Coder brief, slice seven-c: one tip number

The whole of slice seven-c for the writer, with its terminal condition. The binding and the limits are in the [mandate](../mandate.md); the design is the [economic design](../economics-design.md);
the statements and controls are in the [economics plan](../economics-plan.md), including the slice seven-c paragraph and the first of its decisions taken; the rows, including the planned rows of this slice,
are in the [model rows](../economics-models.md); the decisions are in [decisions](../decisions.md); the proof is the [gate](../gate.md), versions 4 and 5. Read the constitution at
`.specify/memory/constitution.md` and `AGENTS.md` before you start.

## Story

As a registry creator, I pin one number, the floor on the tip a requester declares, and I see it in the state's existing field; as a processor, I take exactly the tip the request declares; as a consumer reading
the conformance page, I see which tip rows the deployed validators do not yet meet and why, and no row counts the old behaviour as meeting the ruled design.

## The ruling this slice implements

The operator, 15 October 2026: the fee pin is retired; the minimum tip replaces it in the same state field; the state keeps its shape and only the field's meaning changes. The processor takes exactly the
declared tip. The validators follow after Demo 1 with the rest of protected rejection; this slice states the ruling in the model and touches no validator, builder or command. The epic owner's answer on the plan
fixed: one field named the minimum tip in Lean, written under the existing wire key `maxFee` until the public rename ticket named at acceptance, so the chain datum, the off-chain code, the corpora of unchanged rows
and the transport read what they read today; retirements by append-only restatement rows; a live row whose expectation changes under the new meaning is published unmet by ruling with the tripwire of slice
eight-c, never as a pass; a row that keeps passing is not touched.

## What changes, and what does not

1. **One field.** The configuration (`lean/Singular/Model/Registry.lean`) carries one tip number, `minimumTip`, written under the key `maxFee` (always written, as that key always was) and read from it. The
   key `minimumTip` of slice five and the second field disappear from the written form. Old input that has the key `maxFee` reads as the minimum tip; the other economic fields (registration cost, booking
   width) keep their omit-at-zero rule. The booking judgements of slices six and seven already read the minimum tip; they now read the one field.
2. **One pin preserved.** `onlyRootChanged` and the statement that every fold preserves the parameters keep the one tip number.
3. **The tip cover is retired.** The predicate `lovelaceCoversTip` (`lean/Singular/Model/Routing.lean`), the hypothesis and the conjunct that use it in `insert_active_transaction_row`
   (`Statements/RegistrationTransaction.lean`) and `update_terminal_transaction_row` (`Statements/TerminationTransaction.lean`), the proofs' use of it, the two fields of the corpus transaction rows that carry it
   (`tip` and `lovelaceCoversTip`, `lean/Main/Transactions.lean`) and the check that throws when it is not covered (`lean/Main.lean`) go. Each retired or restated identity is named in an appended row of the
   restatement record (`conformance/coverage/protected-rejection-restatement.md`, append only). A restated statement says at least what it said without the retired premise and conjunct: the hypothesis was an echo
   of the conjunct, so dropping both is a strengthening; show that by the proof, not by prose.
4. **The two scenario rows about the old fee pin** ("the old fee pin does not constrain booking" and "the old fee pin is independent of the minimum tip", `lean/Main.lean`) go. The single-number rule is stated by
   the booking rows that already refuse a tip below the minimum; add the rows that show it on the one field, for a registration and for a termination, at the floor (accepted) and below it (refused).
5. **The transaction baseline and its check follow.** `lean/transaction-baseline.json` is this branch's own accepted state (rows at `63edf08d` plus six fold witness inputs). The retired fields are removed
   from its rows by the narrowest change: every other field of every row stays byte for byte; `tools/check_model.py`'s compatibility check names the retired field names as an explicit, listed exception (not a
   general loosening) and still fails if any other field of any row changes; show it failing on a planted change of one output field. Propose the exact mechanism at the first checkpoint; I decide.
6. **The consumers of a `lean/` change are found and listed by search, not by memory.** Search the repository for `lovelaceCoversTip`, `maxFee` and `minimumTip` (including `conformance/test/Conformance/Support/Binding.hs`,
   which binds Lean statement conjuncts by their text, `conformance/rows.json`, `BOOK.md`, `docs/`, the simulator mirror and its scripts, the application corpus under `applications/open-datum`,
   `lean/M1Main.lean`, `lean/DriverMain/Fixtures.lean`, `lean/Singular/Naming.lean` and `lean/Main/Base.lean`) and classify every hit at the first checkpoint: unchanged (wire key), text changes, or a live row whose
   expectation changes under the new meaning (then unmet by ruling). The general control `wrong-fee` (it bumps the pinned number in a question and expects the chain and the model to disagree) and the tip fields of
   the transaction baseline are named explicitly. A published conformance row that changes is published unmet by ruling ("implementation follows the superseded rule; the ruled rule is not implemented") with
   the existing unmet-by-ruling mechanism, never as a pass; the tripwire that ends the unmet state is slice eight-c's. If a hit needs a change in a file the touch list does not name, stop and file a question.
7. **What does not change.** The chain datum and every off-chain reader of `maxFee`; main's names (the `maxFee` key, `Approval`, `approvalAssetName`, the exit names, `wrong-fee`); the validators, builders and
   command line; the fold's behaviour beyond the removed echo; the tag vocabulary (slice seven-b); the driver protocol version unless a declared question's written form changes (say so at the first checkpoint).

## Names and homes

Declarations stay where slice eight-a put them: the configuration in `lean/Singular/Model/Registry.lean`, the fold model's routing in `lean/Singular/Model/Routing.lean`, the statements in `lean/Singular/Statements/`
(the touch list, section "Slices inserted on 15 October 2026"). Do not add to the facade files `Model.lean`, `Lemmas.lean` and `Statements.lean`.

## Seat

| Field | Value |
|---|---|
| Role | writer for slice seven-c |
| Launcher | `codex --dangerously-bypass-approvals-and-sandbox -C /code/singular-issue-494 -m gpt-6-astra -c model_reasoning_effort=high` |
| Branch and base | `feat/494-protected-rejection-rule`, from the commit named in the runtime brief |
| Auditor | Codex `gpt-6.1-sol` (high effort) in a read-only detached worktree, mute, beside you from your first run; you never address it |
| Commit authority | Local commits on the branch only; no push, no rebase onto main, no comment on GitHub |

You are not alone in the codebase; do not revert edits made by others. Write no `Co-Authored-By` and no attribution of any kind in a commit, whatever a harness reminder says. Name things in
plain words; coin no abbreviation.

Every cabal build, cabal test, nix run or nix build gate row and packaged control that you start runs inside
`systemd-run --user --scope --quiet -p MemoryMax=12G -p MemorySwapMax=0 -- timeout <seconds> <command>` with standard input from `/dev/null` (operator rule of 15 October 2026; 900 seconds for a single row,
1800 for the repository aggregate). If a row legitimately needs more, do not raise the cap: file a question with the evidence. A test you write has no free-running producer thread, a byte cap and a deadline
on every read loop, and a timeout on every wait.

## The task

1. Failing controls first, committed alone on the base and kept as your red evidence. Each fails for the intended reason; a control that cannot be evaluated before the change is recorded as such per row.
   - a state written with the key `maxFee` only (value five) decodes with minimum tip five, and a registration booking and a termination booking with a declared tip of four are refused (`dirty-request`); on the base both
     are accepted, because the booking reads another field;
   - a configuration with minimum tip three is written with the key `maxFee` equal to three and without the key `minimumTip`, and reads back equal; the base writes the other key;
   - a fold transaction row built for a request input whose lovelace is below the old pin is still built (the base refuses it with "Transaction correspondence tip not covered");
   - a fold that changes the minimum tip fails the pins-preserved check (the lawful fold passes).
2. Make the change as above and restate the two transaction-row statements; state and prove, from the standard axioms alone, the restated statements and the preservation of the one pin, and end with the statement
   list: for each, its fully qualified name, the `AXIOMS` line `#audit_statements report` prints for it, and the revision it was printed at.
3. Regenerate every copy the change moves (corpora, theorem register and digests, theorem page and its speech and audio, simulator mirror, application corpus, coverage record). A new identity starts uncovered and is
   appended to the restatement table, never edited.
4. Before the final head, run the consumers of a `lean/` change once each and record exit and time: the model check, the transaction baseline check, the simulator check, the application corpus, the coverage gate and its
   real-tree tests, and the conformance commands that need no devnet (build of the app and the tests, the packaged tests, `conformance -- list`).
5. List in the record what slice ten (the processor takes exactly the declared tip) and slice eight-c (the tripwire) must follow, and every conformance row or published text you changed or marked unmet.

The tasks, by name, are those of slice seven-c in the [tasks](../tasks.md).

## Checkpoints

Journal `REVIEW-REQUESTED` with the commit and the evidence path at each of these; continue only when the previous is approved or I say so: (1) the failing controls committed alone and the first note (the classified list of
consumers, the mechanism proposed for the baseline and its check, the answer on the driver protocol version); (2) the change, the restated statements, the controls and the regeneration green with the always rows;
(3) the consumers of a `lean/` change run once, and the final head (the final rows and `nix develop --quiet -c just ci` once).

## Gate

The slice seven-c rows of the [gate](../gate.md), version 5: the "always" rows once per checkpoint, the conformance commands that need no devnet, the wrong-reason control, the final rows and `nix develop --quiet -c just ci`
once on the final head without a time limit shorter than the aggregate (about twenty-five minutes). A slice that runs for hours without a product commit is cut again: say so in a note.

## Terminal condition

Stop at the first of: every slice seven-c gate command exits as the gate states on a clean committed head (`PROOF-COMPLETE` with the commit, the receipts and the statement list); a question you cannot decide from the
mandate and the design (file it as `questions/Q-NNN-<slug>.md` with the user story of each option and journal `BLOCKED`); capacity (`COMPLETE capacity-limit` with a handoff that makes the remainder mechanical). Do not
stop for any other reason, and do not touch anything listed under the files this ticket must not touch.
