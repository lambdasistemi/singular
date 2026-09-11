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
    validateInventory,
 )
import Paths_conformance (getDataFileName)

spec :: Spec
spec = describe "Rows" $ do
    it "loads the committed inventory: 40 rows, unique ids" $ do
        rows <- loadCommitted
        length rows `shouldBe` 40
        nub (map rowId rows) `shouldBe` map rowId rows

    it "executes exactly CG02 CG03 CG04 CG05 and CL01" $ do
        rows <- loadCommitted
        [rowId r | r <- rows, rowState r == Executed]
            `shouldBe` ["CG02", "CG03", "CG04", "CG05", "CL01"]

    it "rejects an empty inventory" $
        validateInventory [] `shouldSatisfy` isLeft

    it "rejects a shortened inventory naming the count" $ do
        rows <- loadCommitted
        case validateInventory (drop 1 rows) of
            Left err ->
                err `shouldSatisfy` ("39" `isInfixOf`)
            Right _ ->
                expectationFailure "a 39-row inventory validated"

    it "rejects duplicate row ids" $ do
        rows <- loadCommitted
        case rows of
            [] -> expectationFailure "committed inventory is empty"
            r : _ ->
                validateInventory (r : rows)
                    `shouldSatisfy` isLeft

    it "rejects an unknown row state" $
        ( eitherDecode badStateRow :: Either String Row
        )
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
