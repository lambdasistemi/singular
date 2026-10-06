{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.Attached
Description : A write attached to its saved registry and the live chain
License     : Apache-2.0

A write holds its checked identity, wallet, journal reconciliation and
live state within an acquired session. The trie is replayed from that
session's public history. Each later transaction preparation acquires
its own session; no acquisition is claimed to bind an atomic ledger view.
-}
module Singular.CLI.Attached
    ( Attached (..)
    , attached
    , callerKey
    , provider
    , reading
    , savedOf
    , tokenName
    ) where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS
import Data.Text (Text)


import Singular.CLI.Command
    ( ProviderSettings (..)
    , WriteSettings (..)
    )
import Singular.CLI.Live
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Reconcile
    ( reconcile
    , reconciledJson
    , refuseUnreconciled
    )
import Singular.CLI.Registry
    ( checkNetwork
    , renderIdentityError
    )
import Singular.CLI.Session
import Singular.Registry.Evidence qualified as Cage
import Singular.Registry.Ledger
    ( AssetName (..)
    , TokenId (..)
    )
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.TxBuilder.Internal (addrKeyHashBytes)
import Singular.Registry.Wallet (Wallet (..))

-- | Everything a write holds once attached.
data Attached = Attached
    { atWrite :: WriteContext
    , atLive :: Live
    , atTrie :: TrieContext
    }

{- | Attach a write to its registry: saved identity and pins, network,
then — from one view — reconciliation of the journal
("Singular.CLI.Reconcile"), the refusal of whatever it leaves
unresolved, the live references and state, and the replayed root
against the ledger's. The caller's wallet is NOT compared with the
wallet that created the registry; authority is the envelope's. Every
transaction the write then builds reads the chain again, from a view of
its own. The receipt says what the reconciliation did.
-}
attached
    :: Env
    -> FilePath
    -> FilePath
    -> WriteSettings
    -> Text
    -> (Attached -> IO Value)
    -> IO Value
attached env dir blueprint ws command body = do
    saved <- loadSaved dir blueprint
    withWrite env dir command ws $ \wc -> do
        let ProviderSettings _ magic _ _ = writeProvider ws
        either
            (failWith ClientRefusal . renderIdentityError)
            pure
            (checkNetwork (savedConfig saved) magic)
        Cage.withLatest
            (readsIn (wcSource wc) (wcTracer wc) (wcCapabilities wc))
            $ \v -> do
                reconciled <- reconcile command dir saved v
                refuseUnreconciled reconciled
                live <- attachLive v saved
                context <- openTrie saved
                requireTrieSelection saved live context
                printed <-
                    body Attached{atWrite = wc, atLive = live, atTrie = context}
                pure $ case printed of
                    Aeson.Object o ->
                        Aeson.Object
                            (KeyMap.insert "reconciled" (reconciledJson reconciled) o)
                    other -> other

-- | The payment key hash of the wallet this command signs with.
callerKey :: Attached -> ByteString
callerKey = addrKeyHashBytes . walletAddr . wcWallet . atWrite

provider
    :: Attached -> (Cage.Network, Cage.LedgerProvider Cage.NoWitness IO)
provider at =
    let wc = atWrite at
    in  readsIn (wcSource wc) (wcTracer wc) (wcCapabilities wc)

-- | One read operation: acquire a view and read through it.
reading
    :: Attached -> (Cage.Session Cage.NoWitness IO -> IO a) -> IO a
reading at = Cage.withLatest (provider at)

savedOf :: Attached -> Saved
savedOf = liveSaved . atLive

tokenName :: Saved -> ByteString
tokenName s = let TokenId (AssetName n) = savedToken s in SBS.fromShort n
