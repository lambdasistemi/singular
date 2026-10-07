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
    , readingBack
    , savedOf
    , tokenName
    ) where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS
import Data.IORef (readIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)

import Cardano.Tx.Ledger (ConwayTx)

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
    , hexT
    , renderIdentityError
    )
import Singular.CLI.Session
import Singular.CLI.Trace (Scope (..), What (..), report, within)
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
    withWrite env dir command ws $ \connected -> do
        -- everything the write reports is inside its registry
        let wc =
                connected
                    { wcTracer =
                        within (InRegistry (hexT (tokenName saved))) (wcTracer connected)
                    }
            ProviderSettings _ magic _ _ = writeProvider ws
        either
            (failWith ClientRefusal . renderIdentityError)
            pure
            (checkNetwork (savedConfig saved) magic)
        Cage.withLatest
            (readsIn (wcSource wc) (wcTracer wc) (wcCapabilities wc))
            $ \v -> do
                (reconciled, live) <-
                    timedRead
                        (wcTracer wc)
                        (wcSource wc)
                        ["journal transactions", "state"]
                        $ do
                            r <- reconcile command dir saved v
                            refuseUnreconciled r
                            (,) r <$> attachLive v saved
                context <- openTrie saved
                requireTrieSelection saved live context
                observed <- either (failWith StaleState) pure (observedRoot live)
                report
                    (wcTracer wc)
                    []
                    (RegistrySeen (txInText (fst (liveState live))) (hexT observed) Nothing)
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

{- | A read-back of what a confirmed transaction made: one read step, inside
the scopes the transaction's build placed it in, so it sits with the
observation it serves.
-}
readingBack
    :: Attached
    -> Text
    -> ConwayTx
    -> [Text]
    -> (Cage.Session Cage.NoWitness IO -> IO a)
    -> IO a
readingBack at step tx items body = do
    let wc = atWrite at
    placed <-
        Map.findWithDefault [] (txIdHex tx) <$> readIORef (wcPlaced wc)
    readStep
        (inScopes (placed <> [InTransaction step]) (wcTracer wc))
        (wcSource wc)
        items
        (wcCapabilities wc)
        body

savedOf :: Attached -> Saved
savedOf = liveSaved . atLive

tokenName :: Saved -> ByteString
tokenName s = let TokenId (AssetName n) = savedToken s in SBS.fromShort n
