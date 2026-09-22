-- | A book rendered from the same programs the live backend executes.
module Conformance.Book (renderBook) where

import Data.Text qualified as T
import Conformance.Edge.Register qualified as Register
import Conformance.Edge.Retire qualified as Retire
import Conformance.Story.Live (Context (..), renderLive)
import Conformance.Rows (Row (..), RowState (..))
import Conformance.Receipt (Receipt (..), EdgeEvidence (..), RetirementEvidence (..), RetirementQuantities (..))

-- | Called only after both live stories and their observations have succeeded.
renderBook :: [Row] -> [Receipt] -> String
renderBook requirements receipts =
    "# The running registry book\n\n"
        <> "These are executable stories. The runner supplies fresh registry and wallet contexts; the stories submit real transactions to a local Cardano devnet and check what happened. The same story programs supply the steps printed below.\n\n"
        <> "## This run\n\n"
        <> concatMap result receipts
        <> "## Register a key and receive its active token\n\n"
        <> "A requester registers a new key for a recipient. The recipient must receive exactly one active token for that key. A fresh key must work; registering the same key again must fail. The batch example checks that a correct token total cannot hide a wrong allocation between keys.\n\n"
        <> renderLive (Register.story (Context "registration" "recipient wallet"))
        <> "## Retire a registration and burn its active token\n\n"
        <> "The holder first registers a key in this run. Retirement must consume and burn that very token and change the key to Terminal. A never-registered key and a key recorded as Absent must be refused, each beside a successful retirement in the same registry.\n\n"
        <> renderLive (Retire.story (Context "retirement" "holder wallet") (Context "comparison" "holder wallet"))
        <> "## What these runs do not establish\n\n"
        <> "Every declared observation of a registration is compared with the model: configuration, custody, held tokens, leaf, mint, payments, root, the resulting state and the transaction, including the transaction's signers value, which a check changes to prove the difference is reported. Two things are named rather than compared: a ledger makes every output carry a minimum ada and the model says nothing about it, so outputMinimumAda is removed from both sides and earns no pass; and the model states no obligation about who must sign, so requiredSigners stays a named unobservable until the signer rules are stated and proved. Retirement effects still come from the oracle replay, which starts each example in an empty registry. Batch allocation and refusal checks still use Haskell predicates. The requirement that every Lean theorem has an executable consumer remains unmet. These examples exercise the open registry on one local devnet and one protocol-parameter set. They do not establish every case in the formal model. Signature-set invariance is not observed. Retirement of an already Terminal key and retirement without the token remain compiled-script controls rather than live examples here. The naming application's additional approval behavior is outside these stories.\n\n"
        <> "## Requirements inventory\n\n"
        <> "The descriptions and planned statuses below are preserved from the committed inventory. The transaction evidence above belongs to this particular run; it does not rewrite planned statuses or discharge unrelated requirements.\n\n"
        <> concatMap requirement requirements
        <> "## Appendix: checking the evidence machinery\n\n"
        <> "The report-validation tests remain under `test/Conformance/Support`. They check missing and contradictory evidence, report parsing and preservation, and refusal attribution. They run alongside the live stories but do not replace them. Authentication tests are still compiled but unwired, tracked in #210.\n\n"
        <> "The generated book is committed to the repository and is not yet reachable from the documentation site, tracked as #218. The general census of Haskell specification bindings remains tracked in #213.\n"
  where
    result receipt =
        "Code revision: `" <> T.unpack (receiptBase receipt) <> "`"
            <> (if receiptDirty receipt then " (working tree had changes)." else " (clean working tree).") <> "\n\n"
            <> "Node: `" <> T.unpack (receiptNode receipt) <> "`. Compiled validators: `"
            <> T.unpack (receiptBlueprint receipt) <> "`.\n\n"
            <> maybe "" (\edge -> "Registration passed: exactly one active token reached the requested recipient.\n\nTransaction: `"
                <> T.unpack (eeFoldTxid edge) <> "`.\n\n") (receiptEdge receipt)
            <> maybe "" (\retired -> "Retirement passed: the holder's active-token quantity changed from **"
                <> show (rqBefore (rtQuantities retired)) <> "** to **" <> show (rqAfter (rtQuantities retired))
                <> "**, the token was burned, and the key became Terminal.\n\nRegistration transaction: `"
                <> T.unpack (rtInsertTxid retired) <> "`. Retirement transaction: `"
                <> T.unpack (rtRetireTxid retired) <> "`.\n\n") (receiptRetirement receipt)
    requirement row = "### " <> T.unpack (rowRequirement row) <> "\n\nExpected: "
        <> T.unpack (rowExpected row) <> ". Planned evidence status: " <> stateName (rowState row)
        <> ".\n\nSource: " <> T.unpack (rowSource row) <> ".\n\n"
        <> maybe "" (\e -> "Existing evidence: " <> T.unpack e <> "\n\n") (rowEvidence row)
    stateName Uncovered = "uncovered"
    stateName BoundElsewhere = "bound elsewhere"
    stateName OutOfScope = "outside the registry's scope"
