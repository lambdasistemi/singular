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

import Control.Exception (SomeException, displayException, try)
import Control.Monad (forM_, void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.List (isInfixOf, sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Word (Word32)
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data (Data (..))
import PlutusTx.Builtins.Internal
    ( BuiltinByteString (..)
    , BuiltinData (..)
    )
import PlutusTx.IsData.Class (FromData (..), ToData (..))
import Test.Hspec

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Alonzo.Plutus.Evaluate (evalTxExUnits)
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.PParams (ppTxFeeFixedL)
import Cardano.Ledger.Api.Scripts.Data (Datum (..))
import Cardano.Ledger.Api.Tx (bodyTxL, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , feeTxBodyL
    , inputsTxBodyL
    , mintTxBodyL
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , scriptIntegrityHashTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , coinTxOutL
    , datumTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits
    ( Redeemers (..)
    , rdmrsTxWitsL
    , scriptTxWitsL
    )
import Cardano.Ledger.BaseTypes
    ( Network (Testnet)
    , SlotNo (..)
    , StrictMaybe (..)
    )
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.Data (getPlutusData)
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.State (UTxO (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Balance (refScriptsSize)
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Application (ApplicationPin (..))
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint
    ( NamingCodes (..)
    , applyRequestParams
    )
import Singular.Registry.Config (CageConfig (..), bootStateFromCfg)
import Singular.Registry.Config.Application
    ( RegistryEconomics (..)
    , configForApplication
    )
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger
    ( AssetName (..)
    , Coin (..)
    , ConwayEra
    , PParams
    , TokenId (..)
    )
import Singular.Registry.LedgerProvider (Session)
import Singular.Registry.NetworkTime
    ( networkEpochInfo
    , networkSystemStart
    )
import Singular.Registry.StubSession
import Singular.Registry.SyntheticLedger (withCostCoefficients)
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.TxBuilder.BookingFixture
    ( cfg
    , codes
    , payer
    , preprodParams
    , program
    , requestPin
    , tokenId
    )
import Singular.Registry.TxBuilder.CollateralJudgement
    ( Spend (..)
    , judgeCollateral
    )
import Singular.Registry.TxBuilder.Internal
    ( addrKeyHashBytes
    , cageAddrFromCfg
    , computeScriptHash
    , extractCageDatum
    , mkInlineDatum
    , onChainTokenId
    , policyIdFromPin
    , requestAddrFromCfg
    , scriptFromBytes
    , scriptHashBytes
    , toPlcData
    )
import Singular.Registry.TxBuilder.RegistrationBooking
    ( RegistrationBooking (..)
    , bookRegistrationImpl
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

    bookingTxSpec

-- ---------------------------------------------------------
-- The booking transaction
-- ---------------------------------------------------------

{- | The registry state output the booking references: at the state address,
holding the one state token, with an inline state datum whose pins are the
configuration's. The pins are written out here, not read through the
library's boot state.
-}
stateRef :: TxIn
stateRef = outRef '7' 0

stateOutputFor :: CageConfig -> TxOut ConwayEra
stateOutputFor c =
    mkBasicTxOut
        (cageAddrFromCfg c Testnet)
        ( MaryValue
            (Coin 2_000_000)
            ( MultiAsset
                ( Map.singleton
                    (PolicyID (cfgScriptHash c))
                    (Map.singleton (unTokenId tokenId) 1)
                )
            )
        )
        & datumTxOutL .~ mkInlineDatum (toPlcData (StateDatum (pinnedBy c)))

-- | The state a registry booted under this configuration carries.
pinnedBy :: CageConfig -> OnChainTokenState
pinnedBy c =
    OnChainTokenState
        { stateRoot = OnChainRoot (BS.replicate 32 0)
        , stateMaxFee = let Coin t = defaultTip c in t
        , stateProcessTime = defaultProcessTime c
        , stateRetractTime = defaultRetractTime c
        , stateAppPolicy =
            BuiltinByteString (SBS.fromShort (cfgApplicationPolicy c))
        , stateActivePolicy =
            BuiltinByteString (SBS.fromShort (cfgActivePolicy c))
        , stateAbsentPolicy =
            BuiltinByteString (SBS.fromShort (cfgAbsentPolicy c))
        , stateTerminalPolicy =
            BuiltinByteString (SBS.fromShort (cfgTerminalPolicy c))
        , stateRegistrationCost = let Coin n = defaultRegistrationCost c in n
        , stateBookingWidth = defaultBookingWidth c
        , stateRequestPolicy =
            BuiltinByteString (SBS.fromShort (cfgRequestPolicy c))
        }

outRef :: Char -> Int -> TxIn
outRef c i =
    either
        (error . ("RegistrationBookingSpec fixture: " <>))
        id
        (parseOutRef (T.pack (replicate 64 c <> "#" <> show i)))

fundingIn :: TxIn
fundingIn = outRef '4' 0

fundingOut :: TxOut ConwayEra
fundingOut = mkBasicTxOut payer (MaryValue (Coin 100_000_000) mempty)

-- | What each address answers with, for the view.
type Served = [(Addr, [(TxIn, TxOut ConwayEra)])]

-- | The ordinary view: the payer's funding output and the given state output.
servedWith :: CageConfig -> TxOut ConwayEra -> Served
servedWith c stateOut =
    [ (payer, [(fundingIn, fundingOut)])
    , (cageAddrFromCfg c Testnet, [(stateRef, stateOut)])
    ]

{- | One view of a served world: outputs by address, the resolved outputs the
evaluator needs, the synthetic network time (one-second slots from the
start, so a slot's start in milliseconds is a thousand times its number) and
the preprod parameters.
-}
viewServing :: Served -> Session NoWitness IO
viewServing = viewServingUnder ledgerParameters

-- | The same world under other protocol parameters.
viewServingUnder
    :: PParams ConwayEra -> Served -> Session NoWitness IO
viewServingUnder params served =
    withAddressOutputs
        (\a -> pure (concat [os | (x, os) <- served, x == a]))
        $ withParameters params
        $ withTime (pure syntheticTime)
        $ withResolvedOutputs
            ( \wanted ->
                pure [(r, o) | (r, o) <- concatMap snd served, r `Set.member` wanted]
            )
            stubSession

ledgerParameters :: PParams ConwayEra
ledgerParameters =
    withCostCoefficients (ExUnits 500_000 200_000_000) 10 preprodParams

viewFor :: CageConfig -> Session NoWitness IO
viewFor c = viewServing (servedWith c (stateOutputFor c))

-- | Book against a view serving this state output.
bookedAgainst :: TxOut ConwayEra -> IO ConwayTx
bookedAgainst stateOut =
    bookRegistrationImpl
        cfg
        (viewServing (servedWith cfg stateOut))
        tokenId
        stateRef
        booking
        payer

{- | Fourteen distinct bytes make a 28-byte policy that is none of the
registry's.
-}
anotherPolicy :: SBS.ShortByteString
anotherPolicy = SBS.toShort (BS.replicate 28 0x5e)

presentButNotTheRegistrys :: Spec
presentButNotTheRegistrys =
    describe
        "refuses a state output that is present but not the registry's"
        $ do
            let honest = stateOutputFor cfg
                holding v = honest & valueTxOutL .~ v
                stateToken policy name =
                    MaryValue
                        (Coin 2_000_000)
                        ( MultiAsset
                            (Map.singleton policy (Map.singleton (AssetName name) 1))
                        )
                registryToken = unTokenId tokenId
            it
                "at the state address, with the honest datum, without the state token"
                $ refusesWith "does not hold the registry's state token"
                $ bookedAgainst (holding (MaryValue (Coin 2_000_000) mempty))
            it "holding another registry's state token" $
                refusesWith "does not hold the registry's state token" $
                    bookedAgainst
                        ( holding
                            ( stateToken
                                (PolicyID (cfgScriptHash cfg))
                                (SBS.toShort "another-registry")
                            )
                        )
            it "holding a token of this name under another policy" $
                refusesWith "does not hold the registry's state token" $
                    bookedAgainst
                        ( holding
                            ( stateToken
                                (policyIdFromPin anotherPolicy)
                                (case registryToken of AssetName n -> n)
                            )
                        )
            it "with a registration datum where the state datum belongs" $
                refusesWith "does not carry this configuration's booking pins" $
                    bookedAgainst
                        ( honest
                            & datumTxOutL
                                .~ mkInlineDatum
                                    (toPlcData (RegistrationDatum (requestFor booking)))
                        )
            it "with no datum" $
                refusesWith "does not carry this configuration's booking pins" $
                    bookedAgainst (honest & datumTxOutL .~ NoDatum)
            it "served only at the payer's address, not at the state address" $
                refusesWith "state output not found" $
                    bookRegistrationImpl
                        cfg
                        ( viewServing
                            [ (payer, [(fundingIn, fundingOut), (stateRef, honest)])
                            , (cageAddrFromCfg cfg Testnet, [])
                            ]
                        )
                        tokenId
                        stateRef
                        booking
                        payer
            describe "pinning other terms, one at a time" $ do
                let pinsOf c = bookedAgainst (stateOutputFor c)
                    refused = refusesWith "does not carry this configuration's booking pins"
                it "a registration cost one lovelace higher" $
                    refused (pinsOf cfg{defaultRegistrationCost = Coin 2_000_001})
                it "a minimum tip one lovelace higher" $
                    refused (pinsOf cfg{defaultTip = Coin 1_000_001})
                it "a booking width one millisecond wider" $
                    refused (pinsOf cfg{defaultBookingWidth = 10_001})
                it "another request policy" $
                    refused (pinsOf cfg{cfgRequestPolicy = anotherPolicy})
                it "another application policy" $
                    refused (pinsOf cfg{cfgApplicationPolicy = anotherPolicy})

-- | The units the ledger's own evaluator measures on the final body.
measuredOn
    :: ConwayTx -> Map.Map (ConwayPlutusPurpose AsIx ConwayEra) ExUnits
measuredOn tx =
    Map.map
        (either (error . ("independent evaluation: " <>) . show) id)
        ( evalTxExUnits
            ledgerParameters
            tx
            ( UTxO
                (Map.fromList [(fundingIn, fundingOut), (stateRef, stateOutputFor cfg)])
            )
            (networkEpochInfo syntheticTime)
            (networkSystemStart syntheticTime)
        )

measuredSpec :: Spec
measuredSpec = describe "the measured budget" $ do
    it
        "declares for each redeemer the units the ledger evaluator measures on the final body"
        $ do
            tx <- built cfg booking
            let Redeemers declared = tx ^. witsTxL . rdmrsTxWitsL
            Map.map snd declared `shouldBe` measuredOn tx
    it
        "states the fee and collateral the ledger charges for the body it submits"
        $ do
            tx <- built cfg booking
            judgeCollateral
                Spend
                    { spInputs = [(fundingIn, 100_000_000)]
                    , spFunding = fundingIn
                    , spRefBytes = 0
                    }
                tx
                `shouldBe` []

-- ---------------------------------------------------------
-- The funding output
-- ---------------------------------------------------------

-- | The lovelace the request output holds: the declared cost, tip and carrier.
requestLovelace :: Integer
requestLovelace =
    let r = requestFor booking
    in  regRegistrationCost r + regDeclaredTip r + regCarrierAda r

-- | The fee a transaction states.
feeOf :: ConwayTx -> Integer
feeOf tx = let Coin f = tx ^. bodyTxL . feeTxBodyL in f

-- | The output a balancer appends last: the change.
lastOutput :: ConwayTx -> Maybe (TxOut ConwayEra)
lastOutput tx =
    listToMaybe (reverse (toList (tx ^. bodyTxL . outputsTxBodyL)))

-- | Book for a payer who holds only this one ada-only output.
bookedFundedBy :: PParams ConwayEra -> Integer -> IO ConwayTx
bookedFundedBy params lovelace =
    bookRegistrationImpl
        cfg
        ( viewServingUnder
            params
            [
                ( payer
                , [(fundingIn, mkBasicTxOut payer (MaryValue (Coin lovelace) mempty))]
                )
            , (cageAddrFromCfg cfg Testnet, [(stateRef, stateOutputFor cfg)])
            ]
        )
        tokenId
        stateRef
        booking
        payer

{- | The minimum ada of an ada-only output at the payer's address, derived
from the parameters: what a change output must hold.
-}
changeMinimum :: PParams ConwayEra -> Integer
changeMinimum params =
    let Coin m =
            getMinCoinTxOut
                params
                (mkBasicTxOut payer (MaryValue (Coin 1_000_000) mempty))
    in  m

{- | A payer with one ada-only output has to pay the request, the fee and
leave each output the ledger will check its minimum ada. A booking that
cannot is refused with the reason, or states exactly what it owes: no
transaction the ledger would refuse is returned.

The fee that sizes each funding output is read from a booking funded amply;
the judgement of every transaction derives its own expectations from the
parameters and from the funding output alone.
-}
fundingSpec :: Spec
fundingSpec = describe "the funding output" $ do
    let owes lovelace =
            Spend
                { spInputs = [(fundingIn, lovelace)]
                , spFunding = fundingIn
                , spRefBytes = 0
                }
        feeAmply = feeOf <$> bookedFundedBy ledgerParameters 100_000_000
        refusedOrOwesNothing lovelace = do
            outcome <- try (bookedFundedBy ledgerParameters lovelace)
            case outcome of
                Left e ->
                    displayException (e :: SomeException)
                        `shouldSatisfy` isInfixOf "the funding output is too small"
                Right tx -> judgeCollateral (owes lovelace) tx `shouldBe` []
        minimum' = changeMinimum ledgerParameters
    it "leaves the change its minimum ada when it holds a little more" $ do
        fee <- feeAmply
        let lovelace = requestLovelace + fee + minimum' + 50_000
        tx <- bookedFundedBy ledgerParameters lovelace
        judgeCollateral (owes lovelace) tx `shouldBe` []
    it
        "leaves the change exactly its minimum ada when the funding output holds just that"
        $ do
            fee <- feeAmply
            let lovelace = requestLovelace + fee + minimum'
            tx <- bookedFundedBy ledgerParameters lovelace
            -- The fee does not depend on the amount funded, so this funding
            -- leaves exactly the minimum; if it did, the example would say so.
            feeOf tx `shouldBe` fee
            fmap (^. coinTxOutL) (lastOutput tx)
                `shouldBe` Just (Coin minimum')
            judgeCollateral (owes lovelace) tx `shouldBe` []
    it
        "does not return a change output one lovelace below its minimum ada"
        $ do
            fee <- feeAmply
            refusedOrOwesNothing (requestLovelace + fee + minimum' - 1)
    it "does not return a change output a little below its minimum ada" $ do
        fee <- feeAmply
        refusedOrOwesNothing (requestLovelace + fee + minimum' - 50_000)
    it "does not return a change output of a fraction of its minimum ada" $ do
        fee <- feeAmply
        refusedOrOwesNothing (requestLovelace + fee + minimum' `div` 4)
    it
        "does not put the whole funding output at risk when it cannot leave a collateral return"
        $ do
            -- A fixed fee above twice the request makes the required
            -- collateral exceed what the request and the fee leave, so a
            -- funding output can pay for the booking and its change and
            -- still be unable to return its collateral's remainder.
            let costly = ledgerParameters & ppTxFeeFixedL .~ Coin 12_000_000
            fee <- feeOf <$> bookedFundedBy costly 100_000_000
            let collateral = (fee * 150 + 99) `div` 100
                lovelace = collateral + changeMinimum costly `div` 2
            lovelace - requestLovelace - fee
                `shouldSatisfy` (>= changeMinimum costly)
            bookedFundedBy costly lovelace
                `shouldThrow` \e ->
                    "collateral return" `isInfixOf` displayException (e :: SomeException)

-- ---------------------------------------------------------
-- A state output that carries a script
-- ---------------------------------------------------------

{- | The registry's state output also carrying a Plutus script. Nothing in
the registry forbids it, and a transaction that references the output is
charged for the script's bytes whether or not it runs them.
-}
stateWithScript :: TxOut ConwayEra
stateWithScript =
    stateOutputFor cfg
        & referenceScriptTxOutL
            .~ SJust (scriptFromBytes "state-reference" (ncApplication codes))

{- | The lovelace the ledger charges for each reference-script byte, in
the public preprod parameters the fixtures run under.
-}
referenceByteLovelace :: Integer
referenceByteLovelace = 15

stateReferenceScriptSpec :: Spec
stateReferenceScriptSpec =
    describe "a state output that carries a reference script" $ do
        let bytes =
                toInteger $
                    refScriptsSize
                        (Set.singleton stateRef)
                        [(stateRef, stateWithScript)]
        it "carries script bytes the ledger prices" $
            bytes `shouldSatisfy` (> 0)
        it
            "states the fee the ledger charges for the script bytes the booking references"
            $ do
                tx <- bookedAgainst stateWithScript
                judgeCollateral
                    Spend
                        { spInputs = [(fundingIn, 100_000_000)]
                        , spFunding = fundingIn
                        , spRefBytes = fromInteger bytes
                        }
                    tx
                    `shouldBe` []
        it "pays at least the byte price for each byte more than without it" $ do
            without <- feeOf <$> bookedAgainst (stateOutputFor cfg)
            with <- feeOf <$> bookedAgainst stateWithScript
            with - without `shouldSatisfy` (>= referenceByteLovelace * bytes)

-- | A booking at the upper slot 4 005, the lower slot five seconds earlier.
booking :: RegistrationBooking
booking =
    RegistrationBooking
        { rbKey = "booked-key"
        , rbRefundAddress = payer
        , rbDestination = BS.cons 0x60 (BS.replicate 28 0x77)
        , rbDatum = Just (I 7)
        , rbDeclaredTip = Coin 1_500_000
        , rbCarrier = Coin 1_500_000
        , rbNonce = 5
        , rbLower = SlotNo 4_000
        , rbUpper = SlotNo 4_005
        , rbApplicationScript = ncApplication codes
        }

built :: CageConfig -> RegistrationBooking -> IO ConwayTx
built c b = bookRegistrationImpl c (viewFor c) tokenId stateRef b payer

-- | The request the booking states, written from the booking's own values.
requestFor :: RegistrationBooking -> OnChainRegistrationRequest
requestFor b =
    OnChainRegistrationRequest
        { regRegistry = onChainTokenId tokenId
        , regKey = rbKey b
        , regRefundAddress =
            BuiltinByteString (addrKeyHashBytes (rbRefundAddress b))
        , regDestination = rbDestination b
        , regDatum = rbDatum b
        , regSubmittedAt = 1000 * slotNumber (rbUpper b)
        , regRegistrationCost = let Coin n = defaultRegistrationCost cfg in n
        , regDeclaredTip = let Coin n = rbDeclaredTip b in n
        , regCarrierAda = let Coin n = rbCarrier b in n
        , regNonce = rbNonce b
        }
  where
    slotNumber (SlotNo s) = fromIntegral s

appPolicyId, requestPolicyId :: PolicyID
appPolicyId = policyIdFromPin (cfgApplicationPolicy cfg)
requestPolicyId = policyIdFromPin requestPin

refusesWith :: String -> IO a -> Expectation
refusesWith what action =
    action `shouldThrow` \e -> what `isInfixOf` displayException (e :: SomeException)

bookingTxSpec :: Spec
bookingTxSpec = describe "the registration booking transaction" $ do
    it
        "pays the request address the declared cost, tip and carrier with both tags and the registration datum"
        $ do
            tx <- built cfg booking
            let r = requestFor booking
                outs = toList (tx ^. bodyTxL . outputsTxBodyL)
                atRequest =
                    [ o
                    | o <- outs
                    , o ^. addrTxOutL == requestAddrFromCfg cfg tokenId Testnet
                    ]
                tags =
                    MultiAsset
                        ( Map.fromList
                            [
                                ( requestPolicyId
                                , Map.singleton (AssetName (SBS.toShort (trieReadyTagName r))) 1
                                )
                            ,
                                ( appPolicyId
                                , Map.singleton (AssetName (SBS.toShort (applicationTagOf r))) 1
                                )
                            ]
                        )
            case atRequest of
                [o] -> do
                    o ^. valueTxOutL `shouldBe` MaryValue (Coin 5_000_000) tags
                    extractCageDatum o `shouldBe` Just (RegistrationDatum r)
                other -> expectationFailure ("request outputs: " <> show (length other))
    it
        "mints exactly the two tags, one under each policy, and nothing else"
        $ do
            tx <- built cfg booking
            let r = requestFor booking
            tx ^. bodyTxL . mintTxBodyL
                `shouldBe` MultiAsset
                    ( Map.fromList
                        [
                            ( requestPolicyId
                            , Map.singleton (AssetName (SBS.toShort (trieReadyTagName r))) 1
                            )
                        ,
                            ( appPolicyId
                            , Map.singleton (AssetName (SBS.toShort (applicationTagOf r))) 1
                            )
                        ]
                    )
    it
        "states the booked time as the start of the upper slot and the interval as the slots"
        $ do
            tx <- built cfg booking
            tx ^. bodyTxL . vldtTxBodyL
                `shouldBe` ValidityInterval (SJust (SlotNo 4_000)) (SJust (SlotNo 4_005))
            fmap regSubmittedAt (registrationOf tx) `shouldBe` Just 4_005_000
    it
        "references the registry state and spends the payer's output, which is also its collateral"
        $ do
            tx <- built cfg booking
            tx ^. bodyTxL . referenceInputsTxBodyL
                `shouldBe` Set.singleton stateRef
            tx ^. bodyTxL . inputsTxBodyL `shouldBe` Set.singleton fundingIn
            tx ^. bodyTxL . collateralInputsTxBodyL
                `shouldBe` Set.singleton fundingIn
    it "carries each mint's script and its redeemer, with measured units" $ do
        tx <- built cfg booking
        Map.keysSet (tx ^. witsTxL . scriptTxWitsL)
            `shouldBe` Set.fromList
                [ hashScript (scriptFromBytes "request" (appliedRequest cfg))
                , hashScript
                    (scriptFromBytes "application" (rbApplicationScript booking))
                ]
        let Redeemers rs = tx ^. witsTxL . rdmrsTxWitsL
            byPolicy =
                [ (p, getPlutusData d, units)
                | (ConwayMinting (AsIx i), (d, units)) <- Map.toList rs
                , (p, ix) <- zip (sort [requestPolicyId, appPolicyId]) [0 :: Word32 ..]
                , ix == i
                ]
        map (\(p, d, _) -> (p, d)) byPolicy
            `shouldMatchList` [ (requestPolicyId, Constr 0 [])
                              ,
                                  ( appPolicyId
                                  , Constr
                                        1
                                        [ B (rbKey booking)
                                        , B (addrKeyHashBytes (rbRefundAddress booking))
                                        , B (rbDestination booking)
                                        , I (rbNonce booking)
                                        ]
                                  )
                              ]
        all (\(_, _, ExUnits m s) -> m > 0 && s > 0) byPolicy `shouldBe` True
        tx ^. bodyTxL . scriptIntegrityHashTxBodyL `shouldSatisfy` setS
    it "is balanced: the payer's output is the outputs plus the fee" $ do
        tx <- built cfg booking
        let Coin fee = tx ^. bodyTxL . feeTxBodyL
            outs = toList (tx ^. bodyTxL . outputsTxBodyL)
            total = sum [c | o <- outs, let Coin c = o ^. coinTxOutL]
        fee `shouldSatisfy` (> 0)
        total + fee `shouldBe` 100_000_000
        length outs `shouldBe` 2
    presentButNotTheRegistrys
    measuredSpec
    fundingSpec
    stateReferenceScriptSpec
    describe "refuses before building" $ do
        it "an interval wider than the registry's widest" $
            refusesWith "wider than the registry's booking width" $
                built cfg booking{rbLower = SlotNo 3_994}
        it "an interval exactly as wide as the registry's widest is accepted" $
            void (built cfg booking{rbLower = SlotNo 3_995})
        it "an empty interval" $
            refusesWith "lower slot is not before the upper slot" $
                built cfg booking{rbLower = SlotNo 4_005}
        it "an inverted interval" $
            refusesWith "lower slot is not before the upper slot" $
                built cfg booking{rbLower = SlotNo 4_006}
        it "a tip below the registry's minimum" $
            refusesWith "tip is below the registry's minimum tip" $
                built cfg booking{rbDeclaredTip = Coin 999_999}
        it "a negative carrier" $
            refusesWith "carrier is negative" $
                built cfg booking{rbCarrier = Coin (-1)}
        it "a negative nonce" $
            refusesWith "nonce is negative" $
                built cfg booking{rbNonce = -1}
        it "a refund address that is not a key address" $
            refusesWith "refund address is not a key address" $
                built cfg booking{rbRefundAddress = cageAddrFromCfg cfg Testnet}
        it
            "an application script that is not the registry's application policy"
            $ refusesWith
                "application script is not the registry's application policy"
            $ built cfg booking{rbApplicationScript = program}
        it "a state reference that no output at the state address answers" $
            refusesWith "state output not found" $
                bookRegistrationImpl
                    cfg
                    (viewFor cfg)
                    tokenId
                    (outRef '8' 3)
                    booking
                    payer
        it "a state output pinning other booking terms than the configuration" $
            refusesWith "does not carry this configuration's booking pins" $ do
                let other = cfg{defaultBookingWidth = 20_000}
                bookRegistrationImpl
                    cfg
                    (viewFor other)
                    tokenId
                    stateRef
                    booking
                    payer
        it "a booking that cannot carry its own minimum ada" $
            refusesWith "below the minimum ada" $ do
                let thin = cfg{defaultRegistrationCost = Coin 0, defaultTip = Coin 0}
                built thin booking{rbDeclaredTip = Coin 0, rbCarrier = Coin 0}
  where
    setS (SJust _) = True
    setS SNothing = False

-- | The registration a booking transaction carries, read back from its request output.
registrationOf :: ConwayTx -> Maybe OnChainRegistrationRequest
registrationOf tx =
    case [ r
         | o <- toList (tx ^. bodyTxL . outputsTxBodyL)
         , o ^. addrTxOutL == requestAddrFromCfg cfg tokenId Testnet
         , Just (RegistrationDatum r) <- [extractCageDatum o]
         ] of
        [r] -> Just r
        _ -> Nothing

-- | The request script as the booking attaches it: the unapplied bytes applied to the registry.
appliedRequest :: CageConfig -> SBS.ShortByteString
appliedRequest c =
    applyRequestParams
        (scriptHashBytes (cfgScriptHash c))
        (onChainTokenId tokenId)
        (requestScriptBytes c)

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
