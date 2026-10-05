{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.Attached
Description : A write attached to its saved registry and the live chain
License     : Apache-2.0

What every write after @create@ holds before it builds anything: the
saved identity and the node it runs against, the journal reconciled
("Singular.CLI.Reconcile") with nothing left unresolved, the live
references and state output, and a local mirror that commits to exactly
the root the ledger holds. 'attached' is that attachment; the booking
commands ("Singular.CLI.Entry") and the fold ("Singular.CLI.Fold") each
run their body inside it, so every write, whoever runs it and with
whatever wallet, starts from the same checked state.
-}
module Singular.CLI.Attached
    ( Attached (..)
    , attached
    , callerKey
    , provider
    , reading
    , savedOf
    , tokenName
    , commitLocal
    ) where

import Control.Monad (when)
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS
import Data.Text (Text)
import Data.Text qualified as T

import Cardano.Tx.Ledger (ConwayTx)

import Singular.CLI.Command
    ( ProviderSettings (..)
    , WriteSettings (..)
    )
import Singular.CLI.Live
import Singular.CLI.Node (Capabilities (..))
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Reconcile
    ( reconcile
    , reconciledJson
    , refuseUnreconciled
    )
import Singular.CLI.Registry
    ( LocalState (..)
    , checkNetwork
    , hexT
    , renderIdentityError
    , writeLocalState
    )
import Singular.CLI.Session
import Singular.Registry.Ledger
    ( AssetName (..)
    , TokenId (..)
    )
import Singular.Registry.Node (Wallet (..))
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.TxBuilder.Internal (addrKeyHashBytes)

-- | Everything a write holds once attached.
data Attached = Attached
    { atWrite :: WriteContext
    , atLive :: Live
    , atMirror :: Mirror
    }

{- | Attach a write to its registry: saved identity and pins, network,
then — from one view — reconciliation of the journal
("Singular.CLI.Reconcile"), the refusal of whatever it leaves
unresolved, the live references and state, and the mirror's root
against the ledger's. The caller's wallet is NOT compared with the
wallet that created the registry; authority is the envelope's. Every
transaction the write then builds reads the chain again, from a view of
its own. The receipt says what the reconciliation did.
-}
attached
    :: FilePath
    -> FilePath
    -> WriteSettings
    -> Text
    -> (Attached -> IO Value)
    -> IO Value
attached dir blueprint ws command body = do
    saved <- loadSaved dir blueprint
    withWrite dir command ws $ \wc -> do
        let ProviderSettings _ magic _ _ = writeProvider ws
        either
            (failWith ClientRefusal . renderIdentityError)
            pure
            (checkNetwork (savedConfig saved) magic)
        (reconciled, live) <-
            Cage.withView (capReads (wcCapabilities wc)) $ \v -> do
                r <- reconcile command dir saved v
                refuseUnreconciled r
                (,) r <$> attachLive v saved
        mirror <- openMirror saved
        observed <- either (failWith StaleState) pure (observedRoot live)
        local <- mirrorRoot saved mirror
        when (local /= observed) $
            failWith
                StaleState
                ( "the saved mirror commits to 0x"
                    <> T.unpack (hexT local)
                    <> " but the ledger holds 0x"
                    <> T.unpack (hexT observed)
                    <> ": stale, concurrent or altered local state is refused, \
                       \never repaired"
                )
        requireMirrorSelection saved live mirror
        printed <-
            body Attached{atWrite = wc, atLive = live, atMirror = mirror}
        pure $ case printed of
            Aeson.Object o ->
                Aeson.Object
                    (KeyMap.insert "reconciled" (reconciledJson reconciled) o)
            other -> other

-- | The payment key hash of the wallet this command signs with.
callerKey :: Attached -> ByteString
callerKey = addrKeyHashBytes . walletAddr . wcWallet . atWrite

provider :: Attached -> Cage.Provider IO
provider = capReads . wcCapabilities . atWrite

-- | One read operation: acquire a view and read through it.
reading :: Attached -> (Cage.View IO -> IO a) -> IO a
reading at = Cage.withView (provider at)

savedOf :: Attached -> Saved
savedOf = liveSaved . atLive

tokenName :: Saved -> ByteString
tokenName s = let TokenId (AssetName n) = savedToken s in SBS.fromShort n

-- | Write @state.json@: the commitment a confirmed write left.
commitLocal :: Attached -> ConwayTx -> ByteString -> IO ()
commitLocal at tx root =
    writeLocalState
        (savedDir (savedOf at))
        LocalState
            { localVersion = 1
            , localToken = hexT (tokenName (savedOf at))
            , localRoot = hexT root
            , localLastTx = Just (txIdHex tx)
            , localLastSlot = Nothing
            }
