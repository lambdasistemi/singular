{-# LANGUAGE TypeApplications #-}

{- |
Module      : Singular.Registry.BundleSpec
Description : The bundle of unsigned transactions: codec, envelopes, offline checks
License     : Apache-2.0

The proofs of the bundle, one row per promise it makes to the offline
signer who reads it:

* what the codec writes, it reads back — the same transactions in the
same order — and an unknown version, a missing field or a malformed
envelope is refused by name;
* the offline checks prove every recorded identity against the hash of
its decoded body and every recorded deadline against the body's
validity upper bound, naming both sides of each disagreement, refusing
duplicate identities, and requiring every key hash a body names to be
covered by a signer address;
* the identity the checks compare against is the hash any Cardano tool
would compute: the transaction id equals an independent blake2b-256 of
the body bytes;
* a detached witness is the signer's own public key over the body's
hash, verifies as such, and round-trips through its text envelope.

Every expected value is obtained at run time from the producer — the
identity from the ledger's own transaction id, the addresses from the
wallet derivation, the covered key hash from a fresh key — never typed
beside the expectation.
-}
module Singular.Registry.BundleSpec
    ( spec
    , fixtureBundle
    , fixtureBytes
    , fixedKey
    , fixedSigner
    , syntheticBody
    , syntheticBodyRequiring
    , bundleTxOf
    ) where

import Control.Monad (unless)
import Data.Bits (xor)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BSL
import Data.Char (toLower)
import Data.List (isInfixOf)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64, Word8)
import Test.Hspec

import Cardano.Crypto.DSIGN
    ( Ed25519DSIGN
    , SigDSIGN
    , SignKeyDSIGN
    , SignedDSIGN (..)
    , deriveVerKeyDSIGN
    , rawDeserialiseSignKeyDSIGN
    , rawSerialiseSigDSIGN
    , rawSerialiseVerKeyDSIGN
    , verifyDSIGN
    )
import Cardano.Crypto.Hash (Blake2b_256, hashToBytes, hashWith)
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Alonzo.TxBody (reqSignerHashesTxBodyL)
import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body (mkBasicTxBody, vldtTxBodyL)
import Cardano.Ledger.BaseTypes
    ( SlotNo (..)
    , StrictMaybe (SJust, SNothing)
    )
