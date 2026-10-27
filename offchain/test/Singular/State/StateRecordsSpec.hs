{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.State.StateRecordsSpec
Description : The datum and the actions of the state validator, as Plutus Data
License     : Apache-2.0

The encodings are compared with bytes written here by hand from the type
definitions of the validator (@singular_state\/state@, @genesis@, @fold@), so a
row compares the codec with data it did not produce. The same functions decode
what a transaction's redeemers carry, so every action the builders write is
read back as it was written.
-}
module Singular.State.StateRecordsSpec
    ( spec
    ) where

import Data.ByteString qualified as BS
import PlutusCore.Data qualified as PLC
import Test.Hspec

import Data.ByteString.Base16 qualified as B16
import PlutusLedgerApi.V3 (DatumHash (..))
import PlutusTx.Builtins.Internal (BuiltinByteString (..))

import Singular.Registry.Types (Neighbor (..), ProofStep (..))
import Singular.State.Preimage (initialDatumHash)
import Singular.State.Records
    ( Change (..)
    , decodeFoldRedeemer
    , decodeGenesisRedeemer
    , decodeStateDatum
    , foldRedeemer
    , foldedRedeemer
    , genesisRedeemer
    , stateDatum
    )
import Singular.State.StateWorld (txInOf)

spec :: Spec
spec = do
    describe "the state datum" $ do
        it "is the root alone, a constructor of one field" $
            stateDatum root `shouldBe` PLC.Constr 0 [PLC.B root]

        it "is read back" $ do
            decodeStateDatum (stateDatum root) `shouldBe` Just root
            decodeStateDatum (PLC.Constr 1 [PLC.B root]) `shouldBe` Nothing
            decodeStateDatum (PLC.Constr 0 [PLC.I 3]) `shouldBe` Nothing

    describe "the actions of the state policy" $ do
        it "genesis carries the seed as an output reference" $
            genesisRedeemer (txInOf 'a' 3)
                `shouldBe` PLC.Constr 0 [PLC.Constr 0 [PLC.B (BS.replicate 32 0x61), PLC.I 3]]

        it
            "a mint that belongs to a fold is the second constructor, without fields"
            $ foldedRedeemer `shouldBe` PLC.Constr 1 []

        it "the seed of a genesis is read back" $ do
            decodeGenesisRedeemer (genesisRedeemer (txInOf 'a' 3))
                `shouldBe` Just (txInOf 'a' 3)
            decodeGenesisRedeemer foldedRedeemer `shouldBe` Nothing

    describe "the hash of the datum a holding starts with" $ do
        it "is the blake2b-256 hash of the serialised datum: an integer" $
            initialDatumHash (PLC.I 7)
                `shouldBe` datumHashOf
                    "873e4fe9e41e924911bba3ec53ff4782efc8c0f244fb75c879f8a4328d0142ca"

        it
            "is the blake2b-256 hash of the serialised datum: a short byte string"
            $ initialDatumHash (PLC.B (BS.pack [1, 2, 3, 4]))
                `shouldBe` datumHashOf
                    "556aae26af9d9bbf448ecb50230660f270ee2d16357b1dbcbe1c855abdd64787"

    describe "the spend of the state" $ do
        it
            "a fold carries the seed and its changes, each in the order of the validator's type"
            $ foldRedeemer (txInOf 'a' 3) [registration]
                `shouldBe` PLC.Constr
                    0
                    [ PLC.Constr 0 [PLC.B (BS.replicate 32 0x61), PLC.I 3]
                    , PLC.List
                        [ PLC.Constr
                            0
                            [ PLC.Constr 0 [PLC.B (BS.replicate 32 0x62), PLC.I 0]
                            , PLC.B "key"
                            , PLC.I 1
                            , PLC.I 5_000_000
                            , PLC.List
                                [ PLC.Constr 0 [PLC.I 2, PLC.B (BS.replicate 128 7)]
                                , PLC.Constr
                                    1
                                    [ PLC.I 0
                                    , PLC.Constr 0 [PLC.I 9, PLC.B "", PLC.B (BS.replicate 32 5)]
                                    ]
                                , PLC.Constr
                                    2
                                    [PLC.I 1, PLC.B (BS.replicate 32 3), PLC.B (BS.replicate 32 4)]
                                ]
                            ]
                        ]
                    ]

        it "is read back with every change as it was written" $
            decodeFoldRedeemer
                (foldRedeemer (txInOf 'a' 3) [registration, termination, registration])
                `shouldBe` Just (txInOf 'a' 3, [registration, termination, registration])

        it "is not read from the data of another action" $ do
            decodeFoldRedeemer foldedRedeemer `shouldBe` Nothing
            decodeFoldRedeemer (PLC.Constr 0 [PLC.I 1, PLC.List []])
                `shouldBe` Nothing
  where
    root = BS.replicate 32 9
    registration =
        Register
            { changeRequest = txInOf 'b' 0
            , changeKey = "key"
            , changeHolding = 1
            , changeDeposit = 5_000_000
            , changeProof =
                [ Branch 2 (BS.replicate 128 7)
                , Fork 0 (Neighbor 9 "" (BS.replicate 32 5))
                , Leaf 1 (BS.replicate 32 3) (BS.replicate 32 4)
                ]
            }
    termination = Terminate (txInOf 'c' 1) "gone" []
    datumHashOf hex = case B16.decode hex of
        Right bytes -> DatumHash (BuiltinByteString bytes)
        Left failure -> error failure
