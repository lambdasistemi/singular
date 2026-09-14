{- |
Module      : Naming.CLI.Values
Description : Authenticate a known value preimage against a registry root
License     : Apache-2.0

The existing pure trie's lookup is an occupancy sentinel, not a value
decoder. A candidate is authenticated by reconstructing the same mapping
in a speculative copy and comparing its root with the confirmed root.
-}
module Naming.CLI.Values (CandidateResult (..), authenticateCandidates) where

import Control.Monad (filterM)
import Data.ByteString (ByteString)
import Singular.Registry.Ledger (Root, TokenId)
import Singular.Registry.Trie qualified as Trie

data CandidateResult = ValueUnavailable | ValueAmbiguous | Authenticated ByteString
    deriving stock (Eq, Show)

{- | Keep duplicate matching candidates: distinct live outputs claiming
the same value are ambiguous and must not be selected arbitrarily.
-}
authenticateCandidates :: Trie.TrieManager IO -> TokenId -> ByteString -> Root -> [ByteString] -> IO CandidateResult
authenticateCandidates manager token key expected candidates = do
    matches <- filterM (authenticatesValue manager token key expected) candidates
    pure $ case matches of
        [] -> ValueUnavailable
        [value] -> Authenticated value
        _ -> ValueAmbiguous

authenticatesValue :: Trie.TrieManager IO -> TokenId -> ByteString -> Root -> ByteString -> IO Bool
authenticatesValue manager token key expected candidate =
    Trie.withSpeculativeTrie manager token $ \trie -> do
        _ <- Trie.delete trie key
        actual <- Trie.insert trie key candidate
        pure (actual == expected)
