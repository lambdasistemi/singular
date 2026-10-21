{- |
Module      : Singular.Registry.AddressSpec
Description : A registry's address and fingerprint, written and read
License     : Apache-2.0

The address is the registry's state token as one bech32 word. These cases hold
the module on its own: fixed addresses and fingerprints for the four networks,
made by an independent implementation; the eight fingerprints CIP-14 publishes;
the round trip from a token to its address and back; every single changed
character refused as a wrong checksum; every other prefix and every other body
length refused with its own cause; and the refusals in their order.

The words that the module is judged against are never made by it: the fixed
ones come from "Singular.Registry.AddressVectors", and the generated ones are
written with the @bech32@ package directly.
-}
module Singular.Registry.AddressSpec (spec) where

import Codec.Binary.Bech32 qualified as Bech32
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.Char (isLower, toUpper)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word32)
import Test.Hspec
import Test.QuickCheck
    ( Gen
    , choose
    , elements
    , forAll
    , property
    , vectorOf
    )

import Cardano.Crypto.Hash.Class (hashFromBytes)
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value (AssetName (..), PolicyID (..))

import Singular.Registry.Address
    ( AddressRefusal (..)
    , addressPrefix
    , addressPrefixes
    , parseRegistryAddress
    , registryFingerprint
    , renderAddressRefusal
    , renderRegistryAddress
    )
import Singular.Registry.AddressOracle (addressOf)
import Singular.Registry.AddressVectors
    ( Cip14 (..)
    , Vector (..)
    , cip14
    , refusalWord
    , vectors
    )
import Singular.Registry.LedgerProvider (Asset)
import Singular.Registry.StateToken (parseStateToken)

spec :: Spec
spec = describe "a registry's address and fingerprint" $ do
    networkRows
    vectorRows
    fingerprintRows
    roundTripRows
    refusalRows
    sentenceRows

-- | A token from the spelling the command line gives.
tokenOf :: Vector -> IO Asset
tokenOf v =
    either
        (\why -> fail ("the vector's token: " <> T.unpack why))
        pure
        (parseStateToken (T.pack (vPolicy v <> "." <> vName v)))

-- | An asset of any name length from hex, as CIP-14 gives them.
assetOf :: String -> String -> IO Asset
assetOf policyHex nameHex = do
    policy <- hex policyHex
    name <- hex nameHex
    hash <- maybe (fail "not a script hash") pure (hashFromBytes policy)
    pure (PolicyID (ScriptHash hash), AssetName (SBS.toShort name))
  where
    hex = either fail pure . B16.decode . BC.pack

networkRows :: Spec
networkRows = describe "the networks" $ do
    it "have exactly the four prefixes, one per network magic" $
        addressPrefixes
            `shouldBe` [ ("singular", 764824073)
                       , ("singular_preprod", 1)
                       , ("singular_preview", 2)
                       , ("singular_devnet", 42)
                       ]
    it "have no prefix for any other magic" $
        forM_ [0, 3, 41, 43, 100, 764824072, 764824074] $ \magic ->
            addressPrefix magic `shouldBe` Nothing
    it "write no address for a magic that has no prefix" $
        forM_ (take 1 vectors) $ \v -> do
            token <- tokenOf v
            renderRegistryAddress 3 token `shouldBe` Nothing

vectorRows :: Spec
vectorRows = describe "the fixed addresses of the four networks" $
    forM_ vectors $ \v -> do
        let label = vPrefix v <> " " <> take 8 (vPolicy v) <> "." <> take 8 (vName v)
        it ("write " <> label) $ do
            token <- tokenOf v
            renderRegistryAddress (vMagic v) token
                `shouldBe` Just (T.pack (vAddress v))
        it ("read " <> label <> " in lower and in upper case") $ do
            token <- tokenOf v
            parseRegistryAddress (T.pack (vAddress v))
                `shouldBe` Right (vMagic v, token)
            parseRegistryAddress (T.pack (map toUpper (vAddress v)))
                `shouldBe` Right (vMagic v, token)
        it
            ( "refuse "
                <> label
                <> " with one letter in upper case among lower case"
            )
            $ parseRegistryAddress (T.pack (mixCase (vAddress v)))
                `shouldBe` Left NotAnAddress
        it ("fingerprint " <> label) $ do
            token <- tokenOf v
            registryFingerprint token `shouldBe` T.pack (vFingerprint v)
  where
    mixCase word = case break isLower word of
        (lead, c : rest) -> lead <> [toUpper c] <> rest
        (lead, []) -> lead

fingerprintRows :: Spec
fingerprintRows = describe "the fingerprints CIP-14 publishes" $
    forM_ (zip [1 :: Int ..] cip14) $ \(n, Cip14 policy name expected) ->
        it ("are reproduced, number " <> show n) $ do
            asset <- assetOf policy name
            registryFingerprint asset `shouldBe` T.pack expected

-- | A random network magic with a prefix, a 28-byte policy and a 32-byte name.
genToken :: Gen (Word32, ByteString, ByteString)
genToken = do
    magic <- elements (map snd addressPrefixes)
    policy <- BS.pack <$> vectorOf 28 (choose (0, 255))
    name <- BS.pack <$> vectorOf 32 (choose (0, 255))
    pure (magic, policy, name)

spelling :: ByteString -> ByteString -> String
spelling policy name = hexString policy <> "." <> hexString name

