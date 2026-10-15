# Coder brief, slice nine: refunds

The whole of slice nine for the writer, with its terminal condition. The binding and the limits are in the [mandate](../mandate.md); the design is the [economic design](../economics-design.md), sections "Every exit", "The rejection rule" and "The tags";
the statements and controls are in the [economics plan](../economics-plan.md), including the slice nine paragraph; the rows, including slices six, seven, seven-b, seven-c, eight-a and eight as built, are in the [model rows](../economics-models.md); the proof is the [gate](../gate.md), versions 4 and 5.
Read the constitution at `.specify/memory/constitution.md` and `AGENTS.md` before you start.

## Story

As a requester, I get back everything but the tip when my request is rejected, and everything it held when I retract it in the reclaim window; as a refund address that appears in several rejected requests of one batch, I receive exactly the sum owed to me, once; and nobody walks away with a live tag.

## The design this slice implements

The words of the decided design, as the design page states them:

> Registration rejected: treasury nothing; processor the tip; refund address R and the carrier ada (everything held except the tip). Registration retracted: nothing to the treasury or the processor; the refund address everything the request held, tip included, except the two tags.
> Every exit burns the trie-ready tag; the exits of a registration also burn the application tag.
> Rejections batch: each request is consumed and refunded once; refunds are summed per refund address.
> Retraction is signed by the refund address and admitted only in `[s + W_p, s + W_p + W_r)`.

