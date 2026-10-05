{- |
Module      : Singular.Registry.Provider
Description : The chain read interface: one acquired view per operation
License     : Apache-2.0

The only way to read the chain is to acquire a 'View' with 'withView'
and read through it. A view is one acquired ledger state: it names the
chain point it was acquired at ('viewPoint'), carries the protocol
parameters captured once at acquisition ('viewProtocolParams'), and
answers every other read — UTxOs, script-credential registration, time
to slot, script evaluation — from that same state. Building one
transaction is one operation: its preview, its fee and outlay decisions
and its body come from one view, and a change the chain makes after the
acquisition never reaches them.

A view carries no submission. Signing and sending live in
"Singular.Registry.Node.Submit".

A view is valid only inside its 'withView' scope. A read after the
scope, an acquisition at the chain origin, and a connection lost while
acquiring or reading are each a 'ViewFailure' — never an empty answer.

Adapters build a 'Provider' with 'scopedProvider', which enforces the
scope; the node adapter is "Singular.Registry.Node.View", the
deterministic in-memory one "Singular.Registry.Node.Memory".
-}
module Singular.Registry.Provider
    ( -- * Read interface
      Provider (..)
    , View (..)
    , ChainPoint (..)
    , ViewFailure (..)

      -- * Building adapters
    , scopedProvider

      -- * Result types
    , EvaluateTxResult

      -- * Re-exports
    , SlotNo (..)
    ) where

import Control.Exception (Exception, finally, throwIO)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Word (Word32)

import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Slotting.Slot (SlotNo (..))

import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Ledger
    ( Addr
    , ConwayEra
    , PParams
    , TxIn
    )

import Singular.Registry.LocalEvaluation (EvaluateTxResult)

{- | A point on a chain: the network it belongs to, the era of the
ledger state there, its slot and the hash of the block header at that
slot. The chain origin has no block and is not a 'ChainPoint'.
-}
data ChainPoint = ChainPoint
    { cpNetwork :: Word32
    -- ^ Network magic of the chain
    , cpEra :: Text
    -- ^ Era of the ledger state at this point
    , cpSlot :: SlotNo
    -- ^ Slot of the block
    , cpBlockHash :: ByteString
    -- ^ Header hash of the block
    }
    deriving stock (Eq, Show)

{- | One acquired ledger state, valid inside the 'withView' scope that
acquired it. All era-specific types are fixed to 'ConwayEra'.
-}
data View m = View
    { viewPoint :: ChainPoint
    -- ^ The point this view was acquired at
    , viewProtocolParams :: PParams ConwayEra
    -- ^ Protocol parameters, captured once at acquisition
    , viewUTxOsAt
        :: Addr
        -> m [(TxIn, TxOut ConwayEra)]
    -- ^ UTxOs at an address
    , viewScriptRegistered
        :: ScriptHash
        -> m Bool
    {- ^ Whether a script credential has a registered reward account,
    including a zero balance
    -}
    , viewEvaluateTx
        :: ConwayTx
        -> m (EvaluateTxResult ConwayEra)
    -- ^ Script execution units of a transaction
    , viewPosixMsToSlot
        :: Integer
        -> m SlotNo
    -- ^ POSIX time (ms) to slot, floor
    , viewPosixMsCeilSlot
        :: Integer
        -> m SlotNo
    -- ^ POSIX time (ms) to slot, ceiling
    }

-- | The chain read interface: acquire a view and read through it.
newtype Provider m = Provider
    { withView :: forall a. (View m -> m a) -> m a
    -- ^ Acquire one view, run the action on it, release it
    }

-- | Why a view could not be acquired or read.
data ViewFailure
    = -- | The chain is at its origin: there is no block to acquire.
      AcquiredAtOrigin
    | -- | The view was read after its 'withView' scope ended.
      ViewOutOfScope
    | -- | The connection to the chain was lost while acquiring or reading.
      ViewConnectionLost
    deriving stock (Eq, Show)

instance Exception ViewFailure

{- | A provider from an adapter's acquisition. Every effectful read of
the view the adapter hands out fails 'ViewOutOfScope' once the
'withView' scope that acquired it has ended, whatever the adapter does
with a released state.
-}
scopedProvider
    :: (forall a. (View IO -> IO a) -> IO a)
    -> Provider IO
scopedProvider acquire = Provider $ \action -> acquire $ \view -> do
    open <- newIORef True
    action (guarded open view) `finally` writeIORef open False

guarded :: IORef Bool -> View IO -> View IO
guarded open v =
    v
        { viewUTxOsAt = inScope . viewUTxOsAt v
        , viewScriptRegistered = inScope . viewScriptRegistered v
        , viewEvaluateTx = inScope . viewEvaluateTx v
        , viewPosixMsToSlot = inScope . viewPosixMsToSlot v
        , viewPosixMsCeilSlot = inScope . viewPosixMsCeilSlot v
        }
  where
    inScope :: IO a -> IO a
    inScope read' = do
        live <- readIORef open
        unless live (throwIO ViewOutOfScope)
        read'
