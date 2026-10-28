{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}

{- |
Module      : Singular.Registry.ReaderSpec
Description : The neutral reader against the executable Lean reader's answers
License     : Apache-2.0

The corpus is exported by ReaderCorpusMain and replayed by both native Lean
readers in the model gate. Expected answers are read from that export. The
bridge gives abstract identities concrete ledger bytes, using the existing
preimage producer for the two hashed roles. It does not decide an answer.
These observations test classification, not a connected ledger lifecycle.
-}
module Singular.Registry.ReaderSpec (spec, readerRows) where

import Control.Monad (forM_, (>=>))
import Data.Aeson
    ( FromJSON
    , Object
    , Value (..)
    , eitherDecodeFileStrict'
    , parseJSON
    , withObject
    , (.:)
    )
import Data.Aeson.Key (Key)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((&), (.~))
import PlutusCore.Data qualified as PLC
import System.Environment (lookupEnv)
import Test.Hspec

import Cardano.Crypto.Hash (hashFromBytes)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Tx.Out (datumTxOutL, mkBasicTxOut)
import Cardano.Ledger.BaseTypes
    ( Network (Testnet)
    , TxIx (..)
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes (ScriptHash (..), unsafeMakeSafeHash)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))

import Singular.Reader qualified as R
import Singular.Registry.ContractTable (ApplicationIdentity (..))
import Singular.Registry.Ledger (ConwayEra, Root (..), TxOut)
import Singular.Registry.LedgerProvider qualified as LP
import Singular.Registry.TrieState qualified as Trie
import Singular.Registry.TxBuilder.Internal (mkInlineDatum)
import Singular.State.Preimage
    ( activeTokenName
    , approvalName
    , terminationPreimage
    )
import Singular.State.Records (stateDatum)

spec :: Spec
spec = describe "reading a key from complete or unavailable evidence" $ do
    rows <- runIO readerRows
    it "has more than one independently exported observation" $
        length rows `shouldSatisfy` (> 1)
    forM_ rows $ \(name, request, observed, expected) ->
        it (T.unpack name) $
            R.readNeutralKey request observed `shouldBe` expected

-- | Native Lean observations translated to ledger identities, with native answers.
readerRows
    :: IO
        [(Text, R.ReaderRequest, R.ReaderObservation, R.NeutralReaderAnswer)]
readerRows = do
    path <-
        fromMaybe "../models/singular-application-held/reader-corpus.json"
            <$> lookupEnv "SINGULAR_READER_CORPUS"
    decoded <- eitherDecodeFileStrict' path :: IO (Either String [Value])
    either fail pure (decoded >>= parseEither (traverse rowOf))

type ModelAsset = (Integer, Integer)
type Bridge = Map.Map ModelAsset LP.Asset

rowOf
    :: Value
    -> Parser
        (Text, R.ReaderRequest, R.ReaderObservation, R.NeutralReaderAnswer)
rowOf = withObject "exported reader story" $ \row -> do
    query <- row .: "query"
    withObject
        "reader query"
        ( \q -> do
            request <- q .: "request"
            bridge <- bridgeOf q
            asked <- requestOf request
            observed <- q .: "observation" >>= observationOf bridge asked q
            expected <- row .: "neutralAnswer" >>= answerOf bridge asked q
            (,,,)
                <$> row .: "name"
                <*> pure asked
                <*> pure observed
                <*> pure expected
        )
        query

requestOf :: Value -> Parser R.ReaderRequest
requestOf = withObject "reader request" $ \o ->
    R.ReaderRequest . LP.Network
        <$> o .: "network"
        <*> (o .: "registry" >>= registryOf)
        <*> (bytes 8 <$> o .: "key")

registryOf :: Value -> Parser Trie.RegistryIdentity
registryOf = withObject "registry" $ \o ->
    Trie.RegistryIdentity . Trie.StatePolicyId . bytes 28
        <$> o .: "policy"
        <*> (AssetName . SBS.toShort . bytes 32 <$> o .: "name")

modelAsset :: Value -> Parser ModelAsset
modelAsset = withObject "model asset" $ \o -> (,) <$> o .: "policy" <*> o .: "name"

assetOf :: Bridge -> Value -> Parser LP.Asset
assetOf bridge v = do
    key@(p, n) <- modelAsset v
    case Map.lookup key bridge of
        Just asset -> pure asset
        Nothing -> (,) <$> policyOf p <*> pure (AssetName (SBS.toShort (bytes 32 n)))

