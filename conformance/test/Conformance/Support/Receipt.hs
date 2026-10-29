-- | Reader controls use synthetic reports and never supply product evidence.
module Conformance.Support.Receipt (spec) where

import Control.Monad (forM_)
import Data.Aeson (Value (..), eitherDecode, encode, toJSON)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BSL
import Data.Either (isLeft, isRight)
import Data.Text qualified as T
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldReturn
    , shouldSatisfy
    )

import Conformance.Receipt
    ( Outcome (..)
    , Receipt (..)
    , RefusalInfo (..)
    , Verdict (..)
    , checkReceiptSize
    , loadReceipts
    , maxReceiptBytes
    , writeReceiptFile
    )
import Conformance.Rows
    ( Row (..)
    , ShownState (..)
    , effectiveState
    , loadRows
    )
import Paths_conformance (getDataFileName)

spec :: Spec
spec = describe "Appendix: deciding whether a report counts as evidence" $ do
    it "Preserves every verdict through its JSON representation" $
        forM_ [minBound :: Verdict .. maxBound] $ \verdict ->
            eitherDecode (encode verdict) `shouldBe` Right verdict
    it
        "Reads independently named reports and refuses duplicate requirements"
        $ do
            reports <- fixtures
            length reports `shouldSatisfy` (> 1)
            loaded reports `shouldReturn` Right reports
            loaded (reports <> take 1 reports) >>= (`shouldSatisfy` isLeft)
    it
        "Refuses unsupported evidence fields rather than dropping their claims"
        $ do
            reports <- fixtures
            forM_ reports $ \report -> do
                forM_ ["steps", "partial", "derivation"] $ \name ->
                    withSystemTempDirectory "reader-unsupported" $ \dir -> do
                        let body = case toJSON report of
                                Object fields -> Object (KM.insert name (Bool True) fields)
                                other -> other
                        BSL.writeFile (dir </> "receipt-unsupported.json") (encode body)
                        loadReceipts dir >>= (`shouldSatisfy` isLeft)
                loaded [report{receiptVerdict = Partial}] >>= (`shouldSatisfy` isLeft)
    it "Refuses missing or unreadable evidence, naming the file" $
        withSystemTempDirectory "reader-evidence" $ \dir -> do
            loadReceipts (dir </> "missing") >>= (`shouldSatisfy` isLeft)
            BSL.writeFile (dir </> "receipt-bad.json") "unreadable"
            loadReceipts dir >>= (`shouldSatisfy` isLeft)
    it
        "Needs a clean report of this revision before granting execution credit"
        $ do
            rows <- getDataFileName "rows.json" >>= loadRows >>= either fail pure
            reports <- fixtures
            rows `shouldSatisfy` (not . null)
            reports `shouldSatisfy` (not . null)
            forM_ [(row, report) | row <- rows, report <- reports] $ \(row, report) -> do
                effectiveState "fixture-base" [] row
                    `shouldBe` ShownPlanned (rowState row)
                let bound = report{receiptRow = rowId row}
                effectiveState "fixture-base" [bound] row `shouldBe` ShownExecuted
                effectiveState "other-base" [bound] row
                    `shouldBe` ShownPlanned (rowState row)
                forM_ [minBound .. maxBound] $ \verdict ->
                    case verdict of
                        AgreesWithModel -> pure ()
                        Partial ->
                            effectiveState "fixture-base" [bound{receiptVerdict = verdict}] row
                                `shouldBe` ShownPartial
                        _ ->
                            effectiveState "fixture-base" [bound{receiptVerdict = verdict}] row
                                `shouldBe` ShownRecorded verdict
                loaded [bound{receiptDirty = True}] >>= (`shouldSatisfy` isLeft)
    it
        "Refuses acceptance without its transaction, venue or measured units"
        $ do
            reports <- fixtures
            forM_ reports $ \report -> do
                forM_
                    [ report{receiptTransactions = []}
                    , report{receiptVenue = "local-check"}
                    , report{receiptMem = Nothing}
                    , report{receiptCpu = Nothing}
                    , report{receiptTxSize = Nothing}
                    , report{receiptRejected = Just "rejected"}
                    ]
                    $ \changed -> loaded [changed] >>= (`shouldSatisfy` isLeft)
    it
        "Requires refusal attribution and a rejected id exactly at the node boundary"
        $ do
            reports <- fixtures
            forM_ reports $ \report -> do
                let info =
                        RefusalInfo
                            "script"
                            "observed refusal"
                            "phase-2"
                            ["hash"]
                            Nothing
                            (Just "no traced branch")
                            Nothing
                    refused =
                        report
                            { receiptOutcome = Refused
                            , receiptTransactions = []
                            , receiptRefusal = Just info
                            , receiptRejected = Just "rejected"
                            }
                loaded [refused] `shouldReturn` Right [refused]
                forM_
                    [ refused{receiptRefusal = Nothing}
                    , refused{receiptRejected = Nothing}
                    , refused{receiptRefusal = Just info{refusalHashes = []}}
                    , refused{receiptRefusal = Just info{refusalPhase = "phase-1"}}
                    , refused{receiptRefusal = Just info{refusalLimit = Nothing}}
                    , refused{receiptRefusal = Just info{refusalBranch = Just "invented"}}
                    ]
                    $ \changed -> loaded [changed] >>= (`shouldSatisfy` isLeft)
                let local = refused{receiptVenue = "ledger-eval", receiptRejected = Nothing}
                loaded [local] `shouldReturn` Right [local]
    it
        "Writes readable receipts and refuses exactly one byte beyond the bound"
        $ do
            reports <- fixtures
            forM_ reports $ \report -> do
                let remaining = maxReceiptBytes - fromIntegral (BSL.length (encode report))
                    full =
                        report{receiptNode = receiptNode report <> T.replicate remaining "x"}
                BSL.length (encode full) `shouldBe` fromIntegral maxReceiptBytes
                checkReceiptSize full `shouldSatisfy` isRight
                checkReceiptSize full{receiptNode = receiptNode full <> "x"}
                    `shouldSatisfy` isLeft
                withSystemTempDirectory "reader-write" $ \dir -> do
                    writeReceiptFile dir report
                    loadReceipts dir `shouldReturn` Right [report]

fixtures :: IO [Receipt]
fixtures =
    getDataFileName "test/fixtures/reader"
        >>= loadReceipts
        >>= either fail pure

loaded :: [Receipt] -> IO (Either String [Receipt])
loaded reports = withSystemTempDirectory "reader-receipts" $ \dir -> do
    -- Distinct filenames let the loader, rather than a file overwrite, judge duplicates.
    forM_ (zip [0 :: Int ..] reports) $ \(i, report) ->
        BSL.writeFile
            (dir </> ("receipt-" <> show i <> ".json"))
            (encode report)
    loadReceipts dir
