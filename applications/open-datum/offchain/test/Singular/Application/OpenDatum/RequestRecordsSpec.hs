{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Singular.Application.OpenDatum.RequestRecordsSpec
Description : The bytes a request builder writes are the bytes the validator decodes
License     : Apache-2.0

The records and actions of the request validator, in the layout its types
fix, compared with encodings written by hand from those types. The validator
itself judges the same bytes in the builder rows; these rows say which byte
is which, so a mismatch is found at the field and not at a refused
transaction.
-}
module Singular.Application.OpenDatum.RequestRecordsSpec
    ( spec
    ) where

import Data.ByteString qualified as BS
import Data.Maybe (fromMaybe)
import PlutusCore.Data qualified as PLC
import PlutusLedgerApi.V1 qualified as PV1
import PlutusLedgerApi.V3 (DatumHash (..), Lovelace (..))
import PlutusTx.Builtins.Internal
    ( BuiltinByteString (..)
    , BuiltinData (..)
    )
import PlutusTx.IsData.Class (toBuiltinData)
import Test.Hspec

import Cardano.Ledger.Mary.Value (AssetName (..))
import Cardano.Ledger.Plutus.TxInfo (transAddr)

import Singular.Application.OpenDatum.RequestWorld
    ( baseAddress
    , keyAddress
    , keyHashOf
    , network
    , oracleAddress
    , oracleConfiguration
    , oracleDatumHash
    , oracleLive
    , oracleRegistration
    , scriptAddress
    , seedIn
    )
import Singular.Application.OpenDatum.Requests.Records
    ( MintAction (..)
    , RegistrationData (..)
    , RequestParameters (..)
    , SpendAction (..)
    , approvalNameOf
    , configurationDatum
    , decodeConfiguration
    , decodeRegistration
    , initialDatumHash
    , liveDatum
    , mintRedeemer
    , registrationDatum
    , spendRedeemer
    )
import Singular.Registry.TrieState
    ( RegistryIdentity (..)
    , StatePolicyId (..)
    )
import Singular.State.Preimage
    ( approvalName
    , registrationPreimage
    )

registryOne, registryTwo :: RegistryIdentity
registryOne =
    RegistryIdentity
        (StatePolicyId (BS.replicate 28 0xaa))
        (AssetName "registry one")
registryTwo =
    RegistryIdentity
        (StatePolicyId (BS.replicate 28 0xbb))
        (AssetName "registry two")

parametersA, parametersB :: RequestParameters
parametersA = RequestParameters 2_000_000 1_000_000 600_000 600_000 60_000
parametersB = RequestParameters 0 0 1 2 3

-- | Three registrations that differ in every field a builder chooses.
registrations :: [RegistrationData]
registrations = [registrationA, registrationB, registrationC]

registrationA, registrationB, registrationC :: RegistrationData
registrationA =
    RegistrationData
        { rdRegistry = registryOne
        , rdKey = "first key"
        , rdController = keyHashOf 0x11
        , rdRefundAddress = keyAddress 0x22
        , rdHoldingAddress = scriptAddress 0x33 0x34
        , rdInitialDatum = PLC.I 42
        , rdDeposit = 5_000_000
        , rdBookedAt = 10_060_000
        , rdProcessDeadline = 10_660_000
        , rdReclaimEnd = 11_260_000
        }
registrationB =
    RegistrationData
        { rdRegistry = registryTwo
        , rdKey = BS.replicate 70 0x61
        , rdController = keyHashOf 0x12
        , rdRefundAddress = baseAddress 0x23 0x24
        , rdHoldingAddress = keyAddress 0x35
        , rdInitialDatum = PLC.List [PLC.I 1, PLC.B "payload"]
        , rdDeposit = 7_500_000
        , rdBookedAt = 1
        , rdProcessDeadline = 2
        , rdReclaimEnd = 3
        }
registrationC =
    RegistrationData
        { rdRegistry = registryOne
        , rdKey = ""
        , rdController = keyHashOf 0x13
        , rdRefundAddress = scriptAddress 0x25 0x26
        , rdHoldingAddress = baseAddress 0x36 0x37
        , rdInitialDatum = PLC.Constr 3 []
        , rdDeposit = 2_000_000
        , rdBookedAt = 9_000_000_000_000
        , rdProcessDeadline = 9_000_000_600_000
        , rdReclaimEnd = 9_000_001_200_000
        }

expectedRegistration :: RegistrationData -> PLC.Data
expectedRegistration r =
    oracleRegistration
        (rdRegistry r)
        (rdKey r)
        (rdController r)
        (rdRefundAddress r)
        (rdHoldingAddress r)
        (rdInitialDatum r)
        (rdDeposit r)
        (rdBookedAt r, rdProcessDeadline r, rdReclaimEnd r)

parameterList :: RequestParameters -> [Integer]
parameterList p =
    [ rpRegistrationCost p
    , rpMinimumTip p
    , rpProcessTime p
    , rpRetractTime p
    , rpBookingWidth p
    ]

