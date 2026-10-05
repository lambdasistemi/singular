{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Singular.Provider.Koios.Wire
Description : Koios requests and the decoders of their answers
License     : Apache-2.0

One request description per Koios call, and one decoder per answer,
from Koios JSON into Conway ledger types. Nothing here performs a
request: a transport carries the description and returns the raw
answer, and "Singular.Provider.Koios.Client" pages and decodes it with
these functions. A recorded answer and a live one therefore pass
through the same code.

A request is indexed by its access: every call reads, except
'submitTxRequest', which is the only 'Submission'. A component that must
never submit, such as the fixture recorder, accepts only
@'Request' ''Read'@.

A decoder that fails names the position that failed, as a JSON path
into the answer. Outputs keep everything the ledger keeps: the
address, the value with every policy and asset name, an inline datum's
bytes or else a datum hash, and a reference script's bytes, checked
against the script hash Koios names. A native reference script is
refused by name: Koios gives no bytes for it, only a summary. Koios
reports a @datum_hash@ for an inline datum too; the inline datum wins.
Transaction bytes are decoded as a Conway transaction and checked
against the transaction id Koios names.

A transaction's validity — false for a transaction recorded as a
phase-2 failure, whose collateral alone was spent — is read from the
transaction itself where its bytes are decoded, from Koios's
@valid_contract@ otherwise, and never used to drop a transaction.

Requests name addresses and stake addresses in bech32, so they cover
Shelley addresses; Koios names Byron addresses in base58, which this
module does not render.
-}
module Singular.Provider.Koios.Wire
    ( -- * Calls
      Call (..)
    , callName

      -- * Requests
    , Access (..)
    , Method (..)
    , Body (..)
    , Request (..)
    , tipRequest
    , addressUtxosRequest
    , assetUtxosRequest
    , assetTxsRequest
    , txInfoRequest
    , txCborRequest
    , epochParamsRequest
    , cliProtocolParamsRequest
    , submitTxRequest
    , txStatusRequest
    , accountInfoRequest

      -- * Decoded facts
    , Tip (..)
    , AssetTx (..)
    , TxInfo (..)
    , TxCbor (..)
    , TxStatus (..)
    , AccountStatus (..)

      -- * Decoders
    , DecodeFailure (..)
    , parseBody
    , decodeTip
    , decodeUtxos
    , decodeAssetTxs
    , decodeTxInfos
    , decodeTxCbors
    , decodeEpochParams
    , decodeCliProtocolParams
    , decodeSubmitted
    , decodeTxStatuses
    , decodeAccountStatuses

      -- * Renderings
    , renderAddress
    , parseAddress
    , renderRewardAccount
    , parseRewardAccount
    , txIdHex
    , policyHex
    , assetNameHex
    ) where

import Codec.Binary.Bech32 qualified as Bech32
import Control.Monad (unless, when, zipWithM)
import Data.Aeson
    ( Key
    , Object
    , Value (..)
    , eitherDecodeStrict'
    , object
    , withArray
    , withObject
    , (.:)
    , (.:?)
    , (.=)
    )
import Data.Aeson.Types
    ( IResult (..)
    , JSONPathElement (..)
    , Parser
    , formatPath
    , iparse
    , parseJSON
    , (<?>)
    )
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.Int (Int64)
import Data.Kind (Type)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Maybe.Strict (maybeToStrictMaybe)
import Data.Scientific (Scientific, floatingOrInteger)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word16, Word32, Word64, Word8)
import Lens.Micro ((&), (.~), (^.))

import Cardano.Crypto.Hash.Class
    ( Hash
    , HashAlgorithm
    , hashFromBytes
    , hashToTextAsHex
    )
import Cardano.Ledger.Address
    ( AccountAddress (..)
    , Addr
    , decodeAddrEither
    , deserialiseAccountAddress
    , getNetwork
    , serialiseAccountAddress
    , serialiseAddr
    )
import Cardano.Ledger.Alonzo.Scripts
    ( fromPlutusScript
    , mkBinaryPlutusScript
    )
import Cardano.Ledger.Alonzo.Tx (IsValid (..))
import Cardano.Ledger.Api.PParams
    ( CoinPerByte (..)
    , emptyPParams
    , ppA0L
    , ppCoinsPerUTxOByteL
    , ppCollateralPercentageL
    , ppCostModelsL
    , ppEMaxL
    , ppKeyDepositL
    , ppMaxBBSizeL
    , ppMaxBHSizeL
    , ppMaxBlockExUnitsL
    , ppMaxCollateralInputsL
    , ppMaxTxExUnitsL
    , ppMaxTxSizeL
    , ppMaxValSizeL
    , ppMinPoolCostL
    , ppNOptL
    , ppPoolDepositL
    , ppPricesL
    , ppProtocolVersionL
    , ppRhoL
    , ppTauL
    , ppTxFeeFixedL
    , ppTxFeePerByteL
    )
