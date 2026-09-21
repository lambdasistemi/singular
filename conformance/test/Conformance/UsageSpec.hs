{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Conformance.UsageSpec
Description : Recipe for adding the next theorem clause, executed
License     : Apache-2.0

How to add the next theorem clause and its cases, as a runnable
recipe rather than prose alone (so a stale recipe goes red):

1. Bind the obligation from 'Conformance.StoryBindings'. Never retype
   a digest: one copy exists, reconciled against the manifest on every
   run.
2. Quote the clause's conjunct anchors verbatim from
   @lean/Singular/Statements.lean@ and extend the inventory beside the
   obligation. Every anchor must appear in the source or the suite
   fails.
3. Write the cases with 'accepts'/'acceptsBecause'/'rejects' over real
   'loadOne' actions from 'Conformance.EdgeFixtures'. 'rejects' takes
   its @because@ as a required argument; say which condition changes
   and why it distinguishes the defect.
4. Record what the slice leaves out with 'unexercised'. A theorem
   pointer alone earns no coverage.
5. Run the group with 'runTheorem'. Keep the row compatibility beside
   the cases ('compatRow') and keep row IDs and ticket numbers out of
   every clause and example name.

The group below mirrors the open-params clause on purpose: its point
is the recipe path (bind, quote, run, record), not new coverage, so
it reuses the clause's identity instead of inventing a parallel one.
-}
module Conformance.UsageSpec (spec, usageGroup) where

import Data.Aeson (Value (..))
import Test.Hspec (Spec, it, shouldBe)

import Conformance.EdgeFixtures (edgeSet, loadOne)
import Conformance.Story (
    TheoremGroup,
    acceptsBecause,
    compatRow,
    groupNames,
    mkClause,
    nameViolation,
    receiptClause,
    runTheorem,
    theorem,
    unexercised,
 )
import Conformance.StoryBindings (insertActiveRow)

-- | The recipe, runnable: the open-params clause revisited step by
-- step. The accepts case states explicitly what the fixtures carry
-- implicitly, so the recipe path itself is what goes green.
usageGroup :: TheoremGroup
usageGroup =
    theorem
        insertActiveRow
        [ receiptClause
            ( mkClause
                "the open application declares no parameter"
                ["openPolicyParameters = []"]
            )
            [ acceptsBecause
                "an explicit zero parameter is accepted"
                (loadOne (edgeSet "openParameters" (Number 0)))
                "zero is what parameterless means on the wire; stating it outright must load exactly like the complete artifact"
            ]
            [ unexercised
                "the parameterized-application refusal"
                "a blueprint that grew a parameter would need a second case refusing a nonzero count"
            ]
            (compatRow "CG21")
        ]

spec :: Spec
spec = do
    runTheorem usageGroup
    it "names the recipe without a row ID or ticket number" $
        [n | n <- groupNames usageGroup, nameViolation n]
            `shouldBe` []
