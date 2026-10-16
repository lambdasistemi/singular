{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Singular.Registry.Bundle
Description : The bundle of unsigned transactions: types, codec, envelopes, offline checks
License     : Apache-2.0

A bundle is what a write command hands an offline signer: one JSON file
holding the addresses that must sign and the unsigned transactions in
submission order, each as the standard @cardano-cli@ text envelope of an
unsigned Conway transaction — the complete transaction, body, empty
witness set, validity flag and auxiliary data, exactly the bytes the
official tool writes. This module owns the bundle and nothing else: its
types, its JSON codec, the text envelope of a transaction and of a
detached witness, and the offline consistency checks. It is pure — no
files, no clock, no network, no key store.

Everything a bundle says about itself is checked before it is signed:
the recorded identity must be the hash of the decoded transaction's
body, the recorded deadline must be the body's validity upper bound,
the identities must be distinct, and every key hash a body requires
must be the key hash of an address among the bundle's signers. The
effects lines are the writer's claims: they are carried and shown,
never trusted. Whether the signers list is complete cannot be checked
offline — that is the submitting command's judgement.
-}
module Singular.Registry.Bundle
    ( Bundle (..)
    , BundleTransaction (..)
    , TextEnvelope (..)
    , DetachedWitness (..)
    , BundleRefusal (..)
    , renderBundleRefusal
    , bundleVersion
    , bodyIdentity
    , bodyDeadline
    , transactionEnvelopeType
    , acceptedTransactionEnvelopeTypes
    , hexText
    , encodeBundle
    , decodeBundle
    , checkBundle
    , transactionEnvelope
    , decodeTransactionEnvelope
    , encodeTextEnvelope
    , witnessEnvelope
    , decodeWitnessEnvelope
    ) where

import Cardano.Crypto.Hash (hashToBytes)
import Cardano.Ledger.Address (Addr (..), decodeAddrEither)
import Cardano.Ledger.Alonzo.TxBody (reqSignerHashesTxBodyL)
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body (ValidityInterval (..), vldtTxBodyL)
import Cardano.Ledger.BaseTypes (SlotNo (..), StrictMaybe (..))
import Cardano.Ledger.Binary
    ( Decoder
    , EncCBOR (..)
    , Encoding
    , decCBOR
    , decodeBytes
    , decodeFullAnnotator
    , decodeFullDecoder
    , decodeListLenOf
    , encodeBytes
    , encodeListLen
    , serialize'
    )
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (eraProtVerHigh, extractHash)
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Keys (unKeyHash)
import Cardano.Ledger.TxIn (TxId (..))
import Cardano.Tx.Ledger (ConwayTx)
import Codec.Binary.Bech32 qualified as Bech32
import Control.Monad (forM_, unless)
import Data.Aeson
    ( FromJSON
    , Value (..)
    , eitherDecodeStrict
    , encode
    , fromJSON
    , object
    , (.=)
    )
import Data.Aeson.Key (fromString)
import Data.Aeson.KeyMap (KeyMap)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Result (..))
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BSL
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word32, Word64)
import Lens.Micro ((^.))

{- | The version this codec writes and the only one it reads. A bundle
carrying any other version is refused by name.
-}
bundleVersion :: Word
bundleVersion = 1

-- | The envelope type this codec writes for an unsigned transaction.
transactionEnvelopeType :: Text
transactionEnvelopeType = "Unwitnessed Tx ConwayEra"

{- | The envelope types read for an unsigned transaction: this codec's
own label, and the one the official @cardano-cli@ writes.
-}
acceptedTransactionEnvelopeTypes :: [Text]
acceptedTransactionEnvelopeTypes =
    [transactionEnvelopeType, "Tx ConwayEra"]

-- | The envelope type of a detached verification-key witness.
witnessEnvelopeType :: Text
witnessEnvelopeType = "TxWitness ConwayEra"

{- | The description the official @cardano-cli@ writes for one key
witness; this codec writes the same.
-}
witnessEnvelopeDescription :: Text
witnessEnvelopeDescription = "Key Witness ShelleyEra"

