{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.Application
Description : The application a registry pins, as a value
License     : Apache-2.0

A registry pins one application policy at boot (#157 genesis-policy-pins).
This module carries what the registry needs to know of an application
without naming any: a name for receipts and refusals, the executable that
folds its terminations, how the policy is fixed, and the decoder and
holding rules. Each executable composes its value and hands it to the
library.

The pin has four forms: a hash given as input (a registry booted for an
application whose script does not depend on the registry identity), a
blueprint validator title applied to the registry identity (the state
policy then the token name), a blueprint validator title pinned as
compiled (the parameterless form the tests use; production registries
are always identity-scoped), or read from the state datum of a registry
that already exists. 'applyPin' derives the pinned bytes and codes for
the first three; the fourth needs the datum, so only 'resolveRegistry'
passes it after reading the datum, and 'configForApplication' refuses it
by name.

Slice 2: the decoder reads a datum into a holding view (or names why it
cannot); the holding rules find this registry's holding of a key among
the outputs at the application address (refusing a foreign or duplicate
one), release a termination (script, redeemer, recipient and amount), add
the application's part to the fold context, and check a request's carried
datum before an insertion is folded. The neutral value carries none of
them; the open-datum value fills them from the envelope and release.
-}
module Singular.Registry.Application
    ( -- * The pin
      ApplicationPin (..)

      -- * The value
    , Application (..)
    , neutralApplication
    , hashPinnedApplication

      -- * The concrete parts
    , DecodedHolding (..)
    , Decoder (..)
    , HoldingRules (..)

      -- * Generic datum bytes, hashes and JSON (no application named)
    , datumCbor
    , datumHash
    , txOutDatum
    , datumToJson
    , datumFromJson

      -- * Deriving from a pin
    , applyPin
    ) where

import Control.Monad (unless, when)
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Api.Scripts.Data
    ( Datum (..)
    , binaryDataToData
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, datumTxOutL)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.Plutus.Data (Data (..), hashData)
import Lens.Micro ((^.))
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins qualified as Builtins
import PlutusTx.Builtins.Internal
    ( BuiltinByteString (..)
    , BuiltinData (..)
    )

import Singular.Registry.Blueprint (NamingCodes (..), applyBytesParam)
import Singular.Registry.Config (CageConfig)
import Singular.Registry.Ledger (ConwayEra, TokenId, TxIn)
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , scriptHashBytes
    )
import Singular.Registry.TxBuilder.Update
    ( HolderRelease
    , RegistryContext
    )
import Singular.Registry.Types (OnChainRequest)

-- | How the registry's application policy is fixed.
data ApplicationPin
    = -- | A 28-byte policy hash given as input
      PinByHash SBS.ShortByteString
    | -- | The blueprint validator title, applied to the registry identity
      PinByScript Text
    | {- | The blueprint validator title, pinned as compiled: the
      parameterless form the tests use, never a production registry
      -}
      PinAsCompiled Text
    | -- | Read from the state datum of the registry being attached to
      PinFromState
    deriving stock (Eq, Show)

{- | What the registry knows of a holding: the datum it carries and what
the application protects in it. The open datum fills this from the
envelope (control + payload); a future application fills it from its own
datum. The library never names either.
-}
data DecodedHolding = DecodedHolding
    { dhDatumData :: PLC.Data
    -- ^ The full datum, as data
    , dhDatumCbor :: ByteString
    -- ^ Its CBOR, as the ledger hashes it
    , dhDatumHash :: ByteString
    -- ^ Its BLAKE2b-256, as requests and journals name it
    , dhKey :: ByteString
    -- ^ The key the holding belongs to
    , dhDeposit :: Integer
    -- ^ The protected deposit, in lovelace
    , dhController :: ByteString
    -- ^ The controller's payment key hash
    , dhPayload :: PLC.Data
    -- ^ The payload the application leaves unread by the registry
    , dhDatumJson :: Value
    -- ^ The datum as detailed-schema JSON (for receipts)
    , dhPayloadJson :: Value
    -- ^ The payload as detailed-schema JSON (for receipts)
    }
    deriving stock (Eq, Show)

