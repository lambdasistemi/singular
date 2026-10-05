{-# LANGUAGE LambdaCase #-}

{- | Retained runners receive a provider and wallet explicitly. Their private
node fixture belongs to the devnet launcher; this composition opens only
the shipping shared HTTP provider and reads the caller's signing-key file.
-}
module Singular.Registry.Runner
    ( RunnerSettings (..)
    , runnerSettings
    , withRunner
    ) where

import Control.Applicative ((<|>))
import Control.Exception (ErrorCall (..), finally, throwIO)
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.List (stripPrefix)
import Data.Word (Word32)
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.Terminal (withWrites)
import Singular.Registry.Wallet (Wallet, loadWallet)
import System.Environment (getArgs, getEnvironment, lookupEnv)
import Text.Read (readMaybe)

data RunnerSettings = RunnerSettings
    { runnerProvider :: ProviderSettings
    , runnerWalletFile :: FilePath
    }
    deriving stock (Eq, Show)

{- | Flags override environment; unrelated story flags remain with the runner.
Removed settings refuse before a wallet, source or provider is opened.
-}
runnerSettings
    :: [String] -> [(String, String)] -> Either String RunnerSettings
runnerSettings args environment = do
    case [argument | argument <- args, obsolete argument] of
        argument : _ -> Left ("obsolete provider setting: " <> argument)
        [] -> pure ()
    case lookup "SINGULAR_NODE_SOCKET" environment of
        Just _ -> Left "obsolete provider setting: SINGULAR_NODE_SOCKET"
        Nothing -> pure ()
    url <- required "--koios-url" "SINGULAR_KOIOS_URL"
    magicText <- required "--network-magic" "SINGULAR_NETWORK_MAGIC"
    magic <-
        maybe
            (Left ("network magic is not a number: " <> magicText))
            Right
            (readMaybe magicText :: Maybe Word32)
    if magic == 764824073
        then
            Left "these submitting runners refuse mainnet network magic764824073"
        else pure ()
    key <- required "--wallet-skey" "SINGULAR_WALLET_SKEY"
    token <- selected "--koios-token-file" "SINGULAR_KOIOS_TOKEN_FILE"
    time <- selected "--network-time" "SINGULAR_NETWORK_TIME"
    pure (RunnerSettings (ProviderSettings url magic token time) key)
  where
    obsolete argument =
        argument `elem` ["--backend", "--node-socket"]
            || any
                (\prefix -> maybe False (const True) (stripPrefix prefix argument))
                ["--backend=", "--node-socket="]
    selected flag variable = do
        chosen <- named flag args
        case chosen <|> lookup variable environment of
            Just "" -> Left (flag <> " needs a nonempty value")
            other -> Right other
    required flag variable =
        selected flag variable
            >>= maybe
                ( Left
                    ( "provider runner is partially configured: "
                        <> flag
                        <> " (or "
                        <> variable
                        <> ") is required with --koios-url, --network-magic and --wallet-skey"
                    )
                )
                Right
    named flag = \case
        [] -> Right Nothing
        argument : rest
            | argument == flag -> case rest of
                value : _ | take 2 value /= "--" -> Right (Just value)
                _ -> Left (flag <> " needs a value")
            | Just value <- stripPrefix (flag <> "=") argument ->
                Right (Just value)
            | otherwise -> named flag rest

withRunner :: (Wallet -> Capabilities NoWitness IO -> IO a) -> IO a
withRunner action = do
    args <- getArgs
    environment <- getEnvironment
    settings <-
        either (throwIO . ErrorCall) pure (runnerSettings args environment)
    wallet <-
        loadWallet
            (providerMagic (runnerProvider settings))
            (runnerWalletFile settings)
    target <- lookupEnv "SINGULAR_RUNNER_EVIDENCE"
    withWrites (runnerProvider settings) wallet $ \capabilities ->
        action wallet capabilities `finally` case target of
            Nothing -> pure ()
            Just path -> do
                facts <- capFacts capabilities
                trace <- capTrace capabilities
                LBS.writeFile
                    path
                    ( encode
                        ( object
                            [ "facts" .= facts
                            , "rawSources" .= trace
                            ]
                        )
                    )
