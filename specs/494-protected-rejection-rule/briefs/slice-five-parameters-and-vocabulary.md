# Coder brief, slice five: parameters and the transaction vocabulary

The whole of slice five for the writer, with its terminal condition. The binding and the limits are in the [mandate](../mandate.md); the design is the
[economic design](../economics-design.md); the statements and the controls are in the [economics plan](../economics-plan.md); the signed rows are in the
[model rows](../economics-models.md), section "Slice five: signed rows"; the proof is the [gate](../gate.md), version 4. Read the constitution at
`.specify/memory/constitution.md` before you start.

## Story

As a registry creator, I fix the registration cost, the minimum tip and the maximum booking width once, and I see every fold leave them as they were; as a
reviewer, I read a transaction the way the ledger shows it: inputs and reference inputs by output reference, values, a validity interval, a fee and a donation.

## The design this slice implements

The words of the decided design, verbatim:

> Every parameter is fixed at creation. A Singular registry has no authority that could change one.

> Output references and their presence in the current UTxO set, so that "a reference to a spent output is refused" can be stated. Reference inputs alongside spending inputs. The exact state token identity (policy and name). Actual input and output values, with native assets. The donation field (a zero amount omits it), the ledger fee, and a balance relation scoped to these transactions.

> Every fold preserves every registry parameter. Today's preservation (`onlyRootChanged`), extended to R, t_min and δ.

R is the registration cost, t_min the minimum tip, δ the maximum booking width; the design page has their meaning. The three are numbers here: no measured value is chosen
or implied, and a value in a corpus row is illustrative. The relation between the old fee pin and the minimum tip is an open item: write no statement that assumes one.

## Seat

| Field | Value |
|---|---|
| Role | writer for slice five |
| Launcher | `codex --dangerously-bypass-approvals-and-sandbox -C /code/singular-issue-494 -m gpt-6-astra -c model_reasoning_effort=high` |
| Branch and base | `feat/494-protected-rejection-rule`, from the plan commit named in the runtime brief |
| Auditor | Grok, mute, beside you from your first run; you never address it |
| Commit authority | Local commits on the branch only; no push, no rebase onto main, no comment on GitHub |

You are not alone in the codebase; do not revert edits made by others. Write no `Co-Authored-By` and no attribution of any kind in a commit, whatever a harness reminder
says. Name things in plain words; coin no abbreviation.

## The task

1. Failing controls first, committed alone on the base and kept as your red evidence: a scenario whose configuration carries a nonzero registration cost, minimum tip
   and booking width and is folded, expecting the next state's configuration to carry the same three (the base drops them); and, for the vocabulary, one row each for a
   reference to an output an earlier transaction spent, an inflating transaction and a deflating one. A row that cannot be evaluated before the vocabulary exists is
   recorded as such per row. Every control must fail for the intended reason, never for a build or setup reason.
2. Add the three parameters and the vocabulary exactly as the signed rows state; extend `onlyRootChanged`; keep every existing row's meaning: each new field is omitted
   from the written form at its default and read as its default when absent.
3. State and prove statement 1 and the four supporting statements of the plan, in `Singular.Statements`, from the standard axioms alone.
4. Add `Singular.Economics` to the root module and to the frozen source extent in `tools/check_model.py` (the one mechanical change the touch list allows there).
5. Regenerate every copy the change moves (corpora, theorem register and digests, theorem page and its speech and audio, simulator mirror and derived pages, the open-datum
   application's committed corpus, the coverage record with a published restatement table). Restate nothing by hand that a tool regenerates. No obligation is dropped; a
   restated identity starts uncovered.
6. The 1.16.0 entry of the constitution is completed by slice ten. Touch it in this slice only if the model checker's reconciliation fails without a row for one of this
   slice's declarations; then add exactly that row.
7. End with the list of this slice's statements: for each, its fully qualified name, the `AXIOMS` line `#audit_statements report` prints for it, and the revision it was
   printed at, in your final record.

The tasks, by name, are those of slice five in the [tasks](../tasks.md).

## Checkpoints

Journal `REVIEW-REQUESTED` with the commit and the evidence path at each of these and continue without waiting: the failing controls; the parameters and their
preservation green; the vocabulary and its statements green; the regeneration green and the final head before the ticket owner pushes. One repair per block.

## Gate

The slice-five rows of the [gate](../gate.md), version 4, run once per candidate on a clean committed tree. Run the narrowest build while editing (`lake build` of the
changed modules); the gate's commands only when you have a candidate.

## Terminal condition

Stop at the first of: every slice-five gate command exits as the gate states on a clean committed head (`CANDIDATE-GREEN` with the commit, the receipts and the statement
list); a question you cannot decide from the mandate and the design (file it as `questions/Q-NNN-<slug>.md` with the user story of each option and journal `BLOCKED`);
capacity (`COMPLETE capacity-limit` with a handoff that makes the remainder mechanical). Do not stop for any other reason, ask for no confirmation, and do not touch
anything listed under the files this ticket must not touch.