bridgeOf :: Data.Aeson.Object -> Parser Bridge
bridgeOf q = do
    codes <- q .: "codes"
    hashes <- q .: "hashes"
    Map.fromList <$> traverse (entry hashes) codes
  where
    entry hashes = withObject "encoding entry" $ \o -> do
        encoded <- o .: "encoded"
        matches <- traverse (hashEntry encoded) hashes
        let name = case catMaybes matches of
                n : _ -> n
                [] -> 0
        preimage <- o .: "preimage"
        (role, fields) <- tagged preimage
        withObject
            "preimage fields"
            ( \p -> do
                regValue <- p .: "registry"
                reg <- registryOf regValue
                (modelPolicy, _) <- modelAsset regValue
                key <- bytes 8 <$> p .: "key"
                policy <- case role of
                    "active" -> policyOf modelPolicy
                    "terminationApproval" -> do
                        obs <- q .: "observation"
                        withObject
                            "observation"
                            ( \ob -> do
                                release <- ob .: "release"
                                case release of
                                    Null -> policyOf modelPolicy
                                    _ ->
                                        withObject
                                            "release"
                                            (\r -> r .: "applicationPolicy" >>= policyOf)
                                            release
                            )
                            obs
                    _ -> fail "the reader corpus contains an unsupported preimage role"
                let concrete = case role of
                        "active" -> activeTokenName reg key
                        _ -> approvalName (terminationPreimage key reg)
                    modelPolicyOf = case role of
                        "active" -> pure modelPolicy
                        _ -> do
                            obs <- q .: "observation"
                            withObject
                                "observation"
                                ( \ob -> do
                                    release <- ob .: "release"
                                    case release of
                                        Null -> pure modelPolicy
                                        _ -> withObject "release" (.: "applicationPolicy") release
                                )
                                obs
                pnum <- modelPolicyOf
                pure ((pnum, name), (policy, concrete))
            )
            fields
    hashEntry encoded = withObject "hash entry" $ \o -> do
        input <- o .: "input" :: Parser [Integer]
        n <- o .: "output"
        pure (if input == encoded then Just n else Nothing)

observationOf
    :: Bridge
    -> R.ReaderRequest
    -> Data.Aeson.Object
    -> Value
    -> Parser R.ReaderObservation
observationOf bridge request q = withObject "reader observation" $ \o ->
    R.ReaderObservation
        <$> (o .: "network" >>= readOf (fmap LP.Network . Data.Aeson.parseJSON))
        <*> (o .: "release" >>= optional releaseOf)
        <*> ( o .: "activeOutputs"
                >>= readOf (Data.Aeson.parseJSON >=> traverse (outputOf bridge))
            )
        <*> (o .: "state" >>= readOf (optional (outputOf bridge)))
        <*> (o .: "trie" >>= readOf (trieOf request q))

releaseOf :: Value -> Parser ApplicationIdentity
releaseOf = withObject "published release" $ \o ->
    ApplicationIdentity . bytes 28
        <$> o .: "statePolicy"
        <*> (bytes 28 <$> o .: "applicationPolicy")
        <*> (bytes 28 <$> o .: "applicationCredential")
        <*> pure []
        <*> pure []

readOf :: (Value -> Parser a) -> Value -> Parser (R.ReaderRead a)
readOf parse v = do
    (kind, fields) <- tagged v
    case kind of
        "missing" -> pure R.ReadMissing
        "failed" -> R.ReadFailed <$> field "reason" fields
        "incomplete" -> R.ReadIncomplete <$> field "reason" fields
        "complete" -> R.Complete <$> (field "value" fields >>= parse)
        _ -> fail "unknown reader observation constructor"

trieOf
    :: R.ReaderRequest
    -> Data.Aeson.Object
    -> Value
    -> Parser (Root, Trie.Leaf)
trieOf request q trie = do
    roots <- q .: "roots"
    entries <-
        traverse
            ( withObject "root entry" $ \o -> (,) <$> o .: "trie" <*> o .: "commitment"
            )
            roots
    pairs <- Data.Aeson.parseJSON trie >>= traverse leafPair
    let root = fromMaybe 0 (Prelude.lookup trie entries)
        leaf = fromMaybe Trie.Unknown (Prelude.lookup (R.readerKey request) pairs)
    pure (Root (bytes 32 root), leaf)
  where
    leafPair :: Value -> Parser (ByteString, Trie.Leaf)
    leafPair v = do
        (key, raw) <- Data.Aeson.parseJSON v
        (tag, fields) <- tagged raw
        leaf <- case tag of
            "unknown" -> pure Trie.Unknown
            "known" ->
                field "s" fields >>= \case
                    ("active" :: Text) -> pure Trie.Active
                    "terminal" -> pure Trie.Terminal
                    "absent" -> pure Trie.Absent
                    _ -> fail "unknown leaf state"
            _ -> fail "unknown leaf constructor"
        pure (bytes 8 key, leaf)

