# Wire callable contracts

As an existing caller, I need the same functions at the `Singular.Registry.Types` import path even when their definitions move.

## Public callables

| ID | Callable | Argument, result and effect constraint |
| --- | --- | --- |
| edge-insert-absent | `edgeInsertAbsent`, `edgeInsertActive`, `edgeUpdateActive`, `edgeUpdateTerminal`, `edgeDeleteAbsent`, `edgeDeleteActive`, `edgeWitnessTerminal :: Edge` | Preserve the seven current integer tags. |
| edge-name | `edgeName :: Edge -> String` | Preserve admitted names and the fallback for any other integer. |
| request-phase | `requestPhase :: SlotNo -> SlotNo -> SlotNo -> RequestPhase` | Preserve the two strict boundary comparisons and the returned phase. |
| state-active-policy-bytes | `stateActivePolicyBytes`, `stateAppPolicyBytes`, `stateAbsentPolicyBytes`, `stateTerminalPolicyBytes :: OnChainTokenState -> ByteString` | Preserve the selected state field and its underlying bytes. |

`ToData`, `FromData` and `UnsafeFromData` are mapped per type in `data-model.md`. Each instance stays beside its type in the owning module. Shared conversion helpers are internal and have no new public API. No constructor, record selector or visible import path may be dropped from the `Types` facade.
