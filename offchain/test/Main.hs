module Main (main) where

import Naming.CompleteVerifySpec qualified
import Naming.RecordValueSpec qualified
import Naming.RegisterSpec qualified
import Naming.RetireVerifySpec qualified
import Singular.Application.OpenDatum.BuildSpec qualified
import Singular.Application.OpenDatum.BuildersSpec qualified
import Singular.Application.OpenDatum.EnvelopeSpec qualified
import Singular.CLI.FoldSpec qualified
import Singular.CLI.InsertEnvelopeSpec qualified
import Singular.CLI.OutlaySpec qualified
import Singular.CLI.ReclaimSpec qualified
import Singular.CLI.RecoverySpec qualified
import Singular.CLI.RejectSpec qualified
import Singular.CLI.TrieRefusalSpec qualified
import Singular.CLI.WriteSpec qualified
import Singular.CLISpec qualified
import Singular.Provider.Koios.ClientSpec qualified
import Singular.Provider.Koios.HttpSpec qualified
import Singular.Provider.Koios.ProviderSpec qualified
import Singular.Provider.Koios.RecordedSpec qualified
import Singular.Provider.Koios.RecorderSpec qualified
import Singular.Registry.BlueprintParametersSpec qualified
import Singular.Registry.CandidateSpec qualified
import Singular.Registry.DeploymentSpec qualified
import Singular.Registry.FailureMatchSpec qualified
import Singular.Registry.IndexerViewSpec qualified
import Singular.Registry.LifecycleSpec qualified
import Singular.Registry.LineageSpec qualified
import Singular.Registry.LocalEvaluationSpec qualified
import Singular.Registry.LocalServicesCallerSpec qualified
import Singular.Registry.NetworkTimeSpec qualified
import Singular.Registry.NodeCleanupSpec qualified
import Singular.Registry.NodeSpec qualified
import Singular.Registry.NodeWaitSpec qualified
import Singular.Registry.OneViewSpec qualified
import Singular.Registry.PhaseLogSpec qualified
import Singular.Registry.Private.ArchiveSpec qualified
import Singular.Registry.ProviderSpec qualified
import Singular.Registry.SessionServicesSpec qualified
import Singular.Registry.TrieStateContractSpec qualified
import Singular.Registry.TrieStateSpec qualified
import Singular.Registry.TxBuilder.BookEdgeSpec qualified
import Singular.Registry.TxBuilder.BootSpec qualified
import Singular.Registry.TxBuilder.BurnSourceSpec qualified
import Singular.Registry.TxBuilder.MeasuredBookingSpec qualified
import Singular.Registry.TxBuilder.RetractFundingSpec qualified
import Singular.Registry.TxBuilder.SkipEvalUnitsSpec qualified
import Singular.Registry.TxBuilder.UpperSlotSpec qualified
import Singular.Registry.TypesSpec qualified
import Singular.Registry.WaitSpec qualified
import Test.Hspec (describe, hspec)
import Test.Tags (Area (..), tagged)

