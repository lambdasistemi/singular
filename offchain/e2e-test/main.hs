module Main (main) where

import Test.Hspec (hspec)

import Singular.Registry.E2E.CageSpec qualified
import Singular.Registry.E2E.DriverSpec qualified
import Singular.Registry.E2E.Fork81Spec qualified
import Singular.Registry.E2E.InsertActiveSpec qualified
import Singular.Registry.E2E.NodeSpec qualified
import Singular.Registry.E2E.OpenBootSpec qualified
import Singular.Registry.E2E.UpdateTerminalSpec qualified

-- | Run all E2E test specs.
main :: IO ()
main =
    hspec $ do
        Singular.Registry.E2E.CageSpec.spec
        Singular.Registry.E2E.DriverSpec.spec
        Singular.Registry.E2E.Fork81Spec.spec
        Singular.Registry.E2E.NodeSpec.spec
        Singular.Registry.E2E.OpenBootSpec.spec
        Singular.Registry.E2E.InsertActiveSpec.spec
        Singular.Registry.E2E.UpdateTerminalSpec.spec
