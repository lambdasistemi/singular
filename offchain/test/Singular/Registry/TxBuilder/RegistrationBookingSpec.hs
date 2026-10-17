{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TxBuilder.RegistrationBookingSpec
Description : The registration booking on the wire, by name, and by configuration
License     : Apache-2.0

What a registration booking commits to, said in terms the model gives:
the registration request and the cage datum that carries it, the eleven-field
state that pins the cost, the widest interval and the request policy, the two
tag names a booking mints, and the one request policy that the configuration,
the state and the request address agree on.

The expected tag names come from the vector generator
(@cage-test-vectors@, JSON mode): it builds each preimage field by field in
the model's order and the Plutus evaluator runs the hash, so neither name
helper in this library produced them. The block of vectors below was written
by a program from that output, never typed.
-}
module Singular.Registry.TxBuilder.RegistrationBookingSpec (spec) where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import PlutusCore.Data (Data (..))
import PlutusTx.Builtins.Internal
    ( BuiltinByteString (..)
    , BuiltinData (..)
    )
import PlutusTx.IsData.Class (FromData (..), ToData (..))
import Test.Hspec

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Hashes (ScriptHash (..))

import Singular.Registry.Application (ApplicationPin (..))
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint (applyRequestParams)
import Singular.Registry.Config (CageConfig (..), bootStateFromCfg)
import Singular.Registry.Config.Application
    ( RegistryEconomics (..)
    , configForApplication
    )
import Singular.Registry.Ledger
    ( AssetName (..)
    , Coin (..)
    , TokenId (..)
    )
import Singular.Registry.TxBuilder.BookingFixture
    ( cfg
    , codes
    , program
    , requestPin
    , tokenId
    )
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , requestAddrFromCfg
    , scriptHashBytes
    )
import Singular.Registry.Types

-- ---------------------------------------------------------
-- Three registrations and the names the machine computed
-- ---------------------------------------------------------

data Vector = Vector
    { vDescription :: String
    , vKey :: ByteString
    , vRefund :: ByteString
    , vDestination :: ByteString
    , vCost :: Integer
    , vTip :: Integer
    , vCarrier :: Integer
    , vNonce :: Integer
    , vApplicationTag :: ByteString
    , vTrieReadyTag :: ByteString
    }

unhex :: ByteString -> ByteString
unhex = either (error . ("unhex: " <>)) id . B16.decode

{- | Written by @jq@ from @cage-test-vectors@ JSON mode (the registration
booking vectors), not typed.
-}
vectors :: [Vector]
vectors =
    [ Vector
        { vDescription = "registration booking request one"
        , vKey = unhex "6b657941"
        , vRefund =
            unhex "d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1"
        , vDestination =
            unhex "60d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1"
        , vCost = 2_000_000
        , vTip = 1_000_000
        , vCarrier = 1_500_000
        , vNonce = 1
        , vApplicationTag =
            unhex
                "4eadfc1d466b50e5b860eb4b331c49160f272c734a7da61448e56833484037b5"
        , vTrieReadyTag =
            unhex
                "2a575fb644da9397be97cafd6293b9cc8aa3d2c10c785c6b62ff6090196173b8"
        }
    , Vector
        { vDescription = "registration booking request two"
        , vKey = unhex "6b657942"
        , vRefund =
            unhex "d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2"
        , vDestination =
            unhex "60d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2d2"
        , vCost = 2_000_000
        , vTip = 1_500_000
        , vCarrier = 1_200_000
        , vNonce = 2
        , vApplicationTag =
            unhex
                "a1c71693342632db781c8369334aa29814760f3e11afdf6f0d5f46e8c25a9133"
        , vTrieReadyTag =
            unhex
                "05b7b16f2567300c65be3665b9a0eae8230318e164160d24c18a3c0b16f4f384"
        }
    , Vector
        { vDescription = "registration booking request three"
        , vKey = unhex "6b657943"
        , vRefund =
            unhex "d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3"
        , vDestination =
            unhex "70d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4"
        , vCost = 2_000_000
        , vTip = 3_000_000
        , vCarrier = 2_000_000
        , vNonce = 1_000_000_000_000
        , vApplicationTag =
            unhex
                "6d4a8cb3f8d6f7b9dc0e56f65cfc6789ce2337af08b67be2f681d23b4d7e35a5"
        , vTrieReadyTag =
            unhex
                "545bcda791df3dcf2f60422e9a52d1bd5575527c1462e77540c63958235b6826"
        }
    ]

firstVector :: Vector
firstVector = case vectors of
    v : _ -> v
    [] -> error "no registration booking vectors"

-- | The generator gives its second registration a delivered datum.
datumOf :: Vector -> Maybe Data
datumOf v
    | vNonce v == 2 = Just (I 42)
    | otherwise = Nothing

{- | The booked time and the registry differ from any transaction row on
purpose: neither name commits to them.
-}
bookedTime :: Integer
bookedTime = 777

