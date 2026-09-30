# Requirements quality checklist

As the ticket owner, I want the requirements checked for testability and scope before any code is written.

## Content quality

- [x] The story names an actor, an action and an outcome.
- [x] Each requirement is observable from a command's exit, its log or a record field.
- [x] No requirement prescribes an implementation beyond the mutation it names and the retained location.

## Requirement completeness

- [x] The RED names the command, the mutant's single change and four ordered witnesses.
- [x] Setup, compile, network and misattributed failures are excluded from the RED.
- [x] The GREEN uses the same command, blueprint, genesis and node on the clean candidate.
- [x] Identity binding covers source, model, blueprint, genesis, node, command, time, exit and log.
- [x] The case where the mutant passes has a bounded repair path.
- [x] Scope exclusions are explicit: CI workflow, product runner, Lean, public pages and other rows.

## Readiness

- [x] No clarification is open; each disposition is recorded in the spec.
- [x] The evidence limits say what the pair does not show.
- [x] Every requirement maps to at least one task.