spec :: Spec
spec = do
    describe "the configuration record" $ do
        it "carries the five request parameters in the validator's order" $
            mapM_
                ( \p ->
                    configurationDatum p
                        `shouldBe` oracleConfiguration (parameterList p)
                )
                [parametersA, parametersB]
        it "reads back the parameters it was written with" $
            mapM_
                ( \p ->
                    decodeConfiguration (configurationDatum p) `shouldBe` Just p
                )
                [parametersA, parametersB]
        it "is not read from a registration or a garbled record" $ do
            let registration = fromMaybe (error "no datum") (registrationDatum registrationA)
            decodeConfiguration registration `shouldBe` Nothing
            decodeConfiguration (PLC.I 1) `shouldBe` Nothing
            decodeConfiguration (PLC.Constr 0 [PLC.Constr 0 [PLC.I 1, PLC.I 2]])
                `shouldBe` Nothing

    describe "the pending registration" $ do
        it "carries the ten booked fields in the validator's order" $
            mapM_
                ( \r ->
                    registrationDatum r `shouldBe` Just (expectedRegistration r)
                )
                registrations
        it "reads back the registration it was written with" $
            mapM_
                ( \r ->
                    (registrationDatum r >>= decodeRegistration network)
                        `shouldBe` Just r
                )
                registrations
        it
            "is not read from a configuration, a live holding or a garbled record"
            $ do
                let configuration = oracleConfiguration (parameterList parametersA)
                    live = oracleLive registryOne "k" (keyHashOf 0x11) 5_000_000 (PLC.I 1)
                decodeRegistration network configuration `shouldBe` Nothing
                decodeRegistration network live `shouldBe` Nothing
                decodeRegistration network (PLC.Constr 1 [PLC.I 1]) `shouldBe` Nothing
        it "uses the address layout the ledger gives a script" $
            mapM_
                ( \a ->
                    fmap addressData (transAddr a) `shouldBe` Just (oracleAddress a)
                )
                [keyAddress 0x22, baseAddress 0x23 0x24, scriptAddress 0x25 0x26]

    describe "the live holding" $
        it "carries the control the validator compares and the payload" $
            mapM_
                ( \(registry, key, controller, deposit, payload) ->
                    liveDatum registry key controller deposit payload
                        `shouldBe` oracleLive registry key controller deposit payload
                )
                [ (registryOne, "first key", keyHashOf 0x11, 5_000_000, PLC.I 42)
                ,
                    ( registryTwo
                    , BS.replicate 70 0x61
                    , keyHashOf 0x12
                    , 7_500_000
                    , PLC.List []
                    )
                ]

    describe "the approval of a registration" $ do
        it "commits the datum of the holding by the hash of its serialisation" $
            mapM_
                (\d -> initialDatumHash d `shouldBe` oracleDatumHash d)
                [ PLC.I 42
                , PLC.List [PLC.I 1, PLC.B "payload"]
                , PLC.Constr 3 []
                , PLC.B (BS.replicate 70 0x61)
                ]
        it "is named from the preimage of the change" $
            mapM_
                ( \r ->
                    approvalNameOf r `shouldBe` Just (expectedApproval r)
                )
                registrations

    describe "the actions of the mint" $ do
        it
            "creates the configuration record naming the registry, the seed and the output"
            $ mintRedeemer [ConfigurationCreate registryOne seedIn 1]
                `shouldBe` PLC.List
                    [ PLC.Constr
                        0
                        [ PLC.B (BS.replicate 28 0xaa)
                        , PLC.B "registry one"
                        , seedData
                        , PLC.I 1
                        ]
                    ]
        it "books the registration of an output" $
            mintRedeemer [BookRegistration 0]
                `shouldBe` PLC.List [PLC.Constr 1 [PLC.I 0]]
        it "burns an approval" $
            mintRedeemer [ApprovalBurn] `shouldBe` PLC.List [PLC.Constr 2 []]
        it "lists several actions in order" $
            mintRedeemer [BookRegistration 2, ApprovalBurn]
                `shouldBe` PLC.List [PLC.Constr 1 [PLC.I 2], PLC.Constr 2 []]

    describe "the actions of the spend" $ do
        it "folds into the holding at an output" $
            spendRedeemer (RegistrationFold 3) `shouldBe` PLC.Constr 0 [PLC.I 3]
        it "reclaims" $ spendRedeemer OwnerReclaim `shouldBe` PLC.Constr 1 []
        it "cleans up" $
            spendRedeemer ExpiredCleanup `shouldBe` PLC.Constr 2 []

-- | The output reference of the seed as the validator's redeemer holds it.
seedData :: PLC.Data
seedData = PLC.Constr 0 [PLC.B (BS.replicate 32 0x77), PLC.I 0]

expectedApproval :: RegistrationData -> AssetName
expectedApproval r =
    approvalName
        ( registrationPreimage
            (rdKey r)
            (rdRegistry r)
            (fromMaybe (error "no Plutus form") (transAddr (rdHoldingAddress r)))
            (DatumHash (BuiltinByteString (oracleDatumHash (rdInitialDatum r))))
            (Lovelace (rdDeposit r))
        )

-- | The Plutus Data a script reads for a translated address.
addressData :: PV1.Address -> PLC.Data
addressData a = let BuiltinData d = toBuiltinData a in d
