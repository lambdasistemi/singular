# Functions model

New or changed signatures only: names, explicit arguments, argument and result types, constraints and effects. No bodies. Output ceiling: 6 KB.

## registry-library

| name | arguments | result | constraint |
|---|---|---|---|
| `neutralApplication` | none | application value | no name, no executable, no decoder, no holding rules; pin read from state |
| `hashPinnedApplication` | `policy`: 28-byte hash | application value | the neutral value with the pin fixed by hash |
| `configForApplication` (changed) | `pin`: pin form; `codes`; `stateBytes`; `requestBytes`; `economics`; `network`; `seed` | configuration and codes | replaces the `Application` enumeration argument; for pinned by hash the codes carry no application script |
| `resolveRegistry` (changed) | `application`: application value; `release`; `token`; `session` | resolved registry or identity refusal | the application pin is compared with the state datum only for pinned-by-script; read from state otherwise; the three witness pins are compared as today |

## registry-cli

| name | arguments | result | constraint |
|---|---|---|---|
| `commonFlagGroup` | none | flag group | the spellings of `--state-token`, `--koios-url`, `--network-magic`, `--wallet-skey`, `--wallet-address`, `--preview`, `--receipt` and the funding limits, with today's refusals |
| `parseFlagGroup` | `environment`; `words`; `flags` | common settings or CLI error | the single reader both binaries call; a flag it does not own is returned untouched |
| `runRegistryCommand` (was `runCommand`) | `application`: application value; `env`; `command` | exit code | dispatches create, fold, reject, reclaim, inspect, help; no insert, update or terminate |
| `runCreate`, `runFold`, `runInspect` (changed) | `application` first, then today's arguments | as today | `runFold` on a termination with no holding rules refuses before building |
| `runReject`, `runReclaim` | as today | as today | unchanged: they take no application |
| `bookRequest` | `env`; `attached`: attached registry; `booking`; `mode`: preview or submit | booked request or booking refusal | reads the key's current leaf from the attached lineage; refuses before any signing key is read |
| `runFoldAfterBooking` | `application`; `env`; `booked` | fold outcome | the `--fold` of an application binary; runs exactly the routine `runFold` runs |

## open-datum-package

| name | arguments | result | constraint |
|---|---|---|---|
| `openDatumApplication` | none | application value | name `open-datum`, executable `open-datum`, pinned by script `open_datum.open_datum` applied to the registry identity, decoder and holding rules from the envelope, and the recognised script `open_datum.open_datum` with its hash from the application's own identity record |
| `parseOpenDatumCommand` | `environment`; `words` | open-datum command or CLI error | verbs create, insert, update, terminate, fold, inspect; reads the common flags through `parseFlagGroup` |
| `runOpenDatum` | `environment`; `arguments` | exit code | what `open-datum`'s `Main` runs |

## keri-stub

| name | arguments | result | constraint |
|---|---|---|---|
| `keriStubApplication` | none | application value | its own always-succeeding approval policy, pinned by script; imports nothing from the open-datum package |
| `runKeriStub` | `environment`; `arguments` | exit code | verbs register, convict, status; `--fold` as the open datum has it |

## separation controls

| name | arguments | result | constraint |
|---|---|---|---|
| `application-separation-check` | repository root | exit status and the offending file with the name found | fails on a registry-side naming and on an application-side reach; the application trees may name the registry packages |
| `application-separation-controls` | repository root | exit status | plants a registry-side naming and an application-side reach in a scratch copy and fails unless the check refuses both |
| `script-hash-comparison` | the registry blueprint; the open-datum blueprint; the base hashes | exit status | fails unless the union of validator hashes equals the base set; a control plants a changed hash |
