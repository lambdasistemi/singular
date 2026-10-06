{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeApplications #-}

-- | Fresh, session-bound public replay. No nodes or selections survive a read.
module Singular.Registry.TrieState.Lineage
    ( lineageTrieState
    , lineageTrieStateObserved
    ) where

import Cardano.Crypto.Hash (hashFromBytes)
import Cardano.Ledger.Alonzo.Tx (IsValid (..))
import Cardano.Ledger.Api.Tx (bodyTxL, isValidTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body (outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (TxOut, valueTxOutL)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Binary (decCBOR, decodeFullAnnotator)
import Cardano.Ledger.Core (eraProtVerHigh)
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxId, TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import Control.Monad (foldM, forM_, unless)
import Control.Monad.State.Strict (runState)
import Data.ByteString.Lazy qualified as BSL
import Data.Foldable (toList)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Lens.Micro ((^.))
import MPF.Backend.Pure (emptyMPFInMemoryDB)
import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.LedgerProvider qualified as LP
import Singular.Registry.Replay (Replayed (..), replayLineage)
import Singular.Registry.Trie.Pure (stateTrie)
import Singular.Registry.TrieState.Core (snapshotObserved)
import Singular.Registry.TrieState.Types

lineageTrieState :: (Monad m) => LP.Session w m -> TrieState m
lineageTrieState session = lineageTrieStateObserved session (const (pure ()))

lineageTrieStateObserved
    :: (Monad m)
    => LP.Session w m
    -> (TrieObservation -> m ())
    -> TrieState m
lineageTrieStateObserved session emit = TrieState select accept
  where
    select chosen use
        | pointSession point /= LP.sessionId session
            || pointBinding point /= LP.sessionBinding session =
            pure (Left (StaleState who Nothing NoSelection))
        | otherwise = case assetOf who of
            Nothing -> pure (Left (WrongRegistry who Nothing UnknownRegistry))
            Just asset -> do
                supplied <- LP.history session asset (LP.HistoryRange Nothing Nothing)
                material <- case supplied of
                    Left failure -> pure (Left (providerRefusal who failure))
                    Right stream -> drain who stream
                case material >>= checkBlocks who asset of
                    Left why -> pure (Left why)
                    Right (resolved, transactions) -> do
                        let (answer, nodes) =
                                runState
                                    ( replayLineage
                                        stateTrie
                                        who
                                        (pointOutput point)
                                        (trieSelectionRoot chosen)
                                        resolved
                                        transactions
                                    )
                                    emptyMPFInMemoryDB
                        case answer of
                            Left why -> pure (Left why)
                            Right Replayed{replayedFolds} -> do
                                emit (Selected chosen)
                                Right
                                    <$> use
                                        ( snapshotObserved
                                            emit
                                            chosen
                                            nodes
                                            (CompleteFromCreate (length replayedFolds))
                                        )
      where
        who = trieSelectionIdentity chosen
        point = trieSelectionPoint chosen
    -- Inclusion is established by the caller. It creates no cache, so the
    -- next selection must obtain and replay public history again.
    accept (ObservedFold from to _) = do
        emit (FoldAccepted from to)
        pure (Right ())

assetOf :: RegistryIdentity -> Maybe LP.Asset
assetOf (RegistryIdentity (StatePolicyId policy) name) =
    (,name) . PolicyID . ScriptHash <$> hashFromBytes policy

drain
    :: (Monad m)
    => RegistryIdentity
    -> LP.HistoryStream m
    -> m (Either TrieFailure [LP.HistoryBlock])
drain who = go Nothing []
  where
    go previous reversed stream =
        LP.nextBlock stream >>= \case
            Left failure -> pure (Left (providerRefusal who failure))
            Right Nothing -> pure (Right (reverse reversed))
            Right (Just (block, rest)) -> case previous of
                Just height
                    | LP.blockHeight block <= height ->
                        pure
                            ( Left
                                ( providerRefusal
                                    who
                                    (LP.HistoryOrderMismatch height (LP.blockHeight block))
                                )
                            )
                _ -> go (Just (LP.blockHeight block)) (block : reversed) rest

checkBlocks
    :: RegistryIdentity
    -> LP.Asset
    -> [LP.HistoryBlock]
    -> Either TrieFailure (Map TxIn (TxOut ConwayEra), [ConwayTx])
checkBlocks who asset blocks = do
    (resolved, reversed) <- foldM block (Map.empty, []) blocks
    pure (resolved, reverse reversed)
  where
    block (resolved, transactions) whole = do
        let records = NE.toList (LP.blockTransactions whole)
            creators = Set.fromList (map LP.historicalId records)
        (_, after, reversed) <-
            foldM
                (transaction creators)
                (Set.empty, resolved, transactions)
                records
        pure (after, reversed)
    transaction creators (seen, resolved, transactions) record = do
        tx <- decode record
        forM_ (LP.spentOutputs record) $ \(TxIn creator _, output) ->
            unless
                ( not (holds asset output)
                    || not (Set.member creator creators)
                    || Set.member creator seen
                )
                $ Left
                    ( providerRefusal
                        who
                        (LP.MissingInBlockParent (LP.historicalId record) creator)
                    )
        let produced =
                zipWith
                    (\index output -> (TxIn (txIdTx tx) (TxIx index), output))
                    [0 ..]
                    (toList (tx ^. bodyTxL . outputsTxBodyL))
        unless (produced == LP.createdOutputs record) $
            mismatch record "created outputs disagree with transaction CBOR"
        after <-
            foldM
                merge
                resolved
                (LP.spentOutputs record <> LP.referenceOutputs record <> produced)
        pure (Set.insert (txIdTx tx) seen, after, tx : transactions)
    decode record = do
        tx <-
            either
                ( \why ->
                    mismatch
                        record
                        ("transaction CBOR cannot be decoded: " <> T.pack (show why))
                )
                Right
                ( decodeFullAnnotator
                    (eraProtVerHigh @ConwayEra)
                    "ConwayTx"
                    decCBOR
                    (BSL.fromStrict (LP.historicalCbor record))
                )
        unless
            (tx == LP.historicalTx record && txIdTx tx == LP.historicalId record)
            $ mismatch record "transaction body or identity disagrees with CBOR"
        unless ((tx ^. isValidTxL == IsValid True) == LP.scriptValid record) $
            mismatch record "script validity disagrees with CBOR"
        pure tx
    mismatch record message =
        Left
            ( providerRefusal
                who
                (LP.HistoryMaterialMismatch (LP.historicalId record) message)
            )
    merge resolved (input, output) = case Map.lookup input resolved of
        Just old
            | old /= output ->
                Left
                    ( HistoryIncomplete
                        who
                        (Just (inputId input))
                        (ConflictingResolution input)
                    )
        _ -> Right (Map.insert input output resolved)

holds :: LP.Asset -> TxOut ConwayEra -> Bool
holds (policy, name) output =
    let MaryValue _ (MultiAsset assets) = output ^. valueTxOutL
    in  Map.findWithDefault
            0
            name
            (Map.findWithDefault Map.empty policy assets)
            /= 0

inputId :: TxIn -> TxId
inputId (TxIn tx _) = tx

providerRefusal
    :: RegistryIdentity -> LP.HistoryFailure -> TrieFailure
providerRefusal who failure = HistoryIncomplete who transaction (ProviderHistoryFailure failure)
  where
    transaction = case failure of
        LP.HistoryReadFailure (LP.MissingOutput input) -> Just (inputId input)
        LP.HistoryReadFailure (LP.ConflictingOutput input) -> Just (inputId input)
        LP.HistoryDependencyCycle (tx NE.:| _) -> Just tx
        LP.MissingInBlockParent tx _ -> Just tx
        LP.DuplicateSpend input -> Just (inputId input)
        LP.HistoryMaterialMismatch tx _ -> Just tx
        _ -> Nothing
