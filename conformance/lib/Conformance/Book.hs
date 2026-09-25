-- | A book rendered from the same programs the live backend executes.
module Conformance.Book (renderBook) where

import Data.Foldable (toList)
import Data.List (intercalate)
import Data.Text qualified as T
import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KM
import Conformance.Edge.Exit qualified as Exit
import Conformance.Edge.Register qualified as Register
import Conformance.Edge.Retire qualified as Retire
import Conformance.Edge.RetractionWindow qualified as RetractionWindow
import Conformance.Edge.Sequence qualified as Sequence
import Conformance.Story.Live (Context (..), renderLive)
import Conformance.Rows (Row (..), RowState (..))
import Conformance.Receipt (Receipt (..))

-- | Called only after both live stories and their observations have succeeded.
renderBook :: [Row] -> [Receipt] -> String
renderBook requirements receipts =
    "# The running registry book\n\n"
        <> "These are executable stories. The runner supplies fresh registry and wallet contexts; the stories submit real transactions to a local Cardano devnet and check what happened. The same story programs supply the steps printed below.\n\n"
        <> "## This run\n\n"
        <> concatMap result receipts
        <> "## Register a key and receive its active token\n\n"
        <> "A requester submits two distinct active registrations and then repeats one key. The delivery is then sent to another address, and paid one lovelace short, beside the same untampered request. Every step is compared with the executable registry model.\n\n"
        <> renderLive (Register.story (Context "registration" "recipient wallet"))
        <> "## Retire a registration and burn its active token\n\n"
        <> "The holder first registers a key in this run. Retirement must consume and burn that very token and change the key to Terminal. A never-registered key and a key recorded as Absent must be refused, each beside a successful retirement in the same registry. A deletion then owes its owner the deposit back: paid one lovelace short, and paid to another address, it must be refused beside the untampered deletion.\n\n"
        <> renderLive (Retire.story (Context "retirement" "holder wallet") (Context "comparison" "holder wallet"))
        <> "## A request that is never folded\n\n"
        <> "A request can leave the queue without a fold. Once it may no longer be folded, a folder rejects it and must refund its owner the deposit, keeping the tip; while it is still retractable, its owner retracts it and must get back everything it held, deposit and tip, through an output whose inline datum is the retracted request's own output reference. Each refund paid one lovelace short or to another address, a return bound to another request, and a retraction spending the registry's state beside it must be refused, each beside the untampered exit of the same request.\n\n"
        <> renderLive (Exit.story (Context "rejection" "holder wallet") (Context "retraction" "holder wallet"))
        <> "## Retract only inside phase 2\n\n"
        <> "Two insertion requests from the same owner are booked in one registry before either exits. The first is retracted before phase 2, then inside it; the second is retracted after its window closes. Both outside-window retractions must be refused, and the in-window retraction must be accepted. The second request shares the first's accepting control: once its own window is over it cannot have an in-window retry. The registry allows thirty seconds for processing and thirty more for retraction; waits follow each request's recorded submission time.\n\n"
        <> renderLive (RetractionWindow.story (Context "retraction window" "owner wallet"))
        <> "## A sequence no chapter names\n\n"
        <> "This program uses the same live interpreter for each listed request. Each step records its own model and chain outcome; any unsupported result carries the reason observed at the booking or fold boundary.\n\n"
        <> renderLive (Sequence.story (Context "sequence" "holder wallet"))
        <> "## What these runs do not establish\n\n"
        <> "Every declared observation of an accepted request in the running chapters is compared with the model: configuration, custody, held tokens, leaf, mint, payments, root, the resulting state and the transaction. Output minimum ada remains a named unobservable. The transaction's required signers are compared: the model requires none for a fold and the owner for a retraction, and the comparison reads them from the submitted transaction. The two-request batch allocation has no driver comparison: the driver evaluates one request per transaction, leaving Singular.Statements.fold_batch_claimed_mint_by_kind_key without this executable consumer. For any step whose receipt reports unsupported, no acceptance or refusal of a completed chain fold is established; the observed reasons are published in the appendix. The Absent retirement probe reaches the state script only after omitting an unfunded burn: the builder cannot fund burning a token that does not exist. Its refusal does not establish how a transaction with that burn would behave. The model admits a retraction only when the pending request inserts a key or reads a terminal one, its owner is among the transaction's required signers, and its validity interval lies inside phase 2. The interval starts no earlier than submission plus the processing time; its excluded upper bound may reach, but not pass, the end of the retraction time that follows. The model represents only finite validity bounds. Open validity intervals remain a named gap: the Aiken tests establish their not-phase2 refusal, but no live model comparison can represent them. Live refusal reason not observed: the deployed validators are compiled without traces; the same-reason claim is checked against the compiled Aiken suite. Tracked by #287. These examples exercise one local devnet and one protocol-parameter set; they do not establish every reachable state, every theorem consumer, or naming-application behavior beyond the observed approval.\n\n"
        <> "## Requirements inventory\n\n"
        <> "The descriptions and planned statuses below are preserved from the committed inventory. The transaction evidence above belongs to this particular run; it does not rewrite planned statuses or discharge unrelated requirements.\n\n"
        <> concatMap requirement requirements
        <> "## Appendix: checking the evidence machinery\n\n"
        <> "The report-validation tests remain under `test/Conformance/Support`. They check missing and contradictory evidence, report parsing and preservation, and refusal attribution. They run alongside the live stories but do not replace them. Authentication tests are still compiled but unwired, tracked in #210.\n\n"
        <> concatMap gapEvidence receipts
        <> "The generated book is committed to the repository and is not yet reachable from the documentation site, tracked as #218. The general census of Haskell specification bindings remains tracked in #213.\n"
  where
    result receipt =
        "Code revision: `" <> T.unpack (receiptBase receipt) <> "`"
            <> (if receiptDirty receipt then " (working tree had changes)." else " (clean working tree).") <> "\n\n"
            <> "Node: `" <> T.unpack (receiptNode receipt) <> "`. Compiled validators: `"
            <> T.unpack (receiptBlueprint receipt) <> "`.\n\n"
            <> maybe "" (\steps -> case receiptRow receipt of
                "CG21" -> "Registration compared " <> outcomeCounts steps <> concatMap detection steps
                    <> concatMap refusedPayment steps
                "CG22" -> "Retirement compared " <> outcomeCounts steps <> concatMap refusedPayment steps
                "CG23" -> "Rejection and retraction compared " <> outcomeCounts steps
                    <> concatMap refusedPayment steps
                    <> admissionEvidence steps
                "CG07" -> "Retraction window compared " <> outcomeCounts steps
                    <> windowEvidence steps
                "sequence" -> "Unnamed sequence compared " <> outcomeCounts steps
                _ -> "") (receiptSteps receipt)
    requirement row = "### " <> T.unpack (rowRequirement row) <> "\n\nExpected: "
        <> T.unpack (rowExpected row) <> ". Planned evidence status: " <> stateName (rowState row)
        <> ".\n\nSource: " <> T.unpack (rowSource row) <> ".\n\n"
        <> maybe "" (\e -> "Existing evidence: " <> T.unpack e <> "\n\n") (rowEvidence row)
    stateName Uncovered = "uncovered"
    stateName BoundElsewhere = "bound elsewhere"
    stateName OutOfScope = "outside the registry's scope"
    hasOutcome expected value = case value of
        Object fields -> case KM.lookup "chain" fields of
            Just (Object chain) -> KM.lookup "outcome" chain == Just (String expected)
            _ -> False
        _ -> False
    outcomeCounts steps = show (length steps) <> " requests: "
        <> show (length (filter (hasOutcome "accepted") steps)) <> " accepted and "
        <> show (length (filter (hasOutcome "refused") steps)) <> " refused on chain.\n\n"
        <> "Unsupported chain folds: " <> show (length (filter (hasOutcome "unsupported") steps)) <> ".\n\n"
    -- A tamper the ledger accepted, and the difference the comparison detected
    -- in the transaction it built: read from the step, never typed here.
    detection value = case value of
        Object fields -> case (KM.lookup "tamper" fields, KM.lookup "comparison" fields
                              , KM.lookup "differences" fields, KM.lookup "chain" fields) of
            (Just (String name), Just (String "agrees"), Just (Array differences), Just (Object chain))
                | not (null differences)
                , Just (String "accepted") <- KM.lookup "outcome" chain
                , Just (String txid) <- KM.lookup "txid" chain ->
                    "The " <> T.unpack name <> " registration was accepted on chain (transaction `"
                        <> T.unpack txid <> "`); the comparison detected the difference at "
                        <> intercalate ", " [ "`" <> T.unpack observation <> "." <> T.unpack path <> "`"
                                            | Object difference <- toList differences
                                            , Just (String observation) <- [KM.lookup "observation" difference]
                                            , Just (String path) <- [KM.lookup "path" difference] ]
                        <> ".\n\n"
            _ -> ""
        _ -> ""
    -- A tampered payment both sides refused, and the reason the model gave:
    -- read from the step, never typed here.
    refusedPayment value = case value of
        Object fields -> case (KM.lookup "tamper" fields, KM.lookup "comparison" fields
                              , KM.lookup "edge" fields, KM.lookup "model" fields, KM.lookup "chain" fields) of
            (Just (String name), Just (String "agrees"), Just (String edge), Just (Object model), Just (Object chain))
                | Just (String "refused") <- KM.lookup "outcome" chain
                , Just (String reason) <- KM.lookup "reason" model
                , Just (String txid) <- KM.lookup "txid" chain ->
                    "The " <> T.unpack name <> " " <> exitOf fields edge <> " was refused on chain (transaction `"
                        <> T.unpack txid <> "`); the model refused it for `" <> T.unpack reason <> "`.\n\n"
            _ -> ""
        _ -> ""
    -- A fold is named by its edge; a reject or a retraction by its exit and the
    -- edge its request named.
    exitOf fields edge = case KM.lookup "exit" fields of
        Just (String exit) | exit `elem` ["reject", "retract"] -> T.unpack exit <> " of " <> T.unpack edge
        _ -> T.unpack edge
    -- Publish the admission run only with both attributed refusals and their
    -- signed insertion control. Missing evidence never becomes a run claim.
    admissionEvidence steps = case
        [ (unsigned, update, control)
        | unsigned <- steps
        , refuses ["insertAbsent", "insertActive"] (String "unsigned") "retract-owner" unsigned
        , ownerSigned unsigned == Just False
        , update <- steps
        , refuses ["updateActive", "updateTerminal"] Null "withdraw-insert-only" update
        , ownerSigned update == Just True
        , same ["registry"] unsigned update
        , control <- steps
        , retraction control
        , at ["tamper"] control == Just Null
        , at ["model", "outcome"] control == Just (String "accepted")
        , at ["chain", "outcome"] control == Just (String "accepted")
        , ownerSigned control == Just True
        , same ["registry"] unsigned control
        , same ["request"] unsigned control
        , same ["edge"] unsigned control
        ] of
            (unsigned, update, control) : _ ->
                "The exit chapter compared both admission refusals: the unsigned insertion retraction (transaction `"
                    <> textAt ["chain", "txid"] unsigned <> "`) was refused by the model for `"
                    <> textAt ["model", "reason"] unsigned
                    <> "`, and the pending update retraction (transaction `"
                    <> textAt ["chain", "txid"] update <> "`) for `"
                    <> textAt ["model", "reason"] update
                    <> "`; the chain attributes both refusals to the request validator. The owner-signed insertion control accepted by both is transaction `"
                    <> textAt ["chain", "txid"] control <> "`.\n\n"
            [] -> ""
    windowEvidence steps = case steps of
        [before, control, after]
            | refuses ["insertActive"] (String "before-phase-2") "not-phase2" before
            , refuses ["insertActive"] (String "after-phase-2") "not-phase2" after
            , all ((== Just True) . ownerSigned) steps
            , all (same ["registry"] before) [control, after]
            , same ["request"] before control
            , same ["request", "owner"] before after
            , same ["edge"] before after
            , at ["request", "reference"] before /= at ["request", "reference"] after
            , retraction control
            , at ["tamper"] control == Just Null
            , at ["model", "outcome"] control == Just (String "accepted")
            , at ["chain", "outcome"] control == Just (String "accepted") ->
                "The window chapter compared both finite timing refusals: transaction `"
                    <> textAt ["chain", "txid"] before <> "` before phase 2 and transaction `"
                    <> textAt ["chain", "txid"] after <> "` after phase 2. The model refused both for `"
                    <> textAt ["model", "reason"] before
                    <> "`; the chain attributes both refusals to the request validator. Their owner-signed in-window control accepted by both is transaction `"
                    <> textAt ["chain", "txid"] control <> "`.\n\n"
        _ -> ""
    refuses edges alteration reason step =
        retraction step
            && at ["edge"] step `elem` map (Just . String) edges
            && at ["tamper"] step == Just alteration
            && at ["model", "outcome"] step == Just (String "refused")
            && at ["model", "reason"] step == Just (String reason)
            && at ["chain", "outcome"] step == Just (String "refused")
            && case (at ["requestScript"] step, at ["chain", "refusal", "hashes"] step) of
                (Just (String script), Just (Array hashes)) -> not (T.null script) && String script `elem` hashes
                _ -> False
    retraction step =
        at ["exit"] step == Just (String "retract")
            && at ["comparison"] step == Just (String "agrees")
            && not (null (textAt ["chain", "txid"] step))
    ownerSigned step = case (at ["request", "owner"] step, at ["witness", "signatories"] step) of
        (Just owner@(Number _), Just (Array signatories)) -> Just (owner `elem` signatories)
        _ -> Nothing
    same path left right = case at path left of
        Just value -> at path right == Just value
        Nothing -> False
    textAt path step = case at path step of
        Just (String value) -> T.unpack value
        _ -> ""
    at [] value = Just value
    at (key : path) (Object fields) = KM.lookup key fields >>= at path
    at _ _ = Nothing
    gapEvidence receipt
        | receiptRow receipt == "sequence" = maybe "" (concatMap gapReason) (receiptSteps receipt)
        | otherwise = ""
    gapReason (Object fields) = case (KM.lookup "edge" fields, KM.lookup "chain" fields) of
        (Just (String edge), Just (Object chain)) -> case (KM.lookup "outcome" chain, KM.lookup "reason" chain) of
            (Just (String "unsupported"), Just (String reason)) ->
                "### " <> T.unpack edge <> " — observed gap\n\n"
                    <> gapExplanation edge
                    <> "The observed reason follows from the receipt.\n\n"
                    <> "```text\n" <> T.unpack reason <> "\n```\n\n"
            _ -> ""
        _ -> ""
    gapReason _ = ""
    gapExplanation _ =
        "The attempted operation did not produce a supported fold.\n\n"
