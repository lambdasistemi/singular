{-# LANGUAGE DataKinds #-}

{- | CI/test-only Koios facade over a generated ledger. Every read is from
LSQ or the full-block source archive. The server imports no terminal receipt,
registry interpretation or acceptance oracle. Only this private composition
receives a node socket; its clients use the normal shared HTTP/client/Wire.
-}
module Singular.Registry.Private.Facade
    ( Facade (..)
    , GenesisFunding (..)
    , withGeneratedFacade
    ) where

import Cardano.Chain.Common (decodeAddressBase58)
import Cardano.Chain.Slotting (EpochSlots (..))
import Cardano.Ledger.Address
    ( AccountAddress (..)
    , AccountId (..)
    , Addr (..)
    , BootstrapAddress (..)
    , serialiseAddr
    )
import Cardano.Ledger.Alonzo.Scripts
    ( plutusScriptBinary
    , plutusScriptLanguage
    , toPlutusScript
    )
import Cardano.Ledger.Api.PParams (ppProtocolVersionL)
import Cardano.Ledger.Api.Tx (mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , datumTxOutL
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( EpochNo (..)
    , ProtVer (..)
    , TxIx (..)
    )
import Cardano.Ledger.Binary
    ( DecoderError
    , decCBOR
    , decodeFullAnnotator
    , getVersion
    , serialize'
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (eraProtVerHigh, hashScript)
import Cardano.Ledger.Hashes (originalBytes)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.Plutus.Data (Datum (..), binaryDataToData)
import Cardano.Ledger.Plutus.Language
    ( Language (..)
    , PlutusBinary (..)
    )
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup (genesisAddr, genesisSignKey)
import Cardano.Node.Client.N2C.ChainSync
    ( Fetched (..)
    , HeaderPoint
    , mkChainSyncN2C
    , runChainSyncN2C
    )
import Cardano.Node.Client.N2C.Connection
    ( newLSQChannel
    , newLTxSChannel
    , runNodeClient
    )
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
import Cardano.Node.Client.N2C.Types (LSQChannel, LTxSChannel)
import Cardano.Node.Client.Submitter qualified as Node
import Cardano.Node.Client.Types (Block)
import Cardano.Slotting.EpochInfo (epochInfoEpoch)
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)
import ChainFollower
    ( Follower (..)
    , Intersector (..)
    , ProgressOrRewind (..)
    )
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (link, withAsync)
import Control.Exception (throwIO)
import Control.Monad (unless, void, when)
import Control.Monad qualified
import Control.Tracer (nullTracer)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson
    ( FromJSON
    , Key
    , Value (..)
    , eitherDecodeStrict'
    , encode
    , object
    , toJSON
    , withObject
    , (.:)
    , (.=)
    )
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.ByteString.Short qualified as SBS
import Data.CaseInsensitive qualified as CI
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe.Strict (StrictMaybe (..))
import Data.Sequence.Strict qualified as Seq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8)
import Data.Word (Word64)
import Lens.Micro ((&), (.~), (^.))
import Network.HTTP.Types
    ( HeaderName
    , Status
    , status200
    , status400
    , status404
    , statusCode
    )
import Network.HTTP.Types.URI (parseQueryText)
import Network.Wai
    ( Application
    , Request
    , rawPathInfo
    , rawQueryString
    , requestHeaders
    , requestMethod
    , responseLBS
    , strictRequestBody
    )
import Network.Wai.Handler.Warp (testWithApplication)
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras
    ( OneEraHash (..)
    )
import Ouroboros.Network.Block qualified as Chain
import Ouroboros.Network.Magic (NetworkMagic (..))
import Ouroboros.Network.Point qualified as Point
import Singular.Provider.Koios.Wire qualified as Wire
import Singular.Registry.NetworkTime
    ( NetworkTime
    , generatedNetworkTime
    , networkEpochInfo
    , slotStartMs
    )
import Singular.Registry.Private.Archive
import Singular.Registry.Private.EpochParameters (epochParameters)
import Singular.Registry.Private.Source
import Singular.Registry.Private.TimePublication (publishTime)
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.Signing (signTx, signedTx)
import Singular.Registry.Wait (tryOutcome)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))
import System.Timeout (timeout)
import Text.Read (readMaybe)

data Facade = Facade
    { facadeSettings :: ProviderSettings
    , facadeSources :: IO [Value]
    , facadeArchive :: IO Archive
    , facadeSocket :: FilePath
    -- ^ Private independent probes only; never part of ProviderSettings.
    }

