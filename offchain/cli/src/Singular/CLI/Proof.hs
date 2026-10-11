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
    , authErrorFields
    , authenticatedLeafPure
    , rootOfDbPure
    , authenticatedLeaf
    , rootOfDb
    ) where

import Control.Exception (evaluate)
import Data.Aeson (Value)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T

import MPF.Backend.Pure (MPFInMemoryDB)

import Singular.Registry.Ledger
    ( Root (..)
    )
import Singular.Registry.Trie.Pure
    ( provesAbsent
    , provesMember
    , rootFromDb
    )
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
    TrieRefusal why -> "TrieState " <> T.unpack (TrieState.trieFailureName why)
  where
    hexS = BC.unpack . B16.encode

{- | The receipt fields printed beside the rendered error: a trie refusal's
registry, the transaction where one is known, and its cause.
-}
authErrorFields :: AuthError -> [(Text, Value)]
authErrorFields = \case
    TrieRefusal why -> TrieState.trieFailureFields why
    _ -> []

-- | The root the saved trie commits to, without allocating mutable state.
rootOfDbPure :: MPFInMemoryDB -> ByteString
rootOfDbPure = unRoot . rootFromDb

{- | Compatibility IO wrapper for 'rootOfDbPure'; allocates no manager.
As the old strict manager seed did, force the snapshot constructor inside IO,
but leave the computed root lazy for the caller.
-}
rootOfDb :: MPFInMemoryDB -> IO ByteString
rootOfDb db = do
    snapshot <- evaluate db
    pure (rootOfDbPure snapshot)

{- | The leaf at a key, proven against the observed root. The saved
trie's root must equal it; then a leaf is reported only when the saved
tree nodes prove the key bound to exactly that leaf's bytes under the
observed root, and Unknown only when they prove the key bound to
nothing. The key index kept beside the nodes, which the root does not
commit to, is never read.
-}
authenticatedLeafPure
    :: MPFInMemoryDB
    -> ByteString
    -> ByteString
    -> Either AuthError Leaf
authenticatedLeafPure db key observed =
    if local /= observed
        then Left (RootMismatch local observed)
        else case [ leaf
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
  where
    local = rootOfDbPure db

{- | Compatibility IO wrapper for 'authenticatedLeafPure'. As before, it
does not catch malformed-node exceptions. Callers that need decode refusal
must own their exception boundary, as the conformance observer does.
-}
authenticatedLeaf
    :: MPFInMemoryDB
    -> ByteString
    -> ByteString
    -> IO (Either AuthError Leaf)
authenticatedLeaf db key observed =
    -- Preserve the old IO action's root comparison: a root decode failure
    -- must still occur inside the caller's handler, before returning Either.
    if local /= observed
        then pure (Left (RootMismatch local observed))
        else pure (authenticatedLeafPure db key observed)
  where
    local = rootOfDbPure db
