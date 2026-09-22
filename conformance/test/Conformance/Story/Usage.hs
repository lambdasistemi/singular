-- | An executed recipe for adding a clause: bind, quote, declare cases,
-- record the gap. Collections and edits are programs; semantics live in Run.
module Conformance.Story.Usage (spec, story) where

import Control.Monad.Operational (Program)
import Data.List (isInfixOf)
import Test.Hspec (Spec, it, shouldBe, shouldSatisfy)
import Conformance.Story
import Conformance.Support.RegistrationReport (insertActiveRow)
import Conformance.Edge.Register qualified as Register
import Conformance.Edge.Retire qualified as Retire
import Conformance.Story.Live qualified as Live

story :: Program StoryI ()
story = theorem insertActiveRow $ do
    clause
        "The open registry application takes no parameters"
        do
            conjunct "openPolicyParameters = []"
        do
            acceptsBecause
                "A registration report is accepted when it explicitly records zero application parameters"
                "The open application takes no parameters, so its report may explicitly record a count of zero." $
                    openParameters 0
    unexercised
        "Rejecting an open application that unexpectedly requires parameters"
        "This example does not check a compiled application that unexpectedly gains a parameter"

spec :: Spec
spec = do
    runStory story
    it "Keeps internal reference numbers out of the example story" $
        filter nameViolation (groupNames story) `shouldBe` []
    it "The registration chapter describes redirected delivery beside its untampered control" $ do
        let rendered = Live.renderLive (Register.story (Live.Context "registry" "recipient"))
        rendered `shouldSatisfy` isInfixOf "redirect delivery"
        rendered `shouldSatisfy` isInfixOf "untampered control"
        rendered `shouldSatisfy` (not . isInfixOf "batch")
    it "The retirement chapter describes registration and retirement as model edge requests" $ do
        let rendered = Live.renderLive (Retire.story
                (Live.Context "retirement" "holder") (Live.Context "comparison" "holder"))
        rendered `shouldSatisfy` isInfixOf "Submit **insertActive**"
        rendered `shouldSatisfy` isInfixOf "Submit **updateTerminal**"
        rendered `shouldSatisfy` isInfixOf "Submit **insertAbsent**"