-- | The text envelope of a transaction or of a detached witness.
data TextEnvelope = TextEnvelope
    { envelopeType :: Text
    -- ^ the @type@ field, naming what the CBOR carries
    , envelopeDescription :: Text
    -- ^ the @description@ field, as the writer spelled it
    , envelopeCborHex :: Text
    -- ^ the @cborHex@ field, the CBOR bytes in hex
    }
    deriving stock (Eq, Show)

{- | One unsigned transaction of a bundle: its recorded identity, its
text envelope, its recorded deadline and the effects its writer claims.
The identity and the deadline are the writer's statements about the
transaction; 'checkBundle' proves them against it.
-}
data BundleTransaction = BundleTransaction
    { bundleTxIdentity :: ByteString
    -- ^ the 32 bytes of the body's hash, as the bundle records it
    , bundleTxEnvelope :: TextEnvelope
    -- ^ the transaction's text envelope, @Unwitnessed Tx ConwayEra@
    , bundleTxDeadline :: Maybe Word64
    -- ^ the body's validity upper bound as a slot number, or nothing
    , bundleTxEffects :: [Text]
    -- ^ the writer's claims, each one line, shown and never trusted
    }
    deriving stock (Eq, Show)

{- | A bundle: version 1, the command name that wrote it, the network
magic its transactions are built for, the registry state token (nothing
before a registry exists), the addresses that must sign, and the
transactions in submission order.
-}
data Bundle = Bundle
    { bundleCommand :: Text
    -- ^ the command name that wrote the bundle
    , bundleNetworkMagic :: Word32
    -- ^ the network the transactions are built for
    , bundleStateToken :: Maybe Text
    -- ^ the registry's state token, or nothing before one exists
    , bundleSigners :: NonEmpty Text
    -- ^ the bech32 addresses that must sign
    , bundleTransactions :: NonEmpty BundleTransaction
    -- ^ the transactions in submission order
    }
    deriving stock (Eq, Show)

{- | A verification-key witness detached from any transaction: the
public key and the signature over the body hash, as bytes.
-}
data DetachedWitness = DetachedWitness
    { detachedKeyBytes :: ByteString
    -- ^ the 32 bytes of the verification key
    , detachedSignatureBytes :: ByteString
    -- ^ the 64 bytes of the signature
    }
    deriving stock (Eq, Show)

-- | Why a bundle was refused. None names a passphrase or a key.
data BundleRefusal
    = -- | the bundle's version, which this codec does not read
      BundleUnknownVersion Word
    | -- | a field of the bundle, and what is wrong with it
      BundleField String String
    | {- | an envelope whose type is not one of the accepted ones,
      naming the type it carries
      -}
      BundleEnvelopeWrongType Text
    | {- | an envelope whose CBOR is not a decodable Conway transaction,
      naming the identity it is recorded under
      -}
      BundleEnvelopeUndecodable String
    | {- | a recorded identity that is not the hash of the transaction's
      body, carrying both hashes
      -}
      BundleIdentityMismatch ByteString ByteString
    | {- | a recorded deadline that is not the body's validity upper
      bound, carrying both bounds and the identity
      -}
      BundleDeadlineMismatch (Maybe Word64) (Maybe Word64) ByteString
    | -- | an identity recorded for two transactions
      BundleDuplicateIdentity ByteString
    | {- | a key hash a body requires and no signer address covers,
      carrying the key hash and the body's identity
      -}
      BundleSignerNotCovered ByteString ByteString
    deriving stock (Eq, Show)

-- | One line naming the refusal, carrying what it concerns and no secret.
renderBundleRefusal :: BundleRefusal -> String
renderBundleRefusal = \case
    BundleUnknownVersion v ->
        "the bundle's version is "
            <> show v
            <> ", and this singular reads only version "
            <> show bundleVersion
    BundleField name why -> "the bundle's " <> name <> " field " <> why
    BundleEnvelopeWrongType found ->
        "the transaction envelope's type is \""
            <> Text.unpack found
            <> "\", not \""
            <> Text.unpack transactionEnvelopeType
            <> "\""
    BundleEnvelopeUndecodable identity ->
        "the transaction envelope recorded as "
            <> identity
            <> " does not decode to a Conway transaction"
    BundleIdentityMismatch recorded actual ->
        "the transaction's recorded identity "
            <> hexText recorded
            <> " is not the hash of its body, "
            <> hexText actual
    BundleDeadlineMismatch recorded actual identity ->
        "the transaction "
            <> hexText identity
            <> " records deadline "
            <> boundText recorded
            <> " and its body's validity upper bound is "
            <> boundText actual
    BundleDuplicateIdentity identity ->
        "the identity " <> hexText identity <> " names two transactions"
    BundleSignerNotCovered keyHash identity ->
        "the key hash "
            <> hexText keyHash
            <> " is required by the transaction "
            <> hexText identity
            <> " and no signer address covers it"
  where
    boundText = maybe "none" show

