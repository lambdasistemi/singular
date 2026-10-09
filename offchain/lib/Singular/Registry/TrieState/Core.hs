{- | The common node/proof engine. Backend effects only fetch and persist a
registry entry. Snapshot reads and speculation use captured immutable nodes.
-}
module Singular.Registry.TrieState.Core
    ( TrieEntry (..)
    , capability
    , capabilityObserved
    , checkedCoverage
    , walkNodes
    , provenLeaf
    , snapshotObserved
    ) where

import Control.Monad (foldM)
import Control.Monad.State.Strict (runState)
import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import MPF.Backend.Pure (MPFInMemoryDB, emptyMPFInMemoryDB)
import MPF.Verify (verifyAikenInclusionProof)
import Singular.Registry.Ledger (Root (..))
import Singular.Registry.Trie.Pure
    ( exclusionFromDb
    , membershipFromDb
    , provesAbsent
    , provesMember
    , rootFromDb
    , stateTrie
    )
import Singular.Registry.TrieState.Types
import Singular.Registry.TxBuilder.Internal.Edges (walkEdge)

data TrieEntry = TrieEntry
    { entrySelection :: TrieSelection
    , entryCreate :: Maybe CreateRecord
    , entryFolds :: [ObservedFold]
    , entryNodes :: MPFInMemoryDB
    }

walkNodes
    :: RegistryIdentity
    -> MPFInMemoryDB
    -> NonEmpty (ByteString, Integer)
    -> Either TrieFailure (MPFInMemoryDB, SpeculativeWalk)
walkNodes who db moves
    | (_, edge) : _ <- filter (\(_, e) -> e < 0 || e > 6) (NE.toList moves) =
        Left (UndecodableRequest who Nothing (EdgeOutOfRange edge))
    | otherwise = do
        (changed, reversed) <- foldM step (db, []) (NE.toList moves)
        Right
            (changed, SpeculativeWalk (rootFromDb changed) (reverse reversed))
  where
    step (before, proofs) (key, edge) = do
        let (proof, after) = runState (walkEdge stateTrie key edge) before
            proofNodes = if edge == 1 then after else before
        -- A singleton's legitimate proof has zero steps. Check the actual
        -- producer's Maybe instead of treating every empty list as missing.
        case membershipFromDb proofNodes key of
            Nothing -> Left (MissingProof who (NoProofFor key))
            Just _ -> Right (after, proof : proofs)

provenLeaf
    :: RegistryIdentity
    -> MPFInMemoryDB
    -> Root
    -> ByteString
    -> Either TrieFailure Leaf
provenLeaf who db (Root root) key =
    case [ leaf
         | leaf <- [Absent, Active, Terminal]
         , provesMember db root key (leafBytes leaf)
         ] of
        [leaf] -> Right leaf
        [] | provesAbsent db root key -> Right Unknown
        _ -> Left (MissingProof who (NoProofFor key))

{- | Replay starts from the actual empty MPF database. Root-preserving history
records are neither required nor counted. The selected output is a separate
caller-session observation; coverage does not claim output-reference lineage.
-}
checkedCoverage :: TrieEntry -> Either TrieFailure CompleteFromCreate
checkedCoverage TrieEntry{..} = do
    case entryCreate of
        Nothing -> Left (HistoryIncomplete who Nothing MissingTransaction)
        Just (CreateRecord other _)
            | other /= who ->
                Left (WrongRegistry who Nothing (OtherRegistry other))
        Just _ -> Right ()
    (replayed, count) <- foldM replay (emptyMPFInMemoryDB, 0) entryFolds
    if rootFromDb replayed /= selected
        then Left (HistoryIncomplete who Nothing MissingTransaction)
        else
            if rootFromDb entryNodes /= selected
                then
                    Left
                        ( RootDoesNotChain
                            who
                            Nothing
                            (RootsPart (rootFromDb entryNodes) selected)
                        )
                else Right (CompleteFromCreate count)
  where
    who = trieSelectionIdentity entrySelection
    selected = trieSelectionRoot entrySelection
    replay (db, count) (ObservedFold from to edges)
        | trieSelectionRoot from == trieSelectionRoot to = Right (db, count)
        | other : _ <-
            filter (/= who) [trieSelectionIdentity from, trieSelectionIdentity to] =
            Left (WrongRegistry who Nothing (OtherRegistry other))
        | trieSelectionRoot from /= rootFromDb db =
            Left
                ( RootDoesNotChain
                    who
                    Nothing
                    (RootsPart (rootFromDb db) (trieSelectionRoot from))
                )
        | otherwise = do
            (changed, walked) <- walkNodes who db edges
            if walkRoot walked == trieSelectionRoot to
                then Right (changed, count + 1)
                else
                    Left
                        ( RootDoesNotChain
                            who
                            Nothing
                            (RootsPart (walkRoot walked) (trieSelectionRoot to))
                        )

capability
    :: (Monad m)
    => (RegistryIdentity -> m (Either TrieFailure TrieEntry))
    -> (TrieEntry -> m ())
    -> TrieState m
