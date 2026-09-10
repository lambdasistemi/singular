module Main (main) where

import Cardano.MPFS.Cage.TypesSpec qualified
import Test.Hspec (hspec)

main :: IO ()
main = hspec Cardano.MPFS.Cage.TypesSpec.spec
