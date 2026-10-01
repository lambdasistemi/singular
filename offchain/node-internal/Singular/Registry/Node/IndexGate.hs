{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Registry.Node.IndexGate
Description : The in-process index behind a write gate views can hold
License     : Apache-2.0

The pinned chain-sync follower mutates the in-process UTxO index only
through the 'IndexerHandle' its caller hands it. 'gatedHandle' is that
handle with its two state-changing writes, @applyAtSlot@ and
@rollbackTo@, passing a gate, and 'indexedPoint' is the block the index
last applied, recorded by the gate as each write completes.

A view holds the index through 'withHeldIndex'. From the moment the
hold starts the index takes no write; the view then names the point it
needs ('Admit') and the index advances to that point and no further,
within a bound. Once admitted, no apply and no rollback takes effect
until every view holding the index has ended, normally or by an
exception; a write attempted meanwhile waits and lands afterwards. A
view that is not admitted within its bound learns the point the index
was at instead, and holds nothing.

Holds are counted per thread, so a view acquired inside another view on
the same thread is admitted only at the point the outer view holds: an
index that must move for it cannot, and the inner admission ends at its
bound instead of waiting for the outer view.
-}
module Singular.Registry.Node.IndexGate
    ( -- * Indexed point and coverage
      IndexedPoint (..)
    , Coverage (..)

      -- * Gate
    , IndexGate
    , newIndexGate
    , gateNetwork
    , gateCoverage
    , gateIndexer
    , gatedHandle
    , indexedPoint

      -- * Holding the index
    , Admit
    , withHeldIndex
    , holdsIndex
    ) where

import Control.Concurrent (ThreadId, myThreadId)
import Control.Concurrent.STM
    ( STM
    , TMVar
    , TVar
    , atomically
    , check
    , modifyTVar'
    , newTMVarIO
    , newTVarIO
    , putTMVar
    , readTVar
    , readTVarIO
    , takeTMVar
    , writeTVar
    )
import Control.Exception (finally, mask, onException)
import Data.ByteString (ByteString)
import Data.List (delete)
import Data.Maybe (listToMaybe)
import Data.Word (Word32)
import System.Timeout (timeout)

import Cardano.Node.Client.UTxOIndexer.Follower (InterestSet)
import Cardano.Node.Client.UTxOIndexer.Indexer (IndexerHandle (..))
import Cardano.Node.Client.UTxOIndexer.Types qualified as Indexer
import Singular.Registry.Provider (SlotNo (..))

-- | The slot and block hash of a block the index applied.
data IndexedPoint = IndexedPoint
    { ipSlot :: SlotNo
    , ipBlockHash :: ByteString
    }
    deriving stock (Eq, Show)

-- | Which outputs the index holds.
data Coverage = Coverage
    { coverageStart :: Maybe IndexedPoint
    -- ^ The block the follower started after; none from the chain's origin
    , coverageInterest :: InterestSet
    -- ^ The addresses whose outputs the follower keeps
    }
    deriving stock (Eq, Show)

-- | Which writes the gate lets through while no view is admitted.
data Limit
    = -- | Every write
      Open
    | -- | None: an acquisition is naming its point
      Frozen
    | -- | Applies up to this slot, and rollbacks
      UpTo SlotNo

-- | An in-process index whose writes pass a gate.
data IndexGate = IndexGate
    { igNetwork :: Word32
    , igCoverage :: Coverage
    , igIndexer :: IndexerHandle
    , igPoint :: TVar (Maybe IndexedPoint)
    , igLimit :: TVar Limit
    , igHolders :: TVar [ThreadId]
    -- ^ One entry per admitted view still running
    , igWriting :: TVar Bool
    , igAcquiring :: TMVar ()
    -- ^ Taken by the one acquisition naming its point
    }

{- | Gate an index following a network with a coverage. Its applied
point starts at the newest block the index retains.
-}
newIndexGate :: Word32 -> Coverage -> IndexerHandle -> IO IndexGate
newIndexGate network coverage idx = do
    newest <- newestApplied idx
    IndexGate network coverage idx
        <$> newTVarIO newest
        <*> newTVarIO Open
        <*> newTVarIO []
        <*> newTVarIO False
        <*> newTMVarIO ()

-- | The network magic of the chain the index follows.
gateNetwork :: IndexGate -> Word32
gateNetwork = igNetwork

-- | The outputs the index holds.
gateCoverage :: IndexGate -> Coverage
gateCoverage = igCoverage

