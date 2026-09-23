# Modules

| ID | Module | Responsibility in this ticket |
|---|---|---|
| M1 | `Singular.Registry.TxBuilder.Internal` | `deltaOf` for edge 5 already names the active burn `[(1, -1)]`. Unchanged unless a repair discovers it does not. |
| M2 | `Singular.Registry.TxBuilder.Update` | `dutiesFor` for edge 5 must spend the holder UTxO that carries the active token, the same obligation edge 3 already discharges through `burnSource`. Callers of Internal. |
| M3 | `Conformance.Run` | The generic sequence's agreeing set. `deleteActive` joins the agreeing edges. No per-edge routine. |
| M4 | `Conformance.Book` | The unsupported-row sentence for `deleteActive` is emitted only while the receipt says unsupported. After regeneration that row is an agreeing step. |

Dependency direction stays as it is: the conformance runner calls the off-chain builder. The builder does not import the conformance suite.
