{- |
Module      : Conformance.Support.Authenticate
Description : Canonical-authentication decision tests (issue #69)

The rival fixtures below are the shapes the devnet rows meet: a
consistent rival under the same policy at the same address (CA02),
and a forged ada-only output at the canonical address (CA05). The
weak authenticator's designed acceptance of the rival is itself
asserted: it is the CA03 control, and a control that could not
accept would prove nothing.
-}
module Conformance.Support.Authenticate (spec) where

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
spec = describe "Appendix: recognising the intended registry" $ do
    let policy = "policy-id-bytes"
        derived = "derived-name-bytes"
        canonical =
            Map.singleton policy (Map.singleton derived 1)
        rival =
            Map.singleton policy (Map.singleton "rival-seed-name" 1)
        forged = Map.empty

    it "Recognises the registry when its token has the expected policy, calculated name and quantity one" $
        authenticate policy derived canonical `shouldBe` AuthAccept

    it "Rejects a different registry token even when it uses the expected policy" $
        authenticate policy derived rival
            `shouldBe` AuthReject NameMismatch

    it "Rejects an output with no token under the expected policy" $
        authenticate policy derived forged
            `shouldBe` AuthReject PolicyAbsent

    it "Rejects an output holding two registry tokens instead of one" $ do
        let two = Map.singleton policy (Map.singleton derived 2)
        authenticate policy derived two
            `shouldBe` AuthReject (QuantityNotOne 2)

    it "Shows that checking only the policy mistakenly accepts a different registry token" $
        authenticateWeak policy rival `shouldBe` AuthAccept

    it "Even the policy-only check rejects an output with no registry token" $
        authenticateWeak policy forged `shouldBe` AuthReject PolicyAbsent

    it "Both checks recognise the intended registry token" $ do
        authenticate policy derived canonical `shouldBe` AuthAccept
        authenticateWeak policy canonical `shouldBe` AuthAccept
