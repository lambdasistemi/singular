{- |
Module      : Conformance.RefusalSpec
Description : Refusal matcher acceptance and rejection tests
License     : Apache-2.0

The samples below are shaped like the node refusal text the
li-refusals runner matches (phase-2 @PlutusFailure@ naming the
script hash hex). The first real devnet run pins the observed text
as a regression sample here; until then these prove the matcher can
both accept and refuse.
-}
module Conformance.RefusalSpec (spec) where

import Data.Either (isLeft)
import Data.List (isInfixOf, isPrefixOf)
import Data.Text qualified as T
import System.Directory (
    createDirectoryIfMissing,
    doesFileExist,
    getTemporaryDirectory,
    removePathForcibly,
 )
import System.FilePath ((</>))
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
    loadReceipts,
    writeReceiptFile,
 )
import Conformance.Refusal (
    RefusalMismatch (..),
    RefusalRole (..),
    attributeRefusalReceipt,
    matchRefusal,
    trimRefusal,
    wrongReasonMarker,
 )

spec :: Spec
spec = describe "Refusal" $ do
    it "accepts a phase-2 failure naming the script" $
        matchRefusal
            "abcdef01"
            "phase-2 PlutusFailure naming ScriptHash \"abcdef01\": \
            \script evaluation failed"
            `shouldBe` Right ()

    it "accepts a build-evaluation failure naming the script" $
        matchRefusal "874e476d" evalFailureSample `shouldBe` Right ()

    it "rejects a phase-1 refusal without PlutusFailure" $
        matchRefusal "abcdef01" "BadInputs: inputs are spent"
            `shouldSatisfy` isLeft

    it "rejects marker-only text with no phase-2 vocabulary" $
        matchRefusal
            "abcdef01"
            "BadInputs 0xabcdef01: inputs are spent"
            `shouldSatisfy` isLeft

    it "rejects a phase-2 failure naming another script" $
        matchRefusal
            "abcdef01"
            "phase-2 PlutusFailure naming ScriptHash \"99999999\": \
            \script evaluation failed"
            `shouldBe` Left
                ( MarkerAbsent
                    "abcdef01"
                    "phase-2 PlutusFailure naming ScriptHash \"99999999\": \
                    \script evaluation failed"
                )

    it "never matches the wrong-reason control marker" $
        matchRefusal
            wrongReasonMarker
            "phase-2 PlutusFailure naming ScriptHash \"abcdef01\": \
            \script evaluation failed"
            `shouldSatisfy` isLeft

    it "refuses a different hash merely mentioning the expected hash" $
        matchRefusal
            "abcdef01"
            "phase-2 PlutusFailure naming ScriptHash \"99999999\": \
            \diagnostic context abcdef01 unquoted"
            `shouldBe` Left
                ( MarkerAbsent
                    "abcdef01"
                    "phase-2 PlutusFailure naming ScriptHash \"99999999\": \
                    \diagnostic context abcdef01 unquoted"
                )

    it "trims the script binary out of an eval refusal" $
        let trimmed = trimRefusal evalShapedRefusal
         in do
                trimmed `shouldSatisfy` ("scriptHash=874e476d" `isInfixOf`)
                trimmed `shouldSatisfy` ("cek=" `isInfixOf`)
                trimmed `shouldSatisfy` (not . ("plutusBinary" `isInfixOf`))
                trimmed `shouldSatisfy` (not . ("pwcCostModel" `isInfixOf`))
                length trimmed `shouldSatisfy` (< 2000)

    it "marks an unknown refusal shape unparsed" $
        trimRefusal "something entirely new"
            `shouldBe` "something entirely new [unparsed]"

    it "keeps every failed script hash when two scripts fail" $
        let two = nodeShapedRefusal <> " second: " <> secondHashRefusal
            trimmed = trimRefusal two
         in do
                -- Joined in ledger order as one field: a trimmer keeping
                -- only the first hash cannot satisfy this.
                trimmed `shouldSatisfy` ("scriptHash=874e476d,28726576" `isInfixOf`)
                length trimmed `shouldSatisfy` (< 2000)

    it "trims the node-submit shape to its attribution" $
        let trimmed = trimRefusal nodeShapedRefusal
         in do
                trimmed `shouldSatisfy` ("scriptHash=874e476d" `isInfixOf`)
                trimmed `shouldSatisfy` ("cek=" `isInfixOf`)
                trimmed `shouldSatisfy` ("PlutusV3 script failed" `isInfixOf`)
                trimmed `shouldSatisfy` (not . ("AAAABBBB" `isInfixOf`))
                trimmed `shouldSatisfy` (not . ("Base64-encoded" `isInfixOf`))
                length trimmed `shouldSatisfy` (< 500)

    -- The A-002 receipt policy, as a nested suite: the control must
    -- never overwrite, the row must write, nothing silent anywhere.
    receiptPolicySpec

