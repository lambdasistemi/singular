{-# LANGUAGE NumericUnderscores #-}

{- | Units stated without local evaluation fit the block that must include
them.

The limits are the development node's: a transaction may state 140M memory
and 10G steps, a block 62M memory and 20G steps. A fold with six purposes
stating 14M memory each (84M) passes the transaction check and waits in the
mempool for ever, because no block can hold it.
-}
module Singular.Registry.TxBuilder.SkipEvalUnitsSpec (spec) where

import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

import Singular.Registry.TxBuilder.ConnectedFold
    ( generousUnits
    , skipEvalUnits
    )

txLimit, blockLimit :: ExUnits
txLimit = ExUnits 140_000_000 10_000_000_000
blockLimit = ExUnits 62_000_000 20_000_000_000

total :: Int -> ExUnits
total n =
    let ExUnits m s = skipEvalUnits txLimit blockLimit n
    in  ExUnits (m * fromIntegral n) (s * fromIntegral n)

fits :: ExUnits -> ExUnits -> Bool
fits (ExUnits m s) (ExUnits lm ls) = m <= lm && s <= ls

spec :: Spec
spec = describe "Units stated without local evaluation" $ do
    it "state the generous units while their sum fits the block" $
        skipEvalUnits txLimit blockLimit 4 `shouldBe` generousUnits
    it "share the block among six purposes instead of stating 84M memory" $
        skipEvalUnits txLimit blockLimit 6
            `shouldBe` ExUnits 10_333_333 1_000_000_000
    it "keep every fold of one to twelve purposes within both limits" $
        mapM_
            ( \n -> do
                total n `shouldSatisfy` (`fits` blockLimit)
                total n `shouldSatisfy` (`fits` txLimit)
            )
            [1 .. 12]
