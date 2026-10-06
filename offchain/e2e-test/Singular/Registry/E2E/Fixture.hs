{- | End-to-end startup over the generated private node's raw HTTP facade.
The source actor owns LSQ, full-block history and independent genesis funding;
the specs receive the shipping shared HTTP capabilities and use explicit
private genesis signing material for their transactions. Source-bound runs
retain every independent source exchange and the actual constructor's facts,
including when an accepting or refusing assertion fails.
-}
module Singular.Registry.E2E.Fixture
    ( withDevnetCapabilities
    ) where

import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Node.Client.E2E.Setup
    ( genesisAddr
    , genesisDir
    , genesisSignKey
    )
import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Exception (finally)
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Unique (hashUnique, newUnique)
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Private.Facade
    ( Facade (..)
    , GenesisFunding (..)
    , withGeneratedFacade
    )
import Singular.Registry.Terminal (withWrites)
import Singular.Registry.Wallet (Wallet (..))
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO (IOMode (AppendMode), hFlush, withBinaryFile)

withDevnetCapabilities
    :: (Integer -> Capabilities NoWitness IO -> IO a) -> IO a
withDevnetCapabilities action = do
    directory <- genesisDir
    let wallet = Wallet genesisAddr genesisSignKey Testnet
        run observer keep =
            withGeneratedFacade FundGenesis directory observer $ \start facade ->
                withWrites (facadeSettings facade) wallet $ \caps ->
                    action start caps `finally` keep caps
    evidence <- lookupEnv "SINGULAR_PROVIDER_CONTROL_EVIDENCE"
    case evidence of
        Nothing -> run (const (pure ())) (const (pure ()))
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
                        ( \caps -> do
                            facts <- capFacts caps
                            trace <- capTrace caps
                            LBS.writeFile
                                (destination </> "actual-provider-evidence.json")
                                (encode (object ["facts" .= facts, "rawSources" .= trace]) <> "\n")
                        )
