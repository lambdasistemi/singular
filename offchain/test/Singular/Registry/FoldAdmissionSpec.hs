{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.FoldAdmissionSpec
Description : Pure fold admission and within-batch checks refuse (#519)
License     : Apache-2.0

Pull request 3 of #519 promotes the fold's window rule into the registry
library. A request's deadline is its submission time plus the registry's
processing time; a fold is admitted when its finite excluded upper bound
is at or before every included request's deadline, and refused
@not-phase1@ naming the first included request in input order whose
deadline the bound passes. A batch that terminates a key an earlier
insertion of the same batch created is refused @token-missing@ naming the
terminating request and the key.

Every expected value is derived from the inputs by field access and
arithmetic, never typed back from the code's output. Fixed times only: no
wall clock, no timing margin.
-}
module Singular.Registry.FoldAdmissionSpec (spec) where

import Test.Hspec

import Singular.Registry.FoldAdmission

-- ---------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------

-- | The registry's processing time, POSIX milliseconds.
processTimeMs :: Integer
processTimeMs = 60000

-- | The deadline of a request submitted at the given time.
deadlineOf :: Integer -> Integer
deadlineOf submittedAt = submittedAt + processTimeMs

spec :: Spec
spec = do
    describe "foldAdmission" $ do
        it "admits an upper bound at the deadline" $ do
            foldAdmission processTimeMs (deadlineOf 1000) [(1 :: Int, 1000)]
                `shouldBe` Nothing
        it "refuses an upper bound one past the deadline, naming the request" $ do
            foldAdmission processTimeMs (deadlineOf 1000 + 1) [(1 :: Int, 1000)]
                `shouldBe` Just
                    ( AdmissionRefusal
                        { refusalRef = 1
                        , refusalSubmittedAt = 1000
                        , refusalDeadline = deadlineOf 1000
                        , refusalBound = deadlineOf 1000 + 1
                        }
                    )
        it "admits every request inside its own window" $ do
            foldAdmission
                processTimeMs
                (deadlineOf 1000)
                [(1 :: Int, 1000), (2, 20000), (3, 1000)]
                `shouldBe` Nothing
        it "names the first offender in input order, not in deadline order" $ do
            let bound = deadlineOf 1000 + 1
            foldAdmission processTimeMs bound [(1 :: Int, 50000), (2, 1000)]
                `shouldBe` Just
                    ( AdmissionRefusal
                        { refusalRef = 2
                        , refusalSubmittedAt = 1000
                        , refusalDeadline = deadlineOf 1000
                        , refusalBound = bound
                        }
                    )
            foldAdmission processTimeMs bound [(1 :: Int, 1000), (2, 50000)]
                `shouldBe` Just
                    ( AdmissionRefusal
                        { refusalRef = 1
                        , refusalSubmittedAt = 1000
                        , refusalDeadline = deadlineOf 1000
                        , refusalBound = bound
                        }
                    )
        it "judges each request from its own submission time" $ do
            let bound = deadlineOf 20000 + 1
            foldAdmission processTimeMs bound [(1 :: Int, 1000), (2, 20000)]
                `shouldBe` Just
                    ( AdmissionRefusal
                        { refusalRef = 1
                        , refusalSubmittedAt = 1000
                        , refusalDeadline = deadlineOf 1000
                        , refusalBound = bound
                        }
                    )
        it "admits the empty batch" $ do
            foldAdmission
                processTimeMs
                (deadlineOf 1000 + 1)
                ([] :: [(Int, Integer)])
                `shouldBe` Nothing
        it "reports the model's refusal word and source" $ do
            admissionReason `shouldBe` "not-phase1"
            admissionSource `shouldBe` "model-refusal"
    describe "batchConsumesCreated" $ do
        it "refuses a termination of a key an earlier insertion created" $ do
            batchConsumesCreated
                [(1 :: Int, 7 :: Int, BatchInsert), (2, 7, BatchTerminate)]
                `shouldBe` Just (BatchConsumption 2 7)
        it "accepts a termination of a holding that predates the batch" $ do
            batchConsumesCreated [(1 :: Int, 7 :: Int, BatchTerminate)]
                `shouldBe` Nothing
        it "accepts insertions and terminations on distinct keys" $ do
            batchConsumesCreated
                [(1 :: Int, 7 :: Int, BatchInsert), (2, 9, BatchTerminate)]
                `shouldBe` Nothing
        it "leaves every other same-key pair to the law" $ do
            batchConsumesCreated
                [(1 :: Int, 7 :: Int, BatchInsert), (2, 7, BatchInsert)]
                `shouldBe` Nothing
            batchConsumesCreated
                [(1 :: Int, 7 :: Int, BatchTerminate), (2, 7, BatchTerminate)]
                `shouldBe` Nothing
        it "names the first termination when several follow one insertion" $ do
            batchConsumesCreated
                [ (1 :: Int, 7 :: Int, BatchInsert)
                , (2, 7, BatchTerminate)
                , (3, 7, BatchTerminate)
                ]
                `shouldBe` Just (BatchConsumption 2 7)
        it "accepts a termination whose insertion comes later in the batch" $ do
            batchConsumesCreated
                [(1 :: Int, 7 :: Int, BatchTerminate), (2, 7, BatchInsert)]
                `shouldBe` Nothing
        it "reports the model's refusal word and source" $ do
            consumptionReason `shouldBe` "token-missing"
            consumptionSource `shouldBe` "model-refusal"
