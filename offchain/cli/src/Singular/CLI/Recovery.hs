{-# LANGUAGE LambdaCase #-}

-- | Journal inclusion, rollback and exclusion decisions from acquired reads.
module Singular.CLI.Recovery (Inclusion (..), inclusionOf, rollbackEvidence, excludedAt) where

import Data.Set (Set)
import Data.Set qualified as Set
import Singular.CLI.Receipt (SubmissionCase (..))
import Singular.Registry.Ledger (SlotNo, TxIn)

-- | What one view shows about whether a transaction is on its chain.
data Inclusion
    = -- | Its first output is live
      OnChain
    | -- | These inputs it spends are live: it is not on the chain
      OffChain [TxIn]
    | -- | Neither its first output nor any input it spends is live
      Undetermined
    deriving stock (Eq, Show)

{- | Inclusion of a transaction, given the outputs live at a view, its
first output and the inputs it spends.
-}
inclusionOf :: Set TxIn -> TxIn -> [TxIn] -> Inclusion
inclusionOf live out0 spent
    | out0 `Set.member` live = OnChain
    | otherwise = case filter (`Set.member` live) spent of
        [] -> Undetermined
        found -> OffChain found

{- | The live inputs that show a transaction whose latest case is
included rolled back; nothing for any other case or evidence.
-}
rollbackEvidence :: Maybe SubmissionCase -> Inclusion -> Maybe [TxIn]
rollbackEvidence = \case
    Just CaseIncluded -> \case
        OffChain found -> Just found
        _ -> Nothing
    _ -> const Nothing

{- | Whether an unresolved transaction can never be included: a live
input shows it off the chain and the tip's slot has reached its validity
upper bound. Without an upper bound it never is.
-}
excludedAt
    :: SlotNo -> Maybe SlotNo -> Maybe SubmissionCase -> Inclusion -> Bool
excludedAt tip upper c inclusion = case (upper, c, inclusion) of
    (Just bound, Just open, OffChain _)
        | open `elem` unresolvedCases -> tip >= bound
    _ -> False
  where
    unresolvedCases =
        [CaseAcknowledged, CaseUnknown, CaseTimeout, CaseRolledBack]
