{- | The common node/proof engine. Backend effects only fetch and persist a
registry entry. Snapshot reads and speculation use captured immutable nodes.
-}
module Singular.Registry.TrieState.Core (TrieEntry (..), capability, checkedCoverage, walkNodes, provenLeaf) where

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
    | otherwise =
        let (proofs, changed) =
                runState
                    (traverse (uncurry (walkEdge stateTrie)) (NE.toList moves))
                    db
        in  Right (changed, SpeculativeWalk (rootFromDb changed) proofs)

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
capability fetch persist = TrieState select accept
  where
    select chosen use = do
        found <- fetch (trieSelectionIdentity chosen)
        case found >>= validate chosen of
            Left why -> pure (Left why)
            Right (entry, coverage) -> Right <$> use (snapshot entry coverage)
    validate chosen entry
        | chosen /= entrySelection entry = Left StaleState
        | otherwise = (entry,) <$> checkedCoverage entry
    snapshot TrieEntry{..} coverage =
        TrieSnapshot
            { trieIdentity = trieSelectionIdentity entrySelection
            , triePoint = trieSelectionPoint entrySelection
            , trieRoot = trieSelectionRoot entrySelection
            , trieCoverage = coverage
            , leafAt =
                pure . provenLeaf entryNodes (trieSelectionRoot entrySelection)
            , membership = \key leaf -> pure $ do
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
            , nonMembership = \key -> pure $ do
                if provesAbsent
                    entryNodes
                    (unRoot (trieSelectionRoot entrySelection))
                    key
                    then
                        NonMembershipProof key
                            <$> maybe (Left MissingProof) Right (exclusionFromDb entryNodes key)
                    else Left MissingProof
            , speculateEdges = pure . fmap snd . walkNodes entryNodes
            }
    accept event@(ObservedFold from to edges) = do
        found <- fetch (trieSelectionIdentity from)
        case found >>= advance event from to edges of
            Left why -> pure (Left why)
            Right Nothing -> pure (Right ())
            Right (Just changed) -> persist changed >> pure (Right ())
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
