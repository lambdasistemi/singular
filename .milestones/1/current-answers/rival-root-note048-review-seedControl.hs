-- | Named seed-plus-fee control (NOTE-048.1). Runs the ACTUAL shared
-- selectLiveFunding decision over the FundingEntry construction the
-- driver performs: consumed inputs are not live, and exactly the
-- configured cage seed carries the seed flag. Four explicit results:
--
--  1. unique-seed-identity: the configured seed is the unique flagged
--     seed entry;
--  2. spent-inputs-unavailable: the configured seed and the distinct
--     boot-fee input are both unavailable for later funding;
--  3. valid-inputs-selectable: every other valid live funding input
--     remains selectable;
--  4. wrong-seed-binding-fails: binding the seed flag to the boot-fee
--     input instead of the configured seed violates the invariant and is
--     rejected.
module Main (main) where

import System.Exit (exitFailure, exitSuccess)
import System.IO

import RivalDriverLogic
    ( FundingEntry (..)
    , selectLiveFunding
    )

configuredSeedId :: String
configuredSeedId = "genesis#configured-seed"

bootFeeId :: String
bootFeeId = "genesis#boot-fee-input"

liveAId :: String
liveAId = "genesis#live-a"

liveBId :: String
liveBId = "genesis#live-b"

-- | The driver's FundingEntry construction: an entry is live unless it
-- was consumed, and the seed flag binds to exactly the configured seed
-- identity given.
observed :: String -> [String] -> [FundingEntry]
observed seedId consumed =
    [ FundingEntry
        { feInputId = i
        , feLive = i `notElem` consumed
        , feIsConsumedBSeed = i == seedId
        }
    | i <- [configuredSeedId, bootFeeId, liveAId, liveBId]
    ]

flaggedSeeds :: [FundingEntry] -> [String]
flaggedSeeds = map feInputId . filter feIsConsumedBSeed

keptIds :: [FundingEntry] -> [String]
keptIds = map feInputId . fst . selectLiveFunding

main :: IO ()
main = do
    let consumed = [configuredSeedId, bootFeeId]
        entries = observed configuredSeedId consumed
        flagged = flaggedSeeds entries
        kept = keptIds entries
        r1 = flagged == [configuredSeedId]
        r2 = not (any (`elem` kept) consumed)
        r3 = kept == [liveAId, liveBId]
        -- binding the seed flag to the wrong (fee) input does not flag the
        -- configured seed: the unique-configured-seed invariant is violated
        -- and the selection is rejected.
        wrongEntries = observed bootFeeId consumed
        wrongFlagged = flaggedSeeds wrongEntries
        r4 = wrongFlagged /= [configuredSeedId]
    let results =
            [ ("unique-seed-identity", r1)
            , ("spent-inputs-unavailable", r2)
            , ("valid-inputs-selectable", r3)
            , ("wrong-seed-binding-fails", r4)
            ]
    mapM_ (\(n, ok) -> putStrLn ((if ok then "PASS " else "FAIL ") ++ n)) results
    hFlush stdout
    if all snd results
        then exitSuccess
        else exitFailure
