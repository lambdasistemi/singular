# Coder brief, slice seven: terminations

The whole of slice seven for the writer, with its terminal condition. The binding and the limits are in the [mandate](../mandate.md); the design is the [economic design](../economics-design.md);
the statements and controls are in the [economics plan](../economics-plan.md), including its section "Names"; the rows, including slice six as built, are in the [model rows](../economics-models.md);
the proof is the [gate](../gate.md), version 4. Read the constitution at `.specify/memory/constitution.md` and `AGENTS.md` before you start.

## Story

As an application, I release a key's singular tag into a termination request with my application tag, and the policy checks only that both tags are present; as anyone, I see that a key has at
most one termination pending and that the supply of its singular tag still adds up: the tag is either held at the application's custody or carried by exactly one pending termination.

## The design this slice implements

The words of the decided design, verbatim:

> Holds exactly: the singular tag, the application tag, tip ≥ t_min, the ada its output needs. Application tag bound to (terminate, key, destination). Refund address: none. Booked time: none.
> Exits: fold only.

> How a termination is booked: the key's token lives at the destination its registration named, under the application's custody. The application's rule releases it into a termination request.
> Singular checks the application tag, not the application's rule.

> The syntax tag's minting checks only that the tags are present, never the application's rule: for a registration the application tag; for a termination the singular tag and the application tag.
> A termination's syntax tag is minted only if the singular tag is present.

> At most one termination per key is pending. This follows from token uniqueness across custody and pending requests (`active_witness_unique`, Statements.lean, extended).

> The mismatch half follows from `biconditional_supply_sync` (Statements.lean) once the token held in a pending request is counted in supply.

A termination has no refund address, no booked time, and cannot expire, be retracted or be rejected: those exits are later slices; this slice adds the booking and nothing that spends a request. The
carrier allocation is declared by the requester, as in slice six, and the same limit applies (see the open item in the plan). The relation between the old fee pin and the minimum tip is an open
item: write no statement that assumes one. The mint validator stays with ticket 529.

## Names and homes

Use the agreed names in every new declaration (plan section "Names"). New declarations go where the plan says, in modules of a few hundred lines: economic definitions under
`Singular/Economics/` (slice six put the registration booking, the pool and the world there; extend them or add siblings), statements in `Singular/Statements/` by property. Do not edit the fold
model's declarations (the fold's refusal and transition, the batch fold and its result, the fold branch of the transaction builder and the lemmas and statements that unfold them): another lane
changes them, and the termination fold is slice ten.

## Seat

| Field | Value |
|---|---|
| Role | writer for slice seven |
| Launcher | `codex --dangerously-bypass-approvals-and-sandbox -C /code/singular-issue-494 -m gpt-6-astra -c model_reasoning_effort=high` |
| Branch and base | `feat/494-protected-rejection-rule`, from the commit named in the runtime brief |
| Auditor | Grok, mute, beside you from your first run; you never address it |
| Commit authority | Local commits on the branch only; no push, no rebase onto main, no comment on GitHub |

You are not alone in the codebase; do not revert edits made by others. Write no `Co-Authored-By` and no attribution of any kind in a commit, whatever a harness reminder says. Name things in
plain words; coin no abbreviation.

## The task

1. Failing controls first, committed alone on the base and kept as your red evidence. Each is a termination booking the model must judge, with the reason it must be judged for; a control that cannot be
   evaluated before the vocabulary exists is recorded as such per row. The lawful booking is a control too: it must be accepted.
   - a lawful termination booking (accepted): the key's singular tag leaves the application's custody and is carried by the pending request;
   - a forged singular tag: the tag of another key, of another registry, or one not taken from custody (refused `forged-singular-tag`);
   - a forged application tag: bound to another tuple than (terminate, key, destination) (refused `forged-application-tag`);
   - a singular tag not in custody: a key with no active holding, or one whose tag a pending termination already carries (refused `singular-tag-not-in-custody`);
   - a second termination of a key whose termination is pending, booked in the same transaction as the first or later (refused for the reason above, and the pool still holds one);
   - a dirty request: an extra asset, a tip below the minimum, a refund address or a booked time (refused `dirty-request`); surplus beyond the declared contents (refused `hidden-surplus`);
   - a forged syntax tag: none, two, or another registry's (refused `forged-syntax-tag`).
2. Model the termination: its request and what it holds, the exact-contents rule for it (declared tip apart from the held value, the singular tag and the application tag), its booking judgement over a booking
   transaction that takes the singular tag out of the application's custody, the booking step into the pool, and the supply laws that count the tags carried by pending requests. Slice six put the pool and
   the world in place with registration as the only step: extend them. Note the consequence: in a world with a pending termination, the key's active holding is no longer in the registry component's holdings
   while the key's leaf is still active, so the registry-level consistency law does not hold of that component alone; define the world-level law that does (held plus carried equals one exactly when the leaf
   is active), prove it for every reachable world, and leave every registry-level statement and `Reachable` as they are. File a question with the user story of each option if a design point blocks you.
3. State and prove, from the standard axioms alone, in `Singular/Statements/`:
   - `at_most_one_pending_termination` (statement 9);
   - `world_supply_sync`: in every reachable world, for each key, the singular tags held plus the singular tags carried by pending terminations are exactly one when the key's leaf is active and none otherwise,
     and never more than one;
   - `termination_request_carries_genuine_token`: every pending termination carries exactly one singular tag, of its own key, whose leaf is active, and was taken from custody by its booking.
4. Existing folds, retractions, rejections, the registry-level reachability, the driver's questions, the transaction baseline and the protocol version do not change; new fields are omitted at their default.
5. Regenerate every copy the change moves (corpora, theorem register and digests, theorem page and its speech and audio, simulator mirror, application corpus, coverage record). A new identity starts uncovered and is appended to
   the restatement table, never edited. Restate nothing by hand that a tool regenerates.
6. End with the statement list: for each, its fully qualified name, the `AXIOMS` line `#audit_statements report` prints for it, and the revision it was printed at; and list in the record anything that bears on the open items (the carrier allocation, the
   tag representation) or that slice ten, which folds a termination and burns its tags, must follow.

The tasks, by name, are those of slice seven in the [tasks](../tasks.md).

## Checkpoints

Journal `REVIEW-REQUESTED` with the commit and the evidence path at each of these; continue only when the previous is approved or I say so: the failing controls; the termination model and the booking judgement
green; the world, the supply laws and the statements green; the final head.

## Gate

The slice-seven rows of the [gate](../gate.md), version 4: the "always" rows once per checkpoint, the final rows and `nix develop --quiet -c just ci` once on the final head without a time limit shorter than the
aggregate (about twenty-five minutes). A slice that runs for hours without a product commit is cut again: say so in a note.

## Terminal condition

Stop at the first of: every slice-seven gate command exits as the gate states on a clean committed head (`PROOF-COMPLETE` with the commit, the receipts and the statement list); a question you cannot decide from the
mandate and the design (file it as `questions/Q-NNN-<slug>.md` with the user story of each option and journal `BLOCKED`); capacity (`COMPLETE capacity-limit` with a handoff that makes the remainder mechanical). Do not
stop for any other reason, and do not touch anything listed under the files this ticket must not touch.
