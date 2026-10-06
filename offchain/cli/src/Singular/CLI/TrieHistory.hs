{-# LANGUAGE LambdaCase #-}

-- | Decode a journal root for diagnostics only; it supplies no trie state.
module Singular.CLI.TrieHistory (journalRoot) where

import Cardano.Ledger.TxIn (TxId)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.Text qualified as T
import Singular.Registry.Ledger (Root (..))
import Singular.Registry.TrieState

{- | A root an accepted fold's journal entry records: none is an incomplete
history, and text that is not hex is a root that does not chain.
-}
journalRoot
    :: RegistryIdentity
    -> Maybe TxId
    -> Maybe T.Text
    -> Either TrieFailure Root
journalRoot who transaction = \case
    Nothing -> Left (HistoryIncomplete who transaction MissingTransaction)
    Just text ->
        Root
            <$> either
                ( const
                    ( Left
                        ( RootDoesNotChain
                            who
                            transaction
                            (UnreadableRoot "an accepted fold's journal root is not hex")
                        )
                    )
                )
                Right
                (B16.decode (BC.pack (T.unpack text)))