-- | How the application reads a datum: into a holding view, or a named reason.
newtype Decoder = Decoder
    { runDecoder :: TxOut ConwayEra -> Either Text DecodedHolding
    }

instance Show Decoder where
    show _ = "Decoder"

instance Eq Decoder where
    _ == _ = True

{- | How the application holds keys: what the registry needs to fold without
naming the application. Absent on the neutral value; the open datum fills
every field from the envelope and release.
-}
data HoldingRules = HoldingRules
    { hrCheckCarried :: OnChainRequest -> Either Text PLC.Data
    -- ^ The datum an insertion's request must carry to be folded
    , hrFindHoldings
        :: CageConfig
        -> TokenId
        -> ByteString
        -> [(TxIn, TxOut ConwayEra)]
        -> [((TxIn, TxOut ConwayEra), DecodedHolding)]
    {- ^ This registry's holdings of a key among the outputs at the
    application address (a foreign envelope is not one of them)
    -}
    , hrLiveOutputFor
        :: CageConfig
        -> TokenId
        -> ByteString
        -> [(TxIn, TxOut ConwayEra)]
        -> Either Text ((TxIn, TxOut ConwayEra), DecodedHolding)
    -- ^ The key's one live holding, or why there is none (foreign or duplicate)
    , hrReleaseOf
        :: SBS.ShortByteString
        -> (TxIn, TxOut ConwayEra)
        -> Either Text (TxIn, HolderRelease)
    -- ^ How the fold spends one live output: script, redeemer, recipient, amount
    , hrWithApplication
        :: SBS.ShortByteString
        -> Maybe (TxIn, TxOut ConwayEra)
        -> [(TxIn, TxOut ConwayEra)]
        -> RegistryContext
        -> Either Text RegistryContext
    -- ^ The fold context with the application's part added
    }

instance Show HoldingRules where
    show _ = "HoldingRules"

instance Eq HoldingRules where
    _ == _ = True

{- | What the registry knows of an application: a name for receipts and
refusals, the executable that folds its terminations, how the policy is
fixed, and the decoder and holding rules. The neutral value carries none
of the last three; a named value carries all of them.
-}
data Application = Application
    { appName :: Maybe Text
    -- ^ What receipts and refusals call the application; none is neutral
    , appExecutable :: Maybe Text
    -- ^ The binary that folds this application's terminations
    , appPin :: ApplicationPin
    , appDecoder :: Maybe Decoder
    -- ^ Reads a datum into a holding view; absent on the neutral value
    , appHolding :: Maybe HoldingRules
    -- ^ Finds and releases this registry's holding; absent on neutral
    }
    deriving stock (Eq, Show)

{- | The value @singular@ folds with: no name, no executable, no decoder,
no holding rules; the pin is read from the state datum.
-}
neutralApplication :: Application
neutralApplication =
    Application
        { appName = Nothing
        , appExecutable = Nothing
        , appPin = PinFromState
        , appDecoder = Nothing
        , appHolding = Nothing
        }

-- | The neutral value with the pin fixed to the given 28-byte policy hash.
hashPinnedApplication :: SBS.ShortByteString -> Application
hashPinnedApplication policy =
    neutralApplication{appPin = PinByHash policy}

{- | The pinned policy bytes and the codes as the registry runs them, for
a pin that carries its own derivation. 'PinFromState' needs the state
datum, which this function is never given, so it is refused by name;
'resolveRegistry' reads the datum first and passes its pin as 'PinByHash'.
-}
applyPin
    :: ApplicationPin
    -> ByteString
    -- ^ The registry identity: state policy then state token name
    -> NamingCodes
    -- ^ The application and witness codes as the blueprint carries them
    -> (SBS.ShortByteString, NamingCodes)
