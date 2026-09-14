module Singular.Registry.LifecycleSpec (spec) where

import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Data.Either (isLeft)
import Singular.Registry.Lifecycle (checkExecutionLimit)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = describe "live aggregate transaction execution limit" $ do
    it "accepts the exact boundary across multiple purposes" $
        checkExecutionLimit (ExUnits 17500000 10000000000)
            [ExUnits 10000000 6000000000, ExUnits 7500000 4000000000]
            `shouldBe` Right (ExUnits 17500000 10000000000)
    it "refuses two individually legal retirement purposes whose sum exceeds memory" $
        checkExecutionLimit (ExUnits 17500000 10000000000)
            [ExUnits 14000000 1000000000, ExUnits 14000000 1000000000]
            `shouldSatisfy` isLeft
    it "refuses excess steps even when memory fits" $
        checkExecutionLimit (ExUnits 17500000 10000000000)
            [ExUnits 1000 6000000000, ExUnits 1000 4000000001]
            `shouldSatisfy` isLeft
    it "reports the measured requirement and the live limit" $
        checkExecutionLimit (ExUnits 10 20) [ExUnits 11 5]
            `shouldBe` Left "lifecycle execution limit: requires memory=11, steps=5; live transaction limit memory=10, steps=20"