import Cardano.Ledger.Api.Tx (bodyTxL, isValidTxL)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , datumTxOutL
    , mkBasicTxOut
    , referenceScriptTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( BoundedRational (..)
    , EpochInterval (..)
    , EpochNo (..)
    , Network (..)
    , ProtVer (..)
    , UnitInterval
    , mkVersion
    , txIxFromIntegral
    )
import Cardano.Ledger.Binary (decCBOR, decodeFullAnnotator)
import Cardano.Ledger.Coin (Coin (..), CompactForm (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.PParams
    ( DRepVotingThresholds (..)
    , PoolVotingThresholds (..)
    , ppCommitteeMaxTermLengthL
    , ppCommitteeMinSizeL
    , ppDRepActivityL
    , ppDRepDepositL
    , ppDRepVotingThresholdsL
    , ppGovActionDepositL
    , ppGovActionLifetimeL
    , ppMinFeeRefScriptCostPerByteL
    , ppPoolVotingThresholdsL
    )
import Cardano.Ledger.Core
    ( PParams
    , Script
    , eraProtVerHigh
    , hashScript
    , txIdTxBody
    )
import Cardano.Ledger.Hashes
    ( ScriptHash (..)
    , extractHash
    , unsafeMakeSafeHash
    )
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.CostModels
    ( CostModels
    , mkCostModelsLenient
    )
import Cardano.Ledger.Plutus.Data (Datum (..), makeBinaryData)
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..), Prices (..))
import Cardano.Ledger.Plutus.Language
    ( Language (..)
    , PlutusBinary (..)
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)

-- | The Koios calls this client makes.
data Call
    = CallTip
    | CallAddressUtxos
    | CallAssetUtxos
    | CallAssetTxs
    | CallTxInfo
    | CallTxCbor
    | CallEpochParams
    | CallCliProtocolParams
    | CallSubmitTx
    | CallTxStatus
    | CallAccountInfo
    deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The Koios endpoint name of a call, as in its path.
callName :: Call -> Text
callName = \case
    CallTip -> "tip"
    CallAddressUtxos -> "address_utxos"
    CallAssetUtxos -> "asset_utxos"
    CallAssetTxs -> "asset_txs"
    CallTxInfo -> "tx_info"
    CallTxCbor -> "tx_cbor"
    CallEpochParams -> "epoch_params"
    CallCliProtocolParams -> "cli_protocol_params"
    CallSubmitTx -> "submittx"
    CallTxStatus -> "tx_status"
    CallAccountInfo -> "account_info"

-- | Whether a request reads or submits.
data Access = Read | Submission

-- | HTTP method of a request.
data Method = Get | Post
    deriving stock (Eq, Ord, Show)

-- | Request body.
data Body
    = NoBody
    | -- | A JSON document
      JsonBody Value
    | -- | Raw CBOR bytes, as @submittx@ takes them
      CborBody ByteString
    deriving stock (Eq, Show)

{- | One Koios request, before paging. A paged request names the order
its rows are read in; the client adds offset and limit.
-}
type Request :: Access -> Type
data Request a = Request
    { requestCall :: Call
    , requestMethod :: Method
    , requestPath :: Text
    -- ^ Path below the base URL, with its leading slash
    , requestQuery :: [(Text, Text)]
    , requestBody :: Body
    , requestOrder :: Maybe Text
    -- ^ @Just@ the order clause when the call is paged
    }
    deriving stock (Eq, Show)

-- | A request whose path is its call's endpoint.
request
    :: Call -> Method -> [(Text, Text)] -> Body -> Maybe Text -> Request a
request call method query body order =
    Request
        { requestCall = call
        , requestMethod = method
        , requestPath = "/" <> callName call
        , requestQuery = query
        , requestBody = body
        , requestOrder = order
        }

-- | Output references: the stable order of the output listings.
byOutputReference :: Maybe Text
byOutputReference = Just "tx_hash.asc,tx_index.asc"

-- | @tip@: the chain tip.
tipRequest :: Request 'Read
tipRequest = request CallTip Get [] NoBody Nothing

