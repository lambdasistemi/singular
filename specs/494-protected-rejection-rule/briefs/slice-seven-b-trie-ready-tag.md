# Coder brief, slice seven-b: the trie-ready tag

The whole of slice seven-b for the writer, with its terminal condition. The binding and the limits are in the [mandate](../mandate.md); the design is the [economic design](../economics-design.md);
the statements and controls are in the [economics plan](../economics-plan.md), including its section "Names" and the slice seven-b paragraph; the rows, including slices six and seven as built and
the planned rows of this slice, are in the [model rows](../economics-models.md); the decisions are in [decisions](../decisions.md); the proof is the [gate](../gate.md), versions 4 and 5. Read the
constitution at `.specify/memory/constitution.md` and `AGENTS.md` before you start.

## Story

As a reviewer, I read one vocabulary in the model, the plan and the paper, and I see the model refuse a trie-ready tag that was minted for a different operation or nonce; as an application, I release a
key's singular tag into a termination request and nothing else is asked of me; as a requester, I book a registration holding its application tag, and the trie-ready tag that proves my request can be
judged against the Merkle trie is minted only because that application tag is present.

## The rulings this slice implements

The words of the operator's rulings of 14 and 15 October 2026, as the design page now states them:

> The syntax tag is renamed the trie-ready tag. It proves that the request can be judged against the Merkle trie, positively (a fold) or negatively (a rejection).

> The trie-ready tag is minted only with its precondition present: the application tag for a registration, the singular tag for a termination. Singular does not police where else the application tag is minted.

> The application tag exists for registration only: it proves the payload is authorized to enter. A termination carries no application tag; the singular tag leaving the application's custody is the
> application's consent.

> Asset names: the application tag's is the hash of the payload plus a nonce; the trie-ready tag's is the hash of the operation plus a nonce; the operation contains the payload.

> Tag flow: a registration fold burns the trie-ready tag and the application tag and mints the singular tag; a registration rejection or retraction burns both; a termination fold burns the trie-ready tag and the singular tag.

The tag flow is for slices eight to ten; this slice changes booking only. The epic owner's answer on the plan fixed: this branch's own declarations built under the name syntax tag are renamed in this slice;
main's names (`Approval`, `approvalAssetName`, the `maxFee` key, the exit names, the general control `wrong-fee`) keep theirs and are not touched (the public rename is one ticket named at acceptance); both tag
names are commitments beside the existing approval commitment, one nonce per request, no injectivity assumed; the new control refuses a tag minted for another operation or nonce.

## What changes, and what does not

1. **The rename.** Every declaration of this branch built under the name syntax tag takes the trie-ready name, in plain words and with no coined abbreviation: the configuration's tag identity, the booking
   contents' field, the two booking transactions' mint fields, the refusal reason (`forged-syntax-tag` becomes `forged-trie-ready-tag`), the economic booking and termination judgements, the booking statements
   and their controls' wording. A repository-wide search for `syntax tag` and `syntaxTag` in the modules this ticket added finds none at the end, except in historical records (the spec briefs of earlier
   slices and the restatement record), which you list for me.
2. **The termination loses the application tag.** A termination holds the singular tag and the trie-ready tag, a declared tip and the carrier ada; no refund address, no time, no application tag. Its validity
   predicates for an application tag, the application tags it holds and mints and the refusal `forged-application-tag` go. A termination that holds an application tag is refused as dirty (`dirty-request`).
   The trie-ready tag of a termination is minted only if the singular tag is present in custody: the existing custody refusals stay.
