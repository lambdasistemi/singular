-- | Read the promises first; machinery checks are the appendix.
module Main (main) where

import Test.Hspec (Spec, describe, hspec)
import Conformance.Support.RegistrationReport qualified as InsertActive
import Conformance.Support.BatchReport qualified as KeyedMint
import Conformance.Story.BindingControl qualified as BindingControl
import Conformance.Story.Control qualified as Control
import Conformance.Story.Usage qualified as Usage
import Conformance.Support.Observation qualified as Observation
import Conformance.Support.Receipt qualified as Receipt
import Conformance.Support.Refusal qualified as Refusal
import Conformance.Support.Rows qualified as Rows
import Conformance.Support.Identity qualified as Identity

main :: IO ()
main = hspec suite

suite :: Spec
suite = do
    describe "Appendix — validating example reports" $ do
        describe "Registering a key" InsertActive.spec
        describe "Allocating tokens across a batch of requests" KeyedMint.spec
    describe "Appendix — how we check the evidence" $ do
        Observation.spec
        Receipt.spec
        Refusal.spec
        Rows.spec
        Identity.spec
        Control.spec
        BindingControl.spec
        Usage.spec