-- | @address_utxos@, extended, ordered by output reference.
addressUtxosRequest :: [Addr] -> Request 'Read
addressUtxosRequest addrs =
    request
        CallAddressUtxos
        Post
        []
        ( JsonBody $
            object
                [ "_addresses" .= map renderAddress addrs
                , "_extended" .= True
                ]
        )
        byOutputReference

-- | @asset_utxos@, extended, ordered by output reference.
assetUtxosRequest :: [(PolicyID, AssetName)] -> Request 'Read
assetUtxosRequest assets =
    request
        CallAssetUtxos
        Post
        []
        ( JsonBody $
            object
                [ "_asset_list"
                    .= [[policyHex p, assetNameHex n] | (p, n) <- assets]
                , "_extended" .= True
                ]
        )
        byOutputReference

{- | @asset_txs@ with history: every transaction that included the asset.
Koios lists them newest first; pages are read by block height then
transaction id only so that pages are stable. That order is not the
order in which the asset was passed on: Koios gives no index within a
block, and a transaction that included the asset need not have spent
it.
-}
assetTxsRequest :: PolicyID -> AssetName -> Request 'Read
assetTxsRequest p n =
    request
        CallAssetTxs
        Get
        [ ("_asset_policy", policyHex p)
        , ("_asset_name", assetNameHex n)
        , ("_history", "true")
        ]
        NoBody
        (Just "block_height.asc,tx_hash.asc")

{- | @tx_info@ with inputs, assets, scripts and bytecode. Without
@_assets@ Koios answers every asset list empty.
-}
txInfoRequest :: [TxId] -> Request 'Read
txInfoRequest ids =
    request
        CallTxInfo
        Post
        []
        ( JsonBody $
            object
                [ "_tx_hashes" .= map txIdHex ids
                , "_inputs" .= True
                , "_assets" .= True
                , "_scripts" .= True
                , "_bytecode" .= True
                ]
        )
        Nothing

-- | @tx_cbor@: the raw transactions.
txCborRequest :: [TxId] -> Request 'Read
txCborRequest ids =
    request
        CallTxCbor
        Post
        []
        (JsonBody (object ["_tx_hashes" .= map txIdHex ids]))
        Nothing

-- | @epoch_params@ of one epoch.
epochParamsRequest :: EpochNo -> Request 'Read
epochParamsRequest (EpochNo e) =
    request
        CallEpochParams
        Get
        [("_epoch_no", T.pack (show e))]
        NoBody
        Nothing

{- | @cli_protocol_params@: the current protocol parameters in the
node's own JSON form.
-}
cliProtocolParamsRequest :: Request 'Read
cliProtocolParamsRequest =
    request CallCliProtocolParams Get [] NoBody Nothing

-- | @submittx@: submit a signed transaction's CBOR.
submitTxRequest :: ByteString -> Request 'Submission
submitTxRequest bytes =
    request CallSubmitTx Post [] (CborBody bytes) Nothing

-- | @tx_status@: confirmations of transactions.
txStatusRequest :: [TxId] -> Request 'Read
txStatusRequest ids =
    request
        CallTxStatus
        Post
        []
        (JsonBody (object ["_tx_hashes" .= map txIdHex ids]))
        Nothing

-- | @account_info@ of one stake address.
accountInfoRequest :: AccountAddress -> Request 'Read
accountInfoRequest account =
    request
        CallAccountInfo
        Post
        []
        ( JsonBody
            (object ["_stake_addresses" .= [renderRewardAccount account]])
        )
        Nothing

-- | The chain tip.
data Tip = Tip
    { tipSlot :: SlotNo
    , tipBlockHash :: ByteString
    , tipBlockHeight :: Word64
    , tipEpoch :: EpochNo
    , tipBlockTime :: Word64
    -- ^ Required raw UNIX/POSIX seconds, never inferred from the tip slot.
    }
    deriving stock (Eq, Show)

-- | One transaction that included an asset.
data AssetTx = AssetTx
    { assetTxId :: TxId
    , assetTxBlockHeight :: Word64
    , assetTxEpoch :: EpochNo
    }
    deriving stock (Eq, Show)

{- | One transaction's resolved outputs: the outputs it spent, the
outputs it referenced and the outputs it created, each with its output
reference, and whether it is valid.
-}
data TxInfo = TxInfo
    { txInfoId :: TxId
    , txInfoBlockHeight :: Word64
    -- ^ Required raw block height, used to resolve omitted same-block creators.
    , txInfoInputs :: [(TxIn, TxOut ConwayEra)]
    , txInfoReferenceInputs :: [(TxIn, TxOut ConwayEra)]
    , txInfoOutputs :: [(TxIn, TxOut ConwayEra)]
    , txInfoValid :: Bool
    {- ^ Koios's @valid_contract@: at top level when present, else every
    script's; true for a transaction without scripts
    -}
    }
    deriving stock (Eq, Show)

