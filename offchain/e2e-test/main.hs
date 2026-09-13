module Main (main) where

import Test.Hspec (hspec)

import Cardano.MPFS.Cage.E2E.CageSpec qualified
import Cardano.MPFS.Cage.E2E.Fork81Spec qualified

-- | Run all E2E test specs.
main :: IO ()
main =
    hspec $ do
        Cardano.MPFS.Cage.E2E.CageSpec.spec
        Cardano.MPFS.Cage.E2E.Fork81Spec.spec
