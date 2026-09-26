{- |
Module      : Singular.Registry.Node.Wallet
Description : The wallet a run is funded from, and its address
License     : Apache-2.0

The one place a runner's funding identity comes from: the mode's
signing key — the devnet genesis key by default, the joiner's key file
in external mode — loaded once per process and derived into the
address every actor is funded from.

Key material is read from the joiner's file and never printed; only
the derived (public) address is reported ('bech32Address').
-}
module Singular.Registry.Node.Wallet (
    -- * Wallet
    Wallet (..),
    loadWallet,
    walletForMode,
    funderAddr,
    funderSignKey,

    -- * Identity
    sessionMagic,
    bech32Address,
) where

import Data.Aeson (eitherDecodeStrict, withObject, (.:))
import Data.Aeson.Types (parseMaybe)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.Char (isSpace)
import Data.Text qualified as T
import Data.Word (Word32)
import System.IO.Unsafe (unsafePerformIO)

import Codec.Binary.Bech32 qualified as Bech32
import Ouroboros.Network.Magic (NetworkMagic (..))

import Cardano.Ledger.Address (Addr (..), serialiseAddr)
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Credential (Credential (..), StakeReference (..))
import Cardano.Node.Client.E2E.Setup (
    Ed25519DSIGN,
    SignKeyDSIGN,
    devnetMagic,
    genesisSignKey,
    keyHashFromSignKey,
    rawDeserialiseSignKeyDSIGN,
 )
import Singular.Registry.Node.Options (
    ExternalNode (..),
    NodeMode (..),
    die,
    mainnetMagic,
    runMode,
 )

-- | The wallet funding every actor of a run.
data Wallet = Wallet
    { walletAddr :: Addr
    -- ^ Enterprise payment address derived from the signing key
    , walletSignKey :: SignKeyDSIGN Ed25519DSIGN
    -- ^ Signing key; read from the joiner's file, never printed
    , walletNetwork :: Network
    -- ^ Network the address is built for
    }

{- | Load a payment signing key from a file and derive its enterprise
address for the given magic.

Accepts the @cardano-cli@ text envelope (a JSON object with a
@cborHex@ field holding the CBOR byte string @5820\<32 bytes\>@), the
same value as bare hex, and the 32 raw key bytes. The key is never
logged.
-}
loadWallet :: Word32 -> FilePath -> IO Wallet
loadWallet magic path = do
    raw <- BS.readFile path
    keyBytes <- either (die . prefix) pure (signKeyBytes raw)
    sk <- case rawDeserialiseSignKeyDSIGN keyBytes of
        Just sk -> pure sk
        Nothing ->
            die (prefix "the 32 bytes are not a valid Ed25519 signing key")
    let net = if magic == mainnetMagic then Mainnet else Testnet
    pure
        Wallet
            { walletAddr =
                Addr net (KeyHashObj (keyHashFromSignKey sk)) StakeRefNull
            , walletSignKey = sk
            , walletNetwork = net
            }
  where
    prefix msg = "wallet signing key " <> path <> ": " <> msg

-- | The 32 raw key bytes carried by a signing-key file.
signKeyBytes :: ByteString -> Either String ByteString
signKeyBytes raw
    | BS.length trimmed == 32, not (isTextual trimmed) = Right trimmed
    | Just h <- envelopeHex trimmed = unwrap =<< decodeHex h
    | otherwise = unwrap =<< decodeHex trimmed
  where
    trimmed = BC.dropWhile isSpace (BC.dropWhileEnd isSpace raw)
    isTextual = BS.all (\w -> w >= 0x20 && w < 0x7f)
    envelopeHex b
        | BC.take 1 b == "{" = case eitherDecodeStrict b of
            Right v ->
                BC.pack . T.unpack
                    <$> parseMaybe (withObject "skey" (.: "cborHex")) v
            Left _ -> Nothing
        | otherwise = Nothing
    decodeHex b = case B16.decode b of
        Right bytes -> Right bytes
        Left _ ->
            Left
                "not a text envelope with a cborHex field, not hex, and not \
                \32 raw bytes"
    unwrap bytes
        | BS.length bytes == 34
        , BS.take 2 bytes == BS.pack [0x58, 0x20] =
            Right (BS.drop 2 bytes)
        | BS.length bytes == 32 = Right bytes
        | otherwise =
            Left ("expected 32 key bytes, found " <> show (BS.length bytes))

{- | The wallet a mode funds from: the devnet genesis key, or the
joiner's key loaded from the file they named.
-}
walletForMode :: NodeMode -> IO Wallet
walletForMode Devnet =
    pure
        Wallet
            { walletAddr =
                Addr
                    Testnet
                    (KeyHashObj (keyHashFromSignKey genesisSignKey))
                    StakeRefNull
            , walletSignKey = genesisSignKey
            , walletNetwork = Testnet
            }
walletForMode (External e) = loadWallet (extMagic e) (extSkeyFile e)

-- | This process's funding wallet, resolved once from 'runMode'.
processWallet :: Wallet
processWallet = unsafePerformIO (walletForMode runMode)
{-# NOINLINE processWallet #-}

{- | The address every actor of this run is funded from: the devnet
genesis address by default, the joiner's address in external mode.
-}
funderAddr :: Addr
funderAddr = walletAddr processWallet

-- | The signing key matching 'funderAddr'.
funderSignKey :: SignKeyDSIGN Ed25519DSIGN
funderSignKey = walletSignKey processWallet

-- | The network magic this run negotiates with its node.
sessionMagic :: NetworkMagic
sessionMagic = case runMode of
    Devnet -> devnetMagic
    External e -> NetworkMagic (extMagic e)

{- | Bech32 rendering of an address, the form a faucet and an explorer
accept (CIP-5: @addr_test@ on a test network, @addr@ on mainnet).
Shelley addresses exceed bech32's 90-character limit, so the lenient
encoder is the correct one here.
-}
bech32Address :: Addr -> String
bech32Address a =
    T.unpack (Bech32.encodeLenient hrp (Bech32.dataPartFromBytes bytes))
  where
    bytes = serialiseAddr a
    hrp = case a of
        Addr Mainnet _ _ -> unsafeHrp "addr"
        Addr Testnet _ _ -> unsafeHrp "addr_test"
        AddrBootstrap _ -> unsafeHrp "addr"
    unsafeHrp t = case Bech32.humanReadablePartFromText t of
        Right h -> h
        Left err -> error ("bech32Address: bad prefix: " <> show err)
