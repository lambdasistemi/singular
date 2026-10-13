# Coder brief, slice five: the economic parameters and fields

The whole of slice five for the commit owner, with its terminal condition. The operator's order and the design are in the
[mandate](../mandate.md) (section "The economic design and the paper") and the [design](../economics-design.md); the plan and the theorems in the
[economics plan](../economics-plan.md); the rows you implement are in the [economic model rows](../economics-models.md); the proof is the
[gate](../gate.md) (version 3). Slices one to three are on the branch.

## Story

As the author of the economic theorems, I find the registry's bond, processor split and termination fee, a request's bond, carried fee and booking root,
and a transaction's donation already in the model with defaults that change nothing, and a booking admission that says exactly what the request-tag mint
must enforce, so that the next slices state outcomes on a model whose every old row still means what it meant.

## Rulings this slice implements

The operator's words are in the mandate. Here: "provable rejection must be punished but not with the deposit"; "it's a new parameter bond"; "termination
should pay the treasury". The adopted design: a registry parameter, the bond, carried by every request beside its deposit; a rejection forfeits the bond only
on a fault proved against the root the request recorded at booking; the forfeited bond is split between the proving processor and the treasury, the split
being a registry parameter; a registry parameter, the termination fee, donated to the treasury per terminated key; parameters set at creation and never
changed by a fold; the treasury donation a transaction field that the model owes.

## Seat

| Field | Value |
|---|---|
| Role | commit owner for slice five |
| Launcher | `/home/paolino/.local/bin/muse --approve`, working directory `/code/singular-issue-494` |
| Runtime root | `<ticket owner root>/commit-owner-5`; your journal is its `STATUS.md` |
| Auditor | Grok, mute, beside you; you never address it |
| Commit authority | Local commits only; no push, no rebase, no comment on GitHub |

You are not alone in the codebase; do not revert edits made by others. No `Co-Authored-By`, no attribution. Plain words, no coined abbreviations.

## The task

Make the model carry the economic parameters and fields with defaults that change nothing, and say the booking rule as a defined admission.

1. Failing control first: add the corpus rows and the statements of the [model rows](../economics-models.md) that cannot hold before the change (the booking
   admission's refusals and its admitting row; the preservation of the parameters by a fold). They fail because the fields and the admission do not exist.
   Keep that output as the RED bundle.
2. Add the three registry parameters, the three request fields and the transaction donation with the defaults and the encoding of the rows: written only when
   not the default, read as the default when absent, a positive denominator checked at decoding. A fold's question is byte for byte what it was.
3. Add the booking admission with its three reasons in the stated order.
4. State and prove `parameters_preserved_by_fold` and `booking_admission_iff` from standard axioms, and export their rows through the model runner.
5. Regenerate every copy the change moves, with the tools: corpora, register and digests, theorem page, simulator mirror, application corpus, coverage
   record, the restatement table (append, never edit earlier lines), and the constitution's 1.16.0 entry, which states the economic fields in the translation
   (one release, one entry: do not open another version).
6. The driver's protocol version moves only if the declared surface digest requires it; say which in the receipt.

The tasks, by name, are those of slice five in the [tasks](../tasks.md).

## Checkpoints

Journal `REVIEW-REQUESTED` with the commit and the evidence path, and continue, at: the RED bundle; the fields and the admission green; the statements and
rows green; the final head before the push.

## Gate

The slice-five rows of the [gate](../gate.md), version 3: per candidate the model check, simulator check, application corpus, coverage gate, conformance
without a devnet, format and lint, and once the batch row; on the final candidate the strict coverage report, browser check, documents, code inventory.

## Terminal condition

Stop at the first of: every slice-five gate command exits as the gate states on a clean committed head (`PROOF-COMPLETE` with the receipt); a question you
cannot decide from the mandate (file it with the user story of each option and journal `BLOCKED`); capacity, only when you cannot make another tool call
(`COMPLETE capacity-limit` with a handoff). Touch nothing under the files this ticket must not touch.
