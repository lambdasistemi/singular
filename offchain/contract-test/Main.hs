{- |
Module      : Main
Description : The raw-session contract with explicit uncovered view requirements
License     : Apache-2.0

Without external settings, exercise the existing raw fixture and a generated
private HTTP source. An external leg requires a provider URL, network magic,
pinned time source, funded wallet and separate private oracle socket together.
It never starts a generated fallback or passes a socket to the shipping provider.
Original view/index and connection-guard requirements remain visibly unsupported.
-}
module Main (main) where

import Data.Word (Word32)
import System.Environment (getArgs, withArgs)
import System.Exit (die)
import Test.Hspec (describe, hspec)
import Test.Tags (Area (..), tagged)
import Text.Read (readMaybe)

import Singular.Registry.ContractMemory (memoryHarness)
import Singular.Registry.ContractNode
    ( Leg (..)
    , guardOnDevnet
    , phaseLogOnDevnet
    , providerHarness
    )
import Singular.Registry.ContractSuite (contractSuite)
import Singular.Registry.ProviderSettings (ProviderSettings (..))

main :: IO ()
main = do
    args <- getArgs
    case external args of
        Left problem -> die ("contract-tests: " <> problem)
        Right (Just leg) ->
            withArgs [] . hspec $
                describe (tagged "Singular.Registry.ContractSuite" [Provider, E2e]) $
                    contractSuite (providerHarness leg)
        Right Nothing ->
            withArgs args . hspec $ do
                describe (tagged "Singular.Registry.ContractSuite" [Provider, E2e]) $
                    contractSuite memoryHarness
                describe (tagged "Singular.Registry.ContractSuite" [Provider, E2e]) $
                    contractSuite (providerHarness Generated)
                describe
                    (tagged "Singular.Registry.ContractNode" [Provider, E2e])
                    guardOnDevnet
                describe
                    (tagged "Singular.Registry.ContractNode" [Provider, E2e])
                    phaseLogOnDevnet

-- | All external inputs, none, or an explicit refusal. No socket fallback.
external :: [String] -> Either String (Maybe Leg)
external args
    | elem "--node-socket" args || elem "--backend" args =
        Left
            "node/backend selectors are retired; use HTTP settings and --private-probe-socket for the independent oracle"
    | otherwise = do
        values <- traverse flag names
        case values of
            [Nothing, Nothing, Nothing, Nothing, Nothing] -> Right Nothing
            [Just url, Just number, Just timeSource, Just key, Just socket] -> do
                magic <-
                    maybe
                        (Left ("--network-magic is not a Word32: " <> number))
                        Right
                        (readMaybe number :: Maybe Word32)
                if any null [url, timeSource, key, socket]
                    then Left "external settings cannot be empty"
                    else
                        Right . Just $
                            Outside
                                (ProviderSettings url magic Nothing (Just timeSource))
                                socket
                                key
            _ ->
                Left
                    "the external leg needs --provider-url, --network-magic, --time-source, --wallet-skey and --private-probe-socket together"
  where
    names =
        [ "--provider-url"
        , "--network-magic"
        , "--time-source"
        , "--wallet-skey"
        , "--private-probe-socket"
        ]
    flag name = case dropWhile (/= name) args of
        [] -> Right Nothing
        _ : value : _
            | take 2 value /= "--" -> Right (Just value)
        _ -> Left ("missing value for " <> name)
