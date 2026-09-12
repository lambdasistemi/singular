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
    RefusalRole (..),
    attributeRefusalReceipt,
    matchRefusal,
    refusalScriptHashes,
    refusalWritesReceipt,
    trimRefusal,
    wrongReasonMarker,
) where

import Conformance.Receipt (
    Outcome (..),
    Receipt (..),
    RefusalInfo (..),
    Verdict (..),
    writeReceiptFile,
 )
import Data.List (intercalate, isInfixOf, isPrefixOf, nub, sortOn)
import Data.Text qualified as T

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
out; every failed script hash in ledger order binds which scripts
ran, and the receipt already carries the blueprint hashes.
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
            , scriptHashes text
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

{- | Every @ScriptHash \"...\"@ value in the reason, ledger order,
first occurrence wins. A malformed transaction can trip two validators
in one submission and the ledger's failure-list order is not stable,
so attribution keeps them all: trim volume — the script binary, the
cost model, the whole context — never the identities that attribute
the refusal. Both shapes name hashes this way: the eval shape via
@pwcScriptHash@, the node-submit shape in its failure headers.
Unquoted ledger credentials never match this pattern.
-}
refusalScriptHashes :: String -> [String]
refusalScriptHashes text = nub (filter (not . null) (go text))
  where
    go s = case findAfter hashMarker s of
        Nothing -> []
        Just after ->
            let h = takeUntil hashEnd after
             in h : go (drop (length h + length hashEnd) after)
    hashMarker = "ScriptHash \\\""
    hashEnd = "\\\""

{- | The failed scripts' hashes joined as one @scriptHash=@ field.
-}
scriptHashes :: String -> Maybe String
scriptHashes text = case refusalScriptHashes text of
    [] -> Nothing
    hs -> Just ("scriptHash=" <> intercalate "," hs)

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

-- ====================================================================
-- Refusal receipts: who writes, and who must never overwrite (A-002)
--
-- The CG11/CG12/CG19 defect: a refused CONTROL submitted through the
-- same helper as a refusal ROW wrote its refusal under the row's id,
-- replacing the row's own held receipt in every receipts directory.
-- The receipts then asserted three held rows were refused — the exact
-- opposite of their executed findings. CG13's receipt survived only
-- because its control was retired before the final runs, which is
-- what isolated the cause.

-- | Whose refusal is being attributed: a refusal ROW's receipt IS
-- the row outcome and is written; a refused CONTROL's outcome is
-- run-log evidence under its own identity and must never overwrite
-- the row's receipt.
data RefusalRole = RefusalRow | RefusalControl
    deriving stock (Show, Eq)

{- | The receipt policy per role. A control keeps its evidence in the
run log and its failures loud — an accepted control fails the run as
a FINDING and a refusal that does not attribute fails the run naming
the mismatch — so writing nothing leaves it unable to pass silently,
while the row's held verdict survives its own control.
-}
refusalWritesReceipt :: RefusalRole -> Bool
refusalWritesReceipt role = case role of
    RefusalRow -> True
    -- The repair (A-002): a control's refusal is run-log evidence with
    -- its own identity. It cannot silently pass — an accepted control
    -- fails the run as a FINDING and a refusal that does not attribute
    -- fails the run naming the mismatch — so writing nothing leaves it
    -- fully evidenced while the row's held verdict survives its own
    -- control. Spec: RefusalSpec, "receipt policy (A-002)".
    RefusalControl -> False

{- | Attribute a node-submit refusal and, when the role's policy
writes, record the refused receipt under the row's id. Returns the
attribution mismatch for the caller to fail on loudly — this function
never swallows a refusal that does not attribute, and a control here
can never silently pass: acceptance and wrong-reason both fail the
run upstream of this call. The receipt carries the trimmed reason
(volume trimmed, never the script identities), the submitted
transaction's id under @rejected@, and the @node-submit@ venue.
-}
attributeRefusalReceipt ::
    RefusalRole ->
    -- | receipts directory (only touched when the policy writes)
    FilePath ->
    -- | row id
    String ->
    -- | verdict the receipt would carry
    Verdict ->
    -- | attributed script label
    String ->
    -- | expected marker (applied script hash hex)
    String ->
    -- | the node's refusal reason, verbatim
    String ->
    -- | the submitted transaction's id
    String ->
    -- | base commit
    String ->
    -- | dirty tree flag
    Bool ->
    -- | node identity
    String ->
    -- | blueprint identity
    String ->
    IO (Either RefusalMismatch ())
attributeRefusalReceipt role dir row verdict script marker text rejectedTxid base dirty node blueprint =
    case matchRefusal marker text of
        Left m -> pure (Left m)
        Right () -> do
            let recorded = recordedReason text marker
            if refusalWritesReceipt role
                then
                    writeReceiptFile
                        dir
                        Receipt
                            { receiptRow = T.pack row
                            , receiptOutcome = Refused
                            , receiptVerdict = verdict
                            , receiptTransactions = []
                            , receiptRefusal =
                                Just
                                    ( RefusalInfo
                                        { refusalScript = T.pack script
                                        , refusalReason = T.pack recorded
                                        }
                                    )
                            , receiptMem = Nothing
                            , receiptCpu = Nothing
                            , receiptTxSize = Nothing
                            , receiptBase = T.pack base
                            , receiptNode = T.pack node
                            , receiptBlueprint = T.pack blueprint
                            , receiptVenue = "node-submit"
                            , receiptRejected = Just (T.pack rejectedTxid)
                            , receiptDirty = dirty
                            }
            else pure ()
            pure (Right ())

{- | The reason a receipt records: trimmed to what attributes, but
kept wide enough that the expected marker survives — a trimmer that
keeps one hash can drop ours when several failed. This is the
Run.hs policy moved beside the write it feeds.
-}
recordedReason :: String -> String -> String
recordedReason text marker =
    let trimmed = trimRefusal text
     in if marker `isInfixOf` trimmed then trimmed else take 2000 text