import Cardano.Ledger.Binary (serialize, serialize')
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (eraProtVerHigh, extractHash)
import Cardano.Ledger.Keys
    ( KeyHash
    , KeyRole (Guard, Witness)
    , VKey (..)
    , WitVKey (..)
    , hashKey
    , unKeyHash
    , verifySignedDSIGN
    )
import Cardano.Ledger.TxIn (TxId (..))
import Cardano.Tx.Ledger (ConwayTx)
import Data.Aeson (Value (Object, String), eitherDecodeStrict)
import Data.Aeson.Key (fromString)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor (first)
import Data.Set (Set)
import Data.Set qualified as Set
import Lens.Micro ((&), (.~), (^.))

import Singular.Registry.Bundle
import Singular.Registry.Ledger (ConwayTxBody)
import Singular.Registry.Signing (detachedWitness)
import Singular.Registry.Wallet
    ( bech32Address
    , walletAddr
    , walletFromSignKey
    )

spec :: Spec
spec = describe "the bundle of unsigned transactions" $ do
    theCodec
    theTransactionEnvelope
    theOfflineChecks
    theOracle
    theDetachedWitness
    theIdentityIsTheBodyHash
    theCommittedFixture

-- * Producers: every expected value is obtained, never typed

{- | The RFC 8032 Ed25519 test vector 1 seed, the fixed test key whose
address the committed fixture names among its signers.
-}
fixedKey :: SignKeyDSIGN Ed25519DSIGN
fixedKey =
    fromMaybe
        (error "BundleSpec: the fixed test key is not a signing key")
        $ rawDeserialiseSignKeyDSIGN
            ( either
                (error "BundleSpec: the fixed test key is not hex")
                id
                ( hexBytes
                    "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
                )
            )

{- | The fixed test key's enterprise address on a test network,
derived through the production derivation.
-}
fixedSigner :: Text
fixedSigner =
    Text.pack (bech32Address (walletAddr (walletFromSignKey 1 fixedKey)))

-- | The transaction that carries a body: the unsigned form.
txOf :: ConwayTxBody -> ConwayTx
txOf = mkBasicTx

{- | The hash of a body: the identity of the transaction that carries
it, obtained from the producer at run time.
-}
bodyHash :: ConwayTxBody -> ByteString
bodyHash = bodyIdentity . txOf

-- | A body.s validity upper bound, read as the deadline it is.
bodyDeadlineOf :: ConwayTxBody -> Maybe Word64
bodyDeadlineOf body = case txOf body ^. bodyTxL . vldtTxBodyL of
    ValidityInterval _ (SJust (SlotNo n)) -> Just n
    ValidityInterval _ SNothing -> Nothing

{- | The body the fixture commits: a synthetic Conway body with no
inputs, no outputs and no required signers, bounded by the slot
given. Nothing in it constrains who may witness it.
-}
syntheticBody :: Word64 -> ConwayTxBody
syntheticBody upper =
    mkBasicTxBody
        & vldtTxBodyL
            .~ ValidityInterval SNothing (SJust (SlotNo upper))

{- | The same synthetic body, requiring the key hashes given: the
offline signer must find each among the bundle's signers.
-}
syntheticBodyRequiring
    :: Word64 -> Set (KeyHash Guard) -> ConwayTxBody
syntheticBodyRequiring upper hashes =
    syntheticBody upper
        & reqSignerHashesTxBodyL
            .~ hashes

{- | One transaction of a bundle: the body's true identity, its
envelope, its true deadline and the writer's claimed effects.
-}
bundleTxOf :: ConwayTxBody -> [Text] -> BundleTransaction
bundleTxOf body effects =
    BundleTransaction
        { bundleTxIdentity = bodyHash body
        , bundleTxEnvelope = transactionEnvelope (txOf body)
        , bundleTxDeadline = bodyDeadlineOf body
        , bundleTxEffects = effects
        }

{- | The sample bundle the codec rows prove: more than one transaction,
in submission order, signed for by the fixed test key. The committed
fixture holds exactly this bundle's bytes.
-}
sampleBundle :: Bundle
sampleBundle =
    Bundle
        { bundleCommand = "singular registry fold"
        , bundleNetworkMagic = 1
        , bundleStateToken = Nothing
        , bundleSigners = fixedSigner :| []
        , bundleTransactions =
            bundleTxOf
                (syntheticBody 1000)
                ["returns the request's deposit to its owner"]
                :| [ bundleTxOf
                        (syntheticBody 1001)
                        ["pays the request's owner 2000000 lovelace"]
                   ]
        }

{- | The bundle the committed fixture holds, built here so the
fixture's bytes are the producer's, never typed.
-}
fixtureBundle :: Bundle
fixtureBundle = sampleBundle

-- | The fixture bundle's bytes: what the committed file must equal.
fixtureBytes :: ByteString
fixtureBytes = encodeBundle fixtureBundle

-- | A fresh key from a byte pattern, as a signing key.
runtimeKey :: Word8 -> SignKeyDSIGN Ed25519DSIGN
runtimeKey firstByte =
    fromMaybe (error "BundleSpec: the seed is not a signing key") $
        rawDeserialiseSignKeyDSIGN (BS.pack (firstByte : replicate 31 0x2a))

{- | The last byte of an identity flipped: a recorded identity that
disagrees with its body by construction.
-}
flippedIdentity :: ByteString -> ByteString
flippedIdentity bytes
    | BS.null bytes = bytes
    | otherwise = BS.init bytes <> BS.singleton (BS.last bytes `xor` 1)

-- | The first transaction of the sample bundle, replaced.
withFirst :: (BundleTransaction -> BundleTransaction) -> Bundle
withFirst replace = case bundleTransactions sampleBundle of
    t :| rest -> sampleBundle{bundleTransactions = replace t :| rest}

-- * The codec

theCodec :: Spec
theCodec = describe "the codec" $ do
    it "round-trips what it writes, transactions in order" $ do
        decoded <- case decodeBundle (encodeBundle sampleBundle) of
            Right bundle -> pure bundle
            Left refusal ->
                error ("the round trip refused: " <> renderBundleRefusal refusal)
        fmap bundleTxIdentity (bundleTransactions decoded)
            `shouldBe` fmap bundleTxIdentity (bundleTransactions sampleBundle)
        fmap bundleTxDeadline (bundleTransactions decoded)
            `shouldBe` fmap bundleTxDeadline (bundleTransactions sampleBundle)
        decoded `shouldBe` sampleBundle
    it "refuses an unknown version by name" $ do
        let tampered = spliceFirstNumberField "version" 2 (encodeBundle sampleBundle)
        decodeBundle tampered `shouldBe` Left (BundleUnknownVersion 2)
        renderedBy tampered `shouldMention` "version"
    it "refuses a missing field by name" $ do
        let tampered = dropFirstNumberField "networkMagic" (encodeBundle sampleBundle)
        case decodeBundle tampered of
            Left (BundleField "networkMagic" _) -> pure ()
            other -> expectationFailure ("refused otherwise: " <> show other)
        renderedBy tampered `shouldMention` "networkMagic"
    it "refuses a malformed field by name" $ do
        let tampered =
                spliceFirstNumberToString
                    "networkMagic"
                    "not-a-number"
                    (encodeBundle sampleBundle)
        case decodeBundle tampered of
            Left (BundleField "networkMagic" _) -> pure ()
            other -> expectationFailure ("refused otherwise: " <> show other)
    it "refuses an envelope of the wrong type by name" $ do
        let wrongType =
                withFirst
                    ( \t ->
                        t
                            { bundleTxEnvelope =
                                (bundleTxEnvelope t){envelopeType = "Witnessed Tx ConwayEra"}
                            }
                    )
        decodeBundle (encodeBundle wrongType)
            `shouldBe` Left (BundleEnvelopeWrongType "Witnessed Tx ConwayEra")
    it "refuses a signer that is not an address" $ do
        let badSigners = sampleBundle{bundleSigners = "not-an-address" :| []}
        case decodeBundle (encodeBundle badSigners) of
            Left (BundleField "signers" _) -> pure ()
            other -> expectationFailure ("refused otherwise: " <> show other)
    it "refuses an empty signers list" $ do
        let tampered = emptyFirstArray "signers" (encodeBundle sampleBundle)
        case decodeBundle tampered of
            Left (BundleField "signers" _) -> pure ()
            other -> expectationFailure ("refused otherwise: " <> show other)
    it "refuses an empty transaction list" $ do
        let tampered = emptyFirstArray "transactions" (encodeBundle sampleBundle)
        case decodeBundle tampered of
            Left (BundleField "transactions" _) -> pure ()
            other -> expectationFailure ("refused otherwise: " <> show other)
    it "refuses an identity that is not 64 hex digits" $ do
        let tampered =
                spliceFirstStringField
                    "identity"
                    "not-hex"
                    (encodeBundle sampleBundle)
        case decodeBundle tampered of
            Left (BundleField "identity" _) -> pure ()
            other -> expectationFailure ("refused otherwise: " <> show other)
    it "refuses an effect that carries a line break" $ do
        let broken = withFirst (\t -> t{bundleTxEffects = ["two\nlines"]})
        case decodeBundle (encodeBundle broken) of
            Left (BundleField "effects" _) -> pure ()
            other -> expectationFailure ("refused otherwise: " <> show other)

-- * The transaction envelope

theTransactionEnvelope :: Spec
theTransactionEnvelope = describe "the transaction envelope" $ do
    it "writes the standard unwitnessed Conway envelope" $ do
        let envelope = transactionEnvelope (txOf (syntheticBody 1000))
        envelopeType envelope `shouldBe` "Unwitnessed Tx ConwayEra"
        envelopeDescription envelope `shouldBe` "Ledger Cddl Format"
    it "decodes what it writes, transaction for transaction" $ do
        let tx = txOf (syntheticBody 1000)
        decodeTransactionEnvelope (transactionEnvelope tx)
            `shouldBe` Right tx
    it "refuses a bare body, which is not a transaction" $ do
        let bareBody =
                TextEnvelope
                    { envelopeType = transactionEnvelopeType
                    , envelopeDescription = "Ledger Cddl Format"
                    , envelopeCborHex =
                        Text.pack
                            (hexText (serialize' (eraProtVerHigh @ConwayEra) (syntheticBody 1000)))
                    }
        case decodeTransactionEnvelope bareBody of
            Left _ -> pure ()
            Right decoded ->
                expectationFailure ("a bare body decoded: " <> show decoded)

-- * The cardano-cli oracle

theOracle :: Spec
theOracle = describe "the cardano-cli oracle" $ do
    it
        "decodes the official unsigned envelope and re-encodes it byte for byte" $ do
        envelope <-
            oracleEnvelope "test/fixtures/bundle/cardano-cli-tx-body.json"
        decoded <- case decodeTransactionEnvelope envelope of
            Right tx -> pure tx
            Left why -> fail ("official envelope refused: " <> why)
        envelopeCborHex (transactionEnvelope decoded)
            `shouldBe` envelopeCborHex envelope
        BS.length (bodyIdentity decoded) `shouldBe` 32
    it "accepts the official envelope's type label" $
        oracleEnvelope "test/fixtures/bundle/cardano-cli-tx-body.json"
            >>= \envelope ->
                envelopeType envelope
                    `shouldSatisfy` (`elem` acceptedTransactionEnvelopeTypes)
    it
        "accepts a bundle built around the official envelope, identity and deadline from the producer" $ do
        envelope <-
            oracleEnvelope "test/fixtures/bundle/cardano-cli-tx-body.json"
        decoded <- case decodeTransactionEnvelope envelope of
            Right tx -> pure tx
            Left why -> fail ("official envelope refused: " <> why)
        let oracleBundle =
                sampleBundle
                    { bundleTransactions =
                        BundleTransaction
                            { bundleTxIdentity = bodyIdentity decoded
                            , bundleTxEnvelope = envelope
                            , bundleTxDeadline = bodyDeadline decoded
                            , bundleTxEffects = ["the oracle writer's claim"]
                            }
                            :| []
                    }
        checkBundle oracleBundle `shouldBe` Right ()
    it
        "refuses a bundle around the official envelope with a flipped identity" $ do
        envelope <-
            oracleEnvelope "test/fixtures/bundle/cardano-cli-tx-body.json"
        decoded <- case decodeTransactionEnvelope envelope of
            Right tx -> pure tx
            Left why -> fail ("official envelope refused: " <> why)
        let flipped =
                sampleBundle
                    { bundleTransactions =
                        BundleTransaction
                            { bundleTxIdentity =
                                flippedIdentity (bodyIdentity decoded)
                            , bundleTxEnvelope = envelope
                            , bundleTxDeadline = bodyDeadline decoded
                            , bundleTxEffects = []
                            }
                            :| []
                    }
        checkBundle flipped
            `shouldBe` Left
                ( BundleIdentityMismatch
                    (flippedIdentity (bodyIdentity decoded))
                    (bodyIdentity decoded)
                )
    it "decodes the official witness and re-encodes it byte for byte" $ do
        bytes <-
            BS.readFile "test/fixtures/bundle/cardano-cli-tx-witness.json"
        decoded <- case decodeWitnessEnvelope bytes of
            Right witness -> pure witness
            Left refusal ->
                fail ("official witness refused: " <> renderBundleRefusal refusal)
        envelopeCborHex (witnessEnvelope decoded)
            `shouldBe` envelopeCborHex
                ( either
                    (error "BundleSpec: the official witness is not an envelope")
                    id
                    (envelopeOfBytes bytes)
                )
    it "writes the same witness type and description as the official tool" $ do
        official <-
            oracleEnvelope "test/fixtures/bundle/cardano-cli-tx-witness.json"
        let witness = detachedWitness fixedKey (txOf (syntheticBody 1000))
            written = witnessEnvelope (witnessData witness)
        envelopeType written `shouldBe` envelopeType official
        envelopeDescription written `shouldBe` envelopeDescription official
        BS.length (detachedKeyBytes (witnessData witness)) `shouldBe` 32
        BS.length (detachedSignatureBytes (witnessData witness)) `shouldBe` 64

-- * The offline checks

theOfflineChecks :: Spec
theOfflineChecks = describe "the offline checks" $ do
    it "accepts the sample bundle" $
        checkBundle sampleBundle `shouldBe` Right ()
    it
        "refuses a recorded identity that is not the body's hash, naming both"
        $ do
            let recorded = flippedIdentity (bodyHash (syntheticBody 1000))
                tampered = withFirst (\t -> t{bundleTxIdentity = recorded})
            checkBundle tampered
                `shouldBe` Left
                    (BundleIdentityMismatch recorded (bodyHash (syntheticBody 1000)))
            case checkBundle tampered of
                Left refusal ->
                    renderBundleRefusal refusal
                        `shouldMention` "is not the hash of its body"
                Right () -> expectationFailure "the tampered bundle was accepted"
    it
        "refuses a recorded deadline that is not the body's bound, naming both"
        $ do
            let tampered = withFirst (\t -> t{bundleTxDeadline = Just 4000})
            checkBundle tampered
                `shouldBe` Left
                    ( BundleDeadlineMismatch
                        (Just 4000)
                        (bodyDeadlineOf (syntheticBody 1000))
                        (bodyHash (syntheticBody 1000))
                    )
    it "refuses a null deadline on a bounded body" $ do
        let tampered = withFirst (\t -> t{bundleTxDeadline = Nothing})
        checkBundle tampered
            `shouldBe` Left
                ( BundleDeadlineMismatch
                    Nothing
                    (bodyDeadlineOf (syntheticBody 1000))
                    (bodyHash (syntheticBody 1000))
                )
    it "accepts a null deadline on an unbounded body" $ do
        let unbounded =
                mkBasicTxBody
                    & vldtTxBodyL
                        .~ ValidityInterval SNothing SNothing
            bundle' = sampleBundle{bundleTransactions = bundleTxOf unbounded [] :| []}
        checkBundle bundle' `shouldBe` Right ()
    it "refuses one identity naming two transactions" $ do
        let body = syntheticBody 1000
            tx = bundleTxOf body ["first"]
            txAgain = bundleTxOf body ["second"]
        case checkBundle sampleBundle{bundleTransactions = tx :| [txAgain]} of
            Left (BundleDuplicateIdentity identity) ->
                identity `shouldBe` bodyHash body
            other -> expectationFailure ("refused otherwise: " <> show other)
    it "accepts a body whose required signers the signers cover" $ do
        let requiring =
                syntheticBodyRequiring 1000 (Set.singleton (requiredHashOf fixedKey))
            bundle' =
                sampleBundle
                    { bundleTransactions = bundleTxOf requiring [] :| []
                    }
        checkBundle bundle' `shouldBe` Right ()
    it "refuses a required signer no address covers, naming it" $ do
        let foreignHash = requiredHashOf (runtimeKey 0x07)
            requiring = syntheticBodyRequiring 1000 (Set.singleton foreignHash)
            bundle' =
                sampleBundle
                    { bundleTransactions = bundleTxOf requiring [] :| []
                    }
        checkBundle bundle'
            `shouldBe` Left
                ( BundleSignerNotCovered
                    (hashToBytes (unKeyHash foreignHash))
                    (bodyHash requiring)
                )
    it "refuses an envelope whose CBOR is not a decodable body" $ do
        let undecodable =
                (bundleTxOf (syntheticBody 1000) [])
                    { bundleTxEnvelope =
                        TextEnvelope
                            { envelopeType = "Unwitnessed Tx ConwayEra"
                            , envelopeDescription = "Ledger Cddl Format"
                            , envelopeCborHex = "ff00"
                            }
                    }
        case checkBundle sampleBundle{bundleTransactions = undecodable :| []} of
            Left (BundleEnvelopeUndecodable identity) ->
                identity `shouldBe` hexText (bodyHash (syntheticBody 1000))
            other -> expectationFailure ("refused otherwise: " <> show other)

-- * The detached witness

theDetachedWitness :: Spec
theDetachedWitness = describe "the detached witness" $ do
    let body = syntheticBody 1000
        tx = txOf body
        witness = detachedWitness fixedKey tx
    it "carries the signer's public key" $ do
        witnessVKeyHash witness
            `shouldBe` (hashKey (VKey (deriveVerKeyDSIGN fixedKey)) :: KeyHash Witness)
    it "signs the body's hash, verifiably" $ do
        let TxId h = txIdOf tx
        case witness of
            WitVKey (VKey verKey) sig -> do
                verifySignedDSIGN (VKey verKey) (extractHash h) sig
                    `shouldBe` True
                verifyDSIGN () verKey (bodyHash body) (rawSig sig)
                    `shouldBe` Right ()
    it "round-trips through its text envelope" $ do
        let envelope = witnessEnvelope (witnessData witness)
            encoded = envelopeBytes envelope
        decodeWitnessEnvelope encoded
            `shouldBe` Right (witnessData witness)
    it "refuses a witness envelope whose CBOR is not a key witness" $ do
        let encoded =
                envelopeBytes
                    (witnessEnvelope (DetachedWitness "too-short" "also-short"))
        case decodeWitnessEnvelope encoded of
            Left _ -> pure ()
            Right decoded ->
                expectationFailure
                    ("decoded anyway: " <> show (detachedKeyBytes decoded))

-- * The identity is the body hash

theIdentityIsTheBodyHash :: Spec
theIdentityIsTheBodyHash = describe "the identity is the body hash" $ do
    it "equals an independent blake2b-256 of the body bytes" $ do
        let body = syntheticBody 1000
            bodyBytes = BSL.toStrict (serialize (eraProtVerHigh @ConwayEra) body)
            independent = hashWith @Blake2b_256 id bodyBytes
        bodyHash body `shouldBe` hashToBytes independent

-- * The committed fixture

theCommittedFixture :: Spec
theCommittedFixture = describe "the committed fixture" $ do
    it "is exactly what the builder writes" $ do
        committed <- BS.readFile "test/fixtures/bundle/unsigned-bundle.json"
        committed `shouldBe` fixtureBytes
    it "decodes and passes the offline checks" $ do
        committed <- BS.readFile "test/fixtures/bundle/unsigned-bundle.json"
        decodeBundle committed `shouldBe` Right fixtureBundle
        checkBundle fixtureBundle `shouldBe` Right ()

-- * Helpers over the codec's own encoding, for tampering

{- | The JSON values the tampering helpers write.
| Replace the value of the first @"FIELD":"value"@ string field in
the bytes given: a byte-level splice over the codec's own encoding,
so no JSON value rebuilding is needed to tamper.
-}
spliceFirstStringField :: Text -> Text -> ByteString -> ByteString
spliceFirstStringField field replacement bytes =
    case BS.breakSubstring needle bytes of
        (prefix, rest)
            | BS.null rest -> bytes
            | otherwise ->
                let valueStart = BS.drop (BS.length needle) rest
                    (_, remainder) = BC.break (== '"') valueStart
                in  prefix
                        <> needle
                        <> quoted replacement
                        <> BS.drop 1 remainder
  where
    needle = BC.pack (show field) <> ":\""
    quoted value = BC.pack (Text.unpack value) <> "\""

-- | Replace the value of the first @"FIELD":number@ field likewise.
spliceFirstNumberField :: Text -> Word -> ByteString -> ByteString
spliceFirstNumberField field replacement bytes =
    case BS.breakSubstring needle bytes of
        (prefix, rest)
            | BS.null rest -> bytes
            | otherwise ->
                let valueStart = BS.drop (BS.length needle) rest
                    (_, remainder) = BC.break (\c -> c < '0' || c > '9') valueStart
                in  prefix <> needle <> BC.pack (show replacement) <> remainder
  where
    needle = BC.pack (show field) <> ":"

-- | Drop the first @"FIELD":number,@ field from the bytes given.
dropFirstNumberField :: Text -> ByteString -> ByteString
dropFirstNumberField field bytes =
    case BS.breakSubstring needle bytes of
        (prefix, rest)
            | BS.null rest -> bytes
            | otherwise ->
                let valueStart = BS.drop (BS.length needle) rest
                    (_, remainder) = BC.break (== ',') valueStart
                in  prefix <> BS.drop 1 remainder
  where
    needle = BC.pack (show field) <> ":"

{- | Replace the value of the first @"FIELD\":number@ field with a
string spelling: a number field made malformed.
-}
spliceFirstNumberToString :: Text -> Text -> ByteString -> ByteString
spliceFirstNumberToString field replacement bytes =
    case BS.breakSubstring needle bytes of
        (prefix, rest)
            | BS.null rest -> bytes
            | otherwise ->
                let valueStart = BS.drop (BS.length needle) rest
                    (_, remainder) = BC.break (\c -> c < '0' || c > '9') valueStart
                in  prefix <> needle <> quoted replacement <> remainder
  where
    needle = BC.pack (show field) <> ":"
    quoted value = "\"" <> BC.pack (Text.unpack value) <> "\""

{- | Empty the first @"FIELD":[...]@ array in the bytes given, walking
balanced brackets.
-}
emptyFirstArray :: Text -> ByteString -> ByteString
emptyFirstArray field bytes =
    case BS.breakSubstring needle bytes of
        (prefix, rest)
            | BS.null rest -> bytes
            | otherwise ->
                let inside = BS.drop (BS.length needle) rest
                    close = arrayEnd inside (1 :: Int)
                in  prefix <> needle <> BC.pack "]" <> BS.drop (close + 1) inside
  where
    needle = BC.pack (show field) <> ":["
    arrayEnd bytes' depth
        | depth <= 0 = -1
        | BS.null bytes' = BS.length bytes'
        | BC.head bytes' == '[' = 1 + arrayEnd (BS.tail bytes') (depth + 1)
        | BC.head bytes' == ']' =
            if depth == 1
                then 0
                else 1 + arrayEnd (BS.tail bytes') (depth - 1)
        | otherwise = 1 + arrayEnd (BS.tail bytes') depth

-- | The envelope's JSON bytes, as a file holds them.
envelopeBytes :: TextEnvelope -> ByteString
envelopeBytes = encodeTextEnvelope

-- | A witness's public key and signature, as the envelope's data.
witnessData :: WitVKey Witness -> DetachedWitness
witnessData (WitVKey (VKey verKey) sig) =
    DetachedWitness
        { detachedKeyBytes = rawSerialiseVerKeyDSIGN verKey
        , detachedSignatureBytes = rawSerialiseSigDSIGN (rawSig sig)
        }

-- | A transaction.s own identifier, pattern-matched from the producer.
txIdOf :: ConwayTx -> TxId
txIdOf = txIdTx

-- | The raw signature a wrapped signature carries.
rawSig :: SignedDSIGN Ed25519DSIGN a -> SigDSIGN Ed25519DSIGN
rawSig (SignedDSIGN s) = s

-- | The key hash of a witness's public key.
witnessVKeyHash :: WitVKey Witness -> KeyHash Witness
witnessVKeyHash (WitVKey (VKey verKey) _) = hashKey (VKey verKey)

-- | A signing key's hash in the role a body's required signers use.
requiredHashOf :: SignKeyDSIGN Ed25519DSIGN -> KeyHash Guard
requiredHashOf = hashKey . VKey . deriveVerKeyDSIGN

-- | Bytes from lowercase hex, the same spelling the codec reads.
hexBytes :: String -> Either String ByteString
hexBytes = B16.decode . BC.pack

-- | Whether the needle's words all appear in the haystack, in any case.
elemWords :: String -> String -> Bool
elemWords needle haystack =
    all
        (\w -> map toLower w `isInfixOf` map toLower haystack)
        (words needle)

-- | The rendered refusal of a decode, for wording checks.
renderedBy :: ByteString -> String
renderedBy bytes = case decodeBundle bytes of
    Left refusal -> renderBundleRefusal refusal
    Right _ -> "accepted"

-- | An expectation helper for wording.
shouldMention :: String -> String -> Expectation
shouldMention line words' =
    unless (words' `elemWords` line) $
        expectationFailure
            ("the refusal does not say it: " <> show (words', line))

{- | An oracle envelope file's three fields, read as this codec reads
them.
-}
oracleEnvelope :: FilePath -> IO TextEnvelope
oracleEnvelope path = do
    bytes <- BS.readFile path
    case envelopeOfBytes bytes of
        Right envelope -> pure envelope
        Left refusal ->
            error ("BundleSpec: the oracle envelope is not one: " <> show refusal)

-- | Any text-envelope-shaped JSON bytes, or the refusal.
envelopeOfBytes :: ByteString -> Either BundleRefusal TextEnvelope
envelopeOfBytes bytes = do
    value <-
        first
            (const (BundleField "envelope" "is not JSON"))
            (eitherDecodeStrict bytes)
    case value of
        Object fields ->
            TextEnvelope
                <$> textFieldOf "type" fields
                <*> textFieldOf "description" fields
                <*> textFieldOf "cborHex" fields
        _ -> Left (BundleField "envelope" "is not a JSON object")
  where
    textFieldOf name fields = case KeyMap.lookup (fromString name) fields of
        Just (String t) -> Right t
        _ -> Left (BundleField name "is missing or not text")
