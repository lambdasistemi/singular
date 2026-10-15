# Coder brief, slice ten: folds

The whole of slice ten for the writer, with its terminal condition. It is the last Lean slice of the economic model; the paper is written after it, from the finished model. The binding and the limits are in the [mandate](../mandate.md); the design is the [economic design](../economics-design.md), sections "Registry parameters", "The two requests", "The tags", "Every exit" and "What the paper may state";
the statements and controls are in the [economics plan](../economics-plan.md), including the slice ten paragraph and its section "Names"; the rows, including slices six to nine as built and what slice ten "must follow" in the slice seven section, are in the [model rows](../economics-models.md); the decisions are in [decisions](../decisions.md); the proof is the [gate](../gate.md), versions 4 and 5.
Read the constitution at `.specify/memory/constitution.md` and `AGENTS.md` before you start.

## Story

As the treasury, I receive at least the registration cost for each key registered and everything but the tip of each key terminated; as a processor, I take exactly the tip each request declared and nothing more; as a requester with a booked termination, I see that it can always be folded, whenever a folder accepts its tip; and nobody keeps a live tag.

## The design this slice implements

The words of the decided design, as the design page states them:

> A registration may be folded only in `[s, s + W_p)`. A termination has no window: everything the fold checks for a termination is fixed at booking.
> Registration folded: the treasury receives R; the processor the tip; the destination the singular tag with its carrier ada; no refund. Termination folded: the treasury everything except the tip; the processor the tip.
> Tag flow per exit: registration fold burns the trie-ready tag and the application tag and mints the singular tag at the destination; termination fold burns the trie-ready tag and the singular tag.
> A fold of n registrations and m terminations donates at least n·R plus the sum, over the m terminations, of (held − tip).
> Across a batch, what the processors can take is at most the sum of the tips. This needs a balance relation with no outside funding.
> A booked termination can be folded at any later time, as long as some folder accepts its tip and ledger fees stay inside the envelope the tip was sized for.

The statements of the plan, with the planned names: statement 7, first half, `fold_donates_registration_cost` (an accepted fold registering n keys donates at least n times the registration cost; the second half, the cost returned on exit, is slice nine's and done); statement 10, `only_booked_terminations_fold` (restated on 15 October 2026: only a booked termination folds, and a booked termination carries its key's genuine singular tag); statement 11, `booked_termination_foldable`; statement 12, `processors_take_at_most_the_tips`; and the supporting statements `fold_routes_every_amount` and `tag_supplies_equal_pending` (the supply of the trie-ready tag equals the count of pending requests, of the application tag the count of pending registrations). The processor takes exactly the declared tip: state it inside the routing statement. Statement 13 (the minimum tip covers the measured cost) is not a Lean statement.

## What exists, and the rule for it