registryName :: ByteString
registryName = "another registry"

requestOf :: Vector -> OnChainRegistrationRequest
requestOf v =
    OnChainRegistrationRequest
        { regRegistry = OnChainTokenId (BuiltinByteString registryName)
        , regKey = vKey v
        , regRefundAddress = BuiltinByteString (vRefund v)
        , regDestination = vDestination v
        , regDatum = datumOf v
        , regSubmittedAt = bookedTime
        , regRegistrationCost = vCost v
        , regDeclaredTip = vTip v
        , regCarrierAda = vCarrier v
        , regNonce = vNonce v
        }

-- | The request as the on-chain type lays it out, written without the codec.
wireOf :: Vector -> Data
wireOf v =
    Constr
        0
        [ Constr 0 [B registryName]
        , B (vKey v)
        , B (vRefund v)
        , B (vDestination v)
        , maybe (Constr 1 []) (\d -> Constr 0 [d]) (datumOf v)
        , I bookedTime
        , I (vCost v)
        , I (vTip v)
        , I (vCarrier v)
        , I (vNonce v)
        ]

applicationTagOf :: OnChainRegistrationRequest -> ByteString
applicationTagOf r =
    applicationTagName
        (regKey r)
        (regRefundAddress r)
        (regDestination r)
        (regNonce r)

-- ---------------------------------------------------------
-- The rows
-- ---------------------------------------------------------

spec :: Spec
spec = do
    describe "the registration request on the wire" $ do
        forM_ vectors $ \v -> describe (vDescription v) $ do
            it "encodes its ten fields in the order of the on-chain type" $
                toBuiltinData (requestOf v) `shouldBe` BuiltinData (wireOf v)
            it "reads its own encoding back" $
                fromBuiltinData (toBuiltinData (requestOf v))
                    `shouldBe` Just (requestOf v)
            it "is constructor three of the cage datum" $
                toBuiltinData (RegistrationDatum (requestOf v))
                    `shouldBe` BuiltinData (Constr 3 [wireOf v])
            it "is read back from the cage datum" $
                fromBuiltinData (toBuiltinData (RegistrationDatum (requestOf v)))
                    `shouldBe` Just (RegistrationDatum (requestOf v))
        it "refuses a request with a field missing" $
            fromBuiltinData
                (BuiltinData (Constr 0 (take 9 (fieldsOf firstVector))))
                `shouldBe` (Nothing :: Maybe OnChainRegistrationRequest)
        it "refuses a request whose number is a byte string" $
            fromBuiltinData
                ( BuiltinData
                    (Constr 0 (replaceAt 9 (B "1") (fieldsOf firstVector)))
                )
                `shouldBe` (Nothing :: Maybe OnChainRegistrationRequest)

    describe "the state with its three booking pins on the wire" $ do
        it
            "encodes eleven fields: the eight, then cost, width, request policy"
            $ toBuiltinData pinnedState `shouldBe` BuiltinData pinnedStateWire
        it "reads its own encoding back" $
            fromBuiltinData (toBuiltinData pinnedState)
                `shouldBe` Just pinnedState
        it "no longer reads the eight-field state" $
            fromBuiltinData (BuiltinData (Constr 0 (take 8 stateFields)))
                `shouldBe` (Nothing :: Maybe OnChainTokenState)
        it "exposes the request policy as plain bytes" $
            stateRequestPolicyBytes pinnedState `shouldBe` BS.replicate 28 0xe0

    describe "the tag names a booking mints" $ do
        forM_ vectors $ \v -> describe (vDescription v) $ do
            it "names the application tag as the machine computed it" $
                applicationTagOf (requestOf v) `shouldBe` vApplicationTag v
            it "names the trie-ready tag as the machine computed it" $
                trieReadyTagName (requestOf v) `shouldBe` vTrieReadyTag v
        describe "what each name commits to" $ do
            let base = requestOf (vectors !! 1)
                apps = applicationTagOf
                tries = trieReadyTagName
                differs f g = f g `shouldNotBe` f base
                same f g = f g `shouldBe` f base
            it "both names commit to the key" $ do
                let r = base{regKey = "another key"}
                differs apps r >> differs tries r
            it "both names commit to the refund address" $ do
                let r = base{regRefundAddress = BuiltinByteString (BS.replicate 28 0x99)}
                differs apps r >> differs tries r
            it "both names commit to the destination" $ do
                let r = base{regDestination = "another destination"}
                differs apps r >> differs tries r
            it "both names commit to the nonce" $ do
                let r = base{regNonce = regNonce base + 1}
                differs apps r >> differs tries r
            it
                "only the trie-ready name commits to the cost, the tip and the carrier"
                $ do
                    let c = base{regRegistrationCost = regRegistrationCost base + 1}
                        t = base{regDeclaredTip = regDeclaredTip base + 1}
                        a = base{regCarrierAda = regCarrierAda base + 1}
                    mapM_ (same apps) [c, t, a]
                    mapM_ (differs tries) [c, t, a]
            it
                "neither name commits to the delivered datum, the booked time or the registry"
                $ do
                    let rs =
                            [ base{regDatum = Nothing}
                            , base{regSubmittedAt = regSubmittedAt base + 1}
                            , base{regRegistry = OnChainTokenId "yet another registry"}
                            ]
                    mapM_ (same apps) rs
                    mapM_ (same tries) rs
            it "the two names of one registration are different" $
                applicationTagOf base `shouldNotBe` trieReadyTagName base

    describe "the configuration binds one request policy" $ do
        let econ =
                RegistryEconomics
                    { reProcessTime = 30_000
                    , reRetractTime = 30_000
                    , reTip = Coin 1_000_000
                    , reRegistrationCost = Coin 2_000_000
                    , reBookingWidth = 10_000
                    }
            seed = cageSeed cfg
            (derived, _) =
                configForApplication
                    (PinAsCompiled "application")
                    codes
                    program
                    program
                    econ
                    Testnet
                    seed
            derivedToken =
                TokenId (AssetName (SBS.toShort (deriveAssetName seed)))
            -- The applied request hash assembled from primitives, not by
            -- the library's own derivation.
            expectedPin =
                SBS.toShort $
                    scriptHashBytes $
                        computeScriptHash $
                            applyRequestParams
                                (scriptHashBytes (computeScriptHash program))
                                ( OnChainTokenId $
                                    BuiltinByteString (deriveAssetName seed)
                                )
                                program
        it
            "the booted state carries the configured cost, width and request policy"
            $ do
                let st = bootStateFromCfg cfg (OnChainRoot (BS.replicate 32 0))
                ( stateRegistrationCost st
                    , stateBookingWidth st
                    , stateRequestPolicyBytes st
                    )
                    `shouldBe` (2_000_000, 10_000, SBS.fromShort requestPin)
        it
            "a configuration derived from a seed carries the economics it was given"
            $ ( defaultRegistrationCost derived
              , defaultBookingWidth derived
              )
                `shouldBe` (Coin 2_000_000, 10_000)
        it "a configuration derived from a seed pins the applied request hash" $
            cfgRequestPolicy derived `shouldBe` expectedPin
        it
            "the pin is the payment credential of the address requests are sent to"
            $ case requestAddrFromCfg derived derivedToken Testnet of
                Addr _ (ScriptHashObj (ScriptHash h)) _ ->
                    scriptHashBytes (ScriptHash h)
                        `shouldBe` SBS.fromShort (cfgRequestPolicy derived)
                other -> expectationFailure ("not a script address: " <> show other)
        it
            "the fixture registry's pin is the credential of its request address"
            $ case requestAddrFromCfg cfg tokenId Testnet of
                Addr _ (ScriptHashObj (ScriptHash h)) _ ->
                    scriptHashBytes (ScriptHash h) `shouldBe` SBS.fromShort requestPin
                other -> expectationFailure ("not a script address: " <> show other)

