{-# LANGUAGE OverloadedStrings #-}

-- | Appendix: statement binding and the interpreter's verdicts.
module Conformance.Story.BindingControl (spec) where

import Data.Either (isLeft, isRight)
import Data.List (isInfixOf)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldReturn, shouldSatisfy)
import Conformance.Fixture.ActiveRegistration (keyHex, loadTwoFixtures)
import Conformance.Edge.Register qualified as InsertActive
import Conformance.Fold.KeyedMint qualified as KeyedMint
import Conformance.Story
import Conformance.Edge.Register (insertActiveRow)
import Conformance.Fold.KeyedMint (keyedMintFold)

spec :: Spec
spec = describe "Statement bindings and story verdicts" $ do
    it "refuses a missing declaration and a changed statement digest" $ do
        manifestE <- loadManifest
        manifest <- either (\err -> expectationFailure err >> pure []) pure manifestE
        let absent = insertActiveRow {boName = "Singular.Statements.no_such_theorem"}
            moved = insertActiveRow {boDigest = "changed"}
        resolveBinding manifest absent `shouldBe` False
        resolveBinding manifest moved `shouldBe` False
        resolveBinding manifest insertActiveRow `shouldBe` True
        resolveBinding manifest keyedMintFold `shouldBe` True
    it "refuses a clause selecting no conjunct" $
        resolveClause conjunctInventory insertActiveRow [] `shouldBe` False
    it "refuses a conjunct outside its obligation" $ do
        resolveClause conjunctInventory insertActiveRow ["not a conjunct"] `shouldBe` False
        resolveClause conjunctInventory insertActiveRow ["foldBatch s [b₁, b₂] = .error \"net-mint-mismatch\""] `shouldBe` False
    it "resolves delivery to its destination conjuncts" $
        resolveClause conjunctInventory insertActiveRow
            [ "address := some r.output", "assets := [((.active, r.key), 1)]", "kindCount t.state .active r.key = 1"] `shouldBe` True
    it "reconciles every quoted anchor against Lean" $ do
        sourceE <- loadStatementSource
        source <- either (\err -> expectationFailure err >> pure "") pure sourceE
        anchorsPresent source conjunctInventory `shouldBe` True
        anchorsPresent source [("mine", ["no such conjunct in any statement"])] `shouldBe` False
    it "refuses cases whose executed outcome contradicts their expectation" $ do
        check (accepts "one token" twoTokens) >>= (`shouldSatisfy` isLeft)
        check (rejects "two tokens" "a reason" unchanged) >>= (`shouldSatisfy` isLeft)
        check (accepts "one token" unchanged) >>= (`shouldSatisfy` isRight)
        check (rejects "two tokens" "a reason" twoTokens) >>= (`shouldSatisfy` isRight)
    it "executes the declared edit through the real loader" $ do
        executeEdit unchanged `shouldReturn` Right 1
        executeEdit twoTokens >>= (`shouldSatisfy` isLeft)
    it "a wrong refusal reports the observed acceptance and executed edit" $ do
        result <- check (rejects "one token" "deliberately wrong refusal" unchanged)
        case result of
            Right () -> expectationFailure "wrong refusal passed"
            Left report -> do
                frActual report `shouldBe` "the loader accepted it, returning 1 receipt"
                checkReport report "one token" "the loader refuses the observation"
    it "a wrong acceptance reports the actual loader refusal and executed edit" $ do
        result <- check (accepts "two tokens" twoTokens)
        case result of
            Right () -> expectationFailure "wrong acceptance passed"
            Left report -> do
                frActual report `shouldSatisfy` isInfixOf "the loader refused:"
                frEdit report `shouldBe` renderEdit twoTokens
                checkReport report "two tokens" "the loader accepts the observation"
    it "two receipts satisfy neither one-receipt acceptance nor refusal" $ do
        loadTwoFixtures `shouldReturn` Right 2
        outcomeMatches True (Right 2) `shouldBe` False
        outcomeMatches False (Right 2) `shouldBe` False
    it "flags row identifiers and ticket numbers in names" $ do
        nameViolation "plain condition and outcome" `shouldBe` False
        nameViolation ("row CG" <> show (21 :: Int) <> " evidence") `shouldBe` True
        nameViolation "case #194" `shouldBe` True
    it "records unexercised clauses without contributing a check" $
        unexercisedChecks (UnexercisedClause "signature-set invariance" "no observed signature set") `shouldBe` 0
    it "keeps every product clause and case free of row identifiers" $
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
