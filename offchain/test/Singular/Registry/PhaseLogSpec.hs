{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.Registry.PhaseLogSpec
Description : #363 — the opt-in phase log of the read interface
License     : Apache-2.0

'loggedProvider' is the one place the read interface is logged: every
acquisition of a view and every query read through it. These rows drive
a counting provider through it and compare the log with what the provider
itself counted, so a query that bypasses the log is a count that does not
match. Every compared value comes from the producer at run time: the
counts from the stub's own counters, the chain point from the view the
body is handed, the ex-units from an independent direct ledger evaluation.

'driveEveryQuery' matches the view's constructor positionally. Adding a
read to 'View' breaks that pattern at compile time. An independently
enumerated read census starts every read at zero and requires a reached call;
the log is compared with producer counts. A reached resolver bypass controls
that comparison. Raw node-call reconciliation is a separate extent below.
-}
module Singular.Registry.PhaseLogSpec (spec) where

import Control.Concurrent.Async (mapConcurrently_)
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM_, join, replicateM_, void)
import Data.Aeson ((.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.Either (rights)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (isInfixOf, sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time
    ( UTCTime
    , addUTCTime
    , defaultTimeLocale
    , getCurrentTime
    , parseTimeM
    )
import Singular.Registry.SyntheticTime (syntheticTime)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Alonzo.Plutus.Evaluate (evalTxExUnits)
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.PParams (emptyPParams)
import Cardano.Ledger.Api.Scripts.Data (Data (..))
import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body (mintTxBodyL, mkBasicTxBody)
import Cardano.Ledger.Api.Tx.Out (TxOut, mkBasicTxOut)
import Cardano.Ledger.Api.Tx.Wits
    ( Redeemers (..)
    , rdmrsTxWitsL
    , scriptTxWitsL
    )
import Cardano.Ledger.BaseTypes (Network (Testnet), SlotNo (..))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.State (UTxO (..))
import Cardano.Node.Client.Provider qualified as N2C
import Cardano.Node.Client.Submitter (Submitter (..))
import Cardano.Node.Client.UTxOIndexer.Indexer (applyAtSlot)
import Cardano.Node.Client.UTxOIndexer.Types qualified as Indexer
import Cardano.Tx.Ledger (ConwayTx)
import Lens.Micro ((&), (.~))
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras
    ( OneEraHash (..)
    )
import Ouroboros.Network.Block qualified as Chain
import Ouroboros.Network.Magic (NetworkMagic (..))
import PlutusLedgerApi.V3 qualified as PLC
import Singular.Registry.Blueprint (applyBytesParam)
import Singular.Registry.NetworkTime
    ( networkEpochInfo
    , networkSystemStart
    )
import Singular.Registry.Services qualified as Services
import Singular.Registry.SyntheticLedger
    ( unitProgram
    , withSyntheticCosts
    )

import Singular.PhaseLogFixture
    ( logObjects
    , phaseLines
    , queryNames
    , withLogFile
    )
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.IndexerRig
    ( Block (..)
    , Rig (..)
    , fullCoverage
    , opsOf
    , readinessOf
    , withRigAt
    )
import Singular.Registry.Ledger (Coin (..), ConwayEra, PParams, TxIn)
import Singular.Registry.Node (Wallet (..), loadWallet)
import Singular.Registry.Node.Indexer (Following (..), withFollowing)
import Singular.Registry.Node.Memory
    ( ChainState (..)
    , memoryProvider
    , mutate
    , newMemoryChain
    )
import Singular.Registry.Node.Options
    ( Backend (..)
    , ExternalNode (..)
    , NodeMode (..)
    )
import Singular.Registry.Node.PhaseLog
    ( isoNow
    , logPhase
    , loggedProvider
    , phaseLogAt
    )
import Singular.Registry.Node.Session
    ( NodeReads (..)
    , NodeSession (..)
    , assembleSession
    , followerStart
    , readsOf
    , serveSession
    )
import Singular.Registry.Node.View (nodeProvider)
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.RawNodeFixture
    ( recordingRawFixture
    , syntheticMaterial
    )
import Singular.Registry.StubView (stubView)
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , computeScriptHash
    , scriptFromBytes
    )

spec :: Spec
spec = describe "the phase log of the read interface (#363)" $ do
    describe "the log file" $ do
        it
            "appends: lines already in the file stay byte for byte, \
            \and every line after them is one JSON object with ts and phase"
            $ withSystemTempDirectory "phase-log"
            $ \dir -> do
                let path = dir </> "phase.log"
                    existing = "{\"ts\":\"old\",\"phase\":\"old\"}\nnot json\n"
                BS.writeFile path existing
                logPhase (phaseLogAt path) "first" []
                logPhase (phaseLogAt path) "second" []
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
                    lg = phaseLogAt path
                mapConcurrently_
                    ( \t ->
                        replicateM_
                            25
                            (logPhase lg "tick" [("thread", Aeson.toJSON (t :: Int))])
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
                logPhase (phaseLogAt path) "now" []
                t1 <- getCurrentTime
                [o] <- logLines path
                stamp <- maybe (fail "no ts") pure (field "ts" o)
                at <- maybe (fail "ts does not parse") pure (parseIso stamp)
                (at >= addUTCTime (-0.001) t0 && at <= t1) `shouldBe` True
                direct <- isoNow
                isIsoMillis direct `shouldBe` True

    describe "every query is one line" $ do
        it
            "names each query once per call, with its duration and its answer size, \
            \for every read of the view at several counts"
            $ withSystemTempDirectory "phase-log"
            $ \dir -> do
                let path = dir </> "phase.log"
                counters <- newCounters
                let prov = loggedProvider (phaseLogAt path) (countingProvider counters)
                Cage.withView prov driveEveryQuery
                counted <- readCounters counters
                lines' <- logLines path
                let queries = [o | o <- lines', field "phase" o == Just ("query" :: Text)]
                    named o = field "query" o :: Maybe Text
                -- the producer's own counts are the expectation
                Map.fromListWith
                    (+)
                    [(q, 1 :: Int) | Just q <- map named queries, q `elem` queryExtent]
                    `shouldBe` Map.fromList [(q, n) | (q, n) <- counted, q /= "acquire"]
                -- at n > 1 per query and distinct counts, a hand-count cannot coincide
                sort (map snd counted) `shouldNotBe` replicate (length counted) 1
                length (Set.fromList (map snd counted)) `shouldSatisfy` (> 1)
                forM_ queries $ \o -> do
                    isNumber "duration_ms" o `shouldBe` True
                    isNumber "answer_size" o `shouldBe` True
                let sizes q =
                        [ s
                        | o <- queries
                        , named o == Just q
                        , Just s <- [field "answer_size" o :: Maybe Int]
                        ]
                sizes "networkTime"
                    `shouldBe` replicate
                        (timeCalls + evaluateCalls + toSlotCalls + ceilCalls + startCalls)
                        1
                sizes "resolvedOutputs"
                    `shouldBe` replicate (resolvedCalls + evaluateCalls) 0
                map fst counted `shouldBe` sort ("acquire" : queryExtent)
                map snd counted `shouldSatisfy` all (> 0)
                sizes "utxosAt" `shouldBe` replicate utxosCalls utxoAnswer
                sizes "scriptRegistered" `shouldBe` replicate registeredCalls 1
                sizes "evaluateTx"
                    `shouldBe` replicate evaluateCalls (Map.size evaluation)
                sizes "posixMsToSlot" `shouldBe` replicate toSlotCalls 1
                sizes "posixMsCeilSlot" `shouldBe` replicate ceilCalls 1
                sizes "slotStart" `shouldBe` replicate startCalls 1
        it "detects a reached raw resolver read that bypasses its query log" $
            withSystemTempDirectory "phase-log" $ \dir -> do
                let path = dir </> "phase.log"
                counters <- newCounters
                let bare = countingProvider counters
                    wrapped = loggedProvider (phaseLogAt path) bare
                    bypass = Cage.Provider $ \action ->
                        Cage.withView bare $ \raw ->
                            Cage.withView wrapped $ \loggedView ->
                                action
                                    loggedView{Cage.viewResolvedOutputs = Cage.viewResolvedOutputs raw}
                Cage.withView bypass driveEveryQuery
                counted <- readCounters counters
                objects <- logLines path
                let actual =
                        Map.fromListWith
                            (+)
                            [ (name, 1 :: Int)
                            | object <- objects
                            , field "phase" object == Just ("query" :: Text)
                            , Just name <- [field "query" object :: Maybe Text]
                            , name `elem` queryExtent
                            ]
                    expected =
                        Map.fromList
                            [(name, calls) | (name, calls) <- counted, name /= "acquire"]
                lookup "resolvedOutputs" counted
                    `shouldBe` Just (resolvedCalls + evaluateCalls)
                Map.lookup "resolvedOutputs" actual `shouldBe` Nothing
                actual `shouldNotBe` expected
        it
            "gives the caller the same answers as the provider it wraps"
            $ withSystemTempDirectory "phase-log"
            $ \dir -> do
                counters <- newCounters
                let bare = countingProvider counters
                    wrapped = loggedProvider (phaseLogAt (dir </> "phase.log")) bare
                a <- Cage.withView bare (`Services.floorSlot` 5_000)
                b <- Cage.withView wrapped (`Services.floorSlot` 5_000)
                b `shouldBe` a
        it
            "still logs the query that failed, once, and throws what it threw; \
            \the failure's text is not in the log"
            $ withSystemTempDirectory "phase-log"
            $ \dir -> do
                let path = dir </> "phase.log"
                    failing =
                        Cage.Provider $ \act ->
                            act
                                stubView
                                    { Cage.viewUTxOsAt = \_ ->
                                        throwIO (userError "401 for project_id=CRED-7f3a9")
                                    }
                r <-
                    try @SomeException $
                        Cage.withView (loggedProvider (phaseLogAt path) failing) $ \v ->
                            void (Cage.viewUTxOsAt v (error "unused address"))
                r
                    `shouldSatisfy` either (("CRED-7f3a9" `isInfixOf`) . show) (const False)
                lines' <- logLines path
                let queries = [o | o <- lines', field "phase" o == Just ("query" :: Text)]
                map (field "query") queries `shouldBe` [Just ("utxosAt" :: Text)]
                map (field "outcome") queries `shouldBe` [Just ("failed" :: Text)]
                raw <- BS.readFile path
                BC.unpack raw `shouldNotSatisfy` ("CRED-7f3a9" `isInfixOf`)

    describe "every view acquisition names its chain point" $ do
        it
            "logs the slot and hash of the point the body was handed, and \
            \the duration, for each acquisition as the chain moves"
            $ withSystemTempDirectory "phase-log"
            $ \dir -> do
                let path = dir </> "phase.log"
                chain <- newMemoryChain memoryState
                mutate chain id
                let prov = loggedProvider (phaseLogAt path) (memoryProvider chain)
                    acquire = do
                        p <- Cage.withView prov (pure . Cage.viewPoint)
                        mutate chain id
                        pure p
                handed <- sequence [acquire, acquire, acquire]
                lines' <- logLines path
                let views = [o | o <- lines', field "phase" o == Just ("view" :: Text)]
                map (\o -> (field "slot" o, field "hash" o)) views
                    `shouldBe` [ ( Just (Cage.unSlotNo (Cage.cpSlot p))
                                 , Just (T.pack (BC.unpack (B16.encode (Cage.cpBlockHash p))))
                                 )
                               | p <- handed
                               ]
                length
                    ( Set.fromList
                        (map (field "slot" :: Aeson.Object -> Maybe Integer) views)
                    )
                    `shouldBe` 3
                forM_ views $ \o ->
                    isNumber "duration_ms" o `shouldBe` True
        it
            "logs how long each view was held, so a build that reads only a view is visible"
            $ withSystemTempDirectory "phase-log"
            $ \dir -> do
                let path = dir </> "phase.log"
                chain <- newMemoryChain memoryState
                mutate chain id
                let prov = loggedProvider (phaseLogAt path) (memoryProvider chain)
                replicateM_
                    2
                    (Cage.withView prov (\v -> void (Services.floorSlot v 1_000)))
                lines' <- logLines path
                let held = [o | o <- lines', field "phase" o == Just ("view-release" :: Text)]
                length held `shouldBe` 2
                forM_ held $ \o ->
                    isNumber "held_ms" o `shouldBe` True
        it
            "logs the ex-units of a script evaluation, per redeemer and in total"
            $ withSystemTempDirectory "phase-log"
            $ \dir -> do
                let path = dir </> "phase.log"
                    prov = loggedProvider (phaseLogAt path) evaluationProvider
                _ <- Cage.withView prov (`Services.evaluateTx` evaluationTx)
                lines' <- logLines path
                let evals = [o | o <- lines', field "phase" o == Just ("eval" :: Text)]
                    returned = rights (Map.elems evaluation)
                    total f = sum (map (fromIntegral . f) returned) :: Integer
                Map.size evaluation `shouldBe` 2
                length returned `shouldBe` Map.size evaluation
                returned
                    `shouldSatisfy` all (\(ExUnits memory steps) -> memory > 0 && steps > 0)
                map (field "redeemers") evals
                    `shouldBe` [Just (Map.size evaluation :: Int)]
                map (field "mem") evals `shouldBe` [Just (total exUnitsMem')]
                map (field "steps") evals `shouldBe` [Just (total exUnitsSteps')]
    describe "the whole query boundary" $ do
        it
            "every call the node was asked below the view is one query line: \
            \the log reconciles with what the node recorded, \
            \acquisition's own reads included"
            $ withLogFile
            $ \path -> do
                (node, asked) <- recordingNode
                let prov =
                        loggedProvider
                            (phaseLogAt path)
                            ( nodeProvider
                                (NetworkMagic 42)
                                syntheticMaterial
                                ( recordingRawFixture
                                    (\n -> atomicModifyIORef' asked (\m -> (m <> [n], ())))
                                    node
                                )
                            )
                replicateM_ 3 (Cage.withView prov driveEveryQuery)
                recorded <- readIORef asked
                objects <- logObjects path
                -- the node's own count is the expectation
                rawLogCounts objects `shouldBe` rawNodeCounts recorded
                length (filter (== "ledgerSnapshot") (queryNames objects))
                    `shouldBe` length (filter (== "h:queryLedgerSnapshot") recorded)
                length (filter (== "protocolParams") (queryNames objects))
                    `shouldBe` length (filter (== "h:queryProtocolParams") recorded)
                -- three acquisitions, so acquisition's reads are not a count of one
                length (filter (== "h:queryProtocolParams") recorded) `shouldBe` 3
                length (phaseLines "view" objects)
                    `shouldBe` length (filter (== "acquire") recorded)
        it
            "the session record logs its tip reads and hands out the logged \
            \provider, over what the command is handed"
            $ withLogFile
            $ \path -> do
                (node, asked) <- recordingNode
                let lg = phaseLogAt path
                    sess =
                        assembleSession
                            lg
                            (External (ExternalNode "node.socket" 42 "payment.skey"))
                            (NetworkMagic 42)
                            Testnet
                            evaluationProvider
                            (Submitter (\_ -> fail "no submission here"))
                            node
                _ <- nsTipSlot sess
                _ <- nsTipSlot sess
                _ <- nsTipSlot sess
                _ <-
                    Cage.withView (nsProvider sess) (`Services.evaluateTx` evaluationTx)
                recorded <- readIORef asked
                objects <- logObjects path
                length (filter (== "queryLedgerSnapshot") recorded) `shouldBe` 3
                length (filter (== "tipSlot") (queryNames objects)) `shouldBe` 3
                length (phaseLines "view" objects) `shouldBe` 1
                length (phaseLines "eval" objects) `shouldBe` 1
        it
            "the follower's start-point read is a ledgerSnapshot line when \
            \the node backend reads it, and no read at all under the index"
            $ withLogFile
            $ \path -> do
                (node, asked) <- recordingNode
                let lg = phaseLogAt path
                started <- followerStart lg NodeBackend node
                started `shouldSatisfy` isJust
                recorded <- readIORef asked
                recorded `shouldBe` ["queryLedgerSnapshot"]
                objects <- logObjects path
                queryNames objects `shouldBe` ["ledgerSnapshot"]
                -- the control: the index starts from the origin and asks nothing
                none <- followerStart lg IndexerBackend node
                none `shouldBe` Nothing
                readIORef asked >>= (`shouldBe` ["queryLedgerSnapshot"])
                logObjects path >>= (`shouldBe` 1) . length . queryNames
        it
            "a session over the node backend: every acquisition the node \
            \served is one view line, and every query one query line, from \
            \the connection to the last read"
            $ withLogFile
            $ \path -> withKeyFile $ \skey -> do
                (node, asked) <- recordingNode
                served <-
                    serveSession
                        (phaseLogAt path)
                        (pure 0)
                        Nothing
                        NodeBackend
                        (External (ExternalNode "node.socket" 42 skey))
                        (NetworkMagic 42)
                        "node.socket"
                        ( nodeProvider
                            (NetworkMagic 42)
                            syntheticMaterial
                            ( recordingRawFixture
                                (\n -> atomicModifyIORef' asked (\m -> (m <> [n], ())))
                                node
                            )
                        )
                        (node, Submitter (\_ -> fail "no submission here"))
                        $ \sess -> do
                            replicateM_ 2 (Cage.withView (nsProvider sess) driveEveryQuery)
                            nsTipSlot sess
                served `shouldBe` SlotNo 7
                reconcile path asked
        it
            "a session over the indexer backend: the acquisition that checks \
            \the wallet's coverage before the first view is a view line too"
            $ withLogFile
            $ \path -> withKeyFile $ \skey -> do
                wallet <- loadWallet 42 skey
                let owned =
                        [
                            ( outRef 'a'
                            , mkBasicTxOut (walletAddr wallet) (MaryValue (Coin 3_000_000) mempty)
                            )
                        ,
                            ( outRef 'b'
                            , mkBasicTxOut (walletAddr wallet) (MaryValue (Coin 4_000_000) mempty)
                            )
                        ]
                (node, asked) <- recordingNodeWith owned
                withRigAt 42 memoryState fullCoverage $ \rig -> do
                    -- the index holds the outputs the node does, at the node's point
                    applyAtSlot
                        (rigFollower rig)
                        (Indexer.SlotNo 7)
                        (Indexer.BlockHash (BS.replicate 32 0xab))
                        (opsOf (Block{spends = [], creates = owned}))
                    withFollowing
                        Following
                            { followingIndexer = rigFollower rig
                            , followingGate = rigGate rig
                            , followingReadiness = readinessOf rig
                            }
                        $ void
                        $ serveSession
                            (phaseLogAt path)
                            (pure 0)
                            Nothing
                            IndexerBackend
                            (External (ExternalNode "node.socket" 42 skey))
                            (NetworkMagic 42)
                            "node.socket"
                            ( nodeProvider
                                (NetworkMagic 42)
                                syntheticMaterial
                                ( recordingRawFixture
                                    (\n -> atomicModifyIORef' asked (\m -> (m <> [n], ())))
                                    node
                                )
                            )
                            (node, Submitter (\_ -> fail "no submission here"))
                        $ \sess ->
                            replicateM_ 2 $
                                Cage.withView (nsProvider sess) (`Cage.viewUTxOsAt` walletAddr wallet)
                reconcile path asked
                -- the coverage check and the two reads: three acquisitions
                readIORef asked >>= (`shouldBe` 3) . length . filter (== "acquire")
        it "a key-free reader's provider is the logged one" $
            withLogFile $ \path -> do
                counters <- newCounters
                let reads' = readsOf (phaseLogAt path) (countingProvider counters)
                Cage.withView (nrProvider reads') driveEveryQuery
                counted <- readCounters counters
                objects <- logObjects path
                length [name | name <- queryNames objects, name `elem` queryExtent]
                    `shouldBe` sum [n | (q, n) <- counted, q /= "acquire"]
                length (phaseLines "view" objects) `shouldBe` 1
  where
    exUnitsMem' (ExUnits m _) = m
    exUnitsSteps' (ExUnits _ s) = s

-- ---------------------------------------------------------
-- The counting provider
-- ---------------------------------------------------------

utxosCalls
    , registeredCalls
    , evaluateCalls
    , toSlotCalls
    , ceilCalls
    , timeCalls
    , resolvedCalls
    , startCalls
        :: Int
utxosCalls = 3
registeredCalls = 2
evaluateCalls = 4
toSlotCalls = 1
ceilCalls = 5
timeCalls = 6
resolvedCalls = 7
startCalls = 2

-- | What the stub answers an address read with: three outputs.
utxoAnswer :: Int
utxoAnswer = 3

{- | Two executable mint witnesses, in a non-submitted synthetic context.
Expected per-purpose units are computed by the imported ledger directly,
independently of both Services.evaluateTx and its phase aggregation.
-}
evaluation :: Cage.EvaluateTxResult ConwayEra
evaluation =
    evalTxExUnits
        evaluationParameters
        evaluationTx
        (UTxO Map.empty)
        (networkEpochInfo syntheticTime)
        (networkSystemStart syntheticTime)

evaluationParameters :: PParams ConwayEra
evaluationParameters = withSyntheticCosts emptyPParams

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

type Counters = IORef [(Text, Int)]

newCounters :: IO Counters
-- The independently enumerated read extent starts at zero, so an omitted
-- read remains observable even when neither the driver nor log calls it.
queryExtent :: [Text]
queryExtent = ["networkTime", "resolvedOutputs", "utxosAt", "scriptRegistered"]
newCounters = newIORef [(name, 0) | name <- queryExtent]

bump :: Counters -> Text -> IO ()
bump c q = atomicModifyIORef' c $ \m -> (m <> [(q, 1)], ())

-- | The producer's count per query name, including acquisitions.
readCounters :: Counters -> IO [(Text, Int)]
readCounters c = Map.toList . Map.fromListWith (+) <$> readIORef c

{- | A provider counting each acquisition and each read, in its own
counters, answering with fixed sizes.
-}
countingProvider :: Counters -> Cage.Provider IO
countingProvider c = Cage.Provider $ \act -> do
    bump c "acquire"
    act
        stubView
            { Cage.viewProtocolParams = evaluationParameters
            , Cage.viewTimeContext = bump c "networkTime" >> pure syntheticTime
            , Cage.viewResolvedOutputs = \_ -> bump c "resolvedOutputs" >> pure []
            , Cage.viewUTxOsAt = \_ -> do
                bump c "utxosAt"
                pure [(outRef ch, out) | ch <- take utxoAnswer "abc"]
            , Cage.viewScriptRegistered = \_ -> bump c "scriptRegistered" >> pure True
            }
  where
    out = mkBasicTxOut (error "address unused") (MaryValue (Coin 1) mempty)

evaluationProvider :: Cage.Provider IO
evaluationProvider = Cage.Provider $ \action ->
    action
        stubView
            { Cage.viewProtocolParams = evaluationParameters
            , Cage.viewTimeContext = pure syntheticTime
            , Cage.viewResolvedOutputs = const (pure [])
            }

{- | Call every read of a view, each a different number of times. The
positional pattern fails to compile when the view gains a read.
-}
driveEveryQuery :: Cage.View IO -> IO ()
driveEveryQuery view@(Cage.View _point _params time resolved _log utxos registered) = do
    replicateM_ timeCalls (void time)
    replicateM_ resolvedCalls (void (resolved Set.empty))
    replicateM_ utxosCalls (void (utxos payer))
    replicateM_ registeredCalls (void (registered credential))
    replicateM_
        evaluateCalls
        (void (Services.evaluateTx view evaluationTx))
    replicateM_ toSlotCalls (void (Services.floorSlot view 1_000))
    replicateM_ ceilCalls (void (Services.ceilingSlot view 1_000))
    replicateM_ startCalls (void (Services.slotStart view (SlotNo 1)))

-- | An address and a script credential every read can be given.
payer :: Addr
payer = addrFromKeyHashBytes Testnet (BS.replicate 28 0x5a)

credential :: ScriptHash
credential = computeScriptHash (SBS.toShort (BS.replicate 16 0x01))

{- | An upstream node client that records the name of every query it is
asked, below the view (@h:@ for a query through the acquired handle) and
around it, and answers a fixed chain. Acquisition itself is not a query
and is not recorded.
-}
recordingNode :: IO (N2C.Provider IO, IORef [Text])
recordingNode = recordingNodeWith [(outRef 'a', out), (outRef 'b', out)]
  where
    out = mkBasicTxOut payer (MaryValue (Coin 1) mempty)

{- | The recording node, answering an address read with these outputs. Every
acquisition is recorded as @acquire@, apart from the queries.
-}
recordingNodeWith
    :: [(TxIn, TxOut ConwayEra)] -> IO (N2C.Provider IO, IORef [Text])
recordingNodeWith held = do
    asked <- newIORef []
    let note :: Text -> IO ()
        note n = atomicModifyIORef' asked (\m -> (m <> [n], ()))
        unused n = note n >> fail (T.unpack n <> " is not read by a command")
        snapshot =
            N2C.LedgerSnapshot
                { N2C.ledgerCurrentEra = "Conway"
                , N2C.ledgerChainPoint = point
                , N2C.ledgerTipSlot = SlotNo 7
                , N2C.ledgerEpoch = N2C.EpochNo 0
                }
        point =
            Chain.BlockPoint
                (SlotNo 7)
                (OneEraHash (SBS.toShort (BS.replicate 32 0xab)))
        handle =
            N2C.mkQueryHandle
                N2C.QueryHandleBackend
                    { N2C.backendQueryUTxOs = \_ ->
                        note "h:queryUTxOs" >> pure held
                    , N2C.backendQueryUTxOsAt = \_ -> unused "h:queryUTxOsAt"
                    , N2C.backendQueryUTxOByTxIn = \_ -> note "h:queryUTxOByTxIn" >> pure Map.empty
                    , N2C.backendQueryProtocolParams =
                        note "h:queryProtocolParams" >> pure evaluationParameters
                    , N2C.backendQueryLedgerSnapshot =
                        note "h:queryLedgerSnapshot" >> pure snapshot
                    , N2C.backendQueryStakeRewards = \s ->
                        note "h:queryStakeRewards" >> pure (Map.fromSet (const (Coin 0)) s)
                    , N2C.backendQueryRewardAccounts = \_ -> unused "h:queryRewardAccounts"
                    , N2C.backendQueryVoteDelegatees = \_ -> unused "h:queryVoteDelegatees"
                    , N2C.backendQueryTreasury = unused "h:queryTreasury"
                    , N2C.backendQueryGovernanceState = unused "h:queryGovernanceState"
                    , N2C.backendEvaluateTx = \_ -> unused "h:evaluateTx"
                    , N2C.backendPosixMsToSlot = \_ -> unused "h:posixMsToSlot"
                    , N2C.backendPosixMsCeilSlot = \_ -> unused "h:posixMsCeilSlot"
                    }
        node =
            N2C.Provider
                { N2C.withAcquired = \k -> note "acquire" >> k handle
                , N2C.queryUTxOs = \_ -> unused "queryUTxOs"
                , N2C.queryUTxOByTxIn = \_ -> unused "queryUTxOByTxIn"
                , N2C.queryProtocolParams = unused "queryProtocolParams"
                , N2C.queryLedgerSnapshot = note "queryLedgerSnapshot" >> pure snapshot
                , N2C.queryStakeRewards = \_ -> unused "queryStakeRewards"
                , N2C.queryRewardAccounts = \_ -> unused "queryRewardAccounts"
                , N2C.queryVoteDelegatees = \_ -> unused "queryVoteDelegatees"
                , N2C.queryTreasury = unused "queryTreasury"
                , N2C.queryGovernanceState = unused "queryGovernanceState"
                , N2C.evaluateTx = \_ -> unused "evaluateTx"
                , N2C.posixMsToSlot = \_ -> unused "posixMsToSlot"
                , N2C.posixMsCeilSlot = \_ -> unused "posixMsCeilSlot"
                , N2C.queryUpperBoundSlot = \_ -> unused "queryUpperBoundSlot"
                }
    pure (node, asked)

{- | The log against the node's own record: one view line for each
acquisition the node served, one query line for each query it answered.
-}

{- | Raw live node calls, excluding cached context and common computations.
Unknown producer reads fail rather than silently dropping from the extent.
-}
rawNodeCounts :: [Text] -> Map.Map Text Int
rawNodeCounts recorded =
    Map.fromListWith
        (+)
        [(named readName, 1) | readName <- recorded, readName /= "acquire"]
  where
    named "h:queryLedgerSnapshot" = "ledgerSnapshot"
    named "h:queryProtocolParams" = "protocolParams"
    named "h:systemStart" = "systemStart"
    named "h:eraHistory" = "eraHistory"
    named "h:queryUTxOs" = "utxosAt"
    named "h:queryUTxOByTxIn" = "resolvedOutputs"
    named "h:queryStakeRewards" = "scriptRegistered"
    named "queryLedgerSnapshot" = "tipSlot"
    named other = error ("unmapped live node read: " <> T.unpack other)

rawLogCounts :: [Aeson.Object] -> Map.Map Text Int
rawLogCounts objects =
    Map.fromListWith
        (+)
        [ (name, 1)
        | object <- objects
        , field "phase" object == Just ("query" :: Text)
        , Just name <- [field "query" object :: Maybe Text]
        , name
            `notElem` [ "networkTime"
                      , "evaluateTx"
                      , "posixMsToSlot"
                      , "posixMsCeilSlot"
                      , "slotStart"
                      , "indexedUTxOs"
                      ]
        ]

reconcile :: FilePath -> IORef [Text] -> Expectation
reconcile path asked = do
    recorded <- readIORef asked
    objects <- logObjects path
    length (phaseLines "view" objects)
        `shouldBe` length (filter (== "acquire") recorded)
    -- Address reads may be supplied by the indexer in this session row;
    -- complete node-backend extent is checked separately above.
    let nodeOwned name =
            name
                `elem` [ "ledgerSnapshot"
                       , "protocolParams"
                       , "systemStart"
                       , "eraHistory"
                       , "tipSlot"
                       ]
    Map.filterWithKey (\name _ -> nodeOwned name) (rawLogCounts objects)
        `shouldBe` Map.filterWithKey (\name _ -> nodeOwned name) (rawNodeCounts recorded)

-- | A signing-key file the wallet loads, for the length of an action.
withKeyFile :: (FilePath -> IO a) -> IO a
withKeyFile k = withSystemTempDirectory "phase-key" $ \dir -> do
    let skey = dir </> "payment.skey"
    BS.writeFile skey (B16.encode (BC.replicate 32 'w'))
    k skey

memoryState :: ChainState
memoryState =
    ChainState
        { csNetwork = 42
        , csEra = "Conway"
        , csTip = Nothing
        , csPParams = emptyPParams
        , csUTxO = Map.empty
        , csRegistered = Set.empty
        , csNetworkTime = syntheticTime
        }

outRef :: Char -> TxIn
outRef c =
    either (error . ("outRef: " <>)) id $
        parseOutRef (T.pack (replicate 64 c <> "#0"))

-- ---------------------------------------------------------
-- Reading the log
-- ---------------------------------------------------------

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
