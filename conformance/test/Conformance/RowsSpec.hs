{- |
Module      : Conformance.RowsSpec
Description : Inventory loading and denominator enforcement tests
License     : Apache-2.0
-}
module Conformance.RowsSpec (spec) where

import Data.Aeson (eitherDecode)
import Data.ByteString.Lazy qualified as BSL
import Data.Either (isLeft)
import Data.List (isInfixOf, nub)
import Test.Hspec (
    Spec,
    describe,
    expectationFailure,
    it,
    shouldBe,
    shouldSatisfy,
 )

import Conformance.Rows (
    Row (..),
    RowState (..),
    loadRows,
    ownedDenominator,
    rowId,
    rowState,
    validateInventory,
 )
import Paths_conformance (getDataFileName)

spec :: Spec
spec = describe "Rows" $ do
    it "loads the committed inventory: 41 rows, 40 owned, unique ids" $ do
        rows <- loadCommitted
        length rows `shouldBe` 41
        length (nub (map rowId rows)) `shouldBe` 41
        length
            (filter ((/= OutOfScope) . rowState) rows)
            `shouldBe` ownedDenominator

    it "records CK06 out of scope under cardano-keri" $ do
        rows <- loadCommitted
        case filter ((== "CK06") . rowId) rows of
            [ck06] -> rowState ck06 `shouldBe` OutOfScope
            _ -> expectationFailure "inventory has no single CK06"

    it "carries no executed rows in the committed file" $ do
        rows <- loadCommitted
        filter (isExecutedPlan . rowState) rows `shouldBe` []

    it "rejects an empty inventory" $
        validateInventory [] `shouldSatisfy` isLeft

    it "rejects a shortened inventory naming the count" $ do
        rows <- loadCommitted
        case validateInventory (drop 1 rows) of
            Left err ->
                err `shouldSatisfy` ("40" `isInfixOf`)
            Right _ ->
                expectationFailure "a 40-row inventory validated"

    it "rejects duplicate row ids" $ do
        rows <- loadCommitted
        case rows of
            [] -> expectationFailure "committed inventory is empty"
            r : _ ->
                validateInventory (r : rows)
                    `shouldSatisfy` isLeft

    it "rejects an unknown row state" $
        (eitherDecode badStateRow :: Either String Row)
            `shouldSatisfy` isLeft

    it "rejects the executed state in rows.json" $
        (eitherDecode executedStateRow :: Either String Row)
            `shouldSatisfy` isLeft

loadCommitted :: IO [Row]
loadCommitted = do
    path <- getDataFileName "rows.json"
    result <- loadRows path
    case result of
        Left err -> expectationFailure err >> pure []
        Right rows -> pure rows

badStateRow :: BSL.ByteString
badStateRow =
    "{\"id\":\"CX01\",\"group\":\"CG\","
        <> "\"requirement\":\"r\",\"source\":\"s\","
        <> "\"expected\":\"accept\",\"state\":\"flying\"}"

executedStateRow :: BSL.ByteString
executedStateRow =
    "{\"id\":\"CX01\",\"group\":\"CG\","
        <> "\"requirement\":\"r\",\"source\":\"s\","
        <> "\"expected\":\"accept\",\"state\":\"executed\"}"

-- There is no Executed plan state; this guard fails the suite if
-- one is ever reintroduced. Unreachable while the type holds,
-- which is the point.
isExecutedPlan :: RowState -> Bool
isExecutedPlan Uncovered = False
isExecutedPlan BoundElsewhere = False
isExecutedPlan OutOfScope = False
