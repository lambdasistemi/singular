module Main (main) where

import Test.Hspec (describe, hspec)
import Test.Tags (Area (..), Lane (..), lane, tagged)

import Singular.Registry.E2E.NodeSpec qualified
import Singular.Registry.E2E.SubmitSpec qualified

-- | Generic node, wallet and submission checks.
main :: IO ()
main = do
    putStrLn "Evidence boundaries: each group names what it exercises."
    putStrLn
        "Pending examples are unexecuted; filtered-out examples provide no evidence."
    hspec $ do
        describe (lane NodeBoot) $ do
            describe (tagged "Singular.Registry.E2E.Node" [E2e, Wallet, Provider]) $
                describe
                    "Unit checks (local files, no node or script execution)"
                    Singular.Registry.E2E.NodeSpec.walletSpec
            describe
                (tagged "Singular.Registry.E2E.Node" [E2e, Provider])
                $ describe
                    "Live node checks (devnet queries, submission and connection refusals)"
                    Singular.Registry.E2E.NodeSpec.spec
            describe (tagged "Singular.Registry.E2E.Submit" [E2e, Submit]) $
                describe
                    "Devnet scenarios (submitted transactions and refusals)"
                    Singular.Registry.E2E.SubmitSpec.spec
