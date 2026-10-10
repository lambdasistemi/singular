# Data model

Fields, relationships, validation. Types are the registry's existing ones unless named here. Output ceiling: 6 KB.

## Application value (registry-library)

| field | meaning | validation |
|---|---|---|
| application name | what receipts and refusals call the application (`open-datum`, `keri-stub`); the neutral value has none | non-empty for a named value |
| application executable | the binary that folds this application's terminations | present for every named value; absent only on the neutral value |
| pin | how the registry's application policy is fixed | one of the three forms below |
| decoder | reads a datum into a holding view; absent on the neutral value | a datum it cannot read yields a named reason, never a partial view |
| holding rules | find this registry's holding of a key among the outputs at the application, and release it in a fold; absent on the neutral value | a termination requires them |
| recognised scripts | the application's script names and hashes that `inspect` labels in an output; empty on the neutral value | hashes come from the application's own identity record, never from the registry |

## Pin forms

| form | meaning | who uses it |
|---|---|---|
| pinned by hash | a 28-byte policy hash given as input | the application-policy input of `create`, wired with the open-datum executable |
| pinned by script | the validator title in the blueprint, and how the registry identity (state policy and token name) is applied to it | open-datum, keri-stub |
| read from state | attach to a registry, taking the application pin from the state datum it carries | `singular` on an existing registry |

For the first form no script bytes exist: no reference output for the application is published by `create`.

## Booking

| field | meaning |
|---|---|
| key | the registry key |
| edge | `insertActive` or `updateTerminal`; the other five edges are refused as today |
| minted | the assets the application mints in the booking transaction: the approval under its policy, its script and redeemer |
| destination | the address and inline datum the fold will deliver to, or none for a termination |
| deposit | lovelace the request holds |

A **booking refusal** names the key, the edge, the leaf found and the leaf required, and is labelled client policy. It is raised before any key is read for signing and in preview alike. The fold still validates on its own; the early refusal never replaces it.

## Neutral behaviours (A-001)

- `singular registry fold` on an insertion: the delivered datum is the request's own, so nothing is decoded; the delivered output is read back at the request's own destination.
- `singular registry fold` on a termination: refused before anything is built, naming the application's executable when the state datum's pin matches a known value, otherwise naming that the application's own binary is needed.
- `singular registry inspect`: raw datums for the key's outputs; no envelope fields.
- The application-policy input of `create`, a HEX policy hash, wired with the open-datum executable: pins that hash; publishes the other reference outputs as today.
- Reconcile matches a journalled `active:` or `payload:` expectation against the hash of the live output's datum bytes; for the open-datum value that hash is the envelope hash, as today.

## Separation records

| record | meaning | validation |
|---|---|---|
| base hashes | the hashes of every validator of the single Aiken project at base, one row per title, recorded under `specs/528-registry-cli-split/evidence/` | the registry project and the open-datum project together reproduce exactly this set; a title may change when only its module path changed, a hash may not |
| tree rule | the names that mark an application (module names, validator titles, the application tree paths) | no file under `offchain/` or `onchain/` contains one; an application tree contains no path outside itself other than the registry packages it depends on |
