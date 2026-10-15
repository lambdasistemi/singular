{-# LANGUAGE LambdaCase #-}

{- |
Module      : Conformance.Support.FoldAdmission
Description : The library admission is the model's admission (#519)
License     : Apache-2.0

Pull request 3 of #519 promotes the fold's window rule into the registry
library. This spec proves the library's pure @foldAdmission@ gives the
model's verdict at the boundary and one past it: each case asks the
model's batch question through the driver transport the conformance
package already uses and compares it with the library's answer. A control
version that admits one past the deadline fails the comparison, and the
comparison reports failure on an answer that is neither accepted nor
refused for the expected reason.

Fixed times only: no wall clock, no timing margin. The verdict agreement
is the whole subject; which request the library names beyond the verdict
is pinned by the off-chain unit suite.
-}
module Conformance.Support.FoldAdmission (spec) where

import Conformance.Lean.Oracle (expectedObservation)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Bits (shiftR, xor, (.&.))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64, Word8)
import System.Environment (lookupEnv)
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , runIO
    , shouldBe
    , shouldSatisfy
    )

import Singular.Registry.FoldAdmission
    ( AdmissionRefusal
    , admissionReason
    , admissionSource
    , foldAdmission
    , refusalRef
    )

-- ---------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------

-- | A variable the package wires, or a failure naming it.
wired :: String -> IO FilePath
wired name =
    lookupEnv name
        >>= maybe
            (error (name <> " is not wired; the transport has nothing to ask"))
            pure

-- ---------------------------------------------------------
-- Fixtures: one registry, fixed times
-- ---------------------------------------------------------

-- | The registry's processing time, POSIX milliseconds.
processTimeMs :: Integer
processTimeMs = 60000

-- | The submission time every fixture request carries.
submittedAtMs :: Integer
submittedAtMs = 1000

-- | The deadline the model and the library both judge against.
deadlineMs :: Integer
deadlineMs = submittedAtMs + processTimeMs

-- | One included request as reference with submission time.
oneRequest :: [(Int, Integer)]
oneRequest = [(1, submittedAtMs)]

-- | Two included requests whose input order differs from deadline order.
twoRequests :: [(Int, Integer)]
twoRequests = [(1, 50000), (2, submittedAtMs)]

-- ---------------------------------------------------------
-- Model identities (inputs only, after FoldSelection)
-- ---------------------------------------------------------

-- | The pinned policies the driver corpus uses.
applicationPolicy :: Int
applicationPolicy = 7

activePolicy :: Int
activePolicy = 8

-- | The model's deposit for a booked request, as the corpus spells it.
depositOf :: Int
depositOf = 55

-- | The output a delivered token is routed to, derived from the key.
outputOf :: Int -> Int
outputOf key = 500 + key

-- | The owner's model identity, derived from the owner's text.
ownerNatOf :: Text -> Int
ownerNatOf owner =
    1000
        + T.foldl'
            (\acc c -> (acc * 33 + fromEnum c) `mod` 9000)
            5381
            owner

-- | FNV-1a over a byte list, as the model commits.
fnv1a :: [Word8] -> Word64
fnv1a =
    foldl
        (\h b -> (h `xor` fromIntegral b) * 16777619)
        14695981039346656037

-- | Big-endian bytes of a word, as the model commits.
u64bytes :: Word64 -> [Word8]
u64bytes n =
    [ fromIntegral ((n `shiftR` s) .&. 0xFF)
    | s <- [56, 48, 40, 32, 24, 16, 8, 0]
    ]

-- | The model's root over no pairs: the empty trie commits FNV-1a of nothing.
rootNumbersEmpty :: [Int]
rootNumbersEmpty = map fromIntegral (u64bytes (fnv1a []))

-- | The start state: the empty trie under a config with our processing time.
startJson :: Value
startJson =
    object
        [ "config"
            .= object
                [ "root" .= rootNumbersEmpty
                , "maxFee" .= (0 :: Int)
                , "processTime" .= processTimeMs
                , "retractTime" .= (0 :: Int)
                , "applicationPolicy" .= applicationPolicy
                , "activePolicy" .= activePolicy
                , "absentPolicy" .= (9 :: Int)
                , "terminalPolicy" .= (10 :: Int)
                ]
        , "trie" .= ([] :: [Value])
        , "custody" .= ([] :: [Value])
        , "held" .= ([] :: [Value])
        ]

{- | One fixture request as the model's request: an insertion of an unknown
key asking for the claim an honest folder makes, with the approval this
very request carries.
-}
requestJson :: Int -> Text -> Integer -> Value
requestJson key owner submittedAt =
    object
        [ "edge" .= ("insertActive" :: Text)
        , "key" .= key
        , "owner" .= ownerNatOf owner
        , "refundAddress" .= (0 :: Int)
        , "submittedAt" .= submittedAt
        , "deposit" .= depositOf
        , "output" .= outputOf key
        , "approval" .= ("canonical" :: Text)
        , "applicationPolicy" .= applicationPolicy
        , "claimed" .= ("canonical" :: Text)
        ]

