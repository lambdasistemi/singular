{- |
Module      : Conformance.Support.Rows
Description : Inventory loading and denominator enforcement tests
License     : Apache-2.0
-}
module Conformance.Support.Rows (spec) where

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
    expectedRowCount,
    loadRows,
    ownedDenominator,
    rowId,
    rowState,
    validateInventory,
 )
import Paths_conformance (getDataFileName)

spec :: Spec
spec = describe "Appendix: keeping the published requirements complete" $ do
    it "Includes every expected requirement once and counts the requirements owned by the registry" $ do
        rows <- loadCommitted
        -- Both sides are read, never written twice: `rows` is the
        -- committed artifact, `expectedRowCount` the pinned count.
        -- Adding a row therefore moves ONE literal, in Rows.hs.
        length rows `shouldBe` expectedRowCount
        length (nub (map rowId rows)) `shouldBe` expectedRowCount
        length
            (filter ((/= OutOfScope) . rowState) rows)
            `shouldBe` ownedDenominator

    it "Identifies checkpoint policy as outside the registry's responsibilities" $ do
        rows <- loadCommitted
        case filter ((== "CK06") . rowId) rows of
            [ck06] -> rowState ck06 `shouldBe` OutOfScope
            _ -> expectationFailure "inventory has no single checkpoint-policy requirement"

    it "Does not store claims of completed tests in the requirements file" $ do
        rows <- loadCommitted
        filter (isExecutedPlan . rowState) rows `shouldBe` []

    it "Rejects an empty list of requirements" $
        validateInventory [] `shouldSatisfy` isLeft

    it "Rejects a missing requirement and reports the remaining count" $ do
        rows <- loadCommitted
        case validateInventory (drop 1 rows) of
            Left err ->
                err `shouldSatisfy` (show (expectedRowCount - 1) `isInfixOf`)
            Right _ ->
                expectationFailure
                    ("a " <> show (expectedRowCount - 1) <> "-row inventory validated")

    it "Rejects two requirements with the same identifier" $ do
        rows <- loadCommitted
        case rows of
            [] -> expectationFailure "committed inventory is empty"
            r : _ ->
                validateInventory (r : rows)
                    `shouldSatisfy` isLeft

    it "Rejects an unrecognised requirement status" $
        (eitherDecode badStateRow :: Either String Row)
            `shouldSatisfy` isLeft

    it "Rejects a completed-test claim typed directly into the requirements file" $
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
