# Data

Retroactive record, written 2026-09-15 from PR #112 merged at
`b4a36eaf72d8a355d9048a00081a8f999c195e27`.

## Asset name

```mermaid
erDiagram
  SPELLING ||--|| DIGEST : hashes to
  DIGEST ||--o| LIVE-NFT : mints under policy
  POLICY ||--o{ LIVE-NFT : scopes
```

| Field | Type | Validation |
| --- | --- | --- |
| spelling | exact UTF-8 bytes supplied | no normalization, no added suffix or newline |
| asset name | 32 bytes | exactly `blake2b_256(spelling bytes)` — no registry, controller, prefix or incarnation bytes |
| demo digest | 32 bytes | `alice` hashes to `e11d8149…abbda4c`; `alice` plus newline hashes to `79cf3829…` |

## Policy parameters

| Field | Type | Validation |
| --- | --- | --- |
| application policy | policy id | the unparameterized application validator's hash |
| registry identity | asset identity | `registry_asset_id(state policy bytes, token name)` — the canonical registry's state credential and token |
| executing policy | policy id | configured at application; mint and burn require it |

The application validator itself takes no parameters. Every
application site passes the registry identity, including the
deployment command.

## Registry binding

Mint and burn enforce the exact registry state credential and token
at quantity one. Maintenance and recovery authorize against the
spent record and preserve its token without reading referenced
registry state; completion spends the registry state and executes
the registry-bound burn policy; retirement executes the
representative validator through a withdrawal witness at the
credential read from the referenced state.

## Lifecycle values

Naming has permanent Over and incarnation zero. Over means the name
was minted and then burned; unclaimed means it was never minted.
The two are told apart through asset history for the same policy
and name. The abstract model keeps naming scope zero.
