# Functions

No new exported function. No signature change.

| ID | Existing function | Constraint this ticket adds |
|---|---|---|
| F1 | `deltaOf` | Edge 5 stays `[(1, -1)]`. |
| F2 | `dutiesFor` | Edge 5 produces the witness input that holds `(activePolicy, key)` at quantity 1, and no carrier output for that asset. |
| F3 | `expectedSequenceOutcome` | `deleteActive` is an agreeing step. `witnessTerminal` stays unsupported. `deleteAbsent` is not added. |

`burnSource` already selects that input for edge 3: one candidate, quantity exactly 1, this registry's active policy, this key.
