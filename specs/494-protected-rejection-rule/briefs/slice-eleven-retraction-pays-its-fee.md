# Coder brief, slice eleven: a retraction pays its ledger fee from ordinary funding

The whole of slice eleven for the writer, with its terminal condition. The binding and the limits are in the [mandate](../mandate.md); the design is the [economic design](../economics-design.md), sections "Every exit" and "The two requests", with the ruling of 16 October 2026 in the [decisions](../decisions.md); the statements and controls are in the [economics plan](../economics-plan.md), including the slice eleven paragraph; the rows, with slices six to ten as built, are in the [model rows](../economics-models.md); the proof is the [gate](../gate.md), versions 4, 5 and 6.
Read the constitution at `.specify/memory/constitution.md` and `AGENTS.md` before you start.

## Story

As a requester whose registration is still pending inside its reclaim window, I sign a retraction with my refund address and get back at least everything my request held, while my wallet pays the ledger fee; nobody else is paid, and the model can say that I am able to do this.

## The gap this slice closes

The accepted retraction (slice nine, `Singular/Economics/Retraction.lean`) refuses every transaction whose inputs are not exactly the one pending registration (the refusal `retract-single-request`) and requires the refund address to receive at least everything the request held. A transaction balances only if its inputs equal its outputs plus the donation plus the fee (`Singular/Economics/Transaction.lean`, `balanced`). With one input holding the whole held amount and an output of at least that amount, the fee must be zero, which no ledger admits. A request holding 3,000,000 lovelace under a fee of 170,000 lovelace has no balanced accepted retraction. The existing statement about the refund floor is true at that scope; no statement says a requester can retract.

## The ruling

Operator, 16 October 2026: the requester pays the retraction. A retraction may also spend the requester's ordinary outputs, which pay the ledger fee. The refund address receives at least everything the request held except the two tags; nobody else is paid; no tip is taken; nothing goes to the treasury.

## What changes

1. **The inputs of a retraction.** Exactly one input is a pending registration. Every other input is an ordinary output of the unspent set: it holds no state token, no trie-ready tag, no application tag and no singular tag (the classification the fold already uses, `foldOrdinary`, by actual token holdings and never by purpose), it is not at the request address, it is not the state output and it is not another request. Duplicate inputs and overlapping input and reference sets stay refused with their present reasons. An extra input that fails the rule is refused with a reason that names which part failed. A transaction with two pending requests, or with a pending termination, is refused as today.
2. **Unchanged:** the signature of the refund address; the whole validity interval inside the reclaim window of the booked time; the state output neither spent nor read; both request tags burned; the registry supply unchanged; the request leaves the pending pool; the refund floor (at least everything the request held except the two tags, tip included, summed at the refund address by actual output lovelace).
3. **Nobody else is paid.** No donation and no tip leave a retraction; what is not the refund and not the ledger fee goes to ordinary outputs, and the fee is paid from ordinary funds. This is a statement over accepted retractions.
4. **The requester can retract.** An availability statement in the style of the termination availability statement of slice ten: for a reachable world with a pending registration, a time inside its window, a refund address that signs, and ordinary funding that covers the fee, an accepted balanced retraction exists. The hypotheses are explicit and no vacuous arm remains. It is also the positive control: a retraction paying a positive fee is accepted.

Planned statements (the writer proposes the final names in the first note): the refund floor for retraction restated over the enlarged shape (its text changes, so its identity is new and uncovered and is appended to the restatement table, never edited); `retraction_pays_only_the_refund_and_the_fee`; `pending_registration_can_be_retracted`. Rejection and the fold are untouched.

## Names and homes

Use the agreed names (trie-ready tag, application tag, singular tag, state token). New declarations go in the modules of their kind in modules of a few hundred lines (`Singular/Economics/` for the judgement, `Singular/Statements/` by property), never into `Model.lean`, `Lemmas.lean`, `Statements.lean` or other facades. The corpus rows go in the economic corpus modules (`lean/Main/Economics.lean` and its siblings). Legacy declarations, the driver and the old exit payments stay byte-identical. If a statement of an earlier slice changes identity (its text changes), that is an uncovered restatement appended to the restatement record and every generated consumer follows; search by digest and by text the handwritten consumers (`conformance/lib/Conformance/Lean/Registration.hs`, `Retirement.hs`, `conformance/test/Conformance/Support/Binding.hs`) and the protected coverage base record before the first checkpoint, list the hits, and file a question; do not edit them unasked.

