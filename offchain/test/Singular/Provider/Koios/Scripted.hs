{- |
Module      : Singular.Provider.Koios.Scripted
Description : In-memory Koios transports for client tests
License     : Apache-2.0

A transport answering from a script, recording every raw request it is
handed, and helpers to build Koios-shaped page answers. The client
under test sees exactly what a live transport would hand it: raw
status, headers and body.
-}
module Singular.Provider.Koios.Scripted
    ( scriptedTransport
    , koiosWith
    , okJson
    , pageAnswer
    , assetTxRow
    , queryParam
    , txIdOfByte
    , scriptHashOfByte
    , signedTransaction
    ) where

import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word8)

import Cardano.Crypto.DSIGN (genKeyDSIGN)
import Cardano.Crypto.Hash.Class (hashFromBytes)
import Cardano.Crypto.Seed (mkSeedFromBytes)
import Cardano.Ledger.Core (mkBasicTx, mkBasicTxBody)
import Cardano.Ledger.Hashes (ScriptHash (..), unsafeMakeSafeHash)
import Cardano.Ledger.TxIn (TxId (..))

import Singular.Provider.Koios.Client
    ( Answer (..)
    , ClientConfig (..)
    , Exchange (..)
    , Koios (..)
    , RawRequest (..)
    , Transport (..)
    )
import Singular.Registry.Signing (SignedTx, signTx)

{- | An empty transaction with a real witness from a deterministic test key.
It exercises signed serialization, not ledger acceptance or funding.
-}
signedTransaction :: SignedTx
signedTransaction =
    signTx
        (genKeyDSIGN (mkSeedFromBytes (BS.replicate 32 1)))
        (mkBasicTx mkBasicTxBody)

{- | A transport answering each request with the script's exchange,
given the request and how many requests preceded it. The second action
reads the requests handed over so far, in order.
-}
scriptedTransport
    :: (RawRequest -> Int -> IO Exchange)
    -> IO (Transport IO, IO [RawRequest])
scriptedTransport script = do
    seen <- newIORef []
    let send raw = do
            n <- atomicModifyIORef' seen (\xs -> (xs <> [raw], length xs))
            script raw n
    pure (Transport send, readIORef seen)

-- | A client over a transport with this page size and ceiling.
koiosWith :: Int -> Int -> Transport IO -> Koios IO
koiosWith size ceiling' =
    Koios ClientConfig{pageSize = size, pageCeiling = ceiling'}

-- | A one-attempt 200 answer with a JSON body and these headers.
okJson :: [(Text, Text)] -> ByteString -> Exchange
okJson headers body =
    Exchange
        { exchangeAttempts = 1
        , exchangeResult =
            Right
                Answer
                    { answerStatus = 200
                    , answerHeaders = ("content-type", "application/json") : headers
                    , answerBody = body
                    }
        }

{- | The honest page of these rows at an offset and limit, with the
exact-count range header Koios sends.
-}
pageAnswer :: [Value] -> Int -> Int -> Exchange
pageAnswer rows offset limit =
    let page = take limit (drop offset rows)
        total = length rows
        range
            | null page = "*/" <> tshow total
            | otherwise =
                tshow offset
                    <> "-"
                    <> tshow (offset + length page - 1)
                    <> "/"
                    <> tshow total
    in  okJson [("content-range", range)] (BSL.toStrict (encode page))

-- | An @asset_txs@ row.
assetTxRow :: Text -> Integer -> Integer -> Value
assetTxRow txHash epoch height =
    object
        [ "tx_hash" .= txHash
        , "epoch_no" .= epoch
        , "block_height" .= height
        , "block_time" .= (1700000000 + height)
        ]

-- | A query parameter of a raw request.
queryParam :: Text -> RawRequest -> Maybe Text
queryParam key raw = lookup key (rawQuery raw)

-- | A transaction id of 32 copies of one byte.
txIdOfByte :: Word8 -> TxId
txIdOfByte b =
    TxId . unsafeMakeSafeHash . fromMaybe (error "txIdOfByte") $
        hashFromBytes (BS.replicate 32 b)

-- | A script hash of 28 copies of one byte.
scriptHashOfByte :: Word8 -> ScriptHash
scriptHashOfByte b =
    ScriptHash . fromMaybe (error "scriptHashOfByte") $
        hashFromBytes (BS.replicate 28 b)

tshow :: (Show a) => a -> Text
tshow = T.pack . show
