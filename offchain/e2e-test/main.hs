module Main (main) where

import Test.Hspec (hspec)

import Cardano.MPFS.Cage.E2E.CageSpec qualified

-- | Run all E2E test specs.
main :: IO ()
main = hspec Cardano.MPFS.Cage.E2E.CageSpec.spec