{- | One transaction's raw bytes, decoded as a Conway transaction whose
id is the one Koios named.
-}
data TxCbor = TxCbor
    { txCborId :: TxId
    , txCborBytes :: ByteString
    , txCborTx :: ConwayTx
    , txCborValid :: Bool
    {- ^ The transaction's own validity flag; when Koios also sends
    @valid_contract@ the two agree
    -}
    }
    deriving stock (Eq, Show)

-- | One transaction's confirmations, or 'Nothing' when not yet seen.
data TxStatus = TxStatus
    { txStatusId :: TxId
    , txStatusConfirmations :: Maybe Word64
    }
    deriving stock (Eq, Show)

-- | One stake address's registration status, as Koios states it.
data AccountStatus = AccountStatus
    { accountStakeAddress :: Text
    , accountStatus :: Text
    }
    deriving stock (Eq, Show)

-- | An answer that does not decode, with the position that failed.
data DecodeFailure = DecodeFailure
    { decodePosition :: Text
    -- ^ JSON path into the answer, @$@ for the body as a whole
    , decodeReason :: Text
    }
    deriving stock (Eq, Show)

{- | Parse an answer body as one JSON document. A body that is not one,
such as a body cut off mid-array, fails with the parser's reason.
-}
parseBody :: ByteString -> Either DecodeFailure Value
parseBody body = case eitherDecodeStrict' body of
    Right v -> Right v
    Left e -> Left (DecodeFailure "$" (T.pack e))

-- | Run a parser, naming the JSON path that failed.
runParser :: (Value -> Parser a) -> Value -> Either DecodeFailure a
runParser p v = case iparse p v of
    ISuccess a -> Right a
    IError path e ->
        Left (DecodeFailure (T.pack (formatPath path)) (T.pack e))

-- | Each row of an array, its index on the path.
rows :: (Object -> Parser a) -> Value -> Parser [a]
rows p = withArray "rows" $ \arr ->
    zipWithM
        (\i v -> withObject "row" p v <?> Index i)
        [0 ..]
        (toList arr)

{- | Decode a @tip@ answer: empty when Koios returned no row.
Koios API 1.4.2, cardano-community/koios-artifacts revision
2e2eb57933e1e2528de5ca36ee961759841cf389,
specs/results/koiosapi-preprod.yaml:
#/components/schemas/tip/items/properties/block_time refers to
#/components/schemas/blocks/items/properties/block_time, UNIX seconds.
Missing, fractional, negative or overflowing raw seconds refuse by name.
-}
decodeTip :: Value -> Either DecodeFailure [Tip]
decodeTip = runParser $ rows $ \o ->
    Tip . SlotNo
        <$> o .: "abs_slot"
        <*> (o .: "hash" >>= hexSized 32)
        <*> o .: "block_height"
        <*> (EpochNo <$> o .: "epoch_no")
        <*> (o .: "block_time" <?> Key "block_time")

-- | Decode the rows of an @address_utxos@ or @asset_utxos@ page.
decodeUtxos :: Value -> Either DecodeFailure [(TxIn, TxOut ConwayEra)]
decodeUtxos = runParser $ rows $ \o -> do
    txIn <- txInOf o
    address <- o .: "address" >>= addressOf
    out <- outputOf address o
    pure (txIn, out)

-- | One output reference.
txInOf :: Object -> Parser TxIn
txInOf o = do
    txId <- o .: "tx_hash" >>= txIdOf
    ix <- o .: "tx_index"
    case txIxFromIntegral (ix :: Integer) of
        Just txIx -> pure (TxIn txId txIx)
        Nothing -> fail ("output index out of range: " <> show ix)

-- | One output: value, assets, datum and reference script.
outputOf :: Addr -> Object -> Parser (TxOut ConwayEra)
outputOf address o = do
    lovelace <- o .: "value" >>= integral
    assets <-
        o .:? "asset_list"
            >>= maybe (pure []) (zipWithM (\i a -> assetOf a <?> Index i) [0 ..])
    inline <- o .:? "inline_datum"
    hashed <- o .:? "datum_hash"
    datum <- case (inline, hashed) of
        (Just d, _) -> inlineDatumOf d <?> Key "inline_datum"
        (Nothing, Just h) -> datumHashOf h <?> Key "datum_hash"
        (Nothing, Nothing) -> pure NoDatum
    script <-
        o .:? "reference_script" >>= \case
            Nothing -> pure Nothing
            Just s -> Just <$> scriptOf s <?> Key "reference_script"
    let value =
            MaryValue
                (Coin lovelace)
                (MultiAsset (Map.fromListWith (Map.unionWith (+)) assets))
    pure $
        mkBasicTxOut address value
            & datumTxOutL .~ datum
            & referenceScriptTxOutL .~ maybeToStrictMaybe script

