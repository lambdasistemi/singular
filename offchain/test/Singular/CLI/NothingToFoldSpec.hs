{- |
Module      : Singular.CLI.NothingToFoldSpec
Description : An automatic fold that finds nothing says it may be early and how to go on
License     : Apache-2.0

Koios lists a newly minted approval only after its asset cache refreshes,
about every two minutes, so an automatic fold run just after a booking can
find nothing although the request is on the chain. The printed refusal must
not read as a settled empty answer: it says that nothing is listed yet, why,
and the two ways on, waiting or naming the request with @--pending@.
-}
module Singular.CLI.NothingToFoldSpec (spec) where

import Data.List (isInfixOf, isPrefixOf)
import Test.Hspec

import Singular.CLI.Steps (renderRefusal)
import Singular.State.Refusal (Refusal (NothingToFold))

spec :: Spec
spec = describe "the refusal of an automatic fold that finds nothing" $ do
    let sentence = renderRefusal NothingToFold
    it "keeps the sentence it has always started with" $
        sentence `shouldSatisfy` ("there is nothing to fold" `isPrefixOf`)
    it "says nothing is listed yet, not that nothing is pending" $
        sentence `shouldSatisfy` ("nothing to fold yet" `isInfixOf`)
    it "names the Koios listing delay" $
        sentence
            `shouldSatisfy` ("up to about two minutes after it is booked" `isInfixOf`)
    it "names the way to fold the request at once" $
        sentence `shouldSatisfy` ("--pending" `isInfixOf`)
