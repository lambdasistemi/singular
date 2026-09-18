# #157 — data model

On-chain shapes, indices and invariants. No bodies.

## The leaf

| state | byte |
|---|---|
| Absent | `0x00` |
| Active | `0x01` |
| Terminal | `0x02` |

Any other value bytes are refused before a proof is checked. The naming-era
values — the representative name, the `over` marker — are not leaves.

## `Operation` (indices published; `Read` appended)

| index | constructor | fields |
|---|---|---|
| 0 | `Insert` | `value` |
| 1 | `Delete` | `value` |
| 2 | `Update` | `old, new` |
| 3 | `Read` | `value` — only `0x02` admitted |

## `Request` (field appended)

```
requestToken, requestOwner, requestKey, requestValue, tip, submitted_at,
destination: (address_bytes, datum_hash)
```

`destination` names where a minted active or terminal token goes and the
inline datum the receiving output must carry (`datum_hash` empty for none).
For `Insert(0x00)` the address is the refund address; the token goes to
custody.

For retirement completion, `requestToken` is the same registry's seed-derived
cage token. The request is locked by the ordinary request validator applied to
that cage token and the registry state policy ID; the validator identity is not
a request or redeemer field.

## `State` (eight fields, replaces six)

| field | role | change |
|---|---|---|
| `root` | the trie root | — |
| `tip` | the fold economics | — |
| `process_time` | the request window | — |
| `retract_time` | the retraction window | — |
| `application_policy` | certifies requests | new pin |
| `active_policy` | mints the active token | renamed from `representative_policy` |
| `absent_policy` | mints the absent token | new pin |
| `terminal_policy` | mints the terminal token | new pin |

`consumer_pin` is deleted. All four policies are set at genesis and preserved
by every `Modify`.

## `CageDatum` (constructor appended)

| index | constructor | fields |
|---|---|---|
| 0 | `RequestDatum` | `Request` |
| 1 | `StateDatum` | `State` |
| 2 | `AbsentCustody` | `key, refund` |

`RequestDatum` remains spendable only at the ordinary request validator through
`Contribute`. The cage/state validator gains no `RequestDatum` spending arm.

## Token identity

Under each of the three policies the asset name is the registry key. Identity
is `(policy, key)`. A key recreated after `Delete(0x01)` carries the same
identity.

## The approval

Minted under `application_policy`, quantity 1, asset name
`blake2b_256(edge ‖ key ‖ owner ‖ destination)`; `edge` one byte, the C2 row
index (`0` insertAbsent … `5` deleteActive). Carried by the request UTxO;
recomputed by the cage; not burned at fold.

## Naming's redeemers (contract change, declared)

| purpose | constructors after this ticket |
|---|---|
| application spend | `Maintain` 0, `Retire` 1, `Recover` 2 |
| application mint | `Approve { edge, key, owner, destination }` 0 |
| witness mint | `Fold` 0 — the only redeemer; the cage decides quantities |

## Naming application parameters and pending retirement

NYA is applied to one immutable `request_validator_hash`. That hash is derived
from the compiled ordinary request validator applied to `(state_policy_id,
cage_token_name)` for the same registry. `cage_token_name` is derived from a
pre-existing seed output reference; the cage script has no application-policy
parameter. Those two assumptions keep the dependency acyclic. The applied NYA
identity then determines `application_policy`, which genesis pins.

A pending retirement records exactly `(request_validator_hash, requestToken,
approved Update(0x01,0x02) request)`. Retirement creates it and moves the active
token to completion custody while the leaf stays Active. Completion consumes
that stored object, validates its home, same-registry token and bound approval,
then alone removes the active holding and writes Terminal.

## State invariants the cage keeps

| invariant | statement |
|---|---|
| pins | the seven non-root fields are equal before and after every `Modify` |
| admissibility | only the seven C2 rows change or read the trie |
| admission | every consumed tree-edge request carries its bound approval |
| delta | mint under the three token policies equals the summed column exactly |
| custody | cage custody holds exactly the outstanding absent tokens, each with its key and refund address |
| destination | each minted active or terminal token is in exactly one output, the one its request named |
| coverage | every consumed request carries at least its tip |
