# #323 functions model

Signatures are binding in shape; exact module placement and auxiliary names are the commit owner's within the modules model.

- F1 `withView :: Provider m -> (View m -> m a) -> m a` — the only way to read (D3). Fails explicitly at origin and on lost connection (I3, I8).
- F2 `viewPoint :: View m -> ChainPoint`; `viewProtocolParams :: View m -> PParams ConwayEra` (pure: captured at acquire, I1).
- F3 `viewUTxOsAt :: View m -> Addr -> m [(TxIn, TxOut ConwayEra)]`; `viewScriptRegistered :: View m -> ScriptHash -> m Bool`; `viewEvaluateTx :: View m -> ConwayTx -> m (EvaluateTxResult ConwayEra)`; `viewPosixMsToSlot`, `viewPosixMsCeilSlot :: View m -> Integer -> m SlotNo`; `viewUTxOsByTxIn :: View m -> Set TxIn -> m (Map TxIn (TxOut ConwayEra))` only if a builder needs it.
- F4 `nodeProvider :: NetworkMagic -> N2C.Provider IO -> Provider IO` (M2).
- F5 `memoryProvider :: MemoryChain-handle -> Provider IO` plus the mutations the interleaving control needs (M3, D5).
- F6 `signTx :: signing key(s) -> ConwayTx -> SignedTx`; `submitSigned :: Submitter -> SignedTx -> IO submit-result` (D4).
- F7 Builders: every exported builder that took `Provider IO` takes `View IO` instead; signatures otherwise unchanged.
