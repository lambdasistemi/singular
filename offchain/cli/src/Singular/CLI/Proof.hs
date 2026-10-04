{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.CLI.Proof
Description : A key's leaf, proven from the local trie against the ledger's root
License     : Apache-2.0

The chain commits a registry's trie by its root and nothing else; the
leaf at a key is not on chain. What a command may report about a key is
therefore a local proof: the saved trie must commit to exactly the root
the ledger holds now, and the leaf is the one value at that key under
which the trie still commits to that root.

'authenticatedLeaf' refuses when the saved trie's root differs from the
observed one — a stale, concurrent or altered local state — and never
reports a leaf the root does not bind.
-}
module Singular.CLI.Proof
    ( Leaf (..)
    , leafName
    , AuthError (..)
    , renderAuthError
    , authenticatedLeaf
    , rootOfDb
    ) where

import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.Map.Strict qualified as Map

import MPF.Backend.Pure (MPFInMemoryDB)

import Singular.Registry.Ledger
    ( AssetName (..)
    , Root (..)
    , TokenId (..)
    )
import Singular.Registry.Trie (Trie (..), TrieManager (..))
import Singular.Registry.Trie.Pure (provesAbsent, provesMember)
import Singular.Registry.Trie.PureManager (mkPureTrieManagerFrom)
import Singular.Registry.TrieState (Leaf (..), leafName)
import Singular.Registry.TrieState qualified as TrieState
import Singular.Registry.TxBuilder.Internal
    ( leafAbsent
    , leafActive
    , leafTerminal
    )

-- | Why no leaf can be reported.
data AuthError
    = -- | Local root, observed root
      RootMismatch ByteString ByteString
    | ProofInconsistent ByteString
    | TrieRefusal TrieState.TrieFailure
    deriving stock (Eq, Show)

renderAuthError :: AuthError -> String
renderAuthError = \case
    RootMismatch local observed ->
        "the saved trie commits to 0x"
            <> hexS local
            <> " but the ledger's registry root is 0x"
            <> hexS observed
            <> ": the local state is stale, concurrent with another writer, \
               \or altered, and is not repaired silently"
    ProofInconsistent key ->
        "no leaf at 0x"
            <> hexS key
            <> " makes the saved trie commit to its own root"
    TrieRefusal why -> "TrieState " <> show why
  where
    hexS = BC.unpack . B16.encode

-- | The root the saved trie commits to.
rootOfDb :: MPFInMemoryDB -> IO ByteString
rootOfDb db = do
    (tm, _) <- mkPureTrieManagerFrom (Map.singleton registry db)
    Root r <- withTrie tm registry getRoot
    pure r

{- | The leaf at a key, proven against the observed root. The saved
trie's root must equal it; then a leaf is reported only when the saved
tree nodes prove the key bound to exactly that leaf's bytes under the
observed root, and Unknown only when they prove the key bound to
nothing. The key index kept beside the nodes, which the root does not
commit to, is never read.
-}
authenticatedLeaf
    :: MPFInMemoryDB
    -> ByteString
    -> ByteString
    -> IO (Either AuthError Leaf)
authenticatedLeaf db key observed = do
    (tm, _) <- mkPureTrieManagerFrom (Map.singleton registry db)
    Root local <- withTrie tm registry getRoot
    if local /= observed
        then pure (Left (RootMismatch local observed))
        else pure $
            case [ leaf
                 | (leaf, bytes) <-
                    [ (Absent, leafAbsent)
                    , (Active, leafActive)
                    , (Terminal, leafTerminal)
                    ]
                 , provesMember db observed key bytes
                 ] of
                [leaf] -> Right leaf
                []
                    | provesAbsent db observed key -> Right Unknown
                _ -> Left (ProofInconsistent key)

-- | The one trie a proof session holds; its name is never observed.
registry :: TokenId
registry = TokenId (AssetName "")
