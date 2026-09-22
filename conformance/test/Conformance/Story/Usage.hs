-- | The live chapters render their submitted model edge requests.
module Conformance.Story.Usage (spec) where

import Data.List (isInfixOf)
import Test.Hspec (Spec, it, shouldSatisfy)
import Conformance.Edge.Register qualified as Register
import Conformance.Edge.Retire qualified as Retire
import Conformance.Story.Live qualified as Live

spec :: Spec
spec = do
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
