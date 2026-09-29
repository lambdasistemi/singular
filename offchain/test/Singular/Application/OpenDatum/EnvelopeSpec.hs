{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.EnvelopeSpec
Description : The open-datum envelope's codec, hash and external JSON
License     : Apache-2.0

The golden vector here is the one @onchain/validators/open_datum.tests.ak@
asserts for the same envelope: the two codecs agree on the CBOR and on
its BLAKE2b-256, byte for byte.
-}
module Singular.Application.OpenDatum.EnvelopeSpec (spec) where

import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Either (isLeft)
import Test.Hspec
import Test.QuickCheck

import PlutusCore.Data qualified as PLC

import Singular.Application.OpenDatum.Envelope

spec :: Spec
spec = describe "the open-datum envelope" $ do
    golden
    codec
    json

-- ---------------------------------------------------------
-- Golden vector shared with the Aiken rows
-- ---------------------------------------------------------

hex :: ByteString -> ByteString
hex = B16.encode

unhex :: ByteString -> ByteString
unhex h = either error id (B16.decode h)

-- | The envelope the Aiken rows call @envelopeA@.
envelopeA :: Envelope
envelopeA =
    Envelope
        { envControl =
            Control
                { ctlVersion = envelopeVersion
                , ctlRegistry =
                    StateAsset
                        (unhex "1f06886c357b5b31b43baf142cb19d0c8e5259110de1905669426428")
                        "cage-token"
                , ctlActivePolicy = BS.replicate 28 0xaa
                , ctlKey = "keyA"
                , ctlController = BS.replicate 28 0xd1
                , ctlDeposit = 2_000_000
                }
        , envPayload = PLC.B "alice"
        }

golden :: Spec
golden = describe "golden vector" $ do
    it "serialises envelopeA to the CBOR the Aiken rows use" $
        hex (envelopeCbor envelopeA) `shouldBe` goldenCbor
    it "hashes envelopeA to the BLAKE2b-256 the Aiken rows assert" $
        hex (envelopeHash envelopeA) `shouldBe` goldenHash

goldenCbor :: ByteString
goldenCbor =
    "d8799fd8799f01d8799f581c1f06886c357b5b31b43baf142cb19d0c8e5259110de19056694264284a636167652d746f6b656eff581caaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa446b657941581cd1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d11a001e8480ff45616c696365ff"

goldenHash :: ByteString
goldenHash =
    "98e07c4c9ae428381b4eb4e8f0b76376fe3a83291b71c6714e66cf0c9dd63af0"

-- ---------------------------------------------------------
-- Plutus data codec
-- ---------------------------------------------------------

-- | Any Plutus datum, every constructor, nested.
genData :: Gen PLC.Data
genData = sized go
  where
    go 0 = leaf
    go n =
        frequency
            [ (2, leaf)
            , (1, PLC.Constr <$> choose (0, 300) <*> smallList (go (n `div` 3)))
            , (1, PLC.List <$> smallList (go (n `div` 3)))
            ,
                ( 1
                , PLC.Map
                    <$> smallList ((,) <$> go (n `div` 4) <*> go (n `div` 4))
                )
            ]
    leaf =
        oneof
            [ PLC.I <$> arbitrary
            , PLC.I <$> choose (-(2 ^ (80 :: Int)), 2 ^ (80 :: Int))
            , PLC.B . BS.pack <$> smallList arbitrary
            ]
    smallList g = do
        k <- choose (0, 4)
        vectorOf k g

genEnvelope :: Gen Envelope
genEnvelope = Envelope envControl' <$> genData
  where
    envControl' = envControl envelopeA

codec :: Spec
codec = describe "Plutus data" $ do
    it "round-trips an envelope with any payload" $
        forAll genEnvelope $ \e ->
            envelopeFromData (envelopeToData e) === Right e
    it "admits every payload shape, the payload never being read" $
        forAll genData $ \p ->
            let e = envelopeA{envPayload = p}
            in  envelopeFromData (envelopeToData e) === Right e
    it "refuses a control of the wrong arity" $
        envelopeFromData (PLC.Constr 0 [PLC.Constr 0 [PLC.I 1], PLC.I 0])
            `shouldSatisfy` isLeft
    it "refuses a control whose registry is not a pair of byte strings" $
        let bad = case controlToData (envControl envelopeA) of
                PLC.Constr 0 (v : _ : rest) -> PLC.Constr 0 (v : PLC.B "x" : rest)
                other -> other
        in  envelopeFromData (PLC.Constr 0 [bad, PLC.I 0]) `shouldSatisfy` isLeft
    it "refuses an envelope under another constructor" $
        envelopeFromData
            (PLC.Constr 1 [controlToData (envControl envelopeA), PLC.I 0])
            `shouldSatisfy` isLeft
    it "hashes two payloads apart" $
        envelopeHash envelopeA
            `shouldNotBe` envelopeHash envelopeA{envPayload = PLC.B "bob"}

-- ---------------------------------------------------------
-- External JSON
-- ---------------------------------------------------------

json :: Spec
json = describe "detailed-schema JSON" $ do
    it "round-trips any datum" $
        forAll genData $
            \d -> dataFromJson (dataToJson d) === Right d
    it "round-trips any datum through its encoded text" $
        forAll genData $ \d ->
            (Aeson.eitherDecode (Aeson.encode (dataToJson d)) >>= dataFromJson)
                === Right d
    it "reads an envelope a caller wrote by hand" $
        envelopeFromJson (envelopeToJson envelopeA) `shouldBe` Right envelopeA
    it "refuses an object with keys of two shapes" $
        dataFromJson
            (object ["int" .= (1 :: Int), "bytes" .= ("00" :: String)])
            `shouldSatisfy` isLeft
    it "refuses bytes that are not hex" $
        dataFromJson (object ["bytes" .= ("zz" :: String)])
            `shouldSatisfy` isLeft
    it "refuses an integer written as a fraction" $
        dataFromJson (object ["int" .= (1.5 :: Double)])
            `shouldSatisfy` isLeft
    it "refuses a negative constructor index" $
        dataFromJson
            (object ["constructor" .= (-1 :: Int), "fields" .= ([] :: [Value])])
            `shouldSatisfy` isLeft
    it "refuses a map entry with extra keys" $
        dataFromJson
            ( object
                [ "map"
                    .= [ object
                            [ "k" .= object ["int" .= (1 :: Int)]
                            , "v" .= object ["int" .= (2 :: Int)]
                            , "w" .= object ["int" .= (3 :: Int)]
                            ]
                       ]
                ]
            )
            `shouldSatisfy` isLeft
