# Functions

Retroactive record, written 2026-09-15 from PR #112 merged at
`b4a36eaf72d8a355d9048a00081a8f999c195e27`.

## Validator functions

No bodies here.

| Function | Arguments | Result | Constraint |
| --- | --- | --- | --- |
| `representative_name` | `key` | asset name | Exactly `blake2b_256(key)`; no second name site. |
| fold arm | folded request, mint | accept or refuse | Minted name must equal `representative_name` of the key from the consumed native Insert selected by the Modify action; only a processed Insert paired with an update yields the key. |
| retire and burn arms | stored record, burn | accept or refuse | Burned name must equal `representative_name(key)` of the unchanged spelling; custody completion checks the Update key against it. |
| representative mint and burn | transaction, registry reference | accept or refuse | The transaction's registry identity must equal the `registry` parameter, with the configured executing policy. |
| representative withdraw | withdrawal witness | accept or refuse | Executes the validator at the credential read from the referenced state against the exact registry parameter. |

## Offchain mirror

| Function | Arguments | Result | Constraint |
| --- | --- | --- | --- |
| `representativeName` | spelling bytes | asset name | Byte-for-byte mirror of the on-chain equation. |
| `consumer_representative_name` | request name | asset name | Same equation at the consumer hook. |
| seed-before-policy | bootstrap seed | applied policy | The deployment and every attached runner derive the identical policy from the manifest seed. |
| evidence verification | retained transitions | accept or refuse | Establishes the actual name, the applied policy and the connected state transition; selects accepted record transitions. |

## Deployment checks

Compiled policy compared with the manifest and live state; live
registration queried for representative, consumer, custody and
staking credentials with reuse of existing registrations; a
substituted manifest policy rejected; attached counts unchanged;
fresh control exercises the foreign-registry refusal.

## Test surface

Aiken naming suite with the spelling-hash accept, the newline
preimage mutant killed, the rejected-spelling and wrong-hash
refusals, the foreign-registry reference refusal and the
missing-witness control; Haskell register and retire-verify specs
pinning the `e11d8149…` digest and its newline sensitivity.
