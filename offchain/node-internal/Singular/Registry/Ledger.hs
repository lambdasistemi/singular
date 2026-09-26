{-# LANGUAGE DataKinds #-}

{- |
Module      : Singular.Registry.Ledger
Description : Cardano ledger type re-exports
License     : Apache-2.0

Central type vocabulary for the cage transaction
builders. Re-exports ledger types (Conway era) and
defines domain types that bridge the gap between
cardano-ledger representations and the Aiken
on-chain validator layout.
-}
module Singular.Registry.Ledger (
    -- * Ledger re-exports
    ConwayEra,
    Addr,
    TxId,
    TxIn,
    TxOut,
    Coin (..),
    MaryValue,
    PolicyID (..),
    AssetName (..),
    SlotNo (..),
    ScriptHash (..),
    KeyHash,
    KeyRole (..),
    ExUnits (..),
    PParams,
    ConwayTxBody,

    -- * Token identification
    TokenId (..),

    -- * Merkle Patricia Forestry
    Root (..),

    -- * Token state
    TokenState (..),
) where

import Data.ByteString (ByteString)

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Alonzo.Core (TopTx, TxBody)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams)
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Keys (KeyHash, KeyRole (..))
import Cardano.Ledger.Mary.Value (
    AssetName (..),
    MaryValue,
    PolicyID (..),
 )
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.Slot (SlotNo (..))
import Cardano.Ledger.TxIn (TxId, TxIn)

-- | Conway-era top-level transaction body.
type ConwayTxBody = TxBody TopTx ConwayEra

{- | Unique identifier for a token managed by the
cage. Corresponds to the on-chain asset name
derived from SHA2-256(txId ++ index).
-}
newtype TokenId = TokenId
    { unTokenId :: AssetName
    }
    deriving (Eq, Ord, Show)

{- | MPF root hash representing the current state
of a trie (32 bytes Blake2b-256).
-}
newtype Root = Root
    { unRoot :: ByteString
    }
    deriving (Eq, Show)

-- #183: the `Operation` domain type and the `Request` record that
-- carried it are gone with the wire they described. Nothing read them —
-- the encoders work on `Singular.Registry.Types.OnChainRequest`, whose
-- request states an edge index and a deposit.

-- | Current on-chain state of a token.
data TokenState = TokenState
    { owner :: !(KeyHash Payment)
    -- ^ Owner's payment key hash
    , root :: !Root
    -- ^ Current root hash of the token's trie
    , tip :: !Coin
    -- ^ Maximum fee charged per request
    , processTime :: !Integer
    -- ^ Duration (ms) of the oracle processing window
    , retractTime :: !Integer
    -- ^ Duration (ms) of the requester retract window
    }
    deriving (Eq, Show)
