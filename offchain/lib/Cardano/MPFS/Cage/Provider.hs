{- |
Module      : Cardano.MPFS.Cage.Provider
Description : Blockchain query interface
License     : Apache-2.0

Record-of-functions interface for querying the
Cardano blockchain. The real implementation uses
node-to-client LocalStateQuery; in-memory stubs
can be used for tests.
-}
module Cardano.MPFS.Cage.Provider (
    -- * Provider interface
    Provider (..),

    -- * Result types
    EvaluateTxResult,

    -- * Re-exports
    SlotNo (..),
) where

import Data.Map.Strict (Map)

import Cardano.Ledger.Alonzo.Plutus.Evaluate (
    TransactionScriptFailure,
 )
import Cardano.Ledger.Alonzo.Scripts (
    AsIx,
    PlutusPurpose,
 )
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.Plutus (ExUnits)
import Cardano.Slotting.Slot (SlotNo (..))

import Cardano.MPFS.Cage.Ledger (
    Addr,
    ConwayEra,
    PParams,
    TxIn,
 )
import Cardano.Tx.Ledger (ConwayTx)

-- | Per-script evaluation result.
type EvaluateTxResult era =
    Map
        (PlutusPurpose AsIx era)
        ( Either
            (TransactionScriptFailure era)
            ExUnits
        )

{- | Interface for querying the blockchain.
All era-specific types are fixed to 'ConwayEra'.
-}
data Provider m = Provider
    { queryUTxOs ::
        Addr ->
        m [(TxIn, TxOut ConwayEra)]
    -- ^ Look up UTxOs at an address
    , queryProtocolParams ::
        m (PParams ConwayEra)
    -- ^ Fetch current protocol parameters
    , evaluateTx ::
        ConwayTx ->
        m (EvaluateTxResult ConwayEra)
    -- ^ Evaluate script execution units
    , posixMsToSlot ::
        Integer ->
        m SlotNo
    -- ^ Convert POSIX time (ms) to slot (floor)
    , posixMsCeilSlot ::
        Integer ->
        m SlotNo
    -- ^ Convert POSIX time (ms) to slot (ceiling)
    }
