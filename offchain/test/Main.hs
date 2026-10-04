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
import Singular.CLI.RejectSpec qualified
import Singular.CLI.WriteSpec qualified
import Singular.CLISpec qualified
import Singular.Provider.Koios.ClientSpec qualified
import Singular.Provider.Koios.HttpSpec qualified
import Singular.Provider.Koios.RecordedSpec qualified
import Singular.Provider.Koios.RecorderSpec qualified
import Singular.Registry.BlueprintParametersSpec qualified
import Singular.Registry.CandidateSpec qualified
import Singular.Registry.DeploymentSpec qualified
import Singular.Registry.FailureMatchSpec qualified
import Singular.Registry.IndexerViewSpec qualified
import Singular.Registry.LifecycleSpec qualified
import Singular.Registry.NodeCleanupSpec qualified
import Singular.Registry.NodeSpec qualified
import Singular.Registry.NodeWaitSpec qualified
import Singular.Registry.OneViewSpec qualified
import Singular.Registry.PhaseLogSpec qualified
import Singular.Registry.ProviderSpec qualified
import Singular.Registry.TxBuilder.BookEdgeSpec qualified
import Singular.Registry.TxBuilder.BootSpec qualified
import Singular.Registry.TxBuilder.BurnSourceSpec qualified
import Singular.Registry.TxBuilder.MeasuredBookingSpec qualified
import Singular.Registry.TxBuilder.RetractFundingSpec qualified
import Singular.Registry.TxBuilder.SkipEvalUnitsSpec qualified
import Singular.Registry.TxBuilder.UpperSlotSpec qualified
import Singular.Registry.TypesSpec qualified
import Test.Hspec (hspec)

main :: IO ()
main = hspec $ do
    Singular.Registry.BlueprintParametersSpec.spec
    Singular.Registry.TxBuilder.BookEdgeSpec.spec
    Singular.Registry.TxBuilder.MeasuredBookingSpec.spec
    Singular.Registry.TxBuilder.RetractFundingSpec.spec
    Singular.Registry.TxBuilder.BootSpec.spec
    Singular.Registry.TxBuilder.BurnSourceSpec.spec
    Singular.Registry.TxBuilder.SkipEvalUnitsSpec.spec
    Singular.Registry.TxBuilder.UpperSlotSpec.spec
    Singular.Registry.CandidateSpec.spec
    Singular.Registry.DeploymentSpec.spec
    Singular.Registry.FailureMatchSpec.spec
    Singular.Registry.NodeCleanupSpec.spec
    Singular.Registry.NodeSpec.spec
    Singular.Registry.NodeWaitSpec.spec
    Singular.Registry.OneViewSpec.spec
    Singular.Registry.PhaseLogSpec.spec
    Singular.Registry.ProviderSpec.spec
    Singular.Registry.IndexerViewSpec.spec
    Singular.Registry.LifecycleSpec.spec
    Singular.Registry.TypesSpec.spec
    Naming.CompleteVerifySpec.spec
    Naming.RegisterSpec.spec
    Naming.RetireVerifySpec.spec
    Naming.RecordValueSpec.spec
    Singular.Application.OpenDatum.EnvelopeSpec.spec
    Singular.Application.OpenDatum.BuildersSpec.spec
    Singular.Application.OpenDatum.BuildSpec.spec
    Singular.CLI.InsertEnvelopeSpec.spec
    Singular.CLISpec.spec
    Singular.CLI.OutlaySpec.spec
    Singular.CLI.FoldSpec.spec
    Singular.CLI.RejectSpec.spec
    Singular.CLI.ReclaimSpec.spec
    Singular.CLI.WriteSpec.spec
    Singular.Provider.Koios.ClientSpec.spec
    Singular.Provider.Koios.HttpSpec.spec
    Singular.Provider.Koios.RecorderSpec.spec
    Singular.Provider.Koios.RecordedSpec.spec