Statements of the plan, with the planned names: statement 6, `rejection_refund_floor` (on rejection each refund address receives at least the sum, over its distinct rejected requests, of held minus declared tip, in lovelace) and `retraction_refund_floor` (on retraction it receives everything the request held except the two tags, which are burned); the second half of statement 7, `registration_cost_returned_on_exit` (the registration cost comes back on rejection and retraction, and never after a successful registration: the second part is slice ten's); and the supporting statement `refunds_sum_per_address`. The first half of statement 7 and statements 10 to 12 are slice ten's.

## What exists, and the rule for it

Slice eight modelled the ruled rejection as a separate economic judgement (`Singular/Economics/`: the observed economic transaction beside `Tx`, the observation of unspent outputs with their pending contents, `rejectionAccepted`, the request address's spending arms with `requestAddressSpend`, and the world constructor for an admitted rejection), with no refund or lovelace obligation: "Refund obligations are absent until slice nine". The retraction exit exists in the model only as the legacy evidence-free exit of the registry (`retractAdmission`, `exitStep`); there is no economic judgement of a retraction yet, and the fold and retraction arms of `requestAddressSpend` certify only a spending and tag prerequisite. The legacy declarations, the driver and the old exit payments stay byte-identical, named as legacy in slice eight; nothing old is weakened or counted as evidence for a statement of this slice.

This slice therefore adds two things beside what exists, never into the facades or the legacy path: the refund obligations of the accepted rejection, and the accepted retraction judgement with its own refunds.

1. **Rejection refunds.** Extend the observed economic transaction and the accepted rejection judgement: the transaction pays each refund address at least held minus the declared tip of each of its distinct rejected requests, in lovelace, summed per address; the registration cost and the carrier ada are inside that sum; the tip goes to the processor and is not part of the refund; a refund observed short of the sum, crossed to another address or counted twice for one request refuses the whole batch.
2. **The accepted retraction.** A judgement over a transaction and the unspent set, in the same style as `rejectionAccepted`: it spends one pending registration (never a termination, never a request not in the pending pool, never a request spent twice), is signed by that request's refund address, has its whole validity interval inside the reclaim window of the request's booked time, returns everything the request held except the two tags to its refund address (tip included, registration cost included), burns the trie-ready tag and the application tag in the same transaction (a retraction that carries a tag out alive is refused), spends no state output and reads none, and removes the request from the pending pool. Add its world constructor and the proof cases for the earlier induction proofs (statement text of earlier statements unchanged).
3. **The statements** over accepted transactions in reachable worlds, never over what a builder produces: the planned ones above, each with no vacuous arm (a production trace reaches each negative arm), standard axioms only.

Refunds are in lovelace only; native assets other than the two tags are excluded by the exact-contents rule already, and the model does not claim a ledger minimum for any output.

## Names and homes

Use the agreed names (plan section "Names": trie-ready tag, application tag, singular tag, state token). New declarations go in the modules of their kind in modules of a few hundred lines (`Singular/Economics/` for the judgement and its observations, `Singular/Statements/` by property), never into `Model.lean`, `Lemmas.lean`, `Statements.lean` or other facades. The corpus rows go in the economic corpus modules (`lean/Main/Economics.lean` and its siblings). Main's declarations and names are untouched. If a statement of an earlier slice changes identity (its text changes), that is an uncovered restatement appended to the restatement record and every generated consumer follows; search by digest and by text the handwritten consumers (`conformance/lib/Conformance/Lean/Registration.hs`, `Retirement.hs`, `conformance/test/Conformance/Support/Binding.hs`) and the protected coverage base record before the first checkpoint, list the hits, and file a question; do not edit them unasked.

## Seat

| Field | Value |
|---|---|
| Role | writer for slice nine |
| Launcher | `codex --dangerously-bypass-approvals-and-sandbox -C /code/singular-issue-494 -m gpt-6-astra -c model_reasoning_effort=high` |
| Branch and base | `feat/494-protected-rejection-rule`, from the commit named in the runtime brief |
| Auditor | Codex `gpt-6.1-sol` (high effort) in a read-only detached worktree, mute, beside you from your first run; you never address it |
| Commit authority | Local commits on the branch only; no push, no rebase onto main, no comment on GitHub |

You are not alone in the codebase; do not revert edits made by others. Write no `Co-Authored-By` and no attribution of any kind in a commit, whatever a harness reminder says. Name things in plain words; coin no abbreviation.

Every cabal build, cabal test, nix run or nix build gate row and packaged control that you start runs inside `systemd-run --user --scope --quiet -p MemoryMax=12G -p MemorySwapMax=0 -- timeout <seconds> <command>` with standard input from `/dev/null` (operator rule of 15 October 2026; 900 seconds for a single row, 1800 for the repository aggregate). If a row legitimately needs more, do not raise the cap: file a question with the evidence. A test you write has no free-running producer thread, a byte cap and a deadline on every read loop, and a timeout on every wait.

## The task

1. Failing controls first, committed alone on the base and kept as your red evidence. Each is a transaction the model must judge, with the reason it must be judged for; a control that cannot be evaluated before the new judgement exists is recorded as such per row, and a rename or a move has no behavioural red. The lawful ones are controls too (accepted).
   - the lawful rejection batch with its refunds, a refund address appearing in two requests of one batch (one output summing both), and a lawful retraction inside the reclaim window with its full refund;
   - a reused refund: one refund output counted for two rejected requests of different addresses, or for one request twice (refused);
   - a refund short of held minus tip on a rejection, by one lovelace, and a refund to another address (refused);
   - a retraction that carries a tag out alive, a retraction outside the reclaim window (before it or at its end), a retraction not signed by the refund address, a retraction of a request not pending, of a termination, or of a request already spent, and a retraction that spends or reads the state output (each refused for the reason that names it);
   - the registration cost missing from a refund (refused).
2. Model the refund obligations and the retraction judgement with its world constructor; state and prove the statements. End with the statement list: for each, its fully qualified name, the `AXIOMS` line `#audit_statements report` prints for it, and the revision it was printed at.
3. Regenerate every copy the change moves (corpora, theorem register and digests, theorem page and its speech and audio, simulator mirror, application corpus, coverage record). A new identity starts uncovered and is appended to the restatement table, never edited. Restate nothing by hand that a tool regenerates.
4. List in the record what slice ten (folds, the registration cost to the treasury on a fold, the processor's exact take) must follow, and any conformance row or published text that mentions the old retraction or refund path (you change none of them).

The tasks, by name, are those of slice nine in the [tasks](../tasks.md).

## Checkpoints

Journal `REVIEW-REQUESTED` with the commit and the evidence path at each of these; continue only when the previous is approved or I say so: (1) the failing controls committed alone and the first note (what you reuse of slice eight's observation types and what you add, the shape of the retraction judgement and the refund observation, the proof cases the world constructor needs, the answer on which earlier statements could change text, the hits of the digest-and-text search); I approve the shape before you write it; (2) the refund obligations and the retraction judgement green; (3) the statements green; (4) the final head. Whatever cannot go green in separate steps because the controls are active is one combined checkpoint: say so in the first note and I decide.

## Gate

The slice nine rows of the [gate](../gate.md), versions 4 and 5: the "always" rows once per checkpoint, the final rows and `nix develop --quiet -c just ci` once on the final head without a time limit shorter than the aggregate. The batch row and the wrong-reason control apply only to slices that change a request or a question the transport reaches: this slice changes neither, say so in the record. A slice that runs for hours without a product commit is cut again: say so in a note.

## Terminal condition

Stop at the first of: every slice nine gate command exits as the gate states on a clean committed head (`PROOF-COMPLETE` with the commit, the receipts and the statement list); a question you cannot decide from the mandate and the design (file it as `questions/Q-NNN-<slug>.md`, written before you journal `BLOCKED`, with the user story of each option); capacity (`COMPLETE capacity-limit` with a handoff that makes the remainder mechanical). Do not stop for any other reason, and do not touch anything listed under the files this ticket must not touch.