-- | One entry of an asset list.
assetOf :: Value -> Parser (PolicyID, Map.Map AssetName Integer)
assetOf = withObject "asset" $ \a -> do
    policy <- a .: "policy_id" >>= fmap (PolicyID . ScriptHash) . hashOf
    name <- a .:? "asset_name" >>= maybe (pure "") hexAny
    when (BS.length name > 32) $ fail "asset name longer than 32 bytes"
    quantity <- a .: "quantity" >>= integral
    pure (policy, Map.singleton (AssetName (SBS.toShort name)) quantity)

inlineDatumOf :: Value -> Parser (Datum ConwayEra)
inlineDatumOf = withObject "inline_datum" $ \d -> do
    bytes <- d .: "bytes" >>= hexAny
    case makeBinaryData (SBS.toShort bytes) of
        Right binary -> pure (Datum binary)
        Left e -> fail ("inline datum is not plutus data: " <> e)

datumHashOf :: Value -> Parser (Datum ConwayEra)
datumHashOf v = DatumHash . unsafeMakeSafeHash <$> (parseJSON v >>= hashOf)

-- | A reference script, checked against the hash Koios names.
scriptOf :: Value -> Parser (Script ConwayEra)
scriptOf = withObject "reference_script" $ \s -> do
    kind <- s .: "type"
    when (kind `elem` ["timelock", "multisig"]) $
        fail
            ( "a native ("
                <> T.unpack kind
                <> ") reference script: Koios gives no bytes for it, only a summary"
            )
    bytes <- s .: "bytes" >>= hexAny
    expected <- s .: "hash" >>= fmap ScriptHash . hashOf
    script <- case kind :: Text of
        "plutusV1" -> plutus PlutusV1 bytes
        "plutusV2" -> plutus PlutusV2 bytes
        "plutusV3" -> plutus PlutusV3 bytes
        other ->
            fail ("unsupported reference script type: " <> T.unpack other)
    let actual = hashScript @ConwayEra script
    unless (actual == expected) $
        fail ("script bytes hash to " <> show actual)
    pure script
  where
    plutus lang bytes =
        case mkBinaryPlutusScript lang (PlutusBinary (SBS.toShort bytes)) of
            Just ps -> pure (fromPlutusScript ps)
            Nothing -> fail ("not a " <> show lang <> " script in this era")

-- | Decode the rows of an @asset_txs@ page.
decodeAssetTxs :: Value -> Either DecodeFailure [AssetTx]
decodeAssetTxs = runParser $ rows $ \o ->
    AssetTx
        <$> (o .: "tx_hash" >>= txIdOf)
        <*> o .: "block_height"
        <*> (EpochNo <$> o .: "epoch_no")

{- | Decode a @tx_info@ answer. The same pinned schema's
#/components/schemas/tx_info/items/properties/block_height refers to
#/components/schemas/blocks/items/properties/block_height, a block height.
-}
decodeTxInfos :: Value -> Either DecodeFailure [TxInfo]
decodeTxInfos = runParser $ rows $ \o -> do
    txId <- o .: "tx_hash" >>= txIdOf
    height <- o .: "block_height" <?> Key "block_height"
    inputs <- o .: "inputs" >>= ioRows "inputs"
    references <-
        o .:? "reference_inputs"
            >>= maybe (pure []) (ioRows "reference_inputs")
    outputs <- o .: "outputs" >>= ioRows "outputs"
    topLevel <- o .:? "valid_contract"
    contracts <-
        o .:? "plutus_contracts"
            >>= maybe (pure []) (mapM contractValid)
    pure
        TxInfo
            { txInfoId = txId
            , txInfoBlockHeight = height
            , txInfoInputs = inputs
            , txInfoReferenceInputs = references
            , txInfoOutputs = outputs
            , txInfoValid = fromMaybe (and contracts) topLevel
            }
  where
    ioRows :: Key -> Value -> Parser [(TxIn, TxOut ConwayEra)]
    ioRows key v = rows ioRow v <?> Key key
    ioRow o = do
        txIn <- txInOf o
        address <-
            o .: "payment_addr"
                >>= withObject "payment_addr" (.: "bech32")
                >>= addressOf
        out <- outputOf address o
        pure (txIn, out)
    contractValid = withObject "plutus_contract" (.: "valid_contract")