-- | The batch question under the given finite excluded upper bound.
questionJson :: Text -> Integer -> [Value] -> Value
questionJson qid validTo requests =
    object
        [ "id" .= qid
        , "theorem" .= ("Singular.Statements.fold_batch_cons" :: Text)
        , "statementSha256"
            .= ( "a0992d97ae5b6f86503bdc5247b4b2602ec74a5516713e274c4919aa53d5d26f"
                    :: Text
               )
        , "question" .= ("foldBatch" :: Text)
        , "start" .= startJson
        , "setup" .= ([] :: [Value])
        , "foldWitness" .= object ["validTo" .= validTo]
        , "requests" .= requests
        ]

-- ---------------------------------------------------------
-- Reading the model's answer and comparing it
-- ---------------------------------------------------------

field :: Key.Key -> Value -> Maybe Value
field name (Object fields) = KM.lookup name fields
field _ _ = Nothing

-- | Require acceptance of the model's batch question.
requireAccepted :: Value -> IO ()
requireAccepted answer = do
    field "outcome" answer `shouldBe` Just (String "accepted")
    field "reason" answer `shouldBe` Just Null

{- | Check a refusal with the expected reason. 'Right' only for the refused
reason; an accepting answer reports failure.
-}
checkRefused :: Text -> Value -> Either String ()
checkRefused expected answer =
    case (field "outcome" answer, field "reason" answer) of
        (Just (String "refused"), Just (String got)) ->
            if got == expected
                then Right ()
                else Left ("refused for another reason: " <> T.unpack got)
        (Just (String "accepted"), _) ->
            Left "the model accepted a batch it must refuse"
        _ -> Left "the model's answer is neither accepted nor refused"

{- | The library's verdict beside the model's answer: agreement is
admitted-and-accepted or refused-for-the-same-reason; anything else is a
mismatch naming what differed.
-}
compareAdmission
    :: Maybe (AdmissionRefusal Int) -> Value -> Either String ()
compareAdmission library answer = case (library, field "outcome" answer) of
    (Nothing, Just (String "accepted")) -> Right ()
    (Nothing, _) -> Left "the library admits what the model refuses"
    (Just _, Just (String "refused")) -> case field "reason" answer of
        Just (String got)
            | got == T.pack admissionReason -> Right ()
            | otherwise ->
                Left ("the model refuses for another reason: " <> T.unpack got)
        _ -> Left "the model's refusal carries no reason"
    (Just _, _) -> Left "the library refuses what the model accepts"

spec :: Spec
spec = describe "The library admission is the model's admission" $ do
    evaluator <- runIO (wired "CONFORMANCE_MODEL_EVALUATOR")
    describe "admission-agrees-at-the-boundary-and-one-past" $ do
        it "admits at the deadline where the model accepts" $ do
            let library = foldAdmission processTimeMs deadlineMs oneRequest
            library `shouldBe` Nothing
            answer <-
                either error pure
                    =<< expectedObservation
                        evaluator
                        []
                        ( questionJson
                            "fold-admission-at-deadline"
                            deadlineMs
                            [requestJson 7 "Alice" submittedAtMs]
                        )
            requireAccepted answer
            compareAdmission library answer `shouldBe` Right ()
        it "refuses one past the deadline where the model refuses not-phase1" $ do
            let bound = deadlineMs + 1
                library = foldAdmission processTimeMs bound oneRequest
            refusalRef <$> library `shouldBe` Just 1
            answer <-
                either error pure
                    =<< expectedObservation
                        evaluator
                        []
                        ( questionJson
                            "fold-admission-one-past"
                            bound
                            [requestJson 7 "Alice" submittedAtMs]
                        )
            checkRefused "not-phase1" answer `shouldBe` Right ()
            compareAdmission library answer `shouldBe` Right ()
        it "names the first offender in input order beside a model refusal" $ do
            let bound = deadlineMs + 1
                library = foldAdmission processTimeMs bound twoRequests
            case library of
                Just refusal -> refusalRef refusal `shouldBe` 2
                Nothing ->
                    expectationFailure
                        "the library admits a batch one past a deadline"
            answer <-
                either error pure
                    =<< expectedObservation
                        evaluator
                        []
                        ( questionJson
                            "fold-admission-input-order"
                            bound
                            [ requestJson 11 "Carol" 50000
                            , requestJson 7 "Alice" submittedAtMs
                            ]
                        )
            checkRefused "not-phase1" answer `shouldBe` Right ()
    describe "control-versions-fail-the-comparison" $ do
        it "fails a version that admits one past the deadline" $ do
            let bound = deadlineMs + 1
                -- The control asks about a bound one smaller, so it admits
                -- what the model refuses one past the deadline.
                wrong = foldAdmission processTimeMs (bound - 1) oneRequest
            wrong `shouldBe` Nothing
            answer <-
                either error pure
                    =<< expectedObservation
                        evaluator
                        []
                        ( questionJson
                            "fold-admission-control"
                            bound
                            [requestJson 7 "Alice" submittedAtMs]
                        )
            checkRefused "not-phase1" answer `shouldBe` Right ()
            compareAdmission wrong answer `shouldSatisfy` \case
                Left _ -> True
                Right _ -> False
        it "reports failure on an answer that is neither accepted nor refused" $ do
            compareAdmission Nothing (object ["outcome" .= ("stuck" :: Text)])
                `shouldSatisfy` \case
                    Left _ -> True
                    Right _ -> False
        it "reports the model's refusal word and source" $ do
            admissionReason `shouldBe` "not-phase1"
            admissionSource `shouldBe` "model-refusal"
