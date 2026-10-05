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
    ) where

import Cardano.Tx.Ledger (ConwayTx)
import Control.Exception (ErrorCall (..), throwIO)
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
import Singular.Provider.Koios.Runtime (newIORuntime)
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Confirmation (awaitTransaction)
import Singular.Registry.Evidence (NoWitness, unverifiedVerifier)
import Singular.Registry.Funding (checkFunding, defaultFundingFloor)
import Singular.Registry.LedgerProvider
    ( Network (..)
    , SubmitResult (..)
    , submitTx
    )
import Singular.Registry.PhaseLog (phaseLogFromEnv)
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.SessionEvidence (observeProvider)
import Singular.Registry.SessionIO (withLatest)
import Singular.Registry.SessionIO qualified as SessionIO
import Singular.Registry.Signing (signTx, signedTx)
import Singular.Registry.TimeSource (loadPinnedSource)
import Singular.Registry.Wait (boundedSignedSubmission)
import Singular.Registry.Wallet (Wallet (..))

newCapabilities :: ProviderSettings -> IO (Capabilities NoWitness IO)
newCapabilities settings = do
    logHandle <- phaseLogFromEnv
    raw <- newIORef []
    facts <- newIORef []
    runtime <-
        newIORuntime
            logHandle
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
            , capSubmit = \signed -> boundedSignedSubmission 300 (submitTx provider network) signed
            , capConfirm = awaitTransaction provider network
            , capFacts = readIORef facts
            , capTrace = readIORef raw
            }

withReads
    :: ProviderSettings -> (Capabilities NoWitness IO -> IO a) -> IO a
withReads settings action = do
    capabilities <- newCapabilities settings
    -- Startup validates the pinned network context in its own logged scope,
    -- as the former composition did. It is never spliced into a built body.
    withLatest (capReads capabilities) $ \session ->
        SessionIO.parameters session >> pure ()
    action capabilities

withWrites
    :: ProviderSettings
    -> Wallet
    -> (Capabilities NoWitness IO -> IO a)
    -> IO a
withWrites settings wallet action = withReads settings $ \capabilities -> do
    checkFunding
        (capReads capabilities)
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
