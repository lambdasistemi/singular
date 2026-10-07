{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

{- |
Module      : Singular.Registry.ContractNode
Description : Private generated and external sources for the shipping HTTP contract
License     : Apache-2.0

The generated leg owns a private node-backed HTTP facade. The external leg
receives a URL, pinned time source and funded wallet, and starts no source.
Only an independent private oracle receives a probe socket. Its second LSQ
connection obtains full outputs independently of the facade's server and the
shipping provider. Payments retain a fresh funded key, another thread, the
original amount and fee, and the original two-minute observation bound.

Original atomic-view, connection-guard and index-log requirements are
published unsupported. Generic session evidence is separately worded.
-}
module Singular.Registry.ContractNode
    ( Leg (..)
    , providerHarness
    , phaseLogOnDevnet
    , guardOnDevnet
    ) where

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (coinTxOutL, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Core (eraProtVerHigh)
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.State (UTxO (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Node.Client.E2E.Setup
    ( genesisAddr
    , genesisDir
    , genesisSignKey
    )
import Cardano.Node.Client.N2C.Connection
    ( newLSQChannel
    , newLTxSChannel
    , runNodeClient
    )
import Cardano.Node.Client.N2C.LocalStateQuery
    ( queryAcquiredLSQ
    , withAcquiredLSQ
    )
import Cardano.Node.Client.N2C.Types (LSQChannel)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (link, wait, withAsync)
import Control.Exception
    ( SomeException
    , displayException
    , finally
    , throwIO
    , try
    )
import Control.Monad (forM_, unless, void)
import Data.Aeson
    ( Value (..)
    , eitherDecodeStrict'
    , encode
    , object
    , (.=)
    )
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.ByteString.Short qualified as SBS
import Data.List (isInfixOf, sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Unique (hashUnique, newUnique)
import Lens.Micro ((&), (.~), (^.))
import Ouroboros.Consensus.Cardano.Block
    ( pattern QueryIfCurrentConway
    )
import Ouroboros.Consensus.Cardano.Node ()
import Ouroboros.Consensus.Ledger.Query
    ( Query (BlockQuery, GetChainPoint)
    )
import Ouroboros.Consensus.Protocol.Praos.Header ()
import Ouroboros.Consensus.Shelley.Ledger.NetworkProtocolVersion ()
import Ouroboros.Consensus.Shelley.Ledger.Query
    ( pattern GetUTxOByAddress
    )
import Ouroboros.Consensus.Shelley.Ledger.SupportsProtocol ()
import Ouroboros.Network.Magic (NetworkMagic (..))
import Singular.PhaseLogFixture
    ( logObjects
    , numberField
    , phaseLines
    , textField
    , withLogFile
    )
import Singular.Provider.Koios.Wire qualified as Wire
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.ContractSuite
    ( AdapterHarness (..)
    , Chain (..)
    , EvidenceClass (..)
    )
import Singular.Registry.Evidence
    ( NoWitness
    , SessionBinding (..)
    , SessionId (..)
    )
import Singular.Registry.Ledger (Coin (..), ConwayEra)
import Singular.Registry.LedgerProvider (Outputs, SubmitResult (..))
import Singular.Registry.Private.Facade
    ( Facade (..)
    , GenesisFunding (..)
    , withGeneratedFacade
    )
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.SessionEvidence (FactRecord (..))
import Singular.Registry.SessionIO qualified as Services
import Singular.Registry.Signing (SignedTx, signTx, signedTx)
import Singular.Registry.Terminal (withReads, withWrites)
import Singular.Registry.TraceRender (backendPhaseLog)
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , computeScriptHash
    )
import Singular.Registry.Wallet (Wallet (..), loadWallet)
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Random.Stateful (globalStdGen, uniformByteStringM)
import System.Timeout (timeout)
import Test.Hspec

-- | The private oracle socket is separate from all shipping settings.
data Leg = Generated | Outside ProviderSettings FilePath FilePath

providerHarness :: Leg -> AdapterHarness
providerHarness leg =
    AdapterHarness
        { ahAdapter = "shared HTTP (" <> legName <> " devnet)"
        , ahEvidence = DevNet
        , ahNotSupported = Map.empty
        , ahChain = \action -> case leg of
            Generated -> withGenerated $ \settings socket wallet ->
                sessionChain settings socket wallet action
            Outside settings socket key -> do
                wallet <- loadWallet (providerMagic settings) key
                sessionChain settings socket wallet action
        }
  where
    legName = case leg of
        Generated -> "generated"
        Outside{} -> "external"

sessionChain
    :: ProviderSettings -> FilePath -> Wallet -> (Chain -> IO a) -> IO a
sessionChain settings socket wallet action =
    withIndependentConnection settings socket $ \oracle -> do
        watched <- freshAddress
        unregistered <- freshScriptHash
        withWrites mempty mempty settings wallet $ \caps ->
            keepEvidence caps $
                let (network, provider) = capReads caps
                in  action
                        Chain
                            { chProvider = provider
                            , chNetwork = network
                            , chWatched = watched
                            , chUnregistered = unregistered
                            , chChange = payAside oracle wallet watched caps
                            , chIndependentOutputs = independentOutputs oracle watched
                            }

-- | A second private connection, never handed to the shipping capabilities.
withIndependentConnection
    :: ProviderSettings -> FilePath -> (LSQChannel -> IO a) -> IO a
withIndependentConnection settings socket action = do
    oracle <- newLSQChannel 16
    unusedSubmit <- newLTxSChannel 16
    withAsync
        ( runNodeClient
            (NetworkMagic (providerMagic settings))
            socket
            oracle
            unusedSubmit
            >>= either
                throwIO
                (const (fail "contract: independent source connection closed"))
        )
        $ \connection -> do
            link connection
            action oracle

{- | Read full address outputs directly, without the facade's source helper.
The recorded private point describes the oracle, not a provider binding.
-}
independentOutputs :: LSQChannel -> Addr -> IO Outputs
independentOutputs oracle address = withAcquiredLSQ oracle $ \handle -> do
    point <- queryAcquiredLSQ handle GetChainPoint
    found <-
        queryAcquiredLSQ
            handle
            ( BlockQuery
                (QueryIfCurrentConway (GetUTxOByAddress (Set.singleton address)))
            )
    UTxO outputs <-
        either
            (const (fail "contract: independent output oracle is not in Conway"))
            pure
            found
    keepValue
        "contract-independent-outputs"
        ( object
            [ "privateSource" .= ("separate LSQ connection" :: String)
            , "point" .= show point
            , "address" .= show address
            , "outputs"
                .= [ object
                        [ "reference" .= show reference
                        , "bytes"
                            .= decodeUtf8
                                (B16.encode (serialize' (eraProtVerHigh @ConwayEra) output))
                        ]
                   | (reference, output) <- Map.toAscList outputs
                   ]
            ]
        )
    pure (Map.toAscList outputs)

-- | Pay from another thread; observe the actual identity and complete outputs.
payAside
    :: LSQChannel -> Wallet -> Addr -> Capabilities NoWitness IO -> IO ()
payAside oracle wallet to caps = withAsync go wait
  where
    go = do
        previous <- independentOutputs oracle to
        transaction <- payment oracle wallet to 2_000_000
        submitPayment caps transaction
        observeWithin "payment" $ do
            current <- independentOutputs oracle to
            let identity = txIdTx (signedTx transaction)
                isPayment (TxIn actual _, _) = actual == identity
            -- Full output comparison in ContractSuite is the independent oracle;
            -- this wait merely establishes that the change has landed.
            pure (length current > length previous && any isPayment current)

payment :: LSQChannel -> Wallet -> Addr -> Integer -> IO SignedTx
payment oracle wallet to lovelace = do
    heldOutputs <- independentOutputs oracle (walletAddr wallet)
    (reference, output) <- case sortOn (Down . (^. coinTxOutL) . snd) heldOutputs of
        pair : _ -> pure pair
        [] -> fail "contract: the funded key holds nothing"
    let fee = 1_000_000
        Coin held = output ^. coinTxOutL
        change = held - lovelace - fee
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton reference
                & outputsTxBodyL
                    .~ StrictSeq.fromList
                        [ mkBasicTxOut to (MaryValue (Coin lovelace) mempty)
                        , mkBasicTxOut (walletAddr wallet) (MaryValue (Coin change) mempty)
                        ]
                & feeTxBodyL .~ Coin fee
    unless (change > 1_000_000) $
        fail "contract: the funded key's largest output cannot pay"
    pure (signTx (walletSignKey wallet) (mkBasicTx body))

submitPayment :: Capabilities NoWitness IO -> SignedTx -> IO ()
submitPayment caps transaction =
    capSubmit caps transaction >>= \case
        SubmitAccepted identity ->
            unless
                (identity == txIdTx (signedTx transaction))
                (fail "contract: accepted payment identity differs from signed body")
        SubmitRefused reason -> fail ("contract: payment rejected: " <> show reason)
        SubmitFailed reason -> fail ("contract: payment transport failed: " <> show reason)
        SubmitWrongNetwork configured wanted ->
            fail
                ( "contract: payment network differs: configured="
                    <> show configured
                    <> "; requested="
                    <> show wanted
                )

observeWithin :: String -> IO Bool -> IO ()
observeWithin what observed = do
    let poll = observed >>= \found -> unless found (threadDelay 200_000 >> poll)
    timeout 120_000_000 poll
        >>= maybe
            (fail ("contract: " <> what <> " did not land within two minutes"))
            pure

withGenerated
    :: (ProviderSettings -> FilePath -> Wallet -> IO a) -> IO a
withGenerated action = do
    directory <- genesisDir
    withGeneratedFacade
        FundGenesis
        directory
        (keepValue "contract-independent-facade-source")
        $ \_ facade ->
            withSystemTempDirectory "contract-key" $ \keyDirectory -> do
                let key = keyDirectory </> "funded.skey"
                    genesisWallet = Wallet genesisAddr genesisSignKey Testnet
                    settings = facadeSettings facade
                    socket = facadeSocket facade
                BS.writeFile key . B16.encode =<< uniformByteStringM 32 globalStdGen
                funded <- loadWallet (providerMagic settings) key
                withIndependentConnection settings socket $ \oracle ->
                    withWrites mempty mempty settings genesisWallet $ \caps -> keepEvidence caps $ do
                        transaction <-
                            payment oracle genesisWallet (walletAddr funded) 1_000_000_000
                        submitPayment caps transaction
                        observeWithin
                            "funding"
                            (not . null <$> independentOutputs oracle (walletAddr funded))
                action settings socket funded

freshAddress :: IO Addr
freshAddress = addrFromKeyHashBytes Testnet <$> uniformByteStringM 28 globalStdGen

freshScriptHash :: IO ScriptHash
freshScriptHash =
    computeScriptHash . SBS.toShort <$> uniformByteStringM 16 globalStdGen

-- | Preserve actual constructor evidence on success and assertion failure.
keepEvidence :: Capabilities NoWitness IO -> IO a -> IO a
keepEvidence caps action = finally action $ do
    facts <- capFacts caps
    trace <- capTrace caps
    keepValue
        "contract-actual-provider-evidence"
        (object ["facts" .= facts, "rawSources" .= trace])

-- | The existing opt-in private fixture evidence root; never writes keys.
keepValue :: String -> Value -> IO ()
keepValue label value =
    lookupEnv "SINGULAR_PROVIDER_CONTROL_EVIDENCE" >>= \case
        Nothing -> pure ()
        Just root -> do
            identity <- hashUnique <$> newUnique
            createDirectoryIfMissing True root
            LBS.writeFile
                (root </> (label <> "-" <> show identity <> ".json"))
                (encode value <> "\n")

-- | The original named guard is retired, not asserted as a generic success.
guardOnDevnet :: Spec
guardOnDevnet =
    describe
        "no node call inside a view by another route, on a generated devnet node (#326)"
        $ it
            "a one-shot query and a submission inside a view fail as NodeCallInView; outside the view the query answers and the node accepts the submission"
        $ pendingWith
            "NodeCallInView and the installed node session are retired. The separately worded generic contract checks ReleasedSession."

phaseLogOnDevnet :: Spec
phaseLogOnDevnet =
    describe
        "the phase log of the sessions a command opens, on a generated devnet node (#363)"
        $ do
            it
                "a write session logs how long it took to open, each view it acquires and each read and tip read through it"
                $ pendingWith
                    "The installed node write session and atomic-view query schema are retired. Generic shipping HTTP logging is exercised separately."
            it "a key-free reader, as preview opens one, logs its views and reads" $
                pendingWith
                    "The node reader's view and derived-query schema are retired. Generic shipping HTTP logging is exercised separately."
            it "the indexer backend logs the index's admission and its reads" $
                pendingWith
                    "The indexer backend and indexAdmit schema are retired without a replacement index."
            it
                "the shipping write capability reconciles every acquired Unbound scope, raw query and release with its trace, including startup parameter and time reads"
                $ withGenerated
                $ \settings socket wallet ->
                    withIndependentConnection settings socket $ \oracle ->
                        withLogFile $ \path -> do
                            (answer, trace, facts) <- withWrites (backendPhaseLog path) mempty settings wallet $ \caps ->
                                keepEvidence caps $ do
                                    answer <- Services.withLatest (capReads caps) $ \session -> do
                                        actual <- Services.outputsAt session (walletAddr wallet)
                                        expected <- independentOutputs oracle (walletAddr wallet)
                                        shouldBe actual expected
                                        void (Services.tip session)
                                        pure actual
                                    trace <- capTrace caps
                                    facts <- capFacts caps
                                    pure (answer, trace, facts)
                            shouldSatisfy answer (not . null)
                            checkExtent path trace facts "cli_protocol_params"
            it
                "the shipping key-free reader reconciles every raw time and parameter query and released Unbound scope with its trace"
                $ withGenerated
                $ \settings _ _ ->
                    withLogFile $ \path -> do
                        (trace, facts) <- withReads (backendPhaseLog path) mempty settings $ \caps -> keepEvidence caps $ do
                            Services.withLatest (capReads caps) $ \session -> do
                                start <- Services.slotStart session 0
                                converted <- Services.floorSlot session start
                                shouldBe converted 0
                            (,) <$> capTrace caps <*> capFacts caps
                        checkExtent path trace facts "network-time"
  where
    -- These assertions belong to the two existing cases, not another gate.
    -- Expected rows and counts come only from the actual constructor trace.
    checkExtent path trace facts omittedQuery = do
        let traced kind =
                [ row
                | Object row <- trace
                , KeyMap.lookup "kind" row == Just (String kind)
                ]
        openingIds <- mapM (requiredText "session") (traced "acquire")
        closingIds <- mapM (requiredText "session") (traced "release")
        shouldSatisfy openingIds (not . null)
        shouldBe closingIds openingIds
        shouldBe (Set.size (Set.fromList openingIds)) (length openingIds)
        expected <-
            mapM
                rawRead
                [ row
                | Object row <- trace
                , KeyMap.lookup "kind" row == Just (String "raw-exchange")
                    || KeyMap.lookup "kind" row == Just (String "raw-time")
                ]
        shouldSatisfy expected (not . null)
        shouldSatisfy facts (not . null)
        forM_ facts $ \fact -> do
            let SessionId identity = factSession fact
            shouldSatisfy identity (`elem` openingIds)
            shouldBe (factBinding fact) Unbound
            shouldBe (factVerdict fact) "Unverified"
            shouldBe (factReason fact) (Just "NoVerifierConfigured")
            shouldBe (factWitnessPresent fact) False
        let assertRecords records = do
                shouldBe
                    (map (textField "session") (phaseLines "view" records))
                    (map Just openingIds)
                shouldBe
                    (map (textField "session") (phaseLines "view-release" records))
                    (map Just closingIds)
                forM_ (phaseLines "view" records) $ \row -> do
                    shouldBe (textField "binding" row) (Just "Unbound")
                    case KeyMap.lookup "duration_ms" row of
                        Just (Number elapsed) -> shouldSatisfy elapsed (>= 0)
                        _ -> expectationFailure "scope acquisition lacks numeric duration_ms"
                forM_ (phaseLines "view-release" records) $ \row ->
                    case KeyMap.lookup "held_ms" row of
                        Just (Number elapsed) -> shouldSatisfy elapsed (>= 0)
                        _ -> expectationFailure "scope release lacks numeric held_ms"
                let queries = phaseLines "query" records
                    actual =
                        [ ( textField "session" row
                          , textField "query" row
                          , numberField "answer_size" row
                          , numberField "answer_bytes" row
                          )
                        | row <- queries
                        , KeyMap.member "session" row
                        ]
                unless (actual == expected) $
                    expectationFailure omissionMessage
                forM_ queries $ \row ->
                    case KeyMap.lookup "duration_ms" row of
                        Just (Number elapsed) -> shouldSatisfy elapsed (>= 0)
                        _ -> expectationFailure "raw query lacks numeric duration_ms"
        positive <- logObjects path
        assertRecords positive
        -- Reach the real, completed phase-log boundary. Remove one actual
        -- parameter/time query line, re-read it with the same log reader,
        -- and require this same extent assertion to reject that omission.
        original <- BS.readFile path
        decoded <-
            mapM (either fail pure . eitherDecodeStrict') (BC.lines original)
        let isOmitted (Object fields) =
                KeyMap.lookup "phase" fields == Just (String "query")
                    && KeyMap.lookup "query" fields == Just (String omittedQuery)
            isOmitted _ = False
            (prefix, remainder) = break (isOmitted . snd) (zip (BC.lines original) decoded)
        case remainder of
            [] ->
                expectationFailure
                    "the omission control did not reach an actual query record"
            _removed : suffix ->
                finally
                    ( do
                        BS.writeFile path (BC.unlines (map fst (prefix <> suffix)))
                        mutated <- logObjects path
                        shouldBe (length mutated) (length positive - 1)
                        result <- try @SomeException (assertRecords mutated)
                        case result of
                            Left failure ->
                                shouldSatisfy (displayException failure) (isInfixOf omissionMessage)
                            Right () ->
                                expectationFailure
                                    "the extent assertion accepted an omitted actual query record"
                    )
                    (BS.writeFile path original)

    omissionMessage =
        "actual phase query records differ from the constructor's complete raw-read trace"

    requiredText field row = case KeyMap.lookup field row of
        Just (String value) -> pure value
        _ -> fail ("actual trace lacks text field " <> show field)

    rawRead row = do
        identity <- requiredText "session" row
        (query, body, bytes) <- case KeyMap.lookup "kind" row of
            Just (String "raw-time") -> pure ("network-time", Object row, Nothing)
            Just (String "raw-exchange") -> do
                query <- requiredText "call" row
                result <- case KeyMap.lookup "result" row of
                    Just (Object fields) -> pure fields
                    _ -> fail "actual HTTP trace lacks a result object"
                encoded <- requiredText "bodyHex" result
                bytes <- either fail pure (B16.decode (encodeUtf8 encoded))
                parsed <- either (fail . show) pure (Wire.parseBody bytes)
                pure (query, parsed, Just (toInteger (BS.length bytes)))
            _ -> fail "the trace row is not an actual successful raw read"
        let cardinality = case body of
                Array rows -> toInteger (length rows)
                Object _ -> 1
                _ -> 0
        pure (Just identity, Just query, Just cardinality, bytes)
