{-# LANGUAGE RankNTypes #-}

{- |
Module      : Cardano.MPFS.Cage.Trie
Description : Per-token MPF trie management interface
License     : Apache-2.0

Record-of-functions interface for managing
per-token Merkle Patricia Forestry tries. The
'TrieManager' mediates access to individual 'Trie'
handles and provides speculative (read-your-writes,
then-discard) sessions for transaction building.
-}
module Cardano.MPFS.Cage.Trie (
    -- * Trie manager
    TrieManager (..),

    -- * Single trie operations
    Trie (..),
) where

import Data.ByteString (ByteString)

import Cardano.MPFS.Cage.Ledger (Root, TokenId)
import Cardano.MPFS.Cage.Types (ProofStep)

-- | Manager for per-token tries.
data TrieManager m = TrieManager
    { withTrie ::
        forall a.
        TokenId ->
        (Trie m -> m a) ->
        m a
    -- ^ Run an action with access to a token's trie
    , withSpeculativeTrie ::
        forall a.
        TokenId ->
        ( forall n.
          (Monad n) =>
          Trie n ->
          n a
        ) ->
        m a
    {- ^ Run a read-your-writes session whose
    mutations are discarded at the end.
    -}
    , createTrie :: TokenId -> m ()
    -- ^ Create a new empty trie for a token
    , deleteTrie :: TokenId -> m ()
    -- ^ Delete a token's trie (permanent removal)
    , hideTrie :: TokenId -> m ()
    -- ^ Mark a token's trie as hidden
    , unhideTrie :: TokenId -> m ()
    -- ^ Restore a hidden token's trie
    }

-- | Operations on a single trie.
data Trie m = Trie
    { insert ::
        ByteString -> ByteString -> m Root
    -- ^ Insert a key-value pair, returning new root
    , delete :: ByteString -> m Root
    -- ^ Delete a key, returning new root
    , lookup :: ByteString -> m (Maybe ByteString)
    -- ^ Look up a value by key
    , getRoot :: m Root
    -- ^ Get current root hash
    , getProofSteps ::
        ByteString -> m (Maybe [ProofStep])
    -- ^ Generate on-chain proof steps for a key
    }
