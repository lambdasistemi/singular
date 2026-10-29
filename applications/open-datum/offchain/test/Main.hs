module Main (main) where

import Singular.Application.OpenDatum.ReaderSpec qualified (spec)

import Singular.Application.OpenDatum.ActorDirectorySpec qualified
import Singular.Application.OpenDatum.ApplicationSpec qualified
import Singular.Application.OpenDatum.BuildSpec qualified
import Singular.Application.OpenDatum.BuildersSpec qualified
import Singular.Application.OpenDatum.CLISpec qualified
import Singular.Application.OpenDatum.ClosedModeSpec qualified
import Singular.Application.OpenDatum.CommandRunSpec qualified
import Singular.Application.OpenDatum.EnvelopeSpec qualified
import Singular.Application.OpenDatum.FlagGroupExtentSpec qualified
import Singular.Application.OpenDatum.FoldSpec qualified
import Singular.Application.OpenDatum.HelpSnapshotSpec qualified
import Singular.Application.OpenDatum.LibraryStateSpec qualified
import Singular.Application.OpenDatum.ManagedStateSpec qualified
import Singular.Application.OpenDatum.NeutralValueSpec qualified
import Singular.Application.OpenDatum.OutlaySpec qualified
import Singular.Application.OpenDatum.ParserCorpusSpec qualified
import Singular.Application.OpenDatum.PartitionLibrarySpec qualified
import Singular.Application.OpenDatum.PinGateSpec qualified
import Singular.Application.OpenDatum.RecoverySpec qualified
import Singular.Application.OpenDatum.RegistryAddressSpec qualified
import Singular.Application.OpenDatum.RegistryStateTokenSpec qualified
import Singular.Application.OpenDatum.RequestBookingSpec qualified
import Singular.Application.OpenDatum.RequestCommandSpec qualified
import Singular.Application.OpenDatum.RequestConfigurationSpec qualified
import Singular.Application.OpenDatum.RequestCreationSpec qualified
import Singular.Application.OpenDatum.RequestFoldSpec qualified
import Singular.Application.OpenDatum.RequestHoldingSpec qualified
import Singular.Application.OpenDatum.RequestPendingSpec qualified
import Singular.Application.OpenDatum.RequestPublicationSpec qualified
import Singular.Application.OpenDatum.RequestRecordsSpec qualified
import Singular.Application.OpenDatum.RequestScriptSpec qualified
import Singular.Application.OpenDatum.RequestTerminationFoldSpec qualified
import Singular.Application.OpenDatum.SourcesSpec qualified
import Singular.Application.OpenDatum.StateTokenSpec qualified
import Singular.Application.OpenDatum.TraceSpec qualified
import Singular.Application.OpenDatum.WalletAdmissionSpec qualified
import Singular.Application.OpenDatum.WriteSpec qualified
import Test.Hspec (describe, hspec)
import Test.Tags (Area (..), tagged)

