-- | JSON transport shared by the model observations consumed by live stories.
module Conformance.Lean.Oracle (expectedObservation, compareObservation) where

import Data.Aeson (Value, eitherDecode, encode)
import Data.ByteString.Lazy.Char8 qualified as BSL
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

expectedObservation :: FilePath -> [String] -> Value -> IO (Either String Value)
expectedObservation executable arguments scenario = do
    (status, output, diagnostics) <- readProcessWithExitCode executable arguments (BSL.unpack (encode scenario) <> "\n")
    pure $ case status of
        ExitFailure code -> Left ("Lean oracle failed (" <> show code <> "): " <> diagnostics <> output)
        ExitSuccess -> case eitherDecode (BSL.pack output) of
            Left reason -> Left ("invalid Lean oracle response: " <> reason)
            Right expected -> Right expected

compareObservation :: Value -> Value -> Either String ()
compareObservation expected observed
    | expected == observed = Right ()
    | otherwise = Left ("observation differs from Lean\nexpected: " <> BSL.unpack (encode expected)
        <> "\nobserved: " <> BSL.unpack (encode observed))
