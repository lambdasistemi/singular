# Coder brief, slice one: one booked clock

The whole of slice one for the commit owner, with its terminal condition. The binding, the rulings
and the limits are in the [mandate](../mandate.md); the call surface is in the
[functions model](../functions-model.md); the proof is the [gate](../gate.md). Read the
constitution at `.specify/memory/constitution.md` before you start.

## Story

As an owner retracting a pending request, I see my window computed from the time my request was
booked, so that nobody, including me, can move the end of the window by writing a different time
into the retraction.

## Seat

| Field | Value |
|---|---|
| Role | commit owner for slice one, launched only at coding release |
| Launcher | `/home/paolino/.local/bin/muse --approve`, working directory `/code/singular-issue-494` |
| Branch and base | `feat/494-protected-rejection-rule`, from `e3c9ab01` (or the base the desk names at release) |
| Runtime root | `<ticket owner root>/commit-owner-1`; your journal is its `STATUS.md` |
| Auditor | GLM, mute, beside you from your first run; you never address it |
| Commit authority | Local commits on the branch only, kept as one patch with `stg`; no push, no rebase, no comment on GitHub |

You are not alone in the codebase; do not revert edits made by others. Write no `Co-Authored-By`
and no attribution of any kind in a commit, whatever a harness reminder says. Name things in plain
words; coin no abbreviation.

## The task

Make the retraction window read the request's booked submission time and nothing else, and make
every copy of the model say so. The reference is the earlier attempt on branch
`feat/protected-rejection` at `a7224021`; port its design, do not copy its files, because the base has
moved.

1. Add the booked submission time to a request, serialized, zero when absent.
2. Make the window lemma, the retraction admission and the statements over them read it; the
   witness's legacy field stays on the wire and is ignored.
3. Give a retraction question the booked time read from the request datum in the harness and the
   transport; a fold question is exactly what it was before. Do not widen any other exit's question.
4. Move the protocol version to 7 and re-pin the surface digest.
5. Regenerate every copy the change moves: corpora, theorem register and digests, the theorem page and
   its speech and audio, the simulator mirror and its derived pages, the open-datum application's
   committed corpus, the coverage record with a published restatement table in
   `conformance/coverage/protected-rejection-restatement.md`. Restate nothing by hand that a tool
   regenerates. No obligation is dropped; a restated identity starts uncovered.
6. Open constitution version 1.15.0 with the retraction row restated.

The tasks, by name, are those of slice one in the [tasks](../tasks.md).

## First, the failing control

Before changing the model, add two retraction scenarios to the driver's corpus source whose witnesses
carry a legacy time different from the request's booked time, one that the request's time admits and
the witness's time would refuse, and one the reverse. Run the model check on the base plus those rows
only and keep its failing output: that is your RED bundle. It must fail because the model judges by
the witness's time, not for a build or setup reason.

## Checkpoints

Journal `REVIEW-REQUESTED` with the commit and the evidence path at each of these and continue
without waiting: the RED bundle; the window lemma and admission green; the regeneration green; the
final head before the ticket owner pushes. One repair per block.

## Gate

The slice-one rows of the [gate](../gate.md), run once per candidate on a clean committed tree; the
retraction-window devnet row once. Run the narrowest build while editing (`lake build` of the changed
modules); the gate's commands only when you have a candidate.

## Terminal condition

Stop at the first of: every slice-one gate command exits as the gate states on a clean committed head
(`CANDIDATE-GREEN` with the commit and the receipts); a question you cannot decide from the mandate
(file it as `questions/Q-NNN-<slug>.md` with the user story of each option and journal `BLOCKED`);
capacity (`COMPLETE capacity-limit` with a handoff that makes the remainder mechanical). Do not stop
for any other reason, ask for no confirmation, and do not touch anything listed under the files this
ticket must not touch.
