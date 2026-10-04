{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Provider.Koios.Recorder
Description : Read-only Koios probe and fixture recorder
License     : Apache-2.0

The read requests a person can name on the command line, a probe that
prints the decoded facts of one of them, and the recorder that writes
the raw answers behind them as fixtures for
"Singular.Provider.Koios.Recorded".

The request type has no submission case: 'ReadCall' enumerates every
call a 'ReadRequest' can make, and none is @submittx@. The recorder runs
the same typed calls the probe does, over the live transport, and
writes every exchange they make — page by page — with its request, the
Koios schema revision, the time and the SHA-256 of the body. Request
headers are not recorded, and the live transport replaces the token in
every answer, so a bearer token never reaches a fixture, even from a
server that echoes it. The token file is read before anything is sent.
The recording transport also refuses, without sending it, any submission
handed to it.
-}
module Singular.Provider.Koios.Recorder
    ( -- * Read requests
      ReadCall (..)
    , readCallName
    , readCallCall
    , ReadRequest (..)
    , readRequestCall
    , parseReadRequest

      -- * Probe
    , probe

      -- * Recorder
    , RecorderConfig (..)
    , RecordFailure (..)
    , schemaUrlOf
    , parseSchemaRevision
    , recordFixtures
    ) where

import Control.Exception (IOException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (getCurrentTime)
import Lens.Micro ((^.))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

import Cardano.Crypto.Hash.Class (hashFromBytes)
import Cardano.Ledger.Address (AccountAddress, Addr)
import Cardano.Ledger.Api.Tx.Out (TxOut, addrTxOutL)
import Cardano.Ledger.BaseTypes (EpochNo (..), TxIx (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Hashes (ScriptHash (..), unsafeMakeSafeHash)
import Cardano.Ledger.Mary.Value (AssetName (..), PolicyID (..))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))

import Singular.Provider.Koios.Client
    ( Answer (..)
    , ClientConfig
    , ClientFailure (..)
    , Exchange (..)
    , FailureReason (..)
    , Koios (..)
    , NoAnswer (..)
    , RawRequest (..)
    , Transport (..)
    , accountRegistered
    , addressUtxos
    , assetTxs
    , assetUtxos
    , cliProtocolParams
    , epochParams
    , tip
    , txCbor
    , txInfo
    , txStatus
    )
import Singular.Provider.Koios.Http
    ( HttpClient
    , HttpConfig (..)
    , fetchDocument
    , newHttpClient
    , transportOf
    )
import Singular.Provider.Koios.Recorded
    ( Fixture (..)
    , bodySha256
    , encodeFixture
    , fixtureFileName
    , fixtureRequestOf
    )
import Singular.Provider.Koios.Wire
    ( AssetTx (..)
    , Call (..)
    , Tip (..)
    , TxCbor (..)
    , TxInfo (..)
    , TxStatus (..)
    , callName
    , parseAddress
    , parseRewardAccount
    , renderAddress
    , renderRewardAccount
    , txIdHex
    )

-- | Every call a read request can make. There is no submission.
data ReadCall
    = ReadTip
    | ReadAddressUtxos
    | ReadAssetUtxos
    | ReadAssetTxs
    | ReadTxInfo
    | ReadTxCbor
    | ReadEpochParams
    | ReadCliProtocolParams
    | ReadTxStatus
    | ReadAccountInfo
    deriving stock (Eq, Show, Enum, Bounded)

-- | The command-line name of a read call: its Koios endpoint name.
readCallName :: ReadCall -> Text
readCallName = callName . readCallCall

-- | The Koios call a read call makes.
readCallCall :: ReadCall -> Call
readCallCall = \case
    ReadTip -> CallTip
    ReadAddressUtxos -> CallAddressUtxos
    ReadAssetUtxos -> CallAssetUtxos
    ReadAssetTxs -> CallAssetTxs
    ReadTxInfo -> CallTxInfo
    ReadTxCbor -> CallTxCbor
    ReadEpochParams -> CallEpochParams
    ReadCliProtocolParams -> CallCliProtocolParams
    ReadTxStatus -> CallTxStatus
    ReadAccountInfo -> CallAccountInfo

-- | One read request with its arguments.
data ReadRequest
    = TipOf
    | AddressUtxosOf Addr
    | AssetUtxosOf PolicyID AssetName
    | AssetTxsOf PolicyID AssetName
    | TxInfoOf [TxId]
    | TxCborOf [TxId]
    | EpochParamsOf EpochNo
    | CliProtocolParamsOf
    | TxStatusOf [TxId]
    | AccountInfoOf AccountAddress
    deriving stock (Eq, Show)

-- | The read call a request makes.
readRequestCall :: ReadRequest -> ReadCall
readRequestCall = \case
    TipOf -> ReadTip
    AddressUtxosOf _ -> ReadAddressUtxos
    AssetUtxosOf _ _ -> ReadAssetUtxos
    AssetTxsOf _ _ -> ReadAssetTxs
    TxInfoOf _ -> ReadTxInfo
    TxCborOf _ -> ReadTxCbor
    EpochParamsOf _ -> ReadEpochParams
    CliProtocolParamsOf -> ReadCliProtocolParams
    TxStatusOf _ -> ReadTxStatus
    AccountInfoOf _ -> ReadAccountInfo

{- | Parse @<call>@ or @<call>:<argument>[,<argument>]@, where the call
is a 'readCallName': an address or stake address in bech32, an asset as
@<policy hex>.<name hex>@, transaction hashes in hex, an epoch number.
-}
parseReadRequest :: Text -> Either Text ReadRequest
parseReadRequest text = do
    let (name, rest) = T.breakOn ":" text
        argument = T.drop 1 rest
    call <- case [c | c <- [minBound .. maxBound], readCallName c == name] of
        c : _ -> Right c
        [] ->
            Left $
                "not a read call: "
                    <> name
                    <> " (one of "
                    <> T.intercalate ", " (map readCallName [minBound .. maxBound])
                    <> ")"
    case call of
        ReadTip -> none argument TipOf
        ReadCliProtocolParams -> none argument CliProtocolParamsOf
        ReadAddressUtxos -> AddressUtxosOf <$> parseAddress argument
        ReadAssetUtxos -> uncurry AssetUtxosOf <$> asset argument
        ReadAssetTxs -> uncurry AssetTxsOf <$> asset argument
        ReadTxInfo -> TxInfoOf <$> txIds argument
        ReadTxCbor -> TxCborOf <$> txIds argument
        ReadTxStatus -> TxStatusOf <$> txIds argument
        ReadEpochParams -> case reads (T.unpack argument) of
            [(e, "")] -> Right (EpochParamsOf (EpochNo e))
            _ -> Left ("not an epoch number: " <> argument)
        ReadAccountInfo -> AccountInfoOf <$> parseRewardAccount argument
  where
    none argument r
        | T.null argument = Right r
        | otherwise = Left ("takes no argument: " <> argument)
    asset argument = do
        let (policy, name) = T.breakOn "." argument
        p <-
            hex policy >>= maybe (Left "not a policy id") Right . hashFromBytes
        n <- hex (T.drop 1 name)
        pure (PolicyID (ScriptHash p), AssetName (SBS.toShort n))
    txIds argument =
        traverse
            ( \t ->
                hex t
                    >>= maybe (Left ("not a transaction id: " <> t)) Right . hashFromBytes
                    >>= Right . TxId . unsafeMakeSafeHash
            )
            (T.splitOn "," argument)
    hex t = either (Left . T.pack) Right (Base16.decode (TE.encodeUtf8 t))

-- | Run one read request and render its decoded facts, one per line.
probe :: Koios IO -> ReadRequest -> IO (Either ClientFailure [Text])
probe k = \case
    TipOf ->
        fmap (\t -> [tipLine t]) <$> tip k
    AddressUtxosOf a -> fmap (map outputLine) <$> addressUtxos k [a]
    AssetUtxosOf p n -> fmap (map outputLine) <$> assetUtxos k [(p, n)]
    AssetTxsOf p n -> fmap (map assetTxLine) <$> assetTxs k p n
    TxInfoOf ids -> fmap (concatMap txInfoLines) <$> txInfo k ids
    TxCborOf ids -> fmap (map txCborLine) <$> txCbor k ids
    EpochParamsOf e -> fmap (\p -> [T.pack (show p)]) <$> epochParams k e
    CliProtocolParamsOf -> fmap (\p -> [T.pack (show p)]) <$> cliProtocolParams k
    TxStatusOf ids -> fmap (map statusLine) <$> txStatus k ids
    AccountInfoOf account ->
        fmap
            ( \registered ->
                [ renderRewardAccount account
                    <> if registered then " registered" else " not registered"
                ]
            )
            <$> accountRegistered k account
  where
    tipLine t =
        "slot "
            <> tshow (unSlotNo (tipSlot t))
            <> " block "
            <> TE.decodeUtf8 (Base16.encode (tipBlockHash t))
            <> " height "
            <> tshow (tipBlockHeight t)
            <> " epoch "
            <> tshow (unEpochNo (tipEpoch t))
    assetTxLine a =
        txIdHex (assetTxId a)
            <> " height "
            <> tshow (assetTxBlockHeight a)
            <> " epoch "
            <> tshow (unEpochNo (assetTxEpoch a))
    txInfoLines i =
        ( txIdHex (txInfoId i)
            <> " valid "
            <> tshow (txInfoValid i)
            <> " inputs "
            <> tshow (length (txInfoInputs i))
            <> " reference inputs "
            <> tshow (length (txInfoReferenceInputs i))
            <> " outputs "
            <> tshow (length (txInfoOutputs i))
        )
            : map outputLine (txInfoOutputs i)
    txCborLine c =
        txIdHex (txCborId c)
            <> " valid "
            <> tshow (txCborValid c)
            <> " bytes "
            <> tshow (BS.length (txCborBytes c))
    statusLine s =
        txIdHex (txStatusId s)
            <> maybe
                " not yet seen"
                ((" confirmations " <>) . tshow)
                (txStatusConfirmations s)

outputLine :: (TxIn, TxOut ConwayEra) -> Text
outputLine (TxIn txId (TxIx ix), out) =
    txIdHex txId
        <> "#"
        <> tshow ix
        <> " "
        <> renderAddress (out ^. addrTxOutL)
        <> " "
        <> tshow out

tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- | Where and how to record.
data RecorderConfig = RecorderConfig
    { recorderHttp :: HttpConfig
    , recorderClient :: ClientConfig
    , recorderDirectory :: FilePath
    }

-- | Why recording stopped.
data RecordFailure
    = -- | The live transport could not be built; nothing was sent
      RecordTransport FailureReason
    | -- | The schema document could not be read or carries no revision
      RecordSchema Text
    | -- | The fixture directory or a fixture file could not be written
      RecordWrite FilePath Text
    | {- | A request's call failed for a reason other than its answer's
      content; fixtures written so far are kept
      -}
      RecordCall ReadRequest ClientFailure
    deriving stock (Show)

{- | The schema document of a base URL: @koiosapi.yaml@ at its origin,
as Koios serves it (@https://preprod.koios.rest/koiosapi.yaml@ for
@https://preprod.koios.rest/api/v1@).
-}
schemaUrlOf :: Text -> Text
schemaUrlOf base =
    let (scheme, rest) = T.breakOn "://" base
        authority = T.takeWhile (/= '/') (T.drop 3 rest)
    in  scheme <> "://" <> authority <> "/koiosapi.yaml"

{- | The @info.version@ of a Koios OpenAPI document: the @version@ key
directly under the top-level @info@ key.
-}
parseSchemaRevision :: ByteString -> Either Text Text
parseSchemaRevision document =
    case dropWhile (/= "info:") (T.lines (TE.decodeUtf8Lenient document)) of
        _ : body ->
            let children = takeWhile (\l -> T.null l || "  " `T.isPrefixOf` l) body
            in  case [ T.strip v
                     | l <- children
                     , Just v <- [T.stripPrefix "  version:" l]
                     ] of
                    v : _ | not (T.null v) -> Right (T.dropAround (`elem` ['"', '\'']) v)
                    _ -> Left "the info block names no version"
        [] -> Left "the document has no info block"

{- | The schema revision the base URL's origin publishes, fetched through
the recording connection: its token, timeout and retry bounds.
-}
fetchSchemaRevision :: HttpClient -> Text -> IO (Either Text Text)
fetchSchemaRevision client base = do
    let url = schemaUrlOf base
    ex <- fetchDocument client url
    pure $ case exchangeResult ex of
        Left none -> Left (url <> ": " <> tshow none)
        Right a
            | answerStatus a /= 200 ->
                Left (url <> ": status " <> tshow (answerStatus a))
            | otherwise -> parseSchemaRevision (answerBody a)

{- | Record every exchange the requests make into the directory, and
return the files written. The token file is read before anything is
sent, the schema document first among them. An answer whose content
the client refuses — an absent fact, an answer that does not decode — is
recorded and recording goes on: the recording is the evidence, and the
tests judge it.
-}
recordFixtures
    :: RecorderConfig
    -> [ReadRequest]
    -> IO (Either RecordFailure [FilePath])
recordFixtures cfg requests =
    newHttpClient (recorderHttp cfg) >>= \case
        Left e -> pure (Left (RecordTransport e))
        Right client ->
            fetchSchemaRevision client (httpBaseUrl (recorderHttp cfg)) >>= \case
                Left e -> pure (Left (RecordSchema e))
                Right revision ->
                    try (createDirectoryIfMissing True dir) >>= \case
                        Left e -> pure (Left (RecordWrite dir (ioText e)))
                        Right () -> record client revision
  where
    dir = recorderDirectory cfg
    ioText e = T.pack (show (e :: IOException))
    record client revision = do
        written <- newIORef []
        broken <- newIORef Nothing
        let live = transportOf client
            recording = Transport $ \raw ->
                if rawCall raw == CallSubmitTx
                    then
                        pure
                            Exchange
                                { exchangeAttempts = 0
                                , exchangeResult =
                                    Left (NoConnection "the recorder does not submit")
                                }
                    else do
                        ex <- exchange live raw
                        case exchangeResult ex of
                            Right answer ->
                                write revision raw answer >>= \case
                                    Right path -> modifyIORef' written (<> [path])
                                    Left failure -> writeIORef broken (Just failure)
                            Left _ -> pure ()
                        pure ex
            k = Koios (recorderClient cfg) recording
            run = \case
                [] -> Right <$> readIORef written
                r : rs -> do
                    outcome <- probe k r
                    readIORef broken >>= \case
                        Just failure -> pure (Left failure)
                        Nothing -> case outcome of
                            Left ClientFailure{failureReason = UnknownFact _} -> run rs
                            Left ClientFailure{failureReason = Undecodable _} -> run rs
                            Left f -> pure (Left (RecordCall r f))
                            Right _ -> run rs
        run requests
    write revision raw answer = do
        now <- getCurrentTime
        let request = fixtureRequestOf raw
            path = dir </> fixtureFileName request
            bytes =
                encodeFixture
                    Fixture
                        { fixtureRequest = request
                        , fixtureRevision = revision
                        , fixtureRecordedAt = now
                        , fixtureSha256 = bodySha256 (answerBody answer)
                        , fixtureAnswer = answer
                        }
        try (BSL.writeFile path bytes) >>= \case
            Left e -> pure (Left (RecordWrite path (ioText e)))
            Right () -> pure (Right path)
