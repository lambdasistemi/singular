# Modules model

Responsibilities, dependency direction and promotion. Names and fields are in `data-model.md`, signatures in `functions-model.md`. Output ceiling: 8 KB.

## Components

| id | component | holds | depends on |
|---|---|---|---|
| registry-library | `singular-registry` (existing library, `offchain/`) | the registry's wire, builders, trie, state token and **the application value** (`Singular.Registry.Application`). Names no application. | ledger and tx-build libraries |
| registry-cli | public sublibrary `registry-cli`, source `offchain/cli/src` | every `Singular.CLI.*` module that decides a registry rule: parser for the registry verbs, **the flag group**, session, journal and receipts, `create`, `fold`, `reject`, `reclaim`, `inspect`, reconcile, recovery, and **the booking call** (`Singular.CLI.Booking`). Takes an application value; names no application. | registry-library |
| singular | executable `singular`, source `offchain/cli/Main.hs` | the registry verbs only, composed with the neutral value | registry-cli |
| registry-chain | Aiken project `onchain/` | the registry's validators and, under `onchain/lib/`, the modules they share and an application may import | none |
| open-datum-chain | Aiken project `applications/open-datum/onchain/` | the validator `open_datum`, the module `application/envelope`, their tests | registry-chain |
| open-datum-package | cabal package `open-datum`, `applications/open-datum/offchain/` | library `Singular.Application.OpenDatum.*`, the **open-datum value**, the entry commands and the open-datum verbs with their parser, the recognised open-datum script; executable `open-datum`; the application's specs; the negative host `singular-negative` | registry-library, registry-cli |
| keri-stub | executable `keri-stub`, `applications/keri-stub/` | register, convict, status, its own policy script and value | registry-cli, registry-library |
| tests | `cage-tests` and the existing suites | depend on the libraries above instead of compiling `cli/src` | registry libraries |

## Classification of the on-chain modules

| module | owner | reason |
|---|---|---|
| `open_datum`, `application/envelope`, `open_datum.tests` | open datum | the application's spend and mint law and its envelope; nothing in the registry imports them |
| `open`, `open.tests`, `OpenRedeemer` in `types` | registry | the registry's neutral approval policy: parameterless, it protects nobody, and its asset name is the registry's own binding function `approvalName`, recomputed by the cage at fold time; the registry's journeys and generic rows load it; `open_datum` does not import it |
| `lib`, `types`, `witness`, `state`, `request`, `shared`, `staking`, `registry/*`, `registry_fixtures`, cage modules and tests | registry | the registry's law; the modules that `open_datum` and its tests import (`lib`, `types`, `witness`, `state`, `registry/duty`, `registry/refusal`, `registry/settlement`, `registry_fixtures`, and what those need) move to `onchain/lib/` |

## Rules

- **application-boundary** (invariant): no module of registry-library, registry-cli or `singular` imports `Singular.Application.OpenDatum.*`, and none of those components lists the open-datum library in `build-depends`. Enforced by `application-boundary-check` and by the cabal dependency graph until slice 4 widens it into the separation rule.
- **registry-names-no-application** (invariant, from slice 4 for `offchain/`, slice 5 for `onchain/`): no file under `offchain/` or `onchain/` names an application's module, path or validator title. Enforced by `application-separation-check`.
- **application-reaches-only-the-registry** (invariant): an application's package, Aiken project and flake name nothing outside their own tree except the registry packages they depend on, and neither application names the other's tree. Enforced by `application-separation-check`.
- **hashes-unchanged** (invariant): the hashes of the registry project and the open-datum project together equal the base hashes. Enforced by `script-hash-comparison`.
- **one-flag-group** (invariant): the flag group lives in registry-cli and is parsed by one function; `singular`, `open-datum` and `keri-stub` call it, none re-spells a flag.
- **value-is-the-only-door** (invariant): the open-datum knowledge `Fold`, `Live`, `Reconcile`, `Inspect`, `Create`, `Registry`, `Preview` hold today (envelope check, holding lookup, release, decode, pin title, recognised script hash) is reached only through the application value.
- **booking-written-once** (invariant): the early refusal of a booking the current leaf rules out exists in `Singular.CLI.Booking` and nowhere else.
- No promotion upstream: `cardano-keri` consumes `registry-cli` and the registry library as published components; nothing in this ticket moves code into that repository.