-- | Bytes as lowercase hex, the envelope's and refusal's spelling.
hexText :: ByteString -> String
hexText = BC.unpack . B16.encode

{- | The hash of a transaction's body, as the ledger computes a
transaction id: the identity a bundle records.
-}
bodyIdentity :: ConwayTx -> ByteString
bodyIdentity tx = hashToBytes (extractHash h)
  where
    TxId h = txIdTx tx

-- | The body's validity upper bound, read as the deadline it is.
bodyDeadline :: ConwayTx -> Maybe Word64
bodyDeadline tx = case tx ^. bodyTxL . vldtTxBodyL of
    ValidityInterval _ (SJust (SlotNo n)) -> Just n
    ValidityInterval _ SNothing -> Nothing

{- | The JSON bytes of a bundle: version, command, network magic, state
token, signers and transactions in submission order. Deterministic:
the same bundle encodes to the same bytes.
-}
encodeBundle :: Bundle -> ByteString
encodeBundle bundle = BSL.toStrict (encode (bundleValue bundle))
  where
    bundleValue b =
        object
            [ "version" .= bundleVersion
            , "command" .= bundleCommand b
            , "networkMagic" .= bundleNetworkMagic b
            , "stateToken" .= bundleStateToken b
            , "signers" .= toList (bundleSigners b)
            , "transactions" .= map txValue (toList (bundleTransactions b))
            ]
    txValue tx =
        object
            [ "identity" .= Text.pack (hexText (bundleTxIdentity tx))
            , "envelope" .= envelopeValue (bundleTxEnvelope tx)
            , "deadline" .= bundleTxDeadline tx
            , "effects" .= bundleTxEffects tx
            ]

-- | The envelope as a JSON value, the shape a bundle embeds.
envelopeValue :: TextEnvelope -> Value
envelopeValue envelope =
    object
        [ "type" .= envelopeType envelope
        , "description" .= envelopeDescription envelope
        , "cborHex" .= envelopeCborHex envelope
        ]

-- | The text envelope's JSON bytes, as a file holds them.
encodeTextEnvelope :: TextEnvelope -> ByteString
encodeTextEnvelope = BSL.toStrict . encode . envelopeValue

