{-# LANGUAGE LambdaCase #-}

{- | Exact redacted source observations alongside the consumer's fact
receipts. Raw byte fields retain producer input; they assert no snapshot,
verification, ledger admission or inclusion.
-}
module Singular.Provider.Koios.Evidence (providerEventJson) where

import Data.Aeson (Value, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8)
import Singular.Provider.Koios.Client qualified as Client
import Singular.Provider.Koios.Provider
    ( ProviderEvent (..)
    , TimeSource (..)
    )
import Singular.Provider.Koios.Wire qualified as Wire
import Singular.Registry.Evidence (SessionId (..))
import Singular.Registry.LedgerProvider (Network (..))
import Singular.Registry.NetworkTime (NetworkTimeManifest (..))

hex :: ByteString -> Text
hex = decodeUtf8 . B16.encode

providerEventJson :: ProviderEvent -> Value
providerEventJson = \case
    SessionOpened (SessionId identity) (Network magic) ->
        object
            [ "kind" .= ("acquire" :: Text)
            , "session" .= identity
            , "networkMagic" .= magic
            , "binding" .= ("Unbound" :: Text)
            ]
    SessionClosed (SessionId identity) ->
        object
            ["kind" .= ("release" :: Text), "session" .= identity]
    RawTimeFailure (SessionId identity) failure ->
        object
            [ "kind" .= ("time-source-refusal" :: Text)
            , "session" .= identity
            , "refusal" .= show failure
            ]
    RawTime (SessionId identity) (TimeSource manifest genesis eras) ->
        object
            [ "kind" .= ("raw-time" :: Text)
            , "session" .= identity
            , "networkMagic" .= timeNetworkMagic manifest
            , "systemStartMs" .= timeSystemStartMs manifest
            , "genesisSha256" .= hex (timeGenesisSha256 manifest)
            , "eraHistorySha256" .= hex (timeEraHistorySha256 manifest)
            , "horizonSlot" .= timeHorizonSlot manifest
            , "protocolMajor" .= timeProtocolMajor manifest
            , "sourceIdentity" .= timeSourceIdentity manifest
            , "genesisHex" .= hex genesis
            , "eraHistoryCbor" .= hex eras
            ]
    RawExchange (SessionId identity) request exchange ->
        object
            [ "kind" .= ("raw-exchange" :: Text)
            , "session" .= identity
            , "call" .= Wire.callName (Client.rawCall request)
            , "method" .= show (Client.rawMethod request)
            , "path" .= Client.rawPath request
            , "query" .= Client.rawQuery request
            , "headers" .= Client.rawHeaders request
            , "body" .= bodyJson (Client.rawBody request)
            , "attempts" .= Client.exchangeAttempts exchange
            , "result" .= case Client.exchangeResult exchange of
                Left refusal -> object ["noAnswer" .= show refusal]
                Right answer ->
                    object
                        [ "status" .= Client.answerStatus answer
                        , "headers" .= Client.answerHeaders answer
                        , "bodyHex" .= hex (Client.answerBody answer)
                        ]
            ]
  where
    bodyJson Wire.NoBody = object ["kind" .= ("none" :: Text)]
    bodyJson (Wire.JsonBody document) =
        object
            ["kind" .= ("json" :: Text), "value" .= document]
    bodyJson (Wire.CborBody bytes) =
        object
            ["kind" .= ("cbor" :: Text), "bytesHex" .= hex bytes]
