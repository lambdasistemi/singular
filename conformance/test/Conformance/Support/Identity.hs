-- | The translation boundary must preserve identities rather than manufacture
-- agreement with the model. These are interpreter checks, not registry claims.
module Conformance.Support.Identity (spec) where

import Data.Either (isLeft)
import Data.List (nub)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Conformance.Story.Identity qualified as Identity

spec :: Spec
spec = describe "Identity translation between Cardano and the model" $ do
    it "Keeps an identity stable when another action uses it again" $ do
        let (first, initial) = Identity.identify ("recipient" :: String) Identity.empty
            (_, extended) = Identity.identify "another wallet" initial
            (again, final) = Identity.identify "recipient" extended
        again `shouldBe` first
        Identity.bindings final `shouldBe` Identity.bindings extended
    it "Keeps distinct identities distinct, even when their names share a prefix" $ do
        let names = ["wallet-" <> show n | n <- [1 .. 32 :: Int]]
            (allocated, final) = foldl
                (\(ids, state) name -> let (identifier, next) = Identity.identify name state
                                      in (ids <> [identifier], next))
                ([], Identity.empty) names
        length (nub allocated) `shouldBe` length names
        traverse (`Identity.observe` final) names `shouldBe` Right allocated
    it "Refuses an unknown observed identity instead of assigning the expected one" $ do
        let (recipient, known) = Identity.identify ("requested wallet" :: String) Identity.empty
        Identity.observe "unexpected wallet" known `shouldSatisfy` isLeft
        Identity.observe "requested wallet" known `shouldBe` Right recipient
