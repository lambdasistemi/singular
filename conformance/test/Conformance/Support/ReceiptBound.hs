{- |
Module      : Conformance.Support.ReceiptBound
Description : Live chapter receipts rebuilt from a recorded run, against the size bound
License     : Apache-2.0

One devnet run wrote the retirement and the exit controls as one receipt of
21649 bytes, over the bound every receipt is written under, and failed. Its
step lines are kept as a fixture. Each is rebuilt here into the step record the
live interpreter writes and passed through the receipt encoder, so the size of
each chapter's receipt is measured by the same code that refuses it.

A step line does not carry every field of the record. The rebuilt steps take
the declared observations from the driver corpus and one refused perturbation
per observation; the rebuilt run as one receipt must still exceed the bound, as
the run did, and the bytes it falls short of the observed 21649 are added in
full to each chapter measured on its own.
-}
module Conformance.Support.ReceiptBound (spec) where

import Data.Aeson (Value (..), eitherDecodeFileStrict, eitherDecodeStrict, encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BSL
import Data.Either (isRight)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import System.Environment (lookupEnv)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

import Conformance.Compare.Registration (Declared (..), declaredSurface)
import Conformance.Receipt (Outcome (..), Receipt (..), Verdict (..), checkReceiptSize, maxReceiptBytes)
import Paths_conformance (getDataFileName)

-- | The size of the one receipt the recorded run failed to write.
observedBytes :: Int
observedBytes = 21649

-- | The retirement chapter's eleven steps come first in the recorded run; the
-- exit controls' eight follow.
retirementSteps :: Int
retirementSteps = 11

spec :: Spec
spec = describe "Appendix: keeping each live chapter's receipt under the size bound" $ do
    it "Rebuilds the recorded run as one receipt over the bound, as the run failed" $ do
        steps <- recordedSteps
        length steps `shouldBe` 19
        size (chapter "CG22" steps) `shouldSatisfy` (> maxReceiptBytes)
        putStrLn
            ( "rebuilt run: " <> show (size (chapter "CG22" steps)) <> " bytes, "
                <> show (missing steps) <> " short of the observed; retirement "
                <> show (size (chapter "CG22" (take retirementSteps steps))) <> ", exit controls "
                <> show (size (chapter "CG23" (drop retirementSteps steps))) <> " bytes before that is added"
            )
    it "Writes the exit controls' receipt under the bound, with every byte the rebuilt run misses added" $ do
        steps <- recordedSteps
        let exits = chapter "CG23" (drop retirementSteps steps)
        size exits + missing steps `shouldSatisfy` (< maxReceiptBytes)
        checkReceiptSize exits `shouldSatisfy` isRight
    it "Writes the retirement receipt under the bound, with every byte the rebuilt run misses added" $ do
        steps <- recordedSteps
        let retirement = chapter "CG22" (take retirementSteps steps)
        size retirement + missing steps `shouldSatisfy` (< maxReceiptBytes)
        checkReceiptSize retirement `shouldSatisfy` isRight

size :: Receipt -> Int
size = fromIntegral . BSL.length . encode

-- | What the rebuilt run falls short of the receipt the run failed to write.
missing :: [Value] -> Int
missing steps = max 0 (observedBytes - size (chapter "CG22" steps))

-- | A chapter's receipt as the story receipt writer builds it. The envelope
-- numbers take the widest values a run of this size writes.
chapter :: Text -> [Value] -> Receipt
chapter row steps =
    Receipt
        { receiptRow = row
        , receiptOutcome = Accepted
        , receiptVerdict = AgreesWithModel
        , receiptTransactions = [txid | Just txid <- map acceptedTxid steps]
        , receiptRefusal = Nothing
        , receiptRejected = Nothing
        , receiptMem = Just 99_999_999
        , receiptCpu = Just 99_999_999_999
        , receiptTxSize = Just 16_384
        , receiptBase = T.replicate 40 "0"
        , receiptDirty = False
        , receiptNode = T.replicate 64 "0"
        , receiptBlueprint = T.replicate 128 "0"
        , receiptVenue = "node-submit"
        , receiptPartial = Nothing
        , receiptDerivation = Nothing
        , receiptSteps = Just steps
        }

acceptedTxid :: Value -> Maybe Text
acceptedTxid step = case at "chain" step of
    Just chain
        | at "outcome" chain == Just (String "accepted")
        , Just (String txid) <- at "txid" chain ->
            Just txid
    _ -> Nothing

at :: Text -> Value -> Maybe Value
at name (Object fields) = KM.lookup (Key.fromText name) fields
at _ _ = Nothing

recordedSteps :: IO [Value]
recordedSteps = do
    path <- getDataFileName "test/fixtures/live-steps/overflowed-retirement.txt"
    declared <- declaredCorpus
    ls <- T.lines <$> TIO.readFile path
    either fail pure (traverse (stepRecord declared) ls)

declaredCorpus :: IO Declared
declaredCorpus = do
    wired <- lookupEnv "CONFORMANCE_DRIVER_CORPUS"
    path <- maybe (fail "CONFORMANCE_DRIVER_CORPUS is not wired; the declared observations are unknown") pure wired
    corpus <- eitherDecodeFileStrict path >>= either fail pure
    either fail pure (declaredSurface corpus)

{- | One recorded step line as the record the interpreter wrote for it. A
reject or retract line is labelled by its exit; its request is the exit
chapter's insertion. Every refusing script is named by the longer of the two
names the interpreter gives, and each model identity by one digit.
-}
stepRecord :: Declared -> Text -> Either String Value
stepRecord declared line = do
    label <- word "step: "
    _ <- quoted "key=\""
    tamper <- word "tamper="
    modelOutcome <- quoted "model=String \""
    reason <- case T.stripPrefix "String \"" =<< rest "modelReason=" of
        Just quotedReason -> pure (String (T.takeWhile (/= '"') quotedReason))
        Nothing -> pure Null
    chainOutcome <- quoted "chain=String \""
    txid <- word "txid="
    comparison <- word "comparison="
    chain <- case chainOutcome of
        "refused" -> do
            hashes <- json =<< word "scriptHashes="
            kind <- word "refusalKind="
            budget <- json =<< word "budgetPurposes="
            over <- json =<< word "overDeclaredPurposes="
            rejection <- between "nodeRejection=" " declared="
            units <- json =<< between " declared=" " measured="
            measured <- json =<< between " measured=" " comparison="
            let scripts = case hashes of
                    Array names -> Array (fmap (const (String "request")) names)
                    _ -> Array mempty
            pure $ object
                [ "outcome" .= chainOutcome, "txid" .= txid
                , "refusal" .= object
                    [ "trace" .= Null, "hashes" .= hashes, "kind" .= kind
                    , "rejection" .= rejection, "budgetPurposes" .= budget
                    , "overDeclaredPurposes" .= over, "declared" .= units
                    , "measured" .= measured, "scripts" .= scripts ]
                ]
        _ -> pure (object ["outcome" .= chainOutcome, "txid" .= txid])
    let exit = label
        edge = if label `elem` ["reject", "retract"] then "insertActive" else label
        untamperedAccepted = tamper == "none" && chainOutcome == "accepted"
        observations = declaredObservations declared
    pure $ object
        [ "registry" .= (0 :: Int)
        , "edge" .= edge
        , "exit" .= exit
        , "request" .= object
            ( [ "edge" .= edge, "key" .= (0 :: Int), "owner" .= (0 :: Int)
              , "refundAddress" .= (0 :: Int), "deposit" .= (3_000_000 :: Int)
              , "output" .= (0 :: Int), "applicationPolicy" .= (0 :: Int)
              , "approval" .= ("canonical" :: Text), "tip" .= (9_999_999 :: Int) ]
                <> ["reference" .= (0 :: Int) | exit == "retract"]
            )
        , "tamper" .= (if tamper == "none" then Null else String tamper)
        , "model" .= object ["outcome" .= modelOutcome, "reason" .= reason]
        , "chain" .= chain
        , "comparison" .= comparison
        , "compared" .= (if untamperedAccepted then observations else [])
        , "unobserved" .= (if untamperedAccepted then declaredUnobservable declared else [])
        , "perturbation" .= if untamperedAccepted
            then object
                [ "refused" .= length observations
                , "byObservation" .= object [Key.fromText name .= (1 :: Int) | name <- observations]
                , "exempt" .= ([] :: [Text]) ]
            else Null
        , "differences" .= ([] :: [Value])
        ]
  where
    rest marker = case T.breakOn marker line of
        (_, found) | not (T.null found) -> Just (T.drop (T.length marker) found)
        _ -> Nothing
    required marker = maybe (Left ("step line has no " <> show marker <> ": " <> T.unpack line)) Right (rest marker)
    word marker = T.takeWhile (/= ' ') <$> required marker
    quoted marker = T.takeWhile (/= '"') <$> required marker
    between open close = fst . T.breakOn close <$> required open
    json text = eitherDecodeStrict (TE.encodeUtf8 text) :: Either String Value
