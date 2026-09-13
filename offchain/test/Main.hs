module Main (main) where

import Cardano.MPFS.Cage.FailureMatchSpec qualified
import Cardano.MPFS.Cage.TypesSpec qualified
import Naming.RegisterSpec qualified
import Test.Hspec (hspec)

main :: IO ()
main = hspec $ do
    Cardano.MPFS.Cage.FailureMatchSpec.spec
    Cardano.MPFS.Cage.TypesSpec.spec
    Naming.RegisterSpec.spec
