{-# LANGUAGE GADTs #-}

-- | Exercise the reusable language with actions unrelated to Cardano.
module Conformance.Support.Specification (spec) where

import Control.Monad.Operational (Program, ProgramViewT (Return, (:>>=)), view)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Control.Monad (forM_)
import Data.List (isInfixOf)
import Conformance.Story.Live qualified as Live
import Conformance.Story.Binding (mkBoundObligation)
import Conformance.Story.Specification
    ( Clause (..)
    , LeanCheck
    , Step (..)
    , Story
    , Theorem
    , action
    , bindTheorem
    , bindCheck
    , checkAction
    , clause
    , clauses
    , theorem
    )

data Arithmetic
data Calculate obs where
    Increment :: Int -> Calculate Int
    AssertEqual :: Int -> Int -> Calculate ()

arithmeticCheck :: Int -> LeanCheck Calculate Arithmetic Int
arithmeticCheck expected = bindCheck arithmetic (action . AssertEqual expected)

arithmetic :: Theorem Arithmetic
arithmetic = bindTheorem (mkBoundObligation "example.arithmetic" "example-digest" "example-revision")

spec :: Spec
spec = describe "Appendix — reusable theorem and clause execution" $ do
    it "Names both finite alterations of the retraction window" $ do
        let names = map Live.tamperName [minBound .. maxBound]
        filter (`elem` ["before-phase-2", "after-phase-2"]) names
            `shouldBe` ["before-phase-2", "after-phase-2"]
    forM_ [minBound .. maxBound :: Live.Tamper] $ \alteration ->
        it ("validates and renders the complete instruction sequence for " <> Live.tamperName alteration) $ do
            let program = do
                    step <- Live.tamperExit alteration Live.Retract "registry"
                        (Live.EdgeRequest Live.InsertActive "request" "owner")
                    observation <- Live.observe step
                    _ <- Live.compareWithModel step observation
                    pure ()
                rendered = Live.renderLive program
            Live.validateLive program `shouldBe` Right ()
            rendered `shouldSatisfy` isInfixOf "Retract"
            rendered `shouldSatisfy` isInfixOf "Observe"
            rendered `shouldSatisfy` isInfixOf "Compare"
    it "Checks each clause and passes its observed result to the next action" $
        execute (theorem arithmetic $ do
            first <- clause "One becomes two" (arithmeticCheck 2) (action (Increment 1))
            clause "That result becomes three" (arithmeticCheck 3) (action (Increment first)))
            `shouldBe` Right (3, ["theorem", "action 1", "check 2", "action 2", "check 3"])
    it "Stops at a failed clause before the next action can run" $
        execute (theorem arithmetic $ do
            first <- clause "A deliberately wrong expectation" (arithmeticCheck 9) (action (Increment 1))
            clause "This action must not run" (arithmeticCheck 3) (action (Increment first)))
            `shouldBe` Left "expected 9, observed 2"

execute :: Story Calculate res -> Either String (res, [String])
execute program = case view program of
    Return result -> Right (result, [])
    Action (Increment number) :>>= next -> do
        (result, trace) <- execute (next (number + 1))
        pure (result, ("action " <> show number) : trace)
    Action (AssertEqual expected observation) :>>= next ->
        if observation /= expected
            then Left ("expected " <> show expected <> ", observed " <> show observation)
            else do
                (result, trace) <- execute (next ())
                pure (result, ("check " <> show observation) : trace)
    Theorem _ body :>>= next -> do
        (observation, trace) <- executeClauses (clauses body)
        (result, following) <- execute (next observation)
        pure (result, "theorem" : trace <> following)

executeClauses :: Program (Clause thm Calculate) res -> Either String (res, [String])
executeClauses program = case view program of
    Return result -> Right (result, [])
    Clause _ check body :>>= next -> do
        (observation, trace) <- execute body
        ((), checked) <- execute (checkAction check observation)
        (result, following) <- executeClauses (next observation)
        pure (result, trace <> checked <> following)
