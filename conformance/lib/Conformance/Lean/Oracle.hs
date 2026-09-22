-- | JSON transport shared by the model observations consumed by live stories.
module Conformance.Lean.Oracle (expectedObservation) where

import Data.Aeson (Value, eitherDecode, encode)
import Data.ByteString.Lazy.Char8 qualified as BSL
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

expectedObservation :: FilePath -> [String] -> Value -> IO (Either String Value)
expectedObservation executable arguments scenario = do
    (status, output, diagnostics) <- readProcessWithExitCode executable arguments (BSL.unpack (encode scenario) <> "\n")
    pure $ case status of
        ExitFailure code -> Left ("Lean evaluator failed (" <> show code <> "): " <> diagnostics <> output)
        ExitSuccess -> case eitherDecode (BSL.pack output) of
            Left reason -> Left ("invalid Lean evaluator response: " <> reason)
            Right expected -> Right expected
