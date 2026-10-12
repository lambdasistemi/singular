module Main (main) where

import Singular.Application.KeriStub.CLISpec qualified
import Singular.Application.KeriStub.ConvictSpec qualified
import Singular.Application.KeriStub.DatumSpec qualified
import Singular.Application.KeriStub.FlagGroupExtentSpec qualified
import Singular.Application.KeriStub.PurposesSpec qualified
import Singular.Application.KeriStub.RegisterSpec qualified
import Singular.Application.KeriStub.RulesSpec qualified
import Singular.Application.KeriStub.ScriptRecordSpec qualified
import Singular.Application.KeriStub.ValueSpec qualified
import Test.Hspec (describe, hspec)
import Test.Tags (Area (..), tagged)

main :: IO ()
main = hspec $ do
    describe
        (tagged "Singular.Application.KeriStub.CLI" [Cli])
        Singular.Application.KeriStub.CLISpec.spec
    describe
        (tagged "Singular.Application.KeriStub.Convict" [Application])
        Singular.Application.KeriStub.ConvictSpec.spec
    describe
        (tagged "Singular.Application.KeriStub.Datum" [Application])
        Singular.Application.KeriStub.DatumSpec.spec
    describe
        (tagged "Singular.Application.KeriStub.FlagGroupExtent" [Cli])
        Singular.Application.KeriStub.FlagGroupExtentSpec.spec
    describe
        (tagged "Singular.Application.KeriStub.Register" [Application])
        Singular.Application.KeriStub.RegisterSpec.spec
    describe
        (tagged "Singular.Application.KeriStub.Purposes" [Application])
        Singular.Application.KeriStub.PurposesSpec.spec
    describe
        (tagged "Singular.Application.KeriStub.Rules" [Application])
        Singular.Application.KeriStub.RulesSpec.spec
    describe
        (tagged "Singular.Application.KeriStub.ScriptRecord" [Application])
        Singular.Application.KeriStub.ScriptRecordSpec.spec
    describe
        (tagged "Singular.Application.KeriStub.Value" [Application])
        Singular.Application.KeriStub.ValueSpec.spec
