# Plan: the Demo 1 steps need no jq

## The class of change

Each part changes product behaviour: new options and a new command of two programs, a rewrite of a file the reader owns, and new text on standard output. The full process applies, one coder and one persistent auditor, with the hosted checks as the net. The documentation and its narration are part of each pull request.

## Slices

One pull request per part, in the order of the specification, each merged on the desk's grant before the next starts. Every pull request body says `Part of #717`; the last says `Closes #717`.

| Slice | Pull request carries | Reuses from the earlier slice |
|---|---|---|
| Registry's name recorded | the settings file writer; the `create` switch in both programs; documentation of the switch | nothing |
| Settings from the devnet | the command `settings save` and its help; the documentation of the command | the writer |
| Receipt as input | the `@FILE` form for `--request` and `--state-token` in both programs and in `settings save` | the options of the earlier slices |
| Summary | the `--summary` switch on the listed commands; the summary text for each receipt shape | nothing |

## Where each piece lives

- The settings file writer is one module of the command library next to the module that reads the file, used by `create` and by `settings save`. It takes the file, the keys to set and returns the text of the new file, and it replaces the file in a single step. The two programs share it.
- The `create` switch is declared once with the other shared flags and taken by both create commands, like the earlier shared options. It is not a standing setting: no variable and no key.
- The command `settings save` is a group `settings` with the one leaf `save` in the overview of `singular`. Its eleven setting flags reuse the words of the standing declarations without their variable and key.
- The `@FILE` form is applied once, after the settings sources have filled the command line and before the command sees it, for exactly the two options. A command never learns where its value came from.
- The summary is rendered from the receipt value, after the command has finished, by one module with one function per receipt shape. A command that prints a receipt calls it when the switch is on. The exit status and the files written are decided before.

## Consumers of a flag change

A new flag or command is never one edit. Each part lists and touches these, found by the earlier tickets:

- the shared declarations and the help declarations of both programs;
- the help snapshots of both programs, recorded with the snapshot spec's own switch;
- the two parser corpora, where a changed line keeps `result` and gains `after`, and a new accepted line is added;
- the application settings spec of `open-datum`;
- the third program, `keri-stub`, which builds the shared create arguments and stops compiling when a field is added to them without a value there; its component build and its tests are hosted jobs and a row of the gate;
- the settings table of `docs/singular-node.md` and the documented-flags check that holds it to the real help;
- the narration clips of every documentation page the part changes.

## The gate

Existing commands only, narrowed by the suite's own filters to what the part can break. Every build and test runs in a memory-capped scope with a timeout, from the package's own development shell, never from the root.

| What | Command |
|---|---|
| Format | `just format` twice, then `just format-check` |
| Lint | `just lint` when a shell script or a workflow changes; the lint of the Haskell sources through the repository's lint recipe |
| Build | the singular suite and the `singular` executable from `offchain/`; the `open-datum` suite and executable from the application's `offchain/` |
| Tests | the singular suite filtered to the command layer; the whole `open-datum` suite, whose 14 specs that need flake-staged fixtures cannot run in a plain checkout |
| Help and corpora | the snapshot spec and the corpus specs, re-recorded with their own switches and read as a diff |
| Documentation | the documented-flags check, then the documentation check with the staged files |
| Ownership | the effect-ownership and node-confinement checks when a module adds effects |

The hosted checks at the exact head of each pull request are the net; the whole board is awaited by name before a merge is asked for.

## Checkpoints

The auditor is persistent for a part and mute toward the coder. The coder asks for a verdict at two points: when its failing tests are committed, and before the push, when everything is green and the documentation is regenerated. A commit that only changes documentation, narration or generated files gets no checkpoint. A block needs a concrete failure scenario.

## Hosted checks

Each part adds to a journey that already runs on a devnet in a hosted job, so it runs where the board runs. The coder names, at the start of the part, the existing journey it extends and the workflow step that runs it, and the walk for the merge request lists that step. A check that no workflow step runs is not evidence.

## Coordination

Issue #719 runs in parallel and changes the options of `insert`. Whoever merges second rebases once onto main, re-records the help snapshots and the corpora, and says so in the merge-ready line.

## Notes for the tutorial's owner

For each part, `handoffs/singular-demo-route-part<N>.md` in the ticket's runtime root names the tutorial lines, at a named commit fetched first, that lose their `jq` and what replaces them. Nothing is pushed to the tutorial's repository.
