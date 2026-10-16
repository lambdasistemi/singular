# Coder brief, slice six: registrations

The whole of slice six for the writer, with its terminal condition. The binding and the limits are in the [mandate](../mandate.md); the design is the [economic design](../economics-design.md);
the statements and controls are in the [economics plan](../economics-plan.md), including its section "Names"; the rows are in the [model rows](../economics-models.md); the proof is the
[gate](../gate.md), version 4. Read the constitution at `.specify/memory/constitution.md` and `AGENTS.md` before you start.

## Story

As a requester, I book a registration holding exactly the registration cost, a tip of at least the minimum, the carrier ada and the application tag, and my booked time cannot be moved:
the policy refuses any other contents, mints my syntax tag together with my request, and takes my booked time from the upper end of my booking interval, which can be at most the
registry's maximum booking width wide.

## The design this slice implements

The words of the decided design, verbatim:

> The request policy, the minting policy that mints a booked request's syntax tag, refuses any request whose contents are not exactly the following ("dirty requests").

> Holds exactly: R, tip ≥ t_min, the ada its token output needs (carrier ada), the application tag. Application tag bound to (register, key, refund address, destination). Refund address: yes.
> Booked time: s = U, the upper end of the booking interval [L, U), U − L ≤ δ. Exits: fold, retraction, rejection.

> The syntax tag is minted when a request is booked and burned when that request is spent, by any exit: fold, retraction or rejection. There is no syntax tag without a pending request and no
> pending request without its syntax tag. The application tag has the same life. It is minted at booking and burned by every exit.

> The syntax tag's minting checks only that the tags are present, never the application's rule.

R is the registration cost, t_min the minimum tip, δ the maximum booking width (slice five added them to the configuration). The exits are slices eight to ten: this slice adds the
booking and nothing that spends a request. The relation between the old fee pin and the minimum tip is an open item: write no statement that assumes one. The mint validator that enforces
all this stays with ticket 529; this slice models what the syntax tag guarantees about a pending request.

## Names

Use the agreed names in every new declaration: syntax tag, singular tag, application tag, state token (plan section "Names"). The existing `Approval` structure and `approvalAssetName`
are the application tag's older names and keep their declaration names until a slice that restates them; do not rename them. New declarations go where the plan says: definitions of the
model's vocabulary in `Singular/Model/`, the economic definitions under `Singular/Economics/` (split by what they define, a few hundred lines each, with `Singular/Economics.lean` as the
facade the root imports), statements in `Singular/Statements/Booking.lean` in the namespace the axiom gate walks. The facades stay small.

## Seat

| Field | Value |
|---|---|
| Role | writer for slice six |
| Launcher | `codex --dangerously-bypass-approvals-and-sandbox -C /code/singular-issue-494 -m gpt-6-astra -c model_reasoning_effort=high` |
| Branch and base | `feat/494-protected-rejection-rule`, from the commit named in the runtime brief |
| Auditor | Grok, mute, beside you from your first run; you never address it |
| Commit authority | Local commits on the branch only; no push, no rebase onto main, no comment on GitHub |

You are not alone in the codebase; do not revert edits made by others. Write no `Co-Authored-By` and no attribution of any kind in a commit, whatever a harness reminder says. Name things in
plain words; coin no abbreviation.

## The task

1. Failing controls first, committed alone on the base and kept as your red evidence. Each control is a booking the model must judge, with the reason it must be judged for; a control that cannot be
   evaluated before the vocabulary exists is recorded as such per row. The lawful booking is a control too: it must be accepted, so that a refusal for any reason cannot make a refusal control pass.
   - a lawful registration booking (accepted);
   - a dirty request: an extra asset, a wrong amount of the registration cost or of the carrier ada, an application tag bound to another tuple (refused `dirty-request`);
   - hidden surplus: lovelace held beyond the declared contents (refused `hidden-surplus`);
   - a forged syntax tag: none minted, two minted, or one of another registry's (refused `forged-syntax-tag`);
   - a backdated booking: a booked time that is not the upper end of the booking interval (refused `backdated-booking`);
   - a booking wider than the maximum: upper end minus lower end above the configured width (refused `booking-too-wide`).
2. Model the registration: its request and what it holds; the exact-contents rule, with the declared tip kept apart from the held value; the pending pool; the booking judgement over a booking
   transaction (interval, contents, tags minted with the pending request); the booking step into the pool; the world (registry state with the pool) and its reachability with the booking step as
   its only transition besides the initial one. How tags are represented (as assets of the transaction's mint, or as fields beside it) is your design: keep every written form that exists
   unchanged (fields omitted at their default), keep the state token abstraction of slice five (`Config.stateToken = (registryId, 0)`), and derive the syntax tag's identity from the registry
   identity the same way, with no new configuration field. File a question with the user story of each option if a design point blocks you.
3. State and prove the four supporting statements of the plan in `Singular/Statements/Booking.lean`, from the standard axioms alone:
   - `booked_request_has_exact_contents`: every request in the pool of a reachable world holds exactly what its kind allows, the declared tip at least the minimum;
   - `booked_time_is_interval_end`: the booked time of a pending registration is the upper end of the interval of the transaction that booked it;
   - `booked_time_not_before_inclusion`: for every inclusion time inside the booking interval, the booked time is not before it, so expiry comes no earlier than both windows after inclusion;
   - `booking_width_within_limit`: the booking interval of a pending registration is at most the configured width wide.
4. The registry-level reachability, every existing fold, retraction and rejection, and the driver's questions do not change. The transaction baseline stays byte-identical (the check the model check
   runs), and the protocol version stays unless a declared question's written form must change, which you say at the first checkpoint.
5. Regenerate every copy the change moves (corpora, theorem register and digests, theorem page and its speech and audio, simulator mirror, application corpus, coverage record). A new identity
   starts uncovered and is appended to the restatement table, never edited. Restate nothing by hand that a tool regenerates.
6. End with the statement list: for each, its fully qualified name, the `AXIOMS` line `#audit_statements report` prints for it, and the revision it was printed at.

The tasks, by name, are those of slice six in the [tasks](../tasks.md).

## Checkpoints

Journal `REVIEW-REQUESTED` with the commit and the evidence path at each of these; continue only when the previous is approved or I say so: the failing controls; the registration model and the
booking judgement green; the world, the booking step and the statements green; the regeneration green and the final head.

## Gate

The slice-six rows of the [gate](../gate.md), version 4: the "always" rows once per checkpoint, the final rows and `nix develop --quiet -c just ci` once on the final head without a time limit
shorter than the aggregate. A slice that runs for hours without a product commit is cut again: say so in a note.

## Terminal condition

Stop at the first of: every slice-six gate command exits as the gate states on a clean committed head (`PROOF-COMPLETE` with the commit, the receipts and the statement list); a question you cannot
decide from the mandate and the design (file it as `questions/Q-NNN-<slug>.md` with the user story of each option and journal `BLOCKED`); capacity (`COMPLETE capacity-limit` with a handoff that
makes the remainder mechanical). Do not stop for any other reason, and do not touch anything listed under the files this ticket must not touch.
