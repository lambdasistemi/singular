{- |
Module      : Singular.Registry.TxBuilder.TerminationBooking
Description : The termination booking transaction
License     : Apache-2.0

Builds the transaction that books a termination: it spends the key's genuine
custody output, pays the request address the whole custody value plus the
requester's declared ordinary addition with an inline termination datum, and
mints in the same transaction the trie-ready tag under the registry's request
policy. The key's singular tag travels into the request output. The request
policy's mint handler judges the booking; this builder only builds what that
handler accepts, and refuses before building what it would refuse.

There is no booked time and no expiry: a termination has no window. The
custody's own spending condition is the caller's: the builder carries the
spend witness and redeemer it is given and adds nothing of its own, so the
universal layer puts no restriction on the custody address.

This module is the checkpoint's boundary: the types and the entry point exist
so the fold, the command line and the applications can name them, and the
builder is not written yet.
-}
module Singular.Registry.TxBuilder.TerminationBooking
    ( TerminationBooking (..)
    , bookTerminationImpl
    ) where

import Data.ByteString (ByteString)
import Data.ByteString.Short (ShortByteString)
import PlutusCore.Data qualified as PLC

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)

import Cardano.Ledger.Api.Tx.Out (TxOut)
import Singular.Registry.Config (CageConfig)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger
    ( Coin
    , ConwayEra
    , TokenId
    )
import Singular.Registry.LedgerProvider (Session)

{- | What a controller chooses for one termination. Everything else comes from
the registry's configuration: the minimum tip and the request policy.
-}
data TerminationBooking = TerminationBooking
    { tbKey :: !ByteString
    -- ^ The registry key being terminated
    , tbDeclaredTip :: !Coin
    -- ^ The declared tip, at least the registry's minimum tip
    , tbCarrier :: !Coin
    {- ^ The declared carrier lovelace: the held value less the tip, so that
    tip and carrier account for the whole of the custody value and the
    ordinary addition
    -}
    , tbNonce :: !Integer
    -- ^ The nonce the trie-ready tag commits to
    , tbCustody :: !(TxIn, TxOut ConwayEra)
    -- ^ The genuine custody output the booking spends, holding the singular tag
    , tbOrdinaryAdded :: !Coin
    -- ^ The ordinary addition the requester pays in beside the custody value
    , tbApplicationScript :: !ShortByteString
    -- ^ The script that guards the custody output, which the spend must satisfy
    , tbRedeemer :: !PLC.Data
    -- ^ The redeemer the custody's script is spent with
    }

{- | Build the unsigned booking of one termination, balanced from the payer's
largest ada-only output, which is also its collateral. Not written yet.
-}
bookTerminationImpl
    :: CageConfig
    -> Session NoWitness IO
    -> TokenId
    -- ^ The registry token
    -> TxIn
    -- ^ The registry state output, referenced
    -> TerminationBooking
    -> Addr
    -- ^ Fee payer and change address
    -> IO ConwayTx
bookTerminationImpl _ _ _ _ _ _ =
    ioError (userError "bookTermination: the builder is not written yet")