-- | Decode a @tx_cbor@ answer, each transaction checked against its id.
decodeTxCbors :: Value -> Either DecodeFailure [TxCbor]
decodeTxCbors = runParser $ rows $ \o -> do
    txId <- o .: "tx_hash" >>= txIdOf
    bytes <- o .: "cbor" >>= hexAny
    tx <- case decodeConwayTx bytes of
        Right tx -> pure tx
        Left e -> fail ("not a Conway transaction: " <> e) <?> Key "cbor"
    let actual = txIdTxBody (tx ^. bodyTxL)
    when (actual /= txId) $
        fail ("transaction bytes hash to " <> T.unpack (txIdHex actual))
            <?> Key "cbor"
    let IsValid valid = tx ^. isValidTxL
    stated <- o .:? "valid_contract"
    when (maybe False (/= valid) stated) $
        fail "valid_contract disagrees with the transaction's own flag"
            <?> Key "valid_contract"
    pure
        TxCbor
            { txCborId = txId
            , txCborBytes = bytes
            , txCborTx = tx
            , txCborValid = valid
            }

decodeConwayTx :: ByteString -> Either String ConwayTx
decodeConwayTx bytes =
    either (Left . show) Right $
        decodeFullAnnotator
            (eraProtVerHigh @ConwayEra)
            "ConwayTx"
            decCBOR
            (BSL.fromStrict bytes)

-- | Decode an @epoch_params@ answer: empty when Koios returned no row.
decodeEpochParams :: Value -> Either DecodeFailure [PParams ConwayEra]
decodeEpochParams = runParser $ rows $ \o -> do
    let threshold :: Key -> Parser UnitInterval
        threshold key = (o .: key >>= bounded) <?> Key key
        ratio key = (o .: key >>= bounded) <?> Key key
        lovelace key = Coin <$> (o .: key >>= integral)
    major <- o .: "protocol_major"
    version <- case mkVersion (major :: Word64) of
        Just v -> pure v
        Nothing ->
            fail ("unknown protocol version " <> show major)
                <?> Key "protocol_major"
    minor <- o .: "protocol_minor"
    pvt <-
        PoolVotingThresholds
            <$> threshold "pvt_motion_no_confidence"
            <*> threshold "pvt_committee_normal"
            <*> threshold "pvt_committee_no_confidence"
            <*> threshold "pvt_hard_fork_initiation"
            <*> threshold "pvtpp_security_group"
    dvt <-
        DRepVotingThresholds
            <$> threshold "dvt_motion_no_confidence"
            <*> threshold "dvt_committee_normal"
            <*> threshold "dvt_committee_no_confidence"
            <*> threshold "dvt_update_to_constitution"
            <*> threshold "dvt_hard_fork_initiation"
            <*> threshold "dvt_p_p_network_group"
            <*> threshold "dvt_p_p_economic_group"
            <*> threshold "dvt_p_p_technical_group"
            <*> threshold "dvt_p_p_gov_group"
            <*> threshold "dvt_treasury_withdrawal"
    minFeeA <- (o .: "min_fee_a" >>= compactCoin) <?> Key "min_fee_a"
    minFeeB <- lovelace "min_fee_b"
    maxBlock <- o .: "max_block_size"
    maxTx <- o .: "max_tx_size"
    maxHeader <- o .: "max_bh_size"
    keyDeposit <- lovelace "key_deposit"
    poolDeposit <- lovelace "pool_deposit"
    eMax <- o .: "max_epoch"
    nOpt <- o .: "optimal_pool_count"
    a0 <- ratio "influence"
    rho <- ratio "monetary_expand_rate"
    tau <- ratio "treasury_growth_rate"
    minPoolCost <- lovelace "min_pool_cost"
    costModels <-
        (o .: "cost_models" >>= costModelsOf) <?> Key "cost_models"
    priceMem <- ratio "price_mem"
    priceStep <- ratio "price_step"
    maxTxMem <- o .: "max_tx_ex_mem"
    maxTxSteps <- o .: "max_tx_ex_steps"
    maxBlockMem <- o .: "max_block_ex_mem"
    maxBlockSteps <- o .: "max_block_ex_steps"
    maxVal <- o .: "max_val_size"
    collateral <- o .: "collateral_percent"
    maxCollateral <- o .: "max_collateral_inputs"
    perByte <-
        (o .: "coins_per_utxo_size" >>= integral >>= compactCoin)
            <?> Key "coins_per_utxo_size"
    committeeMin <- o .: "committee_min_size"
    committeeTerm <- o .: "committee_max_term_length"
    lifetime <- o .: "gov_action_lifetime"
    govDeposit <- lovelace "gov_action_deposit"
    drepDeposit <- lovelace "drep_deposit"
    drepActivity <- o .: "drep_activity"
    refScript <- ratio "min_fee_ref_script_cost_per_byte"
    pure $
        emptyPParams @ConwayEra
            & ppTxFeePerByteL .~ CoinPerByte minFeeA
            & ppTxFeeFixedL .~ minFeeB
            & ppMaxBBSizeL .~ (maxBlock :: Word32)
            & ppMaxTxSizeL .~ (maxTx :: Word32)
            & ppMaxBHSizeL .~ (maxHeader :: Word16)
            & ppKeyDepositL .~ keyDeposit
            & ppPoolDepositL .~ poolDeposit
            & ppEMaxL .~ EpochInterval eMax
            & ppNOptL .~ (nOpt :: Word16)
            & ppA0L .~ a0
            & ppRhoL .~ rho
            & ppTauL .~ tau
            & ppProtocolVersionL .~ ProtVer version minor
            & ppMinPoolCostL .~ minPoolCost
            & ppCostModelsL .~ costModels
            & ppPricesL .~ Prices priceMem priceStep
            & ppMaxTxExUnitsL .~ ExUnits maxTxMem maxTxSteps
            & ppMaxBlockExUnitsL .~ ExUnits maxBlockMem maxBlockSteps
            & ppMaxValSizeL .~ (maxVal :: Word32)
            & ppCollateralPercentageL .~ (collateral :: Word16)
            & ppMaxCollateralInputsL .~ (maxCollateral :: Word16)
            & ppCoinsPerUTxOByteL .~ CoinPerByte perByte
            & ppPoolVotingThresholdsL .~ pvt
            & ppDRepVotingThresholdsL .~ dvt
            & ppCommitteeMinSizeL .~ (committeeMin :: Word16)
            & ppCommitteeMaxTermLengthL .~ EpochInterval committeeTerm
            & ppGovActionLifetimeL .~ EpochInterval lifetime
            & ppGovActionDepositL .~ govDeposit
            & ppDRepDepositL .~ drepDeposit
            & ppDRepActivityL .~ EpochInterval drepActivity
            & ppMinFeeRefScriptCostPerByteL .~ refScript

