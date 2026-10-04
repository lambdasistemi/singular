{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Main
Description : Read-only node inputs and independent time answers
License     : Apache-2.0

This recorder captures raw node data before the common services exist. It
never signs or submits a transaction. Generated devnet runs retain only public
genesis/configuration files; delegate keys stay in the generator's scratch.
-}
module Main (main) where

import Control.Concurrent.Async (withAsync)
import Control.Exception (ErrorCall, displayException, try)
import Control.Monad (forM, unless)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (toList)
import Data.Set qualified as Set
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import EvaluationFixture (captureFixtures)
import System.Directory
    ( copyFile
    , createDirectory
    , doesDirectoryExist
    )
import System.Environment (getEnv, lookupEnv)
import System.FilePath (takeDirectory, (</>))
import System.Process (callProcess)

import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (eraProtVerLow)
import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup (genesisDir)
import Cardano.Node.Client.N2C.Connection
    ( newLSQChannel
    , newLTxSChannel
    , runNodeClient
    )
import Cardano.Node.Client.N2C.LocalStateQuery
    ( queryAcquiredLSQ
    , withAcquiredLSQ
    )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.Provider qualified as Node
import Cardano.Node.Client.Types (Block)
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Slotting.Time (RelativeTime (..), SystemStart (..))
import Codec.Serialise
    ( DeserialiseFailure
    , deserialiseOrFail
    , serialise
    )
import Ouroboros.Consensus.Cardano.Block
    ( pattern QueryIfCurrentConway
    )
import Ouroboros.Consensus.HardFork.Combinator.Ledger.Query
    ( QueryHardFork (GetInterpreter)
    , pattern QueryHardFork
    )
import Ouroboros.Consensus.HardFork.History.Summary
    ( Bound (..)
    , EraEnd (..)
    , EraSummary (..)
    , Summary (..)
    )
import Ouroboros.Consensus.Ledger.Query
    ( Query (BlockQuery, GetChainPoint, GetSystemStart)
    )
import Ouroboros.Consensus.Shelley.Ledger.Query
    ( pattern GetCurrentPParams
    )
import Ouroboros.Network.Magic (NetworkMagic (..))

{- | Eight slots accommodate the seven historical Cardano eras and Dijkstra;
the raw list is checked separately to prevent the decoder truncating it.
-}
type RecordingEras = '[(), (), (), (), (), (), (), ()]

-- | Capture an authorised socket, or create a private generated devnet.
main :: IO ()
main = do
    output <- getEnv "LOCAL_SERVICES_OUTPUT"
    exists <- doesDirectoryExist output
    unless (not exists) (fail "RecordingAlreadyExists")
    createDirectory output
    fixture <- lookupEnv "LOCAL_SERVICES_FIXTURE_PARAMETERS"
    case fixture of
        Just parameters -> captureFixtures output parameters
        Nothing -> captureNode output

captureNode :: FilePath -> IO ()
captureNode output = do
    source <- lookupEnv "LOCAL_SERVICES_SOCKET"
    case source of
        Just sock -> do
            magic <- read <$> getEnv "LOCAL_SERVICES_NETWORK"
            capture output sock (NetworkMagic magic)
        Nothing -> do
            genesis <- genesisDir
            withCardanoNode genesis $ \sock _ -> do
                let generated = takeDirectory sock
                mapM_
                    (\name -> copyFile (generated </> name) (output </> name))
                    [ "byron-genesis.json"
                    , "shelley-genesis.json"
                    , "alonzo-genesis.json"
                    , "conway-genesis.json"
                    , "dijkstra-genesis.json"
                    , "node-config.json"
                    ]
                capture output sock (NetworkMagic 42)

