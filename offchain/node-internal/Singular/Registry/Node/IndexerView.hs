{- |
Module      : Singular.Registry.Node.IndexerView
Description : The read interface over the in-process index and a node view, at one point
License     : Apache-2.0

The indexer adapter: a view's address reads come from the in-process
UTxO index, every other read — protocol parameters, script
registration, time to slot, evaluation — from a node view, and all of
them are answered at the node view's chain point.

The pinned node client acquires LocalStateQuery only at the node's tip,
so the index is brought to the node's point, never the other way. One
'withView' holds the index ('withHeldIndex') before it acquires the
node view, so no block the follower applies afterwards reaches the
index; it then admits the index at the node view's slot and block hash,
letting the follower apply up to that block and no further, within a
bound. The follower must also be connected and within its readiness
threshold of its tip. Admitted, the index stays at that point until the
view ends: its address reads and the node view's reads are of one
block.

When the index does not reach the node view's point within the bound,
the view is refused by name, carrying the points involved, and nothing
is read: a disconnected upstream, a follower still restoring, another
block at the node view's slot (a fork), or an index elsewhere (lag). A
node view on another network, or in an era whose outputs the index does
not decode, is refused as unsupported. An address read the index cannot
answer completely — the follower started at a tip, or filters out that
address — is refused as incomplete coverage, never answered empty.
-}
module Singular.Registry.Node.IndexerView
    ( -- * Adapter
      indexerProvider
    , IndexerReadiness (..)

      -- * Refusals
    , IndexerViewFailure (..)

      -- * Reading the index
    , indexedUTxOs
    ) where

import Control.Concurrent.STM (STM, atomically)
import Control.Exception (Exception, throwIO)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64)

