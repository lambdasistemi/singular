{- |
Module      : Conformance.Support.Receipt
Description : Receipt loading, validation and overlay tests
License     : Apache-2.0

A row prints as executed only when a receipt for it exists and
matches the base. The fixture receipts carry base @fixture-base@;
@other-base@ is the stale-receipt case.
-}
module Conformance.Support.Receipt (spec) where

import Data.Aeson (ToJSON, Value (..), eitherDecode, encode, object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BSL
import Data.Either (isLeft, isRight)
import Data.Foldable (forM_)
import Data.List (isInfixOf)
import Data.Text qualified as T
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (
    Spec,
    describe,
    it,
    shouldBe,
    shouldReturn,
    shouldSatisfy,
 )

import Conformance.Book (renderBook)
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
spec = describe "Appendix: deciding whether a run report counts as evidence" $ do
    stepRoundTrip
    liveStepChecks
    it "Preserves every result category when saving and reading it back" $
        forM_ [minBound :: Verdict .. maxBound] $ \v ->
            case eitherDecode (encode v) :: Either String Verdict of
                Right v' -> v' `shouldBe` v
                Left err -> fail err
    it "Reads both example run reports successfully" $ do
        dir <- getDataFileName "test/fixtures/receipts"
        result <- loadReceipts dir
        result `shouldSatisfy` isRight
        case result of
            Right rs -> length rs `shouldBe` 2
            Left err -> fail err

    it "Marks a requirement as tested only when its report matches the code revision being assessed" $ do
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
                        fail "fixture inventory has no single update requirement"

    it "Counts a demonstrated rejection as a completed test of a rejection requirement" $ do
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
                        fail "fixture inventory has no single occupied-key refusal requirement"

    it "Rejects a report claiming transaction acceptance without naming a transaction" $ do
        dir <- getDataFileName "test/fixtures/bad-accepted"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft

    it "Rejects a rejection report that does not identify the responsible script" $ do
        dir <- getDataFileName "test/fixtures/bad-refused"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft

    it "Does not count a transaction rejected before script execution as a demonstrated script rejection" $ do
        dir <- getDataFileName "test/fixtures/bad-phase"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err ->
                err `shouldSatisfy` ("phase is not phase-2" `isInfixOf`)
            Right _ -> fail "a phase-1 refusal loaded as attributed"

    it "Rejects rejection evidence that leaves its stated limitation blank" $ do
        dir <- getDataFileName "test/fixtures/bad-limit"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err ->
                err `shouldSatisfy` ("empty branch or limit" `isInfixOf`)
            Right _ -> fail "an empty limit loaded as explicit"

    it "Rejects competing reports for the same requirement" $ do
        dir <- getDataFileName "test/fixtures/duplicate"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft

    it "Rejects an unreadable report and identifies the file to fix" $ do
        dir <- getDataFileName "test/fixtures/malformed"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err ->
                err `shouldSatisfy` ("receipt-CG02.json" `isInfixOf`)
            Right _ -> fail "a malformed receipt loaded"

    it "Rejects a report that names an unrecognised way of obtaining evidence" $ do
        dir <- getDataFileName "test/fixtures/bad-venue"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft

    it "Rejects a node rejection report that omits the rejected transaction identifier" $ do
        dir <- getDataFileName "test/fixtures/bad-no-rejected"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft

    it "Rejects a report that claims acceptance while also naming a rejected transaction" $ do
        dir <- getDataFileName "test/fixtures/bad-accepted-rejected"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft

    it "Accepts a compiled-script inspection report without requiring a chain transaction" $ do
        dir <- getDataFileName "test/fixtures/good-blueprint-check"
        result <- loadReceipts dir
        result `shouldSatisfy` isRight

    it "Accepts a parameter inspection report without requiring a chain transaction" $ do
        dir <- getDataFileName "test/fixtures/good-param-check"
        result <- loadReceipts dir
        result `shouldSatisfy` isRight

    it "Rejects a compiled-script inspection report that claims transaction evidence" $ do
        dir <- getDataFileName "test/fixtures/bad-blueprint-tx"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft

    it "Accepts a report within the allowed file size" $
        checkReceiptSize smallReceipt `shouldBe` Right ()

    it "Rejects an oversized report and identifies the affected requirement" $
        case checkReceiptSize oversizedReceipt of
            Left err ->
                err `shouldSatisfy` ("CG05" `isInfixOf`)
            Right () -> fail "a 20KB receipt passed the bound"

    it "Reads an incomplete-coverage report without turning it into a full success" $ do
        dir <- getDataFileName "test/fixtures/partial-valid"
        result <- loadReceipts dir
        result `shouldSatisfy` isRight
        case result of
            Right [r] -> receiptVerdict r `shouldBe` Partial
            Right rs -> fail ("expected one receipt, got " <> show (length rs))
            Left err -> fail err

    it "Shows incomplete coverage as partial, not as a completed requirement" $ do
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

    it "Shows partial coverage in the published status column and uncovered when no report exists" $ do
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

    it "Rejects a success claim when the report says some operation variants remain untested" $ do
        dir <- getDataFileName "test/fixtures/partial-success"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err -> do
                err `shouldSatisfy` ("carrying partial constructors" `isInfixOf`)
                err `shouldSatisfy` (not . ("does not parse" `isInfixOf`))
            Right _ -> fail "a false-success receipt loaded"

    it "Rejects a partial-coverage report that silently omits a required operation variant" $ do
        dir <- getDataFileName "test/fixtures/partial-incomplete"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err -> do
                err `shouldSatisfy` ("accounts" `isInfixOf`)
                err `shouldSatisfy` ("Sweep" `isInfixOf`)
            Right _ -> fail "an incomplete partial receipt loaded"

    it "Rejects a partial-coverage report that identifies no remaining gap" $ do
        dir <- getDataFileName "test/fixtures/partial-empty"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err ->
                err `shouldSatisfy` ("no residual or gap" `isInfixOf`)
            Right _ -> fail "a vacuous partial receipt loaded"

    it "Rejects coverage counts for operation variants the requirement never listed" $ do
        dir <- getDataFileName "test/fixtures/partial-nodecl"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err ->
                err `shouldSatisfy` ("declares no constructor set" `isInfixOf`)
            Right _ -> fail "undeclared partial accounting loaded"

    it "Does not count a rejected operation variant as evidence that the required operation succeeded" $ do
        dir <- getDataFileName "test/fixtures/partial-refused"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err ->
                err `shouldSatisfy` ("refused constructor witness" `isInfixOf`)
            Right _ -> fail "a refused-standing receipt loaded"

    it "Accepts a complete report comparing the calculated validator identity with its reference" $ do
        dir <- getDataFileName "test/fixtures/derivation-valid"
        result <- loadReceipts dir
        result `shouldSatisfy` isRight

    it "Rejects an identity-comparison report labelled as a different kind of check" $ do
        dir <- getDataFileName "test/fixtures/derivation-venue"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err ->
                err `shouldSatisfy` ("derivation venue must be" `isInfixOf`)
            Right _ -> fail "a misvenued derivation receipt loaded"

    it "Rejects an identity-check report that never tried a deliberately wrong identity" $ do
        dir <- getDataFileName "test/fixtures/derivation-incomplete"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err ->
                err `shouldSatisfy` ("incomplete" `isInfixOf`)
            Right _ -> fail "an incomplete derivation receipt loaded"

    it "Rejects an identity-check report that mislabels where its reference came from" $ do
        dir <- getDataFileName "test/fixtures/derivation-mislabelled"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err ->
                err `shouldSatisfy` ("mislabelled" `isInfixOf`)
            Right _ -> fail "a mislabelled provenance receipt loaded"

    it "Rejects an identity-check report that does not say where its reference came from" $ do
        dir <- getDataFileName "test/fixtures/derivation-missingsource"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err ->
                err `shouldSatisfy` ("no reference provenance" `isInfixOf`)
            Right _ -> fail "a missing-provenance receipt loaded"

    it "Rejects a claimed chain reference that does not identify a transaction output" $ do
        dir <- getDataFileName "test/fixtures/derivation-bareprefix"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err ->
                err `shouldSatisfy` ("mislabelled" `isInfixOf`)
            Right _ -> fail "a bare-prefix provenance receipt loaded"

    it "Rejects an identity-comparison report labelled as a submitted transaction" $ do
        dir <- getDataFileName "test/fixtures/derivation-legacyvenue"
        result <- loadReceipts dir
        result `shouldSatisfy` isLeft
        case result of
            Left err ->
                err `shouldSatisfy` ("CA04 venue must be" `isInfixOf`)
            Right _ -> fail "a legacy-venue CA04 receipt loaded"

    it "Reports an identity match only when the calculated and reference values are equal" $ do
        derivationMatches ("a" :: T.Text) "a" `shouldBe` ("a", True)
        derivationMatches ("a" :: T.Text) "b" `shouldBe` ("a", False)

    it "Rejects an older report that never accounts for which operation variants were tested" $ do
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
        , receiptSteps = Nothing
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

stepRoundTrip :: Spec
stepRoundTrip = describe "Saving compared live requests" $
    it "Preserves the model and chain outcomes of a retirement step" $ do
        let step :: Value
            step =
                object
                    [ "registry" .= (1 :: Integer)
                    , "edge" .= ("updateTerminal" :: String)
                    , "request" .= object ["key" .= (2 :: Integer)]
                    , "tamper" .= (Nothing :: Maybe String)
                    , "model" .= object ["outcome" .= ("refused" :: String), "reason" .= ("not-booked" :: String)]
                    , "chain" .= object ["outcome" .= ("refused" :: String), "txid" .= ("a1" :: String)]
                    , "comparison" .= ("agrees" :: String)
                    , "compared" .= ([] :: [String])
                    , "unobserved" .= ([] :: [String])
                    , "perturbation" .= (Nothing :: Maybe Value)
                    ]
            receipt = smallReceipt{receiptRow = "CG22", receiptSteps = Just [step]}
        case eitherDecode (encode receipt) :: Either String Receipt of
            Left err -> fail ("compared request receipt does not parse: " <> err)
            Right decoded -> receiptSteps decoded `shouldBe` Just [step]

-- The step body is a public evidence claim. These checks load an actual
-- written receipt, so none can pass merely because JSON round-trips.
liveStepChecks :: Spec
liveStepChecks = describe "Checking compared requests in live receipts" $ do
    it "publishes the unnamed request sequence beside the two chapters" $
        renderBook [] [acceptedLive] `shouldSatisfy` isInfixOf "## A sequence no chapter names"
    it "accepts a complete compared request" $
        loadLive acceptedLive `shouldReturn` Right 1
    it "Rejects registration evidence submitted under a different requirement" $
        loadLive acceptedLive{receiptRow = "CG02"} >>= (`shouldSatisfy` isLeft)
    it "rejects a live chapter with no step records" $
        loadLive acceptedLive{receiptSteps = Nothing} >>= (`shouldSatisfy` isLeft)
    it "rejects a step whose accepted transaction is absent from the envelope" $
        loadLive acceptedLive{receiptTransactions = []} >>= (`shouldSatisfy` isLeft)
    it "rejects agreement when the model and chain outcome classes differ" $
        loadLive (changeStep (setField "chain" (object ["outcome" .= ("refused" :: String)])) acceptedLive)
            >>= (`shouldSatisfy` isLeft)
    it "rejects accepted agreement with an omitted observation" $
        loadLive (changeStep (setField "compared" (["mint"] :: [String])) acceptedLive)
            >>= (`shouldSatisfy` isLeft)
    it "rejects accepted agreement without perturbation evidence" $
        loadLive (changeStep (setField "perturbation" Null) acceptedLive)
            >>= (`shouldSatisfy` isLeft)
    it "rejects a claimed redirected-delivery agreement without a script hash" $
        loadLive (changeStep (setField "tamper" ("redirect-delivery" :: String)) acceptedLive)
            >>= (`shouldSatisfy` isLeft)
    it "accepts an extra required signer the comparison reported in the transaction's signers" $
        loadLive extraSignerLive `shouldReturn` Right 1
    it "rejects an extra-signer agreement whose comparison reported no difference" $
        loadLive (changeStep (setField "differences" ([] :: [Value])) extraSignerLive)
            >>= (`shouldSatisfy` isLeft)
    it "rejects an untampered agreement that reports a difference" $
        loadLive (changeStep (setField "differences" [signerDifference]) acceptedLive)
            >>= (`shouldSatisfy` isLeft)

acceptedLive :: Receipt
acceptedLive =
    smallReceipt
        { receiptRow = "CG21"
        , receiptSteps =
            Just
                [ object
                    [ "registry" .= (1 :: Int)
                    , "edge" .= ("insertActive" :: String)
                    , "request" .= object ["key" .= ("example" :: String)]
                    , "tamper" .= (Nothing :: Maybe String)
                    , "model" .= object ["outcome" .= ("accepted" :: String)]
                    , "chain" .= object ["outcome" .= ("accepted" :: String), "txid" .= ("abc123" :: String)]
                    , "comparison" .= ("agrees" :: String)
                    , "compared" .= ["config", "custody", "held", "leaf", "mint", "paid", "root", "state", "tx" :: String]
                    , "unobserved" .= ([] :: [String])
                    , "perturbation"
                        .= object
                            ["refused" .= (1 :: Int), "byObservation" .= object [], "exempt" .= ([] :: [String])]
                    ]
                ]
        }

-- | The registration folded with one required signer the model does not
-- require: the ledger accepts it, and the comparison reports exactly the
-- transaction's signers.
extraSignerLive :: Receipt
extraSignerLive =
    changeStep
        ( setField "tamper" ("extra-signer" :: String)
            . setField "compared" ([] :: [String])
            . setField "perturbation" Null
            . setField "differences" [signerDifference]
        )
        acceptedLive

signerDifference :: Value
signerDifference = object ["observation" .= ("tx" :: String), "path" .= ("signers" :: String)]

setField :: (ToJSON a) => String -> a -> Value -> Value
setField name value (Object fields) = Object (KM.insert (Key.fromString name) (toJSON value) fields)
setField _ _ value = value

changeStep :: (Value -> Value) -> Receipt -> Receipt
changeStep f receipt = receipt{receiptSteps = fmap (map f) (receiptSteps receipt)}

loadLive :: Receipt -> IO (Either String Int)
loadLive receipt = withSystemTempDirectory "conformance-live-receipt" $ \dir -> do
    BSL.writeFile (dir </> "receipt-CG21.json") (encode receipt)
    fmap length <$> loadReceipts dir
