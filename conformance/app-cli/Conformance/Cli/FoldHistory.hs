{-# LANGUAGE LambdaCase #-}

{- | The adversarial fold builder still takes a mutable trie. Reconstruct one
from authenticated public replay for this call, never from a saved mirror.
The keys come from the very stream the lineage backend validates; their
current leaves come only from its snapshot. The rebuilt root must match
that snapshot before a transaction can be built.
-}
module Conformance.Cli.FoldHistory
    ( publicFoldTrie
    , materializeFoldTrie
    ) where

import Control.Monad (foldM, join, void)
import Data.ByteString (ByteString)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty qualified as NE
import Data.Set (Set)
import Data.Set qualified as Set
import Singular.Registry.Ledger (TokenId (..))
import Singular.Registry.LedgerProvider qualified as LP
import Singular.Registry.Trie (Trie (..), TrieManager (..))
import Singular.Registry.Trie.PureManager (mkPureTrieManager)
import Singular.Registry.TrieState qualified as TS
import Singular.Registry.TrieState.Lineage (lineageTrieState)
import Singular.Registry.TxBuilder.Internal
    ( extractCageDatum
    , leafAbsent
    , leafActive
    , leafTerminal
    , onChainTokenId
    )
import Singular.Registry.Types (CageDatum (..), OnChainRequest (..))

-- | Acquire and replay fresh public material for the selected state output.
publicFoldTrie
    :: LP.Session w IO
    -> TS.TrieSelection
    -> IO (Either TS.TrieFailure (TrieManager IO))
publicFoldTrie session chosen = do
    keys <- newIORef Set.empty
    let TS.RegistryIdentity _ name = TS.trieSelectionIdentity chosen
        token = TokenId name
        tracked =
            session
                { LP.history = \asset range ->
                    fmap (fmap (recordKeys token keys)) (LP.history session asset range)
                }
    answer <- TS.withTrieState (lineageTrieState tracked) chosen $ \snapshot ->
        readIORef keys >>= materializeFoldTrie snapshot
    pure (join answer)

-- | Observe consumed request keys without interpreting their edges or roots.
recordKeys
    :: TokenId
    -> IORef (Set ByteString)
    -> LP.HistoryStream IO
    -> LP.HistoryStream IO
recordKeys token keys stream =
    LP.HistoryStream $
        LP.nextBlock stream >>= \case
            Left why -> pure (Left why)
            Right Nothing -> pure (Right Nothing)
            Right (Just (block, rest)) -> do
                modifyIORef' keys $
                    Set.union $
                        Set.fromList
                            [ requestKey request
                            | record <- NE.toList (LP.blockTransactions block)
                            , (_, output) <- LP.spentOutputs record
                            , Just (RequestDatum request) <- [extractCageDatum output]
                            , requestToken request == onChainTokenId token
                            ]
                pure (Right (Just (block, recordKeys token keys rest)))

{- | Materialize authenticated current leaves into the ordinary MPF producer.
Deleted keys are proven Unknown and omitted. A missing key cannot silently
give a partial trie: it changes the root and refuses before building.
This also provides a component-test seam over checked fixture snapshots;
those tests do not assert provider history or ledger admission.
-}
materializeFoldTrie
    :: TS.TrieSnapshot IO
    -> Set ByteString
    -> IO (Either TS.TrieFailure (TrieManager IO))
materializeFoldTrie snapshot keys = do
    manager <- mkPureTrieManager
    let who@(TS.RegistryIdentity _ name) = TS.trieIdentity snapshot
        token = TokenId name
    createTrie manager token
    withTrie manager token $ \trie -> do
        filled <- foldM (fill trie) (Right ()) (Set.toList keys)
        case filled of
            Left why -> pure (Left why)
            Right () -> do
                rebuilt <- getRoot trie
                pure $
                    if rebuilt == TS.trieRoot snapshot
                        then Right manager
                        else
                            Left
                                ( TS.RootDoesNotChain
                                    who
                                    Nothing
                                    (TS.RootsPart rebuilt (TS.trieRoot snapshot))
                                )
  where
    fill _ failure@(Left _) _ = pure failure
    fill trie (Right ()) key =
        TS.leafAt snapshot key >>= \case
            Left why -> pure (Left why)
            Right leaf -> case leaf of
                TS.Unknown -> pure (Right ())
                TS.Absent -> inserted leafAbsent
                TS.Active -> inserted leafActive
                TS.Terminal -> inserted leafTerminal
              where
                inserted bytes = do
                    void (insert trie key bytes)
                    pure (Right ())
