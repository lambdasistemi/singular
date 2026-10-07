{-# LANGUAGE LambdaCase #-}

{- | Shipping HTTP capabilities and an explicit funding wallet for conformance.
A generated private source exposes actual ledger queries and full blocks;
a separate read-only LSQ connection supplies the independent replay controls.
-}
module Conformance.Run.Node
    ( checkHarnessGenesis
    , withHarnessNode
    , withReplayingNode
    ) where

import Control.Applicative ((<|>))
import Control.Concurrent.Async (link, withAsync)
import Control.Monad (when)
import Data.List (stripPrefix)
import Data.Text (Text)
import System.Environment (getArgs, getEnvironment)
import Text.Read (readMaybe)

import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Node.Client.E2E.Setup qualified as Setup
import Cardano.Node.Client.N2C.Connection
    ( newLSQChannel
    , newLTxSChannel
    , runNodeClient
    )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Ouroboros.Network.Magic (NetworkMagic (..))
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Private.Facade
    ( Facade (..)
    , GenesisFunding (..)
    , withGeneratedFacade
    )
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.Terminal (withWrites)
import Singular.Registry.Wallet (Wallet (..), loadWallet)

import Conformance.Run.Actor (Actor (..))
import Conformance.Run.Environment (checkGenesis)
import Conformance.Run.Replay
    ( ReplayEnv (..)
    , ReplayIndex
    , capturingSignedSubmission
    , newReplayEnv
    )

-- | Only the private replay probe uses a node socket. All writes use HTTP.
data HarnessSettings
    = Generated
    | ExternalProbe ProviderSettings FilePath FilePath

harnessSettings :: IO HarnessSettings
harnessSettings = do
    args <- getArgs
    environment <- getEnvironment
    let flag name = go args
          where
            go [] = Nothing
            go (a : rest)
                | a == name = case rest of
                    [] -> Just ""
                    value : _ | take 2 value /= "--" -> Just value
                    _ -> Just ""
                | Just value <- stripPrefix (name <> "=") a = Just value
                | otherwise = go rest
        setting name variable = flag name <|> lookup variable environment
        socket = setting "--node-socket" "SINGULAR_NODE_SOCKET"
        magic = setting "--network-magic" "SINGULAR_NETWORK_MAGIC"
        skey = setting "--wallet-skey" "SINGULAR_WALLET_SKEY"
        required name value = case value of
            Just text | not (null text) -> pure text
            _ -> fail (name <> " is required for external conformance")
    case (socket, magic, skey) of
        (Nothing, Nothing, Nothing) -> pure Generated
        _ -> do
            probe <- required "--node-socket" socket
            magicText <- required "--network-magic" magic
            network <-
                maybe
                    (fail "network magic is not a number")
                    pure
                    (readMaybe magicText)
            when (network == 764824073) $
                fail "external conformance refuses mainnet"
            key <- required "--wallet-skey" skey
            url <-
                required "--koios-url" (setting "--koios-url" "SINGULAR_KOIOS_URL")
            timeDirectory <-
                required
                    "--network-time"
                    (setting "--network-time" "SINGULAR_NETWORK_TIME")
            let token = setting "--koios-token-file" "SINGULAR_KOIOS_TOKEN_FILE"
                settings = ProviderSettings url network token (Just timeDirectory)
            pure (ExternalProbe settings probe key)

checkHarnessGenesis :: IO ()
checkHarnessGenesis =
    harnessSettings >>= \case
        Generated -> Setup.genesisDir >>= checkGenesis
        ExternalProbe{} -> pure ()

withHarnessNode :: (Actor -> IO a) -> IO a
withHarnessNode body = openHarnessNode (\_ _ -> body)

withReplayingNode
    :: FilePath
    -> FilePath
    -> Text
    -> (Actor -> ReplayIndex -> IO a)
    -> IO a
withReplayingNode blueprintPath receiptsDir nodeId body =
    openHarnessNode $ \magic socket actor -> do
        lsq <- newLSQChannel 16
        unusedSubmission <- newLTxSChannel 16
        withAsync (runNodeClient magic socket lsq unusedSubmission) $ \connection -> do
            link connection
            replay <-
                newReplayEnv (mkN2CProvider lsq) lsq blueprintPath receiptsDir nodeId
            let caps = actorCaps actor
            body
                actor
                    { actorCaps =
                        caps{capSubmit = capturingSignedSubmission replay (capSubmit caps)}
                    }
                (reIndex replay)

openHarnessNode
    :: (NetworkMagic -> FilePath -> Actor -> IO a)
    -> IO a
openHarnessNode body =
    harnessSettings >>= \case
        Generated -> do
            directory <- Setup.genesisDir
            let wallet = Wallet Setup.genesisAddr Setup.genesisSignKey Testnet
            withGeneratedFacade FundGenesis directory (const (pure ())) $ \_ facade ->
                withWrites mempty mempty (facadeSettings facade) wallet $ \caps ->
                    body (NetworkMagic 42) (facadeSocket facade) (Actor wallet caps)
        ExternalProbe provider probe key -> do
            wallet <- loadWallet (providerMagic provider) key
            withWrites mempty mempty provider wallet $ \caps ->
                body (NetworkMagic (providerMagic provider)) probe (Actor wallet caps)
