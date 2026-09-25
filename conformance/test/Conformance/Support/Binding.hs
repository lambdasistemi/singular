{-# LANGUAGE OverloadedStrings #-}

-- | Check that appendix examples name the Lean statements they exercise.
module Conformance.Support.Binding (spec) where

import Conformance.Fold.KeyedMint (keyedMintFold)
import Conformance.Fold.KeyedMint qualified as KeyedMint
import Conformance.Lean.Registration qualified as Registration
import Conformance.Story.Binding (
    Binding,
    BoundObligation (..),
    anchorsPresent,
    loadManifest,
    loadStatementSource,
    nameViolation,
    resolveBinding,
    resolveClause,
 )
import Conformance.Story.Specification (theoremBinding)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)

spec :: Spec
spec = describe "Appendix: binding examples to their specification" $ do
    it "Rejects a test linked to a missing or changed specification" $ do
        manifestE <- loadManifest
        manifest <- either (\err -> expectationFailure err >> pure []) pure manifestE
        let absent = insertActiveRow{boName = "Singular.Statements.no_such_theorem"}
            changed = insertActiveRow{boDigest = "changed"}
        resolveBinding manifest absent `shouldBe` False
        resolveBinding manifest changed `shouldBe` False
        resolveBinding manifest insertActiveRow `shouldBe` True
        resolveBinding manifest keyedMintFold `shouldBe` True
    it "Rejects a test that does not identify the promise it checks" $ do
        requireBound
        resolveClause conjunctInventory insertActiveRow [] `shouldBe` False
    it "Rejects a test whose claimed promise is absent from its specification" $ do
        requireBound
        resolveClause conjunctInventory insertActiveRow ["not a conjunct"] `shouldBe` False
        resolveClause
            conjunctInventory
            insertActiveRow
            ["foldBatch s [b₁, b₂] = .error \"net-mint-mismatch\""]
            `shouldBe` False
    it "Links the token delivery checks to the specified address, token and quantity" $
        resolveClause
            conjunctInventory
            insertActiveRow
            [ "address := some r.output"
            , "assets := [((.active, r.key), 1)]"
            , "kindCount t.state .active r.key = 1"
            ]
            `shouldBe` True
    it "Checks that every quoted rule actually appears in the formal specification" $ do
        sourceE <- loadStatementSource
        source <- either (\err -> expectationFailure err >> pure "") pure sourceE
        anchorsPresent source conjunctInventory `shouldBe` True
        anchorsPresent source [("missing", ["no such conjunct in any statement"])] `shouldBe` False
    it "Detects test titles that use internal reference numbers" $ do
        nameViolation "plain condition and outcome" `shouldBe` False
        nameViolation ("row CG" <> show (21 :: Int) <> " evidence") `shouldBe` True
        nameViolation "case #194" `shouldBe` True

insertActiveRow :: Binding
insertActiveRow = theoremBinding Registration.insertActiveRow

requireBound :: IO ()
requireBound = do
    manifestE <- loadManifest
    manifest <- either (\err -> expectationFailure err >> pure []) pure manifestE
    resolveBinding manifest insertActiveRow `shouldBe` True

conjunctInventory :: [(String, [String])]
conjunctInventory =
    [ (boName insertActiveRow, insertActiveConjuncts)
    , (boName keyedMintFold, KeyedMint.conjuncts)
    ]

insertActiveConjuncts :: [String]
insertActiveConjuncts =
    [ "address := some r.output"
    , "assets := [((.active, r.key), 1)]"
    , "kindCount t.state .active r.key = 1"
    , "mint := [((.active, r.key), 1)]"
    , "openPolicyParameters = []"
    , "lovelace := r.deposit"
    , "refunds := [(r.output, r.deposit)]"
    , "signers := []"
    , "lovelaceCoversTip s.config lovelace = true"
    , "destinationDatumBinds r = true"
    , "onlyRootChanged s.config t.state.config = true"
    , "txOf t.state r₂ lovelace = .error \"key-exists\""
    ]
