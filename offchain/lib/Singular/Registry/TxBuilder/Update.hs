{- |
Module      : Singular.Registry.TxBuilder.Update
Description : Update token transaction — the public fold facade
License     : Apache-2.0

Builds the oracle update transaction that processes
all pending requests for a token. Consumes the State
UTxO and all request UTxOs, applies each operation
speculatively through the trie to generate proofs,
then outputs a new State UTxO with the updated root
and per-request refund outputs.

This module is the fold's public orchestration and its compatibility
surface: the six exports every caller imports are re-exported
unchanged, and the two entry points coordinate the three owners the
fold's work is divided into (#267):

- "Singular.Registry.TxBuilder.Update.Context" — the registry context,
  its queries, the ordered speculative proofs, the state continuation
  and the validity slot;
- "Singular.Registry.TxBuilder.Update.Duties" — what the fold's
  requests owe (mints, destinations, custody, returns, signatures);
- "Singular.Registry.TxBuilder.Update.Build" — the evaluation adapter
  and the one transaction DSL program a fold submits.

No algorithm lives here; each decision has exactly one owner above.
-}
module Singular.Registry.TxBuilder.Update
    ( updateTokenImpl
    , updateTokenWithDuties
    , emptyRegistryContext
    , RegistryDuties (..)
    , RegistryContext (..)
    , registryDuties
    ) where

import Data.Void (Void)

import Cardano.Ledger.Address (Addr)
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Config
    ( CageConfig (..)
    )
import Singular.Registry.Ledger
    ( TokenId
    )
import Singular.Registry.Provider
    ( Provider (..)
    )
import Singular.Registry.Trie
    ( TrieManager (..)
    )
import Singular.Registry.TxBuilder.ConnectedFold
    ( ConnectedSpend (..)
    )
import Singular.Registry.TxBuilder.Internal.Identity
import Singular.Registry.TxBuilder.Update.Build
    ( NoCtx
    , buildProgram
    , mkEvalTx
    )
import Singular.Registry.TxBuilder.Update.Context
    ( RegistryContext (..)
    , completeContext
    , computeProofs
    , computeUpperSlot
    , emptyRegistryContext
    , prepareState
    , queryContext
    )
import Singular.Registry.TxBuilder.Update.Duties
    ( RegistryDuties (..)
    , registryDuties
    )

-- | Build an update-token transaction (fair fee).
updateTokenImpl
    :: CageConfig
    -> Provider IO
    -> TrieManager IO
    -> TokenId
    -> Addr
    -> IO ConwayTx
updateTokenImpl cfg prov tm tid addr =
    updateTokenWithDuties cfg prov tm tid addr emptyRegistryContext

{- | Fold the pending requests, discharging every obligation the edges
they take create (#157 C5, C6, T1-T6).
-}
updateTokenWithDuties
    :: CageConfig
    -> Provider IO
    -> TrieManager IO
    -> TokenId
    -> Addr
    -> RegistryContext
    -> IO ConwayTx
updateTokenWithDuties cfg prov tm tid addr ctx0 = do
    (stateUtxo, reqUtxos, feeUtxo, pp) <-
        queryContext cfg prov tid addr
    let (stateIn, stateOut) = stateUtxo
    (proofs, newRoot) <-
        computeProofs tm tid reqUtxos
    let (oldState, newStateOut, script) =
            prepareState
                cfg
                stateOut
                newRoot
        requestScript = mkRequestScript cfg tid
    ctx <-
        completeContext cfg prov addr script ctx0
    duties <- case registryDuties
        cfg
        pp
        oldState
        ctx
        reqUtxos
        (map (const True) reqUtxos) of
        Right d -> pure d
        Left err -> error ("updateToken: " <> err)
    upperSlot <-
        computeUpperSlot prov oldState reqUtxos
    let evalTx = mkEvalTx prov
        prog =
            buildProgram
                cfg
                pp
                stateIn
                stateOut
                reqUtxos
                feeUtxo
                oldState
                newStateOut
                script
                requestScript
                proofs
                upperSlot
                duties
                (rcRefUtxos ctx)
    result <-
        Tx.build
            (Tx.mkPParamsBound pp)
            (Tx.InterpretIO (const (pure undefined)))
            evalTx
            ( feeUtxo
                : stateUtxo
                : reqUtxos
                    <> map csUtxo (rdSpends duties)
                    <> rdInputs duties
            )
            (rcRefUtxos ctx)
            addr
            (prog :: Tx.TxBuild NoCtx Void ())
    case result of
        Right tx -> pure tx
        Left err ->
            error $
                "updateToken: build failed: "
                    <> show err
