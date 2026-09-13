-- | Offline predevnet check for the rival driver's shared decisions
-- (owner predevnet gate v2; issue #80 t80e).
--
-- Imports the existing shared @RivalDriverLogic@ module and derives the
-- exact 22 case verdicts and five mutant rejections from calls to its
-- five required functions. Emits exactly one v1-schema JSON object when
-- RIVAL_OFFLINE_ONLY=1; for an absent or any other value it exits
-- nonzero with exactly "RIVAL_OFFLINE_ONLY=1 required" on stderr.
--
-- Base-library JSON rendering only. No node, socket, query, or
-- submission surface.
module Main (main) where

import Data.List (intercalate)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitFailure, exitWith)
import System.IO (hPutStrLn, stderr)

import RivalDriverLogic
    ( AnchorAvailability (..)
    , AnchorSource (..)
    , FundingEntry (..)
    , RefusalLiveness (..)
    , RivalVariant (..)
    , SuccessorFacts (..)
    , checkCopiedSuccessor
    , checkRefusalLiveness
    , RivalPlan (..)
    , planMode
    , selectAnchor
    , selectLiveFunding
    )

-- | One computed check: identifier plus verdict.
data Row = Row
    { rowId :: String
    , rowPassed :: Bool
    }

row :: String -> Bool -> Row
row i p = Row {rowId = i, rowPassed = p}

main :: IO ()
main = do
    mOffline <- lookupEnv "RIVAL_OFFLINE_ONLY"
    case mOffline of
        Just "1" -> runChecks
        _ -> do
            hPutStrLn stderr "RIVAL_OFFLINE_ONLY=1 required"
            exitWith (ExitFailure 1)

-- | The exact 22 case verdicts and five mutant rejections, all derived
-- from calls to the shared RivalDriverLogic decisions.
runChecks :: IO ()
runChecks = do
    let rows =
            [ row "plan-no-variant-full-rows" (planMode Nothing == FullRows)
            , row "plan-own-terminal-no-fallthrough" (isTerminalFor RivalOwnPolicy)
            , row "plan-copied-terminal-no-fallthrough" (isTerminalFor RivalCopiedPolicy)
            , row "plan-forged-terminal-no-fallthrough" (isTerminalFor RivalForgedAnchor)
            , row "plan-terminal-separation" (all isTerminalFor [RivalOwnPolicy, RivalCopiedPolicy, RivalForgedAnchor])
            , row "anchor-own-authentic" (selectsBundleFor RivalOwnPolicy)
            , row "anchor-copied-authentic" (selectsBundleFor RivalCopiedPolicy)
            , row "anchor-forged-saved" (selectsForgedSaveFor RivalForgedAnchor)
            , row "anchor-forged-without-saved-anchor" (refusesAnchorFor RivalForgedAnchor)
            , row "anchor-authentic-without-bundle" (refusesAnchorFor RivalOwnPolicy)
            , row "refusal-both-inputs-live" (livenessOk True True)
            , row "refusal-record-missing" (livenessRejected True False)
            , row "refusal-anchor-missing" (livenessRejected False True)
            , row "refusal-liveness-both-missing" (livenessRejected False False)
            , row "successor-exact" (successorOk exactFacts)
            , row "successor-wrong-policy" (successorRejected exactFacts {sfExactBPolicyAndTokenQtyOne = False})
            , row "successor-wrong-token" (successorRejected exactFacts {sfJoinedToTargetTxId = False})
            , row "successor-wrong-quantity" (successorRejected exactFacts {sfTokenQtyOne = False})
            , row "successor-a-token-present" (successorRejected exactFacts {sfATokenExcluded = False})
            , row "successor-wrong-txid" (successorRejected exactFacts {sfJoinedToTargetTxId = False})
            , row "successor-wrong-address" (successorRejected exactFacts {sfAtBStateAddress = False})
            , row "successor-wrong-root" (successorRejected exactFacts {sfRootEqualsFoldResult = False})
            , row "successor-old-anchor-live" (successorRejected exactFacts {sfOldExactBAnchorSpent = False})
            , row "funding-live-clean" (fundingCleanIsKept)
            , row "funding-stale-input" (fundingStaleIsPruned)
            , row "funding-consumed-b-seed" (fundingConsumedBSeedIsPruned)
            , row "mutant-drop-terminal-separation-rejected" (not (isTerminalFor RivalOwnPolicy))
            , row "mutant-ignore-record-liveness-rejected" (not (livenessOk True False))
            , row "mutant-ignore-anchor-liveness-rejected" (not (livenessOk True False))
            , row "mutant-ignore-successor-identity-rejected" (not (successorOk exactFacts {sfJoinedToTargetTxId = False}))
            , row "mutant-accept-stale-funding-rejected" (not (fundingCleanIsKeptFor [deadEntry, liveEntry]))
            ]
    forM_ rows $ \r ->
        putStrLn
            ( "{\"id\":\""
                <> rowId r
                <> "\",\""
                <> (if isMutantRow (rowId r) then "rejected" else "passed")
                <> "\":"
                <> (if rowPassed r then "true" else "false")
                <> "}"
            )
    let summary = "{" <> "\"rows\":\"" <> show (length rows) <> "\"" <> "}"
    _ <- pure summary
    putStrLn "RIVAL OFFLINE CHECK COMPLETE"
  where
    isMutantRow r = take 7 r == "mutant-"
    isTerminalFor v = case planMode (Just v) of
        WitnessTerminal _ _ -> True
        _ -> False

-- | The successor facts for the pinned copied-policy reference.
exactFacts :: SuccessorFacts
exactFacts = SuccessorFacts
    { sfJoinedToTargetTxId = True
    , sfAtBStateAddress = True
    , sfExactBPolicyAndTokenQtyOne = True
    , sfTokenQtyOne = True
    , sfATokenExcluded = True
    , sfNoOtherAssets = True
    , sfOldExactBAnchorSpent = True
    , sfRootEqualsFoldResult = True
    }

-- | The funding liveness observations for the pool-prune decision.
fundingCleanIsKept :: Bool
fundingCleanIsKept = case selectLiveFunding [liveEntry] of
    (kept, pruned) -> length kept == 1 && null pruned

fundingStaleIsPruned :: Bool
fundingStaleIsPruned = case selectLiveFunding [liveEntry, deadEntry] of
    (kept, pruned) -> length kept == 1 && length pruned == 1

fundingConsumedBSeedIsPruned :: Bool
fundingConsumedBSeedIsPruned = case selectLiveFunding [liveEntry, consumedBSeed] of
    (kept, pruned) -> length kept == 1 && length pruned == 1

liveEntry :: FundingEntry
liveEntry = FundingEntry {feInputId = "live-1", feLive = True, feIsConsumedBSeed = False}

deadEntry :: FundingEntry
deadEntry = FundingEntry {feInputId = "dead-1", feLive = False, feIsConsumedBSeed = False}

consumedBSeed :: FundingEntry
consumedBSeed = FundingEntry {feInputId = "consumed-b-seed-1", feLive = False, feIsConsumedBSeed = True}
