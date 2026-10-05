module Singular.Registry.LifecycleSpec (spec) where

import Cardano.Ledger.Api.Tx.Out (TxOut, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Inject (..))
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Data.Either (isLeft)
import Data.Text qualified as T
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger (Coin (..), ConwayEra)
import Singular.Registry.Lifecycle
    ( checkExecutionLimit
    , fundingView
    , lifecycleRequested
    )
import Singular.Registry.Node (funderAddr)
import Singular.Registry.Provider (ChainPoint (..), View (..))
import Singular.Registry.StubView (stubView)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = do
    lifecycleSelection
    executionLimit

lifecycleSelection :: Spec
lifecycleSelection = describe "lifecycle selection from the chain point" $ do
    let at magic = (viewPoint stubView){cpNetwork = magic}
    it "stays off on the factory devnet unless asked" $ do
        lifecycleRequested (at 42) [] `shouldBe` False
        lifecycleRequested (at 42) ["--lifecycle"] `shouldBe` True
    it "turns on for any other network, asked or not" $ do
        lifecycleRequested (at 1) [] `shouldBe` True
        lifecycleRequested (at 764824073) ["--lifecycle"] `shouldBe` True

executionLimit :: Spec
executionLimit = describe "live aggregate transaction execution limit" $ do
    it "accepts the exact boundary across multiple purposes" $
        checkExecutionLimit
            (ExUnits 17500000 10000000000)
            [ExUnits 10000000 6000000000, ExUnits 7500000 4000000000]
            `shouldBe` Right (ExUnits 17500000 10000000000)
    it
        "refuses two individually legal retirement purposes whose sum exceeds memory"
        $ checkExecutionLimit
            (ExUnits 17500000 10000000000)
            [ExUnits 14000000 1000000000, ExUnits 14000000 1000000000]
            `shouldSatisfy` isLeft
    it "refuses excess steps even when memory fits" $
        checkExecutionLimit
            (ExUnits 17500000 10000000000)
            [ExUnits 1000 6000000000, ExUnits 1000 4000000001]
            `shouldSatisfy` isLeft
    it "reports the measured requirement and the live limit" $
        checkExecutionLimit (ExUnits 10 20) [ExUnits 11 5]
            `shouldBe` Left
                "lifecycle execution limit: requires memory=11, steps=5; live transaction limit memory=10, steps=20"
    it
        "request funding excludes larger inputs reserved for later lifecycle steps"
        $ do
            reserved <-
                either fail pure (parseOutRef (T.pack (replicate 64 '0' <> "#0")))
            free <-
                either fail pure (parseOutRef (T.pack (replicate 64 '0' <> "#1")))
            let output :: Integer -> TxOut ConwayEra
                output amount = mkBasicTxOut funderAddr (inject (Coin amount))
                prov =
                    stubView
                        { viewUTxOsAt = \_ -> pure [(reserved, output 100000000), (free, output 5000000)]
                        }
            selected <- viewUTxOsAt (fundingView [reserved] prov) funderAddr
            map fst selected `shouldBe` [free]
