{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}

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
into the answer.
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

      -- * Bech32 renderings
    , renderAddress
    , parseAddress
    , renderRewardAccount
    , parseRewardAccount
    ) where

import Data.Aeson (Value)
import Data.ByteString (ByteString)
import Data.Kind (Type)
import Data.Text (Text)
import Data.Word (Word64)

import Cardano.Ledger.Address (AccountAddress, Addr)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.BaseTypes (EpochNo)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams)
import Cardano.Ledger.Mary.Value (AssetName, PolicyID)
import Cardano.Ledger.TxIn (TxId, TxIn)
import Cardano.Slotting.Slot (SlotNo)
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
callName = notImplemented

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

-- | @tip@: the chain tip.
tipRequest :: Request 'Read
tipRequest = notImplemented

-- | @address_utxos@, extended, ordered by output reference.
addressUtxosRequest :: [Addr] -> Request 'Read
addressUtxosRequest = notImplemented

-- | @asset_utxos@, extended, ordered by output reference.
assetUtxosRequest :: [(PolicyID, AssetName)] -> Request 'Read
assetUtxosRequest = notImplemented

{- | @asset_txs@ with history: every transaction that moved the asset,
ordered by block height then transaction.
-}
assetTxsRequest :: PolicyID -> AssetName -> Request 'Read
assetTxsRequest = notImplemented

-- | @tx_info@ with inputs, scripts and bytecode.
txInfoRequest :: [TxId] -> Request 'Read
txInfoRequest = notImplemented

-- | @tx_cbor@: the raw transactions.
txCborRequest :: [TxId] -> Request 'Read
txCborRequest = notImplemented

-- | @epoch_params@ of one epoch.
epochParamsRequest :: EpochNo -> Request 'Read
epochParamsRequest = notImplemented

{- | @cli_protocol_params@: the current protocol parameters in the
node's own JSON form.
-}
cliProtocolParamsRequest :: Request 'Read
cliProtocolParamsRequest = notImplemented

-- | @submittx@: submit a signed transaction's CBOR.
submitTxRequest :: ByteString -> Request 'Submission
submitTxRequest = notImplemented

-- | @tx_status@: confirmations of transactions.
txStatusRequest :: [TxId] -> Request 'Read
txStatusRequest = notImplemented

-- | @account_info@ of one stake address.
accountInfoRequest :: AccountAddress -> Request 'Read
accountInfoRequest = notImplemented

-- | The chain tip.
data Tip = Tip
    { tipSlot :: SlotNo
    , tipBlockHash :: ByteString
    , tipBlockHeight :: Word64
    , tipEpoch :: EpochNo
    }
    deriving stock (Eq, Show)

-- | One transaction that moved an asset.
data AssetTx = AssetTx
    { assetTxId :: TxId
    , assetTxBlockHeight :: Word64
    , assetTxEpoch :: EpochNo
    }
    deriving stock (Eq, Show)

{- | One transaction's resolved outputs: the outputs it spent, the
outputs it referenced and the outputs it created, each with its output
reference.
-}
data TxInfo = TxInfo
    { txInfoId :: TxId
    , txInfoInputs :: [(TxIn, TxOut ConwayEra)]
    , txInfoReferenceInputs :: [(TxIn, TxOut ConwayEra)]
    , txInfoOutputs :: [(TxIn, TxOut ConwayEra)]
    }
    deriving stock (Eq, Show)

{- | One transaction's raw bytes, decoded as a Conway transaction whose
id is the one Koios named.
-}
data TxCbor = TxCbor
    { txCborId :: TxId
    , txCborBytes :: ByteString
    , txCborTx :: ConwayTx
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
    -- ^ JSON path into the answer, or the byte position of a syntax error
    , decodeReason :: Text
    }
    deriving stock (Eq, Show)

{- | Parse an answer body as one JSON document. A body that is not one,
such as a body cut off mid-array, fails at the byte position the parser
reached.
-}
parseBody :: ByteString -> Either DecodeFailure Value
parseBody = notImplemented

-- | Decode a @tip@ answer: empty when Koios returned no row.
decodeTip :: Value -> Either DecodeFailure [Tip]
decodeTip = notImplemented

-- | Decode the rows of an @address_utxos@ or @asset_utxos@ page.
decodeUtxos :: Value -> Either DecodeFailure [(TxIn, TxOut ConwayEra)]
decodeUtxos = notImplemented

-- | Decode the rows of an @asset_txs@ page.
decodeAssetTxs :: Value -> Either DecodeFailure [AssetTx]
decodeAssetTxs = notImplemented

-- | Decode a @tx_info@ answer.
decodeTxInfos :: Value -> Either DecodeFailure [TxInfo]
decodeTxInfos = notImplemented

-- | Decode a @tx_cbor@ answer, each transaction checked against its id.
decodeTxCbors :: Value -> Either DecodeFailure [TxCbor]
decodeTxCbors = notImplemented

-- | Decode an @epoch_params@ answer: empty when Koios returned no row.
decodeEpochParams :: Value -> Either DecodeFailure [PParams ConwayEra]
decodeEpochParams = notImplemented

-- | Decode a @cli_protocol_params@ answer with the ledger's own reader.
decodeCliProtocolParams
    :: Value -> Either DecodeFailure (PParams ConwayEra)
decodeCliProtocolParams = notImplemented

-- | Decode the transaction id a @submittx@ accepted.
decodeSubmitted :: ByteString -> Either DecodeFailure TxId
decodeSubmitted = notImplemented

-- | Decode a @tx_status@ answer.
decodeTxStatuses :: Value -> Either DecodeFailure [TxStatus]
decodeTxStatuses = notImplemented

-- | Decode an @account_info@ answer.
decodeAccountStatuses :: Value -> Either DecodeFailure [AccountStatus]
decodeAccountStatuses = notImplemented

-- | The bech32 rendering of an address.
renderAddress :: Addr -> Text
renderAddress = notImplemented

-- | Parse a bech32 address.
parseAddress :: Text -> Either Text Addr
parseAddress = notImplemented

-- | The bech32 stake address of a reward account.
renderRewardAccount :: AccountAddress -> Text
renderRewardAccount = notImplemented

-- | Parse a bech32 stake address.
parseRewardAccount :: Text -> Either Text AccountAddress
parseRewardAccount = notImplemented

notImplemented :: a
notImplemented = error "Singular.Provider.Koios.Wire: not implemented"
