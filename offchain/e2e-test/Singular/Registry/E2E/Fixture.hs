{- | End-to-end startup over the generated private node's raw HTTP facade.
The source actor owns LSQ, full-block history and independent genesis funding;
the specs receive the shipping shared HTTP capabilities and use explicit
private genesis signing material for their transactions. Source-bound runs
retain every independent source exchange and the actual constructor's facts,
including when an accepting or refusing assertion fails.
-}
module Singular.Registry.E2E.Fixture
    ( withDevnetCapabilities
    , withDevnetSource
    , withRecordedWrites
    , keepPrivateValue
    ) where

import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Node.Client.E2E.Setup
    ( genesisAddr
    , genesisDir
    , genesisSignKey
    )
import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Exception (finally)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Unique (hashUnique, newUnique)
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Private.Facade
    ( Facade (..)
    , GenesisFunding (..)
    , withGeneratedFacade
    )
import Singular.Registry.ProviderSettings (ProviderSettings)
import Singular.Registry.Terminal (withWritesObserved)
import Singular.Registry.Wallet (Wallet (..))
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO (IOMode (AppendMode), hFlush, withBinaryFile)

withDevnetCapabilities
    :: (Integer -> Capabilities NoWitness IO -> IO a) -> IO a
withDevnetCapabilities action =
    withDevnetSource (\start _ _ caps -> action start caps)

{- | Private source inspection is confined to the E2E fixture callback.
Ordinary consumers still receive only withDevnetCapabilities.
-}
withDevnetSource
    :: (Integer -> Facade -> Wallet -> Capabilities NoWitness IO -> IO a)
    -> IO a
withDevnetSource action = do
    directory <- genesisDir
    let wallet = Wallet genesisAddr genesisSignKey Testnet
        run observer =
            withGeneratedFacade FundGenesis directory observer $ \start facade ->
                withRecordedWrites (facadeSettings facade) wallet $ \caps ->
                    action start facade wallet caps
    evidence <- lookupEnv "SINGULAR_PROVIDER_CONTROL_EVIDENCE"
    case evidence of
        Nothing -> run (const (pure ()))
        Just root -> do
            identity <- hashUnique <$> newUnique
            let destination = root </> ("e2e-source-" <> show identity)
            createDirectoryIfMissing True destination
            serial <- newMVar ()
            withBinaryFile
                (destination </> "independent-sources.jsonl")
                AppendMode
                $ \handle ->
                    run
                        ( \event -> withMVar serial $ \_ -> do
                            LBS.hPut handle (encode event <> "\n")
                            hFlush handle
                        )

-- | Retain each actual constructor even when funding refuses before its body.
withRecordedWrites
    :: ProviderSettings
    -> Wallet
    -> (Capabilities NoWitness IO -> IO a)
    -> IO a
withRecordedWrites settings wallet action = do
    observed <- newIORef Nothing
    finally
        ( withWritesObserved
            mempty
            mempty
            (writeIORef observed . Just)
            settings
            wallet
            action
        )
        ( readIORef observed
            >>= maybe
                (pure ())
                ( \caps -> do
                    facts <- capFacts caps
                    trace <- capTrace caps
                    keepPrivateValue
                        "e2e-actual-provider-evidence"
                        (object ["facts" .= facts, "rawSources" .= trace])
                )
        )

-- | The existing opt-in private fixture directory. No key material is saved.
keepPrivateValue :: String -> Value -> IO ()
keepPrivateValue label value = do
    evidence <- lookupEnv "SINGULAR_PROVIDER_CONTROL_EVIDENCE"
    case evidence of
        Nothing -> pure ()
        Just root -> do
            identity <- hashUnique <$> newUnique
            createDirectoryIfMissing True root
            LBS.writeFile
                (root </> (label <> "-" <> show identity <> ".json"))
                (encode value <> "\n")
