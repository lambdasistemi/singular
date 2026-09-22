-- | Read the promises first; machinery checks are the appendix.
module Main (main) where

import System.Environment (lookupEnv)
import Test.Hspec (Spec, describe, hspec)
import Conformance.Story.Usage qualified as Usage
import Conformance.Support.Receipt qualified as Receipt
import Conformance.Support.Refusal qualified as Refusal
import Conformance.Support.Rows qualified as Rows
import Conformance.Support.Fixture qualified as Fixture
import Conformance.Support.FixtureChild (childModeVariable, holdScopedDirectories)
import Conformance.Support.Identity qualified as Identity
import Conformance.Support.RegistrationComparison qualified as RegistrationComparison
import Conformance.Support.Specification qualified as Specification

-- | Normally the suite. With the rendezvous variable set, the second process
-- the temporary-directory checks need: it claims directories through the same
-- fixture boundary and holds them until released.
main :: IO ()
main = do
    rendezvous <- lookupEnv childModeVariable
    case rendezvous of
        Just dir -> holdScopedDirectories 256 dir
        Nothing -> hspec suite

suite :: Spec
suite = do
    describe "Appendix — how we check the evidence" $ do
        Receipt.spec
        Refusal.spec
        Rows.spec
        Identity.spec
        Fixture.spec
        RegistrationComparison.spec
        Specification.spec
        Usage.spec