evalFailureSample :: String
evalFailureSample = "updateToken: build failed: EvalFailure (ConwaySpending (AsIx 2)) ValidationFailure (CekError script error) (PlutusWithContext {pwcScriptHash = ScriptHash 874e476d})"

evalShapedRefusal :: String
evalShapedRefusal = "updateToken: build failed: EvalFailure (ConwaySpending (AsIx 2)) \\\"ValidationFailure (CekError script error) [] (PlutusWithContext {pwcScript = Left (Plutus {plutusBinary = \\\"AAAABBBB\\\"}), pwcScriptHash = ScriptHash \\\"874e476d\\\", pwcExUnits = X, pwcCostModel = CostModel PlutusV3 [1, 2, 3]})\\\""

-- | The node shape with a different failing script: a tampered fold can
-- fail two scripts in one submission, and the failure-list order varies
-- run to run, so attribution must keep every hash it names.
secondHashRefusal :: String
secondHashRefusal = replaceAll "874e476d" "28726576" nodeShapedRefusal
  where
    replaceAll _ _ [] = []
    replaceAll from to s@(c : cs)
        | from `isPrefixOf` s = to <> replaceAll from to (drop (length from) s)
        | otherwise = c : replaceAll from to cs

nodeShapedRefusal :: String
nodeShapedRefusal = "HardForkApplyTxErrFromEra (ConwayUtxowFailure (FailedUnexpectedly (PlutusFailure \"The PlutusV3 script failed: Base64-encoded script bytes: \\\"AAAABBBB\\\", ScriptHash \\\"874e476d\\\", The plutus evaluation error is: CekError script error. Caused by: error. The protocol version is: Version 10, ScriptInfo: more\")))"

-- ============================================================================
-- Receipt policy (A-002): who writes, and who must never overwrite.
--
-- The defect: a refused CONTROL submitted through the same helper as a
-- refusal ROW wrote its refusal under the row's id, replacing the row's
-- held receipt in every receipts directory (CG11/CG12/CG19). These tests
-- deliberately clobber a main receipt and require the path to
-- discriminate: the row writes, the control never does, a refusal that
-- does not attribute writes nothing for either role.
--
-- The control cannot silently pass with no receipt: an accepted control
-- fails the run as a FINDING and a refusal that does not attribute fails
-- the run naming the mismatch — both upstream of the write this policy
-- governs.

-- | A deterministic receipts directory: wiped at the start of each use
-- so a previous run's bytes can never flatter an assertion.
freshReceiptsDir :: IO FilePath
freshReceiptsDir = do
    tmp <- getTemporaryDirectory
    let dir = tmp </> "conformance-refusal-spec"
    removePathForcibly dir
    createDirectoryIfMissing True dir
    pure dir

