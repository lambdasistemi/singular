module Main (main) where

import Singular.Application.OpenDatum.ApplicationSpec qualified
import Singular.Application.OpenDatum.BuildSpec qualified
import Singular.Application.OpenDatum.BuildersSpec qualified
import Singular.Application.OpenDatum.BurnSourceSpec qualified
import Singular.Application.OpenDatum.CLISpec qualified
import Singular.Application.OpenDatum.CommandRunSpec qualified
import Singular.Application.OpenDatum.EnvelopeSpec qualified
import Singular.Application.OpenDatum.FoldSpec qualified
import Singular.Application.OpenDatum.InsertEnvelopeSpec qualified
import Singular.Application.OpenDatum.ManagedStateSpec qualified
import Singular.Application.OpenDatum.NegativeParseSpec qualified
import Singular.Application.OpenDatum.NeutralValueSpec qualified
import Singular.Application.OpenDatum.OutlaySpec qualified
import Singular.Application.OpenDatum.RecoverySpec qualified
import Singular.Application.OpenDatum.RegistryStateTokenSpec qualified
import Singular.Application.OpenDatum.StateTokenSpec qualified
import Singular.Application.OpenDatum.TraceSpec qualified
import Singular.Application.OpenDatum.WriteSpec qualified
import Test.Hspec (describe, hspec)
import Test.Tags (Area (..), tagged)

main :: IO ()
main = hspec $ do
    describe
        (tagged "Singular.Application.OpenDatum.BurnSource" [Builders])
        Singular.Application.OpenDatum.BurnSourceSpec.spec
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
        (tagged "Singular.Application.OpenDatum.InsertEnvelope" [Cli])
        Singular.Application.OpenDatum.InsertEnvelopeSpec.spec
    describe
        (tagged "Singular.Application.OpenDatum.CLI" [Cli])
        Singular.Application.OpenDatum.CLISpec.spec
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
        (tagged "Singular.Application.OpenDatum.Trace" [Cli])
        Singular.Application.OpenDatum.TraceSpec.spec
    describe
        (tagged "Singular.Application.OpenDatum.NegativeParse" [Cli])
        Singular.Application.OpenDatum.NegativeParseSpec.spec
