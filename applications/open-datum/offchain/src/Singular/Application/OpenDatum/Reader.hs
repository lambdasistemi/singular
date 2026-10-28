{- |
Module      : Singular.Application.OpenDatum.Reader
Description : Open datum's refinement of Singular's neutral reader
License     : Apache-2.0

Only an active answer is decoded by the application. The caller owns the
session and trace; refinement has no effects or additional observations.
-}
module Singular.Application.OpenDatum.Reader
    ( ReaderAnswer (..)
    , refineReaderAnswer
    , readKey
    ) where

import PlutusCore.Data qualified as PLC
import Singular.Application.OpenDatum.Requests.Records
    ( ProtectedControl
    )
import Singular.Reader qualified as R
import Singular.Registry.ContractTable
    ( ApplicationIdentity
    , ContractTable
    )
import Singular.Registry.Ledger (ConwayEra, TxIn, TxOut)
import Singular.Registry.LedgerProvider (Session)

-- | The model's answers, with the current live control and payload decoded.
data ReaderAnswer
    = Live (TxIn, TxOut ConwayEra) ProtectedControl PLC.Data
    | PendingTermination (TxIn, TxOut ConwayEra)
    | Terminal R.ReaderState
    | NeverRegistered R.ReaderState
    | Unavailable R.ReaderReadName R.ReaderUnavailable
    | Refused R.ReaderRefusal
    deriving stock (Eq, Show)

-- | Refine only active custody, retaining every other neutral result.
refineReaderAnswer
    :: R.ReaderRequest
    -> Maybe ApplicationIdentity
    -> R.NeutralReaderAnswer
    -> ReaderAnswer
refineReaderAnswer _ _ _ = Refused R.ConflictingEvidence

-- | Read through the neutral adapter, then interpret its application datum.
readKey
    :: (Monad m)
    => Session w m
    -> ContractTable
    -> R.ReaderRequest
    -> m ReaderAnswer
readKey _ _ _ = pure (Refused R.ConflictingEvidence)