Slice eight and nine modelled the ruled rejection and retraction as separate economic judgements over the observed economic transaction beside `Tx` (`Singular/Economics/`: `rejectionAccepted`, `retractionAccepted`, the refund obligations, the request address's spending arms, the world constructors), with no fold, no donation and no processor take. The registry's fold exists in the model as the legacy fold (`step`, `foldBatch`, `admittedFoldBatch`, `foldAdmission` with the processing window of every request, the transaction builder `buildFold`, in the child modules of `Singular/Model/` after slice eight-a), unchanged; its statements (preservation, inversions, transaction rows) are on main or on this branch and keep their text. Slice eight's statement `rejection_cannot_invalidate_fold` preserves the legacy admitted fold and its needed unspent outputs and "does not implement this future economic fold judgement". The world (registry state, pending registrations, pending terminations) and `WorldReachable` already have booking, rejection and retraction constructors.

This slice adds the economic fold beside what exists, never into the facades and never by editing the legacy fold:

1. **The economic fold judgement** over an observed economic transaction and the unspent set: it spends the registry state output (the only judgement that does), applies the registry's own fold transition of the model to the batch of consumed pending requests (the registry's root update and token movements are the existing fold's, reused, not re-derived; the economic judgement must be shown consistent with the legacy fold's accepted result for the same batch), and consumes pending requests by reference with their full observed contents. A registration is admitted only inside its processing window (the transaction's validity upper bound at or before the booked time plus the processing window, the existing `inPhase1` reading) and only if its trie-ready tag and application tag are present and burned; a termination has no window, burns its trie-ready tag and its singular tag, and its leaf becomes terminal. Each consumed request is consumed once; a mixed batch of registrations and terminations is allowed where the registry's own batch law allows it; any refused member refuses the whole transaction.
2. **Routing.** Registration: the registration cost to the treasury (the transaction's donation), the declared tip to the processor, the carrier ada to the destination output that carries the minted singular tag; nothing to a refund address. Termination: held minus the declared tip to the treasury, the declared tip to the processor. The processor takes exactly the declared tip of each consumed request: not more, not less. Value is conserved: the observed balance relation of slice five (`balanced`) holds for the transaction with the ledger fee paid from the processors' own funding, never from a request's value; no outside funding is assumed.
3. **Tag flow and supply.** Registration fold: trie-ready and application tags burned, the singular tag minted at the destination; termination fold: trie-ready and singular tags burned. No tag is carried out alive. `tag_supplies_equal_pending`, over reachable worlds with all four transitions.
4. **The world.** Add the fold constructors to `WorldReachable` (the registry component moves by the fold's own transition; the pending pools lose the consumed requests; the treasury's total grows by the donation) and the proof cases to the earlier induction proofs (statement text of earlier statements unchanged; any statement whose text must change is an uncovered restatement appended to the restatement record). The world-supply law that slice seven proved for pending terminations is reproved for the remaining requests after a termination fold.
5. **Availability of a booked termination.** `booked_termination_foldable`: for a pending termination in a reachable world and any later time, there is a transaction that the economic fold judgement accepts, provided the processor's declared funding accepts the tip and the ledger fee is at most the declared tip (the fee envelope is an explicit hypothesis, not an assumption about the ledger); a registration's window does not apply. This is existence over the model, not a claim about a builder or a ledger.
6. **The constitution.** The task `amendment-economics`: the 1.18.0 entry of `.specify/memory/constitution.md` states the economic rows in the translation (one release, one entry): the economic model's rows for booking, rejection, retraction and fold as the Lean model states them, in the entry's own style, saying plainly that the legacy rows (reject, rejectBatch, paid, tx as the deployed validators follow them) are superseded by the ruled rows and that the live rows stay unmet until the validators meet them. Write the proposed text in the first note and wait for my approval; then apply it. The model checker's reconciliation of the version string and the declared names must pass.

The refund and retraction judgements, the legacy fold, retraction and rejection, the driver, the transport and main's declarations are not changed.

## Names and homes

Use the agreed names (plan section "Names"). New declarations go in the modules of their kind in modules of a few hundred lines (`Singular/Economics/` for the judgement, its observations and routing, `Singular/Lemmas/` for helper theorems, `Singular/Statements/` by property: helper theorems never under `Statements/`, the extractor treats every theorem there as public), never into `Model.lean`, `Lemmas.lean`, `Statements.lean` or other facades. The corpus rows go in the economic corpus modules (`lean/Main/Economics.lean` and its siblings). Main's declarations and names are untouched. Search by digest and by text the handwritten consumers (`conformance/lib/Conformance/Lean/Registration.hs`, `Retirement.hs`, `conformance/test/Conformance/Support/Binding.hs`) and the protected coverage base record before the first checkpoint, list the hits, and file a question; do not edit them unasked.

## Seat

| Field | Value |
|---|---|
| Role | writer for slice ten |
| Launcher | `codex --dangerously-bypass-approvals-and-sandbox -C /code/singular-issue-494 -m gpt-6-astra -c model_reasoning_effort=high` |
| Branch and base | `feat/494-protected-rejection-rule`, from the commit named in the runtime brief |
| Auditor | Codex `gpt-6.1-sol` (high effort) in a read-only detached worktree, mute, beside you from your first run; you never address it |
| Commit authority | Local commits on the branch only; no push, no rebase onto main, no comment on GitHub |

You are not alone in the codebase; do not revert edits made by others. Write no `Co-Authored-By` and no attribution of any kind in a commit, whatever a harness reminder says. Name things in plain words; coin no abbreviation.

Every cabal build, cabal test, nix run or nix build gate row and packaged control that you start runs inside `systemd-run --user --scope --quiet -p MemoryMax=12G -p MemorySwapMax=0 -- timeout <seconds> <command>` with standard input from `/dev/null` (operator rule of 15 October 2026; 900 seconds for a single row, 1800 for the repository aggregate). If a row legitimately needs more, do not raise the cap: file a question with the evidence. A test you write has no free-running producer thread, a byte cap and a deadline on every read loop, and a timeout on every wait.

## The task

1. Failing controls first, committed alone on the base and kept as your red evidence. Each is a transaction the model must judge, with the reason it must be judged for; a control that cannot be evaluated before the new judgement exists is recorded as such per row, and a rename or a move has no behavioural red. The lawful ones are controls too (accepted).
   - lawful folds: one registration inside its window; one termination at a later time; a mixed batch; a batch of several registrations (the donation counts each key once);
   - a termination stranded by a check made at fold time: a termination refused for a window, a clock or an expiry it does not have;
   - one donation counted for many keys (a fold registering n keys donating less than n times the cost);
   - a registration whose application tag is forged or absent, a registration outside its processing window (refused `not-phase1` or the judgement's own reason);
   - an unbalanced fold (value created or destroyed), a ledger fee paid from a request's value, the processor taking more or less than the declared tip;
   - a fold that carries a tag out alive; a tagged request spent through the sweep arm; a request consumed twice; a fold that does not spend the state output.
2. Model the judgement, the routing, the tag flow and the world constructors; state and prove the statements. End with the statement list: for each, its fully qualified name, the `AXIOMS` line `#audit_statements report` prints for it, and the revision it was printed at.
3. The constitution rows (item 6 above), after my approval of your text.
4. Regenerate every copy the change moves (corpora, theorem register and digests, theorem page and its speech and audio, simulator mirror, application corpus, coverage record). A new identity starts uncovered and is appended to the restatement table, never edited. Restate nothing by hand that a tool regenerates.
5. List in the record what the paper must cite (each statement by fully qualified name, revision and axiom line), the limits of each statement (what the model does not say: no ledger minimum, no fee market, no flood price), the conformance rows and published texts that still describe the superseded fold, rejection and retraction, and the open items that remain (adapting open-datum, adapting cardano-keri, the measured values of the registration cost, the minimum tip and the booking width).

The tasks, by name, are those of slice ten in the [tasks](../tasks.md).

## Checkpoints

Journal `REVIEW-REQUESTED` with the commit and the evidence path at each of these; continue only when the previous is approved or I say so: (1) the failing controls committed alone and the first note (what you reuse of slices eight and nine and what you add; how the economic fold ties the registry's own fold transition to the observed economic transaction and why it is consistent with the legacy fold; the routing and the balance relation, in particular how the processor's take and the fee are defined; the shape of the foldability statement and its fee hypothesis; the proof cases the world constructors need; which earlier statements could change text; the hits of the digest-and-text search); I approve the shape before you write it; (2) the registration fold, the termination fold, the routing and the world constructors green with the proof cases; (3) the statements green; (4) the constitution rows (text approved by me first); (5) the final head. Whatever cannot go green in separate steps because the controls are active is one combined checkpoint: say so in the first note and I decide.

## Gate

The slice ten rows of the [gate](../gate.md), versions 4 and 5: the "always" rows once per checkpoint, the final rows and `nix develop --quiet -c just ci` once on the final head without a time limit shorter than the aggregate. The batch row and the wrong-reason control apply only to slices that change a request or a question the transport reaches: this slice changes neither, say so in the record. A slice that runs for hours without a product commit is cut again: say so in a note.

## Terminal condition

Stop at the first of: every slice ten gate command exits as the gate states on a clean committed head (`PROOF-COMPLETE` with the commit, the receipts and the statement list); a question you cannot decide from the mandate and the design (file it as `questions/Q-NNN-<slug>.md`, written before you journal `BLOCKED`, with the user story of each option); capacity (`COMPLETE capacity-limit` with a handoff that makes the remainder mechanical). Do not stop for any other reason, and do not touch anything listed under the files this ticket must not touch.
