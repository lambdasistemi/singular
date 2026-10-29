{- |
Module      : Conformance.Support.EvidencePage
Description : The published evidence page is computed, never typed
License     : Apache-2.0

Every value a property compares against is read from the committed
inventory or from the fixture receipts the loader accepts; the page is
read back by its rendered text.
-}
module Conformance.Support.EvidencePage (spec) where

import Control.Monad (forM_)
import Data.ByteString.Lazy qualified as BSL
import Data.List (isInfixOf, sort)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )

import Conformance.EvidencePage
    ( ContractEvidence (..)
    , ContractOutcome (..)
    , ContractResult (..)
    , RenderedPage (..)
    , Snapshot (..)
    , Source (..)
    , renderConsumerSummary
    , renderEvidencePage
    )
import Conformance.Receipt
    ( Receipt (..)
    , Verdict (..)
    , loadReceipts
    )
import Conformance.Rows
    ( Row (..)
    , RowState (..)
    , ShownState (..)
    , effectiveState
    , loadRows
    )
import Data.Aeson qualified as Aeson
import Paths_conformance (getDataFileName)

spec :: Spec
spec = describe "Appendix: computing the published evidence page" $ do
    it
        "Shows a requirement as demonstrated only from a receipt for the stated revision"
        $ do
            (rows, receipts) <- fixtures
            page <-
                renderedPage <$> rendered rows (snapshotOf "fixture-base" receipts)
            let demonstrated = section "Requirements a run demonstrated" page
                missing = sectionTree "Requirements not demonstrated" page
            mapM_
                (\r -> tableIds rows demonstrated `shouldSatisfy` elem (receiptRow r))
                receipts
            tableIds rows demonstrated `shouldBe` sort (map receiptRow receipts)
            -- every other requirement is listed by name, requirement text and plan
            let others = [r | r <- rows, rowId r `notElem` map receiptRow receipts]
            length others `shouldSatisfy` (> 1)
            mapM_
                ( \r -> do
                    tableIds rows missing `shouldSatisfy` elem (rowId r)
                    rowLine r missing
                        `shouldSatisfy` T.isInfixOf (cellText (rowRequirement r))
                    rowLine r missing `shouldSatisfy` T.isInfixOf (planName (rowState r))
                )
                others

    it "Lists every requirement exactly once" $ do
        (rows, receipts) <- fixtures
        page <- rendered rows (snapshotOf "fixture-base" receipts)
        let ids = tableIds rows (renderedPage page)
        mapM_ (\r -> length (filter (== rowId r) ids) `shouldBe` 1) rows
        length ids `shouldBe` length rows

    it
        "Names published requirements by their text without internal row identifiers"
        $ do
            (rows, receipts) <- fixtures
            page <- rendered rows (snapshotOf "fixture-base" receipts)
            forM_ rows $ \row -> do
                renderedPage page
                    `shouldSatisfy` T.isInfixOf (cellText (rowRequirement row))
                renderedPage page `shouldSatisfy` (not . T.isInfixOf (rowId row))

    it "Names the model revision it was given and the stated revision" $ do
        (rows, receipts) <- fixtures
        page <- rendered rows (snapshotOf "fixture-base" receipts)
        renderedPage page `shouldSatisfy` T.isInfixOf model
        renderedPage page `shouldSatisfy` T.isInfixOf "fixture-base"

    it
        "Computes the consumer totals and changes standings only with receipts" $ do
        (rows, receipts) <- fixtures
        length receipts `shouldSatisfy` (> 1)
        let cell label n = "| " <> label <> " | " <> T.pack (show n) <> " |"
            summary reports =
                either
                    fail
                    pure
                    (renderConsumerSummary rows (snapshotOf "fixture-base" reports))
        without <- summary []
        without
            `shouldSatisfy` T.isInfixOf (cell "Total requirements" (length rows))
        without `shouldSatisfy` T.isInfixOf (cell "Uncovered" (length rows))
        with <- summary receipts
        with
            `shouldSatisfy` T.isInfixOf (cell "Demonstrated by a run" (length receipts))
        with
            `shouldSatisfy` T.isInfixOf (cell "Uncovered" (length rows - length receipts))
        let groups = sort (map rowGroup rows)
        forM_ groups $ \group ->
            with
                `shouldSatisfy` T.isInfixOf
                    ( cell
                        (T.toTitle (T.replace "-" " " group))
                        (length (filter (== group) groups))
                    )
        forM_ rows $ \row -> with `shouldSatisfy` (not . T.isInfixOf (rowId row))
        let failed = map (\r -> r{receiptVerdict = DivergesFromLean}) receipts
        refusedSummary <- summary failed
        refusedSummary
            `shouldSatisfy` T.isInfixOf (cell "Run, result not a pass" (length failed))
        refusedSummary
            `shouldSatisfy` T.isInfixOf (cell "Demonstrated by a run" (0 :: Int))

    it "Refuses a receipt for another code revision, wherever it stands" $ do
        (rows, receipts) <- fixtures
        everyPosition receipts (\r -> r{receiptBase = "other-base"}) $ \tampered ->
            refusal
                rows
                (snapshotOf "fixture-base" tampered)
                "not the stated base"

    it "Refuses a receipt recorded on a dirty tree, wherever it stands" $ do
        (rows, receipts) <- fixtures
        everyPosition receipts (\r -> r{receiptDirty = True}) $ \tampered ->
            refusal rows (snapshotOf "fixture-base" tampered) "dirty tree"

    it
        "Refuses a receipt for a requirement the inventory does not have, wherever it stands"
        $ do
            (rows, receipts) <- fixtures
            everyPosition receipts (\r -> r{receiptRow = "CX99"}) $ \tampered ->
                refusal
                    rows
                    (snapshotOf "fixture-base" tampered)
                    "unknown requirement"

    it
        "Publishes every uncovered requirement when no comparison receipt exists"
        $ do
            (rows, _) <- fixtures
            page <- rendered rows (snapshotOf "fixture-base" [])
            tableIds
                rows
                (sectionTree "Requirements not demonstrated" (renderedPage page))
                `shouldBe` sort (map rowId rows)

    it
        "Never shows a run that did not pass as demonstrated, whatever its verdict and wherever it stands"
        $ do
            (rows, receipts) <- fixtures
            let notPassing =
                    [ v
                    | v <- [minBound .. maxBound]
                    , v `notElem` [AgreesWithModel, Partial, UnmetByRuling]
                    ]
            length notPassing `shouldSatisfy` (> 1)
            forM_ notPassing $ \verdict ->
                everyPositionAt receipts (\r -> r{receiptVerdict = verdict}) $ \i held -> do
                    page <- rendered rows (snapshotOf "fixture-base" held)
                    let heldId = maybe "" receiptRow (lookup i (zip [0 ..] held))
                        others = [receiptRow r | (j, r) <- zip [0 ..] held, j /= i]
                    tableIds
                        rows
                        (section "Requirements a run demonstrated" (renderedPage page))
                        `shouldBe` sort others
                    tableIds
                        rows
                        (section "Requirements a run did not pass" (renderedPage page))
                        `shouldBe` [heldId]
                    case filter ((== heldId) . rowId) rows of
                        [row] ->
                            effectiveState "fixture-base" held row
                                `shouldSatisfy` (/= ShownExecuted)
                        _ ->
                            expectationFailure
                                "the fixture's requirement is not in the inventory once"

    it
        "Counts contract results per adapter and never counts a not-supported case as passed"
        $ do
            (rows, receipts) <- fixtures
            page <- rendered rows (snapshotOf "fixture-base" receipts)
            let summary =
                    section
                        "Appendix: backend contract across adapters"
                        (renderedPage page)
            summary
                `shouldSatisfy` T.isInfixOf "| memory | test-adapter | 1 | 0 | 1 |"
            summary
                `shouldSatisfy` T.isInfixOf "| node (generated devnet) | devnet | 1 | 1 | 0 |"
            let node = section "node (generated devnet) adapter" (renderedPage page)
            node
                `shouldSatisfy` T.isInfixOf "failed: the connection was not refused"

    it
        "Refuses a contract result for another code revision or a dirty tree, wherever it stands"
        $ do
            (rows, receipts) <- fixtures
            let with cs = (snapshotOf "fixture-base" receipts){snapContract = cs}
            everyPosition contract (\c -> c{crBase = "other-base"}) $ \tampered ->
                refusal rows (with tampered) "not the stated base"
            everyPosition contract (\c -> c{crDirty = True}) $ \tampered ->
                refusal rows (with tampered) "dirty tree"

    it "Refuses adapters that do not report the same case list" $ do
        (rows, receipts) <- fixtures
        let short =
                filter
                    (\c -> not (crAdapter c == "memory" && crCase c == "AtOrigin"))
                    contract
            twice = contract <> take 1 contract
        refusal
            rows
            ((snapshotOf "fixture-base" receipts){snapContract = short})
            "same contract case list"
        refusal
            rows
            ((snapshotOf "fixture-base" receipts){snapContract = twice})
            "twice"
        refusal
            rows
            ((snapshotOf "fixture-base" receipts){snapContract = []})
            "no contract result"

    it "Reads no public-chain evidence class" $
        (Aeson.eitherDecode publicChainLine :: Either String ContractResult)
            `shouldSatisfy` either ("not one the contract suite runs" `isInfixOf`) (const False)

