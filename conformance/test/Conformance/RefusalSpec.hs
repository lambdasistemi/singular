{- |
Module      : Conformance.RefusalSpec
Description : Refusal matcher acceptance and rejection tests
License     : Apache-2.0

The samples below are shaped like the node refusal text the
li-refusals runner matches (phase-2 @PlutusFailure@ naming the
script hash hex). The first real devnet run pins the observed text
as a regression sample here; until then these prove the matcher can
both accept and refuse.
-}
module Conformance.RefusalSpec (spec) where

import Data.Either (isLeft)
import Data.List (isInfixOf, isPrefixOf)
import Test.Hspec (
    Spec,
    describe,
    it,
    shouldBe,
    shouldSatisfy,
 )

import Conformance.Refusal (
    RefusalMismatch (..),
    matchRefusal,
    trimRefusal,
    wrongReasonMarker,
 )

spec :: Spec
spec = describe "Refusal" $ do
    it "accepts a phase-2 failure naming the script" $
        matchRefusal
            "abcdef01"
            "phase-2 PlutusFailure naming 0xabcdef01: \
            \script evaluation failed"
            `shouldBe` Right ()

    it "accepts a build-evaluation failure naming the script" $
        matchRefusal "874e476d" evalFailureSample `shouldBe` Right ()

    it "rejects a phase-1 refusal without PlutusFailure" $
        matchRefusal "abcdef01" "BadInputs: inputs are spent"
            `shouldSatisfy` isLeft

    it "rejects marker-only text with no phase-2 vocabulary" $
        matchRefusal
            "abcdef01"
            "BadInputs 0xabcdef01: inputs are spent"
            `shouldSatisfy` isLeft

    it "rejects a phase-2 failure naming another script" $
        matchRefusal
            "abcdef01"
            "phase-2 PlutusFailure naming 0x99999999: \
            \script evaluation failed"
            `shouldBe` Left
                ( MarkerAbsent
                    "abcdef01"
                    "phase-2 PlutusFailure naming 0x99999999: \
                    \script evaluation failed"
                )

    it "never matches the wrong-reason control marker" $
        matchRefusal
            wrongReasonMarker
            "phase-2 PlutusFailure naming 0xabcdef01: \
            \script evaluation failed"
            `shouldSatisfy` isLeft

    it "trims the script binary out of an eval refusal" $
        let trimmed = trimRefusal evalShapedRefusal
         in do
                trimmed `shouldSatisfy` ("scriptHash=874e476d" `isInfixOf`)
                trimmed `shouldSatisfy` ("cek=" `isInfixOf`)
                trimmed `shouldSatisfy` (not . ("plutusBinary" `isInfixOf`))
                trimmed `shouldSatisfy` (not . ("pwcCostModel" `isInfixOf`))
                length trimmed `shouldSatisfy` (< 2000)

    it "marks an unknown refusal shape unparsed" $
        trimRefusal "something entirely new"
            `shouldBe` "something entirely new [unparsed]"

    it "keeps every failed script hash when two scripts fail" $
        let two = nodeShapedRefusal <> " second: " <> secondHashRefusal
            trimmed = trimRefusal two
         in do
                -- Joined in ledger order as one field: a trimmer keeping
                -- only the first hash cannot satisfy this.
                trimmed `shouldSatisfy` ("scriptHash=874e476d,28726576" `isInfixOf`)
                length trimmed `shouldSatisfy` (< 2000)

    it "trims the node-submit shape to its attribution" $
        let trimmed = trimRefusal nodeShapedRefusal
         in do
                trimmed `shouldSatisfy` ("scriptHash=874e476d" `isInfixOf`)
                trimmed `shouldSatisfy` ("cek=" `isInfixOf`)
                trimmed `shouldSatisfy` ("PlutusV3 script failed" `isInfixOf`)
                trimmed `shouldSatisfy` (not . ("AAAABBBB" `isInfixOf`))
                trimmed `shouldSatisfy` (not . ("Base64-encoded" `isInfixOf`))
                length trimmed `shouldSatisfy` (< 500)

evalFailureSample :: String
evalFailureSample = "updateToken: build failed: EvalFailure (ConwaySpending (AsIx 2)) ValidationFailure (CekError script error) (PlutusWithContext {pwcScriptHash = ScriptHash 874e476d})"

evalShapedRefusal :: String
evalShapedRefusal = "updateToken: build failed: EvalFailure (ConwaySpending (AsIx 2)) \\\"ValidationFailure (CekError script error) [] (PlutusWithContext {pwcScript = Left (Plutus {plutusBinary = \\\"AAAABBBB\\\"}), pwcScriptHash = ScriptHash \\\"874e476d\\\", pwcExUnits = X, pwcCostModel = CostModel PlutusV3 [1, 2, 3]})\\\""

-- | The node shape with a different failing script: a tampered fold can
-- fail two scripts in one submission, and the failure-list order varies
-- run to run, so attribution must keep every hash it names.
secondHashRefusal :: String
secondHashRefusal = replaceAll "874e476d" "28726576" nodeShapedRefusal
  where
    replaceAll _ _ [] = []
    replaceAll from to s@(c : cs)
        | from `isPrefixOf` s = to <> replaceAll from to (drop (length from) s)
        | otherwise = c : replaceAll from to cs

nodeShapedRefusal :: String
nodeShapedRefusal = "HardForkApplyTxErrFromEra (ConwayUtxowFailure (FailedUnexpectedly (PlutusFailure \"The PlutusV3 script failed: Base64-encoded script bytes: \\\"AAAABBBB\\\", ScriptHash \\\"874e476d\\\", The plutus evaluation error is: CekError script error. Caused by: error. The protocol version is: Version 10, ScriptInfo: more\")))"
