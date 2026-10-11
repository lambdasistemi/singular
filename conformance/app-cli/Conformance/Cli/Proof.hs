{-# LANGUAGE LambdaCase #-}

{- | A key's leaf, proven from a saved trie against the root the chain holds.

This follows the discipline of the ordinary command's own proof
(@Singular.CLI.Proof.authenticatedLeaf@), over the same library helpers:
the saved trie must commit to exactly the observed root; a leaf is reported
only when the saved tree nodes prove the key bound to exactly that leaf's
bytes under the observed root, and only when exactly one candidate does;
Unknown only when the tree nodes prove the key bound to nothing. The key
index kept beside the nodes, which the root does not commit to, is never
read, and missing, altered or inconsistent nodes yield no answer.
-}
module Conformance.Cli.Proof
    ( Leaf (..)
    , leafText
    , provenLeaf
    ) where

import Control.Exception
    ( SomeAsyncException
    , SomeException
    , evaluate
    , fromException
    , throwIO
    , try
    )
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)

import MPF.Backend.Pure (MPFInMemoryDB)

import Singular.Registry.Ledger
    ( Root (..)
    )
import Singular.Registry.Trie.Pure
    ( provesAbsent
    , provesMember
    , rootFromDb
    )
import Singular.Registry.TxBuilder.Internal
    ( leafAbsent
    , leafActive
    , leafTerminal
    )

-- | The four answers a key has in the model's vocabulary.
data Leaf = Unknown | Absent | Active | Terminal
    deriving stock (Eq, Show, Enum, Bounded)

leafText :: Leaf -> Text
leafText = \case
    Unknown -> "unknown"
    Absent -> "absent"
    Active -> "active"
    Terminal -> "terminal"

{- | The leaf at a key, proven by the tree nodes of one saved trie against
the observed root, or why none can be reported.
-}
provenLeaf
    :: MPFInMemoryDB -> ByteString -> ByteString -> IO (Either String Leaf)
provenLeaf db key observed =
    -- Tree nodes that do not decode prove nothing: no answer, not a crash.
    try (evaluate (proven db key observed)) >>= \case
        Right answer -> pure answer
        Left (e :: SomeException)
            | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
            | otherwise ->
                pure (Left ("the saved tree nodes do not decode: " <> show e))

proven
    :: MPFInMemoryDB -> ByteString -> ByteString -> Either String Leaf
proven db key observed =
    if local /= observed
        then
            Left
                ( "the saved trie commits to 0x"
                    <> hexS local
                    <> ", not the chain's root 0x"
                    <> hexS observed
                )
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
            _ ->
                Left
                    ( "the saved tree nodes prove no single leaf at 0x"
                        <> hexS key
                        <> " under the chain's root"
                    )
  where
    Root local = rootFromDb db
    hexS = BC.unpack . B16.encode
