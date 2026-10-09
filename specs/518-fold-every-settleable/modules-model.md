# Modules model

Responsibilities, dependency direction and promotion. Names and fields are in the [data model](data-model.md), signatures in the [functions model](functions-model.md). Output ceiling: 6 KB.

## Components

| component | holds after this ticket | depends on |
|---|---|---|
| registry library, module `Singular.Registry.FoldSelection` (new) | the pure selection: the seven checks in order, both vocabularies, the capacity bound with its provenance, the judgement of one request against the live facts. No command line, no open datum, no clock reading of its own. | registry types |
| registry library, `Singular.Registry.TxBuilder.Update` and `Update.Context` | the fold builder over a given non-empty set of pending request outputs: one request in pull request 1, several in pull request 2, where the validity bound is the earliest deadline among them. Folding every pending request stays available as the set of all. | registry types, ledger and transaction libraries |
| registry command line (`registry-cli`), `Singular.CLI.FoldRules` | the processing window, the post-build check, the guard for a named request, the refusal wording, and the check that a built fold spends exactly the selection. Loses `foldTarget`. | registry library |
| registry command line, `Singular.CLI.Fold` | takes the application value, reads the pending outputs and the live facts, calls the selection, reads each selected request's application detail through one function that reaches the application only through the value, builds, signs, journals and prints the list receipt. | registry library, `FoldRules`, `Session`, `Receipt`, `Reconcile` |
| registry command line, `Singular.CLI.Receipt` and `Singular.CLI.Session` (pull request 2 only) | the journal line and the expectation carry a list of transitions; an earlier line reads as a list of one. | registry library |
| registry command line, `Singular.CLI.Reconcile` (pull request 2 only) | observation and rollback over every transition of a fold. | `Receipt`, `Session` |
| open-datum package, `Singular.Application.OpenDatum.Entry` | `insert --fold` and `terminate --fold` call the same fold routine with the open-datum value and print the same receipt. | registry `registry-cli` library (`Fold`) |
| conformance library and unit suite | asks the model's `foldBatch` question about the selection's output and holds the same-key negative control; its command-line controls read the list receipt. | registry library, the driver transport |
| scripts and pages | `tools/demo1_cli_journey.sh`, `tools/cli_recovery_controls.sh`, the pages describing `registry fold`. | the command line as a binary |

## Rules

- **selection-is-pure** (invariant): the selection module imports no command-line module, no open-datum module, no clock and no provider; everything it needs arrives as an argument. Enforced by the module compiling in the registry library alone, which the conformance unit suite also links.
- **one-application-step** (invariant): the fold reaches application knowledge in exactly one per-request function, and only through the application value (the split's rule that the value is the only door); neither the selection nor the receipt's request fields name the envelope or the open datum.
- **one-fold-routine** (invariant): `registry fold` and the combined forms call the same routine; no second fold path exists to drift.
- **verdict-independence** (invariant): no function ranges over all pending requests to decide whether one request may proceed; the only cross-request rule is `key-in-batch`, which reads earlier included requests of the same key, and the capacity cut, which runs after every request has its own verdict.
- **pull-request-boundary** (invariant): pull request 1 leaves `Session`, `Receipt` and `Reconcile` untouched and the journal single-request; pull request 2 is the only one that changes the journal.
- **swap-rule** (invariant): the code the new path replaces (`foldTarget`, `FoldTargetRefusal`, `SeveralPending`, the sentence "exactly one is pending" in the pages) is deleted in the same change.
- **dependency-direction**: the command line depends on the registry library; the conformance suite depends on the registry library and never on command-line source. The selection is placed in the library for that reason: the Lean driver transport exists only in the conformance package.
- **promotion**: the selection is promoted from the command line (where the harvested branch kept it) to the registry library, the nearest stable owner both the command line and the conformance suite can use. Nothing else is promoted.
