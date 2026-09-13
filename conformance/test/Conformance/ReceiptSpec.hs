{- |
Module      : Conformance.ReceiptSpec
Description : Receipt loading, validation and overlay tests
License     : Apache-2.0

A row prints as executed only when a receipt for it exists and
matches the base. The fixture receipts carry base @fixture-base@;
@other-base@ is the stale-receipt case.
-}
module Conformance.ReceiptSpec (spec) where

import Data.Aeson (eitherDecode, encode)
import Data.Either (isLeft, isRight)
import Data.Foldable (forM_)
import Data.List (isInfixOf)
import Data.Text qualified as T
import Test.Hspec (
    Spec,
    describe,
    it,
    shouldBe,
    shouldSatisfy,
 )

import Conformance.Receipt (
    Outcome (..),
    Receipt (..),
    RefusalInfo (..),
    Verdict (..),
    checkReceiptSize,
    derivationMatches,
    loadReceipts,
    maxReceiptBytes,
 )
import Conformance.Rows (
    Row (..),
    RowState (..),
    ShownState (..),
    effectiveState,
    loadRows,
    renderInventory,
    rowId,
 )
import Paths_conformance (getDataFileName)

spec :: Spec
spec = describe "Receipt" $ do
    it "round-trips every verdict class" $
        forM_ [minBound :: Verdict .. maxBound] $ \v ->
            case eitherDecode (encode v) :: Either String Verdict of
                Right v' -> v' `shouldBe` v
                Left err -> fail err
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

    it "rejects a phase-1 refusal as unattributed" $ do
        dir <- getDataFileName "test/fixtures/bad-phase"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err ->
                err `shouldSatisfy` ("phase is not phase-2" `isInfixOf`)
            Right _ -> fail "a phase-1 refusal loaded as attributed"

    it "rejects an empty attribution limit" $ do
        dir <- getDataFileName "test/fixtures/bad-limit"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err ->
                err `shouldSatisfy` ("empty branch or limit" `isInfixOf`)
            Right _ -> fail "an empty limit loaded as explicit"

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

    it "rejects a receipt with an unknown venue" $ do
        dir <- getDataFileName "test/fixtures/bad-venue"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft

    it "rejects a node-submit refusal with no rejected id" $ do
        dir <- getDataFileName "test/fixtures/bad-no-rejected"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft

    it "rejects an accepted receipt naming a rejected id" $ do
        dir <- getDataFileName "test/fixtures/bad-accepted-rejected"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft

    it "accepts a blueprint-check receipt with no transactions" $ do
        dir <- getDataFileName "test/fixtures/good-blueprint-check"
        result <- loadReceipts dir
        result `shouldSatisfy` isRight

    it "accepts a param-check receipt with no transactions" $ do
        dir <- getDataFileName "test/fixtures/good-param-check"
        result <- loadReceipts dir
        result `shouldSatisfy` isRight

    it "rejects a blueprint-check receipt naming transactions" $ do
        dir <- getDataFileName "test/fixtures/bad-blueprint-tx"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft

    it "accepts a small receipt under the size bound" $
        checkReceiptSize smallReceipt `shouldBe` Right ()

    it "rejects an oversized receipt naming the row" $
        case checkReceiptSize oversizedReceipt of
            Left err ->
                err `shouldSatisfy` ("CG05" `isInfixOf`)
            Right () -> fail "a 20KB receipt passed the bound"

    it "loads a valid partial receipt and keeps it partial" $ do
        dir <- getDataFileName "test/fixtures/partial-valid"
        result <- loadReceipts dir
        result `shouldSatisfy` isRight
        case result of
            Right [r] -> receiptVerdict r `shouldBe` Partial
            Right rs -> fail ("expected one receipt, got " <> show (length rs))
            Left err -> fail err

    it "renders a partial receipt as partial, never executed" $ do
        dir <- getDataFileName "test/fixtures/partial-valid"
        result <- loadReceipts dir
        case result of
            Left err -> fail err
            Right rs -> do
                rows <- loadCommitted
                case filter ((== "CS03") . rowId) rows of
                    [cs03] ->
                        effectiveState "fixture-base" rs cs03
                            `shouldBe` ShownPartial
                    _ -> fail "fixture inventory has no single CS03"

    it "renders the inventory table with partial in column four" $ do
        dir <- getDataFileName "test/fixtures/partial-valid"
        result <- loadReceipts dir
        case result of
            Left err -> fail err
            Right rs -> do
                rows <- loadCommitted
                let rendered = T.lines (renderInventory "fixture-base" rs rows)
                    cs03line =
                        [ l
                        | l <- rendered
                        , "CS03\t" `T.isPrefixOf` l
                        ]
                case cs03line of
                    [l] -> T.splitOn "\t" l !! 3 `shouldBe` "partial"
                    _ -> fail "inventory has no single CS03 line"
                let bare = T.lines (renderInventory "fixture-base" [] rows)
                    cs03bare =
                        [ l
                        | l <- bare
                        , "CS03\t" `T.isPrefixOf` l
                        ]
                case cs03bare of
                    [l] -> T.splitOn "\t" l !! 3 `shouldBe` "uncovered"
                    _ -> fail "bare inventory has no single CS03 line"

    it "rejects a success verdict carrying partial constructors" $ do
        dir <- getDataFileName "test/fixtures/partial-success"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err -> do
                err `shouldSatisfy` ("carrying partial constructors" `isInfixOf`)
                err `shouldSatisfy` (not . ("does not parse" `isInfixOf`))
            Right _ -> fail "a false-success receipt loaded"

    it "rejects a partial receipt omitting a declared constructor" $ do
        dir <- getDataFileName "test/fixtures/partial-incomplete"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err -> do
                err `shouldSatisfy` ("accounts" `isInfixOf`)
                err `shouldSatisfy` ("Sweep" `isInfixOf`)
            Right _ -> fail "an incomplete partial receipt loaded"

    it "rejects a partial verdict with no residual or gap" $ do
        dir <- getDataFileName "test/fixtures/partial-empty"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err ->
                err `shouldSatisfy` ("no residual or gap" `isInfixOf`)
            Right _ -> fail "a vacuous partial receipt loaded"

    it "rejects partial accounting for a row with no declared set" $ do
        dir <- getDataFileName "test/fixtures/partial-nodecl"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err ->
                err `shouldSatisfy` ("declares no constructor set" `isInfixOf`)
            Right _ -> fail "undeclared partial accounting loaded"

    it "rejects a refused constructor witness as fail-closed" $ do
        dir <- getDataFileName "test/fixtures/partial-refused"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err ->
                err `shouldSatisfy` ("refused constructor witness" `isInfixOf`)
            Right _ -> fail "a refused-standing receipt loaded"

    it "loads a valid derivation receipt" $ do
        dir <- getDataFileName "test/fixtures/derivation-valid"
        result <- loadReceipts dir
        result `shouldSatisfy` isRight

    it "rejects a derivation receipt with a non-identity venue" $ do
        dir <- getDataFileName "test/fixtures/derivation-venue"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err ->
                err `shouldSatisfy` ("derivation venue must be" `isInfixOf`)
            Right _ -> fail "a misvenued derivation receipt loaded"

    it "rejects a CA04 receipt missing the executed negative" $ do
        dir <- getDataFileName "test/fixtures/derivation-incomplete"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err ->
                err `shouldSatisfy` ("incomplete" `isInfixOf`)
            Right _ -> fail "an incomplete derivation receipt loaded"

    it "rejects a mislabelled reference provenance" $ do
        dir <- getDataFileName "test/fixtures/derivation-mislabelled"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err ->
                err `shouldSatisfy` ("mislabelled" `isInfixOf`)
            Right _ -> fail "a mislabelled provenance receipt loaded"

    it "rejects a missing reference provenance as unknown" $ do
        dir <- getDataFileName "test/fixtures/derivation-missingsource"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err ->
                err `shouldSatisfy` ("no reference provenance" `isInfixOf`)
            Right _ -> fail "a missing-provenance receipt loaded"

    it "rejects a bare chain-observed prefix with no outref" $ do
        dir <- getDataFileName "test/fixtures/derivation-bareprefix"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err ->
                err `shouldSatisfy` ("mislabelled" `isInfixOf`)
            Right _ -> fail "a bare-prefix provenance receipt loaded"

    it "rejects a CA04 receipt with legacy node-submit venue" $ do
        dir <- getDataFileName "test/fixtures/derivation-legacyvenue"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err ->
                err `shouldSatisfy` ("CA04 venue must be" `isInfixOf`)
            Right _ -> fail "a legacy-venue CA04 receipt loaded"

    it "decides derivation matches from the comparison" $ do
        derivationMatches ("a" :: T.Text) "a" `shouldBe` ("a", True)
        derivationMatches ("a" :: T.Text) "b" `shouldBe` ("a", False)

    it "rejects a legacy constructor row with no accounting as unknown" $ do
        dir <- getDataFileName "test/fixtures/partial-legacy"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err -> do
                err `shouldSatisfy` ("no constructor accounting" `isInfixOf`)
                err `shouldSatisfy` ("never covered" `isInfixOf`)
            Right _ -> fail "a legacy no-accounting receipt read as covered"

