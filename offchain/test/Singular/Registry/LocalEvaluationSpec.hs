{-# LANGUAGE TypeApplications #-}

-- | Exact recorded evaluation answers and reachable context corruptions.
module Singular.Registry.LocalEvaluationSpec (spec, fixture) where

import Control.Monad (forM_, unless)
import Control.Monad.State.Strict (modify', runState)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson
    ( FromJSON (..)
    , eitherDecodeStrict'
    , withObject
    , (.:)
    )
import Data.Aeson.Types (Parser)
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)
import Lens.Micro ((&), (.~), (^.))
import Paths_singular_registry (getDataFileName)
import Prettyprinter (pretty)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldNotBe
    , shouldSatisfy
    )

import Cardano.Ledger.Alonzo.Plutus.Evaluate
    ( TransactionScriptFailure (..)
    )
import Cardano.Ledger.Alonzo.Scripts
    ( AsIx (..)
    , costModelsValid
    , getCostModelParams
    , mkCostModel
    , mkCostModels
    )
import Cardano.Ledger.Api.PParams (ppCostModelsL)
import Cardano.Ledger.Api.Scripts.Data (Data (..))
import Cardano.Ledger.Api.Tx (witsTxL)
import Cardano.Ledger.Api.Tx.Out (TxOut, datumTxOutL)
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.Binary
    ( decCBOR
    , decodeFull'
    , decodeFullAnnotator
    )
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (eraProtVerLow)
import Cardano.Ledger.Plutus (ExUnits (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)
import PlutusLedgerApi.V3 qualified as PLC
import Singular.Registry.LocalEvaluation
import Singular.Registry.NetworkTime (validateNetworkTime)
import Singular.Registry.NetworkTimeSpec (loadNetworkFixture)
import Singular.Registry.TxBuilder.Internal (mkInlineDatum)

data Answer = Units ExUnits | ScriptFailure Text [Text]
    deriving stock (Eq, Show)
data Recorded = Recorded [(ConwayPlutusPurpose AsIx ConwayEra, Answer)]
data RecordIdentity = RecordIdentity FilePath ByteString
newtype Manifest = Manifest [RecordIdentity]

instance FromJSON RecordIdentity where
    parseJSON = withObject "immutable evaluation record" $ \v ->
        RecordIdentity <$> v .: "path" <*> (v .: "sha256" >>= hex)
      where
        hex = either fail pure . B16.decode . encodeUtf8

instance FromJSON Manifest where
    parseJSON = withObject "evaluation recording manifest" $ \v -> do
        network <- v .: "networkMagic" :: Parser Int
        unless (network == 1) (fail "WrongRecordedEvaluationNetwork")
        source <- v .: "sourceIdentity" :: Parser Text
        unless
            ("Ogmios v6.14 sha256:" `Text.isPrefixOf` source)
            (fail "UnknownEvaluationSource")
        records <- v .: "records"
        unless (length records > 1) (fail "EmptyEvaluationRecording")
        pure (Manifest records)

instance FromJSON Recorded where
    parseJSON = withObject "recorded independent evaluator response" $ \v -> do
        method <- v .: "method" :: Parser Text
        unless
            (method == "evaluateTransaction")
            (fail "WrongRecordedEvaluationMethod")
        success <- v .: "id" :: Parser Text
        rows <- case success of
            "success" -> do
                values <- v .: "result"
                mapM
                    ( withObject "recorded purpose budget" $ \row -> do
                        purpose <- row .: "validator" >>= pointer
                        budget <-
                            row .: "budget"
                                >>= withObject
                                    "execution units"
                                    ( \b ->
                                        ExUnits <$> b .: "memory" <*> b .: "cpu"
                                    )
                        pure (purpose, Units budget)
                    )
                    values
            "script-failure" ->
                v .: "error"
                    >>= withObject
                        "recorded script failure aggregate"
                        ( \failure -> do
                            code <- failure .: "code" :: Parser Int
                            unless (code == 3010) (fail "RecordedErrorIsNotScriptEvaluation")
                            values <- failure .: "data"
                            mapM
                                ( withObject "recorded failed purpose" $ \row -> do
                                    purpose <- row .: "validator" >>= pointer
                                    outcome <-
                                        row .: "error"
                                            >>= withObject
                                                "validation failure"
                                                ( \err -> do
                                                    inner <- err .: "code" :: Parser Int
                                                    unless (inner == 3012) (fail "UnsupportedRecordedFailureKind")
                                                    err .: "data"
                                                        >>= withObject
                                                            "validation details"
                                                            ( \detail ->
                                                                ScriptFailure <$> detail .: "validationError" <*> detail .: "traces"
                                                            )
                                                )
                                    pure (purpose, outcome)
                                )
                                values
                        )
            _ -> fail "UnexpectedRecordedResponseIdentity"
        unless (not (null rows)) (fail "EmptyScriptEvaluationExtent")
        pure (Recorded rows)
      where
        pointer = withObject "script purpose" $ \v -> do
            kind <- v .: "purpose" :: Parser Text
            unless (kind == "mint") (fail "UnsupportedRecordedPurpose")
            ConwayMinting . AsIx <$> v .: "index"

readRecorded :: FilePath -> IO ByteString
readRecorded name =
    getDataFileName ("data/network/preprod/evaluation/" <> name)
        >>= BS.readFile

decodeJSON :: (FromJSON a) => ByteString -> IO a
decodeJSON = either fail pure . eitherDecodeStrict'

fixture
    :: IO
        ( EvaluationContext
        , [(TxIn, TxOut ConwayEra)]
        , ConwayTx
        , ConwayTx
        , Map.Map (ConwayPlutusPurpose AsIx ConwayEra) Answer
        , Map.Map (ConwayPlutusPurpose AsIx ConwayEra) Answer
        )
fixture = do
    Manifest identities <-
        readRecorded "evaluation-manifest.json" >>= decodeJSON
    forM_ identities $ \(RecordIdentity path expected) -> do
        unless
            (not (null path) && all (`notElem` path) ['/', '\\'])
            (fail "InvalidRecordedPath")
        actual <- readRecorded path
        unless
            (expected == convert (hash actual :: Digest SHA256))
            (fail ("RecordedEvaluationHashMismatch: " <> path))
    (manifest, genesis, history, _) <- loadNetworkFixture "preprod"
    context <-
        either
            (fail . show)
            pure
            (validateNetworkTime 1 manifest genesis history)
    recordedHistory <- readRecorded "era-history.cbor"
    recordedHistory `shouldBe` history
    parameters <- readRecorded "protocol-parameters.cbor" >>= decodeLedger
    inputs <- readRecorded "resolved-inputs.cbor" >>= decodeLedger
    success <- transaction "success.cbor"
    failure <- transaction "script-failure.cbor"
    Recorded successAnswer <-
        readRecorded "success.response.json" >>= decodeJSON
    Recorded failureAnswer <-
        readRecorded "script-failure.response.json" >>= decodeJSON
    pure
        ( EvaluationContext parameters context
        , inputs
        , success
        , failure
        , Map.fromList successAnswer
        , Map.fromList failureAnswer
        )
  where
    version = eraProtVerLow @ConwayEra
    decodeLedger bytes = either (fail . show) pure (decodeFull' version bytes)
    transaction name =
        readRecorded name
            >>= either (fail . show) pure
                . decodeFullAnnotator
                    version
                    "recorded non-submitted transaction"
                    decCBOR
                . LBS.fromStrict

observed
    :: EvaluateTxResult ConwayEra
    -> Map.Map (ConwayPlutusPurpose AsIx ConwayEra) Answer
observed = Map.map $ either failure Units
  where
    failure (ValidationFailure _ err traces _) = ScriptFailure (Text.pack (show (pretty err))) traces
    failure other = error ("UnexpectedLedgerFailureKind: " <> show other)

alterOutput :: (TxIn, TxOut ConwayEra) -> (TxIn, TxOut ConwayEra)
alterOutput (reference, output) =
    ( reference
    , output & datumTxOutL .~ mkInlineDatum (PLC.B (BS.replicate 1000 0x61))
    )

spec :: Spec
spec = describe "Local ledger evaluation from independent recorded context" $ do
    it
        "matches every recorded purpose's units and validation error/traces"
        $ do
            (ctx, inputs, success, failure, successAnswer, failureAnswer) <-
                fixture
            length inputs `shouldBe` 3
            success `shouldNotBe` failure
            let compareTx tx expected = do
                    result <- either (fail . show) pure (evaluateResolved ctx tx inputs)
                    Map.size result `shouldSatisfy` (> 0)
                    observed result `shouldBe` expected
            compareTx success successAnswer
            compareTx failure failureAnswer
    it
        "resolves the complete spent/collateral/reference extent in a pure monad"
        $ do
            (ctx, inputs, tx, _, expected, _) <- fixture
            let resolver refs = modify' (<> [refs]) >> pure inputs
                (result, calls) = runState (localEvaluation ctx resolver tx) []
            calls `shouldBe` [evaluationInputs tx]
            evaluationInputs tx `shouldBe` Set.fromList (map fst inputs)
            fmap observed result `shouldBe` Right expected
    it
        "names each missing input and every conflicting output before execution"
        $ do
            (ctx, inputs, tx, _, expected, _) <- fixture
            forM_ inputs $ \(reference, _) ->
                refusal
                    (evaluateResolved ctx tx (filter ((/= reference) . fst) inputs))
                    `shouldBe` Just (MissingEvaluationInputs (Set.singleton reference))
            case inputs of
                firstInput : _ -> do
                    refusal (evaluateResolved ctx tx (inputs <> [alterOutput firstInput]))
                        `shouldBe` Just (ConflictingEvaluationInput (fst firstInput))
                    fmap observed (evaluateResolved ctx tx (inputs <> [firstInput]))
                        `shouldBe` Right expected
                _ -> fail "EmptyRecordedInputExtent"
    it "detects actual spent-output and reference-output corruption" $ do
        (ctx, inputs, tx, _, expected, _) <- fixture
        forM_ [0, 2] $ \index -> do
            let changed =
                    [ if position == index then alterOutput item else item
                    | (position, item) <- zip [0 :: Int ..] inputs
                    ]
            changed `shouldNotBe` inputs
            fmap observed (evaluateResolved ctx tx changed)
                `shouldNotBe` Right expected
    it
        "detects a changed valid cost model on the same transaction and outputs"
        $ do
            (ctx, inputs, tx, _, expected, _) <- fixture
            let pp = evaluationParameters ctx
            models <-
                either (fail . show) pure $
                    Map.traverseWithKey
                        ( \language model -> mkCostModel language (map (+ 1) (getCostModelParams model))
                        )
                        (costModelsValid (pp ^. ppCostModelsL))
            let changed = pp & ppCostModelsL .~ mkCostModels models
            changed `shouldNotBe` pp
            fmap
                observed
                (evaluateResolved ctx{evaluationParameters = changed} tx inputs)
                `shouldNotBe` Right expected
    it
        "detects actual redeemer corruption as the recorded validation failure"
        $ do
            (ctx, inputs, tx, _, expected, failureAnswer) <- fixture
            let Redeemers redeemers = tx ^. witsTxL . rdmrsTxWitsL
                changed =
                    tx
                        & witsTxL . rdmrsTxWitsL
                            .~ Redeemers
                                (Map.map (\(_, units) -> (Data (PLC.I 43), units)) redeemers)
            changed `shouldNotBe` tx
            let answer = fmap observed (evaluateResolved ctx changed inputs)
            answer `shouldNotBe` Right expected
            answer `shouldBe` Right failureAnswer
  where
    refusal = either Just (const Nothing)
