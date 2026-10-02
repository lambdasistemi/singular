-- | A book rendered from the same programs the live backend executes.
module Conformance.Book (renderBook, bookStories, bookReceipts) where

import Conformance.Edge.Programs
    ( Chapter (..)
    , Classification (..)
    , Kind (..)
    , Program (..)
    , classify
    , displayStory
    , programFor
    , programs
    )
import Conformance.Receipt (Receipt (..), Verdict (..))
import Conformance.Rows (Row (..), RowState (..))
import Conformance.Story.Live (renderLive)
import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KM
import Data.Foldable (toList)
import Data.List (intercalate)
import Data.Maybe (isJust)
import Data.Text qualified as T

-- | The stories a book run executes, renders and requires, in book order.
bookStories :: [String]
bookStories = [programRow p | p <- programs, isJust (programChapter p)]

{- | The receipts a book renders: one per story of the book, each agreeing
with the model, in book order; a missing or disagreeing story is refused,
named.
-}
bookReceipts :: [Receipt] -> Either String [Receipt]
bookReceipts receipts = traverse story bookStories
  where
    story name = case [r | r <- receipts, receiptRow r == T.pack name] of
        [r]
            | receiptVerdict r == AgreesWithModel -> Right r
            | otherwise ->
                Left
                    ("the book's " <> name <> " receipt does not agree with the model")
        [] -> Left ("the book run has no receipt for " <> name)
        _ -> Left ("the book run has more than one receipt for " <> name)

