{- |
Module      : Singular.Registry.TxBuilder.RegistrationBooking
Description : The registration booking transaction
License     : Apache-2.0

Builds the transaction that books a registration: it pays the request
address the declared cost, tip and carrier with an inline registration
datum, and mints in the same transaction the registry's application tag
under its application policy and the trie-ready tag under its request
policy, both held by the request output. The request policy's mint handler
judges the booking; this builder only builds what that handler accepts, and
refuses before building what it would refuse.

The booked time is the start of the explicit upper validity slot, never a
wall-clock sample, and the nonce is the caller's.
-}
module Singular.Registry.TxBuilder.RegistrationBooking
    ( RegistrationBooking (..)
    , bookRegistrationImpl
    ) where

import Data.ByteString (ByteString)
import Data.ByteString.Short (ShortByteString)
import PlutusCore.Data qualified as PLC

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.BaseTypes (SlotNo)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Config (CageConfig)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (Coin, TokenId)
import Singular.Registry.LedgerProvider (Session)

{- | What a requester chooses for one registration. Everything else comes
from the registry's configuration: the cost, the minimum tip, the widest
interval and the request policy.
-}
data RegistrationBooking = RegistrationBooking
    { rbKey :: !ByteString
    -- ^ The registry key being registered
    , rbRefundAddress :: !Addr
    -- ^ The key address that may retract and is refunded
    , rbDestination :: !ByteString
    -- ^ Binary address bytes of the output that will receive the token
    , rbDatum :: !(Maybe PLC.Data)
    -- ^ The datum the delivered output must carry, or none
    , rbDeclaredTip :: !Coin
    -- ^ The declared tip, at least the registry's minimum tip
    , rbCarrier :: !Coin
    -- ^ The declared carrier lovelace
    , rbNonce :: !Integer
    -- ^ The one nonce both tags commit to
    , rbLower :: !SlotNo
    -- ^ The first slot of the validity interval
    , rbUpper :: !SlotNo
    -- ^ The slot whose start is the booked time: the interval's upper end
    , rbApplicationScript :: !ShortByteString
    {- ^ The application policy's script, whose hash must be the registry's
    pinned application policy
    -}
    }

{- | Build the unsigned booking of one registration, balanced from the
payer's largest ada-only output.

Not implemented yet.
-}
bookRegistrationImpl
    :: CageConfig
    -> Session NoWitness IO
    -> TokenId
    -- ^ The registry token
    -> TxIn
    -- ^ The registry state output, referenced
    -> RegistrationBooking
    -> Addr
    -- ^ Fee payer and change address
    -> IO ConwayTx
bookRegistrationImpl _ _ _ _ _ _ =
    ioError (userError "bookRegistrationImpl: not implemented")
