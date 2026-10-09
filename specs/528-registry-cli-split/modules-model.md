# Modules model

Responsibilities, dependency direction and promotion. Names and fields are in `data-model.md`, signatures in `functions-model.md`. Output ceiling: 6 KB.

## Components

| id | component | holds | depends on |
|---|---|---|---|
| registry-library | `singular-registry` (existing library) | the registry's wire, builders, trie, state token and **the application value** (`Singular.Registry.Application`). Names no application. | ledger and tx-build libraries |
| registry-cli | public sublibrary `registry-cli`, source `cli/src` | every `Singular.CLI.*` module that decides a registry rule: parser for the registry verbs, **the flag group**, session, journal and receipts, `create`, `fold`, `reject`, `reclaim`, `inspect`, reconcile, recovery, and **the booking call** (`Singular.CLI.Booking`). Takes an application value; names no application. | registry-library |
| open-datum-application | public sublibrary `open-datum-application`, source `open-datum/src` | `Singular.Application.OpenDatum.*` (envelope, booking approval and destination, payload update, release rules, script), the **open-datum value**, and the open-datum verbs (`insert`, `update`, `terminate` and the thin `create`, `fold`, `inspect`) with their parser | registry-library, registry-cli |
| singular | executable `singular`, source `cli/Main.hs` | the registry verbs only, composed with the neutral value | registry-cli |
| open-datum | executable `open-datum`, source `open-datum/app` | one `Main` that composes the open-datum value | open-datum-application |
| keri-stub | executable `keri-stub`, source `keri-stub` | register, convict, status, its own policy script and value | registry-cli, registry-library |
| tests | `cage-tests` and the existing suites | depend on the libraries above instead of compiling `cli/src` | all libraries |

## Rules

- **application-boundary** (invariant): no module of registry-library, registry-cli, `singular` or `keri-stub` imports `Singular.Application.OpenDatum.*`, and none of those components lists `open-datum-application` in `build-depends`. Enforced by `application-boundary-check` and by the cabal dependency graph.
- **one-flag-group** (invariant): the flag group lives in registry-cli and is parsed by one function; `singular` and `open-datum` call it, neither re-spells a flag.
- **value-is-the-only-door** (invariant): the open-datum knowledge `Fold`, `Live`, `Reconcile`, `Inspect`, `Create`, `Registry`, `Preview` hold today (envelope check, holding lookup, release, decode, pin title) is reached only through the application value.
- **booking-written-once** (invariant): the early refusal of a booking the current leaf rules out exists in `Singular.CLI.Booking` and nowhere else.
- No promotion upstream: `cardano-keri` consumes `registry-cli` and the registry library as published components; nothing in this ticket moves code into that repository.
