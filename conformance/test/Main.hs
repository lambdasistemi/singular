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
import Conformance.Support.FoldHistory qualified as FoldHistory
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
import Conformance.Support.Withhold qualified as Withhold
import System.Environment (lookupEnv)
import Test.Hspec (Spec, describe, hspec)
import Test.Tags (Area (..), tagged)

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
    describe (tagged "Conformance.Support.Receipt" [Conformance]) $
        describe "Appendix — how we check the evidence" Receipt.spec
    describe (tagged "Conformance.Support.ReceiptBound" [Conformance]) $
        describe "Appendix — how we check the evidence" ReceiptBound.spec
    describe (tagged "Conformance.Support.Refusal" [Conformance]) $
        describe "Appendix — how we check the evidence" Refusal.spec
    describe (tagged "Conformance.Support.Rows" [Conformance]) $
        describe "Appendix — how we check the evidence" Rows.spec
    describe (tagged "Conformance.Support.Programs" [Conformance]) $
        describe "Appendix — how we check the evidence" Programs.spec
    describe (tagged "Conformance.Support.EvidencePage" [Conformance]) $
        describe "Appendix — how we check the evidence" EvidencePage.spec
    describe (tagged "Conformance.Support.Identity" [Conformance]) $
        describe "Appendix — how we check the evidence" Identity.spec
    describe (tagged "Conformance.Support.Fixture" [Conformance]) $
        describe "Appendix — how we check the evidence" Fixture.spec
    describe
        (tagged "Conformance.Support.RegistrationComparison" [Conformance])
        $ describe
            "Appendix — how we check the evidence"
            RegistrationComparison.spec
    describe (tagged "Conformance.Support.Payments" [Conformance]) $
        describe "Appendix — how we check the evidence" Payments.spec
    describe (tagged "Conformance.Support.ObservedTx" [Conformance]) $
        describe "Appendix — how we check the evidence" ObservedTx.spec
    describe (tagged "Conformance.Support.ObservedTx" [Conformance]) $
        describe
            "Appendix — how we check the evidence"
            ObservedTx.mintTamperSpec
    describe (tagged "Conformance.Support.Oracle" [Conformance]) $
        describe "Appendix — how we check the evidence" Oracle.spec
    describe (tagged "Conformance.Support.DriverTransport" [Conformance]) $
        describe "Appendix — how we check the evidence" DriverTransport.spec
    describe (tagged "Conformance.Support.Step" [Conformance]) $
        describe "Appendix — how we check the evidence" Step.spec
    describe (tagged "Conformance.Support.Retraction" [Conformance]) $
        describe "Appendix — how we check the evidence" Retraction.spec
    describe (tagged "Conformance.Support.Specification" [Conformance]) $
        describe "Appendix — how we check the evidence" Specification.spec
    describe (tagged "Conformance.Support.HeldView" [Conformance]) $
        describe "Appendix — how we check the evidence" HeldView.spec
    describe
        (tagged "Conformance.Support.PurposeUnits" [Conformance, Evaluation])
        $ describe "Appendix — how we check the evidence" PurposeUnits.spec
    describe (tagged "Conformance.Story.Usage" [Conformance]) $
        describe "Appendix — how we check the evidence" Usage.spec
    describe (tagged "Conformance.Support.Binding" [Conformance]) $
        describe "Appendix — how we check the evidence" Binding.spec
    describe (tagged "Conformance.Support.CliControls" [Conformance, Cli]) $
        describe "Appendix — how we check the evidence" CliControls.spec
    describe (tagged "Conformance.Support.CliProof" [Conformance, Cli]) $
        describe "Appendix — how we check the evidence" CliProof.spec
    describe
        (tagged "Conformance.Support.Withhold" [Conformance, Cli, History])
        $ describe "Appendix — how we check the evidence" Withhold.spec
    describe
        ( tagged
            "Conformance.Support.FoldHistory"
            [Conformance, Cli, History, Trie]
        )
        $ describe "Appendix — how we check the evidence" FoldHistory.spec
    describe
        (tagged "Conformance.Support.CliAdmission" [Conformance, Cli])
        $ describe "Appendix — how we check the evidence" CliAdmission.spec
    describe (tagged "Conformance.Support.CliAttach" [Conformance, Cli]) $
        describe "Appendix — how we check the evidence" CliAttach.spec
    describe (tagged "Conformance.Support.Replay" [Conformance, History]) $
        describe "Appendix — how we check the evidence" Replay.spec
    describe
        (tagged "Conformance.Support.RunReplay" [Conformance, History])
        $ describe "Appendix — how we check the evidence" RunReplay.spec
    describe (tagged "Conformance.Support.Extent" [Conformance]) $
        describe "Appendix — how we check the evidence" Extent.spec
