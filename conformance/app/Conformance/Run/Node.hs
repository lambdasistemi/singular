{- | Shipping HTTP capabilities for conformance transactions. A generated
private source exposes actual ledger queries and full blocks; a separate private
LSQ connection supplies the independent accepting/refusing replay controls.
The replay connection never submits a conformance transaction.
-}
module Conformance.Run.Node
    ( checkHarnessGenesis
    , withHarnessNode
    , withReplayingNode
    ) where

import Control.Concurrent.Async (link, withAsync)
import Data.Text (Text)
import System.Environment (lookupEnv)

import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Node.Client.E2E.Setup (genesisDir)
import Cardano.Node.Client.N2C.Connection
    ( newLSQChannel
    , newLTxSChannel
    , runNodeClient
    )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Ouroboros.Network.Magic (NetworkMagic (..))
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Node
    ( ExternalNode (..)
    , NodeMode (..)
    , devnetGenesis
    , runMode
    )
import Singular.Registry.Private.Facade
    ( Facade (..)
    , GenesisFunding (..)
    , withGeneratedFacade
    )
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.Terminal (withWrites)
import Singular.Registry.Wallet (Wallet (..), loadWallet)

import Conformance.Run.Environment
    ( checkGenesis
    , genesisAddr
    , genesisSignKey
    )
import Conformance.Run.Replay
    ( ReplayEnv (..)
    , ReplayIndex
    , capturingSignedSubmission
    , newReplayEnv
    )

checkHarnessGenesis :: IO ()
checkHarnessGenesis = devnetGenesis >>= mapM_ checkGenesis

withHarnessNode :: (Capabilities NoWitness IO -> IO a) -> IO a
withHarnessNode body = openHarnessNode (\_ _ -> body)

withReplayingNode
    :: FilePath
    -> FilePath
    -> Text
    -> (Capabilities NoWitness IO -> ReplayIndex -> IO a)
    -> IO a
withReplayingNode blueprintPath receiptsDir nodeId body =
    openHarnessNode $ \magic socket caps -> do
        lsq <- newLSQChannel 16
        unusedSubmission <- newLTxSChannel 16
        withAsync (runNodeClient magic socket lsq unusedSubmission) $ \connection -> do
            link connection
            replay <-
                newReplayEnv (mkN2CProvider lsq) lsq blueprintPath receiptsDir nodeId
            body
                caps{capSubmit = capturingSignedSubmission replay (capSubmit caps)}
                (reIndex replay)

openHarnessNode
    :: (NetworkMagic -> FilePath -> Capabilities NoWitness IO -> IO a)
    -> IO a
openHarnessNode body = case runMode of
    Devnet -> do
        directory <- genesisDir
        let wallet = Wallet genesisAddr genesisSignKey Testnet
        withGeneratedFacade FundGenesis directory (const (pure ())) $ \_ facade ->
            withWrites (facadeSettings facade) wallet $
                body (NetworkMagic 42) (facadeSocket facade)
    External external -> do
        url <- required "SINGULAR_KOIOS_URL"
        timeDirectory <- required "SINGULAR_NETWORK_TIME"
        tokenFile <- lookupEnv "SINGULAR_KOIOS_TOKEN_FILE"
        wallet <- loadWallet (extMagic external) (extSkeyFile external)
        let settings =
                ProviderSettings
                    { providerUrl = url
                    , providerMagic = extMagic external
                    , providerTokenFile = tokenFile
                    , providerTimeDirectory = Just timeDirectory
                    }
        withWrites settings wallet $
            body (NetworkMagic (extMagic external)) (extSocket external)
  where
    required name =
        lookupEnv name
            >>= maybe (fail (name <> " is required for external conformance")) pure