-- | The row's own receipt as CG11's run writes it before its control
-- fires: accepted, held-q002, transaction id and measurements present.
heldRowReceipt :: Receipt
heldRowReceipt =
    Receipt
        { receiptRow = "CG11"
        , receiptOutcome = Accepted
        , receiptVerdict = HeldQ002
        , receiptTransactions = [T.pack "rowtxid"]
        , receiptRefusal = Nothing
        , receiptMem = Just 273449
        , receiptCpu = Just 87149465
        , receiptTxSize = Just 8388
        , receiptBase = T.pack "base"
        , receiptNode = T.pack "node"
        , receiptBlueprint = T.pack "blueprint"
        , receiptVenue = "node-submit"
        , receiptRejected = Nothing
        , receiptDirty = False
        , receiptPartial = Nothing
        , receiptDerivation = Nothing
        }

-- | A phase-2 node refusal naming the expected script.
policyMarker :: String
policyMarker = "ce7615f6ba4d"

policyReason :: String
policyReason =
    -- Raw node shape (what submitTxResilient hands the attributor):
    -- the failure class token the matcher requires, the script hash
    -- in its quoted ledger form, the machine error.
    "HardForkApplyTxErrFromEra (ConwayUtxowFailure (FailedUnexpectedly "
        <> "(PlutusFailure \"The PlutusV3 script failed: Base64-encoded "
        <> "script bytes, ScriptHash \\\""
        <> policyMarker
        <> "\\\", The plutus evaluation error is: CekError script error. "
        <> "Caused by: error. The protocol version is: Version 10\")))"

receiptPolicySpec :: Spec
receiptPolicySpec = describe "receipt policy (A-002)" $ do
    it "a refused control never overwrites the row's held receipt" $ do
        dir <- freshReceiptsDir
        writeReceiptFile dir heldRowReceipt
        r <-
            attributeRefusalReceipt
                RefusalControl
                dir
                "CG11"
                HeldQ002
                "state"
                policyMarker
                policyReason
                "controltxid"
                "base"
                False
                "node"
                "blueprint"
        r `shouldBe` Right ()
        rs <- loadReceipts dir
        case rs of
            Right [r0] -> do
                receiptVerdict r0 `shouldBe` HeldQ002
                receiptOutcome r0 `shouldBe` Accepted
                receiptTransactions r0 `shouldBe` [T.pack "rowtxid"]
                receiptRejected r0 `shouldBe` Nothing
            other -> fail ("expected the untouched held receipt, got " <> show other)
    it "a refusal row writes its refused receipt" $ do
        dir <- freshReceiptsDir
        r <-
            attributeRefusalReceipt
                RefusalRow
                dir
                "CG05"
                AgreesWithModel
                "state"
                policyMarker
                policyReason
                "rejectedtxid"
                "base"
                False
                "node"
                "blueprint"
        r `shouldBe` Right ()
        rs <- loadReceipts dir
        case rs of
            Right [r0] -> do
                receiptOutcome r0 `shouldBe` Refused
                receiptVerdict r0 `shouldBe` AgreesWithModel
                receiptRejected r0 `shouldBe` Just (T.pack "rejectedtxid")
                fmap refusalScript (receiptRefusal r0) `shouldBe` Just (T.pack "state")
                receiptVenue r0 `shouldBe` "node-submit"
            other -> fail ("expected the row's refused receipt, got " <> show other)
    it -- A control that attempted any write would throw here: the
       -- directory does not exist, so Right () proves no write attempt.
        "a control refusal writes nothing even where no receipts directory exists"
        $ do
            r <-
                attributeRefusalReceipt
                    RefusalControl
                    "/nonexistent-conformance-refusal-spec"
                    "CG12"
                    HeldQ002
                    "state"
                    policyMarker
                    policyReason
                    "controltxid"
                    "base"
                    False
                    "node"
                    "blueprint"
            r `shouldBe` Right ()
    it "a refusal that does not attribute writes nothing and says why" $ do
        dir <- freshReceiptsDir
        r <-
            attributeRefusalReceipt
                RefusalRow
                dir
                "CG05"
                AgreesWithModel
                "state"
                policyMarker
                "phase-1 refusal that names no script at all"
                "rejectedtxid"
                "base"
                False
                "node"
                "blueprint"
        r `shouldSatisfy` isLeft
        exists <- doesFileExist (dir </> "receipt-CG05.json")
        exists `shouldBe` False
