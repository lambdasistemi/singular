{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}

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
    , loseConnection
    ) where

import Cardano.Ledger.Api.Tx.Out (TxOut, addrTxOutL, valueTxOutL)
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Data.Bits (shiftR)
import Data.ByteString qualified as BS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Word (Word32)
import Lens.Micro ((^.))
import Singular.Registry.Evidence (Evidenced (..), NoWitness)
import Singular.Registry.Ledger (ConwayEra, PParams, TxIn)
import Singular.Registry.LedgerProvider
import Singular.Registry.NetworkTime (NetworkTime)
import Singular.Registry.StubSession (servingSession, stubSession)

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
    }
newRawChain :: ChainFacts -> IO RawChain
newRawChain facts =
    RawChain (Network (csNetwork facts))
        <$> newIORef facts
        <*> newIORef True

advanceChain :: RawChain -> (ChainFacts -> ChainFacts) -> IO ()
advanceChain chain change = atomicModifyIORef' (chainFacts chain) $ \facts ->
    let next = maybe 1 (succ . fst) (csTip facts)
    in  ((change facts){csTip = Just (next, blockHash next)}, ())
loseConnection :: RawChain -> IO ()
loseConnection chain = atomicModifyIORef' (chainConnected chain) (const (False, ()))

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
                                            }
                                acquire (snd (servingSession session)) request action
        , submitTx = \wanted _ ->
            pure $
                if wanted /= configured
                    then SubmitWrongNetwork configured wanted
                    else SubmitFailed "raw chain fixture has no ledger submitter"
        }
    )
  where
    configured = chainNetwork chain

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
        AnyOf queries -> Map.unions <$> traverse selected (NE.toList queries)
        AllOf queries -> do
            results <- traverse selected queries
            pure (foldl1 Map.intersection (NE.toList results))
blockHash :: SlotNo -> BS.ByteString
blockHash (SlotNo slot) =
    BS.replicate 24 0
        <> BS.pack
            [fromIntegral (slot `shiftR` amount) | amount <- [56, 48 .. 0 :: Int]]
