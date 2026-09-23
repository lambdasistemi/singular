# Data

No new type and no new field.

For one `deleteActive` request on key `k` under this registry's active policy:

| Side | Active token `(activePolicy, k)` |
|---|---|
| Input | the single holder UTxO that carries quantity 1 |
| Mint | quantity `-1` |
| Output | absent |

The coin on that input returns as ada change. The approval token still returns to its owner. The state output keeps the state token.

Identity of the asset is the active policy pin and the request key. Another key or another policy is not that input.