## Seat

| Field | Value |
|---|---|
| Role | writer for slice eleven |
| Launcher | `codex --dangerously-bypass-approvals-and-sandbox -C /code/singular-issue-494 -m gpt-6-astra -c model_reasoning_effort=high` |
| Branch and base | `feat/494-protected-rejection-rule`, from the commit named in the runtime brief |
| Auditor | Codex `gpt-6.1-sol` (high effort) in a read-only detached worktree, mute, beside you from your first run; you never address it |
| Commit authority | Local commits on the branch only; no push, no rebase onto main, no comment on GitHub |

You are not alone in the codebase; do not revert edits made by others. Write no `Co-Authored-By` and no attribution of any kind in a commit, whatever a harness reminder says. Name things in plain words; coin no abbreviation.

Every cabal build, cabal test, nix run or nix build gate row and packaged control that you start runs inside `systemd-run --user --scope --quiet -p MemoryMax=12G -p MemorySwapMax=0 -- timeout <seconds> <command>` with standard input from `/dev/null` (operator rule of 15 October 2026; 900 seconds for a single row, 1800 for the repository aggregate). If a row legitimately needs more, do not raise the cap: file a question with the evidence.

## The task

1. Failing controls first, committed alone on the base and kept as your red evidence. Each is a transaction the model must judge, with the reason it must be judged for; a control that cannot be evaluated before the new judgement exists is recorded as such per row.
   - a funded retraction with a positive fee: accepted (it is refused on the base for the single-request rule);
   - the same transaction with the fee one lovelace beyond the ordinary funding: refused;
   - an extra input holding any of the four tokens, an extra input at the request address, an extra input that is the state output, an extra input that is another request: each refused for the reason that names it;
   - a retraction that pays a donation, or leaves a tip to anyone: refused;
   - the existing controls of slice nine (a tag carried out alive, outside the window, not signed by the refund address, a request not pending, a termination, a state output spent or read) stay refused for their own reasons.
2. Widen the retraction judgement and its world constructor as above; state and prove the statements. End with the statement list: for each, its fully qualified name, the `AXIOMS` line `#audit_statements report` prints for it, and the revision it was printed at.
3. Propose, at checkpoint four, the wording of the constitution's economic rows for the retraction (the 1.18.0 entry and its "Ruled economic translation" table state the retraction as spending one observed pending registration and returning the whole held value; they must now state the ordinary funding and the fee). Do not edit the constitution before the owner approves the exact text.
4. Regenerate every copy the change moves (corpora, theorem register and digests, theorem page and its speech and audio, simulator mirror, application corpus, coverage record). A new identity starts uncovered and is appended to the restatement table, never edited. Restate nothing by hand that a tool regenerates.
5. List in the record any conformance row or published text that mentions the old retraction path (you change none of them).

The tasks, by name, are those of slice eleven in the [tasks](../tasks.md).

## Checkpoints

Journal `REVIEW-REQUESTED` with the commit and the evidence path at each of these; continue only when the previous is approved or the owner says so: (1) the failing controls committed alone and the first note (the shape of the widened judgement, the proof cases the world constructor needs, which earlier statements could change text, the hits of the digest-and-text search); the owner approves the shape before you write it; (2) the judgement green; (3) the statements green; (4) the constitution wording proposal and the final head with the regenerated copies.

## Gate

The slice eleven rows of the [gate](../gate.md), versions 4, 5 and 6: the "always" rows once per checkpoint, the final rows and `nix develop --quiet -c just ci` once on the final head without a time limit shorter than the aggregate. The batch row and the wrong-reason control apply only to slices that change a request or a question the transport reaches: this slice changes neither, say so in the record. A slice that runs for hours without a product commit is cut again: say so in a note.

## Terminal condition

Stop at the first of: every slice eleven gate command exits as the gate states on a clean committed head (`PROOF-COMPLETE` with the commit, the receipts and the statement list); a question you cannot decide from the mandate and the design (file it as `questions/Q-NNN-<slug>.md`, written before you journal `BLOCKED`, with the user story of each option); capacity (`COMPLETE capacity-limit` with a handoff that makes the remainder mechanical). Do not stop for any other reason, and do not touch anything listed under the files this ticket must not touch.