{- | The text envelope of an unsigned transaction: type
@Unwitnessed Tx ConwayEra@, the ledger CDDL description, and the
complete transaction's CBOR in hex — body, empty witness set,
validity flag and auxiliary data, the shape the official
@cardano-cli@ writes and every Cardano tool reads — serialized at the
Conway protocol version.
-}
transactionEnvelope :: ConwayTx -> TextEnvelope
transactionEnvelope tx =
    TextEnvelope
        { envelopeType = transactionEnvelopeType
        , envelopeDescription = "Ledger Cddl Format"
        , envelopeCborHex =
            Text.pack (hexText (serialize' (eraProtVerHigh @ConwayEra) tx))
        }

{- | The envelope's decoding: the complete Conway transaction its CBOR
carries — body, witness set, validity flag and auxiliary data — or
the decode error. A bare body is not a transaction and does not
decode. Pure.
-}
decodeTransactionEnvelope :: TextEnvelope -> Either String ConwayTx
decodeTransactionEnvelope envelope = do
    payload <- hexOf (envelopeCborHex envelope)
    first
        (const "the cborHex does not decode to a Conway transaction")
        ( decodeFullAnnotator
            (eraProtVerHigh @ConwayEra)
            "ConwayTx"
            decCBOR
            (BSL.fromStrict payload)
        )

{- | The text envelope of a detached witness: type
@TxWitness ConwayEra@, the description the official @cardano-cli@
writes for one key witness, and the CBOR of the witness itself in
hex — an array of the 32 key bytes and the 64 signature bytes.
-}
witnessEnvelope :: DetachedWitness -> TextEnvelope
witnessEnvelope witness =
    TextEnvelope
        { envelopeType = witnessEnvelopeType
        , envelopeDescription = witnessEnvelopeDescription
        , envelopeCborHex =
            Text.pack (hexText (serialize' (eraProtVerHigh @ConwayEra) witness))
        }

{- | A witness encodes as @\[key, signature\]@, the official spelling
of one verification-key witness.
-}
instance EncCBOR DetachedWitness where
    encCBOR = encodeDetached

-- | The witness's CBOR: @\[key, signature\]@.
encodeDetached :: DetachedWitness -> Encoding
encodeDetached witness =
    encodeListLen 2
        <> encodeBytes (detachedKeyBytes witness)
        <> encodeBytes (detachedSignatureBytes witness)

{- | The witness envelope's decoding: the key and signature bytes its
CBOR carries, or the named refusal. Pure.
-}
decodeWitnessEnvelope
    :: ByteString -> Either BundleRefusal DetachedWitness
decodeWitnessEnvelope bytes = do
    value <-
        first
            (const (BundleField "witness" "is not JSON"))
            (eitherDecodeStrict bytes)
    envelope <- case value of
        Object o -> envelopeOf o
        _ -> Left (BundleField "witness" "is not a JSON object")
    unless (envelopeType envelope == witnessEnvelopeType) $
        Left (BundleEnvelopeWrongType (envelopeType envelope))
    payload <-
        first
            (const (BundleField "witness" "cborHex is not hex"))
            (hexOf (envelopeCborHex envelope))
    decoded <-
        first
            (const (BundleField "witness" "is not a key witness"))
            ( decodeFullDecoder
                (eraProtVerHigh @ConwayEra)
                "TxWitness"
                witnessDecoder
                (BSL.fromStrict payload)
            )
    validBytes decoded
  where
    validBytes (DetachedWitness key signature)
        | BS.length key == 32
        , BS.length signature == 64 =
            Right (DetachedWitness key signature)
        | otherwise =
            Left
                ( BundleField
                    "witness"
                    "does not carry a 32-byte key and a 64-byte signature"
                )

-- | One verification-key witness: the key-signature pair.
witnessDecoder :: Decoder s DetachedWitness
witnessDecoder = do
    decodeListLenOf 2
    DetachedWitness <$> decodeBytes <*> decodeBytes

{- | The JSON bytes of a bundle read back: the same bundle, or the
named refusal — an unknown version, a missing or malformed field, an
envelope of the wrong type. The transactions are not decoded here;
that is 'checkBundle', which owns the undecodable-envelope refusal.
-}
decodeBundle :: ByteString -> Either BundleRefusal Bundle
decodeBundle bytes = do
    value <-
        first
            (const (BundleField "bundle" "is not JSON"))
            (eitherDecodeStrict bytes)
    fields <- case value of
        Object o -> Right o
        _ -> Left (BundleField "bundle" "is not a JSON object")
    version <- numberField "version" fields
    unless (version == bundleVersion) $
        Left (BundleUnknownVersion version)
    command <- textField "command" fields
    magic <- numberField "networkMagic" fields
    stateToken <- case fieldOf "stateToken" fields of
        Nothing -> Left (BundleField "stateToken" "is missing")
        Just Null -> Right Nothing
        Just (String t) -> Right (Just t)
        Just _ -> Left (BundleField "stateToken" "is not text or null")
    signers <- signersOf fields
    transactions <- transactionsOf fields
    pure
        Bundle
            { bundleCommand = command
            , bundleNetworkMagic = magic
            , bundleStateToken = stateToken
            , bundleSigners = signers
            , bundleTransactions = transactions
            }

{- | The offline consistency checks, each refusing by name: every
recorded identity is the hash of its decoded transaction's body, every
recorded deadline is the body's validity upper bound, no identity
names two transactions, and every key hash a body requires is covered
by the key hash of a signer address. Pure.
-}
checkBundle :: Bundle -> Either BundleRefusal ()
checkBundle bundle = do
    transactions <-
        mapM checkedTransaction (toList (bundleTransactions bundle))
    forM_ transactions $ \(tx, decoded) ->
        unless (bodyIdentity decoded == bundleTxIdentity tx) $
            Left
                ( BundleIdentityMismatch
                    (bundleTxIdentity tx)
                    (bodyIdentity decoded)
                )
    forM_ transactions $ \(tx, decoded) ->
        unless (bodyDeadline decoded == bundleTxDeadline tx) $
            Left
                ( BundleDeadlineMismatch
                    (bundleTxDeadline tx)
                    (bodyDeadline decoded)
                    (bundleTxIdentity tx)
                )
    case firstDuplicate (map (bundleTxIdentity . fst) transactions) of
        Just identity -> Left (BundleDuplicateIdentity identity)
        Nothing -> Right ()
    let covered = signerKeyHashes (bundleSigners bundle)
    forM_ transactions $ \(tx, decoded) ->
        forM_ (decoded ^. bodyTxL . reqSignerHashesTxBodyL) $ \hash ->
            unless (hashToBytes (unKeyHash hash) `elem` covered) $
                Left
                    ( BundleSignerNotCovered
                        (hashToBytes (unKeyHash hash))
                        (bundleTxIdentity tx)
                    )
  where
    checkedTransaction tx = do
        decoded <-
            first
                (const (BundleEnvelopeUndecodable (hexText (bundleTxIdentity tx))))
                (decodeTransactionEnvelope (bundleTxEnvelope tx))
        pure (tx, decoded)
    firstDuplicate = go []
      where
        go _ [] = Nothing
        go seen (i : rest)
            | i `elem` seen = Just i
            | otherwise = go (i : seen) rest

-- | The payment key hashes of the signers' addresses, as bytes.
signerKeyHashes :: NonEmpty Text -> [ByteString]
signerKeyHashes signers =
    [ hashToBytes (unKeyHash hash)
    | spelling <- toList signers
    , Right (Addr _ (KeyHashObj hash) _) <-
        [addressOfText "signers" spelling]
    ]

-- | A signer's address, or the field refusal for its spelling.
addressOfText :: String -> Text -> Either BundleRefusal Addr
addressOfText fieldName spelling = do
    (_, dataPart) <-
        first (const refused) (Bech32.decode spelling)
    bytes <- maybe (Left refused) Right (Bech32.dataPartToBytes dataPart)
    first (const refused) (decodeAddrEither bytes)
  where
    refused =
        BundleField
            fieldName
            ("is not a bech32 address: " <> Text.unpack spelling)

-- * Field readers over the codec's own JSON

-- | A field of an object, in the codec's spelling.
fieldOf :: String -> KeyMap Value -> Maybe Value
fieldOf name = KeyMap.lookup (fromString name)

-- | A text field, refusing by name when missing or not text.
textField :: String -> KeyMap Value -> Either BundleRefusal Text
textField name fields = case fieldOf name fields of
    Nothing -> Left (BundleField name "is missing")
    Just (String t) -> Right t
    Just _ -> Left (BundleField name "is not text")

-- | A number field, read at the width given.
numberField
    :: forall w
     . (FromJSON w) => String -> KeyMap Value -> Either BundleRefusal w
numberField name fields = case fieldOf name fields of
    Nothing -> Left (BundleField name "is missing")
    Just v -> case fromJSON v of
        Success w -> Right w
        Error _ -> Left (BundleField name "is not a number")

-- | A deadline: a number of slots, or nothing.
deadlineOf :: KeyMap Value -> Either BundleRefusal (Maybe Word64)
deadlineOf fields = case fieldOf "deadline" fields of
    Nothing -> Left (BundleField "deadline" "is missing")
    Just Null -> Right Nothing
    Just (Number _) -> numberField "deadline" fields >>= (Right . Just)
    Just _ -> Left (BundleField "deadline" "is not a slot number or null")

-- | The signers list: non-empty, every entry a bech32 address.
signersOf :: KeyMap Value -> Either BundleRefusal (NonEmpty Text)
signersOf fields = case fieldOf "signers" fields of
    Nothing -> Left (BundleField "signers" "is missing")
    Just (Array entries)
        | null entries -> Left (BundleField "signers" "is empty")
        | otherwise -> case mapM asAddress (toList entries) of
            Right (one : more) -> Right (one :| more)
            Right [] -> Left (BundleField "signers" "is empty")
            Left refusal -> Left refusal
    Just _ -> Left (BundleField "signers" "is not a list")

-- | One signer, validated as an address.
asAddress :: Value -> Either BundleRefusal Text
asAddress = \case
    String t -> t <$ addressOfText "signers" t
    _ -> Left (BundleField "signers" "is not text")

-- | The transaction list: non-empty, every entry a bundle transaction.
transactionsOf
    :: KeyMap Value -> Either BundleRefusal (NonEmpty BundleTransaction)
transactionsOf fields = case fieldOf "transactions" fields of
    Nothing -> Left (BundleField "transactions" "is missing")
    Just (Array entries)
        | null entries -> Left (BundleField "transactions" "is empty")
        | otherwise -> case mapM asTransaction (toList entries) of
            Right (one : more) -> Right (one :| more)
            Right [] -> Left (BundleField "transactions" "is empty")
            Left refusal -> Left refusal
    Just _ -> Left (BundleField "transactions" "is not a list")

-- | One transaction, as the codec reads it.
asTransaction :: Value -> Either BundleRefusal BundleTransaction
asTransaction value = case value of
    Object o -> do
        identity <- identityOf o
        envelope <- envelopeTransactionOf o
        deadline <- deadlineOf o
        effects <- effectsOf o
        pure
            BundleTransaction
                { bundleTxIdentity = identity
                , bundleTxEnvelope = envelope
                , bundleTxDeadline = deadline
                , bundleTxEffects = effects
                }
    _ -> Left (BundleField "transactions" "is not a JSON object")

-- | The recorded identity: 64 hex digits, 32 bytes.
identityOf :: KeyMap Value -> Either BundleRefusal ByteString
identityOf fields = do
    spelling <- textField "identity" fields
    bytes <-
        first
            (const (BundleField "identity" "is not 64 hex digits"))
            (hexOf spelling)
    if BS.length bytes == 32
        then Right bytes
        else Left (BundleField "identity" "is not 32 bytes")

-- | The transaction's envelope, its type accepted from either label.
envelopeTransactionOf
    :: KeyMap Value -> Either BundleRefusal TextEnvelope
envelopeTransactionOf fields = do
    value <- case fieldOf "envelope" fields of
        Nothing -> Left (BundleField "envelope" "is missing")
        Just v -> Right v
    envelope <- case value of
        Object o -> envelopeOf o
        _ -> Left (BundleField "envelope" "is not a JSON object")
    unless (envelopeType envelope `elem` acceptedTransactionEnvelopeTypes) $
        Left (BundleEnvelopeWrongType (envelopeType envelope))
    envelope
        <$ first
            (const (BundleField "envelope.cborHex" "is not hex"))
            (hexOf (envelopeCborHex envelope))

-- | The effects: single-line texts.
effectsOf :: KeyMap Value -> Either BundleRefusal [Text]
effectsOf fields = case fieldOf "effects" fields of
    Nothing -> Left (BundleField "effects" "is missing")
    Just (Array entries) ->
        mapM
            ( \case
                String t
                    | Text.any (\c -> c == '\n' || c == '\r') t ->
                        Left (BundleField "effects" "carries a line break")
                    | otherwise -> Right t
                _ -> Left (BundleField "effects" "is not text")
            )
            (toList entries)
    Just _ -> Left (BundleField "effects" "is not a list")

-- | The three envelope fields, without the type check.
envelopeOf :: KeyMap Value -> Either BundleRefusal TextEnvelope
envelopeOf fields = do
    theType <- textField "type" fields
    description <- textField "description" fields
    cborHex <- textField "cborHex" fields
    pure
        TextEnvelope
            { envelopeType = theType
            , envelopeDescription = description
            , envelopeCborHex = cborHex
            }

-- | Hex text as bytes.
hexOf :: Text -> Either String ByteString
hexOf spelling =
    first (const ("is not hex: " <> Text.unpack spelling))
        . B16.decode
        . BC.pack
        $ Text.unpack spelling
