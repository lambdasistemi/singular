-- | JSON transport shared by the model observations consumed by live stories.
module Conformance.Lean.Oracle (expectedObservation, modelVerdict) where

import Data.Aeson (Value (..), eitherDecode, encode)
import Data.Aeson.KeyMap qualified as KM
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

{- | The model's verdict on a submitted transaction, as its outcome and reason:
the law's, from the driver's row, and, when the law accepts and the driver was
asked to judge the transaction's outputs, a refusal for the reason the
judgement names when they do not pay what the exit owes.
-}
modelVerdict :: Value -> Maybe Value -> Either String (Value, Value)
modelVerdict row judged = do
    outcome <- field "outcome" row
    reason <- field "reason" row
    case (outcome, judged) of
        (String "accepted", Just judgement) -> do
            settled <- field "settle" judgement
            case settled of
                Null -> pure (outcome, reason)
                String why -> pure (String "refused", String why)
                _ -> Left "the driver's judgement is neither settled nor a reason"
        _ -> pure (outcome, reason)
  where
    field name (Object fields) = maybe (Left ("model row has no " <> show name)) Right
        (KM.lookup name fields)
    field name _ = Left ("model row is not an object reading " <> show name)