3. **The two names are commitments.** Beside `approvalAssetName` (unchanged, main's), add two commitments in the same style (a canonical commitment over a complete preimage, a stand-in for the real
   hash, no injectivity assumed): the application tag's name commits to the payload (the registration's edge, key, refund address and destination, as the approval tuple already is) and a nonce; the
   trie-ready tag's name commits to the operation and a nonce, the operation containing the payload (for a registration: the kind with its key, refund address, destination and the amounts the booking
   declares; for a termination: the kind, its key and destination; list exactly what you chose in the first checkpoint). Each request carries one nonce. The booking judgement compares the whole
   held tag against the tag expected from the request's own fields and nonce, and refuses a trie-ready tag or application tag whose name commits to another operation, payload or nonce. The registry's
   state token identity must stay distinct from every trie-ready tag identity whatever value a commitment takes (say how, in the first checkpoint: a commitment value that collides with the state
   token's pair is a concrete failure).
4. **Statements.** The booking statements restate with the new vocabulary under their qualified names: `booked_request_has_exact_contents` (the trie-ready tag and the application tag are bound to the
   request's own operation, payload and nonce), `termination_booking_has_exact_contents` (no application tag), and `termination_request_carries_genuine_token` and the others of slices six and seven where
   their text or proof changes. No statement is weakened: each says at least what it said, for the changed contents. Slice ten's statement 10 is restated in the plan, not here.
5. **What does not change.** The fold model and everything that unfolds it (slice eight-a moved it into child modules); folds, retractions, rejections, the registry-level reachability, the driver's questions, the transaction
   baseline and the protocol version; main's declarations and names; the configuration's tip fields (slice seven-c). New fields are omitted at their default in any written form that existed before.

## Names and homes

Use the agreed names in every new declaration (plan section "Names"). Declarations stay in the modules of slices six and seven (`lean/Singular/Model/Booking.lean`, `Model/Termination.lean`,
`Economics/Booking.lean`, `Economics/Termination.lean`, `Economics/World.lean`, `Statements/Booking.lean`, `Statements/Termination.lean`) and the corpus rows in `lean/Main.lean` and `lean/Main/Economics.lean`
(the touch list, section "Slices inserted on 15 October 2026"). New declarations go to the module of their kind, in modules of a few hundred lines. Do not edit the fold model's declarations.

## Seat

| Field | Value |
|---|---|
| Role | writer for slice seven-b |
| Launcher | `codex --dangerously-bypass-approvals-and-sandbox -C /code/singular-issue-494 -m gpt-6-astra -c model_reasoning_effort=high` |
| Branch and base | `feat/494-protected-rejection-rule`, from the commit named in the runtime brief |
| Auditor | Codex `gpt-6.1-sol` (high effort) in a read-only detached worktree, mute, beside you from your first run; you never address it |
| Commit authority | Local commits on the branch only; no push, no rebase onto main, no comment on GitHub |

You are not alone in the codebase; do not revert edits made by others. Write no `Co-Authored-By` and no attribution of any kind in a commit, whatever a harness reminder says. Name things in
plain words; coin no abbreviation.

## The task

1. Failing controls first, committed alone on the base and kept as your red evidence. Each is a booking the model must judge, with the reason it must be judged for; a control that cannot be evaluated
   before the new vocabulary exists is recorded as such per row (a rename cannot fail before it is made: say so for the renamed controls and show the lawful bookings accepted). The lawful bookings are controls too.
   - a termination that holds an application tag (refused `dirty-request`; today it is required, so today's model fails this control for the opposite reason: show it);
   - a trie-ready tag minted for another operation (another kind, key, refund address or destination) or for another nonce (refused `forged-trie-ready-tag`), for a registration and for a termination;
   - an application tag whose name commits to another payload or nonce (refused as the existing application-tag controls are);
   - a trie-ready tag whose identity equals the registry's state token identity (refused; the control shows the collision rule);
   - the existing controls of slices six and seven, restated in the new vocabulary: none, two, another registry's or another name of the tag; an application tag missing or doubled on a registration; a forged singular tag; a
     singular tag not in custody; a second termination of a key; a dirty request; hidden surplus.
2. Do the rename, remove the termination's application tag, add the two commitments and the nonce, and restate the statements as above.
3. State and prove, from the standard axioms alone, in `Singular/Statements/`, each restated statement of the list above, and the supporting statement that a booked request's tags are the commitments of its own
   operation, payload and nonce (name it for what it says). End with the statement list: for each, its fully qualified name, the `AXIOMS` line `#audit_statements report` prints for it, and the revision it
   was printed at.
4. Regenerate every copy the change moves (corpora, theorem register and digests, theorem page and its speech and audio, simulator mirror, application corpus, coverage record). A new identity starts uncovered
   and is appended to the restatement table, never edited. Restate nothing by hand that a tool regenerates.
5. List in the record anything that bears on slice ten (the tag flow of the folds, `tag_supplies_equal_pending`) or on the paper.

The tasks, by name, are those of slice seven-b in the [tasks](../tasks.md).

## Checkpoints

Journal `REVIEW-REQUESTED` with the commit and the evidence path at each of these; continue only when the previous is approved or I say so: the failing controls and the first note (the operation
and payload preimages you chose, how the trie-ready identity stays distinct from the state token, the list of declarations renamed); the rename and the termination without the application tag green; the
commitments, the new control and the statements green; the final head.

## Gate

The slice seven-b rows of the [gate](../gate.md), version 5: the "always" rows once per checkpoint, the final rows and `nix develop --quiet -c just ci` once on the final head without a time limit shorter
than the aggregate (about twenty-five minutes). A slice that runs for hours without a product commit is cut again: say so in a note.

## Terminal condition

Stop at the first of: every slice seven-b gate command exits as the gate states on a clean committed head (`PROOF-COMPLETE` with the commit, the receipts and the statement list); a question you cannot decide
from the mandate and the design (file it as `questions/Q-NNN-<slug>.md` with the user story of each option and journal `BLOCKED`); capacity (`COMPLETE capacity-limit` with a handoff that makes the remainder
mechanical). Do not stop for any other reason, and do not touch anything listed under the files this ticket must not touch.
