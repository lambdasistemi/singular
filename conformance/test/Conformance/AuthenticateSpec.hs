{- |
Module      : Conformance.AuthenticateSpec
Description : Canonical-authentication decision tests (issue #69)

The rival fixtures below are the shapes the devnet rows meet: a
consistent rival under the same policy at the same address (CA02),
and a forged ada-only output at the canonical address (CA05). The
weak authenticator's designed acceptance of the rival is itself
asserted: it is the CA03 control, and a control that could not
accept would prove nothing.
-}
module Conformance.AuthenticateSpec (spec) where

import Data.Map.Strict qualified as Map
import Test.Hspec (
    Spec,
    describe,
    it,
    shouldBe,
 )

import Conformance.Authenticate (
    AuthDecision (..),
    AuthReject (..),
    authenticate,
    authenticateWeak,
 )

spec :: Spec
spec = describe "Authenticate" $ do
    let policy = "policy-id-bytes"
        derived = "derived-name-bytes"
        canonical =
            Map.singleton policy (Map.singleton derived 1)
        rival =
            Map.singleton policy (Map.singleton "rival-seed-name" 1)
        forged = Map.empty

    it "accepts the canonical registry: policy, derived name, quantity one" $
        authenticate policy derived canonical `shouldBe` AuthAccept

    it "rejects a rival on the derived name, policy present" $
        authenticate policy derived rival
            `shouldBe` AuthReject NameMismatch

    it "rejects a forged output: no asset under the canonical policy" $
        authenticate policy derived forged
            `shouldBe` AuthReject PolicyAbsent

    it "rejects a wrong quantity on the derived name" $ do
        let two = Map.singleton policy (Map.singleton derived 2)
        authenticate policy derived two
            `shouldBe` AuthReject (QuantityNotOne 2)

    it "the weak control accepts the rival: policy+address cannot exclude it" $
        authenticateWeak policy rival `shouldBe` AuthAccept

    it "the weak control still rejects the forged output" $
        authenticateWeak policy forged `shouldBe` AuthReject PolicyAbsent

    it "weak and strong agree on the canonical registry" $ do
        authenticate policy derived canonical `shouldBe` AuthAccept
        authenticateWeak policy canonical `shouldBe` AuthAccept
