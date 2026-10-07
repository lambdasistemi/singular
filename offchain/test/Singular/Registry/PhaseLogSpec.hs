{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- The generic log keeps append/timestamp/concurrency and common-service
-- evidence. Actual raw constructor reads are reconciled independently against
-- its HTTP server and pinned-source callback. Atomic node/indexer point,
-- follower and installed-session tests retire with those mechanisms; they
-- are not passed claims about an Unbound provider.
module Singular.Registry.PhaseLogSpec (spec) where

import Cardano.Ledger.Alonzo.Plutus.Evaluate (evalTxExUnits)
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.Scripts.Data (Data (..))
import Cardano.Ledger.Api.Tx (mkBasicTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body (mintTxBodyL, mkBasicTxBody)
import Cardano.Ledger.Api.Tx.Wits
    ( Redeemers (..)
    , rdmrsTxWitsL
    , scriptTxWitsL
    )
import Cardano.Ledger.BaseTypes (SlotNo (..))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.State (UTxO (..))
import Cardano.Tx.Ledger (ConwayTx)
import Control.Concurrent.Async (mapConcurrently_)
import Control.Exception (ErrorCall (..), throwIO, try)
import Control.Monad (forM_, join, replicateM_, void)
import Data.Aeson ((.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Either (rights)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time
    ( UTCTime
    , addUTCTime
    , defaultTimeLocale
    , getCurrentTime
    , parseTimeM
    )
import Lens.Micro ((&), (.~))
import PlutusLedgerApi.V3 qualified as PLC
import Singular.PhaseLogFixture (logObjects, phaseLines, withLogFile)
import Singular.Registry.Blueprint (applyBytesParam)
import Singular.Registry.Evidence (Evidenced (..))
import Singular.Registry.Ledger (ConwayEra, PParams)
import Singular.Registry.LedgerProvider (Session (..))
import Singular.Registry.LocalEvaluation (EvaluateTxResult)
import Singular.Registry.NetworkTime
    ( networkEpochInfo
    , networkSystemStart
    )
import Singular.Registry.SessionIO qualified as Services
import Singular.Registry.StubSession
    ( stubSession
    , withParameters
    , withTime
    )
import Singular.Registry.SyntheticLedger
    ( unitProgram
    , withSyntheticCosts
    )
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.Trace (isoNow)
import Singular.Registry.TraceRender (appendPhaseLine, readPhaseLog)
import Singular.Registry.TxBuilder.BookingFixture (preprodParams)
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , scriptFromBytes
    )
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "the phase log of the generic read interface (#363)" $ do
    describe "the log file" $ do
        it
            "appends: lines already in the file stay byte for byte, \
            \and every line after them is one JSON object with ts and phase"
            $ withSystemTempDirectory "phase-log"
            $ \dir -> do
                let path = dir </> "phase.log"
                    existing = "{\"ts\":\"old\",\"phase\":\"old\"}\nnot json\n"
                BS.writeFile path existing
                appendPhaseLine path "first" []
                appendPhaseLine path "second" []
                raw <- BS.readFile path
                BS.take (BS.length existing) raw `shouldBe` existing
                let new = BC.lines (BS.drop (BS.length existing) raw)
                length new `shouldBe` 2
                objects <- either fail pure (traverse decodeObject new)
                map (field "phase") objects
                    `shouldBe` [Just ("first" :: Text), Just "second"]
                forM_ objects $ \o -> do
                    stamp <- maybe (fail "line without ts") pure (field "ts" o)
                    isIsoMillis stamp `shouldBe` True
        it
            "keeps one line per call when threads append at once"
            $ withSystemTempDirectory "phase-log"
            $ \dir -> do
                let path = dir </> "phase.log"
                    lg = path
                mapConcurrently_
                    ( \t ->
                        replicateM_
                            25
                            (appendPhaseLine lg "tick" [("thread", Aeson.toJSON (t :: Int))])
                    )
                    [1 .. 8]
                lines' <- logLines path
                length lines' `shouldBe` 200
                Map.elems
                    ( Map.fromListWith
                        (+)
                        [(field "thread" o :: Maybe Int, 1 :: Int) | o <- lines']
                    )
                    `shouldBe` replicate 8 25
        it "stamps ts from the clock, to the millisecond, in UTC" $
            withSystemTempDirectory "phase-log" $ \dir -> do
                let path = dir </> "phase.log"
                t0 <- getCurrentTime
                appendPhaseLine path "now" []
                t1 <- getCurrentTime
                [o] <- logLines path
                stamp <- maybe (fail "no ts") pure (field "ts" o)
                at <- maybe (fail "ts does not parse") pure (parseIso stamp)
                (at >= addUTCTime (-0.001) t0 && at <= t1) `shouldBe` True
                direct <- isoNow
                isIsoMillis direct `shouldBe` True

    -- Constructor HTTP/time log controls run in the retained Koios ProviderSpec.

    it
        "logs independently evaluated units for both redeemers and their total"
        $ withLogFile
        $ \path -> do
            let session =
                    withParameters
                        evaluationParameters
                        ( withTime
                            (pure syntheticTime)
                            stubSession{sessionTracer = readPhaseLog path}
                        )
            actual <- Services.evaluateTx session evaluationTx
            Map.map (either (Left . show) Right) actual
                `shouldBe` Map.map (either (Left . show) Right) evaluation
            let expected = rights (Map.elems evaluation)
                total f = sum (map (toInteger . f) expected)
            Map.size evaluation `shouldBe` 2
            length expected `shouldBe` 2
            expected
                `shouldSatisfy` all (\(ExUnits memory steps) -> memory > 0 && steps > 0)
            objects <- logObjects path
            let evals = phaseLines "eval" objects
                queries = phaseLines "query" objects
            map (field "redeemers") evals `shouldBe` [Just (2 :: Int)]
            map (field "failed") evals `shouldBe` [Just (0 :: Int)]
            map (field "mem") evals
                `shouldBe` [Just (total (\(ExUnits memory _) -> memory))]
            map (field "steps") evals
                `shouldBe` [Just (total (\(ExUnits _ steps) -> steps))]
            map (field "answer_size") queries
                `shouldBe` [Just (Map.size evaluation)]

    it
        "reconciles varied derived queries with actual raw context reads and answer sizes"
        $ withLogFile
        $ \path -> do
            counts <- newIORef (Map.empty :: Map.Map Text Int)
            let counted name result = do
                    atomicModifyIORef'
                        counts
                        (\previous -> (Map.insertWith (+) name (1 :: Int) previous, ()))
                    pure result
                session =
                    (withTime (counted "time" syntheticTime) stubSession)
                        { sessionTracer = readPhaseLog path
                        , protocolParameters =
                            counted "parameters" (Right (Evidenced evaluationParameters Nothing))
                        }
            replicateM_ 4 $ void (Services.evaluateTx session evaluationTx)
            Services.floorSlot session 5_000 `shouldReturn` SlotNo 5
            replicateM_
                5
                (Services.ceilingSlot session 5_001 `shouldReturn` SlotNo 6)
            replicateM_
                2
                (Services.slotStart session (SlotNo 2) `shouldReturn` 2_000)
            replicateM_
                3
                (Services.parameters session `shouldReturn` evaluationParameters)
            actual <- readIORef counts
            objects <- logObjects path
            let queries = phaseLines "query" objects
                named =
                    Map.fromListWith
                        (+)
                        [ (name, 1 :: Int)
                        | row <- queries
                        , Just name <- [field "query" row :: Maybe Text]
                        ]
                count name = Map.findWithDefault 0 name named
            Map.lookup "time" actual `shouldBe` Just (sum (Map.elems named))
            Map.lookup "parameters" actual
                `shouldBe` Just (count "evaluateTx" + count "protocolMajorGuard")
            Map.keys named
                `shouldBe` [ "evaluateTx"
                           , "posixMsCeilSlot"
                           , "posixMsToSlot"
                           , "protocolMajorGuard"
                           , "slotStart"
                           ]
            Map.elems named `shouldSatisfy` all (> 0)
            forM_ queries $ \row -> do
                isNumber "duration_ms" row `shouldBe` True
                let expectedSize =
                        if field "query" row == Just ("evaluateTx" :: Text)
                            then Map.size evaluation
                            else 1
                field "answer_size" row `shouldBe` Just expectedSize

    it
        "logs a failed common query once and rethrows its original exception without its text"
        $ withLogFile
        $ \path -> do
            let session =
                    withTime
                        (throwIO (ErrorCall "producer CRED-7f3a9"))
                        stubSession{sessionTracer = readPhaseLog path}
            result <- try (Services.floorSlot session 5_000)
            case result of
                Left failure -> show (failure :: ErrorCall) `shouldBe` "producer CRED-7f3a9"
                Right _ ->
                    expectationFailure "the common query swallowed its producer failure"
            objects <- logObjects path
            let queries = phaseLines "query" objects
            map (field "query") queries
                `shouldBe` [Just ("posixMsToSlot" :: Text)]
            map (field "outcome") queries `shouldBe` [Just ("failed" :: Text)]
            map (field "error_class") queries
                `shouldBe` [Just ("ErrorCall" :: Text)]
            BS.readFile path
                >>= (\bytes -> bytes `shouldNotSatisfy` BS.isInfixOf "CRED-7f3a9")

-- Two executable mint witnesses. The imported ledger supplies the independent
-- per-purpose result before either the common service or log aggregates it.
evaluation :: EvaluateTxResult ConwayEra
evaluation =
    evalTxExUnits
        evaluationParameters
        evaluationTx
        (UTxO Map.empty)
        (networkEpochInfo syntheticTime)
        (networkSystemStart syntheticTime)

evaluationParameters :: PParams ConwayEra
evaluationParameters = withSyntheticCosts preprodParams

evaluationTx :: ConwayTx
evaluationTx =
    let firstBytes = unitProgram 1
        secondBytes = applyBytesParam "phase-distinct-witness" (unitProgram 2)
        scripts =
            [ (computeScriptHash bytes, scriptFromBytes "synthetic-phase" bytes)
            | bytes <- [firstBytes, secondBytes]
            ]
        minted =
            MultiAsset
                ( Map.fromList
                    [ (PolicyID hash, Map.singleton (AssetName "phase") 1)
                    | (hash, _) <- scripts
                    ]
                )
        redeemers =
            Redeemers
                ( Map.fromList
                    [ (ConwayMinting (AsIx index), (Data (PLC.I 0), ExUnits 1 1))
                    | index <- [0, 1]
                    ]
                )
    in  mkBasicTx (mkBasicTxBody & mintTxBodyL .~ minted)
            & witsTxL . scriptTxWitsL .~ Map.fromList scripts
            & witsTxL . rdmrsTxWitsL .~ redeemers

decodeObject :: BS.ByteString -> Either String Aeson.Object
decodeObject = Aeson.eitherDecodeStrict'

-- | Every line of the log, each a JSON object.
logLines :: FilePath -> IO [Aeson.Object]
logLines path = do
    there <- doesFileExist path
    if not there
        then pure []
        else do
            raw <- BS.readFile path
            either fail pure (traverse decodeObject (BC.lines raw))

field :: (Aeson.FromJSON a) => Aeson.Key -> Aeson.Object -> Maybe a
field k o = join (Aeson.parseMaybe (.:? k) o)

-- | Whether the line carries this key as a JSON number.
isNumber :: Aeson.Key -> Aeson.Object -> Bool
isNumber k o = case field k o of
    Just (Aeson.Number _) -> True
    _ -> False

isIsoMillis :: Text -> Bool
isIsoMillis t =
    T.length t == 24
        && T.index t 10 == 'T'
        && T.index t 19 == '.'
        && T.last t == 'Z'
        && isJust (parseIso t)

parseIso :: Text -> Maybe UTCTime
parseIso =
    parseTimeM False defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" . T.unpack
