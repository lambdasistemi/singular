{- |
Module      : Singular.CLI.Recovery
Description : The decisions reconciliation takes over the journal and the roots
License     : Apache-2.0

What reconciling an interrupted local commit decides, before any file
is touched: whether a journalled fold's edge is applied to the mirror.
-}
module Singular.CLI.Recovery
    ( MirrorDecision (..)
    , mirrorDecision
    ) where

import Data.Text (Text)

import Singular.CLI.Receipt (JournalEntry (..))

-- | What reconciliation does to the mirror for one included transaction.
data MirrorDecision
    = ApplyEdge
    | AlreadyApplied
    | EdgeStale
    | NoEdge
    deriving stock (Eq, Show)

{- | The decision for one included transaction's @prepared@ line, given
the mirror's root and the ledger's, both as hex.
-}
mirrorDecision :: Text -> Text -> JournalEntry -> MirrorDecision
mirrorDecision _ _ _ = NoEdge
