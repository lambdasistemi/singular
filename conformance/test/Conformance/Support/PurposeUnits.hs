module Conformance.Support.PurposeUnits (spec) where

import Data.Map.Strict qualified as Map
import Test.Hspec (Spec, describe, it, shouldBe)

import Conformance.PurposeUnits

spec :: Spec
spec = describe "per-purpose execution-unit fixture" $ do
    it "uses the existing fallback only for failed purpose evaluations" $ do
        let measured = Map.fromList
                [("spend", Right (10, 20)), ("mint", Left "script refused"), ("other", Left "script refused")]
        allocatePurposeUnits (100, 200) (100, 200) measured `shouldBe` Right
            (Map.fromList [("spend", (20, 40)), ("mint", (1, 10)), ("other", (1, 10))])
    it "does not fabricate room when successful declarations exceed the maximum" $
        allocatePurposeUnits (10, 20) (10, 20) (Map.singleton "spend" (Right (6, 10)))
            `shouldBe` Left "harness refusal: per-purpose declarations exceed transaction/block execution-unit ceiling (mem=10, cpu=20)"
    it "keeps successful declarations distinct from a failed-purpose fallback" $ do
        let measured = Map.fromList [("spend", Right (10, 20)), ("mint", Left "script refused")]
        allocatePurposeUnits (140, 100) (62, 200) measured `shouldBe` Right
            (Map.fromList [("spend", (20, 40)), ("mint", (1, 5))])
    it "refuses successful declarations above the block ceiling before submission" $
        allocatePurposeUnits (140, 100) (62, 200) (Map.singleton "spend" (Right (32, 20)))
            `shouldBe` Left "harness refusal: per-purpose declarations exceed transaction/block execution-unit ceiling (mem=62, cpu=100)"
    it "checks the ceiling after including every failed-purpose fallback" $
        allocatePurposeUnits (140, 100) (62, 200)
            (Map.fromList [("spend", Right (30, 20)), ("fail1", Left "script refused"),
                ("fail2", Left "script refused"), ("fail3", Left "script refused")])
            `shouldBe` Left "harness refusal: per-purpose declarations exceed transaction/block execution-unit ceiling (mem=62, cpu=100)"
    it "names only the node's budget-failing purpose in a mixed failure report" $ do
        let hashes = Map.fromList [("spend", "aa"), ("mint", "bb")]
            reason = "The PlutusV3 script failed: ScriptHash \"aa\" overspending the budget The PlutusV3 script failed: ScriptHash \"bb\" script refused"
        budgetRefusalPurposes hashes reason `shouldBe` ["spend"]
        budgetRefusalPurposes hashes "The PlutusV3 script failed: ScriptHash \"aa\" script refused" `shouldBe` []
    it "prints the evaluation map and selects a fallback below its maximum" $ do
        let measured = fixtureMeasurements
            fallback = fallbackBelowMaximum measured
            declared = Map.map (const (maybe (0, 0) id fallback)) measured
            overrunNames = overBudgetPurposes measured declared
            doubled = doublePurposeUnits measured
        putStrLn ("fixture purpose evaluation map: " <> show measured)
        putStrLn ("fixture componentwise maximum: " <> show (maximumPurposeUnits measured))
        putStrLn ("fixture selected test-build fallback: " <> show fallback)
        putStrLn ("fixture purposes above fallback: " <> show overrunNames)
        maximumPurposeUnits measured `shouldBe` Just (1_100_000, 435_000_000)
        fallback `shouldBe` Just (1_099_999, 434_999_999)
        overrunNames `shouldBe` ["ConwaySpending (AsIx 0)"]
        missingPurposeBudgets measured declared `shouldBe` []
        doubled `shouldBe`
            Map.fromList
                [ ("ConwayMinting (AsIx 0)", (180_000, 14_000_000))
                , ("ConwaySpending (AsIx 0)", (2_200_000, 870_000_000))
                , ("ConwaySpending (AsIx 1)", (240_000, 36_000_000))
                ]

fixtureMeasurements :: PurposeUnits
fixtureMeasurements =
    Map.fromList
        [ ("ConwaySpending (AsIx 0)", (1_100_000, 435_000_000))
        , ("ConwaySpending (AsIx 1)", (120_000, 18_000_000))
        , ("ConwayMinting (AsIx 0)", (90_000, 7_000_000))
        ]
