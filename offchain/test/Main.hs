module Main (main) where

import Singular.CLI.CommandRunSpec qualified (spec)
import Singular.CLI.CreateFundingSpec qualified (spec)
import Singular.CLI.FailureSentenceSpec qualified (spec)
import Singular.CLI.FlagGroupSpec qualified (spec)
import Singular.CLI.HelpSnapshotSpec qualified (spec)
import Singular.CLI.InspectSpec qualified (spec)
import Singular.CLI.JournalTransitionsSpec qualified (spec)
import Singular.CLI.OneOutputCreateSpec qualified (spec)
import Singular.CLI.ParserCorpusSpec qualified (spec)
import Singular.CLI.PayloadSpec qualified (spec)
import Singular.CLI.PinGateSpec qualified (spec)
import Singular.CLI.PrintedPayloadSpec qualified (spec)
import Singular.CLI.SignSpec qualified (spec)
import Singular.CLI.SourcesSpec qualified (spec)
import Singular.CLI.StateCommandSpec qualified (spec)
import Singular.CLI.SubmitSpec qualified (spec)
import Singular.CLI.TrieRefusalSpec qualified (spec)
import Singular.CLI.VaultSpec qualified (spec)
import Singular.CLI.VersionSpec qualified (spec)
import Singular.Provider.Koios.ClientSpec qualified (spec)
import Singular.Provider.Koios.HttpSpec qualified (spec)
import Singular.Provider.Koios.ProviderSpec qualified (spec)
import Singular.Provider.Koios.RecordedSpec qualified (spec)
import Singular.Provider.Koios.RecorderSpec qualified (spec)
import Singular.Provider.Koios.ReferenceScriptsSpec qualified
    ( spec
    )
import Singular.Registry.AddressSpec qualified (spec)
import Singular.Registry.BlueprintParametersSpec qualified (spec)
import Singular.Registry.BundleSpec qualified (spec)
import Singular.Registry.ChainedViewSpec qualified (spec)
import Singular.Registry.ContractTableSpec qualified (spec)
import Singular.Registry.DeploymentSpec qualified (spec)
import Singular.Registry.FailureMatchSpec qualified (spec)
import Singular.Registry.FoldAdmissionSpec qualified (spec)
import Singular.Registry.LifecycleSpec qualified (spec)
import Singular.Registry.LineageSpec qualified (spec)
import Singular.Registry.LocalEvaluationSpec qualified (spec)
import Singular.Registry.LocalServicesCallerSpec qualified (spec)
import Singular.Registry.NetworkTimeSpec qualified (spec)
import Singular.Registry.OneViewSpec qualified (spec)
import Singular.Registry.PhaseLogSpec qualified (spec)
import Singular.Registry.PlainJsonSpec qualified (spec)
import Singular.Registry.Private.ArchiveSpec qualified (spec)
import Singular.Registry.ProviderSpec qualified (spec)
import Singular.Registry.ReaderSpec qualified (spec)
import Singular.Registry.SessionServicesSpec qualified (spec)
import Singular.Registry.SubmitSpec qualified (spec)
import Singular.Registry.TrieStateContractSpec qualified (spec)
import Singular.Registry.TrieStateSpec qualified (spec)
import Singular.Registry.TxBuilder.PrepareSpec qualified (spec)
import Singular.Registry.TxBuilder.PublicationFundingSpec qualified
    ( spec
    )
import Singular.Registry.TxBuilder.ReferencePublicationSpec qualified
    ( spec
    )
import Singular.Registry.TxBuilder.UpperSlotSpec qualified (spec)
import Singular.Registry.TypesSpec qualified (spec)
import Singular.Registry.WaitSpec qualified (spec)
import Singular.State.PreimageSpec qualified (spec)
import Singular.State.StateFoldSpec qualified (spec)
import Singular.State.StateGenesisSpec qualified (spec)
import Singular.State.StateLineageSpec qualified (spec)
import Singular.State.StatePublicationSpec qualified (spec)
import Singular.State.StateRecordsSpec qualified (spec)
import Singular.State.StateWindowSpec qualified (spec)
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
        (tagged "Singular.Registry.TxBuilder.ReferencePublication" [Builders])
        Singular.Registry.TxBuilder.ReferencePublicationSpec.spec
    describe
        (tagged "Singular.Registry.TxBuilder.Prepare" [Builders])
        Singular.Registry.TxBuilder.PrepareSpec.spec
    describe
        (tagged "Singular.Registry.TxBuilder.PublicationFunding" [Builders])
        Singular.Registry.TxBuilder.PublicationFundingSpec.spec
    describe
        ( tagged
            "Singular.Registry.TxBuilder.UpperSlot"
            [Builders, Time, Validity]
        )
        Singular.Registry.TxBuilder.UpperSlotSpec.spec
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
        (tagged "Singular.CLI.TrieRefusal" [Cli])
        Singular.CLI.TrieRefusalSpec.spec
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
        (tagged "Singular.CLI.PinGate" [Cli])
        Singular.CLI.PinGateSpec.spec
    describe
        (tagged "Singular.CLI.PrintedPayload" [Cli])
        Singular.CLI.PrintedPayloadSpec.spec
    describe
        (tagged "Singular.CLI.Inspect" [Cli])
        Singular.CLI.InspectSpec.spec
    describe
        (tagged "Singular.CLI.HelpSnapshot" [Cli])
        Singular.CLI.HelpSnapshotSpec.spec
    describe
        (tagged "Singular.CLI.Sources" [Cli])
        Singular.CLI.SourcesSpec.spec
    describe
        (tagged "Singular.CLI.StateCommand" [Cli, Recovery])
        Singular.CLI.StateCommandSpec.spec
    describe
        (tagged "Singular.Registry.Address" [Cli])
        Singular.Registry.AddressSpec.spec
    describe
        (tagged "Singular.Registry.ContractTable" [Cli])
        Singular.Registry.ContractTableSpec.spec
    describe
        (tagged "Singular.Registry.Reader" [Provider])
        Singular.Registry.ReaderSpec.spec
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
    describe
        (tagged "Singular.State.Preimage" [Builders])
        Singular.State.PreimageSpec.spec
    describe
        (tagged "Singular.State.StateRecords" [Builders])
        Singular.State.StateRecordsSpec.spec
    describe
        (tagged "Singular.State.StateGenesis" [Builders, Evaluation])
        Singular.State.StateGenesisSpec.spec
    describe
        (tagged "Singular.State.StatePublication" [Builders])
        Singular.State.StatePublicationSpec.spec
    describe
        (tagged "Singular.State.StateWindow" [Builders])
        Singular.State.StateWindowSpec.spec
    describe
        (tagged "Singular.State.StateLineage" [Builders, Trie, History])
        Singular.State.StateLineageSpec.spec
    describe
        (tagged "Singular.State.StateFold" [Builders, Trie, Evaluation])
        Singular.State.StateFoldSpec.spec
