{- |
Module      : Singular.CLI.Recovery
Description : The decisions reconciliation takes over the journal and the roots
License     : Apache-2.0

What reconciling an interrupted local commit decides before any file is
touched: whether an included fold's journalled edge is applied to the
mirror. The @prepared@ line of a fold names its key, its edge, the root
it folds from and the root it commits to; the edge is applied only when
the mirror still holds that root before and the ledger already holds
that root after, so it is applied at most once — once walked, the
mirror holds the root after and the same line reads as already applied.
Any other pair of roots is stale local state, never repaired.
-}
module Singular.CLI.Recovery
    ( MirrorDecision (..)
    , mirrorDecision

      -- * Inclusion, rollback and exclusion
    , Inclusion (..)
    , inclusionOf
    , rollbackEvidence
    , excludedAt

      -- * Returning the mirror to a root before
    , Rewind (..)
    , rewindOf
    , replayFolds
    ) where

import Data.ByteString (ByteString)
import Data.Set (Set)
import Data.Text (Text)

import Singular.CLI.Receipt (JournalEntry (..), SubmissionCase (..))
import Singular.Registry.Ledger (SlotNo, TxIn)
import Singular.Registry.Trie (Trie)

-- | What reconciliation does to the mirror for one included transaction.
data MirrorDecision
    = -- | Walk the journalled edge: the mirror is at its root before
      ApplyEdge
    | -- | Nothing to walk: the mirror already holds its root after
      AlreadyApplied
    | -- | The roots do not authenticate the change; nothing is applied
      EdgeStale
    | -- | The transaction commits no edge (a booking, a publication)
      NoEdge
    deriving stock (Eq, Show)

{- | The decision for one included transaction's @prepared@ line, given
the mirror's root and the ledger's, both as hex.
-}
mirrorDecision :: Text -> Text -> JournalEntry -> MirrorDecision
mirrorDecision local ledger p =
    case (journalKey p, journalEdge p, journalRootBefore p, journalRootAfter p) of
        (Just _, Just _, Just before, Just after)
            | after /= ledger -> EdgeStale
            | local == after -> AlreadyApplied
            | local == before -> ApplyEdge
            | otherwise -> EdgeStale
        _ -> NoEdge

-- | What one view shows about whether a transaction is on its chain.
data Inclusion
    = OnChain
    | OffChain [TxIn]
    | Undetermined
    deriving stock (Eq, Show)

-- | Inclusion from the outputs live at a view.
inclusionOf :: Set TxIn -> TxIn -> [TxIn] -> Inclusion
inclusionOf _ _ _ = Undetermined

-- | The live inputs that show an included transaction rolled back.
rollbackEvidence :: Maybe SubmissionCase -> Inclusion -> Maybe [TxIn]
rollbackEvidence _ _ = Nothing

-- | Whether an unresolved transaction can never be included.
excludedAt
    :: SlotNo -> Maybe SlotNo -> Maybe SubmissionCase -> Inclusion -> Bool
excludedAt _ _ _ _ = False

-- | Where the mirror returns after a rollback, and the folds that rebuild it.
data Rewind = Rewind
    { rewindRoot :: Text
    , rewindFolds :: [JournalEntry]
    }
    deriving stock (Eq, Show)

-- | The rewind a journal asks for, if any fold of it is rolled back.
rewindOf :: [JournalEntry] -> Maybe Rewind
rewindOf _ = Nothing

-- | Replay journalled fold edges onto a trie.
replayFolds
    :: (Monad m) => Trie m -> [JournalEntry] -> m (Either Text ByteString)
replayFolds _ _ = pure (Left "not replayed")
