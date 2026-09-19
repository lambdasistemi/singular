module Main (main) where

import Singular.Registry.BlueprintParametersSpec qualified
import Singular.Registry.CandidateSpec qualified
import Singular.Registry.FailureMatchSpec qualified
import Singular.Registry.NodeSpec qualified
import Singular.Registry.LifecycleSpec qualified
import Singular.Registry.TypesSpec qualified
import Naming.CompleteVerifySpec qualified
import Naming.RegisterSpec qualified
import Naming.RetireVerifySpec qualified
import Naming.RecordValueSpec qualified
import Test.Hspec (hspec)

main :: IO ()
main = hspec $ do
    Singular.Registry.BlueprintParametersSpec.spec
    Singular.Registry.CandidateSpec.spec
    Singular.Registry.FailureMatchSpec.spec
    Singular.Registry.NodeSpec.spec
    Singular.Registry.LifecycleSpec.spec
    Singular.Registry.TypesSpec.spec
    Naming.CompleteVerifySpec.spec
    Naming.RegisterSpec.spec
    Naming.RetireVerifySpec.spec
    Naming.RecordValueSpec.spec
