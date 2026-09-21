{-# LANGUAGE OverloadedStrings #-}

-- | Appendix: statement binding and the interpreter's verdicts.
module Conformance.Story.BindingControl (spec) where

import Data.Either (isLeft, isRight)
import Data.List (isInfixOf)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldReturn, shouldSatisfy)
import Conformance.Fixture.ActiveRegistration (keyHex, loadTwoFixtures)
import Conformance.Support.RegistrationReport qualified as InsertActive
import Conformance.Support.BatchReport qualified as KeyedMint
import Conformance.Story
import Conformance.Support.RegistrationReport (insertActiveRow)
import Conformance.Fold.KeyedMint (keyedMintFold)

spec :: Spec
spec = describe "Appendix: keeping tests honest about what they demonstrate" $ do
    it "Rejects a test linked to a missing or changed specification" $ do
        manifestE <- loadManifest
        manifest <- either (\err -> expectationFailure err >> pure []) pure manifestE
        let absent = insertActiveRow {boName = "Singular.Statements.no_such_theorem"}
            moved = insertActiveRow {boDigest = "changed"}
        resolveBinding manifest absent `shouldBe` False
        resolveBinding manifest moved `shouldBe` False
        resolveBinding manifest insertActiveRow `shouldBe` True
        resolveBinding manifest keyedMintFold `shouldBe` True
    it "Rejects a test that does not identify the promise it checks" $
        resolveClause conjunctInventory insertActiveRow [] `shouldBe` False
    it "Rejects a test whose claimed promise is absent from its specification" $ do
        resolveClause conjunctInventory insertActiveRow ["not a conjunct"] `shouldBe` False
        resolveClause conjunctInventory insertActiveRow ["foldBatch s [b₁, b₂] = .error \"net-mint-mismatch\""] `shouldBe` False
    it "Links the token delivery checks to the specified address, token and quantity" $
        resolveClause conjunctInventory insertActiveRow
            [ "address := some r.output", "assets := [((.active, r.key), 1)]", "kindCount t.state .active r.key = 1"] `shouldBe` True
    it "Checks that every quoted rule actually appears in the formal specification" $ do
        sourceE <- loadStatementSource
        source <- either (\err -> expectationFailure err >> pure "") pure sourceE
        anchorsPresent source conjunctInventory `shouldBe` True
        anchorsPresent source [("mine", ["no such conjunct in any statement"])] `shouldBe` False
    it "Fails a test when the report is accepted but rejection was expected, or the reverse" $ do
        check (accepts "one token" twoTokens) >>= (`shouldSatisfy` isLeft)
        check (rejects "two tokens" "a reason" unchanged) >>= (`shouldSatisfy` isLeft)
        check (accepts "one token" unchanged) >>= (`shouldSatisfy` isRight)
        check (rejects "two tokens" "a reason" twoTokens) >>= (`shouldSatisfy` isRight)
    it "Checks the supplied report: one delivered token is accepted and two are rejected" $ do
        executeEdit unchanged `shouldReturn` Right 1
        executeEdit twoTokens >>= (`shouldSatisfy` isLeft)
    it "Explains a failed test by showing the report that was unexpectedly accepted" $ do
        result <- check (rejects "one token" "deliberately wrong refusal" unchanged)
        case result of
            Right () -> expectationFailure "wrong refusal passed"
            Left report -> do
                frActual report `shouldBe` "the loader accepted it, returning 1 receipt"
                checkReport report "one token" "the loader refuses the observation"
    it "Explains a failed test by showing why the report was unexpectedly rejected" $ do
        result <- check (accepts "two tokens" twoTokens)
        case result of
            Right () -> expectationFailure "wrong acceptance passed"
            Left report -> do
                frActual report `shouldSatisfy` isInfixOf "the loader refused:"
                frEdit report `shouldBe` renderEdit twoTokens
                checkReport report "two tokens" "the loader accepts the observation"
    it "Does not treat two reports as the expected single report or as a rejection" $ do
        loadTwoFixtures `shouldReturn` Right 2
        outcomeMatches True (Right 2) `shouldBe` False
        outcomeMatches False (Right 2) `shouldBe` False
    it "Detects test titles that use internal reference numbers" $ do
        nameViolation "plain condition and outcome" `shouldBe` False
        nameViolation ("row CG" <> show (21 :: Int) <> " evidence") `shouldBe` True
        nameViolation "case #194" `shouldBe` True
    it "Does not count an untested promise as a completed test" $
        unexercisedChecks (UnexercisedClause "signature-set invariance" "no observed signature set") `shouldBe` 0
    it "Keeps internal reference numbers out of the product stories" $
        filter nameViolation (groupNames InsertActive.story <> groupNames KeyedMint.story) `shouldBe` []
  where
    twoTokens = deliver $ activeToken keyHex 2
    check = checkCase insertActiveRow "the destination holds exactly one active token" ReceiptValidation
    checkReport report example expected = do
        frTheorem report `shouldBe` boName insertActiveRow <> " @" <> boRevision insertActiveRow
        frClause report `shouldBe` "the destination holds exactly one active token"
        frExample report `shouldBe` example
        frBoundary report `shouldBe` renderBoundary ReceiptValidation
        frExpected report `shouldBe` expected
        renderFailure report `shouldSatisfy` isInfixOf (frActual report)

-- The existing two-constant check; this is not a binding-population census.
conjunctInventory :: [(String, [String])]
conjunctInventory =
    [(boName insertActiveRow, InsertActive.conjuncts), (boName keyedMintFold, KeyedMint.conjuncts)]
