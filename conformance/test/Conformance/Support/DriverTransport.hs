{- |
Module      : Conformance.Support.DriverTransport
Description : The transport answers every corpus row exactly as the driver did
License     : Apache-2.0

Appendix material. The live runner asks the model through the transport; the
model check holds the driver's committed corpus. This replays every corpus row
— each single-request scenario and each batch row — through the transport the
runner uses, and requires the answer the driver gave. A batch question the
transport could not carry, or a single-request answer it changed, fails here.
-}
module Conformance.Support.DriverTransport (spec) where

import Conformance.Lean.Oracle (expectedObservation)
import Control.Monad (forM_)
import Data.Aeson
    ( Value (..)
    , eitherDecodeFileStrict
    , object
    , (.=)
    )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Maybe (mapMaybe)
import Data.Vector qualified as V
import System.Environment (lookupEnv)
import Test.Hspec (Spec, describe, it, runIO, shouldBe, shouldSatisfy)

-- | A variable the package wires, or a failure naming it.
wired :: String -> IO FilePath
wired name =
    lookupEnv name
        >>= maybe
            (error (name <> " is not wired; the transport has nothing to replay"))
            pure

field :: Key.Key -> Value -> Maybe Value
field name (Object fields) = KM.lookup name fields
field _ _ = Nothing

rowsOf :: Key.Key -> Value -> [Value]
rowsOf name corpus = case field name corpus of
    Just (Array rows) -> V.toList rows
    _ -> []

-- | The requests a setup trace ran, as a question names them.
setupRequests :: Value -> Value
setupRequests row = case field "setup" row of
    Just (Array steps) -> Array (V.mapMaybe (field "request") steps)
    _ -> Array V.empty

-- | Copy these fields of the row into the question, where the row has them.
carried :: [Key.Key] -> Value -> [(Key.Key, Value)]
carried names row = mapMaybe (\name -> (,) name <$> field name row) names

-- | The question a single-request row answers.
scenarioQuestion :: Value -> Value
scenarioQuestion row =
    object $
        [ "setup" .= setupRequests row
        , "exit" .= field "operation" row
        ]
            <> map
                (uncurry (.=))
                ( carried
                    [ "id"
                    , "theorem"
                    , "statementSha256"
                    , "start"
                    , "request"
                    , "lovelace"
                    , "witness"
                    ]
                    row
                )

-- | The question a batch row answers.
batchQuestion :: Value -> Value
batchQuestion row =
    object $
        ["setup" .= setupRequests row]
            <> map
                (uncurry (.=))
                ( carried
                    [ "question"
                    , "id"
                    , "theorem"
                    , "statementSha256"
                    , "start"
                    , "requests"
                    , "outputs"
                    ]
                    row
                )

-- | What an answer must agree with its row on: everything the driver computed.
computed :: [Key.Key] -> Value -> [(Key.Key, Maybe Value)]
computed names row = [(name, field name row) | name <- names]

answered :: [Key.Key]
answered = ["outcome", "reason", "premise", "observations", "setup"]

spec :: Spec
spec = describe "Appendix — the transport answers as the driver did" $ do
    corpus <-
        runIO $
            wired "CONFORMANCE_DRIVER_CORPUS"
                >>= eitherDecodeFileStrict
                >>= either error pure
    evaluator <- runIO (wired "CONFORMANCE_MODEL_EVALUATOR")
    let scenarios = rowsOf "scenarios" corpus
        batches = rowsOf "batches" corpus
        questions = mapMaybe (field "question") batches
    it "replays a non-empty extent of single-request and batch rows" $ do
        scenarios `shouldSatisfy` (not . null)
        batches `shouldSatisfy` (not . null)
        questions
            `shouldSatisfy` (\qs -> all (`elem` qs) [String "foldBatch", String "rejectBatch"])
    forM_ scenarios $ \row ->
        it ("answers the single-request row " <> show (field "id" row)) $ do
            answer <-
                expectedObservation evaluator [] (scenarioQuestion row)
                    >>= either error pure
            computed answered answer `shouldBe` computed answered row
    forM_ batches $ \row ->
        it ("answers the batch row " <> show (field "id" row)) $ do
            answer <-
                expectedObservation evaluator [] (batchQuestion row)
                    >>= either error pure
            computed
                (answered <> ["question", "requests", "folded", "settle"])
                answer
                `shouldBe` computed
                    (answered <> ["question", "requests", "folded", "settle"])
                    row