import Cardano.Crypto.Hash (hashFromBytes)
import Cardano.Ledger.Address (Addr, serialiseAddr)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Binary (decodeFull')
import Cardano.Ledger.Core (eraProtVerLow)
import Cardano.Ledger.Hashes (unsafeMakeSafeHash)
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Node.Client.N2C.Reconnect (UpstreamStatus (..))
import Cardano.Node.Client.UTxOIndexer.Follower
    ( InterestSet (..)
    , Readiness (..)
    )
import Cardano.Node.Client.UTxOIndexer.Indexer (IndexerHandle (..))
import Cardano.Node.Client.UTxOIndexer.Types qualified as Indexer
import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.Node.IndexGate
    ( Coverage (..)
    , IndexGate
    , IndexedPoint (..)
    , gateCoverage
    , gateIndexer
    , gateNetwork
    , withHeldIndex
    )
import Singular.Registry.Node.Options (die)
import Singular.Registry.Provider
    ( ChainPoint (..)
    , Provider (..)
    , SlotNo (..)
    , View (..)
    , scopedProvider
    )

-- | The follower's readiness and the slot lag it tolerates.
data IndexerReadiness = IndexerReadiness
    { irReadiness :: STM Readiness
    , irThresholdSlots :: Word64
    -- ^ How many slots the follower may be behind its tip and be ready
    }

-- | Why the index cannot answer a view at the node view's point.
data IndexerViewFailure
    = -- | The index did not reach the node view's point within the bound.
      IndexerLag
        { lagNodePoint :: ChainPoint
        , lagIndexedPoint :: Maybe IndexedPoint
        , lagBoundMicros :: Int
        }
    | -- | The index holds another block at the node view's slot.
      IndexerFork
        { forkSlot :: SlotNo
        , forkNodeHash :: ByteString
        , forkIndexedHash :: ByteString
        }
    | -- | The index started at a tip or filters the address read.
      IndexerCoverageIncomplete Coverage
    | -- | The follower is restoring: processed slot and tip slot.
      IndexerRestoring (Maybe SlotNo) (Maybe SlotNo)
    | -- | The follower's upstream is not connected.
      IndexerDisconnected UpstreamStatus
    | -- | A capability the adapter cannot serve.
      IndexerUnsupported Text
    deriving stock (Eq, Show)

instance Exception IndexerViewFailure

{- | The node provider with its address reads answered by the index at
each view's point, within a bound (microseconds) for the index to reach
it.
-}
indexerProvider
    :: IndexGate -> IndexerReadiness -> Int -> Provider IO -> Provider IO
indexerProvider gate readiness bound node =
    scopedProvider $ \action -> withHeldIndex gate $ \admit ->
        withView node $ \v -> do
            let point = viewPoint v
            either throwIO pure (supported gate point)
            verdict <-
                admit
                    (IndexedPoint (cpSlot point) (cpBlockHash point))
                    (isNothing . unready readiness <$> irReadiness readiness)
                    bound
            case verdict of
                Right () -> action v{viewUTxOsAt = covered gate}
                Left indexed -> do
                    r <- atomically (irReadiness readiness)
                    throwIO $ case unready readiness r of
                        Just failure -> failure
                        Nothing -> elsewhere point indexed bound

-- | Whether the index can serve a node view at this point at all.
supported :: IndexGate -> ChainPoint -> Either IndexerViewFailure ()
supported gate point
    | cpNetwork point /= gateNetwork gate =
        Left . IndexerUnsupported . T.pack $
            "a view of network "
                <> show (cpNetwork point)
                <> " over an index following network "
                <> show (gateNetwork gate)
    | cpEra point /= "Conway" =
        Left . IndexerUnsupported $
            "address reads in era "
                <> cpEra point
                <> ": the index decodes Conway outputs"
    | otherwise = Right ()

-- | Why the follower is not ready, if it is not.
unready :: IndexerReadiness -> Readiness -> Maybe IndexerViewFailure
unready readiness r = case rUpstream r of
    status@UpstreamDisconnected{} -> Just (IndexerDisconnected status)
    UpstreamConnected -> case (rProcessedSlot r, rTipSlot r) of
        (Just (Indexer.SlotNo processed), Just (Indexer.SlotNo tip))
            | tip <= processed + irThresholdSlots readiness -> Nothing
        (processed, tip) ->
            Just (IndexerRestoring (slotOf <$> processed) (slotOf <$> tip))
  where
    slotOf (Indexer.SlotNo s) = SlotNo s

-- | The index held another block at the node view's slot, or was elsewhere.
elsewhere
    :: ChainPoint -> Maybe IndexedPoint -> Int -> IndexerViewFailure
elsewhere point indexed bound = case indexed of
    Just IndexedPoint{ipSlot, ipBlockHash}
        | ipSlot == cpSlot point && ipBlockHash /= cpBlockHash point ->
            IndexerFork
                { forkSlot = ipSlot
                , forkNodeHash = cpBlockHash point
                , forkIndexedHash = ipBlockHash
                }
    _ ->
        IndexerLag
            { lagNodePoint = point
            , lagIndexedPoint = indexed
            , lagBoundMicros = bound
            }

-- | An address read the index answers completely, or its refusal.
covered :: IndexGate -> Addr -> IO [(TxIn, TxOut ConwayEra)]
covered gate addr = case gateCoverage gate of
    coverage@Coverage{coverageStart = Just _} ->
        throwIO (IndexerCoverageIncomplete coverage)
    coverage@Coverage{coverageInterest = IndexAddressSet kept}
        | Indexer.Address (serialiseAddr addr) `Set.notMember` kept ->
            throwIO (IndexerCoverageIncomplete coverage)
    _ -> indexedUTxOs (gateIndexer gate) addr

-- | Every output at an address as the index holds it, in the node's order.
indexedUTxOs :: IndexerHandle -> Addr -> IO [(TxIn, TxOut ConwayEra)]
indexedUTxOs idx addr = do
    rows <- snapshotAt idx (Indexer.Address (serialiseAddr addr))
    Map.toList . Map.fromList <$> traverse decodeRow rows
  where
    decodeRow (Indexer.TxIn tid ix, Indexer.TxOut bytes) = do
        h <-
            maybe
                (bad tid "the transaction id is not 32 bytes")
                pure
                (hashFromBytes tid)
        out <-
            either
                (bad tid . show)
                pure
                (decodeFull' (eraProtVerLow @ConwayEra) bytes)
        pure
            (TxIn (TxId (unsafeMakeSafeHash h)) (TxIx (fromIntegral ix)), out)
    bad tid why =
        die
            ( "an indexed output of transaction "
                <> BC.unpack (B16.encode tid)
                <> " does not decode: "
                <> why
            )
