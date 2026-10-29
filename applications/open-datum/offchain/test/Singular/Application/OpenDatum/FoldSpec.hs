{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Shared datum/value assertions retained after the old fold rules leave.
module Singular.Application.OpenDatum.FoldSpec (spec) where

import Data.ByteString qualified as BS
import Data.Maybe (isJust)
import PlutusCore.Data qualified as PLC
import Singular.Application.OpenDatum.Envelope
    ( Control (..)
    , Envelope (..)
    , StateAsset (..)
    , envelopeHash
    , envelopeToData
    , envelopeVersion
    )
import Singular.Application.OpenDatum.Value (openDatumApplication)
import Singular.Registry.Application
    ( Application (..)
    , datumFromJson
    , datumHash
    , datumToJson
    , neutralApplication
    )
import Test.Hspec
import Test.QuickCheck (Gen, chooseInteger, forAll, property, (===))

spec :: Spec
spec = neutralFold

envelopeWith :: PLC.Data -> Envelope
envelopeWith payload =
    Envelope
        { envControl =
            Control
                { ctlVersion = envelopeVersion
                , ctlRegistry = StateAsset (BS.replicate 28 0x11) "registry"
                , ctlActivePolicy = BS.replicate 28 0x22
                , ctlKey = "key"
                , ctlController = BS.replicate 28 0x33
                , ctlDeposit = 2_000_000
                }
        , envPayload = payload
        }

genPayload :: Gen PLC.Data
genPayload = PLC.I <$> chooseInteger (-1_000_000, 1_000_000)

neutralFold :: Spec
neutralFold = describe "the fold through the application value" $ do
    it "hashes a datum like the envelope hash it carries (open datum)" $
        property $
            forAll genPayload $ \p ->
                let e = envelopeWith p
                in  datumHash (envelopeToData e) === envelopeHash e
    it
        "decodes only through the value's decoder (open datum has one, neutral has none)"
        $ do
            appDecoder openDatumApplication `shouldSatisfy` isJust
            appDecoder neutralApplication `shouldBe` Nothing
            appHolding openDatumApplication `shouldSatisfy` isJust
            appHolding neutralApplication `shouldBe` Nothing
    it
        "round-trips any datum through detailed-schema JSON (generic, byte-identical to the envelope's)"
        $ property
        $ forAll genPayload
        $ \p ->
            datumFromJson (datumToJson p) === Right p
