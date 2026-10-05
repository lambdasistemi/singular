{- |
Module      : Singular.Registry.Node.Memory
Description : A deterministic in-memory chain behind the read interface
License     : Apache-2.0

The in-memory adapter: a chain value ('ChainState') held in a mutable
cell, read through the same 'Provider' interface the node adapter
serves. 'withView' snapshots the whole value at acquisition, so a
'mutate' made while a view is open never reaches that view and a fresh
acquisition sees it. Every 'mutate' advances the chain point by one
slot, with a block hash derived from that slot.

The chain starts at its origin when 'csTip' is empty, and acquiring
there is 'AcquiredAtOrigin'. 'loseConnection' makes every later
acquisition and read 'ViewConnectionLost'. Script evaluation is the
ledger's own, through common resolved-input evaluation over the snapshot's
parameters and UTxO. Evaluation and conversion use the same explicitly
validated finite synthetic network-time context.

Library code rather than test code: interleaving controls and contract
suites use it to drive builders deterministically.
-}
module Singular.Registry.Node.Memory
    ( -- * Chain value
      ChainState (..)

      -- * Handle
    , MemoryChain
    , newMemoryChain
    , memoryProvider
    , mutate
    , loseConnection
    ) where

import Control.Exception (throwIO)
import Control.Monad (unless)
import Data.Bits (shiftR)
import Data.ByteString qualified as BS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Word (Word32)

import Cardano.Ledger.Hashes (ScriptHash)
import Lens.Micro ((^.))

import Cardano.Ledger.Api.Tx.Out (TxOut, addrTxOutL)
import Singular.Registry.Ledger
    ( ConwayEra
    , PParams
    , TxIn
    )
import Singular.Registry.NetworkTime (NetworkTime)
import Singular.Registry.PhaseLog (noPhaseLog)
import Singular.Registry.Provider
    ( ChainPoint (..)
    , Provider
    , SlotNo (..)
    , View (..)
    , ViewFailure (..)
    , scopedProvider
    )

-- | Everything the in-memory chain holds.
data ChainState = ChainState
    { csNetwork :: Word32
    -- ^ Network magic every view names
    , csEra :: Text
    -- ^ Era every view names
    , csTip :: Maybe (SlotNo, BS.ByteString)
    -- ^ Slot and block hash of the tip; none at the origin
    , csPParams :: PParams ConwayEra
    -- ^ Current protocol parameters
    , csUTxO :: Map TxIn (TxOut ConwayEra)
    -- ^ Unspent outputs
    , csRegistered :: Set ScriptHash
    -- ^ Script credentials with a registered reward account
    , csNetworkTime :: NetworkTime
    -- ^ Explicit validated, finite synthetic time material
    }

-- | A mutable in-memory chain.
data MemoryChain = MemoryChain
    { mcState :: IORef ChainState
    , mcConnected :: IORef Bool
    }

-- | A chain holding this value, connected.
newMemoryChain :: ChainState -> IO MemoryChain
newMemoryChain s = MemoryChain <$> newIORef s <*> newIORef True

{- | Change the chain and advance its point by one slot, with a block hash
derived from the new slot.
-}
mutate :: MemoryChain -> (ChainState -> ChainState) -> IO ()
mutate chain f =
    atomicModifyIORef' (mcState chain) $ \s ->
        let next = maybe 1 (succ . fst) (csTip s)
        in  ((f s){csTip = Just (next, blockHash next)}, ())

-- | Lose the connection: every later acquisition and read fails.
loseConnection :: MemoryChain -> IO ()
loseConnection chain = atomicModifyIORef' (mcConnected chain) (const (False, ()))

-- | The read interface over the chain, snapshotting it at each acquisition.
memoryProvider :: MemoryChain -> Provider IO
memoryProvider chain = scopedProvider $ \action -> do
    connected
    s <- readIORef (mcState chain)
    (slot, hash) <- maybe (throwIO AcquiredAtOrigin) pure (csTip s)
    let reading :: IO a -> IO a
        reading answer = connected >> answer
        utxo = csUTxO s
        resolved refs = reading (pure (Map.toList (Map.restrictKeys utxo refs)))
        view =
            View
                { viewPoint =
                    ChainPoint
                        { cpNetwork = csNetwork s
                        , cpEra = csEra s
                        , cpSlot = slot
                        , cpBlockHash = hash
                        }
                , viewProtocolParams = csPParams s
                , viewTimeContext = reading (pure (csNetworkTime s))
                , viewResolvedOutputs = resolved
                , viewPhaseLog = noPhaseLog
                , viewUTxOsAt = \addr ->
                    reading . pure $
                        [u | u@(_, out) <- Map.toList utxo, out ^. addrTxOutL == addr]
                , viewScriptRegistered = \sh ->
                    reading . pure $ Set.member sh (csRegistered s)
                }
    action view
  where
    connected = do
        up <- readIORef (mcConnected chain)
        unless up (throwIO ViewConnectionLost)

-- | A 32-byte block hash naming a slot.
blockHash :: SlotNo -> BS.ByteString
blockHash (SlotNo s) =
    BS.replicate 24 0
        <> BS.pack [fromIntegral (s `shiftR` n) | n <- [56, 48 .. 0 :: Int]]
