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
    :: MPFInMemoryDB
    -> NonEmpty (ByteString, Integer)
    -> Either TrieFailure (MPFInMemoryDB, SpeculativeWalk)
walkNodes db moves
    | any (\(_, edge) -> edge < 0 || edge > 6) moves =
        Left UndecodableRequest
    | otherwise = do
        (changed, reversed) <- foldM step (db, []) (NE.toList moves)
        Right
            (changed, SpeculativeWalk (rootFromDb changed) (reverse reversed))
  where
    step (before, proofs) (key, edge) = do
        let (proof, after) = runState (walkEdge stateTrie key edge) before
            proofNodes = if edge < 2 then after else before
        -- A singleton's legitimate proof has zero steps. Check the actual
        -- producer's Maybe instead of treating every empty list as missing.
        case membershipFromDb proofNodes key of
            Nothing -> Left MissingProof
            Just _ -> Right (after, proof : proofs)

provenLeaf
    :: MPFInMemoryDB -> Root -> ByteString -> Either TrieFailure Leaf
provenLeaf db (Root root) key =
    case [ leaf
         | leaf <- [Absent, Active, Terminal]
         , provesMember db root key (leafBytes leaf)
         ] of
        [leaf] -> Right leaf
        [] | provesAbsent db root key -> Right Unknown
        _ -> Left MissingProof

{- | Replay starts from the actual empty MPF database. Root-preserving history
records are neither required nor counted. The selected output is a separate
caller-session observation; coverage does not claim output-reference lineage.
-}
checkedCoverage :: TrieEntry -> Either TrieFailure CompleteFromCreate
checkedCoverage TrieEntry{..} = do
    case entryCreate of
        Nothing -> Left HistoryIncomplete
        Just (CreateRecord who _) | who /= trieSelectionIdentity entrySelection -> Left WrongRegistry
        Just _ -> Right ()
    (replayed, count) <- foldM replay (emptyMPFInMemoryDB, 0) entryFolds
    if rootFromDb replayed /= trieSelectionRoot entrySelection
        then Left HistoryIncomplete
        else
            if rootFromDb entryNodes /= trieSelectionRoot entrySelection
                then Left RootDoesNotChain
                else Right (CompleteFromCreate count)
  where
    replay (db, count) (ObservedFold from to edges)
        | trieSelectionRoot from == trieSelectionRoot to = Right (db, count)
        | trieSelectionIdentity from /= trieSelectionIdentity entrySelection
            || trieSelectionIdentity to /= trieSelectionIdentity entrySelection =
            Left WrongRegistry
        | trieSelectionRoot from /= rootFromDb db = Left RootDoesNotChain
        | otherwise = do
            (changed, walked) <- walkNodes db edges
            if walkRoot walked == trieSelectionRoot to
                then Right (changed, count + 1)
                else Left RootDoesNotChain

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
                Right <$> use (snapshot entry coverage)
    validate chosen entry
        | chosen /= entrySelection entry = Left StaleState
        | otherwise = (entry,) <$> checkedCoverage entry
    snapshot TrieEntry{..} coverage =
        TrieSnapshot
            { snapshotTrieIdentity = trieSelectionIdentity entrySelection
            , snapshotTriePoint = trieSelectionPoint entrySelection
            , snapshotTrieRoot = trieSelectionRoot entrySelection
            , snapshotTrieCoverage = coverage
            , snapshotLeafAt = \key ->
                recordResult
                    emit
                    (provenLeaf entryNodes (trieSelectionRoot entrySelection) key)
                    (LeafRead entrySelection key)
            , snapshotMembership = \key leaf ->
                recordResult
                    emit
                    ( do
                        bytes <-
                            maybe (Left MissingProof) Right (membershipFromDb entryNodes key)
                        if leaf /= Unknown
                            && verifyAikenInclusionProof
                                (unRoot (trieSelectionRoot entrySelection))
                                key
                                (leafBytes leaf)
                                bytes
                            then Right (MembershipProof bytes)
                            else Left MissingProof
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
                                    <$> maybe (Left MissingProof) Right (exclusionFromDb entryNodes key)
                            else Left MissingProof
                    )
                    (const (AbsenceProved entrySelection key))
            , snapshotSpeculateEdges = \moves ->
                recordResult
                    emit
                    (fmap snd (walkNodes entryNodes moves))
                    (Speculated entrySelection)
            }
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
            Left WrongRegistry
        | event `elem` entryFolds entry && entrySelection entry == to =
            Right Nothing
        | entrySelection entry /= from = Left StaleState
        | otherwise = do
            _ <- checkedCoverage entry
            (nodes, walked) <- walkNodes (entryNodes entry) edges
            if walkRoot walked /= trieSelectionRoot to
                then Left RootDoesNotChain
                else
                    Right
                        ( Just
                            entry
                                { entrySelection = to
                                , entryNodes = nodes
                                , entryFolds = entryFolds entry <> [event]
                                }
                        )

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