-- | A lovelace amount in its compact form.
compactCoin :: Integer -> Parser (CompactForm Coin)
compactCoin n
    | n >= 0 && n <= fromIntegral (maxBound :: Word64) =
        pure (CompactCoin (fromIntegral n))
    | otherwise = fail ("lovelace out of range: " <> show n)

-- | A bounded ratio from a JSON number, exactly.
bounded :: (BoundedRational r) => Scientific -> Parser r
bounded s = case boundRational (toRational s) of
    Just r -> pure r
    Nothing -> fail ("out of bounds: " <> show s)

-- | Cost models by Plutus language name.
costModelsOf :: Value -> Parser CostModels
costModelsOf = withObject "cost_models" $ \o -> do
    let language :: Key -> Word8 -> Parser [(Word8, [Int64])]
        language name index =
            o .:? name >>= \case
                Nothing -> pure []
                Just params -> pure [(index, params)]
    v1 <- language "PlutusV1" 0
    v2 <- language "PlutusV2" 1
    v3 <- language "PlutusV3" 2
    mkCostModelsLenient (Map.fromList (v1 <> v2 <> v3))

-- | Decode a @cli_protocol_params@ answer with the ledger's own reader.
decodeCliProtocolParams
    :: Value -> Either DecodeFailure (PParams ConwayEra)
decodeCliProtocolParams = runParser parseJSON

{- | Decode the transaction id a @submittx@ accepted: a JSON string, or
the bare hex text.
-}
decodeSubmitted :: ByteString -> Either DecodeFailure TxId
decodeSubmitted body =
    case eitherDecodeStrict' body of
        Right (String t) -> txIdText t
        Right _ -> Left (DecodeFailure "$" "not a transaction id")
        Left _ -> txIdText (T.strip (TE.decodeUtf8Lenient body))
  where
    txIdText t = runParser (const (txIdOf t)) Null

