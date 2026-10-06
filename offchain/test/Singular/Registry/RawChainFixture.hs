{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

{- | Private deterministic raw facts for consumer interleavings. Each
acquisition captures an immutable value; common services calculate all
derived evaluation and time answers from these facts.
-}
module Singular.Registry.RawChainFixture
    ( ChainFacts (..)
    , RawChain
    , newRawChain
    , rawChainProvider
    , advanceChain
    , jumpChainTo
    , loseConnection
    , recordTransaction
    ) where

import Cardano.Ledger.Alonzo.Tx (IsValid (..))
import Cardano.Ledger.Api.Tx (bodyTxL, isValidTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( inputsTxBodyL
    , mintTxBodyL
    , outputsTxBodyL
    , referenceInputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..), TxIx (..))
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Core (eraProtVerHigh, hashScript)
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)
import Data.Bits (shiftR)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (toList)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Word (Word32)
import Lens.Micro ((^.))
import Singular.Registry.Evidence
    ( Evidenced (..)
    , NoWitness
    , SessionId (..)
    )
import Singular.Registry.Ledger (ConwayEra, PParams)
import Singular.Registry.LedgerProvider
import Singular.Registry.NetworkTime (NetworkTime)
import Singular.Registry.StubSession
    ( servingSessionWithId
    , stubSession
    )

data ChainFacts = ChainFacts
    { csNetwork :: Word32
    , csTip :: Maybe (SlotNo, BS.ByteString)
    , csPParams :: PParams ConwayEra
    , csUTxO :: Map TxIn (TxOut ConwayEra)
    , csRegistered :: Set ScriptHash
    , csNetworkTime :: NetworkTime
    }

data RawChain = RawChain
    { chainNetwork :: Network
    , chainFacts :: IORef ChainFacts
    , chainConnected :: IORef Bool
    , chainHistory :: IORef [HistoryBlock]
    -- ^ Every transaction recorded, oldest first, one block each
    , chainAcquisitions :: IORef Int
    -- ^ How many views were acquired: each view is named by its count
    }
newRawChain :: ChainFacts -> IO RawChain
newRawChain facts =
    RawChain (Network (csNetwork facts))
        <$> newIORef facts
        <*> newIORef True
        <*> newIORef []
        <*> newIORef 0

advanceChain :: RawChain -> (ChainFacts -> ChainFacts) -> IO ()
advanceChain chain change = atomicModifyIORef' (chainFacts chain) $ \facts ->
    let next = maybe 1 (succ . fst) (csTip facts)
    in  ((change facts){csTip = Just (next, blockHash next)}, ())

-- | Move the tip to a later slot, as the chain does while nothing reads it.
jumpChainTo :: RawChain -> SlotNo -> IO ()
jumpChainTo chain slot = atomicModifyIORef' (chainFacts chain) $ \facts ->
    (facts{csTip = Just (slot, blockHash slot)}, ())

loseConnection :: RawChain -> IO ()
loseConnection chain = atomicModifyIORef' (chainConnected chain) (const (False, ()))

{- | Record a transaction the chain is about to apply as public history, its
inputs and references resolved against the outputs live before it: a block
of its own, after every block recorded before it.
-}
recordTransaction :: RawChain -> ConwayTx -> IO ()
recordTransaction chain tx = do
    live <- csUTxO <$> readIORef (chainFacts chain)
    let txid = txIdTx tx
        resolved ins = [(i, out) | i <- Set.toList ins, Just out <- [Map.lookup i live]]
        record =
            HistoricalTransaction
                { historicalId = txid
                , historicalCbor =
                    BL.toStrict (serialize (eraProtVerHigh @ConwayEra) tx)
                , historicalTx = tx
                , spentOutputs = resolved (tx ^. bodyTxL . inputsTxBodyL)
                , referenceOutputs = resolved (tx ^. bodyTxL . referenceInputsTxBodyL)
                , createdOutputs =
                    zipWith
                        (\ix out -> (TxIn txid (TxIx ix), out))
                        [0 ..]
                        (toList (tx ^. bodyTxL . outputsTxBodyL))
                , scriptValid = tx ^. isValidTxL == IsValid True
                }
    atomicModifyIORef' (chainHistory chain) $ \blocks ->
        ( blocks
            <> [HistoryBlock (fromIntegral (length blocks) + 1) (record NE.:| [])]
        , ()
        )