capability fetch persist = capabilityObserved fetch persist (const (pure ()))

-- The observer is optional evidence, after the actual computation. State
-- supplies no effects; the IO mirror supplies only its bounded harness writer.
capabilityObserved
    :: (Monad m)
    => (RegistryIdentity -> m (Either TrieFailure TrieEntry))
    -> (TrieEntry -> m ())
    -> (TrieObservation -> m ())
    -> TrieState m
capabilityObserved fetch persist emit = TrieState select accept
  where
    select chosen use = do
        found <- fetch (trieSelectionIdentity chosen)
        case found >>= validate chosen of
            Left why -> pure (Left why)
            Right (entry, coverage) -> do
                emit (Selected (entrySelection entry))
                Right
                    <$> use
                        ( snapshotObserved
                            emit
                            (entrySelection entry)
                            (entryNodes entry)
                            coverage
                        )
    validate chosen entry
        | chosen /= entrySelection entry =
            Left
                ( StaleState
                    (trieSelectionIdentity chosen)
                    Nothing
                    (StaleSelection chosen (entrySelection entry))
                )
        | otherwise = (entry,) <$> checkedCoverage entry
    accept event@(ObservedFold from to edges) = do
        found <- fetch (trieSelectionIdentity from)
        case found >>= advance event from to edges of
            Left why -> pure (Left why)
            Right Nothing -> emit (FoldAccepted from to) >> pure (Right ())
            Right (Just changed) -> do
                persist changed
                emit (FoldAccepted from (entrySelection changed))
                pure (Right ())
    advance event from to edges entry
        | trieSelectionIdentity from /= trieSelectionIdentity to =
            Left
                ( WrongRegistry
                    (trieSelectionIdentity from)
                    Nothing
                    (OtherRegistry (trieSelectionIdentity to))
                )
        | event `elem` entryFolds entry && entrySelection entry == to =
            Right Nothing
        | entrySelection entry /= from =
            Left
                ( StaleState
                    (trieSelectionIdentity from)
                    Nothing
                    (StaleSelection from (entrySelection entry))
                )
        | otherwise = do
            _ <- checkedCoverage entry
            (nodes, walked) <-
                walkNodes (trieSelectionIdentity from) (entryNodes entry) edges
            if walkRoot walked /= trieSelectionRoot to
                then
                    Left
                        ( RootDoesNotChain
                            (trieSelectionIdentity from)
                            Nothing
                            (RootsPart (walkRoot walked) (trieSelectionRoot to))
                        )
                else
                    Right
                        ( Just
                            entry
                                { entrySelection = to
                                , entryNodes = nodes
                                , entryFolds = entryFolds entry <> [event]
                                }
                        )

snapshotObserved
    :: (Monad m)
    => (TrieObservation -> m ())
    -> TrieSelection
    -> MPFInMemoryDB
    -> CompleteFromCreate
    -> TrieSnapshot m
snapshotObserved emit entrySelection entryNodes coverage =
    let who = trieSelectionIdentity entrySelection
        noProof key = Left (MissingProof who (NoProofFor key))
    in  TrieSnapshot
            { snapshotTrieIdentity = trieSelectionIdentity entrySelection
            , snapshotTriePoint = trieSelectionPoint entrySelection
            , snapshotTrieRoot = trieSelectionRoot entrySelection
            , snapshotTrieCoverage = coverage
            , snapshotLeafAt = \key ->
                recordResult
                    emit
                    (provenLeaf who entryNodes (trieSelectionRoot entrySelection) key)
                    (LeafRead entrySelection key)
            , snapshotMembership = \key leaf ->
                recordResult
                    emit
                    ( do
                        bytes <-
                            maybe (noProof key) Right (membershipFromDb entryNodes key)
                        if leaf /= Unknown
                            && verifyAikenInclusionProof
                                (unRoot (trieSelectionRoot entrySelection))
                                key
                                (leafBytes leaf)
                                bytes
                            then Right (MembershipProof bytes)
                            else noProof key
                    )
                    (MemberProved entrySelection key leaf . membershipBytes)
            , snapshotNonMembership = \key ->
                recordResult
                    emit
                    ( do
                        if provesAbsent
                            entryNodes
                            (unRoot (trieSelectionRoot entrySelection))
                            key
                            then
                                NonMembershipProof key
                                    <$> maybe (noProof key) Right (exclusionFromDb entryNodes key)
                            else noProof key
                    )
                    (const (AbsenceProved entrySelection key))
            , snapshotSpeculateEdges = \moves ->
                recordResult
                    emit
                    (fmap snd (walkNodes who entryNodes moves))
                    (Speculated entrySelection)
            }

recordResult
    :: (Monad m)
    => (TrieObservation -> m ())
    -> Either TrieFailure a
    -> (a -> TrieObservation)
    -> m (Either TrieFailure a)
recordResult emit result describe = do
    case result of
        Left _ -> pure ()
        Right value -> emit (describe value)
    pure result
