# Coder brief, slice three: the in-window rows

The whole of slice three for the commit owner, with its terminal condition. The binding and limits are
in the [mandate](../mandate.md); the proof is the [gate](../gate.md). Slices one and two are on the
branch.

## Story

As a reader of the public conformance suite, I see the rows about rejecting a request inside its
windows say exactly what is true until the validators change: which rejection the model and the chain
both accept, which one the model refuses while the chain still accepts it, labelled unmet and never as a
pass, and what will turn that label into agreement.

## Direction

Decision B of 9 October 2026 (operator ruling, recorded in the [mandate](../mandate.md)): this ticket
merges alone, ahead of ticket 495. After it the suite shows two rows.

1. The rejection at once, with lifecycle evidence, of a request that cannot be folded: model and chain
   both accept and the owner is refunded. Green.
2. The rejection, inside the windows, of a foldable `insertActive` request for a key not yet
   registered: the model refuses, the chain accepts. Published as unmet by ruling and never counted as
   passing. A tripwire turns red unless ticket 495 changes the validators so that the two agree;
   ticket 495's acceptance includes that flip.

The row books a foldable insertion on a fresh key, because the insertion the standing row books today
names an edge the two-edge model excludes, which is rejectable at once and would leave the row without
its subject.

## Rulings this slice implements

The operator's words, verbatim; the rest of the rulings are in the [mandate](../mandate.md).

A lifecycle mismatch permits immediate rejection:

> Authenticated incompatibility with the current lifecycle state permits immediate rejection even
> when a later transition could make the request eligible.

Expiry follows both windows:

> expiry-only rejection after both the processing and owner's reclaim windows end ... The expiry
> threshold is therefore submission time plus processing duration plus reclaim duration.

A request naming an excluded edge is rejectable at once:

Epic owner ruling of 9 October 2026, as an application of the first ruling: an excluded edge has no
successor at any leaf, so a request naming one is incompatible with every current state and is
rejectable at once with the lifecycle evidence.

## Seat

| Field | Value |
|---|---|
| Role | commit owner for slice three, launched after the rebased plan is reviewed |
| Launcher | `/home/paolino/.local/bin/muse --approve`, working directory `/code/singular-issue-494` |
| Runtime root | `<ticket owner root>/commit-owner-3`; your journal is its `STATUS.md` |
| Auditor | Grok, mute, beside you; you never address it |
| Commit authority | Local commits only, one patch with `stg`; no push, no rebase, no comment on GitHub |

You are not alone in the codebase; do not revert edits made by others. No `Co-Authored-By`, no
attribution. Plain words, no coined abbreviations.

## The task

1. The dedicated early-rejection row ("early rejection inside the windows") becomes a lawful rejection
   that model and chain both accept inside the windows: a request to register a key that is already
   Active, rejected at once with the lifecycle evidence, the owner refunded the deposit. Its tampered
   refunds (one lovelace short, to another key) stay refused by both for the refund reason. Its workflow
   assertions and placement counts follow the row; its name and requirement text are unchanged.
2. The generic session's standing unmet row for rejecting a request while it can still be folded books a
   foldable registration, an insertion of a key not yet registered (a request naming a retired edge is rejectable at once and would leave the row without its subject), and records each of its three steps as the divergence it
   now is: the two refund controls refuse for different reasons, the untampered reject is refused by the
   model and accepted by the chain. Its stated reason and consumer reading change to say that the model
   refuses and the chain does not; its standing stays unmet. The session's expected-debt assertion keeps
   naming exactly the same rows.
3. The tripwire: the row's expected list stops matching, and the session goes red, on the day the chain
   refuses the untampered reject. Prove it with a seeded control in the same way the neighbouring rows
   prove theirs, or say in the receipt why the existing control already covers it.
4. The consumer record, the book and the evidence page say the same, including the history of ticket
   320's early rejection. History is not edited; add a dated note, do not rewrite.
5. Regenerate what the prose moves: speech companions and audio of the edited pages, the row inventory.

## Checkpoints

Journal `REVIEW-REQUESTED` with commit and evidence path, and continue, at: the red-for-the-right-reason
control (the rows as they stand fail against the changed model); the dedicated row green; the unmet row
recorded; the final head.

## Gate

The slice-three rows of the [gate](../gate.md): the two devnet rows locally once each, the non-devnet
conformance commands, format and lint, the workflow lint and the documents check.

## Terminal condition

Stop at the first of: every slice-three gate command exits as the gate states on a clean committed head
(`CANDIDATE-GREEN`); a question the mandate cannot decide (user story per option, `BLOCKED`); capacity
(`COMPLETE capacity-limit` with a handoff). Touch nothing under the files this ticket must not touch.