rawChainProvider :: RawChain -> (Network, LedgerProvider NoWitness IO)
rawChainProvider chain =
    ( configured
    , LedgerProvider
        { acquire = \request action -> case request of
            Latest wanted
                | wanted /= configured -> pure (Left (WrongNetwork configured wanted))
            AtPoint wanted _
                | wanted /= configured -> pure (Left (WrongNetwork configured wanted))
            AtPoint _ point -> pure (Left (PointNotSupported point))
            Latest _ -> do
                alive <- readIORef (chainConnected chain)
                if not alive
                    then
                        pure
                            ( Left
                                (AcquisitionReadFailure (BackendReadFailure "ViewConnectionLost"))
                            )
                    else do
                        captured <- readIORef (chainFacts chain)
                        recorded <- readIORef (chainHistory chain)
                        case csTip captured of
                            Nothing ->
                                pure
                                    (Left (AcquisitionReadFailure (BackendReadFailure "AcquiredAtOrigin")))
                            Just (slot, header) -> do
                                let fact answer = do
                                        connected <- readIORef (chainConnected chain)
                                        pure $
                                            if connected
                                                then Right (Evidenced answer Nothing)
                                                else Left (BackendReadFailure "ViewConnectionLost")
                                    session =
                                        stubSession
                                            { sessionNetwork = Network (csNetwork captured)
                                            , outputs = \query -> do
                                                connected <- readIORef (chainConnected chain)
                                                pure $
                                                    if connected
                                                        then
                                                            fmap (`Evidenced` Nothing) (selectOutputs (csUTxO captured) query)
                                                        else Left (BackendReadFailure "ViewConnectionLost")
                                            , protocolParameters = fact (csPParams captured)
                                            , tipObservation =
                                                fact (TipObservation slot header (fromIntegral (unSlotNo slot)) 0)
                                            , networkTime = fact (csNetworkTime captured)
                                            , scriptRegistered = \script -> fact (Set.member script (csRegistered captured))
                                            , history = \asset _ ->
                                                pure (Right (streamOf (filter (touches asset) recorded)))
                                            }
                                n <-
                                    atomicModifyIORef' (chainAcquisitions chain) (\k -> (k + 1, k + 1))
                                acquire
                                    ( snd
                                        ( servingSessionWithId
                                            (pure (SessionId ("raw-chain-" <> T.pack (show n))))
                                            session
                                        )
                                    )
                                    request
                                    action
        , submitTx = \wanted _ ->
            pure $
                if wanted /= configured
                    then SubmitWrongNetwork configured wanted
                    else SubmitFailed "raw chain fixture has no ledger submitter"
        }
    )
  where
    configured = chainNetwork chain

{- | The recorded blocks whose transaction spends, references, creates, mints
or burns the asset, as the public history of that asset. Every range is
answered whole.
-}
touches :: Asset -> HistoryBlock -> Bool
touches (policy, name) block =
    any involved (NE.toList (blockTransactions block))
  where
    involved record =
        any
            (holds . snd)
            ( spentOutputs record
                <> referenceOutputs record
                <> createdOutputs record
            )
            || minted (historicalTx record ^. bodyTxL . mintTxBodyL)
    holds out = let MaryValue _ assets = out ^. valueTxOutL in minted assets
    minted (MultiAsset assets) =
        maybe
            False
            ((/= 0) . Map.findWithDefault 0 name)
            (Map.lookup policy assets)

streamOf :: [HistoryBlock] -> HistoryStream IO
streamOf = \case
    [] -> HistoryStream (pure (Right Nothing))
    b : bs -> HistoryStream (pure (Right (Just (b, streamOf bs))))

selectOutputs
    :: Map TxIn (TxOut ConwayEra)
    -> OutputQuery
    -> Either ReadFailure Outputs
selectOutputs allOutputs = fmap Map.toAscList . selected
  where
    selected = \case
        AtAddress address ->
            Right (Map.filter (\out -> out ^. addrTxOutL == address) allOutputs)
        HoldingAsset (policy, name) ->
            Right $
                Map.filter
                    ( \out ->
                        let MaryValue _ (MultiAsset assets) = out ^. valueTxOutL
                        in  maybe
                                False
                                ((/= 0) . Map.findWithDefault 0 name)
                                (Map.lookup policy assets)
                    )
                    allOutputs
        AtTxIn reference -> case Map.lookup reference allOutputs of
            Nothing -> Left (MissingOutput reference)
            Just out -> Right (Map.singleton reference out)
        CarryingReferenceScript script ->
            Right $
                Map.filter
                    ( \out -> case out ^. referenceScriptTxOutL of
                        SJust carried -> hashScript carried == script
                        SNothing -> False
                    )
                    allOutputs
        AnyOf queries -> Map.unions <$> traverse selected (NE.toList queries)
        AllOf queries -> do
            results <- traverse selected queries
            pure (foldl1 Map.intersection (NE.toList results))
blockHash :: SlotNo -> BS.ByteString
blockHash (SlotNo slot) =
    BS.replicate 24 0
        <> BS.pack
            [fromIntegral (slot `shiftR` amount) | amount <- [56, 48 .. 0 :: Int]]
