{- | Unit controls for the factored cleanup predicate.

Each case feeds synthetic inputs directly to `cleanupFailure`, so every
branch is observed with no processes involved: clean passes, leftover
tree fails, observed pids fail naming them. The devnet control run
(synthetic marker process plus a story) then proves the wired path
reaches this predicate with a real observation.
-}
module Main (main) where

import Cleanup (cleanupFailure)
import Data.List (isInfixOf)
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, testCase)

main :: IO ()
main = defaultMain $ testGroup "cleanup failure predicate"
    [ testCase "clean tree and no observed pids passes" $
        assertBool "expected Nothing" (cleanupFailure False [] == Nothing)
    , testCase "leftover tree fails" $
        case cleanupFailure True [] of
            Nothing -> assertBool "expected failure" False
            Just _ -> return ()
    , testCase "observed pids fail naming them" $
        case cleanupFailure False ["12345"] of
            Nothing -> assertBool "expected failure" False
            Just reason -> assertBool "names the pid" ("12345" `isInfixOf` reason)
    , testCase "leftover tree plus pids reports the tree first" $
        case cleanupFailure True ["12345"] of
            Nothing -> assertBool "expected failure" False
            Just reason -> assertBool "tree reason takes priority" ("tree" `isInfixOf` reason)
    ]