{- | Only the private source actor's funding action changes for the retained
genesis-only coverage control. The ledger/node/time parameters stay identical.
-}
data GenesisFunding = FundGenesis | LeaveGenesis
    deriving stock (Eq, Show)

data Server = Server
    { serverLSQ :: LSQChannel
    , serverSubmit :: LTxSChannel
    , serverArchive :: IORef Archive
    , serverLog :: IORef [Value]
    , serverGenesis :: ByteString
    , serverGenesisOutputs :: Map.Map TxIn (TxOut ConwayEra)
    , serverTimeRoot :: FilePath
    , serverObserver :: Value -> IO ()
    }

withGeneratedFacade
    :: GenesisFunding
    -> FilePath
    -> (Value -> IO ())
    -> (Integer -> Facade -> IO a)
    -> IO a
withGeneratedFacade funding genesisDirectory observer action =
    withCardanoNode genesisDirectory $ \socket startMs -> do
        lsq <- newLSQChannel 16
        submit <- newLTxSChannel 16
        withAsync
            (closedConnection =<< runNodeClient (NetworkMagic 42) socket lsq submit)
            $ \connection -> do
                link connection
                initial <- withinStartup (readLedgerSource lsq)
                genesis <-
                    BS.readFile (takeDirectory socket </> "shelley-genesis.json")
                byron <- BS.readFile (takeDirectory socket </> "byron-genesis.json")
                byronValue <- either fail pure (eitherDecodeStrict' byron)
                security <-
                    parsed
                        ( withObject
                            "Byron genesis"
                            ( \value ->
                                value .: "protocolConsts"
                                    >>= withObject "Byron protocol constants" (.: "k")
                            )
                        )
                        byronValue
                unless
                    ( (security :: Integer) > 0
                        && security <= toInteger (maxBound :: Word64) `div` 10
                    )
                    (fail "private facade unsupported Byron security parameter")
                let epochSlots = EpochSlots (fromInteger (security * 10))
                let initialEvent =
                        object
                            [ "kind" .= ("initial-genesis-ledger" :: Text)
                            , "genesisBytes" .= hex genesis
                            , "byronGenesisBytes" .= hex byron
                            , "source" .= sourceValue initial
                            ]
                observer initialEvent
                validateGenesisUTxO genesis byron initial
                archive <- newIORef (emptyArchive (sourceOutputs initial))
                events <- newIORef [initialEvent]
                let timeRoot = takeDirectory socket </> "facade-time"
                    server =
                        Server
                            lsq
                            submit
                            archive
                            events
                            genesis
                            (sourceOutputs initial)
                            timeRoot
                            observer
                createDirectoryIfMissing True timeRoot
                void (publishTime timeRoot genesis (timeFactsOf initial))
                withAsync
                    ( closedConnection
                        =<< runChainSyncN2C
                            epochSlots
                            (NetworkMagic 42)
                            socket
                            ( mkChainSyncN2C
                                nullTracer
                                nullTracer
                                (intersector server)
                                [Chain.GenesisPoint]
                            )
                    )
                    $ \follower -> do
                        link follower
                        withinStartup (awaitArchive server initial)
                        when (funding == FundGenesis) (bootstrapGenesis server)
                        testWithApplication (pure (application server)) $ \port ->
                            action
                                startMs
                                Facade
                                    { facadeSettings =
                                        ProviderSettings
                                            ("http://127.0.0.1:" <> show port <> "/api/v1")
                                            42
                                            Nothing
                                            (Just (timeRoot </> "current"))
                                    , facadeSources = reverse <$> readIORef events
                                    , facadeArchive = readIORef archive
                                    , facadeSocket = socket
                                    }
  where
    closedConnection =
        either
            throwIO
            (const (fail "private facade source connection closed"))

{- | The genesis allocation has no transaction CBOR. Convert it to actual
confirmed outputs before commands start, through an independent private
actor. The full-block follower observes this transaction itself; no fake
genesis transaction is inserted into tx_info or tx_cbor.
-}
bootstrapGenesis :: Server -> IO ()
bootstrapGenesis server = withinStartup $ do
    let owned =
            Map.filter
                ((== genesisAddr) . (^. addrTxOutL))
                (serverGenesisOutputs server)
        originals = Map.toAscList owned
        total =
            sum
                [ amount
                | (_, output) <- originals
                , let MaryValue (Coin amount) _ = output ^. valueTxOutL
                ]
        fee = 2_000_000
        half = (total - fee) `div` 2
        fundingOutput amount =
            mkBasicTxOut
                genesisAddr
                (MaryValue (Coin amount) (MultiAsset Map.empty))
        transaction =
            signedTx
                ( signTx
                    genesisSignKey
                    ( mkBasicTx
                        ( mkBasicTxBody
                            & inputsTxBodyL .~ Map.keysSet owned
                            & outputsTxBodyL
                                .~ Seq.fromList [fundingOutput half, fundingOutput (total - fee - half)]
                            & feeTxBodyL .~ Coin fee
                        )
                    )
                )
        identity = txIdTx transaction
    result <-
        Node.submitTx (mkN2CSubmitter (serverSubmit server)) transaction
    case result of
        Node.Rejected reason -> fail ("private genesis funding refused: " <> BC.unpack reason)
        Node.Submitted actual ->
            unless
                (actual == identity)
                (fail "private genesis funding identity mismatch")
    record
        server
        ( object
            [ "kind" .= ("independent-private-funding-actor" :: Text)
            , "transactionId" .= Wire.txIdHex identity
            , "transactionCBOR"
                .= hex (serialize' (eraProtVerHigh @ConwayEra) transaction)
            ]
        )
    let await = do
            archive <- readIORef (serverArchive server)
            current <- readLedgerSource (serverLSQ server)
            let recorded =
                    any
                        ((== identity) . archivedId)
                        [ tx | block <- archiveBlocks archive, tx <- archivedTransactions block
                        ]
                live =
                    all
                        (`Map.member` sourceOutputs current)
                        [TxIn identity (TxIx 0), TxIn identity (TxIx 1)]
            if recorded && live then pure () else threadDelay 20_000 >> await
    await

withinStartup :: IO a -> IO a
withinStartup action =
    timeout 300_000_000 action
        >>= maybe (fail "private facade startup bound expired") pure

awaitArchive :: Server -> LedgerSource -> IO ()
awaitArchive server initial = do
    blocks <- archiveBlocks <$> readIORef (serverArchive server)
    let wanted = case Chain.pointSlot (sourcePoint initial) of
            Point.Origin -> SlotNo 0
            Point.At slot -> slot
    if any ((>= wanted) . archivedSlot) blocks
        then pure ()
        else threadDelay 20_000 >> awaitArchive server initial

intersector :: Server -> Intersector HeaderPoint SlotNo Fetched
intersector server = scope
  where
    scope =
        Intersector
            { intersectFound = \point -> do
                updateArchive server (rollbackArchive point)
                pure follow
            , intersectNotFound = pure (scope, [Chain.GenesisPoint])
            }
    follow =
        Follower
            { rollForward = \fetched _ -> do
                updateArchive server (appendFetched fetched)
                source <- readTimeSourceFacts (serverLSQ server)
                void
                    (publishTime (serverTimeRoot server) (serverGenesis server) source)
                blocks <- archiveBlocks <$> readIORef (serverArchive server)
                case reverse blocks of
                    block : _ ->
                        record
                            server
                            ( object
                                [ "kind" .= ("chain-sync-full-block" :: Text)
                                , "block" .= blockValue block
                                , "timeSource" .= timeSourceValue source
                                ]
                            )
                    [] -> fail "private facade: missing appended block"
                pure follow
            , rollBackward = \point -> do
                updateArchive server (rollbackArchive point)
                record
                    server
                    ( object
                        ["kind" .= ("chain-sync-rollback" :: Text), "point" .= show point]
                    )
                pure (Progress follow)
            }

updateArchive
    :: Server -> (Archive -> Either ArchiveFailure Archive) -> IO ()
updateArchive server change = do
    result <- atomicModifyIORef' (serverArchive server) $ \archive -> case change archive of
        Left failure -> (archive, Left failure)
        Right updated -> (updated, Right ())
    either throwIO pure result

-- The new private node admits no transaction until the HTTP callback starts.
-- Check the initial source against the generated genesis before following
-- from origin; a pre-spent or invented seed cannot enter this archive.
validateGenesisUTxO
    :: ByteString -> ByteString -> LedgerSource -> IO ()
validateGenesisUTxO genesis byron source = do
    value <- either fail pure (eitherDecodeStrict' genesis)
    shelleyFunds <-
        parsed (withObject "generated genesis" (.: "initialFunds")) value
    byronValue <- either fail pure (eitherDecodeStrict' byron)
    byronFunds <-
        parsed
            (withObject "generated Byron genesis" (.: "nonAvvmBalances"))
            byronValue
    initialByron <-
        traverse
            ( \(address, amount) -> do
                decoded <- either (fail . show) pure (decodeAddressBase58 address)
                quantity <-
                    maybe
                        (fail "invalid Byron genesis allocation")
                        pure
                        (readMaybe (Text.unpack amount))
                pure
                    ( hex (serialiseAddr (AddrBootstrap (BootstrapAddress decoded)))
                    , quantity
                    )
            )
            (Map.toAscList (byronFunds :: Map.Map Text Text))
    let expected =
            Map.union
                (shelleyFunds :: Map.Map Text Integer)
                (Map.fromList initialByron)
    let outputs = Map.elems (sourceOutputs source)
        actual =
            Map.fromList
                [ (hex (serialiseAddr (output ^. addrTxOutL)), amount)
                | output <- outputs
                , let MaryValue (Coin amount) _ = output ^. valueTxOutL
                ]
        plain output = case ( output ^. valueTxOutL
                            , output ^. datumTxOutL
                            , output ^. referenceScriptTxOutL
                            ) of
            (MaryValue _ (MultiAsset assets), NoDatum, SNothing) -> Map.null assets
            _ -> False
    unless
        ( actual == expected
            && length outputs == Map.size actual
            && all plain outputs
        )
        ( fail
            ( "private facade initial UTxO differs from generated genesis: expected="
                <> show expected
                <> "; actual="
                <> show actual
            )
        )

application :: Server -> Application
application server request reply = do
    body <- LBS.toStrict <$> strictRequestBody request
    outcome <- tryOutcome (answer server request body)
    let (status, headers, bytes, source) = case outcome of
            Right result -> result
            Left failure ->
                ( status400
                , []
                , encode (object ["sourceFailure" .= show failure])
                , Null
                )
        event =
            object
                [ "kind" .= ("http-ledger-exchange" :: Text)
                , "method" .= decodeUtf8 (requestMethod request)
                , "path" .= decodeUtf8 (rawPathInfo request)
                , "query" .= decodeUtf8 (rawQueryString request)
                , "publicRequestHeaders"
                    .= [ (decodeUtf8 (CI.original key), decodeUtf8 value)
                       | (key, value) <- requestHeaders request
                       , key `notElem` ["authorization", "cookie"]
                       ]
                , "requestBytes" .= hex body
                , "requestSha256" .= digest body
                , "status" .= statusCode status
                , "declaredResponseHeaders"
                    .= [ (decodeUtf8 (CI.original key), decodeUtf8 value)
                       | (key, value) <- ("content-type", "application/json") : headers
                       ]
                , "responseBytes" .= hex (LBS.toStrict bytes)
                , "responseSha256" .= digest (LBS.toStrict bytes)
                , "source" .= source
                , "sourceSha256" .= digest (LBS.toStrict (encode source))
                ]
    record server event
    reply
        ( responseLBS
            status
            (("content-type", "application/json") : headers)
            bytes
        )

answer
    :: Server
    -> Request
    -> ByteString
    -> IO (Status, [(HeaderName, ByteString)], LBS.ByteString, Value)
answer server request body
    | rawPathInfo request == "/api/v1/submittx"
    , requestMethod request == "POST" = do
        transaction <-
            either
                (fail . show)
                pure
                ( decodeFullAnnotator
                    (eraProtVerHigh @ConwayEra)
                    "private submitted Conway transaction"
                    decCBOR
                    (LBS.fromStrict body)
                    :: Either DecoderError ConwayTx
                )
        result <-
            Node.submitTx (mkN2CSubmitter (serverSubmit server)) transaction
        let (status, value) = case result of
                Node.Submitted identity -> (status200, toJSON (Wire.txIdHex identity))
                Node.Rejected reason -> (status400, toJSON (decodeUtf8 reason))
        pure
            ( status
            , []
            , encode value
            , object
                [ "kind" .= ("actual-node-submission" :: Text)
                , "transactionId" .= Wire.txIdHex (txIdTx transaction)
                , "transactionCBOR" .= hex body
                , "result" .= value
                ]
            )
    | requestMethod request == "POST"
    , rawPathInfo request
        `elem` ["/api/v1/tx_info", "/api/v1/tx_cbor", "/api/v1/tx_status"] =
        answerArchive server request body
    | requestMethod request == "POST"
    , rawPathInfo request
        `elem` ["/api/v1/address_utxos", "/api/v1/asset_utxos"] =
        answerOutputs server request body
    | otherwise = do
        source <- readLedgerSource (serverLSQ server)
        archive <- readIORef (serverArchive server)
        context <-
            either
                throwIO
                pure
                ( generatedNetworkTime
                    42
                    (getVersion (pvMajor (sourceParameters source ^. ppProtocolVersionL)))
                    "private HTTP LSQ"
                    (serverGenesis server)
                    (sourceEraHistory source)
                )
        let json value = pure (status200, [], encode value, sourceValue source)
            archiveRows blocks =
                rowsFrom
                    ( object
                        [ "ledger" .= sourceValue source
                        , "blocks"
                            .= map
                                blockValue
                                ( Map.elems
                                    (Map.fromList [(archivedHeight block, block) | block <- blocks])
                                )
                        ]
                    )
            rowsFrom origin values = do
                (headers, value) <- paged request values
                pure
                    ( status200
                    , headers
                    , encode value
                    , origin
                    )
            material =
                [ (block, tx)
                | block <- archiveBlocks archive
                , tx <- archivedTransactions block
                ]
        case (requestMethod request, rawPathInfo request) of
            ("GET", "/api/v1/tip") -> case (sourcePoint source, sourceBlockNo source) of
                ( point@(Chain.BlockPoint slot _)
                    , Point.At (Chain.BlockNo height)
                    ) -> do
                        let EpochNo epoch = sourceEpoch source
                        header <- pointHash point
                        milliseconds <-
                            either throwIO pure (slotStartMs context slot)
                        json
                            ( toJSON
                                [ object
                                    [ "abs_slot" .= slot
                                    , "hash" .= header
                                    , "block_height" .= height
                                    , "epoch_no" .= epoch
                                    , "block_time" .= (milliseconds `div` 1000)
                                    ]
                                ]
                            )
                _ -> fail "private facade raw ledger has no actual block"
            ("GET", "/api/v1/cli_protocol_params") -> json (toJSON (sourceParameters source))
            ("GET", "/api/v1/epoch_params") -> do
                selected <- requiredQuery "_epoch_no" request
                let EpochNo epoch = sourceEpoch source
                unless
                    (readMaybe (Text.unpack selected) == Just epoch)
                    (fail "private facade has no historical epoch parameters")
                json (toJSON [epochParameters (sourceParameters source)])
            ("GET", "/api/v1/asset_txs") -> do
                policy <- requiredQuery "_asset_policy" request
                name <- requiredQuery "_asset_name" request
                values <-
                    traverse
                        ( \(block, tx) -> do
                            epoch <- epochFor context (archivedSlot block)
                            pure
                                ( object
                                    [ "tx_hash" .= Wire.txIdHex (archivedId tx)
                                    , "block_height" .= archivedHeight block
                                    , "epoch_no" .= epoch
                                    ]
                                )
                        )
                        ( sortOn
                            (\(block, tx) -> (archivedHeight block, Wire.txIdHex (archivedId tx)))
                            [ (block, tx)
                            | (block, tx) <- material
                            , any
                                (\output -> matchesAsset output [policy, name])
                                (Map.elems (archivedInputs tx) <> map snd (archivedBodyOutputs tx))
                            ]
                        )
                archiveRows (archiveBlocks archive) values
            ("POST", "/api/v1/account_info") -> do
                asked <- jsonField "_stake_addresses" body
                accounts <-
                    traverse
                        (either (fail . Text.unpack) pure . Wire.parseRewardAccount)
                        (asked :: [Text])
                (registrationPoint, registrations) <-
                    readRegistrations
                        (serverLSQ server)
                        ( Set.fromList
                            [credential | AccountAddress _ (AccountId credential) <- accounts]
                        )
                let value =
                        toJSON
                            [ object
                                [ "stake_address" .= Wire.renderRewardAccount account
                                , "status"
                                    .= ( if Map.member credential registrations
                                            then "registered"
                                            else "not registered" :: Text
                                       )
                                ]
                            | account@(AccountAddress _ (AccountId credential)) <- accounts
                            ]
                pure
                    ( status200
                    , []
                    , encode value
                    , object
                        [ "ledger" .= sourceValue source
                        , "registrationPoint" .= show registrationPoint
                        , "registrationCredentials"
                            .= [ show credential | AccountAddress _ (AccountId credential) <- accounts
                               ]
                        , "registrationRewards"
                            .= [ (show credential, reward)
                               | (credential, reward) <- Map.toAscList registrations
                               ]
                        ]
                    )
            _ ->
                pure
                    ( status404
                    , []
                    , encode ("private facade endpoint is not mapped" :: Text)
                    , Null
                    )

genesisReference :: TxIn -> Text
genesisReference (TxIn identity (TxIx index)) =
    Wire.txIdHex identity <> "#" <> Text.pack (show index)

-- | Keep current-output provenance to the actual acquired point and UTxO.
answerOutputs
    :: Server
    -> Request
    -> ByteString
    -> IO (Status, [(HeaderName, ByteString)], LBS.ByteString, Value)
answerOutputs server request body = do
    (source, extent) <- case rawPathInfo request of
        "/api/v1/address_utxos" -> do
            names <- jsonField "_addresses" body
            addresses <-
                traverse
                    (either (fail . Text.unpack) pure . Wire.parseAddress)
                    (names :: [Text])
            source <-
                readAddressOutputSourceFacts
                    (serverLSQ server)
                    (Set.fromList addresses)
            pure
                ( source
                , object ["query" .= ("GetUTxOByAddress" :: Text), "addresses" .= names]
                )
        "/api/v1/asset_utxos" -> do
            source <- readOutputSourceFacts (serverLSQ server)
            pure (source, object ["query" .= ("GetUTxOWhole" :: Text)])
        _ -> fail "private facade output endpoint is not mapped"
    let outputs = Map.toAscList (outputSourceOutputs source)
    selected <- case rawPathInfo request of
        "/api/v1/address_utxos" -> do
            addresses <- jsonField "_addresses" body
            pure
                [ (reference, output)
                | (reference, output) <- outputs
                , Wire.renderAddress (output ^. addrTxOutL) `elem` (addresses :: [Text])
                ]
        "/api/v1/asset_utxos" -> do
            assets <- jsonField "_asset_list" body
            pure
                [ (reference, output)
                | (reference, output) <- outputs
                , any (matchesAsset output) (assets :: [[Text]])
                ]
        _ -> fail "private facade output endpoint is not mapped"
    let genesisOnly =
            [ reference
            | (reference, _) <- selected
            , Map.member reference (serverGenesisOutputs server)
            ]
        origin =
            object
                [ "point" .= show (outputSourcePoint source)
                , "queriedExtent" .= extent
                , "outputsCBOR"
                    .= [ object
                            [ "reference" .= show reference
                            , "bytes" .= hex (serialize' (eraProtVerHigh @ConwayEra) output)
                            ]
                       | (reference, output) <- outputs
                       ]
                , "unindexedGenesisReferences" .= map genesisReference genesisOnly
                ]
    if null genesisOnly
        then do
            (headers, value) <-
                paged
                    request
                    [outputValue False reference output | (reference, output) <- selected]
            pure (status200, headers, encode value, origin)
        else
            -- These are actual unspent genesis allocations, carried by no
            -- full block. Refuse their indexed coverage explicitly rather
            -- than fabricating transaction CBOR or silently returning empty.
            pure
                ( status400
                , []
                , encode
                    ( "(coverage-incomplete) genesis outputs have no indexed full-block transaction: "
                        <> Text.intercalate ", " (map genesisReference genesisOnly)
                    )
                , origin
                )

{- | These endpoints consume confirmed full-block material only. A fresh
whole-UTxO/parameter acquisition contributes no fact to their answer.
Current output visibility is checked separately by address_utxos.
-}
answerArchive
    :: Server
    -> Request
    -> ByteString
    -> IO (Status, [(HeaderName, ByteString)], LBS.ByteString, Value)
answerArchive server request body = do
    archive <- readIORef (serverArchive server)
    asked <- jsonField "_tx_hashes" body
    let material =
            [ (block, tx)
            | block <- archiveBlocks archive
            , tx <- archivedTransactions block
            , Wire.txIdHex (archivedId tx) `elem` (asked :: [Text])
            ]
        blocks = case rawPathInfo request of
            "/api/v1/tx_status" -> archiveBlocks archive
            _ -> map fst material
        origin =
            object
                [ "blocks"
                    .= map
                        blockValue
                        ( Map.elems
                            (Map.fromList [(archivedHeight block, block) | block <- blocks])
                        )
                ]
        rows values = do
            (headers, value) <- paged request values
            pure (status200, headers, encode value, origin)
    case rawPathInfo request of
        "/api/v1/tx_info" ->
            rows [transactionValue block tx | (block, tx) <- material]
        "/api/v1/tx_cbor" ->
            rows
                [ object
                    [ "tx_hash" .= Wire.txIdHex (archivedId tx)
                    , "cbor" .= hex (archivedCBOR tx)
                    , "valid_contract" .= archivedValid tx
                    ]
                | (_, tx) <- material
                ]
        "/api/v1/tx_status" -> do
            let latest = maximum (0 : map archivedHeight (archiveBlocks archive))
            pure
                ( status200
                , []
                , encode
                    [ object
                        [ "tx_hash" .= identity
                        , "num_confirmations" .= case [ latest - archivedHeight block + 1
                                                      | (block, tx) <- material
                                                      , Wire.txIdHex (archivedId tx) == identity
                                                      ] of
                            count : _ -> Just count
                            [] -> Nothing
                        ]
                    | identity <- asked
                    ]
                , origin
                )
        _ -> fail "private facade archive endpoint is not mapped"

epochFor :: NetworkTime -> SlotNo -> IO Word64
epochFor context slot = do
    EpochNo epoch <-
        either
            (fail . Text.unpack)
            pure
            (epochInfoEpoch (networkEpochInfo context) slot)
    pure epoch

record :: Server -> Value -> IO ()
record server value = do
    atomicModifyIORef'
        (serverLog server)
        (\values -> (value : values, ()))
    serverObserver server value

parsed :: (Value -> Parser a) -> Value -> IO a
parsed parser = either fail pure . parseEither parser

jsonField :: (FromJSON a) => Key -> ByteString -> IO a
jsonField field bytes =
    either fail pure (eitherDecodeStrict' bytes)
        >>= parsed (withObject "Koios request" (.: field))

requiredQuery :: Text -> Request -> IO Text
requiredQuery field request =
    maybe
        (fail ("missing query " <> Text.unpack field))
        pure
        (Control.Monad.join (lookup field (queryText request)))

queryText :: Request -> [(Text, Maybe Text)]
queryText = parseQueryText . rawQueryString

paged :: Request -> [Value] -> IO ([(HeaderName, ByteString)], Value)
paged request values = do
    let number field defaultValue = case Control.Monad.join (lookup field (queryText request)) of
            Nothing -> pure defaultValue
            Just text ->
                maybe (fail "invalid page extent") pure (readMaybe (Text.unpack text))
    offset <- number "offset" 0
    limit <- number "limit" (length values)
    unless (offset >= 0 && limit >= 0) (fail "negative page extent")
    let selected = take limit (drop offset values)
        spanText =
            if null selected
                then "*"
                else show offset <> "-" <> show (offset + length selected - 1)
    pure
        ( [("content-range", BC.pack (spanText <> "/" <> show (length values)))]
        , toJSON selected
        )

matchesAsset :: TxOut ConwayEra -> [Text] -> Bool
matchesAsset output [policy, name] = case output ^. valueTxOutL of
    MaryValue _ (MultiAsset assets) ->
        or
            [ Wire.policyHex actualPolicy == policy
                && Wire.assetNameHex actualName == name
                && quantity /= 0
            | (actualPolicy, names) <- Map.toList assets
            , (actualName, quantity) <- Map.toList names
            ]
matchesAsset _ _ = False

outputValue :: Bool -> TxIn -> TxOut ConwayEra -> Value
outputValue historical (TxIn identity (TxIx index)) output =
    object
        ( [ "tx_hash" .= Wire.txIdHex identity
          , "tx_index" .= index
          , "value" .= amount
          , "asset_list"
                .= [ object
                        [ "policy_id" .= Wire.policyHex policy
                        , "asset_name" .= Wire.assetNameHex name
                        , "quantity" .= quantity
                        ]
                   | (policy, names) <- Map.toAscList assets
                   , (name, quantity) <- Map.toAscList names
                   ]
          , "datum_hash" .= case output ^. datumTxOutL of
                DatumHash hashed -> toJSON hashed
                _ -> Null
          , "inline_datum" .= case output ^. datumTxOutL of
                Datum binary -> object ["bytes" .= hex (originalBytes (binaryDataToData binary))]
                _ -> Null
          , "reference_script" .= case output ^. referenceScriptTxOutL of
                SNothing -> Null
                SJust script -> case toPlutusScript script of
                    Nothing ->
                        object
                            [ "type" .= ("timelock" :: Text)
                            , "hash" .= hashScript @ConwayEra script
                            ]
                    Just plutus ->
                        let PlutusBinary bytes = plutusScriptBinary plutus
                        in  object
                                [ "type" .= case plutusScriptLanguage plutus of
                                    PlutusV1 -> ("plutusV1" :: Text)
                                    PlutusV2 -> "plutusV2"
                                    PlutusV3 -> "plutusV3"
                                    PlutusV4 -> "plutusV4"
                                , "bytes" .= hex (SBS.fromShort bytes)
                                , "hash" .= hashScript @ConwayEra script
                                ]
          ]
            <> if historical
                then
                    [ "payment_addr"
                        .= object ["bech32" .= Wire.renderAddress (output ^. addrTxOutL)]
                    ]
                else ["address" .= Wire.renderAddress (output ^. addrTxOutL)]
        )
  where
    MaryValue (Coin amount) (MultiAsset assets) = output ^. valueTxOutL

transactionValue :: ArchivedBlock -> ArchivedTransaction -> Value
transactionValue block tx =
    object
        [ "tx_hash" .= Wire.txIdHex (archivedId tx)
        , "block_height" .= archivedHeight block
        , "inputs"
            .= [ outputValue True reference output
               | (reference, output) <- Map.toAscList (archivedInputs tx)
               ]
        , "reference_inputs"
            .= [ outputValue True reference output
               | (reference, output) <- Map.toAscList (archivedReferences tx)
               ]
        , "outputs"
            .= [ outputValue True reference output
               | (reference, output) <- archivedBodyOutputs tx
               ]
        , "valid_contract" .= archivedValid tx
        ]

blockValue :: ArchivedBlock -> Value
blockValue block =
    object
        [ "point" .= show (archivedPoint block)
        , "slot" .= archivedSlot block
        , "height" .= archivedHeight block
        , "transactions"
            .= [ object
                    [ "material" .= transactionValue block tx
                    , "cbor" .= hex (archivedCBOR tx)
                    , "cborSha256" .= digest (archivedCBOR tx)
                    , "collateral"
                        .= [ outputValue True reference output
                           | (reference, output) <- Map.toAscList (archivedCollateral tx)
                           ]
                    ]
               | tx <- archivedTransactions block
               ]
        ]

sourceValue :: LedgerSource -> Value
sourceValue source =
    object
        [ "point" .= show (sourcePoint source)
        , "blockNo" .= show (sourceBlockNo source)
        , "epoch" .= sourceEpoch source
        , "protocolParametersCBOR"
            .= hex (serialize' (eraProtVerHigh @ConwayEra) (sourceParameters source))
        , "outputsCBOR"
            .= [ object
                    [ "reference" .= show reference
                    , "bytes" .= hex (serialize' (eraProtVerHigh @ConwayEra) output)
                    ]
               | (reference, output) <- Map.toAscList (sourceOutputs source)
               ]
        , "systemStart" .= show (sourceSystemStart source)
        , "eraHistoryCBOR" .= hex (sourceEraHistory source)
        ]

timeSourceValue :: TimeSourceFacts -> Value
timeSourceValue source =
    object
        [ "point" .= show (timeSourcePoint source)
        , "systemStart" .= show (timeSourceSystemStart source)
        , "eraHistoryCBOR" .= hex (timeSourceEraHistory source)
        , "protocolParametersCBOR"
            .= hex
                (serialize' (eraProtVerHigh @ConwayEra) (timeSourceParameters source))
        ]

pointHash :: Chain.Point Block -> IO Text
pointHash point = case point of
    Chain.GenesisPoint -> fail "private facade tip has no block hash"
    Chain.BlockPoint _ (OneEraHash header) -> pure (hex (SBS.fromShort header))

hex :: ByteString -> Text
hex = decodeUtf8 . B16.encode

digest :: ByteString -> Text
digest bytes = hex (convert (hash bytes :: Digest SHA256))