outputOf :: Bridge -> Value -> Parser (TxIn, TxOut ConwayEra)
outputOf bridge = withObject "observed output" $ \o -> do
    reference <- o .: "reference" >>= referenceOf
    address <- o .: "credential" >>= addressOf
    amount <- Coin <$> o .: "lovelace"
    assets <- o .: "assets" >>= traverse assetPair
    datum <- o .: "datum" >>= datumOf
    let value =
            MaryValue
                amount
                ( MultiAsset
                    ( Map.fromListWith
                        (Map.unionWith (+))
                        [(policy, Map.singleton name n) | ((policy, name), n) <- assets]
                    )
                )
        output = mkBasicTxOut address value
    pure
        ( reference
        , maybe output (\d -> output & datumTxOutL .~ mkInlineDatum d) datum
        )
  where
    assetPair v = do
        (raw, quantity) <- Data.Aeson.parseJSON v
        (,quantity) <$> assetOf bridge raw
    datumOf v = do
        (kind, fields) <- tagged v
        case kind of
            "empty" -> pure Nothing
            "root" -> Just . stateDatum . bytes 32 <$> field "commitment" fields
            "application" -> Just . PLC.I <$> field "data" fields
            _ -> fail "unknown observed datum"

answerOf
    :: Bridge
    -> R.ReaderRequest
    -> Data.Aeson.Object
    -> Value
    -> Parser R.NeutralReaderAnswer
answerOf bridge request q v = do
    (kind, fields) <- tagged v
    case kind of
        "active" -> R.Active <$> (field "output" fields >>= outputOf bridge)
        "terminal" -> R.Terminal <$> (field "state" fields >>= stateOf)
        "neverRegistered" -> R.NeverRegistered <$> (field "state" fields >>= stateOf)
        "unavailable" ->
            R.Unavailable
                <$> (field "read" fields >>= readName)
                <*> (field "reason" fields >>= unavailableOf)
        "refused" -> R.Refused <$> (field "reason" fields >>= refusalOf)
        _ -> fail "unknown neutral answer constructor"
  where
    stateOf = withObject "reader state" $ \o -> do
        output <- o .: "output" >>= outputOf bridge
        (root, _) <- o .: "trie" >>= trieOf request q
        pure (R.ReaderState output root)
    readName :: Text -> Parser R.ReaderReadName
    readName = \case
        "network" -> pure R.NetworkRead
        "activeOutputs" -> pure R.ActiveOutputsRead
        "state" -> pure R.StateRead
        "trie" -> pure R.TrieRead
        _ -> fail "unknown read name"
    unavailableOf raw = do
        (kind, fields) <- tagged raw
        case kind of
            "missing" -> pure R.Missing
            "failed" -> R.Failed <$> field "reason" fields
            "incomplete" -> R.Incomplete <$> field "reason" fields
            "stateNotFound" -> pure R.StateNotFound
            "stateNotRecognized" -> pure R.StateNotRecognized
            "trieRootMismatch" -> pure R.TrieRootMismatch
            _ -> fail "unknown unavailable constructor"
    refusalOf raw = do
        (kind, fields) <- tagged raw
        case kind of
            "wrongNetwork" ->
                R.WrongNetwork . LP.Network
                    <$> field "requested" fields
                    <*> (LP.Network <$> field "served" fields)
            "unknownStatePolicy" -> R.UnknownStatePolicy . bytes 28 <$> field "policy" fields
            "foreignStatePolicy" ->
                R.ForeignStatePolicy . bytes 28
                    <$> field "requested" fields
                    <*> (bytes 28 <$> field "published" fields)
            "tokenOutsideApplicationCustody" ->
                R.TokenOutsideApplicationCustody
                    <$> (field "reference" fields >>= referenceOf)
                    <*> (field "credential" fields >>= addressOf)
            "conflictingEvidence" -> pure R.ConflictingEvidence
            _ -> fail "unknown refusal constructor"

referenceOf :: Value -> Parser TxIn
referenceOf = withObject "output reference" $ \o -> do
    tid <- o .: "tx"
    ix <- o .: "index"
    hashed <-
        maybe
            (fail "transaction hash bytes")
            pure
            (hashFromBytes (bytes 32 tid))
    pure (TxIn (TxId (unsafeMakeSafeHash hashed)) (TxIx ix))

policyOf :: Integer -> Parser PolicyID
policyOf n =
    PolicyID . ScriptHash
        <$> maybe (fail "policy hash bytes") pure (hashFromBytes (bytes 28 n))

addressOf :: Integer -> Parser Addr
addressOf n = do
    PolicyID script <- policyOf n
    pure (Addr Testnet (ScriptHashObj script) StakeRefNull)

bytes :: Int -> Integer -> ByteString
bytes width n =
    BS.pack
        [fromInteger (n `div` (256 ^ i) `mod` 256) | i <- [0 .. width - 1]]

tagged :: Value -> Parser (Text, Value)
tagged (String name) = pure (name, Null)
tagged (Object fields) = case KM.toList fields of
    [(key, value)] -> pure (Key.toText key, value)
    _ -> fail "expected exactly one constructor"
tagged _ = fail "expected a constructor"

field :: (Data.Aeson.FromJSON a) => Key -> Value -> Parser a
field name = withObject "constructor fields" (.: name)

optional :: (Value -> Parser a) -> Value -> Parser (Maybe a)
optional _ Null = pure Nothing
optional parse v = Just <$> parse v
