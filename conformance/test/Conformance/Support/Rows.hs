{-# LANGUAGE LambdaCase #-}

{- |
Module      : Conformance.Support.Rows
Description : Inventory loading and denominator enforcement tests
License     : Apache-2.0
-}
module Conformance.Support.Rows (spec) where

import Control.Monad (forM_)
import Data.Aeson (eitherDecode)
import Data.ByteString.Lazy qualified as BSL
import Data.Either (isLeft)
import Data.List (isInfixOf, nub, sort)
import Data.Text qualified as T
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )

import Conformance.RowNames (canonicalRowName, historicalRowNames)
import Conformance.Rows
    ( Row (..)
    , RowState (..)
    , ShownState (..)
    , effectiveState
    , expectedRowCount
    , loadRows
    , ownedDenominator
    , renderInventory
    , rowId
    , rowState
    , validateInventory
    )
import Paths_conformance (getDataFileName)

spec :: Spec
spec = describe "Appendix: keeping the published requirements complete" $ do
    it
        "Associates every historical receipt key with exactly one current requirement"
        $ do
            rows <- loadCommitted
            let current = map rowId rows
            -- New requirements need no fabricated historical receipt key.
            length historicalRowNames `shouldBe` 46
            length (nub (map snd historicalRowNames)) `shouldBe` 46
            map snd historicalRowNames `shouldSatisfy` all (`elem` current)
            map (canonicalRowName . fst) historicalRowNames
                `shouldBe` map snd historicalRowNames
            map canonicalRowName current `shouldBe` current
            canonicalRowName "unknown-requirement"
                `shouldBe` "unknown-requirement"

    it
        "Includes every expected requirement once and counts the requirements owned by the registry"
        $ do
            rows <- loadCommitted
            -- Both sides are read, never written twice: `rows` is the
            -- committed artifact, `expectedRowCount` the pinned count.
            -- Adding a row therefore moves ONE literal, in Rows.hs.
            length rows `shouldBe` expectedRowCount
            length (nub (map rowId rows)) `shouldBe` expectedRowCount
            length
                (filter ((/= OutOfScope) . rowState) rows)
                `shouldBe` ownedDenominator

    it
        "Identifies checkpoint policy as outside the registry's responsibilities"
        $ do
            rows <- loadCommitted
            case filter ((== "checkpoint-and-treasury-policy") . rowId) rows of
                [ck06] -> rowState ck06 `shouldBe` OutOfScope
                _ ->
                    expectationFailure
                        "inventory has no single checkpoint-policy requirement"

    it
        "Keeps the reject and retract exit controls a requirement of their own, apart from the retirement"
        $ do
            rows <- loadCommitted
            case filter ((== "reject-and-retract-refund-controls") . rowId) rows of
                [exits] -> do
                    rowGroup exits `shouldBe` "registry-operations"
                    rowRequirement exits
                        `shouldSatisfy` (\text -> all (`T.isInfixOf` text) ["reject", "retract"])
                _ ->
                    expectationFailure "inventory has no single exit-controls requirement"

    it "Does not store claims of completed tests in the requirements file" $ do
        rows <- loadCommitted
        filter (isExecutedPlan . rowState) rows `shouldBe` []

    it
        "Publishes update and termination comparisons as uncovered statements with their evidence boundary"
        $ do
            rows <- loadCommitted
            let journeys = filter ((== "holding-journeys") . rowGroup) rows
                rendered = renderInventory "current-base" [] rows
            sort (map rowId journeys)
                `shouldBe` [ "holding-update-outcome"
                           , "termination-booking-outcome"
                           , "termination-fold-outcome"
                           ]
            forM_ journeys $ \row -> do
                effectiveState "current-base" [] row `shouldBe` ShownPlanned Uncovered
                rowRequirement row `shouldSatisfy` T.isInfixOf "previous design"
                rowSource row `shouldSatisfy` \text ->
                    all
                        (`T.isInfixOf` text)
                        [ "OpenDatumApplicationHeld.Money.oldAllocation"
                        , "OpenDatumApplicationHeld.Money.newAllocation"
                        ]
                rowExpected row
                    `shouldSatisfy` T.isInfixOf
                        "no executable comparison with the application-held model exists yet"
                rowEvidence row `shouldSatisfy` \case
                    Nothing -> False
                    Just text ->
                        all
                            (`T.isInfixOf` text)
                            [ "no-pin-registration-journey"
                            , "no-pin-termination-refusals"
                            , "nothing about agreement with the model"
                            ]
                rendered `shouldSatisfy` T.isInfixOf (rowRequirement row)

    it
        "States the treasury timing and the folder's whole request value in the termination comparisons"
        $ do
            rows <- loadCommitted
            let statement name = T.unwords [rowRequirement row | row <- rows, rowId row == name]
            statement "termination-booking-outcome" `shouldSatisfy` \text ->
                all
                    (`T.isInfixOf` text)
                    ["deposit", "treasury", "booking", "previous design"]
            statement "termination-fold-outcome" `shouldSatisfy` \text ->
                all
                    (`T.isInfixOf` text)
                    ["whole value", "folder", "tip", "treasury", "previous design"]

    it "Rejects an empty list of requirements" $
        validateInventory [] `shouldSatisfy` isLeft

    it
        "Publishes reading requirements without crediting separate development-network evidence" $ do
        rows <- loadCommitted
        let reading = filter ((== "registry-reading") . rowGroup) rows
            rendered = renderInventory "current-base" [] rows
        sort (map rowId reading)
            `shouldBe` [ "reading-application-holding"
                       , "reading-key-status"
                       , "reading-query-work"
                       , "reading-refusals"
                       ]
        forM_ reading $ \row -> do
            effectiveState "current-base" [] row `shouldBe` ShownPlanned Uncovered
            rowExpected row `shouldSatisfy` T.isInfixOf "no executable comparison"
            rowEvidence row `shouldSatisfy` \case
                Nothing -> False
                Just text ->
                    all
                        (`T.isInfixOf` text)
                        ["no-pin-registration", "nothing about agreement with the model"]
            rendered `shouldSatisfy` T.isInfixOf (rowRequirement row)

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

    it
        "Rejects a completed-test claim typed directly into the requirements file"
        $ (eitherDecode executedStateRow :: Either String Row)
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
    "{\"id\":\"CX01\",\"group\":\"registry-operations\","
        <> "\"requirement\":\"r\",\"source\":\"s\","
        <> "\"expected\":\"accept\",\"state\":\"flying\"}"

executedStateRow :: BSL.ByteString
executedStateRow =
    "{\"id\":\"CX01\",\"group\":\"registry-operations\","
        <> "\"requirement\":\"r\",\"source\":\"s\","
        <> "\"expected\":\"accept\",\"state\":\"executed\"}"

-- There is no Executed plan state; this guard fails the suite if
-- one is ever reintroduced. Unreachable while the type holds,
-- which is the point.
isExecutedPlan :: RowState -> Bool
isExecutedPlan Uncovered = False
isExecutedPlan BoundElsewhere = False
isExecutedPlan OutOfScope = False
