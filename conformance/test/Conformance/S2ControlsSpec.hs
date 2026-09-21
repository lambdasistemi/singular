{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Conformance.S2ControlsSpec
Description : Slice S2 RED controls the operational DSL must satisfy
License     : Apache-2.0

Four legs, each executing its subject. They FAIL against the weak
stub in 'Conformance.Operational' for the named reason and must go
green under checkpoint s2-dsl with no test change:

* LEG-1 rendered story ignores the program it ran;
* LEG-2 'acceptsMeaning' admits a two-receipt load;
* LEG-3 a 'rejects' with an empty reason is accepted;
* LEG-4 a literal-built collection is accepted.
-}
module Conformance.S2ControlsSpec (spec) where

import Data.Either (isLeft)
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn, shouldSatisfy)

import Conformance.EdgeFixtures (activeAsset, keyHex, loadTwoFixtures)
import Conformance.Operational (
    accepts,
    acceptsMeaning,
    activeToken,
    deliver,
    executeEdit,
    literalControl,
    rejects,
    renderEdit,
    unchanged,
    validateCase,
    validateCollection,
 )

spec :: Spec
spec = describe "S2 operational controls" $ do
    it "LEG-1 the rendered edit follows the program that ran" $ do
        -- The subject ran: qty 2 is refused, qty 1 is accepted.
        executeEdit progTwo >>= (`shouldSatisfy` isLeft)
        executeEdit progOne `shouldReturn` Right 1
        -- The failure: rendering ignores the program, so two
        -- different programs render identically.
        (renderEdit progTwo /= renderEdit progOne) `shouldBe` True

    it "LEG-2 accepts means exactly one receipt" $ do
        -- The subject ran: the fixture dir genuinely holds two receipts.
        loadTwoFixtures `shouldReturn` Right 2
        -- The failure: the weak meaning admits any Right.
        acceptsMeaning (Right 2) `shouldBe` False
        acceptsMeaning (Right 1) `shouldBe` True
        acceptsMeaning (Left "boom") `shouldBe` False

    it "LEG-3 a rejects without a reason is refused" $ do
        -- Sanity: reasoned cases and accepts validate in both worlds.
        validateCase (accepts "one active token" unchanged) `shouldBe` True
        validateCase (rejects "two tokens" "a per-kind total cannot see it" unchanged)
            `shouldBe` True
        -- The failure: the stub accepts an empty reason.
        validateCase (rejects "two tokens" "" unchanged) `shouldBe` False

    it "LEG-4 a literal-built collection is refused" $ do
        -- Sanity: program-built collections validate in both worlds.
        validateCollection (activeToken keyHex 1) `shouldBe` True
        -- The failure: the stub accepts the literal control.
        validateCollection (literalControl [activeAsset]) `shouldBe` False
  where
    progTwo = deliver $ activeToken keyHex 2
    progOne = deliver $ activeToken keyHex 1
