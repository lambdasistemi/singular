{- | Existing accepted local records for application trie coverage. No
provider queries or invented output lineage: equal-root records are ignored.
-}
module Singular.CLI.TrieHistory (readTrieHistory, historyAtRoot) where

import Control.Monad (forM)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (isJust, listToMaybe)
import Data.Text qualified as T
import Singular.CLI.Receipt
    ( JournalEntry (..)
    , SubmissionCase (..)
    , readJournal
    , submissionCase
    )
import Singular.CLI.ReceiptBody (boundBody)
import Singular.Registry.Ledger (Root (..))
import Singular.Registry.TrieState
import Singular.Registry.TrieState.Mirror
    ( checkedCreateRecord
    , checkedFoldRecord
    )

readTrieHistory
    :: FilePath
    -> SessionId
    -> RegistryIdentity
    -> IO (Either TrieFailure (CreateRecord, [ObservedFold]))
readTrieHistory dir sid who = do
    entries <- readJournal dir
    let accepted =
            [ p
            | p <- entries
            , journalEvent p == "prepared"
            , submissionCase entries (journalTxId p) == Just CaseIncluded
            ]
    create <- case listToMaybe [p | p <- accepted, journalStep p == "boot"] of
        Nothing -> pure (Left HistoryIncomplete)
        Just p -> do
            (_, body) <- boundBody entries (journalTxId p)
            pure $
                either (const (Left HistoryIncomplete)) (checkedCreateRecord who) body
    folds <- forM
        [ p
        | p <- accepted
        , isJust (journalEdge p)
        , journalEdge p /= Just 6
        , journalRootBefore p /= journalRootAfter p
        ]
        $ \p -> do
            (_, body) <- boundBody entries (journalTxId p)
            pure $ do
                tx <- either (const (Left HistoryIncomplete)) Right body
                before <- rootField (journalRootBefore p)
                after <- rootField (journalRootAfter p)
                key <- case journalKey p of
                    Nothing -> Left UndecodableRequest
                    Just text ->
                        either
                            (const (Left UndecodableRequest))
                            Right
                            (B16.decode (BC.pack (T.unpack text)))
                edge <- maybe (Left UndecodableRequest) Right (journalEdge p)
                checkedFoldRecord sid who before after ((key, edge) :| []) tx
    pure ((,) <$> create <*> sequence folds)
  where
    rootField Nothing = Left HistoryIncomplete
    rootField (Just text) =
        Root
            <$> either
                (const (Left RootDoesNotChain))
                Right
                (B16.decode (BC.pack (T.unpack text)))

{- | A recovery store can still be at a checked prefix while its newest
accepted fold awaits local application. The common engine verifies the
whole selected prefix from empty; a final root match never replaces replay.
-}
historyAtRoot :: Root -> [ObservedFold] -> [ObservedFold]
historyAtRoot target folds =
    case reverse
        [ take count folds
        | (count, ObservedFold _ to _) <- zip [1 ..] folds
        , trieSelectionRoot to == target
        ] of
        latest : _ -> latest
        [] -> if target == Root (BC.replicate 32 '\0') then [] else folds
