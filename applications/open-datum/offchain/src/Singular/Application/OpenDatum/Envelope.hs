{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.Envelope
Description : The open-datum application's datum, its CBOR, hash and JSON
License     : Apache-2.0

An open-datum output carries its 'Envelope' inline: a protected
'Control' the application checks, and a payload it never reads. The
payload is any Plutus @PLC.Data@ — constructor, map, list, integer or
byte string, nested to any depth — so no payload is refused for what
it says. On the wire (the same shape @onchain/validators/application/
envelope.ak@ declares):

@
Envelope = Constr 0 [control, payload]
Control  = Constr 0 [ I version
                    , Constr 0 [B statePolicy, B stateName]
                    , B activePolicy, B key, B controller, I deposit ]
@

The model (@OpenDatumApplication.Model@) states these fields over
abstract numbers and a stand-in hash. The correspondence is this
representation mapping, checked by golden vectors this module and the
Aiken tests share; it is not a proof, and a model number is never
compared with a ledger byte string.

The external form a caller writes is the detailed JSON schema of Plutus
data: @{"constructor": n, "fields": [..]}@, @{"map": [{"k": .., "v":
..}]}@, @{"list": [..]}@, @{"int": n}@ and @{"bytes": "hex"}@, one key
set per value, nothing else admitted.
-}
module Singular.Application.OpenDatum.Envelope
    ( -- * The envelope
      StateAsset (..)
    , Control (..)
    , Envelope (..)
    , envelopeVersion
    , registryBytes

      -- * Plutus data
    , controlToData
    , controlFromData
    , envelopeToData
    , envelopeFromData

      -- * CBOR and hash
    , dataCbor
    , envelopeCbor
    , envelopeHash

      -- * External JSON
    , dataToJson
    , dataFromJson
    , envelopeToJson
    , envelopeFromJson
    ) where

import Control.Monad (unless, when)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.List (sort)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.Plutus.Data (Data (..), hashData)
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins qualified as Builtins
import PlutusTx.Builtins.Internal
    ( BuiltinByteString (..)
    , BuiltinData (..)
    )

-- | The registry an envelope names: the full native asset of its state token.
data StateAsset = StateAsset
    { saPolicy :: ByteString
    , saName :: ByteString
    }
    deriving stock (Eq, Show)

-- | The protected part of an envelope; an update never changes it.
data Control = Control
    { ctlVersion :: Integer
    , ctlRegistry :: StateAsset
    , ctlActivePolicy :: ByteString
    , ctlKey :: ByteString
    , ctlController :: ByteString
    -- ^ The controller's payment key hash
    , ctlDeposit :: Integer
    -- ^ The protected deposit, in lovelace
    }
    deriving stock (Eq, Show)

-- | An open-datum output's inline datum.
data Envelope = Envelope
    { envControl :: Control
    , envPayload :: PLC.Data
    }
    deriving stock (Eq, Show)

-- | The only envelope version the application admits.
envelopeVersion :: Integer
envelopeVersion = 1

-- | The registry identity bytes: state policy followed by state token name.
registryBytes :: StateAsset -> ByteString
registryBytes (StateAsset p n) = p <> n

controlToData :: Control -> PLC.Data
controlToData c =
    PLC.Constr
        0
        [ PLC.I (ctlVersion c)
        , PLC.Constr
            0
            [PLC.B (saPolicy (ctlRegistry c)), PLC.B (saName (ctlRegistry c))]
        , PLC.B (ctlActivePolicy c)
        , PLC.B (ctlKey c)
        , PLC.B (ctlController c)
        , PLC.I (ctlDeposit c)
        ]

-- | The control a datum encodes, or why it is not one.
controlFromData :: PLC.Data -> Either String Control
controlFromData = \case
    PLC.Constr
        0
        [ PLC.I version
            , PLC.Constr 0 [PLC.B policy, PLC.B name]
            , PLC.B active
            , PLC.B key
            , PLC.B controller
            , PLC.I deposit
            ] ->
            Right
                Control
                    { ctlVersion = version
                    , ctlRegistry = StateAsset policy name
                    , ctlActivePolicy = active
                    , ctlKey = key
                    , ctlController = controller
                    , ctlDeposit = deposit
                    }
    _ ->
        Left
            "the control is not Constr 0 [version, Constr 0 [statePolicy, \
            \stateName], activePolicy, key, controller, deposit]"

