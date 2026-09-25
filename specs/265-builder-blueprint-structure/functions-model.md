# Function contracts

As a contributor, I want each moved operation to retain its current callable
contract while gaining one focused implementation owner.

```mermaid
flowchart LR
    Callers[Existing callers] -->|same signature| Facade[Existing module]
    Facade -->|reexport| Owner[Focused module]
```

## Callable contracts

| ID | Existing function family | Signature constraint |
| --- | --- | --- |
| F265-1 | Blueprint `loadBlueprint`, `validateData`, `extractScriptHash`, `extractCompiledCode` | Preserve exact public signatures and results. |
| F265-2 | Blueprint `applyDataParam`, `applyIntParam`, `applyBytesParam`, `applyOutputRef`, `applyPreviousPolicies`, `applyRequestParams`, `loadRegistryCodesFromEnv` | Preserve exact public signatures, parameter order and error values. |
| F265-3 | All exports of `TxBuilder.Internal`, including `evaluateAndBalance`, `failedWitnessHash`, `evalScriptHash`, `isBudgetFailure` and `walkEdge` | Preserve exact public signatures, observable effects and failure text. |

The complete function-by-function before/after location map is a delivery
artifact; this model does not add or change a public signature.