-- | The index, for reads.
gateIndexer :: IndexGate -> IndexerHandle
gateIndexer = igIndexer

{- | The handle a follower writes the index through: applies and
rollbacks wait for the gate, everything else is the index's own.
-}
gatedHandle :: IndexGate -> IndexerHandle
gatedHandle g =
    raw
        { applyAtSlot = \slot bh ops -> do
            let applied = IndexedPoint (fromIndexer slot) (Indexer.unBlockHash bh)
            writing g (admitsApply (ipSlot applied)) $ do
                applyAtSlot raw slot bh ops
                pure (advanceTo applied)
        , rollbackTo = \slot -> writing g admitsRollback $ do
            rollbackTo raw slot
            const <$> newestApplied raw
        }
  where
    raw = igIndexer g

-- | The block the index last applied; none before its first.
indexedPoint :: IndexGate -> STM (Maybe IndexedPoint)
indexedPoint = readTVar . igPoint

{- | Admit a view at a point, once a readiness condition also holds,
within a bound (microseconds): the index held there, or the point it
was at when the bound expired.
-}
type Admit =
    IndexedPoint -> STM Bool -> Int -> IO (Either (Maybe IndexedPoint) ())

{- | Run one view's acquisition and reads against the index. The index
takes no write from the start; the body admits itself once, at the
point it needs, and the hold ends with the body, however it ends.
-}
withHeldIndex :: IndexGate -> (Admit -> IO a) -> IO a
withHeldIndex g body = do
    tid <- myThreadId
    admitted <- newTVarIO False
    mask $ \restore -> do
        atomically $ do
            takeTMVar (igAcquiring g)
            idle g
            writeTVar (igLimit g) Frozen
        let admit target ready bound = do
                atomically $ writeTVar (igLimit g) (UpTo (ipSlot target))
                held <- timeout bound . atomically $ do
                    idle g
                    readTVar (igPoint g) >>= check . (== Just target)
                    ready >>= check
                    modifyTVar' (igHolders g) (tid :)
                    writeTVar admitted True
                    release
                maybe (Left <$> readTVarIO (igPoint g)) (pure . Right) held
            finish = atomically $ do
                wasAdmitted <- readTVar admitted
                if wasAdmitted
                    then modifyTVar' (igHolders g) (delete tid)
                    else release
        restore (body admit) `finally` finish
  where
    release = do
        writeTVar (igLimit g) Open
        putTMVar (igAcquiring g) ()

-- | Whether the calling thread holds the index under a view.
holdsIndex :: IndexGate -> IO Bool
holdsIndex g = elem <$> myThreadId <*> readTVarIO (igHolders g)

{- | Run one write once no view is admitted and the limit admits it,
then record the applied point the write leaves.
-}
writing
    :: IndexGate
    -> (Limit -> Bool)
    -> IO (Maybe IndexedPoint -> Maybe IndexedPoint)
    -> IO ()
writing g admits write = mask $ \restore -> do
    atomically $ do
        readTVar (igHolders g) >>= check . null
        readTVar (igLimit g) >>= check . admits
        idle g
        writeTVar (igWriting g) True
    step <-
        restore write
            `onException` atomically (writeTVar (igWriting g) False)
    atomically $ do
        modifyTVar' (igPoint g) step
        writeTVar (igWriting g) False

-- | No write is in progress.
idle :: IndexGate -> STM ()
idle g = readTVar (igWriting g) >>= check . not

admitsApply :: SlotNo -> Limit -> Bool
admitsApply slot = \case
    Open -> True
    Frozen -> False
    UpTo target -> slot <= target

admitsRollback :: Limit -> Bool
admitsRollback = \case
    Frozen -> False
    _ -> True

{- | The point after an apply: the index applies a block only above its
newest slot, and leaves itself unchanged otherwise.
-}
advanceTo :: IndexedPoint -> Maybe IndexedPoint -> Maybe IndexedPoint
advanceTo applied = \case
    Just current | ipSlot current >= ipSlot applied -> Just current
    _ -> Just applied

-- | The newest block the index retains in its rollback log.
newestApplied :: IndexerHandle -> IO (Maybe IndexedPoint)
newestApplied idx =
    fmap toPoint . listToMaybe <$> getResumePoints idx
  where
    toPoint (slot, Indexer.BlockHash bh) = IndexedPoint (fromIndexer slot) bh

fromIndexer :: Indexer.SlotNo -> SlotNo
fromIndexer (Indexer.SlotNo s) = SlotNo s
