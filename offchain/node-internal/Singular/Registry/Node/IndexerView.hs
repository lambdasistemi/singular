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

A session opened on the adapter waits for its follower to catch up
('awaitIndexerReady') and checks, at one agreed point, that the index
holds every output the node holds at its funding wallet
('requireCovered'): an output only the genesis state carries is in no
block, and is refused by name rather than missing from the answer. Every
refusal renders as one line naming its class and the points involved.
-}
module Singular.Registry.Node.IndexerView
    ( -- * Adapter
      indexerProvider
    , IndexerReadiness (..)
    , awaitIndexerReady
    , requireCovered

      -- * Refusals
    , IndexerViewFailure (..)

      -- * Reading the index
    , indexedUTxOs
    ) where

import Control.Concurrent.STM (STM, atomically, check)
import Control.Exception (Exception (..), throwIO)
import Data.Aeson ((.=))
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.List (intercalate)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64)
import System.Timeout (timeout)

import Cardano.Crypto.Hash (hashFromBytes, hashToBytes)
import Cardano.Ledger.Address (Addr, serialiseAddr)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Binary (decodeFull')
import Cardano.Ledger.Core (eraProtVerLow)
import Cardano.Ledger.Hashes (extractHash, unsafeMakeSafeHash)
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
    , countServed
    , gateCoverage
    , gateIndexer
    , gateNetwork
    , withHeldIndex
    )
import Singular.Registry.Node.Options (die)
import Singular.Registry.Node.PhaseLog
    ( loggedProvider
    , phaseLogFromEnv
    , queryPhase
    , timedPhase
    )
import Singular.Registry.Node.Wallet (bech32Address)
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
    | {- | Outputs the node holds at an address and the index does not: no
      block carried them, so the index cannot answer that address.
      -}
      IndexerUncovered
        { uncoveredAddress :: Addr
        , uncoveredPoint :: ChainPoint
        , uncoveredOutputs :: [TxIn]
        }
    deriving stock (Eq, Show)

-- | A refusal reads as its one-line diagnostic.
instance Exception IndexerViewFailure where
    displayException = renderFailure

{- | The node provider with its address reads answered by the index at
each view's point, within a bound (microseconds) for the index to reach
it.
-}
indexerProvider
    :: IndexGate -> IndexerReadiness -> Int -> Provider IO -> Provider IO
indexerProvider gate readiness bound node =
    scopedProvider $ \action -> agreedView gate readiness bound node $ \v ->
        action
            v
                { viewUTxOsAt = \addr -> covered gate addr <* countServed gate
                }

{- | One view of the node with the index held at its point: the node view,
whose own address reads are still the node's, or the refusal naming why
the index cannot be brought there within the bound.
-}
agreedView
    :: IndexGate
    -> IndexerReadiness
    -> Int
    -> Provider IO
    -> (View IO -> IO a)
    -> IO a
agreedView gate readiness bound node action = do
    lg <- phaseLogFromEnv
    withHeldIndex gate $ \admit ->
        withView node $ \v -> do
            let point = viewPoint v
            either throwIO pure (supported gate point)
            verdict <-
                timedPhase
                    lg
                    "query"
                    ["query" .= ("indexAdmit" :: Text)]
                    ( \r ->
                        [ "answer_size" .= (1 :: Int)
                        , "outcome" .= (either (const "lag") (const "ok") r :: Text)
                        ]
                    )
                    $ admit
                        (IndexedPoint (cpSlot point) (cpBlockHash point))
                        (isNothing . unready readiness <$> irReadiness readiness)
                        bound
            case verdict of
                Right () -> action v
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

{- | Wait, within a bound (microseconds), until the follower is connected
and within its readiness threshold of its tip; refuse with why it is not
when the bound expires.
-}
awaitIndexerReady :: IndexerReadiness -> Int -> IO ()
awaitIndexerReady readiness bound = do
    ready <-
        timeout bound . atomically $
            irReadiness readiness >>= check . isNothing . unready readiness
    case ready of
        Just () -> pure ()
        Nothing ->
            atomically (irReadiness readiness)
                >>= maybe (pure ()) throwIO . unready readiness

