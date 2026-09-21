{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Conformance.Story.Control
Description : Controls protecting the correspondence between stories and execution
License     : Apache-2.0

The renderer must preserve the receipt edit actually executed, including
nested collections and full identities. Constructor samples come from the
compiler's datatype information; an unsupported argument fails compilation.
The real loader also exercises acceptance, refusal and exact receipt count.
-}
module Conformance.Story.Control (spec) where

import Control.Monad.Operational (Program)
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Conformance.Story.Discover (discoverPrograms)
import Data.Either (isLeft)
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn, shouldSatisfy)

import Conformance.Fixture.ActiveRegistration (activeAsset, completeReceipt, keyHex, loadTwoFixtures)
import Conformance.Story (
    EditI,
    foldEdit,
    refunds,
    noRefunds,
    lovelace,
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
spec = describe "Appendix: making sure the published story matches the test" $ do
    it "Describes delivering one token differently from delivering two tokens" $ do
        -- The subject ran: qty 2 is refused, qty 1 is accepted.
        executeEdit progTwo >>= (`shouldSatisfy` isLeft)
        executeEdit progOne `shouldReturn` Right 1
        -- Delivering different quantities must produce different descriptions.
        (renderEdit progTwo /= renderEdit progOne) `shouldBe` True

    it "Does not give the same description to different reports in the generated examples" $ do
        let observations = Map.fromListWith (<>)
                [(renderEdit p, [(label, foldEdit p completeReceipt)]) | (label, p) <- discovered]
            collisions = [(rendered, nub (map fst entries))
                | (rendered, entries) <- Map.toList observations
                , length (nub (map snd entries)) > 1]
        null discovered `shouldBe` False
        putStrLn ("Rendered constructor census: " <> show (length (nub (map fst discovered))) <> " edit constructors, " <> show (length discovered) <> " programs")
        executeEdit (refunds noRefunds) `shouldReturn` Right 1
        executeEdit (refunds (lovelace 1)) >>= (`shouldSatisfy` isLeft)
        collisions `shouldBe` []

    it "Requires exactly one valid report when a story expects acceptance" $ do
        -- The subject ran: the fixture dir genuinely holds two receipts.
        loadTwoFixtures `shouldReturn` Right 2
        -- Two reports do not satisfy a story expecting exactly one.
        acceptsMeaning (Right 2) `shouldBe` False
        acceptsMeaning (Right 1) `shouldBe` True
        acceptsMeaning (Left "boom") `shouldBe` False

    it "Requires every rejection story to explain why the report is rejected" $ do
        -- A rejection needs an explanation; an acceptance does not.
        validateCase (accepts "one active token" unchanged) `shouldBe` True
        validateCase (rejects "two tokens" "a per-kind total cannot see it" unchanged)
            `shouldBe` True
        validateCase (rejects "two tokens" "" unchanged) `shouldBe` False

    it "Rejects token lists that bypass the story language" $ do
        -- Token collections must use the same language as the rest of the story.
        validateCollection (activeToken keyHex 1) `shouldBe` True
        validateCollection (literalControl [activeAsset]) `shouldBe` False
  where
    progTwo = deliver $ activeToken keyHex 2
    progOne = deliver $ activeToken keyHex 1

-- Generated from the datatype, including nested instruction sets.
discovered :: [(String, Program EditI ())]
discovered = $(discoverPrograms ''EditI)
