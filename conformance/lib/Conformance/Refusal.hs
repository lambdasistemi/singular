{- |
Module      : Conformance.Refusal
Description : Phase-2 refusal attribution for refused rows
License     : Apache-2.0

A refusal closes a refuse-row only when it is attributable: the node
must have refused in phase 2 (@PlutusFailure@) naming the script that
refused (@marker@, the applied script hash hex). A phase-1 refusal
proves nothing about the binding, and a reason that does not name the
script proves nothing about which guard held. This is the #41
discipline as @offchain\/journey\/li-refusals\/Main.hs@ applies it.

'wrongReasonMarker' arms the negative control: matched against a
marker no node reason can ever contain, the matcher must fail naming
what came back (@CONFORMANCE_CONTROL=wrong-reason@).
-}
module Conformance.Refusal (
    RefusalMismatch (..),
    matchRefusal,
    trimRefusal,
    wrongReasonMarker,
) where

import Data.List (intercalate, isInfixOf, isPrefixOf, sortOn)

-- | How a refusal failed to attribute.
data RefusalMismatch
    = {- | The node refused outside phase 2: proves nothing about the
      script binding.
      -}
      NotPhase2
        { refusalReason :: String
        }
    | -- | The reason does not name the expected script.
      MarkerAbsent
        { refusalMarker :: String
        , refusalReason :: String
        }
    deriving stock (Show, Eq)

{- | Require @reason@ to be a phase-2 script failure naming @marker@.
@marker@ is the applied refusing script's hash hex; @reason@ is the
node's refusal text verbatim.

Two vocabularies, one discipline. At submit the node speaks
@PlutusFailure@ (the li-refusals precedent). At build evaluation
the DSL reports the node's per-purpose failure, whose text speaks
@CekError@: the CEK machine executed the script and it errored.
Both are the node's word for script-execution failure, never for a
phase-1 ledger refusal — and both must name the script.
-}
matchRefusal :: String -> String -> Either RefusalMismatch ()
matchRefusal marker reason
    | not (isPhase2 reason) =
        Left (NotPhase2 reason)
    | not (marker `isInfixOf` reason) =
        Left (MarkerAbsent marker reason)
    | otherwise = Right ()

-- | The node's word for "a script executed and failed".
isPhase2 :: String -> Bool
isPhase2 reason =
    "PlutusFailure" `isInfixOf` reason
        || "CekError" `isInfixOf` reason

{- | Keep the parts that attribute a refusal and drop the rest.
@show@ on an evaluation context embeds the whole compiled validator
(~30KB of base64) plus the cost model and script context; a receipt
carrying that is unreadable. Kept: the failure class and redeemer
pointer, the failed script hash, the CEK error. Everything else —
@plutusBinary@, @pwcCostModel@, the full @ScriptContext@ — comes
out; the script hash already binds which script ran, and the
receipt already carries the blueprint hashes.
-}
trimRefusal :: String -> String
trimRefusal text =
    case parts of
        [] -> take 500 text <> " [unparsed]"
        _ -> take 2000 (intercalate " | " parts)
  where
    parts =
        [ part
        | Just part <-
            [ evalHead text
            , plutusFailed text
            , scriptHash text
            , cekError text
            ]
        ]

-- | Up to the node's validation report: failure class and purpose.
evalHead :: String -> Maybe String
evalHead text
    | "\\\"ValidationFailure" `isInfixOf` text =
        Just (takeUntil "\\\"ValidationFailure" text)
    | otherwise = Nothing

-- | The node's verdict phrase for a submitted script failure.
plutusFailed :: String -> Maybe String
plutusFailed text
    | "The PlutusV3 script failed" `isInfixOf` text =
        Just "PlutusV3 script failed (node-submit)"
    | otherwise = Nothing

{- | The failed script's hash. Both shapes name it as
@ScriptHash \"...\"@: the eval shape via @pwcScriptHash@, the
node-submit shape bare.
-}
scriptHash :: String -> Maybe String
scriptHash text = do
    after <- findAfter "ScriptHash \\\"" text
    pure ("scriptHash=" <> takeUntil "\\\"" after)

{- | The machine error, capped: the cause, not the context. Ends at
the eval shape's context close or the node shape's protocol
version line, whichever is nearer.
-}
cekError :: String -> Maybe String
cekError text = do
    after <- findAfter "CekError " text
    pure ("cek=" <> take 500 (takeUntilAny [") []", "\\nThe protocol version is:"] after))

-- | Text after the first occurrence of a marker.
findAfter :: String -> String -> Maybe String
findAfter marker text =
    case dropUntil marker text of
        [] -> Nothing
        rest -> Just (drop (length marker) rest)
  where
    dropUntil _ [] = []
    dropUntil m s@(_ : cs)
        | m `isPrefixOf` s = s
        | otherwise = dropUntil m cs

-- | Text up to the first occurrence of an end marker.
takeUntil :: String -> String -> String
takeUntil end text =
    case dropUntil end text of
        [] -> text
        rest -> take (length text - length rest) text
  where
    dropUntil _ [] = []
    dropUntil m s@(_ : cs)
        | m `isPrefixOf` s = s
        | otherwise = dropUntil m cs

{- | Text up to the nearest of several end markers; the whole text
when none occurs.
-}
takeUntilAny :: [String] -> String -> String
takeUntilAny ends text =
    case sortOn length [takeUntil e text | e <- ends, e `isInfixOf` text] of
        [] -> text
        (shortest : _) -> shortest

{- | The marker the wrong-reason control matches refusals against: by
construction no node reason can contain it, so a matched reason can
never close a row and the control must fail.
-}
wrongReasonMarker :: String
wrongReasonMarker =
    "wrong-reason-control marker that no node reason can ever contain"
