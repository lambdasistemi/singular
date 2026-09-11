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

    it "rejects a phase-1 refusal without PlutusFailure" $
        matchRefusal "abcdef01" "BadInputs: inputs are spent"
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