model :: Text
model = "0123456789abcdef0123456789abcdef01234567"

fixtures :: IO ([Row], [Receipt])
fixtures = do
    rows <- committedRows
    receipts <- loadFixture "test/fixtures/reader"
    -- Bind synthetic appendix reports to the discovered inventory. These
    -- reports test rendering and are never published as product evidence.
    pure
        ( rows
        , zipWith (\row report -> report{receiptRow = rowId row}) rows receipts
        )

committedRows :: IO [Row]
committedRows = do
    path <- getDataFileName "rows.json"
    loadRows path >>= either fail pure

loadFixture :: FilePath -> IO [Receipt]
loadFixture dir = getDataFileName dir >>= loadReceipts >>= either fail pure

snapshotOf :: Text -> [Receipt] -> Snapshot
snapshotOf base receipts =
    Snapshot
        { snapBase = base
        , snapSources =
            [ Source
                "Conformance"
                "https://example.invalid/run/1"
                "conformance-receipts"
            ]
        , snapReceipts = receipts
        , snapReceiptFiles =
            map (\r -> "receipt-" <> T.unpack (receiptRow r) <> ".json") receipts
        , snapContract = contract
        , snapContractFiles = ["generated.jsonl"]
        }

-- | Two adapters, the same two cases, one of each outcome.
contract :: [ContractResult]
contract =
    [ result "memory" ContractTestAdapter "ViewNamesPoint" ContractPassed
    , result
        "memory"
        ContractTestAdapter
        "AtOrigin"
        (ContractNotSupported "the chain is never at its origin")
    , result
        "node (generated devnet)"
        ContractDevNet
        "ViewNamesPoint"
        ContractPassed
    , result
        "node (generated devnet)"
        ContractDevNet
        "AtOrigin"
        (ContractFailed "the connection was not refused")
    ]
  where
    result adapter evidence name outcome =
        ContractResult
            { crBase = "fixture-base"
            , crDirty = False
            , crAdapter = adapter
            , crEvidence = evidence
            , crCase = name
            , crKind = "refusal"
            , crRequirement = "requirement of " <> name
            , crOutcome = outcome
            }

