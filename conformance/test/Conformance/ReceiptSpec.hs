{- |
Module      : Conformance.ReceiptSpec
Description : Receipt loading, validation and overlay tests
License     : Apache-2.0

A row prints as executed only when a receipt for it exists and
matches the base. The fixture receipts carry base @fixture-base@;
@other-base@ is the stale-receipt case.
-}
module Conformance.ReceiptSpec (spec) where

import Data.Either (isLeft, isRight)
import Data.List (isInfixOf)
import Test.Hspec (
    Spec,
    describe,
    it,
    shouldBe,
    shouldSatisfy,
 )

import Conformance.Receipt (loadReceipts)
import Conformance.Rows (
    Row (..),
    RowState (..),
    ShownState (..),
    effectiveState,
    loadRows,
    rowId,
 )
import Paths_conformance (getDataFileName)

spec :: Spec
spec = describe "Receipt" $ do
    it "loads the fixture receipts" $ do
        dir <- getDataFileName "test/fixtures/receipts"
        result <- loadReceipts dir
        result `shouldSatisfy` isRight
        case result of
            Right rs -> length rs `shouldBe` 2
            Left err -> fail err

    it "shows executed only with a base-matching receipt" $ do
        dir <- getDataFileName "test/fixtures/receipts"
        result <- loadReceipts dir
        case result of
            Left err -> fail err
            Right rs -> do
                rows <- loadCommitted
                case filter ((== "CG02") . rowId) rows of
                    [cg02] -> do
                        effectiveState "fixture-base" rs cg02
                            `shouldBe` ShownExecuted
                        effectiveState "other-base" rs cg02
                            `shouldBe` ShownPlanned Uncovered
                        effectiveState "fixture-base" [] cg02
                            `shouldBe` ShownPlanned Uncovered
                    _ ->
                        fail "fixture inventory has no single CG02"

    it "shows the refused fixture row executed with its receipt" $ do
        dir <- getDataFileName "test/fixtures/receipts"
        result <- loadReceipts dir
        case result of
            Left err -> fail err
            Right rs -> do
                rows <- loadCommitted
                case filter ((== "CG05") . rowId) rows of
                    [cg05] ->
                        effectiveState "fixture-base" rs cg05
                            `shouldBe` ShownExecuted
                    _ ->
                        fail "fixture inventory has no single CG05"

    it "rejects an accepted receipt with no transactions" $ do
        dir <- getDataFileName "test/fixtures/bad-accepted"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft

    it "rejects a refused receipt with no attribution" $ do
        dir <- getDataFileName "test/fixtures/bad-refused"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft

    it "rejects two receipts for one row" $ do
        dir <- getDataFileName "test/fixtures/duplicate"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft

    it "rejects a malformed receipt naming the file" $ do
        dir <- getDataFileName "test/fixtures/malformed"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err ->
                err `shouldSatisfy` ("receipt-CG02.json" `isInfixOf`)
            Right _ -> fail "a malformed receipt loaded"

loadCommitted :: IO [Row]
loadCommitted = do
    path <- getDataFileName "rows.json"
    result <- loadRows path
    case result of
        Left err -> fail err
        Right rows -> pure rows
