module Main (main) where

import Test.Hspec (hspec)

import Singular.Registry.E2E.CageSpec qualified
import Singular.Registry.E2E.FoldAllSpec qualified
import Singular.Registry.E2E.Fork81Spec qualified
import Singular.Registry.E2E.NodeSpec qualified

-- | Run all E2E test specs.
main :: IO ()
main =
    hspec $ do
        Singular.Registry.E2E.CageSpec.spec
        Singular.Registry.E2E.FoldAllSpec.spec
        Singular.Registry.E2E.Fork81Spec.spec
        Singular.Registry.E2E.NodeSpec.spec
