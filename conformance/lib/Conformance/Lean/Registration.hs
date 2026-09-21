-- | The delivery projection proved by the registration theorem. Expectations
-- are computed by the packaged Lean executable, never reconstructed here.
module Conformance.Lean.Registration (
    DeliveryCheck (..), registrationDelivery, insertActiveRow,
    expectedDelivery, compareDelivery,
) where

import Data.Aeson (Value, eitherDecode, encode)
import Data.ByteString.Lazy.Char8 qualified as BSL
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import Conformance.Story.Binding (Binding, mkBoundObligation)

data DeliveryCheck = RegistrationDelivery
    deriving stock (Show, Eq)

registrationDelivery :: DeliveryCheck
registrationDelivery = RegistrationDelivery

insertActiveRow :: Binding
insertActiveRow = mkBoundObligation
    "Singular.Statements.insert_active_transaction_row"
    "bfb4e3174839b649a883244b97053ea52985cb3eeea1d3eb4475bb273e841737"
    "265c595edd72eab10f3b08a36cb010ad407cf48b"

expectedDelivery :: FilePath -> Value -> IO (Either String Value)
expectedDelivery executable scenario = do
    (status, output, diagnostics) <- readProcessWithExitCode executable [] (BSL.unpack (encode scenario) <> "\n")
    pure $ case status of
        ExitFailure code -> Left ("Lean oracle failed (" <> show code <> "): " <> diagnostics <> output)
        ExitSuccess -> case eitherDecode (BSL.pack output) of
            Left reason -> Left ("invalid Lean oracle response: " <> reason)
            Right expected -> Right expected

compareDelivery :: Value -> Value -> Either String ()
compareDelivery expected observed
    | expected == observed = Right ()
    | otherwise = Left ("delivery differs from Lean\nexpected: " <> BSL.unpack (encode expected)
        <> "\nobserved: " <> BSL.unpack (encode observed))
