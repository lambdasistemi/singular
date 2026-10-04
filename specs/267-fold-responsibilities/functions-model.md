# Fold callable contracts

As a caller, I need the same types and observable failures at the original
`Update` import path.

| ID | Callable | Argument/result and effect constraint |
| --- | --- | --- |
| update-token-impl | `updateTokenImpl :: CageConfig -> Provider IO -> TrieManager IO -> TokenId -> Addr -> IO ConwayTx` | Same arguments, result, fair-fee fold and errors; delegates to the unchanged public `updateTokenWithDuties`. |
| update-token-with-duties | `updateTokenWithDuties :: CageConfig -> Provider IO -> TrieManager IO -> TokenId -> Addr -> RegistryContext -> IO ConwayTx` | Same orchestration, query order, proof/state/duty sequence and `Tx.build` effects. |
| empty-registry-context | `emptyRegistryContext :: RegistryContext` | Same field defaults at the original public import path. |
| registry-duties | `registryDuties :: CageConfig -> PParams ConwayEra -> OnChainTokenState -> RegistryContext -> [(TxIn, TxOut ConwayEra)] -> [Bool] -> Either String RegistryDuties` | Same request/processed alignment, duty accumulation, outputs and named failures. |

`RegistryContext (..)` and `RegistryDuties (..)` retain all constructors and
record selectors through `Update`; internal placement adds no public API.
