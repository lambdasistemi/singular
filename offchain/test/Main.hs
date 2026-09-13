module Main (main) where

import Cardano.MPFS.Cage.FailureMatchSpec qualified
import Cardano.MPFS.Cage.TypesSpec qualified
import Naming.CompleteVerifySpec qualified
import Naming.RegisterSpec qualified
import Naming.RetireVerifySpec qualified
import Test.Hspec (hspec)

main :: IO ()
main = hspec $ do
    Cardano.MPFS.Cage.FailureMatchSpec.spec
    Cardano.MPFS.Cage.TypesSpec.spec
    Naming.CompleteVerifySpec.spec
    Naming.RegisterSpec.spec
    Naming.RetireVerifySpec.spec
