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
  and the one transaction story language program a fold submits.

No algorithm lives here; each decision has exactly one owner above.
-}
module Singular.Registry.TxBuilder.Update
    ( updateTokenImpl
    , updateTokenWithDuties
    , updateTokenWithTrieState
    , emptyRegistryContext
    , RegistryDuties (..)
    , RegistryContext (..)
    , HolderRelease (..)
    , registryDuties
    ) where

import Cardano.Ledger.Api.Tx.Out (TxOut)
import Control.Monad (when)
import Data.List.NonEmpty qualified as NE
import Data.Void (Void)

import Cardano.Ledger.Address (Addr)
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Config
    ( CageConfig (..)
    )
import Singular.Registry.Ledger
    ( ConwayEra
    , Root (..)
    , TokenId (..)
    , TxIn
    )
import Singular.Registry.Provider
    ( View (..)
    )
import Singular.Registry.Trie
    ( TrieManager (..)
    )
import Singular.Registry.TrieState qualified as TS
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
    ( HolderRelease (..)
    , RegistryContext (..)
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
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRequest (..)
    , OnChainRoot (..)
    , OnChainTokenState (..)
    , ProofStep
    )

-- | Build an update-token transaction (fair fee).
updateTokenImpl
    :: CageConfig
    -> View IO
    -> TrieManager IO
    -> TokenId
    -> Addr
    -> IO ConwayTx
updateTokenImpl cfg view tm tid addr =
    updateTokenWithDuties cfg view tm tid addr emptyRegistryContext

{- | Fold the pending requests, discharging every obligation the edges
they take create (#157 mint-matches-edge-deltas, token-destinations-and-refunds, T1-T6).
-}
updateTokenWithDuties
    :: CageConfig
    -> View IO
    -> TrieManager IO
    -> TokenId
    -> Addr
    -> RegistryContext
    -> IO ConwayTx
updateTokenWithDuties cfg view tm tid addr ctx0 =
    updateTokenUsing cfg view tid addr ctx0 (const (computeProofs tm tid))

{- | The current command path obtains its consumed proof bytes and new root
from the selected capability snapshot. Transaction duties and provider reads
remain in the same shared builder as the retained lower-level adapters.
-}
updateTokenWithTrieState
    :: CageConfig
    -> View IO
    -> TS.TrieSnapshot IO
    -> TokenId
    -> Addr
    -> RegistryContext
    -> IO ConwayTx
updateTokenWithTrieState cfg view snap tid@(TokenId name) addr ctx0 =
    updateTokenUsing cfg view tid addr ctx0 $ \(stateIn, stateOut) requests -> do
        let expected =
                TS.RegistryIdentity
                    (TS.StatePolicyId (scriptHashBytes (cfgScriptHash cfg)))
                    name
        let refuse why = error ("TrieState " <> show why)
        when (TS.trieIdentity snap /= expected) $
            refuse
                ( TS.WrongRegistry
                    expected
                    Nothing
                    (TS.OtherRegistry (TS.trieIdentity snap))
                )
        when (TS.pointOutput (TS.triePoint snap) /= stateIn) $
            refuse
                ( TS.StaleState
                    expected
                    Nothing
                    (TS.StaleOutput (TS.pointOutput (TS.triePoint snap)) stateIn)
                )
        case extractCageDatum stateOut of
            Just (StateDatum state)
                | unOnChainRoot (stateRoot state) == unRoot (TS.trieRoot snap) ->
                    pure ()
                | otherwise ->
                    refuse
                        ( TS.StaleState
                            expected
                            Nothing
                            ( TS.StaleRoot
                                (TS.trieRoot snap)
                                (Root (unOnChainRoot (stateRoot state)))
                            )
                        )
            _ ->
                refuse
                    (TS.UndecodableRequest expected Nothing TS.UndecodableStateOutput)
        moves <- case traverse requestEdgeOf requests >>= NE.nonEmpty of
            Nothing ->
                refuse
                    ( TS.UndecodableRequest
                        expected
                        Nothing
                        (TS.UnreadableRecord "the fold's requests name no edge")
                    )
            Just ordered -> pure ordered
        walked <- TS.speculateEdges snap moves >>= either refuse pure
        pure (TS.walkProofs walked, TS.walkRoot walked)
  where
    requestEdgeOf (_, out) = case extractCageDatum out of
        Just (RequestDatum request) -> Just (requestKey request, requestEdge request)
        _ -> Nothing

updateTokenUsing
    :: CageConfig
    -> View IO
    -> TokenId
    -> Addr
    -> RegistryContext
    -> ( (TxIn, TxOut ConwayEra)
         -> [(TxIn, TxOut ConwayEra)]
         -> IO ([[ProofStep]], Root)
       )
    -> IO ConwayTx
updateTokenUsing cfg view tid addr ctx0 makeProofs = do
    (stateUtxo, reqUtxos, feeUtxo, pp) <-
        queryContext cfg view tid addr
    let (stateIn, stateOut) = stateUtxo
    (proofs, newRoot) <-
        makeProofs stateUtxo reqUtxos
    let (oldState, newStateOut, script) =
            prepareState
                cfg
                stateOut
                newRoot
        requestScript = mkRequestScript cfg tid
    ctx <-
        completeContext cfg view addr script ctx0
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
        computeUpperSlot view oldState reqUtxos
    let evalTx = mkEvalTx view
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
