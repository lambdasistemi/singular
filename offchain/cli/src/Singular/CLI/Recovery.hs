{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.CLI.Recovery
Description : The decisions reconciliation takes over the journal, the chain and the roots
License     : Apache-2.0

What reconciling decides before any file is touched.

__Mirror.__ Whether an included fold's journalled edge is applied to the
mirror. The @prepared@ line of a fold names its key, its edge, the root
it folds from and the root it commits to; the edge is applied only when
the mirror still holds that root before and the ledger already holds
that root after, so it is applied at most once — once walked, the
mirror holds the root after and the same line reads as already applied.
Any other pair of roots is stale local state, never repaired.

__Inclusion.__ What one view shows about a journalled transaction: its
first output is live (it is on the view's chain), one of the inputs it
spends is live (it is not: a transaction on the chain has consumed every
input it spends), or neither (its output was spent since, or its inputs
went to another transaction).

__Rollback.__ A transaction whose latest journalled case is included but
which a live input shows off the chain was rolled back. The line that
says so is appended; the observation it supersedes stays.

__Exclusion.__ An unresolved transaction a live input shows off the
chain can never be included once the view's tip has reached its
validity upper bound. One without an upper bound is never excluded.

__Rewind.__ After a rollback the mirror returns to the root before the
earliest fold rolled back, rebuilt from the empty trie create saved by
replaying, in journal order, the edges of the folds still on the chain.
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

import Control.Monad (foldM)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.List (find)
import Data.Maybe (isJust, listToMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

import Singular.CLI.Receipt
    ( JournalEntry (..)
    , SubmissionCase (..)
    , submissionCase
    )
import Singular.CLI.Registry (hexT)
import Singular.Registry.Ledger (Root (..), SlotNo, TxIn)
import Singular.Registry.Trie (Trie (..))
import Singular.Registry.TxBuilder.Internal (walkEdge)

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

-- | Where the mirror returns after a rollback, and the folds that rebuild it.
data Rewind = Rewind
    { rewindRoot :: Text
    -- ^ The root before the earliest rolled-back fold, hex
    , rewindFolds :: [JournalEntry]
    {- ^ The @prepared@ lines of the folds journalled before it whose
    latest case is included, in journal order
    -}
    }
    deriving stock (Eq, Show)

{- | The rewind a journal asks for: none unless some fold was rolled back,
is not included again — unresolved, or since excluded — and no fold has
been prepared after its rollback. A fold prepared after it was built on
the root the rewind returned to, so the rewind is done.
-}
rewindOf :: [JournalEntry] -> Maybe Rewind
rewindOf entries = do
    let numbered = zip [0 :: Int ..] entries
        folds =
            [ (i, p)
            | (i, p) <- numbered
            , journalEvent p == "prepared"
            , isJust (journalKey p)
            , isJust (journalEdge p)
            , isJust (journalRootBefore p)
            , isJust (journalRootAfter p)
            ]
        caseOf = submissionCase entries . journalTxId
        lastRollback t =
            listToMaybe
                ( reverse
                    [ i
                    | (i, e) <- numbered
                    , journalTxId e == t
                    , journalEvent e == "rolled-back"
                    ]
                )
        -- Rolled back and not included again, whether still unresolved
        -- or since excluded, with no fold built after the rollback.
        pending (_, p) = case lastRollback (journalTxId p) of
            Just at ->
                caseOf p /= Just CaseIncluded
                    && not (any ((> at) . fst) folds)
            Nothing -> False
    (_, earliest) <- find pending folds
    root <- journalRootBefore earliest
    pure
        Rewind
            { rewindRoot = root
            , rewindFolds =
                [ p
                | (_, p) <- takeWhile (not . pending) folds
                , caseOf p == Just CaseIncluded
                ]
            }

{- | Walk each fold's journalled edge onto the trie, each only from its
journalled root before and each required to reach its journalled root
after; the root reached, or why the replay stopped.
-}
replayFolds
    :: (Monad m) => Trie m -> [JournalEntry] -> m (Either Text ByteString)
replayFolds trie folds = do
    Root start <- getRoot trie
    foldM step (Right start) folds
  where
    step (Left why) _ = pure (Left why)
    step (Right now) p = case (keyOf p, journalEdge p, journalRootBefore p, journalRootAfter p) of
        (Just key, Just edge, Just before, Just after)
            | hexT now /= before ->
                pure (Left (journalTxId p <> " does not fold from the root reached"))
            | otherwise -> do
                _ <- walkEdge trie key edge
                Root reached <- getRoot trie
                pure $
                    if hexT reached == after
                        then Right reached
                        else
                            Left (journalTxId p <> " does not reach its journalled root after")
        _ -> pure (Left (journalTxId p <> " names no edge to replay"))
    keyOf p =
        journalKey p
            >>= either (const Nothing) Just . B16.decode . BC.pack . T.unpack
