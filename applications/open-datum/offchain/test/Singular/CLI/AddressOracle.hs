{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.CLI.AddressOracle
Description : What an address holds, read by the bech32 package and the hash directly
License     : Apache-2.0

The relations a registry's address and fingerprint must keep, read without the
module under test: the word is decoded by the @bech32@ package, its prefix is
checked against the four the specification names, its body is compared with the
bytes of the state token, and the fingerprint is rebuilt from blake2b with a
160-bit output and the @asset@ prefix. A case that has run a command and holds
its receipt uses these to say whether the address and the fingerprint it
printed are the registry's.
-}
module Singular.CLI.AddressOracle
    ( addressOf
    , holdsOf
    , prefixFor
    , fingerprintOf
    , bodyOfToken
    ) where

import Codec.Binary.Bech32 qualified as Bech32
import Crypto.Hash (Blake2b_160 (..), hashWith)
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.Text qualified as T
import Data.Word (Word32)

-- | The prefix of a network, as the specification's table gives it.
prefixFor :: Word32 -> Maybe String
prefixFor = \case
    764824073 -> Just "singular"
    1 -> Just "singular_preprod"
    2 -> Just "singular_preview"
    42 -> Just "singular_devnet"
    _ -> Nothing

-- | The address of a state token on a network, written by the package.
addressOf :: Word32 -> String -> Maybe String
addressOf magic token = do
    prefix <- prefixFor magic
    body <- bodyOfToken token
    hrp <-
        either
            (const Nothing)
            Just
            (Bech32.humanReadablePartFromText (T.pack prefix))
    pure
        (T.unpack (Bech32.encodeLenient hrp (Bech32.dataPartFromBytes body)))

-- | The prefix and the body of a word, as the package reads it.
holdsOf :: String -> Maybe (String, ByteString)
holdsOf word = case Bech32.decodeLenient (T.pack word) of
    Left _ -> Nothing
    Right (hrp, dataPart) ->
        (,) (T.unpack (Bech32.humanReadablePartToText hrp))
            <$> Bech32.dataPartToBytes dataPart

-- | The 60 bytes a state token spells: its policy and its name.
bodyOfToken :: String -> Maybe ByteString
bodyOfToken token = case break (== '.') token of
    (policy, '.' : name) ->
        either (const Nothing) Just (B16.decode (BC.pack (policy <> name)))
    _ -> Nothing

-- | The CIP-14 fingerprint of a policy and a name given as one byte string.
fingerprintOf :: ByteString -> Maybe String
fingerprintOf body =
    case Bech32.humanReadablePartFromText "asset" of
        Left _ -> Nothing
        Right hrp ->
            Just
                ( T.unpack
                    ( Bech32.encodeLenient
                        hrp
                        ( Bech32.dataPartFromBytes
                            (BA.convert (hashWith Blake2b_160 body))
                        )
                    )
                )