-- | Decode a @tx_status@ answer.
decodeTxStatuses :: Value -> Either DecodeFailure [TxStatus]
decodeTxStatuses = runParser $ rows $ \o ->
    TxStatus
        <$> (o .: "tx_hash" >>= txIdOf)
        <*> o .:? "num_confirmations"

-- | Decode an @account_info@ answer.
decodeAccountStatuses :: Value -> Either DecodeFailure [AccountStatus]
decodeAccountStatuses = runParser $ rows $ \o ->
    AccountStatus <$> o .: "stake_address" <*> o .: "status"

-- | The bech32 rendering of a Shelley address.
renderAddress :: Addr -> Text
renderAddress a = bech32 hrp (serialiseAddr a)
  where
    hrp = case getNetwork a of
        Mainnet -> "addr"
        Testnet -> "addr_test"

-- | Parse a bech32 address.
parseAddress :: Text -> Either Text Addr
parseAddress t = do
    (hrp, bytes) <- unbech32 t
    unless (hrp `elem` ["addr", "addr_test"]) $
        Left ("not an address: " <> hrp)
    either (Left . T.pack) Right (decodeAddrEither bytes)

-- | The bech32 stake address of a reward account.
renderRewardAccount :: AccountAddress -> Text
renderRewardAccount account@(AccountAddress network _) =
    bech32 hrp (serialiseAccountAddress account)
  where
    hrp = case network of
        Mainnet -> "stake"
        Testnet -> "stake_test"

-- | Parse a bech32 stake address.
parseRewardAccount :: Text -> Either Text AccountAddress
parseRewardAccount t = do
    (hrp, bytes) <- unbech32 t
    unless (hrp `elem` ["stake", "stake_test"]) $
        Left ("not a stake address: " <> hrp)
    maybe
        (Left "not a reward account")
        Right
        (deserialiseAccountAddress bytes)

bech32 :: Text -> ByteString -> Text
bech32 hrp bytes = case Bech32.humanReadablePartFromText hrp of
    Right part -> Bech32.encodeLenient part (Bech32.dataPartFromBytes bytes)
    Left e -> error ("Singular.Provider.Koios.Wire.bech32: " <> show e)

unbech32 :: Text -> Either Text (Text, ByteString)
unbech32 t = case Bech32.decodeLenient t of
    Left e -> Left (T.pack (show e))
    Right (hrp, dat) -> case Bech32.dataPartToBytes dat of
        Just bytes -> Right (Bech32.humanReadablePartToText hrp, bytes)
        Nothing -> Left "bech32 data part is not bytes"

-- | Hex of a transaction id.
txIdHex :: TxId -> Text
txIdHex (TxId h) = hashToTextAsHex (extractHash h)

-- | Hex of a policy id.
policyHex :: PolicyID -> Text
policyHex (PolicyID (ScriptHash h)) = hashToTextAsHex h

-- | Hex of an asset name.
assetNameHex :: AssetName -> Text
assetNameHex (AssetName n) = TE.decodeUtf8 (Base16.encode (SBS.fromShort n))

addressOf :: Text -> Parser Addr
addressOf t = either (fail . T.unpack) pure (parseAddress t)

txIdOf :: Text -> Parser TxId
txIdOf t = TxId . unsafeMakeSafeHash <$> hashOf t

hashOf :: (HashAlgorithm h) => Text -> Parser (Hash h a)
hashOf t = do
    bytes <- hexAny t
    maybe (fail ("not a hash of this size: " <> T.unpack t)) pure $
        hashFromBytes bytes

hexSized :: Int -> Text -> Parser ByteString
hexSized size t = do
    bytes <- hexAny t
    unless (BS.length bytes == size) $
        fail
            ("expected " <> show size <> " bytes, got " <> show (BS.length bytes))
    pure bytes

hexAny :: Text -> Parser ByteString
hexAny t =
    either
        (fail . ("not hex: " <>))
        pure
        (Base16.decode (TE.encodeUtf8 t))

-- | An integer Koios sends as a JSON string or a JSON number.
integral :: Value -> Parser Integer
integral = \case
    String t -> integerText t
    Number n -> case floatingOrInteger n :: Either Double Integer of
        Right i -> pure i
        Left _ -> fail ("not an integer: " <> show n)
    other -> fail ("not an integer: " <> show other)

integerText :: Text -> Parser Integer
integerText t = case reads (T.unpack t) of
    [(n, "")] -> pure n
    _ -> fail ("not an integer: " <> T.unpack t)