-- | Called only after both live stories and their observations have succeeded.
renderBook :: [Row] -> [Receipt] -> String
renderBook requirements receipts =
    "# The running registry book\n\n"
        <> "These are executable stories. The runner supplies fresh registry and wallet contexts; the stories submit real transactions to a local Cardano devnet and check what happened. The same story programs supply the steps printed below.\n\n"
        <> "## This run\n\n"
        <> concatMap
            result
            [r | name <- bookStories, r <- receipts, receiptRow r == T.pack name]
        <> concatMap chapterText programs
        <> "## What these runs do not establish\n\n"
        <> "Every declared observation of an accepted request in the running chapters is compared with the model: configuration, custody, held tokens, leaf, mint, payments, root, the resulting state and the transaction. Output minimum ada remains a named unobservable. The transaction's required signers are compared: the model requires none for a fold and the owner for a retraction, and the comparison reads them from the submitted transaction. The registration chapter folds two registrations in one transaction that mints both tokens at the first request's key; it is compared on its outcome and, both refusing, on the reason. The model builds no transaction for a batch, so no other observation of a batch is compared. For any step whose receipt reports unsupported, no acceptance or refusal of a completed chain fold is established; the observed reasons are published in the appendix. The Absent retirement probe reaches the state script only after omitting an unfunded burn: the builder cannot fund burning a token that does not exist. Its refusal does not establish how a transaction with that burn would behave. The model admits a retraction only when the pending request inserts a key or reads a terminal one, its owner is among the transaction's required signers, and its validity interval lies inside phase 2. The interval starts no earlier than submission plus the processing time; its excluded upper bound may reach, but not pass, the end of the retraction time that follows. The model represents only finite validity bounds. Open validity intervals remain a named gap: the Aiken tests establish their not-phase2 refusal, but no live model comparison can represent them. The early rejections are compared in the processing window and the retraction window of one registry; a fold of an update in the retraction window is not compared there, because the validator refuses it while the model admits it, a separate tracked discrepancy. These examples exercise one local devnet and one protocol-parameter set; they do not establish every reachable state, every theorem consumer, or naming-application behavior beyond the observed approval.\n\n"
        <> refusalLimits
        <> "## Requirements inventory\n\n"
        <> "The descriptions and planned statuses below are preserved from the committed inventory. The transaction evidence above belongs to this particular run; it does not rewrite planned statuses or discharge unrelated requirements.\n\n"
        <> concatMap requirement requirements
        <> "## Appendix: checking the evidence machinery\n\n"
        <> "The report-validation tests remain under `test/Conformance/Support`. They check missing and contradictory evidence, report parsing and preservation, and refusal attribution. They run alongside the live stories but do not replace them. Authentication tests are still compiled but unwired, tracked in #210.\n\n"
        <> concatMap gapEvidence receipts
        <> replayCaptures
        <> "The generated book is committed to the repository and is not yet reachable from the documentation site, tracked as #218. The general census of Haskell specification bindings remains tracked in #213.\n"
  where
    result receipt =
        "Code revision: `"
            <> T.unpack (receiptBase receipt)
            <> "`"
            <> ( if receiptDirty receipt
                    then " (working tree had changes)."
                    else " (clean working tree)."
               )
            <> "\n\n"
            <> "Node: `"
            <> T.unpack (receiptNode receipt)
            <> "`. Compiled validators: `"
            <> T.unpack (receiptBlueprint receipt)
            <> "`.\n\n"
            <> maybe
                ""
                ( \steps -> case programFor (T.unpack (receiptRow receipt)) >>= programChapter of
                    Just chapterOf ->
                        chapterSummary chapterOf
                            <> " "
                            <> outcomeCounts steps
                            <> concatMap detection steps
                            <> concatMap refusedStep steps
                            <> concatMap refusedBatch steps
                            <> admissionEvidence steps
                            <> windowEvidence steps
                    Nothing -> ""
                )
                (receiptSteps receipt)
    requirement row =
        "### "
            <> T.unpack (rowRequirement row)
            <> "\n\nExpected: "
            <> T.unpack (rowExpected row)
            <> ". Planned evidence status: "
            <> stateName (rowState row)
            <> ".\n\nSource: "
            <> T.unpack (rowSource row)
            <> ".\n\n"
            <> maybe
                ""
                (\e -> "Existing evidence: " <> T.unpack e <> "\n\n")
                (rowEvidence row)
            <> classification row
    -- A chapter is a program the book renders whole, with what it is for.
    chapterText p = case programChapter p of
        Just chapterOf ->
            "## "
                <> chapterTitle chapterOf
                <> "\n\n"
                <> chapterIntroduction chapterOf
                <> "\n\n"
                <> rendered p
        Nothing -> ""
    rendered p =
        either
            (\problem -> "The program cannot be rendered: " <> problem <> "\n\n")
            renderLive
            (displayStory p)
    -- How a registry row is run, read off the program that runs it or the
    -- reason the model cannot express it.
    classification row
        | rowGroup row /= "CG" = ""
        | otherwise = case classify (rowId row) of
            Right (Composed kind) ->
                kindReading kind
                    <> maybe "." whereRun (programFor (T.unpack (rowId row)))
            Right (Outside reason) ->
                "Outside the model's vocabulary: " <> T.unpack reason <> "\n\n"
            Left problem -> "Not classified: " <> problem <> "\n\n"
    kindReading EdgeComposition =
        "Run as an edge composition over the registry's operations"
    kindReading Tamper = "Run as a tamper of an edge's transaction"
    whereRun p = case programChapter p of
        Just chapterOf -> ", in the chapter \"" <> chapterTitle chapterOf <> "\" above.\n\n"
        Nothing -> ", in the conformance session:\n\n" <> rendered p
    stateName Uncovered = "uncovered"
    stateName BoundElsewhere = "bound elsewhere"
    stateName OutOfScope = "outside the registry's scope"
    hasOutcome expected value = case value of
        Object fields -> case KM.lookup "chain" fields of
            Just (Object chain) -> KM.lookup "outcome" chain == Just (String expected)
            _ -> False
        _ -> False
    outcomeCounts allSteps =
        let steps = filter (not . isBatch) allSteps
            batches = filter isBatch allSteps
        in  show (length steps)
                <> " requests: "
                <> show (length (filter (hasOutcome "accepted") steps))
                <> " accepted and "
                <> show (length (filter (hasOutcome "refused") steps))
                <> " refused on chain.\n\n"
                <> "Unsupported chain folds: "
                <> show (length (filter (hasOutcome "unsupported") steps))
                <> ".\n\n"
                <> ( if null batches
                        then ""
                        else
                            "Batches submitted in one transaction: "
                                <> show (length batches)
                                <> ", "
                                <> show (length (filter (hasOutcome "accepted") batches))
                                <> " accepted and "
                                <> show (length (filter (hasOutcome "refused") batches))
                                <> " refused on chain.\n\n"
                   )
    isBatch value = case value of
        Object fields -> KM.member "batch" fields
        _ -> False
    -- A batch the chain refused, the model's reason for its batch question,
    -- and what the traced replay of its transaction recorded: all read from the
    -- record, never typed here.
    refusedBatch value = case value of
        Object fields -> case ( KM.lookup "batch" fields
                              , KM.lookup "requests" fields
                              , KM.lookup "chain" fields
                              ) of
            (Just (String question), Just (Array asked), Just (Object chain))
                | Just (String "refused") <- KM.lookup "outcome" chain
                , Just (String txid) <- KM.lookup "txid" chain ->
                    "The "
                        <> ( if question == "foldBatch"
                                then "fold of "
                                else "reject of "
                           )
                        <> show (length asked)
                        <> " requests in one transaction"
                        <> ( case KM.lookup "tamper" fields of
                                Just (String name) -> ", tampered " <> T.unpack name <> ","
                                _ -> ""
                           )
                        <> " was refused on chain (transaction `"
                        <> T.unpack txid
                        <> "`)"
                        <> ( case at ["model", "reason"] value of
                                Just (String reason) ->
                                    "; the model's `"
                                        <> T.unpack question
                                        <> "` refused it for `"
                                        <> T.unpack reason
                                        <> "`."
                                _ -> "."
                           )
                        <> " "
                        <> tracedReplay chain
                        <> "\n\n"
            _ -> ""
        _ -> ""
    -- A tamper the ledger accepted, and the difference the comparison detected
    -- in the transaction it built: read from the step, never typed here.
    detection value = case value of
        Object fields -> case ( KM.lookup "tamper" fields
                              , KM.lookup "comparison" fields
                              , KM.lookup "differences" fields
                              , KM.lookup "chain" fields
                              ) of
            ( Just (String name)
                , Just (String "agrees")
                , Just (Array differences)
                , Just (Object chain)
                )
                    | not (null differences)
                    , Just (String "accepted") <- KM.lookup "outcome" chain
                    , Just (String txid) <- KM.lookup "txid" chain ->
                        "The "
                            <> T.unpack name
                            <> " registration was accepted on chain (transaction `"
                            <> T.unpack txid
                            <> "`); the comparison detected the difference at "
                            <> intercalate
                                ", "
                                [ "`" <> T.unpack observation <> "." <> T.unpack path <> "`"
                                | Object difference <- toList differences
                                , Just (String observation) <- [KM.lookup "observation" difference]
                                , Just (String path) <- [KM.lookup "path" difference]
                                ]
                            <> ".\n\n"
            _ -> ""
        _ -> ""
    -- A request the chain refused, the model's reason, and what the traced
    -- replay of its transaction recorded: all read from the step, never typed
    -- here.
    refusedStep value = case value of
        Object fields -> case ( KM.lookup "edge" fields
                              , KM.lookup "chain" fields
                              ) of
            (Just (String edge), Just (Object chain))
                | Just (String "refused") <- KM.lookup "outcome" chain
                , Just (String txid) <- KM.lookup "txid" chain ->
                    "The "
                        <> ( case KM.lookup "tamper" fields of
                                Just (String name) -> T.unpack name <> " "
                                _ -> ""
                           )
                        <> exitOf fields edge
                        <> " was refused on chain (transaction `"
                        <> T.unpack txid
                        <> "`)"
                        <> ( case at ["model", "reason"] value of
                                Just (String reason) ->
                                    "; the model refused it for `" <> T.unpack reason <> "`."
                                _ -> "."
                           )
                        <> " "
                        <> tracedReplay chain
                        <> "\n\n"
            _ -> ""
        _ -> ""
    -- What the traced replay of a refused transaction recorded, purpose by
    -- purpose, or that it recorded nothing.
    tracedReplay chain = case replayOf chain of
        [] -> "No traced replay of this refusal is recorded."
        entries ->
            unwords
                [ "The traced replay of the deployed script `"
                    <> T.unpack deployed
                    <> "` "
                    <> observed
                | entry <- entries
                , Just (String deployed) <- [KM.lookup "deployedHash" entry]
                , Just observed <- [replayObserved entry]
                ]
    replayOf chain = case KM.lookup "refusal" chain of
        Just (Object refusal)
            | Just (Array entries) <- KM.lookup "replay" refusal ->
                [entry | Object entry <- toList entries]
        _ -> []
    replayObserved entry = case ( KM.lookup "reason" entry
                                , KM.lookup "cause" entry
                                , KM.lookup "tracedHash" entry
                                ) of
        (Just (String reason), _, Just (String traced)) ->
            Just
                ( "(traced build `"
                    <> T.unpack traced
                    <> "`) failed with `"
                    <> T.unpack reason
                    <> "`."
                )
        (_, Just (String cause), _) ->
            Just ("admits no reason: `" <> T.unpack cause <> "`.")
        _ -> Nothing
    -- Every refused request of the run's chapters, with its replay.
    refusedChains =
        [ chain
        | receipt <- receipts
        , step <- concat (receiptSteps receipt)
        , Just (Object chain) <- [at ["chain"] step]
        , KM.lookup "outcome" chain == Just (String "refused")
        ]
    recorded predicate =
        length [() | chain <- refusedChains, predicate (replayOf chain)]
    admitted = any (KM.member "reason")
    named entries = not (admitted entries) && any (KM.member "cause") entries
    refusalLimits =
        "Refusal reasons come from traced re-evaluation. The deployed validators are compiled without traces, so the ledger names the script that refused but not why. Each refused transaction is evaluated again on the arguments the ledger built for it: once with the deployed bytes, and once with a build of the same source, compiler and parameters that keeps only the validators' own traces. A reason is admitted only when both evaluations fail and the traced one leaves exactly one trace; otherwise the receipt names the cause no reason was admitted. The receipt names both script hashes, and each refused request above prints what its replay recorded. Of the "
            <> show (length refusedChains)
            <> ( if length refusedChains == 1
                    then " refused request"
                    else " refused requests"
               )
            <> " in this run's chapters, "
            <> counted
                (recorded admitted)
                "carries a reason its"
                "carry a reason their"
            <> " traced replay admitted, "
            <> counted (recorded named) "names the cause its" "name the cause their"
            <> " replay admits none, and "
            <> counted (recorded null) "records" "record"
            <> " no traced replay.\n\n"
            <> "Refusals outside these chapters, by row, recorded in the receipts of the conformance session rather than in this book. Three have no counterpart in the model, so their model comparison is unmet: each receipt carries the verdict unmet by ruling and shows what the traced replay of the refusal recorded. CS04, a fold redeemer at a wrong constructor index: the model has no vocabulary for decoding a redeemer; the witness script names its refusal, while the state and request scripts fail on a path that carries no user-defined trace, so their live refusal reason is not observed (lambdasistemi/singular#347). CG10, a fold whose proof was built against a root the registry has since superseded: the model takes no proof and no authenticated root and admits the insertion on that unoccupied key, so nothing compares with the chain's reason (lambdasistemi/singular#346). CG12, a fold carrying an action beyond its requests, and one missing an action: the model takes no action list (lambdasistemi/singular#345). The other refusals are compared with the model's batch questions, each against the reason the traced replay admits for the state script: CG11, an empty fold, with the fold batch over no request; CG19, two rejects whose refunds are crossed and two whose first refund is short, with the reject batch judged on the refunds the transaction pays; and CG09's control, a reject refunding its owner one lovelace short, with the reject batch of that one request. CG09 itself, a reject while the request can still be folded, is accepted by the chain and by the model, while the consuming project requires it refused: that requirement stays unmet by ruling. Where a reject pays its owner, the chain and the model read the payment differently: the chain requires the output in each refund's position to pay that request's owner what it is owed, while the model credits an owner the sum of every output at its key. A reject paying its owner short in the refund's position and the rest in another output at the same key is refused by the chain and accepted by the model: CG09's receipt records that disagreement from a devnet run, a known divergence and never a pass (lambdasistemi/singular#361). Every compared reject, here and in the conformance session, leaves no other output at its owners' keys, so their agreement holds for that shape only. Whether CG11 and CG19 meet the consuming project's requirements remains unresolved; the two rows stay held.\n\n"
    -- A count with the words that agree with it.
    counted n one many = show n <> " " <> (if n == 1 then one else many)
    -- The capture each refused request's replay was evaluated from: harness
    -- evidence, kept to the appendix.
    replayCaptures = case [ "Transaction `"
                                <> T.unpack txid
                                <> "`: capture `"
                                <> T.unpack capture
                                <> "` of the deployed script `"
                                <> T.unpack deployed
                                <> "`.\n\n"
                          | chain <- refusedChains
                          , Just (String txid) <- [KM.lookup "txid" chain]
                          , entry <- replayOf chain
                          , Just (String capture) <- [KM.lookup "captureId" entry]
                          , Just (String deployed) <- [KM.lookup "deployedHash" entry]
                          ] of
        [] -> ""
        captures ->
            "Each refused request's traced replay was evaluated from a capture of the refused transaction, the outputs it spends, the protocol parameters and the era history:\n\n"
                <> concat captures
    -- A fold is named by its edge; a reject or a retraction by its exit and the
    -- edge its request named.
    exitOf fields edge = case KM.lookup "exit" fields of
        Just (String exit)
            | exit `elem` ["reject", "retract"] ->
                T.unpack exit <> " of " <> T.unpack edge
        _ -> T.unpack edge
    -- Publish the admission run only with both attributed refusals and their
    -- signed insertion control. Missing evidence never becomes a run claim.
    admissionEvidence steps = case [ (unsigned, update, control)
                                   | unsigned <- steps
                                   , refuses
                                        ["insertAbsent", "insertActive"]
                                        (String "unsigned")
                                        "retract-owner"
                                        unsigned
                                   , ownerSigned unsigned == Just False
                                   , update <- steps
                                   , refuses
                                        ["updateActive", "updateTerminal"]
                                        Null
                                        "withdraw-insert-only"
                                        update
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
                <> textAt ["chain", "txid"] unsigned
                <> "`) was refused by the model for `"
                <> textAt ["model", "reason"] unsigned
                <> "`, and the pending update retraction (transaction `"
                <> textAt ["chain", "txid"] update
                <> "`) for `"
                <> textAt ["model", "reason"] update
                <> "`; the chain attributes both refusals to the request validator. The owner-signed insertion control accepted by both is transaction `"
                <> textAt ["chain", "txid"] control
                <> "`.\n\n"
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
            , at ["request", "reference"] before
                /= at ["request", "reference"] after
            , retraction control
            , at ["tamper"] control == Just Null
            , at ["model", "outcome"] control == Just (String "accepted")
            , at ["chain", "outcome"] control == Just (String "accepted") ->
                "The window chapter compared both finite timing refusals: transaction `"
                    <> textAt ["chain", "txid"] before
                    <> "` before phase 2 and transaction `"
                    <> textAt ["chain", "txid"] after
                    <> "` after phase 2. The model refused both for `"
                    <> textAt ["model", "reason"] before
                    <> "`; the chain attributes both refusals to the request validator. Their owner-signed in-window control accepted by both is transaction `"
                    <> textAt ["chain", "txid"] control
                    <> "`.\n\n"
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
        | receiptRow receipt == "sequence" =
            maybe "" (concatMap gapReason) (receiptSteps receipt)
        | otherwise = ""
    gapReason (Object fields) = case (KM.lookup "edge" fields, KM.lookup "chain" fields) of
        (Just (String edge), Just (Object chain)) -> case (KM.lookup "outcome" chain, KM.lookup "reason" chain) of
            (Just (String "unsupported"), Just (String reason)) ->
                "### "
                    <> T.unpack edge
                    <> " — observed gap\n\n"
                    <> gapExplanation edge
                    <> "The observed reason follows from the receipt.\n\n"
                    <> "```text\n"
                    <> T.unpack reason
                    <> "\n```\n\n"
            _ -> ""
        _ -> ""
    gapReason _ = ""
    gapExplanation _ =
        "The attempted operation did not produce a supported fold.\n\n"
