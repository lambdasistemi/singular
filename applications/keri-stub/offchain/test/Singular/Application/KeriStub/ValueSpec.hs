{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.KeriStub.ValueSpec
Description : The stub value names itself and pins its script's hash
License     : Apache-2.0

Every expected value is derived at run time from the script's bytes
through the ledger's own hash, never typed.
-}
module Singular.Application.KeriStub.ValueSpec (spec) where

import Data.ByteString.Short qualified as SBS
import Data.Maybe (isJust)
import Test.Hspec

import Singular.Application.KeriStub.Script
    ( keriStubPolicy
    , keriStubScriptBytes
    )
import Singular.Application.KeriStub.Value (keriStubApplication)
import Singular.Registry.Application
    ( Application (..)
    , ApplicationPin (..)
    )
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , scriptHashBytes
    )

spec :: Spec
spec = describe "the keri-stub value" $ do
    it "is named keri-stub and folded by keri-stub" $ do
        appName keriStubApplication `shouldBe` Just "keri-stub"
        appExecutable keriStubApplication `shouldBe` Just "keri-stub"
    it "carries a decoder and holding rules" $ do
        appDecoder keriStubApplication `shouldSatisfy` isJust
        appHolding keriStubApplication `shouldSatisfy` isJust
    it "pins the hash of its own script bytes" $ do
        let expected =
                SBS.toShort
                    (scriptHashBytes (computeScriptHash keriStubScriptBytes))
        appPin keriStubApplication `shouldBe` PinByHash expected
        SBS.length expected `shouldBe` 28
    it "publishes the policy its hash names" $
        keriStubPolicy
            `shouldBe` scriptHashBytes (computeScriptHash keriStubScriptBytes)