applyPin pin registryId codes = case pin of
    PinByHash policy -> (policy, codes{ncApplication = SBS.empty})
    PinByScript _title ->
        let applied = applyBytesParam registryId (ncApplication codes)
        in  (pinOf applied, codes{ncApplication = applied})
    PinAsCompiled _title -> (pinOf (ncApplication codes), codes)
    PinFromState ->
        error
            "applyPin: PinFromState reads the pin from the state datum, which this derivation is never given"
  where
    pinOf = SBS.toShort . scriptHashBytes . computeScriptHash

{- | The CBOR of a datum, by the same builtin a script's `serialise_data`
runs. Generic: the library names no application to name it.
-}
datumCbor :: PLC.Data -> ByteString
datumCbor d = case Builtins.serialiseData (BuiltinData d) of
    BuiltinByteString bytes -> bytes

{- | The BLAKE2b-256 of a datum's CBOR: the datum hash a request names.
Generic: the same bytes `envelopeHash` hashes, so an open-datum datum
hash equals its envelope hash byte for byte.
-}
datumHash :: PLC.Data -> ByteString
datumHash d =
    hashToBytes
        (extractHash (hashData (Data d :: Data ConwayEra)))

-- | An output's inline datum, as bytes and hash, when it carries one.
txOutDatum :: TxOut ConwayEra -> Maybe (ByteString, ByteString)
txOutDatum out = case out ^. datumTxOutL of
    Datum bd ->
        let Data d = binaryDataToData bd
        in  Just (datumCbor d, datumHash d)
    _ -> Nothing

{- | The detailed-schema JSON of a datum, naming no application.
Byte-identical to the open datum's `dataToJson` on the same datum.
-}
datumToJson :: PLC.Data -> Value
datumToJson = \case
    PLC.Constr tag fields ->
        Aeson.object
            ["constructor" Aeson..= tag, "fields" Aeson..= map datumToJson fields]
    PLC.Map entries ->
        Aeson.object
            [ "map"
                Aeson..= [ Aeson.object ["k" Aeson..= datumToJson k, "v" Aeson..= datumToJson v]
                         | (k, v) <- entries
                         ]
            ]
    PLC.List items -> Aeson.object ["list" Aeson..= map datumToJson items]
    PLC.I n -> Aeson.object ["int" Aeson..= n]
    PLC.B bytes -> Aeson.object ["bytes" Aeson..= TE.decodeUtf8 (B16.encode bytes)]

{- | A datum from its detailed-schema JSON, or where it is wrong.
Byte-identical to the open datum's `dataFromJson` on the same JSON.
-}
datumFromJson :: Value -> Either String PLC.Data
datumFromJson = \case
    Aeson.Object o -> case sort (map Key.toText (KeyMap.keys o)) of
        ["constructor", "fields"] -> do
            tag <- integer "constructor" =<< field "constructor" o
            when (tag < 0) $ Left "a constructor index is never negative"
            fields <- array "fields" =<< field "fields" o
            PLC.Constr tag <$> mapM datumFromJson fields
        ["map"] -> do
            entries <- array "map" =<< field "map" o
            PLC.Map <$> mapM entry entries
        ["list"] -> do
            items <- array "list" =<< field "list" o
            PLC.List <$> mapM datumFromJson items
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
        Aeson.Number _ | Aeson.Success n <- Aeson.fromJSON x -> Right (n :: Integer)
        _ -> Left (T.unpack name <> " is not an integer")
    hexBytes = \case
        Aeson.String t -> case B16.decode (TE.encodeUtf8 t) of
            Right b -> Right b
            Left _ -> Left "bytes is not hex"
        _ -> Left "bytes is not a string"
    entry = \case
        Aeson.Object e -> do
            unless (sort (KeyMap.keys e) == ["k", "v"]) $
                Left "a map entry is exactly {\"k\": .., \"v\": ..}"
            k <- datumFromJson =<< field "k" e
            v <- datumFromJson =<< field "v" e
            pure (k, v)
        _ -> Left "a map entry is a JSON object"
