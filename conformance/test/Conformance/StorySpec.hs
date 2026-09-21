{- |
Module      : Conformance.StorySpec
Description : Controls the theorem-clause DSL must satisfy
License     : Apache-2.0

Slice S1. Each leg executes its subject. RED-1 pins binding refusal
against the repository manifest. The clause legs pin refusal of an
empty selection and of anchors outside the named obligation, resolve
the delivery alias to its three destination conjuncts, and reconcile
every quoted anchor against the Lean source. The example legs execute
actions: a contradicting action is refused, execution itself is
observed, and a deliberately wrong expectation yields the six-field
report read from the produced failure, never written by hand.
-}
module Conformance.StorySpec (spec) where

import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import Test.Hspec (
    Spec,
    describe,
    expectationFailure,
    it,
    shouldBe,
    shouldReturn,
 )

import Conformance.EdgeFixtures (loadTwoFixtures)
import Conformance.Story (
    Clause (..),
    Example (..),
    Expectation (..),
    checkExample,
    loadManifest,
    loadStatementSource,
    mkBoundObligation,
    mkClause,
    nameViolation,
    renderBoundary,
    renderFailure,
    resolveBinding,
    resolveClause,
    unexercised,
    unexercisedChecks,
    validateExample,
    EvidenceBoundary (..),
    anchorsPresent,
    boName,
    boRevision,
 )
import Conformance.StoryBindings (
    conjunctInventory,
    insertActiveRow,
    keyedMintFold,
 )

spec :: Spec
spec = describe "theorem-clause DSL controls" $ do
    it "RED-1 refuses a binding naming no declaration and one with a moved digest" $ do
        manifestE <- loadManifest
        manifest <- case manifestE of
            Left err -> expectationFailure ("manifest unreadable: " <> err) >> pure []
            Right pairs -> pure pairs
        let absent =
                mkBoundObligation
                    "Singular.Statements.no_such_theorem"
                    "bfb4e3174839b649a883244b97053ea52985cb3eeea1d3eb4475bb273e841737"
                    "265c595"
            moved =
                mkBoundObligation
                    "Singular.Statements.insert_active_transaction_row"
                    "bfb4e3174839b649a883244b97053ea52985cb3eeea1d3eb4475bb273e841738"
                    "265c595"
        resolveBinding manifest absent `shouldBe` False
        resolveBinding manifest moved `shouldBe` False
        resolveBinding manifest insertActiveRow `shouldBe` True
        resolveBinding manifest keyedMintFold `shouldBe` True

    it "refuses a clause alias selecting no conjunct" $ do
        resolveClause conjunctInventory insertActiveRow (mkClause "empty clause selects nothing" [])
            `shouldBe` False

    it "refuses a clause alias bound to a conjunct outside its obligation" $ do
        resolveClause
            conjunctInventory
            insertActiveRow
            (mkClause "delivery is one active token" ["not a conjunct of any statement"])
            `shouldBe` False
        resolveClause
            conjunctInventory
            insertActiveRow
            (mkClause "delivery from the other theorem" ["foldBatch s [b₁, b₂] = .error \"net-mint-mismatch\""])
            `shouldBe` False

    it "resolves the delivery alias to its three destination conjuncts" $ do
        resolveClause conjunctInventory insertActiveRow deliveryClause `shouldBe` True

    it "reconciles every quoted anchor against the Lean source" $ do
        sourceE <- loadStatementSource
        source <- case sourceE of
            Left err -> expectationFailure ("source unreadable: " <> err) >> pure ""
            Right text -> pure text
        anchorsPresent source conjunctInventory `shouldBe` True
        anchorsPresent source [("mine", ["no such conjunct in any statement"])] `shouldBe` False

    it "refuses an example whose action contradicts its expectation" $ do
        validateExample
            (Example "accepts what the loader refused" (pure (Left "boom")) ExpectAccept Nothing)
            `shouldReturn` False
        validateExample
            (Example "refuses what the loader accepted" (pure (Right 1)) ExpectRefuse (Just "a reason"))
            `shouldReturn` False
        validateExample
            (Example "accepts what the loader accepted" (pure (Right 1)) ExpectAccept Nothing)
            `shouldReturn` True
        validateExample
            (Example "refuses what the loader refused" (pure (Left "boom")) ExpectRefuse (Just "a reason"))
            `shouldReturn` True

    it "executes the example's action when validating" $ do
        ref <- newIORef (0 :: Int)
        let ex =
                Example
                    "counts its own execution"
                    (writeIORef ref 1 >> pure (Right 1))
                    ExpectAccept
                    Nothing
        _ <- validateExample ex
        readIORef ref `shouldReturn` 1

    it "a deliberately wrong refusal produces the six-field report" $ do
        let wrong =
                Example
                    "two tokens delivered at the key"
                    (pure (Right 1))
                    ExpectRefuse
                    (Just "a per-kind total cannot see a quantity right in kind and wrong in count")
        result <- checkExample insertActiveRow deliveryClause ReceiptValidation wrong
        case result of
            Right _ -> expectationFailure "a wrong expectation passed"
            Left report -> do
                let rendered = renderFailure report
                all
                    (`isInfixOf` rendered)
                    [ boName insertActiveRow <> " @" <> boRevision insertActiveRow
                    , clauseAlias deliveryClause
                    , "two tokens delivered at the key"
                    , renderBoundary ReceiptValidation
                    , "the loader refuses the observation"
                    , "the loader accepted it, returning 1 receipt"
                    ]
                    `shouldBe` True

    it "a deliberately wrong acceptance produces the six-field report" $ do
        let wrong =
                Example
                    "one active token delivered"
                    (pure (Left "boom"))
                    ExpectAccept
                    Nothing
        result <- checkExample insertActiveRow deliveryClause ReceiptValidation wrong
        case result of
            Right _ -> expectationFailure "a wrong expectation passed"
            Left report -> do
                let rendered = renderFailure report
                all
                    (`isInfixOf` rendered)
                    [ boName insertActiveRow <> " @" <> boRevision insertActiveRow
                    , clauseAlias deliveryClause
                    , "one active token delivered"
                    , renderBoundary ReceiptValidation
                    , "the loader accepts the observation"
                    , "the loader refused: boom"
                    ]
                    `shouldBe` True

    it "an accepts over two loaded receipts is refused" $ do
        loadTwoFixtures `shouldReturn` Right 2
        validateExample
            (Example "accepts two receipts where one is promised" loadTwoFixtures ExpectAccept Nothing)
            `shouldReturn` False

    it "flags a name carrying a row ID or ticket number" $
        filter nameViolation ["plain condition and outcome", "row CG21 evidence", "case #194"]
            `shouldBe` ["row CG21 evidence", "case #194"]

    it "records an unexercised clause as data that contributes no check" $ do
        unexercisedChecks
            ( unexercised
                "the signature-set invariance conjunct"
                "no receipt field carries the approval's signature set"
            )
            `shouldBe` 0
  where
    deliveryClause =
        mkClause
            "the destination holds exactly one active token at the requested address"
            [ "address := some r.output"
            , "assets := [((.active, r.key), 1)]"
            , "kindCount t.state .active r.key = 1"
            ]
