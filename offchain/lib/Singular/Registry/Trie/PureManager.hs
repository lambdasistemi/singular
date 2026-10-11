{-# LANGUAGE RankNTypes #-}

{- |
Module      : Singular.Registry.Trie.PureManager
Description : Mutable in-memory TrieManager compatibility adapter
License     : Apache-2.0

In-memory implementation of the 'TrieManager'
interface backed by a 'Map TokenId (IORef
MPFInMemoryDB)'. Each token gets its own isolated
in-memory MPF database; speculative sessions compute in 'State' over a
snapshot so the original is never mutated and no mutable copy is allocated.

The legacy @PureManager@ and @mkPureTrieManager@ names describe the backend,
not the effects. Each caller owns one manager for its serial transaction
builder, replay, evolving fixture or persisted-mirror run. The manager and
dump action must not escape that lifetime into overlapping sessions. There
is no locking: creation, deletion, visibility, reads, writes, dumps and
speculative copying all require external serialization if shared.

Missing and hidden tries retain their legacy 'ErrorCall' failures, respectively
@Trie not found: @ and @Trie is hidden: @ followed by the token's 'show'.
Use the pure snapshot functions in "Singular.Registry.Trie.Pure" for
deterministic computation; a snapshot has neither registry lookup nor hidden
state. No mutable manager is needed to read its root or prove a leaf.
-}
module Singular.Registry.Trie.PureManager
    ( -- * Construction
      mkPureTrieManager

      -- * Carrying a mirror between runs
    , mkPureTrieManagerFrom
    , dumpPureTries
    ) where

import Control.Exception (evaluate)
import Control.Monad.State.Strict (State, get, runState)
import Data.IORef
    ( IORef
    , modifyIORef'
    , newIORef
    , readIORef
    )
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set

import MPF.Backend.Pure
    ( MPFInMemoryDB
    , emptyMPFInMemoryDB
    )

import Singular.Registry.Ledger (TokenId)
import Singular.Registry.Trie (Trie (..), TrieManager (..))
import Singular.Registry.Trie.Pure
    ( mkPureTrieFromRef
    , stateTrie
    )

{- | Create a new 'TrieManager IO' backed by a 'Map'
of per-token in-memory MPF databases.
-}
mkPureTrieManager :: IO (TrieManager IO)
mkPureTrieManager = fst <$> mkPureTrieManagerFrom Map.empty

{- | A manager seeded with tries a previous run left behind, paired with
the action that reads them back out.

An in-memory trie dies with the process, which is right for a runner
that boots its own registry. A runner attaching to a registry that
outlives it needs the trie that registry already has: the proofs it
builds are against the whole trie, not just the root the chain reports.
This is the seam that lets one run hand that trie to the next.
-}
mkPureTrieManagerFrom
    :: Map TokenId MPFInMemoryDB
    -> IO (TrieManager IO, IO (Map TokenId MPFInMemoryDB))
mkPureTrieManagerFrom initial = do
    seeded <- traverse newIORef initial
    ref <- newIORef seeded
    hiddenRef <-
        newIORef (Set.empty :: Set TokenId)
    pure
        ( TrieManager
            { withTrie =
                pureWithTrie ref hiddenRef
            , withSpeculativeTrie =
                pureWithSpeculativeTrie
                    ref
                    hiddenRef
            , createTrie = pureCreateTrie ref
            , deleteTrie = pureDeleteTrie ref
            , hideTrie = pureHideTrie hiddenRef
            , unhideTrie =
                pureUnhideTrie hiddenRef
            }
        , dumpPureTries ref
        )

{- | Read every trie the manager holds back out, so a run can hand what
it built to the next one. This includes hidden tries. The owner must exclude
concurrent mutation while dumping; the reads are not an atomic snapshot.
-}
dumpPureTries
    :: IORef (Map TokenId (IORef MPFInMemoryDB))
    -> IO (Map TokenId MPFInMemoryDB)
dumpPureTries ref = readIORef ref >>= traverse readIORef

-- | Run an action with access to a token's trie.
pureWithTrie
    :: IORef (Map TokenId (IORef MPFInMemoryDB))
    -> IORef (Set TokenId)
    -> TokenId
    -> (Trie IO -> IO a)
    -> IO a
pureWithTrie ref hiddenRef tid action = do
    hidden <- readIORef hiddenRef
    if Set.member tid hidden
        then
            error $
                "Trie is hidden: " ++ show tid
        else do
            tries <- readIORef ref
            case Map.lookup tid tries of
                Nothing ->
                    error $
                        "Trie not found: "
                            ++ show tid
                Just dbRef ->
                    action
                        (mkPureTrieFromRef dbRef)

{- | Run a speculative session on a copy of the
trie.
-}
pureWithSpeculativeTrie
    :: IORef (Map TokenId (IORef MPFInMemoryDB))
    -> IORef (Set TokenId)
    -> TokenId
    -> (forall n. (Monad n) => Trie n -> n a)
    -> IO a
pureWithSpeculativeTrie
    ref
    hiddenRef
    tid
    action = do
        hidden <- readIORef hiddenRef
        if Set.member tid hidden
            then
                error $
                    "Trie is hidden: "
                        ++ show tid
            else do
                tries <- readIORef ref
                case Map.lookup tid tries of
                    Nothing ->
                        error $
                            "Trie not found: "
                                ++ show tid
                    Just dbRef -> do
                        db <- readIORef dbRef
                        -- Force execution inside IO, as the old callback
                        -- did, while preserving a lazy returned value.
                        (answer, _) <- evaluate (runState (action speculativeTrie) db)
                        pure answer

-- The IO adapter forces every changed database when writing its IORef.
-- Keep that strictness locally; the public pure stateTrie stays unchanged.
speculativeTrie :: Trie (State MPFInMemoryDB)
speculativeTrie =
    stateTrie
        { insert = \key value -> strictMutation (insert stateTrie key value)
        , delete = strictMutation . delete stateTrie
        }
  where
    strictMutation action = do
        answer <- action
        changed <- get
        changed `seq` pure answer

-- | Create a new empty trie for a token.
pureCreateTrie
    :: IORef (Map TokenId (IORef MPFInMemoryDB))
    -> TokenId
    -> IO ()
pureCreateTrie ref tid = do
    dbRef <- newIORef emptyMPFInMemoryDB
    modifyIORef' ref (Map.insert tid dbRef)

-- | Delete a token's trie.
pureDeleteTrie
    :: IORef (Map TokenId (IORef MPFInMemoryDB))
    -> TokenId
    -> IO ()
pureDeleteTrie ref =
    modifyIORef' ref . Map.delete

-- | Mark a token's trie as hidden.
pureHideTrie
    :: IORef (Set TokenId) -> TokenId -> IO ()
pureHideTrie hiddenRef tid =
    modifyIORef' hiddenRef (Set.insert tid)

-- | Restore a hidden token's trie.
pureUnhideTrie
    :: IORef (Set TokenId) -> TokenId -> IO ()
pureUnhideTrie hiddenRef tid =
    modifyIORef' hiddenRef (Set.delete tid)
