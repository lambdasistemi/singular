module Naming.RecordValueSpec (spec) where

import Naming.Verify (singleNamingToken)
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec = describe "naming record value readback" $ do
    it "reads the sole representative" $
        singleNamingToken ["representative"] [("representative", "alice", 1)]
            `shouldBe` Right ("alice", 1)
    it "refuses an extra asset under a foreign policy by name" $
        singleNamingToken
            ["representative"]
            [("representative", "alice", 1), ("foreign", "junk", 1)]
            `shouldBe` Left "record-single-asset"
    it "refuses a second name under the representative policy" $
        singleNamingToken
            ["representative"]
            [("representative", "alice", 1), ("representative", "junk", 1)]
            `shouldBe` Left "record-single-asset"
    it "refuses the representative name under a foreign policy" $
        singleNamingToken ["representative"] [("foreign", "alice", 1)]
            `shouldBe` Left "record-single-asset"
    it "refuses a missing representative" $
        singleNamingToken ["representative"] []
            `shouldBe` Left "record-single-asset"