main :: IO ()
main = hspec $ do
    describe
        (tagged "Singular.Application.OpenDatum.Outlay" [Cli])
        Singular.Application.OpenDatum.OutlaySpec.spec
    describe
        (tagged "Singular.Application.OpenDatum.Application" [Application])
        Singular.Application.OpenDatum.ApplicationSpec.spec
    describe
        (tagged "Singular.Application.OpenDatum.NeutralValue" [Application])
        Singular.Application.OpenDatum.NeutralValueSpec.spec
    describe
        (tagged "Singular.Application.OpenDatum.RegistryStateToken" [Provider])
        Singular.Application.OpenDatum.RegistryStateTokenSpec.spec
    describe
        ( tagged
            "Singular.Application.OpenDatum.Envelope"
            [Application, Builders]
        )
        Singular.Application.OpenDatum.EnvelopeSpec.spec
    describe
        ( tagged
            "Singular.Application.OpenDatum.Builders"
            [Application, Builders]
        )
        Singular.Application.OpenDatum.BuildersSpec.spec
    describe
        (tagged "Singular.Application.OpenDatum.Build" [Application, Builders])
        Singular.Application.OpenDatum.BuildSpec.spec
    describe
        ( tagged
            "Singular.Application.OpenDatum.RequestRecords"
            [Application, Builders]
        )
        Singular.Application.OpenDatum.RequestRecordsSpec.spec
    describe
        ( tagged
            "Singular.Application.OpenDatum.RequestBooking"
            [Application, Builders, Evaluation]
        )
        Singular.Application.OpenDatum.RequestBookingSpec.spec
    describe
        ( tagged
            "Singular.Application.OpenDatum.RequestConfiguration"
            [Application, Builders, Evaluation]
        )
        Singular.Application.OpenDatum.RequestConfigurationSpec.spec
    describe
        ( tagged
            "Singular.Application.OpenDatum.RequestCreation"
            [Application, Builders, Evaluation]
        )
        Singular.Application.OpenDatum.RequestCreationSpec.spec
    describe
        ( tagged
            "Singular.Application.OpenDatum.RequestFold"
            [Application, Builders, Evaluation, Trie]
        )
        Singular.Application.OpenDatum.RequestFoldSpec.spec
    describe
        ( tagged
            "Singular.Application.OpenDatum.RequestHolding"
            [Application, Builders, Evaluation]
        )
        Singular.Application.OpenDatum.RequestHoldingSpec.spec
    describe
        ( tagged
            "Singular.Application.OpenDatum.Reader"
            [Application, Builders, Trie]
        )
        Singular.Application.OpenDatum.ReaderSpec.spec
    describe
        ( tagged
            "Singular.Application.OpenDatum.RequestTerminationFold"
            [Application, Builders, Evaluation, Trie]
        )
        Singular.Application.OpenDatum.RequestTerminationFoldSpec.spec
    describe
        ( tagged
            "Singular.Application.OpenDatum.RequestPublication"
            [Application, Builders, Evaluation]
        )
        Singular.Application.OpenDatum.RequestPublicationSpec.spec
    describe
        ( tagged
            "Singular.Application.OpenDatum.RequestPending"
            [Application, Builders, Evaluation]
        )
        Singular.Application.OpenDatum.RequestPendingSpec.spec
    describe
        ( tagged
            "Singular.Application.OpenDatum.RequestScript"
            [Application, Builders, Evaluation]
        )
        Singular.Application.OpenDatum.RequestScriptSpec.spec
    describe
        (tagged "Singular.Application.OpenDatum.CLI" [Cli])
        Singular.Application.OpenDatum.CLISpec.spec
    describe
        (tagged "Singular.Application.OpenDatum.LibraryState" [Cli])
        Singular.Application.OpenDatum.LibraryStateSpec.spec
    describe
        (tagged "Singular.Application.OpenDatum.WalletAdmission" [Cli])
        Singular.Application.OpenDatum.WalletAdmissionSpec.spec
    describe
        (tagged "Singular.Application.OpenDatum.PartitionLibrary" [Cli])
        Singular.Application.OpenDatum.PartitionLibrarySpec.spec
    describe
        ( tagged
            "Singular.Application.OpenDatum.ActorDirectory"
            [Cli, Wallet]
        )
        Singular.Application.OpenDatum.ActorDirectorySpec.spec
    describe
        (tagged "Singular.Application.OpenDatum.ParserCorpus" [Cli])
        Singular.Application.OpenDatum.ParserCorpusSpec.spec
    describe
        (tagged "Singular.Application.OpenDatum.HelpSnapshot" [Cli])
        Singular.Application.OpenDatum.HelpSnapshotSpec.spec
    describe
        (tagged "Singular.Application.OpenDatum.Sources" [Cli])
        Singular.Application.OpenDatum.SourcesSpec.spec
    describe
        (tagged "Singular.Application.OpenDatum.RegistryAddress" [Cli])
        Singular.Application.OpenDatum.RegistryAddressSpec.spec
    describe
        (tagged "Singular.Application.OpenDatum.Fold" [Cli])
        Singular.Application.OpenDatum.FoldSpec.spec
    describe
        (tagged "Singular.Application.OpenDatum.ManagedState" [Cli])
        Singular.Application.OpenDatum.ManagedStateSpec.spec
    describe
        (tagged "Singular.Application.OpenDatum.StateToken" [Cli, Wallet])
        Singular.Application.OpenDatum.StateTokenSpec.spec
    describe
        (tagged "Singular.Application.OpenDatum.Recovery" [Cli, Recovery])
        Singular.Application.OpenDatum.RecoverySpec.spec
    describe
        (tagged "Singular.Application.OpenDatum.Write" [Cli, Recovery])
        Singular.Application.OpenDatum.WriteSpec.spec
    describe
        (tagged "Singular.Application.OpenDatum.CommandRun" [Cli])
        Singular.Application.OpenDatum.CommandRunSpec.spec
    describe
        ( tagged
            "Singular.Application.OpenDatum.RequestCommand"
            [Cli, Recovery, Evaluation]
        )
        Singular.Application.OpenDatum.RequestCommandSpec.spec
    describe
        (tagged "Singular.Application.OpenDatum.ClosedMode" [Cli])
        Singular.Application.OpenDatum.ClosedModeSpec.spec
    describe
        (tagged "Singular.Application.OpenDatum.PinGate" [Cli])
        Singular.Application.OpenDatum.PinGateSpec.spec
    describe
        (tagged "Singular.Application.OpenDatum.Trace" [Cli])
        Singular.Application.OpenDatum.TraceSpec.spec
    describe
        (tagged "Singular.Application.OpenDatum.FlagGroupExtent" [Cli])
        Singular.Application.OpenDatum.FlagGroupExtentSpec.spec