-- ---------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------

fieldsOf :: Vector -> [Data]
fieldsOf v = case wireOf v of
    Constr _ fields -> fields
    other -> error ("fieldsOf: " <> show other)

replaceAt :: Int -> a -> [a] -> [a]
replaceAt n x xs = take n xs <> [x] <> drop (n + 1) xs

-- | The state a registry with the three booking pins carries.
pinnedState :: OnChainTokenState
pinnedState =
    OnChainTokenState
        { stateRoot = OnChainRoot (BS.replicate 32 0xbb)
        , stateMaxFee = 2_000_000
        , stateProcessTime = 300_000
        , stateRetractTime = 600_000
        , stateAppPolicy = BuiltinByteString (BS.replicate 28 0xa9)
        , stateActivePolicy = BuiltinByteString (BS.replicate 28 0xaa)
        , stateAbsentPolicy = BuiltinByteString (BS.replicate 28 0xb0)
        , stateTerminalPolicy = BuiltinByteString (BS.replicate 28 0xc0)
        , stateRegistrationCost = 2_500_000
        , stateBookingWidth = 10_000
        , stateRequestPolicy = BuiltinByteString (BS.replicate 28 0xe0)
        }

stateFields :: [Data]
stateFields =
    [ B (BS.replicate 32 0xbb)
    , I 2_000_000
    , I 300_000
    , I 600_000
    , B (BS.replicate 28 0xa9)
    , B (BS.replicate 28 0xaa)
    , B (BS.replicate 28 0xb0)
    , B (BS.replicate 28 0xc0)
    , I 2_500_000
    , I 10_000
    , B (BS.replicate 28 0xe0)
    ]

pinnedStateWire :: Data
pinnedStateWire = Constr 0 stateFields