main :: IO ()
main = hspec $ do
    describe
        (tagged "Singular.Registry.BlueprintParameters" [Builders])
        Singular.Registry.BlueprintParametersSpec.spec
    describe
        (tagged "Singular.Registry.TxBuilder.BookEdge" [Builders])
        Singular.Registry.TxBuilder.BookEdgeSpec.spec
    describe
        ( tagged
            "Singular.Registry.TxBuilder.MeasuredBooking"
            [Builders, Evaluation]
        )
        Singular.Registry.TxBuilder.MeasuredBookingSpec.spec
    describe
        ( tagged
            "Singular.Registry.TxBuilder.RetractFunding"
            [Builders, Time, Validity]
        )
        Singular.Registry.TxBuilder.RetractFundingSpec.spec
    describe
        (tagged "Singular.Registry.TxBuilder.Boot" [Builders])
        Singular.Registry.TxBuilder.BootSpec.spec
    describe
        (tagged "Singular.Registry.TxBuilder.BurnSource" [Builders])
        Singular.Registry.TxBuilder.BurnSourceSpec.spec
    describe
        ( tagged
            "Singular.Registry.TxBuilder.SkipEvalUnits"
            [Builders, Evaluation]
        )
        Singular.Registry.TxBuilder.SkipEvalUnitsSpec.spec
    describe
        ( tagged
            "Singular.Registry.TxBuilder.UpperSlot"
            [Builders, Time, Validity]
        )
        Singular.Registry.TxBuilder.UpperSlotSpec.spec
    describe
        (tagged "Singular.Registry.Candidate" [Validity, Builders])
        Singular.Registry.CandidateSpec.spec
    describe
        (tagged "Singular.Registry.Deployment" [Builders])
        Singular.Registry.DeploymentSpec.spec
    describe
        (tagged "Singular.Registry.FailureMatch" [Provider])
        Singular.Registry.FailureMatchSpec.spec
    describe
        (tagged "Singular.Registry.NodeCleanup" [Provider, Recovery])
        Singular.Registry.NodeCleanupSpec.spec
    describe
        (tagged "Singular.Registry.NetworkTime" [Time, Provider])
        Singular.Registry.NetworkTimeSpec.spec
    describe
        (tagged "Singular.Registry.LocalEvaluation" [Evaluation, Provider])
        Singular.Registry.LocalEvaluationSpec.spec
    describe
        (tagged "Singular.Registry.SessionServices" [Provider])
        Singular.Registry.SessionServicesSpec.spec
    describe
        (tagged "Singular.Registry.Wait" [Time, Provider])
        Singular.Registry.WaitSpec.spec
    describe
        (tagged "Singular.Registry.LocalServicesCaller" [Provider])
        Singular.Registry.LocalServicesCallerSpec.spec
    describe
        (tagged "Singular.Registry.Node" [Provider, Wallet])
        Singular.Registry.NodeSpec.spec
    describe
        (tagged "Singular.Registry.NodeWait" [Time, Provider])
        Singular.Registry.NodeWaitSpec.spec
    describe
        (tagged "Singular.Registry.OneView" [Provider])
        Singular.Registry.OneViewSpec.spec
    describe
        (tagged "Singular.Registry.PhaseLog" [History, Recovery])
        Singular.Registry.PhaseLogSpec.spec
    describe
        (tagged "Singular.Registry.Provider" [Provider])
        Singular.Registry.ProviderSpec.spec
    describe
        (tagged "Singular.Registry.Private.Archive" [History, Recovery])
        Singular.Registry.Private.ArchiveSpec.spec
    describe
        (tagged "Singular.Registry.IndexerView" [Provider])
        Singular.Registry.IndexerViewSpec.spec
    describe
        (tagged "Singular.Registry.Lifecycle" [Provider])
        Singular.Registry.LifecycleSpec.spec
    describe
        (tagged "Singular.Registry.Lineage" [History, Provider, Trie])
        Singular.Registry.LineageSpec.spec
    describe
        (tagged "Singular.Registry.Types" [Provider])
        Singular.Registry.TypesSpec.spec
    describe
        (tagged "Singular.Registry.TrieState" [Trie])
        Singular.Registry.TrieStateSpec.spec
    describe
        (tagged "Singular.Registry.TrieStateContract" [Trie])
        Singular.Registry.TrieStateContractSpec.spec
    describe
        (tagged "Naming.CompleteVerify" [Naming, Application])
        Naming.CompleteVerifySpec.spec
    describe
        (tagged "Naming.Register" [Naming, Application])
        Naming.RegisterSpec.spec
    describe
        (tagged "Naming.RetireVerify" [Naming, Application])
        Naming.RetireVerifySpec.spec
    describe
        (tagged "Naming.RecordValue" [Naming, Application])
        Naming.RecordValueSpec.spec
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
        (tagged "Singular.CLI.InsertEnvelope" [Cli])
        Singular.CLI.InsertEnvelopeSpec.spec
    describe (tagged "Singular.CLI" [Cli]) Singular.CLISpec.spec
    describe
        (tagged "Singular.CLI.Outlay" [Cli])
        Singular.CLI.OutlaySpec.spec
    describe (tagged "Singular.CLI.Fold" [Cli]) Singular.CLI.FoldSpec.spec
    describe
        (tagged "Singular.CLI.TrieRefusal" [Cli])
        Singular.CLI.TrieRefusalSpec.spec
    describe
        (tagged "Singular.CLI.Reject" [Cli])
        Singular.CLI.RejectSpec.spec
    describe
        (tagged "Singular.CLI.Reclaim" [Cli, Recovery])
        Singular.CLI.ReclaimSpec.spec
    describe
        (tagged "Singular.CLI.Recovery" [Cli, Recovery])
        Singular.CLI.RecoverySpec.spec
    describe
        (tagged "Singular.CLI.Write" [Cli, Recovery])
        Singular.CLI.WriteSpec.spec
    describe
        (tagged "Singular.Provider.Koios.Client" [Provider])
        Singular.Provider.Koios.ClientSpec.spec
    describe
        (tagged "Singular.Provider.Koios.Provider" [Provider])
        Singular.Provider.Koios.ProviderSpec.spec
    describe
        (tagged "Singular.Provider.Koios.Http" [Provider])
        Singular.Provider.Koios.HttpSpec.spec
    describe
        (tagged "Singular.Provider.Koios.Recorder" [Provider, History])
        Singular.Provider.Koios.RecorderSpec.spec
    describe
        (tagged "Singular.Provider.Koios.Recorded" [Provider, History])
        Singular.Provider.Koios.RecordedSpec.spec
