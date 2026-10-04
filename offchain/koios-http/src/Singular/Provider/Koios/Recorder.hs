{- |
Module      : Singular.Provider.Koios.Recorder
Description : Read-only Koios probe and fixture recorder
License     : Apache-2.0

The read requests a person can name on the command line, a probe that
prints the decoded facts of one of them, and the recorder that writes
the raw answers behind them as fixtures for
"Singular.Provider.Koios.Recorded".

The request type has no submission case: 'ReadCall' enumerates every
call a 'ReadRequest' can make, and each is built from a
@'Singular.Provider.Koios.Wire.Request' ''Read'@. The recorder runs
the same typed calls the probe does, over the live transport, and
writes every exchange they make — page by page — with its request, the
Koios schema revision, the time and the SHA-256 of the body. Headers are
not recorded, so a bearer token never reaches a fixture.
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

import Data.ByteString (ByteString)
import Data.Text (Text)

import Cardano.Ledger.Address (AccountAddress, Addr)
import Cardano.Ledger.BaseTypes (EpochNo)
import Cardano.Ledger.Mary.Value (AssetName, PolicyID)
import Cardano.Ledger.TxIn (TxId)

import Singular.Provider.Koios.Client
    ( ClientConfig
    , ClientFailure
    , FailureReason
    , Koios
    )
import Singular.Provider.Koios.Http (HttpConfig)
import Singular.Provider.Koios.Wire (Call)

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
readCallName = notImplemented

-- | The Koios call a read call makes.
readCallCall :: ReadCall -> Call
readCallCall = notImplemented

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
readRequestCall = notImplemented

{- | Parse @<call>@ or @<call>:<argument>[,<argument>]@, where the call
is a 'readCallName': an address or stake address in bech32, an asset as
@<policy hex>.<name hex>@, transaction hashes in hex, an epoch number.
-}
parseReadRequest :: Text -> Either Text ReadRequest
parseReadRequest = notImplemented

-- | Run one read request and render its decoded facts, one per line.
probe :: Koios IO -> ReadRequest -> IO (Either ClientFailure [Text])
probe = notImplemented

-- | Where and how to record.
data RecorderConfig = RecorderConfig
    { recorderHttp :: HttpConfig
    , recorderClient :: ClientConfig
    , recorderDirectory :: FilePath
    }

-- | Why recording stopped.
data RecordFailure
    = -- | The live transport could not be built
      RecordTransport FailureReason
    | -- | The schema document could not be read or carries no revision
      RecordSchema Text
    | -- | A request's call failed; fixtures written so far are kept
      RecordCall ReadRequest ClientFailure
    deriving stock (Show)

{- | The schema document of a base URL: @koiosapi.yaml@ at its origin,
as Koios serves it (@https://preprod.koios.rest/koiosapi.yaml@ for
@https://preprod.koios.rest/api/v1@).
-}
schemaUrlOf :: Text -> Text
schemaUrlOf = notImplemented

-- | The @info.version@ of a Koios OpenAPI document.
parseSchemaRevision :: ByteString -> Either Text Text
parseSchemaRevision = notImplemented

{- | Record every exchange the requests make into the directory, and
return the files written.
-}
recordFixtures
    :: RecorderConfig
    -> [ReadRequest]
    -> IO (Either RecordFailure [FilePath])
recordFixtures = notImplemented

notImplemented :: a
notImplemented = error "Singular.Provider.Koios.Recorder: not implemented"