smallReceipt :: Receipt
smallReceipt =
    Receipt
        { receiptRow = "CG02"
        , receiptOutcome = Accepted
        , receiptVerdict = AgreesWithModel
        , receiptTransactions = ["abc123"]
        , receiptRefusal = Nothing
        , receiptRejected = Nothing
        , receiptMem = Just 1
        , receiptCpu = Just 2
        , receiptTxSize = Just 500
        , receiptBase = "base"
        , receiptDirty = False
        , receiptNode = "node"
        , receiptBlueprint = "blueprint"
        , receiptVenue = "node-submit"
        , receiptPartial = Nothing
        , receiptDerivation = Nothing
        }

oversizedReceipt :: Receipt
oversizedReceipt =
    smallReceipt
        { receiptRow = "CG05"
        , receiptOutcome = Refused
        , receiptTransactions = []
        , receiptRefusal =
            Just
                ( RefusalInfo
                    { refusalScript = "state"
                    , refusalReason =
                        T.pack (replicate (maxReceiptBytes + 4096) 'x')
                    , refusalPhase = "phase-2"
                    , refusalHashes = ["abc123"]
                    , refusalBranch = Nothing
                    , refusalLimit = Just "test limit"
                    }
                )
        , receiptRejected = Just "abc123"
        , receiptMem = Nothing
        , receiptCpu = Nothing
        , receiptTxSize = Nothing
        }

loadCommitted :: IO [Row]
loadCommitted = do
    path <- getDataFileName "rows.json"
    result <- loadRows path
    case result of
        Left err -> fail err
        Right rows -> pure rows
