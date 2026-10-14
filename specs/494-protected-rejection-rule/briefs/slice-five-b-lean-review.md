# Coder brief, slice five-b: review and improvement of the Lean base

The whole of slice five-b for the writer, with its terminal condition. The binding and the limits are in the [mandate](../mandate.md); the plan is the [economics plan](../economics-plan.md);
the proof is the [gate](../gate.md), version 4 and its slice five-b paragraph. Read the constitution at `.specify/memory/constitution.md` and `AGENTS.md` before you start.

## Story

As the author of slices six to ten, and of the paper that cites them, I build on a Lean base whose names say what they mean, whose modules are small and cohesive, and whose
statements are shaped alike, so that nothing I add inherits a misleading name or lands in a module of more than a thousand lines.

## Subject

The whole `lean/` tree at the head of the branch when you start: 25 `.lean` files, about 8,400 lines. That is the Lean that main already had, plus slices one to three (written by a
different writer) and slice five. Five modules are large: `Statements.lean` (1,693 lines), `Model.lean` (1,472), `Main.lean` (1,162), `Lemmas.lean` (813) and `Driver.lean` (700).
Slices six to ten add to this base, so what you leave is what they build on.

Judge against two standards only:

1. The conventions the repository's Lean already follows where it was consistent before this branch: how declarations, statements and docstrings are named and shaped, and how modules are
   grouped.
2. The vocabulary agreed for the economic work, in [the economics plan](../economics-plan.md), section "Names": syntax tag, singular tag, application tag, state token. The older
   declarations that say "approval" or "active token" for these keep their names until a slice that restates them; propose, do not apply, a rename of those.

## The fence

- No statement is weakened. No theorem's meaning changes. Every existing proof and control stays green.
- A rename is not a restatement. A renamed or moved statement keeps its coverage mapping; the old and the new qualified name are both recorded, and the auditor checks each rename and each
  move as meaning-preserving.
- Written forms do not change: no wire name, no field name, no question name and no corpus scenario changes, so the driver protocol version stays. The exported records that quote a declaration
  by name (the theorem register, the theorem page, the coverage inventory, the simulator mirror) change only where a name or a file path changes.
- The qualified names of the protected statements (those in the base record of the coverage gate) and of the statements the paper cites stay as they are. A move that would change one is a
  rename, and is listed for a ruling instead of applied.
- A declaration that exists on `origin/main` may be moved between files of this tree with its qualified name unchanged. Renaming one is listed, not applied: external projects build on this
  library through Lake, and a public name is merged work.
- Findings that would change a statement's meaning, or that touch merged work in a way that needs a ruling, are listed with the concrete user story of each option, not applied.
- The consumers of every renamed or moved declaration are updated in the same checkpoint, by a repository-wide search for the old name and the old file path: the tools that read the model by
  file (`tools/check_model.py`, `tools/check_application_model.py`, `lean/check_insert_absent_mutants.py`, `lean/check_destination_row_mutants.py`, the compiled axiom gate
  `lean/Singular/Audit.lean` and the open-datum application's), the coverage inventory and its tests, the conformance code that quotes a path or a name, the simulator mirror, the documents,
  and the citations of declarations in `paper/economics/main.tex`. Spec pages under `specs/494-protected-rejection-rule/` are the ticket owner's: list each reference you find in your record
  and do not edit them.

## The shape, bounded

Seven checkpoints at most, in this order. The whole slice is bounded at about four hours and the review at one; whatever is not done is listed as follow-up in your final record, never ground
through.

1. **The review.** Write `handoffs/lean-review.md` and edit nothing. Findings ranked by what they cost slices six to ten: names, module structure, duplicated definitions, statement shapes, proof
   hygiene. Each finding names the place (file and line), what is wrong, what it costs the later slices, its kind (rename, move, split, duplication, statement shape, proof hygiene), whether the
   declaration exists on `origin/main`, whether the change could alter a meaning, and the change you propose. Group the accepted-looking ones into the batches you would apply them in. Then wait
   on your channels for my triage note: I tell you which findings are applied, which are listed for a ruling, and which are dropped. Do not edit before it arrives.
2. **The tools learn the module set.** The checkers, the axiom gate, the coverage inventory and the mutant harnesses read the model and the statements as a set of modules instead of one file
   each, with nothing moved yet. The gate stays able to fail: plant an unproved statement in a module of the set and show the axiom gate and the statement manifest refuse it, then remove it.
   Keep the qualified names: the statements stay in the namespace the gate walks whichever file holds them.
3. to 5. **The splits**, one checkpoint each, a move with no change of meaning: the model by registry state, transitions and transaction vocabulary; the statements by the property each group
   proves, with the lemmas beside them; the driver and the corpus runner by what they export. Cohesive submodules of a few hundred lines. Before a move, search the unmerged branches and the live
   worktrees for a lane that edits the file; list any in your record and ask before moving a file another lane edits.
6. to 7. **The renames and structural improvements**, in at most two batches of related changes, each with its record: old name, new name and the reason it was misleading, or the structural
   move with a one-line reason.

At every checkpoint: commit, write `handoffs/review-NNN.md` as a decision record (the commit; the rename or move list with the evidence that each is meaning-preserving: the statement text after
the name substitution is identical, shown by the register's digests or by a mechanical comparison; the gate commands you ran and their exits; what you did not cover), journal
`REVIEW-REQUESTED review=NNN sha=<sha>` and continue to the next only after the previous is approved or I say otherwise.

## Gate

The "always" rows of the [gate](../gate.md), version 4, at every checkpoint after the review: the model check with the axiom guard, the simulator check, the application corpus, the coverage gate
and its real-tree tests, and the conformance commands that need no devnet when the diff touches `conformance/`. Once on the final head: lint, documents including speech and narration of every
edited page, the code inventory, the strict coverage report, the browser check, and `nix develop --quiet -c just ci` once. A move or a rename changes no behaviour, so the corpora of scenarios
must stay byte-identical; a corpus scenario that changes is a finding, not an acceptable regeneration.

## Terminal condition

Stop at the first of: every gate command exits as the gate states on a clean committed head, with the final record (`PROOF-COMPLETE`) holding the list of renames (old to new), the structural
moves with a one-line reason each, the findings listed for a ruling and the gate receipts; a question you cannot decide from this brief (file it as `questions/Q-NNN-<slug>.md` with the user story
of each option and journal `BLOCKED`); capacity (`COMPLETE capacity-limit` with a handoff that makes the remainder mechanical). Do not touch anything listed under the files this ticket must not
touch.
