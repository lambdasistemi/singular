module Main (main) where

import Test.Hspec (describe, hspec)
import Test.Tags (Area (..), tagged)

import Singular.Registry.E2E.CageSpec qualified
import Singular.Registry.E2E.Config (resolveBlueprint)
import Singular.Registry.E2E.ConfigSpec qualified
import Singular.Registry.E2E.Criterion3Spec qualified
import Singular.Registry.E2E.DriverSpec qualified
import Singular.Registry.E2E.Fork81Spec qualified
import Singular.Registry.E2E.InsertActiveSpec qualified
import Singular.Registry.E2E.NodeSpec qualified
import Singular.Registry.E2E.OpenBootSpec qualified
import Singular.Registry.E2E.ReplaySpec qualified
import Singular.Registry.E2E.UpdateTerminalSpec qualified

-- | Run all end-to-end test specs.
main :: IO ()
main = do
    blueprint <- resolveBlueprint
    putStrLn "Evidence boundaries: each group names what it exercises."
    putStrLn
        "Compiled-script component checks are outside this suite; no result is claimed here."
    putStrLn
        "Pending examples are unexecuted; filtered-out examples provide no evidence."
    hspec $ do
        describe (tagged "Singular.Registry.E2E.Node" [E2e, Wallet, Provider]) $
            describe
                "Unit checks (local files, no node or script execution)"
                Singular.Registry.E2E.NodeSpec.walletSpec
        describe (tagged "Singular.Registry.E2E.OpenBoot" [E2e, Builders])
            $ describe
                "Devnet scenarios (compiled scripts, submitted transactions and refusals)"
            $ Singular.Registry.E2E.OpenBootSpec.spec blueprint
        describe (tagged "Singular.Registry.E2E.InsertActive" [E2e, Builders])
            $ describe
                "Devnet scenarios (compiled scripts, submitted transactions and refusals)"
            $ Singular.Registry.E2E.InsertActiveSpec.spec blueprint
        describe
            (tagged "Singular.Registry.E2E.Fork81" [E2e, History, Recovery])
            $ describe
                "Devnet scenarios (compiled scripts, submitted transactions and refusals)"
            $ Singular.Registry.E2E.Fork81Spec.spec blueprint
        describe
            (tagged "Singular.Registry.E2E.UpdateTerminal" [E2e, Builders])
            $ describe
                "Devnet scenarios (compiled scripts, submitted transactions and refusals)"
            $ Singular.Registry.E2E.UpdateTerminalSpec.spec blueprint
        describe (tagged "Singular.Registry.E2E.Criterion3" [E2e, Builders])
            $ describe
                "Devnet scenarios (compiled scripts, submitted transactions and refusals)"
            $ Singular.Registry.E2E.Criterion3Spec.spec blueprint
        describe (tagged "Singular.Registry.E2E.Cage" [E2e, Builders])
            $ describe
                "Devnet scenarios (compiled scripts, submitted transactions and refusals)"
            $ Singular.Registry.E2E.CageSpec.spec blueprint
        describe (tagged "Singular.Registry.E2E.Driver" [E2e, Builders])
            $ describe
                "Devnet scenarios (compiled scripts, submitted transactions and refusals)"
            $ Singular.Registry.E2E.DriverSpec.spec blueprint
        describe
            (tagged "Singular.Registry.E2E.Replay" [E2e, History, Recovery])
            $ describe
                "Devnet scenarios (compiled scripts, submitted transactions and refusals)"
            $ Singular.Registry.E2E.ReplaySpec.spec blueprint
        describe (tagged "Singular.Registry.E2E.Node" [E2e, Provider]) $
            describe
                "Live node checks (devnet queries, submission and connection refusals)"
                Singular.Registry.E2E.NodeSpec.spec
        describe
            (tagged "Singular.Registry.E2E.Config" [E2e, Builders])
            Singular.Registry.E2E.ConfigSpec.spec