envelopeToData :: Envelope -> PLC.Data
envelopeToData e = PLC.Constr 0 [controlToData (envControl e), envPayload e]

-- | The envelope a datum encodes. The payload is taken as it is.
envelopeFromData :: PLC.Data -> Either String Envelope
envelopeFromData = \case
    PLC.Constr 0 [control, payload] -> do
        c <- controlFromData control
        pure (Envelope c payload)
    _ -> Left "the envelope is not Constr 0 [control, payload]"

{- | The CBOR of a datum, by the same builtin a script's `serialise_data`
(Aiken `cbor.serialise`) runs.
-}
dataCbor :: PLC.Data -> ByteString
dataCbor d = case Builtins.serialiseData (BuiltinData d) of
    BuiltinByteString bytes -> bytes

envelopeCbor :: Envelope -> ByteString
envelopeCbor = dataCbor . envelopeToData

{- | The BLAKE2b-256 of the envelope's CBOR: the datum hash a request names
for the output that will carry the envelope inline.
-}
envelopeHash :: Envelope -> ByteString
envelopeHash e =
    hashToBytes
        (extractHash (hashData (Data (envelopeToData e) :: Data ConwayEra)))

-- ---------------------------------------------------------
-- External JSON
-- ---------------------------------------------------------

-- | The detailed-schema JSON of a Plutus datum.
dataToJson :: PLC.Data -> Value
dataToJson = \case
    PLC.Constr tag fields ->
        object ["constructor" .= tag, "fields" .= map dataToJson fields]
    PLC.Map entries ->
        object
            [ "map"
                .= [ object ["k" .= dataToJson k, "v" .= dataToJson v] | (k, v) <- entries
                   ]
            ]
    PLC.List items -> object ["list" .= map dataToJson items]
    PLC.I n -> object ["int" .= n]
    PLC.B bytes -> object ["bytes" .= TE.decodeUtf8 (B16.encode bytes)]

-- | Read the detailed-schema JSON of a Plutus datum, or say where it is wrong.
dataFromJson :: Value -> Either String PLC.Data
dataFromJson = \case
    Object o -> case sort (map Key.toText (KeyMap.keys o)) of
        ["constructor", "fields"] -> do
            tag <- integer "constructor" =<< field "constructor" o
            when (tag < 0) $ Left "a constructor index is never negative"
            fields <- array "fields" =<< field "fields" o
            PLC.Constr tag <$> mapM dataFromJson fields
        ["map"] -> do
            entries <- array "map" =<< field "map" o
            PLC.Map <$> mapM entry entries
        ["list"] -> do
            items <- array "list" =<< field "list" o
            PLC.List <$> mapM dataFromJson items
        ["int"] -> PLC.I <$> (integer "int" =<< field "int" o)
        ["bytes"] -> PLC.B <$> (hexBytes =<< field "bytes" o)
        keys ->
            Left
                ( "a datum is one of constructor+fields, map, list, int, \
                  \bytes; found keys "
                    <> show keys
                )
    _ -> Left "a datum is a JSON object"
  where
    field name o =
        maybe
            (Left ("missing " <> T.unpack name))
            Right
            (KeyMap.lookup (Key.fromText name) o)
    array name x = case Aeson.fromJSON x :: Aeson.Result [Value] of
        Aeson.Success xs -> Right xs
        Aeson.Error _ -> Left (T.unpack name <> " is not an array")
    integer name x = case x of
        Number _ | Aeson.Success n <- Aeson.fromJSON x -> Right (n :: Integer)
        _ -> Left (T.unpack name <> " is not an integer")
    hexBytes = \case
        String t -> case B16.decode (TE.encodeUtf8 t) of
            Right b -> Right b
            Left _ -> Left "bytes is not hex"
        _ -> Left "bytes is not a string"
    entry = \case
        Object e -> do
            unless (sort (KeyMap.keys e) == ["k", "v"]) $
                Left "a map entry is exactly {\"k\": .., \"v\": ..}"
            k <- dataFromJson =<< field "k" e
            v <- dataFromJson =<< field "v" e
            pure (k, v)
        _ -> Left "a map entry is a JSON object"

envelopeToJson :: Envelope -> Value
envelopeToJson = dataToJson . envelopeToData

{- | An envelope from its detailed-schema JSON: the control must have its
exact shape; the payload may be anything.
-}
envelopeFromJson :: Value -> Either String Envelope
envelopeFromJson v = envelopeFromData =<< dataFromJson v
