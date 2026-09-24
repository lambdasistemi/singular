{- | Bounded node diagnostics retain failure constructors and CEK causes.
Script binaries, serialized contexts and cost models are not explanations.
Attribution still uses the original node text; this module only renders it.
-}
module Conformance.NodeRejection (boundedNodeReason) where

import Data.Char (isAlphaNum)
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as T

-- | Select the failure path and each machine error before applying the bound.
-- Both literal and Show-escaped newlines occur in node/evaluator diagnostics.
-- Trace lines take priority over the machine's generic explanatory prose.
boundedNodeReason :: Int -> Text -> Text
boundedNodeReason limit original
    | null causes = clip limit (oneLine (elidePayload text))
    | otherwise = clip limit (T.intercalate " | " (path : map (clip causeLimit) causes))
  where
    text = T.replace "\\n" "\n" (T.replace "\\\\n" "\n" original)
    causes = nub (map machineCause (drop 1 (T.splitOn "CekError " text)))
    header = beforeAny ["The PlutusV3 script failed:", "CekError "] text
    constructors = filter isFailure (T.split (not . isAlphaNum) header)
    isFailure word = any (`T.isSuffixOf` word) ["Failure", "Error"]
        && word `notElem` ["ConwayApplyTxError"]
        || word `elem` ["ValidationTagMismatch", "FailedUnexpectedly"]
    path = clip (min 120 (max 0 limit `div` 2)) (T.intercalate "/" (nub constructors))
    causeLimit = max 0 ((limit - T.length path - 3 * length causes) `div` max 1 (length causes))

machineCause :: Text -> Text
machineCause raw = "CekError: " <> oneLine detail
  where
    body = beforeAny ["The protocol version is:", "ScriptInfo:", ") []", "PlutusWithContext"] raw
    linesOfCause = map T.strip (T.lines body)
    named = filter (T.isPrefixOf "Caused by:") linesOfCause
    traces = filter (\line -> any (`T.isPrefixOf` line) ["Trace:", "Logs:"]) linesOfCause
    detail = case named <> traces of
        [] -> beforeAny ["The budget when", "Negative numbers indicate"]
            (T.replace "An error has occurred:" "" body)
        selected -> T.intercalate " | " selected

-- | Unknown/phase-1 diagnostics retain their text, but never an embedded blob.
elidePayload :: Text -> Text
elidePayload text = case T.breakOn "Base64-encoded script bytes:" text of
    (prefix, rest) | not (T.null rest) ->
        prefix <> "[script bytes elided] " <>
            case T.breakOn "The script hash is:" rest of
                (_, suffix) | not (T.null suffix) -> elidePayload suffix
                _ -> ""
    _ -> beforeAny ["PlutusWithContext", "ScriptInfo:", "plutusBinary", "pwcCostModel"] text

beforeAny :: [Text] -> Text -> Text
beforeAny markers text = foldl (\body marker -> fst (T.breakOn marker body)) text markers

oneLine :: Text -> Text
oneLine = T.unwords . T.words

clip :: Int -> Text -> Text
clip limit text
    | limit <= 0 = ""
    | T.length text <= limit = text
    | otherwise = T.take (limit - 1) text <> "…"
