-- | An executed recipe for adding a clause: bind, quote, declare cases,
-- record the gap. Collections and edits are programs; semantics live in Run.
module Conformance.Story.Usage (spec, story) where

import Control.Monad.Operational (Program)
import Test.Hspec (Spec, it, shouldBe)
import Conformance.Story
import Conformance.Edge.Register (insertActiveRow)

story :: Program StoryI ()
story = theorem insertActiveRow $ do
    clause
        "the open application declares no parameter"
        do
            conjunct "openPolicyParameters = []"
        do
            acceptsBecause
                "an explicit zero parameter is accepted"
                "zero is what parameterless means on the wire; stating it must preserve the complete observation" $
                    openParameters 0
    unexercised
        "the parameterized-application refusal"
        "a blueprint that grew a parameter would need a case refusing a nonzero count"

spec :: Spec
spec = do
    runStory story
    it "names the recipe without a row identifier or ticket number" $
        filter nameViolation (groupNames story) `shouldBe` []
