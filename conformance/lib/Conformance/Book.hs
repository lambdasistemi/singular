-- | A book rendered from the same programs the live backend executes.
module Conformance.Book (renderBook) where

import Data.Foldable (toList)
import Data.List (intercalate)
import Data.Text qualified as T
import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KM
import Conformance.Edge.Register qualified as Register
import Conformance.Edge.Retire qualified as Retire
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
        <> "A requester submits two distinct active registrations and then repeats one key. A redirected delivery is tried beside the same untampered request. Every step is compared with the executable registry model.\n\n"
        <> renderLive (Register.story (Context "registration" "recipient wallet"))
        <> "## Retire a registration and burn its active token\n\n"
        <> "The holder first registers a key in this run. Retirement must consume and burn that very token and change the key to Terminal. A never-registered key and a key recorded as Absent must be refused, each beside a successful retirement in the same registry.\n\n"
        <> renderLive (Retire.story (Context "retirement" "holder wallet") (Context "comparison" "holder wallet"))
        <> "## A sequence no chapter names\n\n"
        <> "This program uses the same live interpreter for each listed request. Each step records its own model and chain outcome; any unsupported result carries the reason observed at the booking or fold boundary.\n\n"
        <> renderLive (Sequence.story (Context "sequence" "holder wallet"))
        <> "## What these runs do not establish\n\n"
        <> "Every declared observation of an accepted request in the running chapters is compared with the model: configuration, custody, held tokens, leaf, mint, payments, root, the resulting state and the transaction. Output minimum ada remains a named unobservable. The transaction's required signers are compared: the model requires none, and the comparison reads them from the submitted transaction. The two-request batch allocation has no driver comparison: the driver evaluates one request per transaction, leaving Singular.Statements.fold_batch_claimed_mint_by_kind_key without this executable consumer. For any step whose receipt reports unsupported, no acceptance or refusal of a completed chain fold is established; the observed reasons are published in the appendix. The Absent retirement probe reaches the state script only after omitting an unfunded burn: the builder cannot fund burning a token that does not exist. Its refusal does not establish how a transaction with that burn would behave. These examples exercise one local devnet and one protocol-parameter set; they do not establish every reachable state, every theorem consumer, or naming-application behavior beyond the observed approval.\n\n"
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
                "CG22" -> "Retirement compared " <> outcomeCounts steps
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
    gapExplanation "witnessTerminal" =
        "Reading a Terminal key is not yet supported: the node rejects the booking transaction before a fold is submitted.\n\n"
    gapExplanation _ =
        "The attempted operation did not produce a supported fold.\n\n"