hexString :: ByteString -> String
hexString = BC.unpack . B16.encode

-- | The state token a spelling gives; a token every generated pair is.
tokenFromBytes :: ByteString -> ByteString -> Maybe Asset
tokenFromBytes policy name =
    either (const Nothing) Just $
        parseStateToken (T.pack (spelling policy name))

roundTripRows :: Spec
roundTripRows = describe "any policy and name" $ do
    it "decode from the address they make, on every network" $
        property $
            forAll genToken $ \(magic, policy, name) ->
                case tokenFromBytes policy name of
                    Nothing -> False
                    Just token ->
                        ( renderRegistryAddress magic token
                            >>= either (const Nothing) Just . parseRegistryAddress
                        )
                            == Just (magic, token)
    it "make the address the bech32 package makes of the same bytes" $
        property $
            forAll genToken $ \(magic, policy, name) ->
                case tokenFromBytes policy name of
                    Nothing -> False
                    Just token ->
                        fmap T.unpack (renderRegistryAddress magic token)
                            == addressOf magic (spelling policy name)
    it
        "are refused, with any one character of the address changed, as a wrong checksum"
        $ property
        $ forAll genToken
        $ \(magic, policy, name) ->
            forAll (choose (0, 10000)) $ \position ->
                forAll (choose (0, 10000)) $ \pick ->
                    case tokenFromBytes policy name >>= renderRegistryAddress magic of
                        Nothing -> False
                        Just word ->
                            let chars = T.unpack word
                                separator = T.length (fst (T.breakOnEnd "1" word)) - 1
                                at = position `mod` length chars
                                alphabet = Bech32.dataCharList
                                swapped c =
                                    case [ x
                                         | x <- drop (pick `mod` length alphabet) (cycle alphabet)
                                         , x /= c
                                         ] of
                                        x : _ -> x
                                        [] -> c
                                changed =
                                    [ if i == at then swapped c else c
                                    | (i, c) <- zip [0 ..] chars
                                    ]
                            in  at == separator
                                    || parseRegistryAddress (T.pack changed) == Left BadChecksum
    it
        "are refused under any other prefix with a right checksum, naming it, and no other cause"
        $ property
        $ forAll genToken
        $ \(_, policy, name) ->
            forAll
                ( elements
                    [ "singular_mainnet"
                    , "other"
                    , "x"
                    , "singular_previews"
                    , "asset"
                    , "addr"
                    ]
                )
                $ \prefix ->
                    parseRegistryAddress (wordOf prefix (policy <> name))
                        == Left (UnknownPrefix prefix)
    it
        "are refused with any other length of body, naming it, and no other cause"
        $ property
        $ forAll (choose (0, 120))
        $ \n ->
            forAll (BS.pack <$> vectorOf n (choose (0, 255))) $ \body ->
                n == 60
                    || parseRegistryAddress (wordOf "singular_devnet" body)
                        == Left (BodyLength n)

-- | A word the package writes for this prefix and body: a right checksum, whatever they are.
wordOf :: Text -> ByteString -> Text
wordOf prefix body =
    case Bech32.humanReadablePartFromText prefix of
        Right hrp -> Bech32.encodeLenient hrp (Bech32.dataPartFromBytes body)
        Left why -> error ("AddressSpec: " <> show why)

refusalRows :: Spec
refusalRows = describe "an address is refused in a fixed order" $ do
    it
        "reads the good word of the same shape, the control of the rows below"
        $ fmap fst (parseRegistryAddress (T.pack (refusalWord "good")))
            `shouldBe` Right 1
    forM_ causes $ \(name, expected) ->
        it ("tells " <> name <> " and no other cause") $
            parseRegistryAddress (T.pack (refusalWord name))
                `shouldBe` Left expected
  where
    causes =
        [ ("mixed-case", NotAnAddress)
        , ("invalid-character", NotAnAddress)
        , ("no-separator", NotAnAddress)
        , ("bad-checksum", BadChecksum)
        , ("bad-checksum-and-unknown-prefix", BadChecksum)
        , ("bad-checksum-and-short", BadChecksum)
        , ("unknown-prefix", UnknownPrefix "singular_mainnet")
        , ("unknown-prefix-and-short", UnknownPrefix "other")
        , ("short", BodyLength 59)
        , ("long", BodyLength 61)
        , ("empty-body", BodyLength 0)
        ]

sentenceRows :: Spec
sentenceRows = describe "each cause is said as itself" $ do
    it "says it is not an address, and no other cause" $
        mentions NotAnAddress ["not an address"] ["checksum", "prefix", "60"]
    it "says the checksum is wrong, and no other cause" $
        mentions BadChecksum ["checksum"] ["not an address", "prefix", "60"]
    it "says the prefix is unknown and lists the four" $
        mentions
            (UnknownPrefix "other")
            [ "prefix"
            , "other"
            , "singular_preprod"
            , "singular_preview"
            , "singular_devnet"
            ]
            ["not an address", "checksum", "60 bytes"]
    it "says the body is not 60 bytes, and how long it is" $
        mentions
            (BodyLength 59)
            ["59 bytes", "60"]
            ["not an address", "checksum", "prefix"]
  where
    mentions refusal present absent = do
        let sentence = renderAddressRefusal refusal
        forM_ present $ \word -> sentence `shouldSatisfy` T.isInfixOf word
        forM_ absent $ \word -> sentence `shouldNotSatisfy` T.isInfixOf word
