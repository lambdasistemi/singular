{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Registry.Address
Description : A registry's address: its state token as one bech32 word
License     : Apache-2.0

A registry has an address. It is the registry's state token written as one
bech32 word: the prefix names the network, and the body is the 28-byte policy
followed by the 32-byte asset name, nothing else. The policy is the version
of the on-chain code, and the name comes from the seed, so the word holds
what a command needs to find the registry and the network to look for it on.

The checksum is the original bech32 one, with no limit on the length of the
word. The word is written in lower case and read in lower case or in upper
case, never in a mixture.

An address is read in a fixed order and each refusal says which cause it is:
not a bech32 word, the checksum, the prefix, the length of the body. A word
that fails an earlier check is never told a later cause.

The fingerprint is the CIP-14 fingerprint of the same asset, the short name
that wallets and explorers print for it: the 160-bit blake2b of the policy
followed by the name, written in bech32 under the prefix @asset@.
-}
module Singular.Registry.Address
    ( -- * The networks that have an address
      addressPrefix
    , addressPrefixes

      -- * Writing an address
    , renderRegistryAddress

      -- * Reading an address
    , AddressRefusal (..)
    , parseRegistryAddress
    , renderAddressRefusal

      -- * The fingerprint
    , registryFingerprint
    ) where

import Codec.Binary.Bech32 qualified as Bech32
import Control.Monad (unless, when)
import Crypto.Hash (Blake2b_160 (..), hashWith)
import Data.Bifunctor (first)
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word32)

import Cardano.Ledger.Mary.Value (AssetName (..), PolicyID (..))

import Singular.Registry.LedgerProvider (Asset)
import Singular.Registry.StateToken (parseStateToken)
import Singular.Registry.TxBuilder.Internal (scriptHashBytes)

{- | The prefix of a network, for the four networks that have one: mainnet,
preprod, preview and the generated development network. Any other network
magic has no prefix, and so no address.
-}
addressPrefix :: Word32 -> Maybe Text
addressPrefix magic = lookup magic [(m, p) | (p, m) <- addressPrefixes]

-- | The four prefixes with the network magic each names, in the order they are listed.
addressPrefixes :: [(Text, Word32)]
addressPrefixes =
    [ ("singular", 764_824_073)
    , ("singular_preprod", 1)
    , ("singular_preview", 2)
    , ("singular_devnet", 42)
    ]

{- | The address of a state token on a network, in lower case; nothing when
the network has no prefix.
-}
renderRegistryAddress :: Word32 -> Asset -> Maybe Text
renderRegistryAddress magic token = do
    prefix <- addressPrefix magic
    hrp <-
        either (const Nothing) Just (Bech32.humanReadablePartFromText prefix)
    pure
        (Bech32.encodeLenient hrp (Bech32.dataPartFromBytes (tokenBytes token)))

-- | Why a text is not the address of a registry, in the order the causes are checked.
data AddressRefusal
    = -- | Not a bech32 word, or upper and lower case mixed
      NotAnAddress
    | -- | The checksum does not match: a character is mistyped
      BadChecksum
    | -- | The prefix is none of the four
      UnknownPrefix Text
    | -- | The body is this many bytes, not 60
      BodyLength Int
    | -- | The body is not a whole number of bytes: this many characters
      BodyNotBytes Int
    deriving stock (Eq, Show)

{- | Read an address: the network magic its prefix names and the state token
its body spells. The causes are checked in a fixed order, and the first that
fails is the one reported.
-}
parseRegistryAddress :: Text -> Either AddressRefusal (Word32, Asset)
parseRegistryAddress word = do
    unless (wellFormed word) (Left NotAnAddress)
    (hrp, dataPart) <-
        first (const BadChecksum) (Bech32.decodeLenient (T.toLower word))
    let prefix = Bech32.humanReadablePartToText hrp
    magic <-
        maybe
            (Left (UnknownPrefix prefix))
            Right
            (lookup prefix addressPrefixes)
    body <-
        maybe
            (Left (BodyNotBytes (T.length (Bech32.dataPartToText dataPart))))
            Right
            (Bech32.dataPartToBytes dataPart)
    when (BS.length body /= 60) (Left (BodyLength (BS.length body)))
    -- sixty bytes always split into a policy of 28 and a name of 32
    token <-
        first
            (const (BodyLength (BS.length body)))
            (parseStateToken (spelling body))
    pure (magic, token)
  where
    spelling body =
        hexText (BS.take 28 body) <> "." <> hexText (BS.drop 28 body)

{- | The word is a bech32 word of one case: a prefix of printable characters,
the separator, and a data part of the bech32 alphabet at least as long as a
checksum. This is the first cause; the package's own decoder reports a wrong
character and a wrong checksum the same way, so it is told apart here.
-}
wellFormed :: Text -> Bool
wellFormed word =
    not mixedCase
        && not (T.null separated)
        && prefixOk
        && T.all (`elem` Bech32.dataCharList) payload
        && T.length payload >= 6
  where
    lowered = T.toLower word
    mixedCase = T.toUpper word /= word && lowered /= word
    (separated, payload) = T.breakOnEnd (T.singleton Bech32.separatorChar) lowered
    prefixOk =
        either (const False) (const True) $
            Bech32.humanReadablePartFromText (T.dropEnd 1 separated)

{- | What a refusal says, as the rest of a sentence about the value:
the cause, and nothing of any other cause.
-}
renderAddressRefusal :: AddressRefusal -> Text
renderAddressRefusal = \case
    NotAnAddress ->
        "is not an address: it is not one bech32 word, in lower case or in upper case"
    BadChecksum ->
        "has a wrong checksum: a character of the address is mistyped"
    UnknownPrefix prefix ->
        "has an unknown prefix "
            <> prefix
            <> ": the prefixes are "
            <> T.intercalate ", " (map fst (init addressPrefixes))
            <> " and "
            <> fst (last addressPrefixes)
    BodyLength n ->
        "has a body of " <> T.pack (show n) <> " bytes, not 60"
    BodyNotBytes n ->
        "has a body of "
            <> T.pack (show n)
            <> " characters that is not whole bytes, not 60 bytes"

{- | The CIP-14 fingerprint of a state token: the 160-bit blake2b of its policy
followed by its name, in bech32 under the prefix @asset@.
-}
registryFingerprint :: Asset -> Text
registryFingerprint token =
    Bech32.encodeLenient
        assetPrefix
        ( Bech32.dataPartFromBytes
            (BA.convert (hashWith Blake2b_160 (tokenBytes token)))
        )

-- | The prefix of a CIP-14 fingerprint.
assetPrefix :: Bech32.HumanReadablePart
assetPrefix =
    either
        ( \why ->
            error ("Singular.Registry.Address: the prefix asset: " <> show why)
        )
        id
        (Bech32.humanReadablePartFromText "asset")

-- | The 60 bytes a state token is: its policy, then its name.
tokenBytes :: Asset -> ByteString
tokenBytes (PolicyID policy, AssetName name) =
    scriptHashBytes policy <> SBS.fromShort name

hexText :: ByteString -> Text
hexText = TE.decodeUtf8 . B16.encode