capture :: FilePath -> FilePath -> NetworkMagic -> IO ()
capture output sock magic@(NetworkMagic networkMagic) = do
    channel <- newLSQChannel 16
    submit <- newLTxSChannel 16
    oracleChannel <- newLSQChannel 16
    oracleSubmit <- newLTxSChannel 16
    withAsync (runNodeClient magic sock channel submit) $ \_ -> do
        withAsync (runNodeClient magic sock oracleChannel oracleSubmit) $ \_ ->
            withAcquiredLSQ channel $ \handle ->
                Node.withAcquired (mkN2CProvider oracleChannel) $ \oracle -> do
                    let query :: Query Block a -> IO a
                        query = queryAcquiredLSQ handle
                    point <- query GetChainPoint
                    observed <- Node.queryLedgerSnapshotH oracle
                    unless
                        (Node.ledgerChainPoint observed == point)
                        (fail "SourcePointMoved: retry into a new recording directory")
                    (start, historyBytes, parameters) <- do
                        start <- query GetSystemStart
                        history <- query (BlockQuery (QueryHardFork GetInterpreter))
                        parameters <-
                            query (BlockQuery (QueryIfCurrentConway GetCurrentPParams))
                        pure (start, serialise history, parameters)
                    LBS.writeFile (output </> "era-history.cbor") historyBytes
                    case parameters of
                        Left _ -> fail "SourceEraMismatch"
                        Right pp ->
                            LBS.writeFile
                                (output </> "protocol-parameters.cbor")
                                (LBS.fromStrict (serialize' (eraProtVerLow @ConwayEra) pp))
                    eras <-
                        either
                            (fail . show)
                            pure
                            ( deserialiseOrFail historyBytes
                                :: Either DeserialiseFailure [EraSummary]
                            )
                    unless
                        (not (null eras) && length eras <= 8)
                        (fail "UnsupportedEraExtent")
                    summary <-
                        either
                            (fail . show)
                            pure
                            ( deserialiseOrFail historyBytes
                                :: Either DeserialiseFailure (Summary RecordingEras)
                            )
                    let SystemStart utcStart = start
                        startMs = floor (utcTimeToPOSIXSeconds utcStart * 1000) :: Integer
                        relativeMs bound = floor (getRelativeTime (boundTime bound) * 1000) :: Integer
                        boundaries =
                            map (relativeMs . eraStart) (toList (getSummary summary))
                                ++ [ relativeMs bound
                                   | EraSummary{eraEnd = EraEnd bound} <- take 1 (reverse eras)
                                   ]
                        samples =
                            concatMap
                                (\ms -> map (\delta -> startMs + ms + delta) [-1, 0, 1])
                                boundaries
                    answers <- forM samples $ \ms -> do
                        floorAnswer <- try @ErrorCall (Node.posixMsToSlotH oracle ms)
                        ceilAnswer <- try @ErrorCall (Node.posixMsCeilSlotH oracle ms)
                        pure $
                            object
                                [ "posixMs" .= ms
                                , "floor" .= answer floorAnswer
                                , "ceiling" .= answer ceilAnswer
                                ]
                    LBS.writeFile (output </> "node-time-answers.json") (encode answers)
                    let endBounds =
                            [bound | EraSummary{eraEnd = EraEnd bound} <- take 1 (reverse eras)]
                    case endBounds of
                        [horizon] -> do
                            let lastMs = startMs + relativeMs horizon
                                slots =
                                    Set.toAscList $
                                        Set.fromList $
                                            map (boundSlot . eraStart) eras
                                                ++ [boundSlot horizon - 1, boundSlot horizon]
                                findStart lo hi wanted
                                    | hi - lo <= 1 = pure hi
                                    | otherwise = do
                                        let middle = (lo + hi) `div` 2
                                        actual <- Node.posixMsToSlotH oracle middle
                                        if actual < wanted
                                            then findStart middle hi wanted
                                            else findStart lo middle wanted
                            starts <- forM slots $ \slot -> do
                                observedStart <- try @ErrorCall $ do
                                    if slot >= boundSlot horizon
                                        then do
                                            _ <- Node.posixMsToSlotH oracle lastMs
                                            fail "UnexpectedHorizonAnswer"
                                        else
                                            if slot == 0
                                                then pure startMs
                                                else findStart (startMs - 1) (lastMs - 1) slot
                                pure $
                                    object
                                        [ "slot" .= slot
                                        , "start"
                                            .= either
                                                (\failure -> object ["refused" .= displayException failure])
                                                (\ms -> object ["posixMs" .= ms])
                                                observedStart
                                        ]
                            LBS.writeFile (output </> "node-slot-starts.json") (encode starts)
                        _ -> fail "MissingFiniteHorizon"
                    LBS.writeFile (output </> "node-source.json") $
                        encode $
                            object
                                [ "networkMagic" .= networkMagic
                                , "point" .= show point
                                , "systemStartMs" .= startMs
                                , "eraCount" .= length eras
                                , "source"
                                    .= ( "cardano-node-clients 0e73121dc1df516b69d69bdd554b12bebd28d072"
                                            :: String
                                       )
                                ]
                    evaluations <- lookupEnv "LOCAL_SERVICES_EVALUATIONS"
                    case evaluations of
                        Nothing -> pure ()
                        Just fixturePath -> do
                            recordedParameters <-
                                LBS.readFile (fixturePath </> "protocol-parameters.cbor")
                            capturedParameters <-
                                LBS.readFile (output </> "protocol-parameters.cbor")
                            unless
                                (recordedParameters == capturedParameters)
                                (fail "EvaluationParametersChanged")
                            python <- getEnv "LOCAL_SERVICES_PYTHON"
                            script <- getEnv "LOCAL_SERVICES_EVALUATOR_RECORDER"
                            callProcess
                                python
                                [ script
                                , "--endpoint"
                                , "http://172.24.0.3:1337"
                                , "--source-id"
                                , "Ogmios v6.14 sha256:c6f4be21e8edc4c38cce80c6558bd8c38338f35ec5d0f186c62103e9e95e7202"
                                , "--fixtures"
                                , fixturePath
                                , "--context"
                                , output
                                , "--output"
                                , output </> "evaluation"
                                ]
                    putStrLn
                        ( "Recorded raw context and "
                            <> show (length answers)
                            <> " time comparisons"
                        )
  where
    answer :: Either ErrorCall SlotNo -> Value
    answer =
        either
            (\failure -> object ["refused" .= displayException failure])
            (\(SlotNo slot) -> object ["slot" .= slot])
