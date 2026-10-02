-- | Read the promises first; machinery checks are the appendix.
module Main (main) where

import Conformance.Story.Usage qualified as Usage
import Conformance.Support.Binding qualified as Binding
import Conformance.Support.CliAdmission qualified as CliAdmission
import Conformance.Support.CliAttach qualified as CliAttach
import Conformance.Support.CliControls qualified as CliControls
import Conformance.Support.CliProof qualified as CliProof
import Conformance.Support.DriverTransport qualified as DriverTransport
import Conformance.Support.EvidencePage qualified as EvidencePage
import Conformance.Support.Extent qualified as Extent
import Conformance.Support.Fixture qualified as Fixture
import Conformance.Support.FixtureChild
    ( childModeVariable
    , holdScopedDirectories
    )
import Conformance.Support.HeldView qualified as HeldView
import Conformance.Support.Identity qualified as Identity
import Conformance.Support.ObservedTx qualified as ObservedTx
import Conformance.Support.Oracle qualified as Oracle
import Conformance.Support.Payments qualified as Payments
import Conformance.Support.Programs qualified as Programs
import Conformance.Support.PurposeUnits qualified as PurposeUnits
import Conformance.Support.Receipt qualified as Receipt
import Conformance.Support.ReceiptBound qualified as ReceiptBound
import Conformance.Support.Refusal qualified as Refusal
import Conformance.Support.RegistrationComparison qualified as RegistrationComparison
import Conformance.Support.Replay qualified as Replay
import Conformance.Support.Retraction qualified as Retraction
import Conformance.Support.Rows qualified as Rows
import Conformance.Support.RunReplay qualified as RunReplay
import Conformance.Support.Specification qualified as Specification
import Conformance.Support.Step qualified as Step
import Conformance.Support.Vocabularies qualified as Vocabularies
import System.Environment (lookupEnv)
import Test.Hspec (Spec, describe, hspec)

{- | Normally the suite. With the rendezvous variable set, the second process
the temporary-directory checks need: it claims directories through the same
fixture boundary and holds them until released.
-}
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
        ReceiptBound.spec
        Refusal.spec
        Rows.spec
        Programs.spec
        Vocabularies.spec
        EvidencePage.spec
        Identity.spec
        Fixture.spec
        RegistrationComparison.spec
        Payments.spec
        ObservedTx.spec
        ObservedTx.mintTamperSpec
        Oracle.spec
        DriverTransport.spec
        Step.spec
        Retraction.spec
        Specification.spec
        HeldView.spec
        PurposeUnits.spec
        Usage.spec
        Binding.spec
        CliControls.spec
        CliProof.spec
        CliAdmission.spec
        CliAttach.spec
        Replay.spec
        RunReplay.spec
        Extent.spec
