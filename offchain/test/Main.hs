module Main (main) where

import Naming.CompleteVerifySpec qualified
import Naming.RecordValueSpec qualified
import Naming.RegisterSpec qualified
import Naming.RetireVerifySpec qualified
import Singular.CLI.BookingRefusalSpec qualified
import Singular.CLI.CommandRunSpec qualified
import Singular.CLI.CreateFundingSpec qualified
import Singular.CLI.DescribeSpec qualified
import Singular.CLI.FailureSentenceSpec qualified
import Singular.CLI.FlagGroupSpec qualified
import Singular.CLI.FoldRulesSpec qualified
import Singular.CLI.HelpSnapshotSpec qualified
import Singular.CLI.JournalTransitionsSpec qualified
import Singular.CLI.OneOutputCreateSpec qualified
import Singular.CLI.ParserCorpusSpec qualified
import Singular.CLI.PayloadSpec qualified
import Singular.CLI.PrepareSpec qualified
import Singular.CLI.ReclaimSpec qualified
import Singular.CLI.RejectSpec qualified
import Singular.CLI.SaveStateTokenSpec qualified
import Singular.CLI.SettingsFileSpec qualified
import Singular.CLI.SignSpec qualified
import Singular.CLI.SourcesSpec qualified
import Singular.CLI.SubmitSpec qualified
import Singular.CLI.TrieRefusalSpec qualified
import Singular.CLI.VaultSpec qualified
import Singular.CLI.VersionSpec qualified
import Singular.Provider.Koios.ClientSpec qualified
import Singular.Provider.Koios.HttpSpec qualified
import Singular.Provider.Koios.ProviderSpec qualified
import Singular.Provider.Koios.RecordedSpec qualified
import Singular.Provider.Koios.RecorderSpec qualified
import Singular.Provider.Koios.ReferenceScriptsSpec qualified
import Singular.Registry.BlueprintParametersSpec qualified
import Singular.Registry.BundleSpec qualified
import Singular.Registry.CandidateSpec qualified
import Singular.Registry.ChainedViewSpec qualified
import Singular.Registry.DeploymentSpec qualified
import Singular.Registry.FailureMatchSpec qualified
import Singular.Registry.FoldAdmissionSpec qualified
import Singular.Registry.FoldSelectionSpec qualified
import Singular.Registry.LifecycleSpec qualified
import Singular.Registry.LineageSpec qualified
import Singular.Registry.LocalEvaluationSpec qualified
import Singular.Registry.LocalServicesCallerSpec qualified
import Singular.Registry.NetworkTimeSpec qualified
import Singular.Registry.OneViewSpec qualified
import Singular.Registry.PageSpec qualified
import Singular.Registry.PhaseLogSpec qualified
import Singular.Registry.PlainJsonSpec qualified
import Singular.Registry.Private.ArchiveSpec qualified
import Singular.Registry.ProviderSpec qualified
import Singular.Registry.SessionServicesSpec qualified
import Singular.Registry.SubmitSpec qualified
import Singular.Registry.TrieStateContractSpec qualified
import Singular.Registry.TrieStateSpec qualified
import Singular.Registry.TxBuilder.BookEdgeSpec qualified
import Singular.Registry.TxBuilder.BootSpec qualified
import Singular.Registry.TxBuilder.MeasuredBookingSpec qualified
import Singular.Registry.TxBuilder.PrepareSpec qualified
import Singular.Registry.TxBuilder.PublicationFundingSpec qualified
import Singular.Registry.TxBuilder.RetractFundingSpec qualified
import Singular.Registry.TxBuilder.SelectedFoldSpec qualified
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
        (tagged "Singular.Registry.Bundle" [Wallet])
        Singular.Registry.BundleSpec.spec
    describe
        (tagged "Singular.Registry.Submit" [Submit, Wallet])
        Singular.Registry.SubmitSpec.spec
    describe
        (tagged "Singular.Registry.ChainedView" [Provider, History])
        Singular.Registry.ChainedViewSpec.spec
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
        (tagged "Singular.Registry.TxBuilder.Prepare" [Builders])
        Singular.Registry.TxBuilder.PrepareSpec.spec
    describe
        (tagged "Singular.Registry.TxBuilder.PublicationFunding" [Builders])
        Singular.Registry.TxBuilder.PublicationFundingSpec.spec
    describe
        (tagged "Singular.Registry.TxBuilder.SelectedFold" [Builders])
        Singular.Registry.TxBuilder.SelectedFoldSpec.spec
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
        (tagged "Singular.Registry.FoldAdmission" [Builders])
        Singular.Registry.FoldAdmissionSpec.spec
    describe
        (tagged "Singular.Registry.FoldSelection" [Builders])
        Singular.Registry.FoldSelectionSpec.spec
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
        (tagged "Singular.Registry.OneView" [Provider])
        Singular.Registry.OneViewSpec.spec
    describe
        (tagged "Singular.Registry.Page" [Trie])
        Singular.Registry.PageSpec.spec
    describe
        (tagged "Singular.Registry.PhaseLog" [Provider, History, Recovery])
        Singular.Registry.PhaseLogSpec.spec
    describe
        (tagged "Singular.Registry.PlainJson" [Application])
        Singular.Registry.PlainJsonSpec.spec
    describe
        (tagged "Singular.Registry.Provider" [Provider])
        Singular.Registry.ProviderSpec.spec
    describe
        (tagged "Singular.Registry.Private.Archive" [History, Recovery])
        Singular.Registry.Private.ArchiveSpec.spec
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
        (tagged "Singular.CLI.TrieRefusal" [Cli])
        Singular.CLI.TrieRefusalSpec.spec
    describe
        (tagged "Singular.CLI.Reject" [Cli])
        Singular.CLI.RejectSpec.spec
    describe
        (tagged "Singular.CLI.Reclaim" [Cli, Recovery])
        Singular.CLI.ReclaimSpec.spec
    describe
        (tagged "Singular.CLI.BookingRefusal" [Cli])
        Singular.CLI.BookingRefusalSpec.spec
    describe
        (tagged "Singular.CLI.FoldRules" [Cli])
        Singular.CLI.FoldRulesSpec.spec
    describe
        (tagged "Singular.CLI.Describe" [Cli])
        Singular.CLI.DescribeSpec.spec
    describe
        (tagged "Singular.CLI.JournalTransitions" [Cli])
        Singular.CLI.JournalTransitionsSpec.spec
    describe
        (tagged "Singular.CLI.CommandRun" [Cli])
        Singular.CLI.CommandRunSpec.spec
    describe
        (tagged "Singular.CLI.CreateFunding" [Cli, Builders])
        Singular.CLI.CreateFundingSpec.spec
    describe
        (tagged "Singular.CLI.OneOutputCreate" [Cli, Builders])
        Singular.CLI.OneOutputCreateSpec.spec
    describe
        (tagged "Singular.CLI.Prepare" [Cli, Builders])
        Singular.CLI.PrepareSpec.spec
    describe
        (tagged "Singular.CLI.FailureSentence" [Cli])
        Singular.CLI.FailureSentenceSpec.spec
    describe
        (tagged "Singular.CLI.FlagGroup" [Cli])
        Singular.CLI.FlagGroupSpec.spec
    describe
        (tagged "Singular.CLI.ParserCorpus" [Cli])
        Singular.CLI.ParserCorpusSpec.spec
    describe
        (tagged "Singular.CLI.Payload" [Cli])
        Singular.CLI.PayloadSpec.spec
    describe
        (tagged "Singular.CLI.HelpSnapshot" [Cli])
        Singular.CLI.HelpSnapshotSpec.spec
    describe
        (tagged "Singular.CLI.Sources" [Cli])
        Singular.CLI.SourcesSpec.spec
    describe
        (tagged "Singular.CLI.SaveStateToken" [Cli])
        Singular.CLI.SaveStateTokenSpec.spec
    describe
        (tagged "Singular.CLI.SettingsFile" [Cli])
        Singular.CLI.SettingsFileSpec.spec
    describe
        (tagged "Singular.CLI.Sign" [Cli, Wallet])
        Singular.CLI.SignSpec.spec
    describe
        (tagged "Singular.CLI.Submit" [Cli, Submit])
        Singular.CLI.SubmitSpec.spec
    describe
        (tagged "Singular.CLI.Vault" [Cli, Wallet])
        Singular.CLI.VaultSpec.spec
    describe
        (tagged "Singular.CLI.Version" [Cli])
        Singular.CLI.VersionSpec.spec
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
    describe
        (tagged "Singular.Provider.Koios.ReferenceScripts" [Provider])
        Singular.Provider.Koios.ReferenceScriptsSpec.spec
