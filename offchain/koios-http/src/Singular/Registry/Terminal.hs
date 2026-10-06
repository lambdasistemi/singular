{-# LANGUAGE LambdaCase #-}

{- | The sole live terminal composition: shared HTTP/client/Wire, the generic
Koios constructor, pinned time input, and explicit receipt sinks. The signed
raw Koios submitter is the allowlisted composition because the transport
submits sealed bytes without leaking an unsigned node capability.
-}
module Singular.Registry.Terminal
    ( Capabilities (..)
    , withReads
    , withWrites
    , newCapabilities
    , submitWithWallet
    , tracedReads
    ) where

import Cardano.Tx.Ledger (ConwayTx)
import Control.Exception (ErrorCall (..), throwIO)
import Control.Monad qualified
import Control.Tracer (Tracer)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text qualified as Text
import Singular.Provider.Koios.Client qualified as Client
import Singular.Provider.Koios.Evidence (providerEventJson)
import Singular.Provider.Koios.Http
    ( HttpConfig (..)
    , defaultHttpConfig
    , newHttpTransport
    )
import Singular.Provider.Koios.Provider (koiosProvider)
import Singular.Provider.Koios.Runtime (koiosSource, newIORuntime)
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Confirmation (awaitTransaction)
import Singular.Registry.Evidence (NoWitness, unverifiedVerifier)
import Singular.Registry.Funding (checkFunding, defaultFundingFloor)
import Singular.Registry.LedgerProvider
    ( LedgerProvider
    , Network (..)
    , SubmitResult (..)
    , submitTx
    )
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.ProviderTrace (tracedLedgerProvider)
import Singular.Registry.SessionEvidence (observeProvider)
import Singular.Registry.SessionIO (withLatest)
import Singular.Registry.SessionIO qualified as SessionIO
import Singular.Registry.Signing (signTx, signedTx)
import Singular.Registry.TimeSource (loadPinnedSource)
import Singular.Registry.Trace (BackendEvent, ReadEvent)
import Singular.Registry.Wait (boundedSignedSubmission)
import Singular.Registry.Wallet (Wallet (..))

newCapabilities
    :: Tracer IO BackendEvent
    -> ProviderSettings
    -> IO (Capabilities NoWitness IO)
newCapabilities backend settings = do
    raw <- newIORef []
    facts <- newIORef []
    runtime <-
        newIORuntime
            backend
            (\event -> modifyIORef' raw (<> [providerEventJson event]))
    transport <-
        newHttpTransport
            (defaultHttpConfig (Text.pack (providerUrl settings)))
                { httpTokenFile = providerTokenFile settings
                }
            >>= either (throwIO . ErrorCall . show) pure
    let network = Network (providerMagic settings)
        provider =
            observeProvider
                unverifiedVerifier
                (\fact -> modifyIORef' facts (<> [fact]))
                $ koiosProvider
                    runtime
                    network
                    ( loadPinnedSource
                        (providerMagic settings)
                        (providerTimeDirectory settings)
                    )
                    (Client.Koios Client.defaultClientConfig transport)
    pure
        Capabilities
            { capReads = (network, provider)
            , capSource = koiosSource
            , capSubmit = boundedSignedSubmission 300 (submitTx provider network)
            , capConfirm = awaitTransaction provider network
            , capFacts = readIORef facts
            , capTrace = readIORef raw
            }

{- | The capabilities for the named provider, its own mechanics traced into the
first tracer. Startup validates the pinned network context in its own
acquisition, read into the second tracer; it is never spliced into a built
body.
-}
withReads
    :: Tracer IO BackendEvent
    -> Tracer IO ReadEvent
    -> ProviderSettings
    -> (Capabilities NoWitness IO -> IO a)
    -> IO a
withReads backend reading settings action = do
    capabilities <- newCapabilities backend settings
    withLatest (tracedReads reading capabilities) $ \session ->
        Control.Monad.void (SessionIO.parameters session)
    action capabilities

{- | The same, with the wallet's funding checked first, its reads traced into
the second tracer.
-}
withWrites
    :: Tracer IO BackendEvent
    -> Tracer IO ReadEvent
    -> ProviderSettings
    -> Wallet
    -> (Capabilities NoWitness IO -> IO a)
    -> IO a
withWrites backend reading settings wallet action = withReads backend reading settings $ \capabilities -> do
    checkFunding
        (tracedReads reading capabilities)
        (walletAddr wallet)
        defaultFundingFloor
    action capabilities

-- | Sign with the caller's explicit wallet and confirm only these signed bytes.
submitWithWallet
    :: Wallet -> Capabilities w IO -> ConwayTx -> IO ConwayTx
submitWithWallet wallet capabilities unsigned = do
    let signed = signTx (walletSignKey wallet) unsigned
    capSubmit capabilities signed >>= \case
        SubmitAccepted _ -> pure ()
        SubmitRefused reason -> throwIO (ErrorCall ("tx rejected: " <> show reason))
        other -> throwIO (ErrorCall ("tx submission unavailable: " <> show other))
    capConfirm capabilities (signedTx signed)
    pure (signedTx signed)

-- | The capabilities' provider with its reads traced into this tracer.
tracedReads
    :: Tracer IO ReadEvent
    -> Capabilities w IO
    -> (Network, LedgerProvider w IO)
tracedReads tracer capabilities =
    let (network, provider) = capReads capabilities
    in  ( network
        , tracedLedgerProvider (capSource capabilities) tracer provider
        )