{- | Refuse an address the index cannot answer completely: at one agreed
view point, the node holds an output there that the index does not.
-}
requireCovered
    :: IndexGate -> IndexerReadiness -> Int -> Provider IO -> Addr -> IO ()
requireCovered gate readiness bound node addr = do
    lg <- phaseLogFromEnv
    -- the node view this acquires is the command's own, before any session
    -- record exists to log it: it goes through the logger like every view
    agreedView gate readiness bound (loggedProvider lg node) $ \v -> do
        held <- viewUTxOsAt v addr
        known <-
            map fst
                <$> queryPhase lg "coverageIndexRead" length (covered gate addr)
        case [i | (i, _) <- held, i `notElem` known] of
            [] -> pure ()
            missing ->
                throwIO
                    IndexerUncovered
                        { uncoveredAddress = addr
                        , uncoveredPoint = viewPoint v
                        , uncoveredOutputs = missing
                        }

-- | One line naming the refusal's class and the points or setting involved.
renderFailure :: IndexerViewFailure -> String
renderFailure failure =
    "indexer backend refused the read (" <> name <> "): " <> detail
  where
    (name, detail) = case failure of
        IndexerLag{lagNodePoint, lagIndexedPoint, lagBoundMicros} ->
            ( "lag"
            , "the index did not reach the node's view at "
                <> chainPoint lagNodePoint
                <> " within "
                <> show (lagBoundMicros `div` 1_000)
                <> " ms; it holds "
                <> maybe "no block" indexedText lagIndexedPoint
            )
        IndexerFork{forkSlot, forkNodeHash, forkIndexedHash} ->
            ( "fork"
            , "at slot "
                <> show (unSlotNo forkSlot)
                <> " the node's view is block "
                <> hex forkNodeHash
                <> " and the index holds block "
                <> hex forkIndexedHash
            )
        IndexerCoverageIncomplete Coverage{coverageStart, coverageInterest} ->
            ( "coverage-incomplete"
            , case (coverageStart, coverageInterest) of
                (Just start, _) ->
                    "the index follows the chain from block "
                        <> indexedText start
                        <> ", not from its origin, so it does not hold the \
                           \outputs created before it"
                (Nothing, IndexAddressSet kept) ->
                    "the index keeps the outputs of "
                        <> show (Set.size kept)
                        <> " chosen addresses only, and this address is not \
                           \one of them"
                (Nothing, IndexAll) -> "the index does not cover this read"
            )
        IndexerRestoring processed tip ->
            ( "restoring"
            , "the follower has processed slot "
                <> maybe "none" (show . unSlotNo) processed
                <> " of the node's tip slot "
                <> maybe "unknown" (show . unSlotNo) tip
                <> "; the index answers once it is within its readiness \
                   \threshold of the tip"
            )
        IndexerDisconnected status ->
            ( "disconnected"
            , "the follower's connection to the node is down: " <> show status
            )
        IndexerUnsupported what -> ("unsupported", T.unpack what)
        IndexerUncovered{uncoveredAddress, uncoveredPoint, uncoveredOutputs} ->
            ( "coverage-incomplete"
            , show (length uncoveredOutputs)
                <> " output(s) at "
                <> bech32Address uncoveredAddress
                <> " are in the ledger's genesis state and no block carried \
                   \them, so the index, which follows blocks from the chain's \
                   \origin, does not hold them at "
                <> chainPoint uncoveredPoint
                <> ": "
                <> intercalate ", " (map outRef uncoveredOutputs)
                <> ". Read this wallet through the node backend, or pay these \
                   \outputs into a block first"
            )
    chainPoint p = show (unSlotNo (cpSlot p)) <> "." <> hex (cpBlockHash p)
    indexedText p = show (unSlotNo (ipSlot p)) <> "." <> hex (ipBlockHash p)
    hex = BC.unpack . B16.encode
    outRef (TxIn (TxId h) (TxIx ix)) =
        hex (hashToBytes (extractHash h)) <> "#" <> show ix
