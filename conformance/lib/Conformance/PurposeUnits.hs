{- | Per-purpose evaluation and declaration arithmetic. Failed evaluations
carry errors, never fabricated measurements.
-}
module Conformance.PurposeUnits (
    PurposeUnits,
    PurposeMeasurements,
    doublePurposeUnits,
    fallbackBelowMaximum,
    maximumPurposeUnits,
    missingPurposeBudgets,
    overBudgetPurposes,
    allocatePurposeUnits,
    protocolUnitsCeiling,
    budgetRefusalPurposes,
) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Conformance.Refusal (refusalScriptHashes)

type PurposeUnits = Map Text (Integer, Integer)

type PurposeMeasurements = Map Text (Either Text (Integer, Integer))

-- | Double successful evaluations. Failed evaluations retain the existing
-- live harness fallback (1% memory / 5% CPU of the transaction maximum),
-- explicitly as a probe rather than a fabricated measurement. The complete
-- declaration must fit both transaction and block limits.
allocatePurposeUnits :: (Integer, Integer) -> (Integer, Integer) -> PurposeMeasurements -> Either Text PurposeUnits
allocatePurposeUnits transactionLimit@(txMem, txCpu) blockLimit measured
    | Map.null measured = Left "node evaluation returned no purposes"
    | usedMem > maxMem || usedCpu > maxCpu = Left ("harness refusal: per-purpose declarations exceed transaction/block execution-unit ceiling (mem=" <> T.pack (show maxMem) <> ", cpu=" <> T.pack (show maxCpu) <> ")")
    | otherwise = Right declarations
  where
    (maxMem, maxCpu) = protocolUnitsCeiling transactionLimit blockLimit
    doubled = doublePurposeUnits (Map.mapMaybe (either (const Nothing) Just) measured)
    failures = Map.mapMaybe (either (const (Just ())) (const Nothing)) measured
    declarations = Map.union doubled probes
    usedMem = sum (map fst (Map.elems declarations))
    usedCpu = sum (map snd (Map.elems declarations))
    probes = Map.map (const (txMem `div` 100, txCpu `div` 20)) failures

-- | A submitted transaction must fit both per-transaction and per-block limits.
protocolUnitsCeiling :: (Integer, Integer) -> (Integer, Integer) -> (Integer, Integer)
protocolUnitsCeiling (txMem, txCpu) (blockMem, blockCpu) =
    (min txMem blockMem, min txCpu blockCpu)

-- | Attribute only node-reported budget failures to their script purposes.
-- Each failure section must itself contain both the budget error and hash;
-- a different script's failure in the same report cannot supply either.
budgetRefusalPurposes :: Map Text Text -> Text -> [Text]
budgetRefusalPurposes hashes reason =
    [ purpose
    | (purpose, scriptHash) <- Map.toList hashes
    , scriptHash `elem` budgetHashes
    ]
  where
    budgetHashes =
        [ T.pack scriptHash
        | failure <- drop 1 (T.splitOn "The PlutusV3 script failed:" reason)
        , "overspending the budget" `T.isInfixOf` failure
        , scriptHash <- refusalScriptHashes (T.unpack failure)
        ]

-- | The componentwise maximum across the script-purpose evaluation map.
maximumPurposeUnits :: PurposeUnits -> Maybe (Integer, Integer)
maximumPurposeUnits purposes
    | Map.null purposes = Nothing
    | otherwise =
        Just
            ( maximum [mem | (mem, _) <- Map.elems purposes]
            , maximum [cpu | (_, cpu) <- Map.elems purposes]
            )

-- | A fixture budget one unit below each component of the measured maximum.
fallbackBelowMaximum :: PurposeUnits -> Maybe (Integer, Integer)
fallbackBelowMaximum purposes = do
    (mem, cpu) <- maximumPurposeUnits purposes
    if mem > 0 && cpu > 0
        then Just (mem - 1, cpu - 1)
        else Nothing

-- | Preserve each purpose's own measured pair when applying the 2x headroom.
doublePurposeUnits :: PurposeUnits -> PurposeUnits
doublePurposeUnits = Map.map (\(mem, cpu) -> (2 * mem, 2 * cpu))

missingPurposeBudgets :: PurposeUnits -> PurposeUnits -> [Text]
missingPurposeBudgets measured declared =
    Map.keys (measured `Map.difference` declared)

overBudgetPurposes :: PurposeUnits -> PurposeUnits -> [Text]
overBudgetPurposes measured declared =
    [ purpose
    | (purpose, (measuredMem, measuredCpu)) <- Map.toList measured
    , Just (declaredMem, declaredCpu) <- [Map.lookup purpose declared]
    , measuredMem > declaredMem || measuredCpu > declaredCpu
    ]
