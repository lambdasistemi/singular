module Main (main) where

import Test.Hspec (describe, hspec)

import Singular.Registry.E2E.CageSpec qualified
import Singular.Registry.E2E.Config (resolveBlueprint)
import Singular.Registry.E2E.ConfigSpec qualified
import Singular.Registry.E2E.DriverSpec qualified
import Singular.Registry.E2E.Fork81Spec qualified
import Singular.Registry.E2E.InsertActiveSpec qualified
import Singular.Registry.E2E.NodeSpec qualified
import Singular.Registry.E2E.OpenBootSpec qualified
import Singular.Registry.E2E.UpdateTerminalSpec qualified

-- | Run all E2E test specs.
main :: IO ()
main = do
    blueprint <- resolveBlueprint
    putStrLn "Evidence boundaries: each group names what it exercises."
    putStrLn "Compiled-script component checks are outside this suite; no result is claimed here."
    putStrLn "Pending examples are unexecuted; filtered-out examples provide no evidence."
    hspec $ do
        describe
            "Unit checks (local files, no node or script execution)"
            Singular.Registry.E2E.NodeSpec.walletSpec
        describe "Devnet scenarios (compiled scripts, submitted transactions and refusals)" $ do
            Singular.Registry.E2E.OpenBootSpec.spec blueprint
            Singular.Registry.E2E.InsertActiveSpec.spec blueprint
            Singular.Registry.E2E.Fork81Spec.spec blueprint
            Singular.Registry.E2E.UpdateTerminalSpec.spec blueprint
            Singular.Registry.E2E.CageSpec.spec blueprint
            Singular.Registry.E2E.DriverSpec.spec blueprint
        describe
            "Live node checks (devnet queries, submission and connection refusals)"
            Singular.Registry.E2E.NodeSpec.spec
        Singular.Registry.E2E.ConfigSpec.spec
