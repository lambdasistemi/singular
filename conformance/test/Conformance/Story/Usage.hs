{-# LANGUAGE GADTs #-}

-- | The live chapters render their submitted model edge requests.
module Conformance.Story.Usage (spec) where

import Control.Monad.Operational (ProgramViewT (Return, (:>>=)), view)
import Data.Either (isLeft)
import Data.List (isInfixOf, isPrefixOf, tails)
import Test.Hspec (Spec, it, shouldBe, shouldSatisfy)
import Conformance.Book (renderBook)
import Conformance.Edge.Register qualified as Register
import Conformance.Edge.Retire qualified as Retire
import Conformance.Edge.Sequence qualified as Sequence
import Conformance.Story.Live qualified as Live
import Conformance.Story.Specification qualified as Specification

spec :: Spec
spec = do
    it "The registration chapter pays its delivery elsewhere and one lovelace short beside its untampered control" $ do
        let rendered = Live.renderLive (Register.story (Live.Context "registry" "recipient"))
        rendered `shouldSatisfy` isInfixOf "payment it owes sent to another address"
        rendered `shouldSatisfy` isInfixOf "payment it owes one lovelace short"
        rendered `shouldSatisfy` isInfixOf "untampered is its control"
        rendered `shouldSatisfy` (not . isInfixOf "batch")
    it "The book names the extra required signer only where the registration story submits it" $ do
        let phrase = "required signer the model does not require"
            story = Live.renderLive (Register.story (Live.Context "registration" "recipient wallet"))
        occurrences phrase story `shouldSatisfy` (>= 1)
        occurrences phrase (renderBook [] []) `shouldBe` occurrences phrase story
    it "The retirement chapter describes registration and retirement as model edge requests" $ do
        let rendered = Live.renderLive (Retire.story
                (Live.Context "retirement" "holder") (Live.Context "comparison" "holder"))
        rendered `shouldSatisfy` isInfixOf "Submit **insertActive**"
        rendered `shouldSatisfy` isInfixOf "Submit **updateTerminal**"
        rendered `shouldSatisfy` isInfixOf "Submit **insertAbsent**"
    it "The retirement chapter pays a deletion's deposit back elsewhere and one lovelace short beside the untampered deletion" $ do
        let rendered = Live.renderLive (Retire.story
                (Live.Context "retirement" "holder") (Live.Context "comparison" "holder"))
        rendered `shouldSatisfy` isInfixOf "Submit **deleteActive** for **deleted** in **retirement** with the payment it owes one lovelace short"
        rendered `shouldSatisfy` isInfixOf "Submit **deleteActive** for **deleted** in **retirement** with the payment it owes sent to another address"
        rendered `shouldSatisfy` isInfixOf "Submit **deleteActive** for **deleted** in **retirement**, using the holder."
    it "accepts the complete unnamed sequence before submitting" $ do
        let original :: Live.Story String String String String String ()
            original = Sequence.story (Live.Context "sequence" "holder")
        Live.validateLive original `shouldSatisfy` (== Right ())
    it "accepts both complete chapters before submitting" $ do
        Live.validateLive (Register.story (Live.Context "registry" "recipient"))
            `shouldSatisfy` (== Right ())
        Live.validateLive (Retire.story
            (Live.Context "retirement" "holder") (Live.Context "comparison" "holder"))
            `shouldSatisfy` (== Right ())
    it "refuses the real unnamed sequence with one Compare removed before submitting" $ do
        let original :: Live.Story String String String String String ()
            original = Sequence.story (Live.Context "sequence" "holder")
        Live.validateLive (dropFirstCompare original) `shouldSatisfy` isLeft

occurrences :: String -> String -> Int
occurrences needle = length . filter (needle `isPrefixOf`) . tails

-- | Mutation of the actual sequence program: remove exactly its first Compare.
dropFirstCompare :: Live.Story String String String String String ()
    -> Live.Story String String String String String ()
dropFirstCompare = go False
  where
    go :: Bool -> Live.Story String String String String String a
        -> Live.Story String String String String String a
    go removed program = case view program of
        Return result -> pure result
        Specification.Action instruction :>>= next -> case instruction of
            Live.Compare _ _ | not removed -> go True (next "dropped")
            _ -> Specification.action instruction >>= go removed . next
        Specification.Theorem _ _ :>>= _ -> error "unnamed sequence unexpectedly gained a theorem wrapper"