publicChainLine :: BSL.ByteString
publicChainLine =
    "{\"base\":\"fixture-base\",\"dirty\":false,\"adapter\":\"node\",\
    \\"evidence\":\"public-chain\",\"case\":\"ViewNamesPoint\",\
    \\"kind\":\"success\",\"requirement\":\"r\",\"outcome\":\"passed\"}"

rendered :: [Row] -> Snapshot -> IO RenderedPage
rendered rows snap = either fail pure (renderEvidencePage model rows snap)

refusal :: [Row] -> Snapshot -> String -> IO ()
refusal rows snap reason = case renderEvidencePage model rows snap of
    Left err -> err `shouldSatisfy` (reason `isInfixOf`)
    Right _ ->
        expectationFailure
            ("rendered a snapshot that should be refused: " <> reason)

planName :: RowState -> Text
planName Uncovered = "uncovered"
planName BoundElsewhere = "bound elsewhere"
planName OutOfScope = "out of scope"

cellText :: Text -> Text
cellText = T.replace "|" "\\|" . T.replace "\n" " "

-- | The lines of one section, up to the next heading of any level.
section :: Text -> Text -> Text
section title page =
    T.unlines
        . takeWhile (not . T.isPrefixOf "#")
        . drop 1
        . dropWhile (not . isHeading)
        $ T.lines page
  where
    isHeading l = T.isPrefixOf "#" l && T.strip (T.dropWhile (== '#') l) == title

-- | One section with its subsections, up to the next heading of its level.
sectionTree :: Text -> Text -> Text
sectionTree title page =
    case break isHeading (T.lines page) of
        (_, h : rest) ->
            let level = T.length (T.takeWhile (== '#') h)
                within l =
                    not (T.isPrefixOf "#" l)
                        || T.length (T.takeWhile (== '#') l) > level
            in  T.unlines (takeWhile within rest)
        _ -> ""
  where
    isHeading l = T.isPrefixOf "#" l && T.strip (T.dropWhile (== '#') l) == title

-- | Resolve rendered requirement text back to machine identities in the test.
tableIds :: [Row] -> Text -> [Text]
tableIds rows page =
    sort
        [ rowId row
        | l <- T.lines page
        , row <- rows
        , T.isPrefixOf ("| " <> cellText (rowRequirement row) <> " |") l
        ]

rowLine :: Row -> Text -> Text
rowLine r page =
    T.unlines
        [ l
        | l <- T.lines page
        , T.isPrefixOf ("| " <> cellText (rowRequirement r) <> " |") l
        ]

{- | Run a property once per position, with exactly that one item tampered:
a check that looks at only some items cannot pass it. Refuses a list too
short to tell positions apart.
-}
everyPosition :: [a] -> (a -> a) -> ([a] -> IO ()) -> IO ()
everyPosition items tamper property =
    everyPositionAt items tamper (const property)

everyPositionAt :: [a] -> (a -> a) -> (Int -> [a] -> IO ()) -> IO ()
everyPositionAt items tamper property
    | length items < 2 =
        expectationFailure "a position property needs at least two items"
    | otherwise =
        mapM_
            ( \i ->
                property
                    i
                    [if j == i then tamper x else x | (j, x) <- zip [0 ..] items]
            )
            [0 .. length items - 1]
