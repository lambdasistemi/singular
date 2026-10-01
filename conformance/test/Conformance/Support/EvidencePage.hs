{- |
Module      : Conformance.Support.EvidencePage
Description : The published evidence page is computed, never typed
License     : Apache-2.0

Every value a property compares against is read from the committed
inventory or from the fixture receipts the loader accepts; the page is
read back by its rendered text.
-}
module Conformance.Support.EvidencePage (spec) where

import Data.Aeson (Value (..), decode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BSL
import Data.Char (isAlphaNum)
import Data.List (isInfixOf, sort)
import Data.Maybe (listToMaybe)
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
        "Shows a requirement as demonstrated only from a receipt for the stated revision" $ do
        (rows, receipts) <- fixtures
        page <-
            renderedPage <$> rendered rows (snapshotOf "fixture-base" receipts)
        let demonstrated = section "Requirements a run demonstrated" page
            missing = sectionTree "Requirements not demonstrated" page
        mapM_
            (\r -> tableIds demonstrated `shouldSatisfy` elem (receiptRow r))
            receipts
        tableIds demonstrated `shouldBe` sort (map receiptRow receipts)
        -- every other requirement is listed by name, requirement text and plan
        let others = [r | r <- rows, rowId r `notElem` map receiptRow receipts]
        length others `shouldSatisfy` (> 1)
        mapM_
            ( \r -> do
                tableIds missing `shouldSatisfy` elem (rowId r)
                rowLine r missing
                    `shouldSatisfy` T.isInfixOf (cellText (rowRequirement r))
                rowLine r missing `shouldSatisfy` T.isInfixOf (planName (rowState r))
            )
            others

    it "Lists every requirement exactly once" $ do
        (rows, receipts) <- fixtures
        page <- rendered rows (snapshotOf "fixture-base" receipts)
        let ids = tableIds (renderedPage page)
        mapM_ (\r -> length (filter (== rowId r) ids) `shouldBe` 1) rows
        length ids `shouldBe` length rows

    it "Names the model revision it was given and the stated revision" $ do
        (rows, receipts) <- fixtures
        page <- rendered rows (snapshotOf "fixture-base" receipts)
        renderedPage page `shouldSatisfy` T.isInfixOf model
        renderedPage page `shouldSatisfy` T.isInfixOf "fixture-base"

    it "Refuses a receipt for another code revision" $ do
        (rows, receipts) <- fixtures
        refusal rows (snapshotOf "other-base" receipts) "not the stated base"

    it "Refuses a receipt recorded on a dirty tree" $ do
        (rows, receipts) <- fixtures
        let dirty = [r{receiptDirty = True} | r <- take 1 receipts] <> drop 1 receipts
        refusal rows (snapshotOf "fixture-base" dirty) "dirty tree"

    it "Refuses a receipt for a requirement the inventory does not have" $ do
        (rows, receipts) <- fixtures
        let unknown = [r{receiptRow = "CX99"} | r <- take 1 receipts] <> drop 1 receipts
        refusal rows (snapshotOf "fixture-base" unknown) "unknown requirement"

    it "Refuses a snapshot with no receipt" $ do
        (rows, _) <- fixtures
        refusal rows (snapshotOf "fixture-base" []) "no conformance receipt"

    it "Never shows a held run as demonstrated" $ do
        (rows, receipts) <- fixtures
        let held =
                [r{receiptVerdict = HeldQ002} | r <- take 1 receipts]
                    <> drop 1 receipts
        page <- rendered rows (snapshotOf "fixture-base" held)
        let heldId = maybe "" receiptRow (listToMaybe held)
        tableIds
            (section "Requirements a run demonstrated" (renderedPage page))
            `shouldSatisfy` notElem heldId
        tableIds
            (section "Requirements a run did not pass" (renderedPage page))
            `shouldBe` [heldId]
        case filter ((== heldId) . rowId) rows of
            [row] ->
                effectiveState "fixture-base" held row
                    `shouldSatisfy` (/= ShownExecuted)
            _ ->
                expectationFailure
                    "the fixture's requirement is not in the inventory once"

    it "Shows a partial run as partly demonstrated" $ do
        rows <- committedRows
        partial <- loadFixture "test/fixtures/partial-valid"
        page <- rendered rows (snapshotOf "fixture-base" partial)
        let demonstrated = section "Requirements a run demonstrated" (renderedPage page)
        tableIds demonstrated `shouldBe` map receiptRow partial
        demonstrated `shouldSatisfy` T.isInfixOf "partly demonstrated"

    it
        "Counts contract results per adapter and never counts a not-supported case as passed" $ do
        (rows, receipts) <- fixtures
        page <- rendered rows (snapshotOf "fixture-base" receipts)
        let summary = section "Backend contract across adapters" (renderedPage page)
        summary
            `shouldSatisfy` T.isInfixOf "| memory | test-adapter | 1 | 0 | 1 |"
        summary
            `shouldSatisfy` T.isInfixOf "| node (generated devnet) | devnet | 1 | 1 | 0 |"
        let node = section "node (generated devnet) adapter" (renderedPage page)
        node
            `shouldSatisfy` T.isInfixOf "failed: the connection was not refused"

    it
        "Refuses contract results for another code revision or a dirty tree" $ do
        (rows, receipts) <- fixtures
        let otherBase =
                [c{crBase = "other-base"} | c <- take 1 contract] <> drop 1 contract
            dirty = [c{crDirty = True} | c <- take 1 contract] <> drop 1 contract
        refusal
            rows
            ((snapshotOf "fixture-base" receipts){snapContract = otherBase})
            "not the stated base"
        refusal
            rows
            ((snapshotOf "fixture-base" receipts){snapContract = dirty})
            "dirty tree"

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

    it "Gives every section of the page a speech section and nothing else" $ do
        (rows, receipts) <- fixtures
        page <- rendered rows (snapshotOf "fixture-base" receipts)
        case decode (renderedSpeech page) of
            Just (Object o) ->
                sort (map Key.toText (KeyMap.keys o))
                    `shouldBe` sort (headingIds (renderedPage page))
            _ -> expectationFailure "the speech companion is not a JSON object"

model :: Text
model = "0123456789abcdef0123456789abcdef01234567"

fixtures :: IO ([Row], [Receipt])
fixtures = (,) <$> committedRows <*> loadFixture "test/fixtures/receipts"

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

-- | The first cell of every table row whose first cell is a requirement name.
tableIds :: Text -> [Text]
tableIds page =
    [ T.strip c
    | l <- T.lines page
    , Just rest <- [T.stripPrefix "| " l]
    , let c = T.takeWhile (/= '|') rest
    , isName (T.strip c)
    ]
  where
    isName c = T.length c == 4 && T.all isAlphaNum c && T.take 1 c == "C"

rowLine :: Row -> Text -> Text
rowLine r page =
    T.unlines
        [l | l <- T.lines page, T.isPrefixOf ("| " <> rowId r <> " |") l]

headingIds :: Text -> [Text]
headingIds page =
    [ slugify (T.strip (T.dropWhile (== '#') l))
    | l <- T.lines page
    , let level = T.length (T.takeWhile (== '#') l)
    , level == 2 || level == 3
    , T.isPrefixOf " " (T.drop level l)
    ]
  where
    slugify =
        T.dropAround (== '-')
            . T.intercalate "-"
            . T.words
            . T.filter (\c -> isAlphaNum c || c `elem` ("-_ " :: String))
            . T.toLower
