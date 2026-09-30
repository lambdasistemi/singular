{-# LANGUAGE GADTs #-}

{- | The ordinary CLI's story and the open-datum application's boundary,
judged from receipts.

Alice's story runs through the ordinary commands and is checked against
the receipts they print. Hand-built updates and an early release reach
the application's own script. And the registry refuses an insertion the
application books: a second insertion of a key that is Active, and an
insertion of a key that is already Terminal.

The application certifies both bookings. Neither can take effect: the
registry refuses to fold them because the key exists (the model's
@duplicate_refused_by_registry@ and @resurrection_refused_by_registry@).
Each refusal is paired with an accepting control that differs only in
the key: a key the registry has never held, booked and folded the same
way. Readbacks taken before and after the refused fold show that it
changed nothing.

Every result here is computed from receipts. A story is interpreted
twice: once against a node, where each action leaves one receipt, and
once over those receipts, where each check is recomputed. A missing,
misplaced or altered receipt changes the verdict; nothing is typed in.
-}
module Conformance.Cli.Controls
    ( -- * Actions
      Command (..)
    , commandName
    , Crafted (..)
    , craftedName
    , craftedPhrase
    , Target (..)
    , Requirement (..)
    , CliI (..)
    , Story

      -- * Statements
    , DuplicateRefused
    , ResurrectionRefused
    , duplicateRefused
    , resurrectionRefused
    , statementBindings
    , resolveStatement

      -- * The stories
    , duplicateStory
    , resurrectionStory
    , lifecycleStory
    , boundaryStory
    , controlsStory

      -- * Receipts
    , Receipt (..)
    , Observation (..)
    , Submission (..)
    , emptyReceipt

      -- * Reading a node's rejection
    , rejectionEvidence
    , attribution

      -- * Verdicts and rendering, from receipts
    , ClauseStatus (..)
    , ClauseResult (..)
    , judge
    , held
    , outline
    , renderControls
    , validateControls
    ) where

import Conformance.Story.Binding
    ( Binding
    , BoundObligation (..)
    , mkBoundObligation
    )
import Conformance.Story.Specification
    ( Clause (..)
    , LeanCheck
    , Step (..)
    , Theorem
    , TheoremStory
    , action
    , bindCheck
    , bindTheorem
    , checkAction
    , clause
    , clauses
    , theorem
    , theoremBinding
    )
import Conformance.Story.Specification qualified as Specification
import Control.Monad (forM_, unless, void, when)
import Control.Monad.Operational
    ( Program
    , ProgramViewT (Return, (:>>=))
    , view
    )
import Data.Aeson
    ( FromJSON (..)
    , ToJSON (..)
    , object
    , withObject
    , (.:)
    , (.:?)
    , (.=)
    )
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Char (ord)
import Data.List (intercalate, isInfixOf, nub)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Text.Printf (printf)

import Conformance.Refusal
    ( RefusalMismatch (..)
    , matchRefusal
    , refusalScriptHashes
    )

-- ---------------------------------------------------------
-- Actions
-- ---------------------------------------------------------

{- | The ordinary commands, as a person runs them. An update names which
of the story's payloads it writes.
-}
data Command = Create | Insert | Update Int | Terminate | Inspect
    deriving stock (Eq, Show)

commandName :: Command -> String
commandName c = case c of
    Create -> "create"
    Insert -> "insert"
    Update _ -> "update"
    Terminate -> "terminate"
    Inspect -> "inspect"

{- | A transaction built by hand against a key's live holding at the
application, and submitted without local evaluation so the node judges
it. Each shape but the first is one of the Aiken suite's refused updates,
or a release outside any fold.
-}
data Crafted
    = -- | The controller's update: same control, value and address
      HonestUpdate
    | -- | The same update, requiring another signer instead of the controller
      UpdateByStranger
    | -- | The continuation names another controller
      UpdateOtherController
    | -- | The continuation's protected deposit is changed
      UpdateDepositTampered
    | -- | The continuation, token and all, leaves for the controller's own address
      UpdateEscaped
    | -- | The continuation stays but the key's token leaves it
      UpdateTokenLeft
    | -- | The continuation holds one lovelace less than the protected deposit
      UpdateShortDeposit
    | -- | The continuation carries no datum
      UpdateWithoutDatum
    | -- | The continuation also carries an asset of another policy
      UpdateAddedAsset
    | -- | The holding is spent with @Release@ outside any fold
      EarlyWithdrawal
    | -- | An insertion booked with the controller's envelope, paid and signed by another wallet
      BookingByStranger
    | -- | An insertion booking whose request names another destination
      BookingOtherDestination
    | -- | An insertion booking whose request deposit is one lovelace short of the protected one
      BookingShortDeposit
    | -- | An insertion booking whose destination names no datum
      BookingNoDatum
    | -- | An insertion booking whose envelope names the state policy under another token name
      EnvelopeOtherStateName
    | -- | An insertion booking whose envelope names the token name under another policy
      EnvelopeOtherStatePolicy
    | -- | An insertion booking whose envelope names another registry's state asset
      EnvelopeOtherRegistry
    | -- | The controller's own booking of the key's termination
      TerminateBooking
    | -- | A termination booking by another wallet
      TerminateBookingByStranger
    | -- | A fold of another key's insertion that also spends the holding with @Release@
      ReleaseInOtherFold
    | -- | The controller's update, submitted without the application's script
      UpdateWithoutScript
    | -- | The terminating fold, folded by another wallet, paying the controller one lovelace short
      FoldPaysShort
    | -- | The same terminating fold, folded by another wallet, paying the controller in full
      FoldPaysInFull
    | -- | One fold of two terminations for one controller, paying it one lovelace short of the sum
      FoldTwoReleasesShort
    | -- | The same fold, paying it one released deposit where the sum of two is owed
      FoldTwoReleasesOneFloor
    | -- | The same fold, paying it the sum in full
      FoldTwoReleasesInFull
    | -- | One fold of an insertion and a termination for one controller, paying it one lovelace short
      FoldMixedShort
    | -- | The same fold, paying it in full
      FoldMixedInFull
    deriving stock (Eq, Show, Enum, Bounded)

craftedName :: Crafted -> String
craftedName c = case c of
    HonestUpdate -> "update"
    UpdateByStranger -> "update-by-stranger"
    UpdateOtherController -> "update-other-controller"
    UpdateDepositTampered -> "update-deposit-tampered"
    UpdateEscaped -> "update-escaped"
    UpdateTokenLeft -> "update-token-left"
    UpdateShortDeposit -> "update-short-deposit"
    UpdateWithoutDatum -> "update-without-datum"
    UpdateAddedAsset -> "update-added-asset"
    EarlyWithdrawal -> "early-withdrawal"
    BookingByStranger -> "booking-by-stranger"
    BookingOtherDestination -> "booking-other-destination"
    BookingShortDeposit -> "booking-short-deposit"
    BookingNoDatum -> "booking-no-datum"
    EnvelopeOtherStateName -> "envelope-other-state-name"
    EnvelopeOtherStatePolicy -> "envelope-other-state-policy"
    EnvelopeOtherRegistry -> "envelope-other-registry"
    TerminateBooking -> "terminate-booking"
    TerminateBookingByStranger -> "terminate-booking-by-stranger"
    ReleaseInOtherFold -> "release-in-other-fold"
    UpdateWithoutScript -> "update-without-script"
    FoldPaysShort -> "fold-pays-short"
    FoldPaysInFull -> "fold-pays-in-full"
    FoldTwoReleasesShort -> "fold-two-releases-short"
    FoldTwoReleasesOneFloor -> "fold-two-releases-one-floor"
    FoldTwoReleasesInFull -> "fold-two-releases-in-full"
    FoldMixedShort -> "fold-mixed-short"
    FoldMixedInFull -> "fold-mixed-in-full"

-- | A registry the story works in: its own directory and its own boot.
newtype Target = Target String
    deriving stock (Eq, Show)

-- | What a check requires of the receipts it is given.
data Requirement
    = -- | One command receipt whose outcome is @success@
      CommandSucceeded
    | -- | One booking or fold the node accepted and the chain confirmed
      Accepted
    | {- | One fold submitted without local evaluation, which the node
      refused, naming the registry's own state validator as the script that
      failed
      -}
      RefusedByState
    | {- | Two readbacks, before and after, that agree on the registry's
      root, the key's holding, the pending requests and the wallet
      -}
      Unchanged
    | {- | A command receipt whose outcome is @partial@ and which names its
      pending request, and a readback after it that finds that request
      pending
      -}
      PartialPending
    | {- | One hand-built transaction submitted without local evaluation,
      which the node refused, naming the applied open-datum script as the
      script that failed
      -}
      RefusedByApplication
    | {- | Two readbacks that agree on the registry's root, the key's holding
      and the wallet
      -}
      HoldingUnchanged
    | {- | The create and insert receipts: the inserted envelope names the
      created registry's state asset and active policy
      -}
      SameRegistry
    | {- | The insert and inspect receipts: the key reads Active, its one
      holding is the output the insert delivered, carrying the inserted
      envelope inline and at least its protected deposit
      -}
      Delivered
    | {- | Inspect, update, inspect: the root does not move, the holding is
      the update's output, the payload is the update's and the control and
      deposit are unchanged
      -}
      PayloadReplaced
    | {- | Inspect, terminate, inspect: the key reads Terminal with no
      holding, and the terminate released the protected deposit it held
      -}
      Released
    | -- | One readback the node answered
      Observed
    | {- | Two readbacks that agree on the registry's root, its pending
      requests and the wallet
      -}
      RegistryUnchanged
    | {- | Command receipts that all succeeded, in one registry: the premise
      a telling builds on
      -}
      Established
    | {- | Command receipts that all succeeded, then a fresh reading of the
      exact key: an @ that authenticated it Active against the
      chain's root, or a readback whose mirror copy agrees with that root
      -}
      ReachedActive
    | -- | The same, reading the key Terminal
      ReachedTerminal
    | {- | One hand-built transaction the node rejected before any script ran,
      although its rejection names the applied open-datum script: the
      control that such a rejection is not counted as the script's refusal
      -}
      RejectedBeforeScripts
    deriving stock (Eq, Show, Enum, Bounded)

{- | One step of the story. Every action but 'Require' leaves exactly one
receipt; 'Require' is computed from receipts and leaves none.
-}
data CliI res where
    -- | Run one ordinary command against a registry, for a key
    Run :: Command -> Target -> String -> CliI Receipt
    {- | Book an insertion of the key through the application, as the
    ordinary insert does, and stop before its fold
    -}
    Book :: Target -> String -> CliI Receipt
    {- | Fold that booking, submitted without evaluating its scripts
    locally, so the node judges it
    -}
    FoldUnevaluated :: Target -> String -> CliI Receipt
    {- | Read the registry's root, the key's holding, the pending requests
    and the wallet back from the node
    -}
    Observe :: Target -> String -> CliI Receipt
    -- | Submit a hand-built transaction against the key's live holding
    Craft :: Crafted -> Target -> String -> CliI Receipt
    Require :: Requirement -> [Receipt] -> CliI ()

type Story = Specification.Story CliI

-- ---------------------------------------------------------
-- Statements
-- ---------------------------------------------------------

-- | @OpenDatumApplication.Statements.duplicate_refused_by_registry@
data DuplicateRefused

-- | @OpenDatumApplication.Statements.resurrection_refused_by_registry@
data ResurrectionRefused

-- | The model revision the two statements are read at.
modelRevision :: String
modelRevision = "de34300540223ccedf1ca85216b131fd09a148b4"

duplicateRefused :: Theorem DuplicateRefused
duplicateRefused =
    bindTheorem $
        mkBoundObligation
            "OpenDatumApplication.Statements.duplicate_refused_by_registry"
            "25ebf9423d2ed30a61be2f77698905a885312aedd0a65f1078760c0508fe599e"
            modelRevision

resurrectionRefused :: Theorem ResurrectionRefused
resurrectionRefused =
    bindTheorem $
        mkBoundObligation
            "OpenDatumApplication.Statements.resurrection_refused_by_registry"
            "2a84afdffe5b91cfd8f0fe9da7980093e77b75107fdbec76f28ba0d2e5bc6184"
            modelRevision

-- | Statement markers for the lifecycle and the application's boundary.
data InsertionHoldingInline

data UpdateKeepsRegistry

data UpdatePayloadFree

data ReleaseBurnsAtomically

data UpdateRequiresController

data UpdatePreservesCustody

data OnlyFoldReleases

bound :: String -> String -> Theorem thm
bound name digest =
    bindTheorem
        ( mkBoundObligation
            ("OpenDatumApplication.Statements." <> name)
            digest
            modelRevision
        )

insertionHoldingInline :: Theorem InsertionHoldingInline
insertionHoldingInline =
    bound
        "insertion_holding_inline"
        "00fb84e4307c41b9743c052983771844dace5a15d4a671ec9895e98d88d2b4b0"

updateKeepsRegistry :: Theorem UpdateKeepsRegistry
updateKeepsRegistry =
    bound
        "update_keeps_registry"
        "1d0bd504d8cbe90ccfcdc7c2a32096a4e370c8652a72d485b01715d5963a3e12"

updatePayloadFree :: Theorem UpdatePayloadFree
updatePayloadFree =
    bound
        "update_payload_free"
        "6577b1757d0291d77a26826fca516543cddbda7276cd515263e81e95ee32886e"

releaseBurnsAtomically :: Theorem ReleaseBurnsAtomically
releaseBurnsAtomically =
    bound
        "release_burns_atomically"
        "7e963ef2c919db15cc34ed9965b55d21d030f6de4b524690720126e4aacdf737"

updateRequiresController :: Theorem UpdateRequiresController
updateRequiresController =
    bound
        "update_requires_controller"
        "bdc250edc8194c67ddb79deb53307780d2ce6e9b865edc11fceceba564b912f7"

updatePreservesCustody :: Theorem UpdatePreservesCustody
updatePreservesCustody =
    bound
        "update_preserves_custody"
        "56a7b787884ab930d2ccb9524d13fb31a391f5c08aab2ac727080d39c4d498cc"

onlyFoldReleases :: Theorem OnlyFoldReleases
onlyFoldReleases =
    bound
        "only_fold_releases"
        "aefd57a28089717e856d92cc5ae3c03404e5d47420827f0659798909c080f84d"

-- | Statement markers for bookings and the terminating fold's settlement.
data BookInsertInversion

data InsertionRequiresRegistryIdentity

data BookTerminateInversion

data FoldInversion

data FoldSettlesAdditively

bookInsertInversion :: Theorem BookInsertInversion
bookInsertInversion =
    bound
        "bookInsert_inversion"
        "8fa1e83820c5041b894beed24171b08ae267128785a16a49ef4108230f691acf"

insertionRequiresRegistryIdentity
    :: Theorem InsertionRequiresRegistryIdentity
insertionRequiresRegistryIdentity =
    bound
        "insertion_requires_registry_identity"
        "73e322298b13ab5d17501865501f684e183c71c486d60c882ff61f68a76a46df"

bookTerminateInversion :: Theorem BookTerminateInversion
bookTerminateInversion =
    bound
        "bookTerminate_inversion"
        "a7d7faecdfd89fd337d2219ab5d9a705e287bcce155b2182e51fa4612c6d196c"

foldInversion :: Theorem FoldInversion
foldInversion =
    bound
        "fold_inversion"
        "e07a28190a45fdc990042b2f83625ae32b448119a91c2c758a34623dfd7df919"

foldSettlesAdditively :: Theorem FoldSettlesAdditively
foldSettlesAdditively =
    bound
        "fold_settles_additively"
        "0038394b2e4e770589310e9c7461adb80a5c9a8d90e3a83456e2cfa36ae2ba0d"

-- | Every statement the stories bind.
statementBindings :: [Binding]
statementBindings =
    [ theoremBinding duplicateRefused
    , theoremBinding resurrectionRefused
    , theoremBinding insertionHoldingInline
    , theoremBinding updateKeepsRegistry
    , theoremBinding updatePayloadFree
    , theoremBinding releaseBurnsAtomically
    , theoremBinding updateRequiresController
    , theoremBinding updatePreservesCustody
    , theoremBinding onlyFoldReleases
    , theoremBinding bookInsertInversion
    , theoremBinding insertionRequiresRegistryIdentity
    , theoremBinding bookTerminateInversion
    , theoremBinding foldSettlesAdditively
    , theoremBinding foldInversion
    ]

{- | Whether the application's statement ledger (@ledgers.json@) carries
the bound statement under the bound digest, proved.
-}
resolveStatement :: Aeson.Value -> Binding -> Either String ()
resolveStatement ledger b = do
    rows <- case Aeson.fromJSON ledger of
        Aeson.Success (LedgerFile r) -> Right r
        Aeson.Error e -> Left ("the statement ledger does not parse: " <> e)
    case [r | r <- rows, lrStatement r == T.pack (boName b)] of
        [r]
            | lrDigest r /= T.pack (boDigest b) ->
                Left
                    ( boName b
                        <> ": the ledger's digest is "
                        <> T.unpack (lrDigest r)
                        <> ", not the bound "
                        <> boDigest b
                    )
            | lrStatus r /= "PROVED" ->
                Left (boName b <> ": the ledger says " <> T.unpack (lrStatus r))
            | otherwise -> Right ()
        [] -> Left (boName b <> ": not in the statement ledger")
        _ ->
            Left (boName b <> ": listed more than once in the statement ledger")

newtype LedgerFile = LedgerFile [LedgerRow]

data LedgerRow = LedgerRow
    { lrStatement :: Text
    , lrDigest :: Text
    , lrStatus :: Text
    }

instance FromJSON LedgerFile where
    parseJSON = withObject "ledgers" $ \o -> LedgerFile <$> o .: "theorems"

instance FromJSON LedgerRow where
    parseJSON = withObject "theorem" $ \o ->
        LedgerRow
            <$> o .: "statement"
            <*> o .: "statementSha256"
            <*> o .: "status"

-- ---------------------------------------------------------
-- The stories
-- ---------------------------------------------------------

requirement
    :: Theorem thm -> Requirement -> LeanCheck CliI thm [Receipt]
requirement thm req = bindCheck thm (action . Require req)

-- | The key the registry already holds, and the key it has never held.
heldKey, freshKey :: String
heldKey = "held"
freshKey = "fresh"

{- | The premise a telling builds on: the ordinary commands that bring a
key to its state, each of which must succeed, then a fresh reading of that
exact key in that registry. A premise that does not hold leaves every later
clause of the telling uncovered.
-}
premiseClause
    :: Theorem thm
    -> String
    -> Requirement
    -> Story [Receipt]
    -> TheoremStory thm CliI [Receipt]
premiseClause thm title req = clause title (requirement thm req)

{- | Create a registry and bring 'heldKey' to Active with the ordinary
commands — and, when asked, to Terminal — then inspect it.
-}
reach :: Bool -> Target -> Story [Receipt]
reach terminal target = do
    created <- action (Run Create target "")
    inserted <- action (Run Insert target heldKey)
    terminated <-
        if terminal
            then pure <$> action (Run Terminate target heldKey)
            else pure []
    seen <- action (Run Inspect target heldKey)
    pure ([created, inserted] <> terminated <> [seen])

{- | The shared shape of both refusals, after their premise. On the control
registry, an absent key booked through the application and folded without
local evaluation is accepted. On the target, the ordinary @insert@ of the
held key is booked, stops partial and names its pending request; that
request's fold, submitted without local evaluation, is refused by the
registry's state validator; and nothing changes.
-}
refusal
    :: Theorem thm
    -> Requirement
    -> String
    -> Target
    -> Target
    -> String
    -> TheoremStory thm CliI ()
refusal thm reachedReq premiseTitle control target keyWhat = do
    _ <-
        clause
            premiseTitle
            ( bindCheck thm $ \(controlPrefix, targetPrefix) -> do
                action (Require reachedReq controlPrefix)
                action (Require reachedReq targetPrefix)
            )
            ( do
                controlPrefix <- reach (reachedReq == ReachedTerminal) control
                targetPrefix <- reach (reachedReq == ReachedTerminal) target
                pure (controlPrefix, targetPrefix)
            )
    _ <-
        clause
            "an absent key, booked through the application and folded without local evaluation, is accepted"
            (requirement thm Accepted)
            ( do
                booking <- action (Book control freshKey)
                _ <- action (Require Accepted [booking])
                fold <- action (FoldUnevaluated control freshKey)
                pure [fold]
            )
    (_, before) <-
        clause
            ( "the ordinary insert of "
                <> keyWhat
                <> " is booked, stops partial and names its pending request"
            )
            ( bindCheck
                thm
                (\(cli, seen) -> action (Require PartialPending [cli, seen]))
            )
            ( do
                cli <- action (Run Insert target heldKey)
                seen <- action (Observe target heldKey)
                pure (cli, seen)
            )
    _ <-
        clause
            "that request's fold, submitted without local evaluation, is refused by the registry's state validator"
            (requirement thm RefusedByState)
            (pure <$> action (FoldUnevaluated target heldKey))
    _ <-
        clause
            "the registry's root, the key's holding, the pending request and the wallet are unchanged"
            (requirement thm Unchanged)
            ( do
                after <- action (Observe target heldKey)
                pure [before, after]
            )
    pure ()

-- | A second insertion of an Active key.
duplicateStory :: Story ()
duplicateStory =
    theorem duplicateRefused $
        refusal
            duplicateRefused
            ReachedActive
            "the key reached Active through the ordinary commands, in the control registry and in the target, and inspect reads it Active in each"
            (Target "duplicate-control")
            (Target "duplicate")
            "the Active key"

-- | An insertion of a key already Terminal.
resurrectionStory :: Story ()
resurrectionStory =
    theorem resurrectionRefused $
        refusal
            resurrectionRefused
            ReachedTerminal
            "the key reached Terminal through the ordinary commands, in the control registry and in the target, and inspect reads it Terminal in each"
            (Target "resurrection-control")
            (Target "resurrection")
            "the Terminal key"

{- | Alice's story through the ordinary commands, judged against the
receipts the commands print: create, insert, inspect, two updates with
unrelated payloads, terminate, inspect.
-}
lifecycleStory :: Story ()
lifecycleStory = do
    let target = Target "lifecycle"
        alice = "alice"
    inserted <-
        theorem insertionHoldingInline $
            clause
                "the ordinary insert delivers the key's one token to the application, under the inserted envelope inline, in the registry create booted"
                ( bindCheck insertionHoldingInline $ \(created, ins, seen) -> do
                    action (Require SameRegistry [created, ins])
                    action (Require Delivered [ins, seen])
                )
                ( do
                    created <- action (Run Create target "")
                    ins <- action (Run Insert target alice)
                    seen <- action (Run Inspect target alice)
                    pure (created, ins, seen)
                )
    let (_, _, afterInsert) = inserted
    afterFirst <-
        theorem updateKeepsRegistry $
            clause
                "the controller's update replaces the payload; the registry's root does not move"
                ( bindCheck updateKeepsRegistry $ \(before, upd, after) ->
                    action (Require PayloadReplaced [before, upd, after])
                )
                ( do
                    upd <- action (Run (Update 1) target alice)
                    after <- action (Run Inspect target alice)
                    pure (afterInsert, upd, after)
                )
    let (_, _, afterUpdate) = afterFirst
    afterSecond <-
        theorem updatePayloadFree $
            clause
                "a second update with an unrelated payload is accepted the same way"
                ( bindCheck updatePayloadFree $ \(before, upd, after) ->
                    action (Require PayloadReplaced [before, upd, after])
                )
                ( do
                    upd <- action (Run (Update 2) target alice)
                    after <- action (Run Inspect target alice)
                    pure (afterUpdate, upd, after)
                )
    let (_, _, beforeTerminate) = afterSecond
    theorem releaseBurnsAtomically $
        void $
            clause
                "the ordinary terminate burns the key's token and releases its protected deposit; the key reads Terminal"
                ( bindCheck releaseBurnsAtomically $ \(before, term, after) ->
                    action (Require Released [before, term, after])
                )
                ( do
                    term <- action (Run Terminate target alice)
                    after <- action (Run Inspect target alice)
                    pure (beforeTerminate, term, after)
                )

{- | The application's own boundary, reached by hand-built transactions the
node judges: the controller's update beside an update required of another
wallet, the Aiken suite's custody tampers realisable on a ledger, and a
release outside any fold beside the ordinary terminate.
-}
boundaryStory :: Story ()
boundaryStory = do
    let target = Target "boundary"
    theorem updateRequiresController $ do
        _ <-
            premiseClause
                updateRequiresController
                "the key reached Active through the ordinary commands, and inspect reads it Active"
                ReachedActive
                (reach False target)
        _ <-
            clause
                "the controller's own update, built by hand and submitted without local evaluation, is accepted"
                (requirement updateRequiresController Accepted)
                (pure <$> action (Craft HonestUpdate target heldKey))
        before <- readback updateRequiresController target
        _ <-
            clause
                "the same update, requiring another wallet's signature instead of the controller's, is refused by the application"
                (requirement updateRequiresController RefusedByApplication)
                (pure <$> action (Craft UpdateByStranger target heldKey))
        _ <-
            clause
                "the same update without the application's script is rejected before any script runs, and is not counted as a refusal"
                (requirement updateRequiresController RejectedBeforeScripts)
                (pure <$> action (Craft UpdateWithoutScript target heldKey))
        unchangedAfter updateRequiresController target before
    theorem updatePreservesCustody $ do
        _ <- stillActive updatePreservesCustody target
        _ <-
            clause
                "another controller's update, built the same way, is accepted"
                (requirement updatePreservesCustody Accepted)
                (pure <$> action (Craft HonestUpdate target heldKey))
        before <- readback updatePreservesCustody target
        forM_ tampers $ \c ->
            clause
                (craftedPhrase c <> " is refused by the application")
                (requirement updatePreservesCustody RefusedByApplication)
                (pure <$> action (Craft c target heldKey))
        unchangedAfter updatePreservesCustody target before
    theorem onlyFoldReleases $ do
        _ <- stillActive onlyFoldReleases target
        before <- readback onlyFoldReleases target
        _ <-
            clause
                "a release of the live holding outside any fold is refused by the application"
                (requirement onlyFoldReleases RefusedByApplication)
                (pure <$> action (Craft EarlyWithdrawal target heldKey))
        unchangedAfter onlyFoldReleases target before
        void $
            clause
                "the same holding, released inside the registry's fold by the ordinary terminate, is accepted"
                (requirement onlyFoldReleases CommandSucceeded)
                (pure <$> action (Run Terminate target heldKey))
  where
    tampers =
        [ UpdateOtherController
        , UpdateDepositTampered
        , UpdateEscaped
        , UpdateTokenLeft
        , UpdateShortDeposit
        , UpdateWithoutDatum
        , UpdateAddedAsset
        ]
    readback :: Theorem thm -> Target -> TheoremStory thm CliI Receipt
    readback thm target =
        clause
            "the registry, the key's holding and the wallet are read back"
            (bindCheck thm (\r -> action (Require Observed [r])))
            (action (Observe target heldKey))
    unchangedAfter
        :: Theorem thm -> Target -> Receipt -> TheoremStory thm CliI ()
    unchangedAfter thm target before =
        void $
            clause
                "the registry's root, the key's holding and the wallet are unchanged by every refusal"
                (requirement thm HoldingUnchanged)
                ( do
                    after <- action (Observe target heldKey)
                    pure [before, after]
                )

-- | Read back the registry, a key's holding and the wallet, in a clause.
readbackOf
    :: Theorem thm -> Target -> String -> TheoremStory thm CliI Receipt
readbackOf thm target key =
    clause
        "the registry, its pending requests and the wallet are read back"
        (bindCheck thm (\r -> action (Require Observed [r])))
        (action (Observe target key))

-- | Read back again and require the given agreement with the first readback.
unchangedOf
    :: Theorem thm
    -> Requirement
    -> String
    -> Target
    -> String
    -> Receipt
    -> TheoremStory thm CliI ()
unchangedOf thm req title target key before =
    void $
        clause
            title
            (requirement thm req)
            ( do
                after <- action (Observe target key)
                pure [before, after]
            )

-- | One refusal clause for a crafted transaction, by its phrase.
refusedCraft
    :: Theorem thm -> Crafted -> Target -> String -> TheoremStory thm CliI ()
refusedCraft thm c target key =
    void $
        clause
            (craftedPhrase c <> " is refused by the application")
            (requirement thm RefusedByApplication)
            (pure <$> action (Craft c target key))

{- | Bookings the application must refuse, beside a booking it certifies:
the controller's envelope booked by another wallet, a request naming
another destination or no datum, a short request deposit, and envelopes
naming another registry's state asset. Each refused booking leaves the
registry, its pending requests and the wallet as they were.
-}
bookingStory :: Story ()
bookingStory = do
    let target = Target "booking"
    created <- theorem bookInsertInversion $ do
        created <-
            premiseClause
                bookInsertInversion
                "the registry was created by the ordinary command"
                Established
                (pure <$> action (Run Create target ""))
        _ <-
            clause
                "an insertion booked through the application by the controller is accepted"
                (requirement bookInsertInversion Accepted)
                (pure <$> action (Book target "booked"))
        before <- readbackOf bookInsertInversion target "booked"
        refusedCraft
            bookInsertInversion
            BookingByStranger
            target
            "by-stranger"
        refusedCraft
            bookInsertInversion
            BookingOtherDestination
            target
            "other-destination"
        refusedCraft
            bookInsertInversion
            BookingShortDeposit
            target
            "short-deposit"
        refusedCraft bookInsertInversion BookingNoDatum target "no-datum"
        unchangedOf
            bookInsertInversion
            RegistryUnchanged
            "the registry's root, its pending requests and the wallet are unchanged by every refusal"
            target
            "booked"
            before
        pure created
    theorem insertionRequiresRegistryIdentity $ do
        _ <-
            premiseClause
                insertionRequiresRegistryIdentity
                "the same registry, created by the ordinary command"
                Established
                (pure created)
        _ <-
            clause
                "an envelope naming this registry, booked the same way, is accepted"
                (requirement insertionRequiresRegistryIdentity Accepted)
                (pure <$> action (Book target "named"))
        before <- readbackOf insertionRequiresRegistryIdentity target "named"
        refusedCraft
            insertionRequiresRegistryIdentity
            EnvelopeOtherStateName
            target
            "other-name"
        refusedCraft
            insertionRequiresRegistryIdentity
            EnvelopeOtherStatePolicy
            target
            "other-policy"
        refusedCraft
            insertionRequiresRegistryIdentity
            EnvelopeOtherRegistry
            target
            "other-registry"
        unchangedOf
            insertionRequiresRegistryIdentity
            RegistryUnchanged
            "the registry's root, its pending requests and the wallet are unchanged by every refusal"
            target
            "named"
            before

{- | A termination and its fold. A stranger's termination booking is
refused beside the controller's own; the terminating fold paying the
controller one lovelace short is refused beside the same fold paying in
full; and a fold of another request that also releases a live holding is
refused beside the same fold without the release.
-}
settlementStory :: Story ()
settlementStory = do
    let target = Target "settlement"
    theorem bookTerminateInversion $ do
        _ <-
            clause
                "two keys reached Active through the ordinary commands, and inspect reads each Active"
                ( bindCheck bookTerminateInversion $ \(heldPrefix, otherPrefix) -> do
                    action (Require ReachedActive heldPrefix)
                    action (Require ReachedActive otherPrefix)
                )
                ( do
                    heldPrefix <- reach False target
                    inserted <- action (Run Insert target otherKey)
                    seen <- action (Run Inspect target otherKey)
                    pure (heldPrefix, [inserted, seen])
                )
        before <- readbackOf bookTerminateInversion target heldKey
        refusedCraft
            bookTerminateInversion
            TerminateBookingByStranger
            target
            heldKey
        unchangedOf
            bookTerminateInversion
            RegistryUnchanged
            "the registry's root, its pending requests and the wallet are unchanged by the refusal"
            target
            heldKey
            before
        void $
            clause
                "the controller's own termination booking is accepted"
                (requirement bookTerminateInversion Accepted)
                (pure <$> action (Craft TerminateBooking target heldKey))
    theorem foldSettlesAdditively $ do
        _ <- stillActive foldSettlesAdditively target
        before <- readbackOf foldSettlesAdditively target heldKey
        refusedCraft foldSettlesAdditively FoldPaysShort target heldKey
        unchangedOf
            foldSettlesAdditively
            HoldingUnchanged
            "the registry's root, the key's holding and the wallet are unchanged by the refusal"
            target
            heldKey
            before
        _ <-
            clause
                "the same terminating fold, folded by another wallet, paying the controller in full, is accepted"
                (requirement foldSettlesAdditively Accepted)
                (pure <$> action (Craft FoldPaysInFull target heldKey))
        -- One controller, two releases in one fold; then an insertion and a
        -- termination in one fold. Each short payment is refused beside the
        -- same fold paid in full, and neither refusal moves anything.
        let batch = Target "batch"
        _ <-
            clause
                "a second registry holds three of the controller's keys Active, and inspect reads each Active"
                ( bindCheck foldSettlesAdditively $ \(first, others) -> do
                    action (Require ReachedActive first)
                    mapM_ (action . Require ReachedActive) others
                )
                ( do
                    created <- action (Run Create batch "")
                    pairs <-
                        mapM
                            ( \k -> do
                                inserted <- action (Run Insert batch k)
                                seen <- action (Run Inspect batch k)
                                pure [inserted, seen]
                            )
                            ["pair-a", "pair-b", "mixed-old"]
                    case pairs of
                        (p : ps) -> pure (created : p, ps)
                        [] -> pure ([created], [])
                )
        _ <-
            clause
                "the controller's terminations of two keys are booked"
                ( bindCheck foldSettlesAdditively $ \bs ->
                    mapM_ (\b -> action (Require Accepted [b])) bs
                )
                ( mapM
                    (action . Craft TerminateBooking batch)
                    ["pair-a", "pair-b"]
                )
        pairBefore <-
            clause
                "the registry, the first key's holding and the wallet are read back before the two-release fold"
                (bindCheck foldSettlesAdditively (\r -> action (Require Observed [r])))
                (action (Observe batch "pair-a"))
        refusedCraft foldSettlesAdditively FoldTwoReleasesShort batch "pair-a"
        refusedCraft
            foldSettlesAdditively
            FoldTwoReleasesOneFloor
            batch
            "pair-a"
        unchangedOf
            foldSettlesAdditively
            HoldingUnchanged
            "the registry's root, the first key's holding and the wallet are unchanged by both refusals"
            batch
            "pair-a"
            pairBefore
        _ <-
            clause
                "the two-release fold paying the controller the sum in full is accepted"
                (requirement foldSettlesAdditively Accepted)
                (pure <$> action (Craft FoldTwoReleasesInFull batch "pair-a"))
        _ <-
            clause
                "an insertion of a new key and the termination of another are booked for the controller"
                ( bindCheck foldSettlesAdditively $ \bs ->
                    mapM_ (\b -> action (Require Accepted [b])) bs
                )
                ( do
                    inserted <- action (Book batch "mixed-new")
                    terminated <- action (Craft TerminateBooking batch "mixed-old")
                    pure [inserted, terminated]
                )
        mixedBefore <-
            clause
                "the registry, the terminated key's holding and the wallet are read back before the mixed fold"
                (bindCheck foldSettlesAdditively (\r -> action (Require Observed [r])))
                (action (Observe batch "mixed-old"))
        refusedCraft foldSettlesAdditively FoldMixedShort batch "mixed-old"
        unchangedOf
            foldSettlesAdditively
            HoldingUnchanged
            "the registry's root, the terminated key's holding and the wallet are unchanged by the refusal"
            batch
            "mixed-old"
            mixedBefore
        void $
            clause
                "the mixed fold paying the controller in full is accepted"
                (requirement foldSettlesAdditively Accepted)
                (pure <$> action (Craft FoldMixedInFull batch "mixed-old"))
    theorem foldInversion $ do
        _ <-
            premiseClause
                foldInversion
                "the other key still reads Active, from a readback whose mirror copy agrees with the chain's root"
                ReachedActive
                (pure <$> action (Observe target otherKey))
        _ <-
            clause
                "an insertion of an absent key, booked through the application, is accepted"
                (requirement foldInversion Accepted)
                (pure <$> action (Book target freshKey))
        before <- readbackOf foldInversion target otherKey
        refusedCraft foldInversion ReleaseInOtherFold target otherKey
        unchangedOf
            foldInversion
            HoldingUnchanged
            "the registry's root, the other key's holding and the wallet are unchanged by the refusal"
            target
            otherKey
            before
        void $
            clause
                "the same fold, without the release, is accepted"
                (requirement foldInversion Accepted)
                (pure <$> action (FoldUnevaluated target freshKey))
  where
    otherKey = "other"

controlsStory :: Story ()
controlsStory =
    duplicateStory
        >> resurrectionStory
        >> lifecycleStory
        >> boundaryStory
        >> bookingStory
        >> settlementStory

-- ---------------------------------------------------------
-- Receipts
-- ---------------------------------------------------------

-- | A readback of one registry, for one key.
data Observation = Observation
    { obRoot :: Text
    -- ^ The root the registry's state output commits to
    , obHolding :: Maybe Text
    -- ^ The key's one live holding at the application, if any
    , obHoldingLovelace :: Maybe Integer
    , obPending :: [Text]
    -- ^ The requests pending at the registry's request address
    , obPendingLovelace :: Integer
    , obWalletLovelace :: Integer
    , obLeaf :: Maybe Text
    {- ^ The key's leaf, read from a mirror copy whose root is the root the
    chain holds: @active@, @terminal@ or @absent@; nothing when no copy
    agrees with the chain
    -}
    }
    deriving stock (Eq, Show)

instance ToJSON Observation where
    toJSON o =
        object
            [ "root" .= obRoot o
            , "holding" .= obHolding o
            , "holdingLovelace" .= obHoldingLovelace o
            , "pending" .= obPending o
            , "pendingLovelace" .= obPendingLovelace o
            , "walletLovelace" .= obWalletLovelace o
            , "leaf" .= obLeaf o
            ]

instance FromJSON Observation where
    parseJSON = withObject "observation" $ \o ->
        Observation
            <$> o .: "root"
            <*> o .:? "holding"
            <*> o .:? "holdingLovelace"
            <*> o .: "pending"
            <*> o .: "pendingLovelace"
            <*> o .: "walletLovelace"
            <*> o .:? "leaf"

{- | What one action left. The step number, action, target and key say
which action it answers; a receipt answering another is not accepted.
-}
data Receipt = Receipt
    { rcStep :: Int
    , rcAction :: Text
    , rcTarget :: Text
    , rcKey :: Text
    , rcOutcome :: Text
    {- ^ A command's own outcome class; @accepted@, @ledger-refused@,
    @client-error@, @submit-unknown@ or @unconfirmed@ for a booking or a
    fold; @observed@ for a readback
    -}
    , rcTxId :: Maybe Text
    , rcPendingRequest :: Maybe Text
    -- ^ The request a stopped command names as left pending
    , rcEvaluation :: Maybe Text
    -- ^ @skipped@ for a fold submitted without local evaluation
    , rcStateValidator :: Maybe Text
    -- ^ The registry's state validator hash, from its pins
    , rcApplication :: Maybe Text
    -- ^ The applied open-datum script's hash, from its pins
    , rcRefusingScripts :: [Text]
    -- ^ The script hashes the node's refusal names
    , rcPhaseWords :: [Text]
    {- ^ The node's words for a script that executed and failed, as they
    occur in its rejection: @PlutusFailure@, @CekError@; none for a
    rejection before any script ran
    -}
    , rcRejectionFile :: Maybe Text
    -- ^ The node's full rejection text, kept beside the receipt
    , rcRejectionSha256 :: Maybe Text
    , rcBodyFile :: Maybe Text
    -- ^ The submitted transaction's body, kept beside the receipt
    , rcBodySha256 :: Maybe Text
    , rcSubmissions :: [Submission]
    {- ^ For an ordinary command: every submission its registry's journal
    recorded while it ran, with the body the command kept
    -}
    , rcAdmission :: Maybe [Text]
    {- ^ What reading the retained body and rejection back found wrong;
    nothing until the receipt is admitted. Never read from a receipt file:
    only admission sets it.
    -}
    , rcReason :: Maybe Text
    -- ^ The node's or the command's own words, bounded
    , rcObservation :: Maybe Observation
    , rcEvidence :: [Text]
    -- ^ Files beside the receipt: command output, transaction bodies
    , rcCommand :: Maybe Aeson.Value
    -- ^ A command's own printed receipt, as it printed it
    }
    deriving stock (Eq, Show)

emptyReceipt :: Int -> Text -> Text -> Text -> Receipt
emptyReceipt step act target key =
    Receipt
        { rcStep = step
        , rcAction = act
        , rcTarget = target
        , rcKey = key
        , rcOutcome = ""
        , rcTxId = Nothing
        , rcPendingRequest = Nothing
        , rcEvaluation = Nothing
        , rcStateValidator = Nothing
        , rcApplication = Nothing
        , rcRefusingScripts = []
        , rcPhaseWords = []
        , rcRejectionFile = Nothing
        , rcRejectionSha256 = Nothing
        , rcBodyFile = Nothing
        , rcBodySha256 = Nothing
        , rcSubmissions = []
        , rcAdmission = Nothing
        , rcReason = Nothing
        , rcObservation = Nothing
        , rcEvidence = []
        , rcCommand = Nothing
        }

instance ToJSON Receipt where
    toJSON r =
        object
            [ "step" .= rcStep r
            , "action" .= rcAction r
            , "target" .= rcTarget r
            , "key" .= rcKey r
            , "outcome" .= rcOutcome r
            , "txId" .= rcTxId r
            , "pendingRequest" .= rcPendingRequest r
            , "evaluation" .= rcEvaluation r
            , "stateValidator" .= rcStateValidator r
            , "application" .= rcApplication r
            , "refusingScripts" .= rcRefusingScripts r
            , "phaseWords" .= rcPhaseWords r
            , "rejectionFile" .= rcRejectionFile r
            , "rejectionSha256" .= rcRejectionSha256 r
            , "bodyFile" .= rcBodyFile r
            , "bodySha256" .= rcBodySha256 r
            , "submissions" .= rcSubmissions r
            , "reason" .= rcReason r
            , "observation" .= rcObservation r
            , "evidence" .= rcEvidence r
            , "command" .= rcCommand r
            ]

instance FromJSON Receipt where
    parseJSON = withObject "receipt" $ \o ->
        Receipt
            <$> o .: "step"
            <*> o .: "action"
            <*> o .: "target"
            <*> o .: "key"
            <*> o .: "outcome"
            <*> o .:? "txId"
            <*> o .:? "pendingRequest"
            <*> o .:? "evaluation"
            <*> o .:? "stateValidator"
            <*> o .:? "application"
            <*> o .: "refusingScripts"
            <*> (fromMaybe [] <$> o .:? "phaseWords")
            <*> o .:? "rejectionFile"
            <*> o .:? "rejectionSha256"
            <*> o .:? "bodyFile"
            <*> o .:? "bodySha256"
            <*> (fromMaybe [] <$> o .:? "submissions")
            <*> pure Nothing
            <*> o .:? "reason"
            <*> o .:? "observation"
            <*> o .: "evidence"
            <*> o .:? "command"

-- | The action name, target and key a receipt for this action must carry.
identify :: CliI res -> Maybe (Text, Text, Text)
identify i = case i of
    Run c (Target t) k -> Just ("run " <> T.pack (commandName c), T.pack t, T.pack k)
    Book (Target t) k -> Just ("book", T.pack t, T.pack k)
    FoldUnevaluated (Target t) k -> Just ("fold-unevaluated", T.pack t, T.pack k)
    Observe (Target t) k -> Just ("observe", T.pack t, T.pack k)
    Craft c (Target t) k ->
        Just ("craft " <> T.pack (craftedName c), T.pack t, T.pack k)
    Require _ _ -> Nothing

-- ---------------------------------------------------------
-- Checks
-- ---------------------------------------------------------

-- | A value inside a command's own receipt, by object keys and list indices.
at :: [Either Text Int] -> Receipt -> Maybe Aeson.Value
at path r = go path =<< rcCommand r
  where
    go [] v = Just v
    go (Left k : rest) (Aeson.Object o) = go rest =<< KeyMap.lookup (Key.fromText k) o
    go (Right i : rest) (Aeson.Array a) = go rest =<< (a V.!? i)
    go _ _ = Nothing

field :: Text -> Either Text Int
field = Left

-- | Fail unless a command receipt says @success@ and its submissions were admitted.
succeeded :: String -> Receipt -> [String]
succeeded what r =
    [ what <> "'s outcome is " <> show (rcOutcome r) <> ", not success"
    | rcOutcome r /= "success"
    ]
        <> map ((what <> ": ") <>) (admitted r)

-- | Fail unless two receipt values are present and equal.
same :: String -> Maybe Aeson.Value -> Maybe Aeson.Value -> [String]
same what a b = case (a, b) of
    (Just x, Just y) | x == y -> []
    (Nothing, _) -> [what <> ": the first receipt does not carry it"]
    (_, Nothing) -> [what <> ": the second receipt does not carry it"]
    _ -> [what <> " differs"]

-- | Fail unless a receipt value is present and equals the one expected.
is :: String -> Aeson.Value -> Maybe Aeson.Value -> [String]
is what expected v =
    [ what <> " is " <> maybe "absent" plain v <> ", not " <> plain expected
    | v /= Just expected
    ]
  where
    plain value = case value of
        Aeson.String t -> show t
        Aeson.Array a | V.null a -> "none"
        other -> show other

-- | The requirement's failures on these receipts; none means it holds.
check :: Requirement -> [Receipt] -> [String]
check req rs = case (req, rs) of
    (Established, cs@(_ : _)) ->
        concatMap (\c -> succeeded ("the " <> T.unpack (rcAction c)) c) cs
            <> oneRegistry cs
    (ReachedActive, _ : _) -> reachedLeaf "active" rs
    (ReachedTerminal, _ : _) -> reachedLeaf "terminal" rs
    (RejectedBeforeScripts, [r]) ->
        [ "the outcome is "
            <> show (rcOutcome r)
            <> ", not a rejection by the node"
        | rcOutcome r /= "ledger-refused"
        ]
            <> case rcApplication r of
                Nothing -> ["the applied open-datum script is not recorded"]
                Just h -> case attribution h r of
                    Left (NotPhase2 _) ->
                        [ "the rejection does not name the open-datum script, so it does not test the attribution"
                        | h `notElem` rcRefusingScripts r
                        ]
                    _ ->
                        [ "a script executed and failed; this is not a rejection before any script ran"
                        ]
            <> submitted r
    (Observed, [r]) ->
        [ "the readback's outcome is " <> show (rcOutcome r) <> ", not observed"
        | rcOutcome r /= "observed"
        ]
    (RefusedByApplication, [r]) ->
        [ "the transaction was evaluated locally, so the node never judged it"
        | rcEvaluation r /= Just "skipped"
        ]
            <> [ "the outcome is "
                    <> show (rcOutcome r)
                    <> ", not a refusal by the node"
               | rcOutcome r /= "ledger-refused"
               ]
            <> attributedTo "applied open-datum script" (rcApplication r) r
    (RegistryUnchanged, [a, b]) -> case (rcObservation a, rcObservation b) of
        (Just x, Just y) ->
            ["the registry's root moved" | obRoot x /= obRoot y]
                <> [ "the pending requests changed"
                   | (obPending x, obPendingLovelace x)
                        /= (obPending y, obPendingLovelace y)
                   ]
                <> ["the wallet changed" | obWalletLovelace x /= obWalletLovelace y]
                <> [ "the readbacks are of different registries"
                   | rcTarget a /= rcTarget b
                   ]
        _ -> ["a readback carries no observation"]
    (HoldingUnchanged, [a, b]) -> case (rcObservation a, rcObservation b) of
        (Just x, Just y) ->
            ["the registry's root moved" | obRoot x /= obRoot y]
                <> [ "the key's holding changed"
                   | (obHolding x, obHoldingLovelace x)
                        /= (obHolding y, obHoldingLovelace y)
                   ]
                <> ["the wallet changed" | obWalletLovelace x /= obWalletLovelace y]
                <> ["the key has no live holding to protect" | isNothing (obHolding y)]
                <> [ "the readbacks are of different registries or keys"
                   | (rcTarget a, rcKey a) /= (rcTarget b, rcKey b)
                   ]
        _ -> ["a readback carries no observation"]
    (SameRegistry, [c, i]) ->
        succeeded "the create" c
            <> succeeded "the insert" i
            <> same
                "the registry's state policy"
                (at [field "pins", field "pinState"] c)
                ( at
                    (controlPath <> [Right 1, field "fields", Right 0, field "bytes"])
                    i
                )
            <> same
                "the registry's state token"
                (at [field "token"] c)
                ( at
                    (controlPath <> [Right 1, field "fields", Right 1, field "bytes"])
                    i
                )
            <> same
                "the registry's active policy"
                (at [field "pins", field "pinActive"] c)
                (at (controlPath <> [Right 2, field "bytes"]) i)
    (Delivered, [i, s]) ->
        succeeded "the insert" i
            <> succeeded "the inspect" s
            <> is "the key's leaf" "active" (at [field "leaf"] s)
            <> same
                "the holding's output"
                (at [field "liveOutput"] i)
                (at [field "applicationOutput", field "output"] s)
            <> same
                "the holding's inline envelope"
                (at [field "envelope"] i)
                (at [field "applicationOutput", field "envelope"] s)
            <> case ( at [field "applicationOutput", field "lovelace"] s
                    , at [field "applicationOutput", field "deposit"] s
                    ) of
                (Just (Aeson.Number l), Just (Aeson.Number d))
                    | l >= d -> []
                    | otherwise -> ["the holding holds less than its protected deposit"]
                _ -> ["the holding's lovelace or deposit is not read back"]
    (PayloadReplaced, [b, u, a]) ->
        succeeded "the update" u
            <> succeeded "the inspect before" b
            <> succeeded "the inspect after" a
            <> same
                "the root across the update"
                (at [field "root"] b)
                (at [field "root"] a)
            <> same
                "the root the update reports"
                (at [field "root"] b)
                (at [field "root"] u)
            <> same
                "the payload"
                (at [field "payload"] u)
                (at [field "applicationOutput", field "payload"] a)
            <> same
                "the holding's output"
                (at [field "liveOutput"] u)
                (at [field "applicationOutput", field "output"] a)
            <> same
                "the controller"
                (at [field "applicationOutput", field "controller"] b)
                (at [field "applicationOutput", field "controller"] a)
            <> same
                "the protected deposit"
                (at [field "applicationOutput", field "deposit"] b)
                (at [field "applicationOutput", field "deposit"] a)
            <> is "the key's leaf" "active" (at [field "leaf"] a)
    (Released, [b, t, a]) ->
        succeeded "the terminate" t
            <> succeeded "the inspect after" a
            <> is "the key's leaf" "terminal" (at [field "leaf"] a)
            <> is
                "the key's holdings"
                (Aeson.Array mempty)
                (at [field "applicationOutput", field "holdings"] a)
            <> same
                "the released deposit"
                (at [field "applicationOutput", field "deposit"] b)
                (at [field "deposit"] t)
            <> case at [field "released"] t of
                Just (Aeson.String _) -> []
                _ -> ["the terminate names no released output"]
    (CommandSucceeded, [r]) -> succeeded "the command" r
    (Accepted, [r]) ->
        [ "the outcome is " <> show (rcOutcome r) <> ", not accepted"
        | rcOutcome r /= "accepted"
        ]
            <> submitted r
    (RefusedByState, [r]) ->
        [ "the fold was evaluated locally, so the node never judged it"
        | rcEvaluation r /= Just "skipped"
        ]
            <> [ "the outcome is "
                    <> show (rcOutcome r)
                    <> ", not a refusal by the node"
               | rcOutcome r /= "ledger-refused"
               ]
            <> attributedTo "registry's state validator" (rcStateValidator r) r
    (Unchanged, [a, b]) -> case (rcObservation a, rcObservation b) of
        (Just x, Just y) ->
            [ "the registry's root moved"
            | obRoot x /= obRoot y
            ]
                <> [ "the key's holding changed"
                   | (obHolding x, obHoldingLovelace x)
                        /= (obHolding y, obHoldingLovelace y)
                   ]
                <> [ "the pending requests changed"
                   | (obPending x, obPendingLovelace x)
                        /= (obPending y, obPendingLovelace y)
                   ]
                <> [ "the wallet changed"
                   | obWalletLovelace x /= obWalletLovelace y
                   ]
                <> [ "no booking is pending, so nothing was refused"
                   | null (obPending y)
                   ]
                <> [ "the readbacks are of different registries or keys"
                   | (rcTarget a, rcKey a) /= (rcTarget b, rcKey b)
                   ]
        _ -> ["a readback carries no observation"]
    (PartialPending, [c, o]) ->
        [ "the command's outcome is " <> show (rcOutcome c) <> ", not partial"
        | rcOutcome c /= "partial"
        ]
            <> map ("the command: " <>) (admitted c)
            <> case (rcPendingRequest c, rcObservation o) of
                (Nothing, _) -> ["the command names no pending request"]
                (_, Nothing) -> ["the readback carries no observation"]
                (Just p, Just seen) ->
                    [ "the request " <> T.unpack p <> " the command names is not pending"
                    | p `notElem` obPending seen
                    ]
            <> [ "the readback is of another registry"
               | rcTarget c /= rcTarget o
               ]
    (_, _) ->
        [ show req
            <> " takes "
            <> ( if req
                    `elem` [ Unchanged
                           , PartialPending
                           , HoldingUnchanged
                           , RegistryUnchanged
                           , SameRegistry
                           , Delivered
                           ]
                    then "two"
                    else if req `elem` [PayloadReplaced, Released] then "three" else "one"
               )
            <> " receipts, given "
            <> show (length rs)
        ]

-- ---------------------------------------------------------
-- Judging
-- ---------------------------------------------------------

data ClauseStatus
    = Held
    | NotHeld [String]
    | Uncovered String
    deriving stock (Eq, Show)

data ClauseResult = ClauseResult
    { crStatement :: String
    , crTitle :: String
    , crStatus :: ClauseStatus
    }
    deriving stock (Eq, Show)

-- | Every clause's verdict holds.
held :: [ClauseResult] -> Bool
held = all ((== Held) . crStatus)

{- | Interpret the story over receipts. A receipt answers the action at its
step exactly when it names that action, target and key; the first missing
or misplaced receipt leaves every later clause uncovered, naming why.
Requirements inside a clause's body fail the clause; its check decides it.
-}
judge :: [Receipt] -> Story () -> [ClauseResult]
judge receipts story =
    let byStep = Map.fromListWith (<>) [(rcStep r, [r]) | r <- receipts]
        (reached, stop) = replay byStep story
        names = outline story
        missing = drop (length reached) names
        why = fromMaybe "no receipt" stop
    in  reached
            <> [ClauseResult s t (Uncovered why) | (s, t) <- missing]

type Receipts = Map.Map Int [Receipt]

-- The replay's state: the next step, the clauses judged, the stop.
data Replay = Replay Int [ClauseResult] (Maybe String)

replay :: Receipts -> Story () -> ([ClauseResult], Maybe String)
replay byStep story =
    let Replay _ results stop = snd (go (Replay 0 [] Nothing) story)
    in  (reverse results, stop)
  where
    go :: Replay -> Story a -> (Maybe a, Replay)
    go st@(Replay _ _ (Just _)) _ = (Nothing, st)
    go st program = case view program of
        Return a -> (Just a, st)
        Action i :>>= next -> case perform st i of
            (Just r, st') -> go st' (next r)
            (Nothing, st') -> (Nothing, st')
        Theorem thm body :>>= next ->
            case goClauses (boName (theoremBinding thm)) Nothing st (clauses body) of
                (Just r, st') -> go st' (next r)
                (Nothing, st') -> (Nothing, st')

    goClauses
        :: String
        -> Maybe String
        -> Replay
        -> Program (Clause thm CliI) a
        -> (Maybe a, Replay)
    goClauses _ _ st@(Replay _ _ (Just _)) _ = (Nothing, st)
    goClauses name premise st program = case view program of
        Return a -> (Just a, st)
        Clause title leanCheck body :>>= next ->
            let (inner, Replay n rs stop) = collect st body
            in  case (inner, stop) of
                    (Just (obs, (bodyFailures, _)), Nothing) ->
                        let (checked, Replay n' _ stop') =
                                collect (Replay n [] Nothing) (checkAction leanCheck obs)
                            failures =
                                bodyFailures <> maybe [] (fst . snd) checked
                            isPremise = maybe False (snd . snd) checked
                            status
                                | Just why <- stop' = Uncovered why
                                | Just failed <- premise =
                                    Uncovered ("its premise does not hold: " <> failed)
                                | null failures = Held
                                | otherwise = NotHeld failures
                            premise'
                                | Just _ <- premise = premise
                                | isPremise && status /= Held = Just title
                                | otherwise = Nothing
                            result = ClauseResult name title status
                        in  goClauses
                                name
                                premise'
                                (Replay n' (result : rs) stop')
                                (next obs)
                    _ ->
                        ( Nothing
                        , Replay n rs (Just (fromMaybe "no receipt" stop))
                        )

    {- Walk a program, collecting the failures of the requirements in it and
    whether any of them is a premise the rest of the telling depends on. -}
    collect :: Replay -> Story a -> (Maybe (a, ([String], Bool)), Replay)
    collect st0 = walk st0 ([], False)
      where
        walk
            :: Replay
            -> ([String], Bool)
            -> Story a
            -> (Maybe (a, ([String], Bool)), Replay)
        walk st@(Replay _ _ (Just _)) _ _ = (Nothing, st)
        walk st acc@(fs, p) program = case view program of
            Return a -> (Just (a, acc), st)
            Action (Require req rs) :>>= next ->
                walk st (fs <> check req rs, p || req `elem` premises) (next ())
            Action i :>>= next -> case perform st i of
                (Just r, st') -> walk st' acc (next r)
                (Nothing, st') -> (Nothing, st')
            Theorem _ _ :>>= _ ->
                (Nothing, stopAt st "a statement nested inside a clause")

    perform :: Replay -> CliI a -> (Maybe a, Replay)
    perform st i = case i of
        Require _ _ -> (Just (), st)
        Run{} -> answer st i
        Book{} -> answer st i
        FoldUnevaluated{} -> answer st i
        Observe{} -> answer st i
        Craft{} -> answer st i

    answer :: Replay -> CliI Receipt -> (Maybe Receipt, Replay)
    answer st@(Replay n rs _) i = case (identify i, Map.lookup n byStep) of
        (Just (a, t, k), Just [r])
            | (rcAction r, rcTarget r, rcKey r) == (a, t, k) ->
                (Just r, Replay (n + 1) rs Nothing)
            | otherwise ->
                ( Nothing
                , stopAt
                    st
                    ( "step "
                        <> show n
                        <> " answers "
                        <> describeReceipt r
                        <> ", not "
                        <> describe3 (a, t, k)
                    )
                )
        (Just ident, Nothing) ->
            ( Nothing
            , stopAt
                st
                ("no receipt for step " <> show n <> ", " <> describe3 ident)
            )
        (Just _, Just _) ->
            ( Nothing
            , stopAt st ("step " <> show n <> " has more than one receipt")
            )
        (Nothing, _) -> (Nothing, stopAt st "an action with no receipt identity")

    stopAt (Replay n rs _) why = Replay n rs (Just why)

describe3 :: (Text, Text, Text) -> String
describe3 (a, t, k) =
    T.unpack a
        <> " in "
        <> T.unpack t
        <> (if T.null k then "" else " for " <> T.unpack k)

describeReceipt :: Receipt -> String
describeReceipt r = describe3 (rcAction r, rcTarget r, rcKey r)

{- | Every clause the story states, in order, with its statement: the
rows a verdict must account for, whether or not a receipt reached them.
The story is walked with placeholder receipts; it never branches on one.
-}
outline :: Story () -> [(String, String)]
outline story = snd (walk 0 story)
  where
    walk :: Int -> Story a -> (Int, [(String, String)])
    walk n program = case view program of
        Return _ -> (n, [])
        Action i :>>= next -> let (n', r) = placeholder n i in walk n' (next r)
        Theorem thm body :>>= next ->
            let name = boName (theoremBinding thm)
                (n', rows, r) = walkClauses name n (clauses body)
                (n'', rest) = walk n' (next r)
            in  (n'', rows <> rest)

    walkClauses
        :: String
        -> Int
        -> Program (Clause thm CliI) a
        -> (Int, [(String, String)], a)
    walkClauses name n program = case view program of
        Return a -> (n, [], a)
        Clause title leanCheck body :>>= next ->
            let (n1, obs) = run n body
                (n2, _) = run n1 (checkAction leanCheck obs)
                (n3, rows, a) = walkClauses name n2 (next obs)
            in  (n3, (name, title) : rows, a)

    run :: Int -> Story a -> (Int, a)
    run n program = case view program of
        Return a -> (n, a)
        Action i :>>= next -> let (n', r) = placeholder n i in run n' (next r)
        Theorem _ _ :>>= _ -> error "outline: a statement nested inside a clause"

    placeholder :: Int -> CliI a -> (Int, a)
    placeholder n i = case i of
        Require _ _ -> (n, ())
        Run{} -> (n + 1, emptyReceipt n "" "" "")
        Book{} -> (n + 1, emptyReceipt n "" "" "")
        FoldUnevaluated{} -> (n + 1, emptyReceipt n "" "" "")
        Observe{} -> (n + 1, emptyReceipt n "" "" "")
        Craft{} -> (n + 1, emptyReceipt n "" "" "")

{- | Refuse a story before it runs: every statement it binds must be one of
'statementBindings' and told once, every clause title distinct within its
statement, and every refusal paired with an accepting clause in the same
telling.
-}
validateControls :: Story () -> Either String ()
validateControls story = do
    let rows = outline story
        statements = nub (map fst rows)
        told = tellings story
    unless (length told == length (nub told)) $
        Left
            "a statement is told more than once; each telling needs its own control"
    forM_ statements $ \s -> do
        unless (s `elem` map boName statementBindings) $
            Left (s <> " is not a statement this domain binds")
        let titles = [t | (s', t) <- rows, s' == s]
        unless (length titles == length (nub titles)) $
            Left (s <> " repeats a clause")
        when
            ( any (("is refused" `T.isInfixOf`) . T.pack) titles
                && not (any (("is accepted" `T.isSuffixOf`) . T.pack) titles)
            )
            $ Left (s <> " has a refusal without an accepting control")
    let (loose, shapes) = shape story
    unless (loose == 0) $
        Left
            ( show loose
                <> " actions run outside any clause; every receipt must feed a verdict"
            )
    forM_ shapes $ \(s, clauseShapes) ->
        when
            ( any (("is refused" `T.isInfixOf`) . T.pack . fst) clauseShapes
                && not (maybe False snd (listToMaybe clauseShapes))
            )
            $ Left (s <> " makes a refusal claim without opening on its premise")
    Right ()

-- ---------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------

{- | The section a reader sees: each statement, what was done, the verdict
of each clause as the receipts give it, and the approved matrix of cases
with each one's coverage computed from those verdicts. Uncovered clauses
and cases are listed, with the reason, beside the rest.
-}
renderControls :: [ClauseResult] -> Story () -> String
renderControls results story =
    unlines $
        [ "## The ordinary CLI and the application's boundary, judged from receipts"
        , ""
        , "Alice's story runs through the ordinary `singular registry` commands, and each claim about it is checked against the receipts those commands print: the registry create booted, the holding insert delivered, the payloads the updates wrote with the root unmoved, and the deposit terminate released."
        , ""
        , "The refusals are the node's. Each refused transaction is submitted without evaluating its scripts locally, so the node judges it, and each refusal names the script that failed: the registry's state validator for an insertion of a key the registry already holds, and the applied open-datum script for a tampered update or a release outside any fold. Every refusal sits beside an accepting control built the same way, and readbacks before and after show that nothing moved. The node does not report the model's reason for a refusal, and no reason is claimed as observed."
        , ""
        , "### What was done"
        , ""
        ]
            <> steps story
            <> [ ""
               , "### Verdicts, computed from the receipts"
               , ""
               , "| statement | clause | verdict |"
               , "|---|---|---|"
               ]
            <> [ "| `"
                    <> crStatement r
                    <> "` | "
                    <> crTitle r
                    <> " | "
                    <> verdictText (crStatus r)
                    <> " |"
               | r <- results
               ]
            <> [ ""
               , summary
               , ""
               , "### The approved cases and what covers each"
               , ""
               , "A case is covered when the clause that exercises it holds on the receipts above. Cases the live run does not reach are listed as uncovered with the reason; the Aiken suite's own tests of them are separate evidence and are not counted here."
               , ""
               , "| case | statement | coverage |"
               , "|---|---|---|"
               ]
            <> [ "| " <> name <> " | " <> stmt <> " | " <> coverage cov <> " |"
               | (name, stmt, cov) <- approvedCases
               ]
            <> [ ""
               , caseSummary
               ]
  where
    verdictText s = case s of
        Held -> "holds"
        NotHeld why -> "does not hold: " <> intercalate "; " why
        Uncovered why -> "uncovered: " <> why
    judged = results
    uncovered = length [() | ClauseResult _ _ (Uncovered _) <- judged]
    notHeld = length [() | ClauseResult _ _ (NotHeld _) <- judged]
    summary =
        show (length judged - uncovered - notHeld)
            <> " of "
            <> show (length judged)
            <> " clauses hold; "
            <> show notHeld
            <> " do not; "
            <> show uncovered
            <> " are uncovered."
    coverage cov = case cov of
        NotLive why -> "uncovered: " <> why
        ByClause stmt title ->
            case [ crStatus r
                 | r <- results
                 , crStatement r == qualified stmt
                 , crTitle r == title
                 ] of
                [Held] -> "covered: the clause holds"
                [Uncovered why] -> "uncovered: " <> why
                [NotHeld why] -> "not covered: the clause does not hold: " <> intercalate "; " why
                _ -> "uncovered: its clause did not run"
    covered =
        length
            [ ()
            | (_, _, cov) <- approvedCases
            , coverage cov == "covered: the clause holds"
            ]
    caseSummary =
        show covered
            <> " of "
            <> show (length approvedCases)
            <> " approved cases are covered live; "
            <> show (length approvedCases - covered)
            <> " are not."

-- | How an approved case is exercised: by a named clause, or not live.
data Coverage
    = ByClause String String
    | NotLive String

qualified :: String -> String
qualified = ("OpenDatumApplication.Statements." <>)

{- | The approved matrix of controls for the ordinary CLI and the
open-datum application, each with the statement it bears on (or the
client safety it checks) and the clause that exercises it live.
-}
approvedCases :: [(String, String, Coverage)]
approvedCases =
    [
        ( "a second insertion of an Active key"
        , "`duplicate_refused_by_registry`"
        , ByClause "duplicate_refused_by_registry" registryRefusal
        )
    ,
        ( "an insertion of a Terminal key"
        , "`resurrection_refused_by_registry`"
        , ByClause "resurrection_refused_by_registry" registryRefusal
        )
    ,
        ( "an update not signed by the controller"
        , "`update_requires_controller`"
        , ByClause
            "update_requires_controller"
            "the same update, requiring another wallet's signature instead of the controller's, is refused by the application"
        )
    ]
        <> [ ( craftedPhrase c
             , "`update_preserves_custody`"
             , ByClause
                "update_preserves_custody"
                (craftedPhrase c <> " is refused by the application")
             )
           | c <-
                [ UpdateOtherController
                , UpdateDepositTampered
                , UpdateEscaped
                , UpdateTokenLeft
                , UpdateShortDeposit
                , UpdateWithoutDatum
                , UpdateAddedAsset
                ]
           ]
        <> [
               ( "an update whose continuation duplicates the token's carrier"
               , "`update_preserves_custody`"
               , NotLive
                    "a second carrier needs a second active token for the key, which only the registry's witness policy mints"
               )
           ,
               ( "a release of the live holding outside any fold"
               , "`only_fold_releases`"
               , ByClause
                    "only_fold_releases"
                    "a release of the live holding outside any fold is refused by the application"
               )
           ]
        <> [ ( craftedPhrase c
             , "`" <> stmt <> "`"
             , ByClause stmt (craftedPhrase c <> " is refused by the application")
             )
           | (c, stmt) <-
                [ (BookingByStranger, "bookInsert_inversion")
                , (BookingOtherDestination, "bookInsert_inversion")
                , (BookingShortDeposit, "bookInsert_inversion")
                , (BookingNoDatum, "bookInsert_inversion")
                , (EnvelopeOtherStateName, "insertion_requires_registry_identity")
                , (EnvelopeOtherStatePolicy, "insertion_requires_registry_identity")
                , (EnvelopeOtherRegistry, "insertion_requires_registry_identity")
                , (TerminateBookingByStranger, "bookTerminate_inversion")
                , (ReleaseInOtherFold, "fold_inversion")
                , (FoldPaysShort, "fold_settles_additively")
                ]
           ]
        <> [ ( name
             , "`fold_settles_additively`"
             , ByClause
                "fold_settles_additively"
                (craftedPhrase c <> " is refused by the application")
             )
           | (name, c) <-
                [
                    ( "a mixed fold paying one controller one lovelace short"
                    , FoldMixedShort
                    )
                ,
                    ( "two releases to one controller paid one lovelace short"
                    , FoldTwoReleasesShort
                    )
                ,
                    ( "two releases paid one floor where the sum is owed"
                    , FoldTwoReleasesOneFloor
                    )
                ]
           ]
        <> [ ( name
             , "client safety, no model statement"
             , NotLive
                "checked by the packaged journey's receipts, not yet a clause here"
             )
           | name <-
                [ "a second create racing for one target on another wallet's live seed"
                , "a create interrupted after its first accepted submission"
                , "a node lost after an accepted submission"
                , "a fold killed after the node accepted it"
                , "a concurrent writer holding the target's lock"
                , "missing proof material, a changed application selector, an unavailable node"
                ]
           ]
  where
    registryRefusal =
        "that request's fold, submitted without local evaluation, is refused by the registry's state validator"

-- | The story's actions, in the description language, numbered by step.
steps :: Story () -> [String]
steps story = snd (walk 0 story)
  where
    walk :: Int -> Story a -> (Int, [String])
    walk n program = case view program of
        Return _ -> (n, [])
        Action i :>>= next ->
            let (n', r, line) = say n i
                (n'', rest) = walk n' (next r)
            in  (n'', maybe rest (: rest) line)
        Theorem thm body :>>= next ->
            let header =
                    "Under `" <> boName (theoremBinding thm) <> "`:"
                (n', ls, r) = walkClauses n (clauses body)
                (n'', rest) = walk n' (next r)
            in  (n'', header : ls <> rest)

    walkClauses
        :: Int -> Program (Clause thm CliI) a -> (Int, [String], a)
    walkClauses n program = case view program of
        Return a -> (n, [], a)
        Clause _ leanCheck body :>>= next ->
            let (n1, ls1, obs) = run n body
                (n2, ls2, _) = run n1 (checkAction leanCheck obs)
                (n3, ls3, a) = walkClauses n2 (next obs)
            in  (n3, ls1 <> ls2 <> ls3, a)

    run :: Int -> Story a -> (Int, [String], a)
    run n program = case view program of
        Return a -> (n, [], a)
        Action i :>>= next ->
            let (n', r, line) = say n i
                (n'', ls, a) = run n' (next r)
            in  (n'', maybe ls (: ls) line, a)
        Theorem _ _ :>>= _ -> error "steps: a statement nested inside a clause"

    say :: Int -> CliI a -> (Int, a, Maybe String)
    say n i = case i of
        Require _ _ -> (n, (), Nothing)
        Run c (Target t) k ->
            ( n + 1
            , emptyReceipt n "" "" ""
            , Just
                ( numbered
                    n
                    ( "Run `singular registry "
                        <> commandName c
                        <> "` on **"
                        <> t
                        <> "**"
                        <> forKey k
                        <> "."
                    )
                )
            )
        Book (Target t) k ->
            ( n + 1
            , emptyReceipt n "" "" ""
            , Just
                ( numbered
                    n
                    ( "Book an insertion of **"
                        <> k
                        <> "** in **"
                        <> t
                        <> "** through the application, as `insert` does, and stop before its fold."
                    )
                )
            )
        FoldUnevaluated (Target t) k ->
            ( n + 1
            , emptyReceipt n "" "" ""
            , Just
                ( numbered
                    n
                    ( "Fold that booking of **"
                        <> k
                        <> "** in **"
                        <> t
                        <> "**, submitted without evaluating its scripts locally."
                    )
                )
            )
        Observe (Target t) k ->
            ( n + 1
            , emptyReceipt n "" "" ""
            , Just
                ( numbered
                    n
                    ( "Read back **"
                        <> t
                        <> "**: its root, the holding of **"
                        <> k
                        <> "**, the pending requests and the wallet."
                    )
                )
            )
        Craft c (Target t) k ->
            ( n + 1
            , emptyReceipt n "" "" ""
            , Just
                ( numbered
                    n
                    ( "Submit, without evaluating its scripts locally, "
                        <> craftedPhrase c
                        <> ", for **"
                        <> k
                        <> "** in **"
                        <> t
                        <> "**."
                    )
                )
            )
    numbered n s = show (n + 1) <> ". " <> s
    forKey k = if null k then "" else " for **" <> k <> "**"

-- | The statements a story tells, one entry per telling, in order.
tellings :: Story () -> [String]
tellings = go
  where
    go :: Story a -> [String]
    go program = case view program of
        Return _ -> []
        Action i :>>= next -> go (next (placeholderOf i))
        Theorem thm body :>>= next ->
            boName (theoremBinding thm) : go (next (skip (clauses body)))

    skip :: Program (Clause thm CliI) a -> a
    skip program = case view program of
        Return a -> a
        Clause _ _ body :>>= next -> skip (next (result body))

    result :: Story a -> a
    result program = case view program of
        Return a -> a
        Action i :>>= next -> result (next (placeholderOf i))
        Theorem _ _ :>>= _ -> error "tellings: a statement nested inside a clause"

    placeholderOf :: CliI a -> a
    placeholderOf i = case i of
        Require _ _ -> ()
        Run{} -> emptyReceipt 0 "" "" ""
        Book{} -> emptyReceipt 0 "" "" ""
        FoldUnevaluated{} -> emptyReceipt 0 "" "" ""
        Observe{} -> emptyReceipt 0 "" "" ""
        Craft{} -> emptyReceipt 0 "" "" ""

-- | A crafted transaction, in the description language.
craftedPhrase :: Crafted -> String
craftedPhrase c = case c of
    HonestUpdate ->
        "the controller's own update of the live holding, with a new payload"
    UpdateByStranger ->
        "that update requiring another wallet's signature instead of the controller's"
    UpdateOtherController ->
        "an update whose continuation names another controller"
    UpdateDepositTampered ->
        "an update whose continuation changes the protected deposit"
    UpdateEscaped ->
        "an update whose continuation, token and all, goes to the controller's own address"
    UpdateTokenLeft ->
        "an update whose continuation stays at the application without the key's token"
    UpdateShortDeposit ->
        "an update whose continuation holds one lovelace less than the protected deposit"
    UpdateWithoutDatum ->
        "an update whose continuation carries no datum"
    UpdateAddedAsset ->
        "an update whose continuation also carries an asset of another policy"
    EarlyWithdrawal ->
        "a release of the live holding outside any fold"
    BookingByStranger ->
        "an insertion booking of the controller's envelope, paid and signed by another wallet"
    BookingOtherDestination ->
        "an insertion booking whose request names another destination"
    BookingShortDeposit ->
        "an insertion booking whose request deposit is one lovelace short of the protected deposit"
    BookingNoDatum ->
        "an insertion booking whose destination names no datum"
    EnvelopeOtherStateName ->
        "an insertion booking whose envelope names the registry's state policy under another token name"
    EnvelopeOtherStatePolicy ->
        "an insertion booking whose envelope names the registry's token name under another policy"
    EnvelopeOtherRegistry ->
        "an insertion booking whose envelope names another registry's state asset"
    TerminateBooking ->
        "the controller's own booking of the key's termination"
    TerminateBookingByStranger ->
        "a termination booking of the key by another wallet"
    ReleaseInOtherFold ->
        "a fold of another key's insertion that also releases this live holding"
    UpdateWithoutScript ->
        "the controller's update, submitted without the application's script"
    FoldPaysShort ->
        "the terminating fold, folded by another wallet, paying the controller one lovelace short"
    FoldPaysInFull ->
        "the same terminating fold, folded by another wallet, paying the controller in full"
    FoldTwoReleasesShort ->
        "one fold of two terminations for one controller, folded by another wallet, paying the controller one lovelace short of the sum"
    FoldTwoReleasesOneFloor ->
        "that fold paying the controller one released deposit where the sum of two is owed"
    FoldTwoReleasesInFull ->
        "that fold paying the controller the sum in full"
    FoldMixedShort ->
        "one fold of an insertion and a termination for one controller, folded by another wallet, paying the controller one lovelace short"
    FoldMixedInFull ->
        "that mixed fold paying the controller in full"

-- | The path of an insert receipt's envelope control fields.
controlPath :: [Either Text Int]
controlPath = [Left "envelope", Left "fields", Right 0, Left "fields"]

{- | The node's rejection, rebuilt from exactly what the receipt carries of
it — its words for a script that executed and failed, and the hashes of
the scripts that failed — and judged by the suite's own refusal discipline
('matchRefusal'): a phase-2 failure among whose failed scripts the
expected one is.
-}
attribution :: Text -> Receipt -> Either RefusalMismatch ()
attribution expected r = matchRefusal (T.unpack expected) rebuilt
  where
    rebuilt =
        unwords (map T.unpack (rcPhaseWords r))
            <> concat
                [" ScriptHash \"" <> T.unpack h <> "\"" | h <- rcRefusingScripts r]

-- | Fail unless the receipt shows the expected script executed and failed.
attributedTo :: String -> Maybe Text -> Receipt -> [String]
attributedTo what expected r =
    case expected of
        Nothing -> ["the " <> what <> " is not recorded"]
        Just h -> case attribution h r of
            Right () -> []
            Left (NotPhase2 _) ->
                [ "the node rejected it before any script ran, so no script refused it"
                ]
            Left (MarkerAbsent _ _) ->
                [ "the scripts that failed do not include the "
                    <> what
                    <> " "
                    <> T.unpack h
                    <> "; they are "
                    <> show (rcRefusingScripts r)
                ]
        <> submitted r

-- | Fail unless the retained body and rejection were read back and bind.
submitted :: Receipt -> [String]
submitted r = case rcTxId r of
    Nothing -> ["no transaction id is recorded"]
    Just _ -> admitted r

{- | Fail unless admission read the retained body and rejection back and
found nothing wrong: the body decodes to the receipt's transaction, the
rejection is the digested bytes, and its words and failed scripts are the
ones the verdict uses.
-}
admitted :: Receipt -> [String]
admitted r = case rcAdmission r of
    Nothing ->
        [ "the retained body and rejection were not read back, so the receipt is not admitted"
        ]
    Just problems -> map T.unpack problems

{- | The node's words for a script that executed and failed, and the
hashes of the scripts that failed, as they occur in its rejection text.
-}
rejectionEvidence :: String -> ([Text], [Text])
rejectionEvidence text =
    ( [T.pack w | w <- ["PlutusFailure", "CekError"], w `isInfixOf` text]
    , map T.pack (refusalScriptHashes text)
    )

-- | A key label as the lowercase hex of its bytes, as the commands print keys.
hexLabel :: String -> Text
hexLabel = T.pack . concatMap (printf "%02x" . ord)

-- | The requirements whose failure leaves the rest of a telling unfounded.
premises :: [Requirement]
premises = [Established, ReachedActive, ReachedTerminal]

-- | Fail unless every receipt of a premise is of one registry.
oneRegistry :: [Receipt] -> [String]
oneRegistry rs =
    [ "the premise's receipts are of different registries"
    | length (nub (map rcTarget rs)) > 1
    ]

-- | Fail unless the receipts reach the key at the given leaf.
reachedLeaf :: Text -> [Receipt] -> [String]
reachedLeaf leaf rs = case reverse rs of
    [] -> ["the premise has no receipts"]
    (reading : commands) ->
        concatMap
            (\c -> succeeded ("the " <> T.unpack (rcAction c)) c)
            commands
            <> oneRegistry rs
            <> readsLeaf reading
  where
    readsLeaf r
        | T.null (rcKey r) = ["the premise's reading names no key"]
        | rcAction r == "run inspect" =
            succeeded "the inspect" r
                <> is "the key's leaf" (Aeson.String leaf) (at [field "leaf"] r)
                <> is
                    "the key inspected"
                    (Aeson.String (hexLabel (T.unpack (rcKey r))))
                    (at [field "key"] r)
        | rcAction r == "observe" =
            [ "the readback's outcome is " <> show (rcOutcome r) <> ", not observed"
            | rcOutcome r /= "observed"
            ]
                <> case obLeaf =<< rcObservation r of
                    Just l
                        | l == leaf -> []
                        | otherwise ->
                            [ "the key's leaf, authenticated against the chain's root, is "
                                <> T.unpack l
                                <> ", not "
                                <> T.unpack leaf
                            ]
                    Nothing ->
                        [ "no mirror copy agrees with the chain's root, so the key's leaf is not authenticated"
                        ]
        | otherwise =
            [ "the premise ends in "
                <> T.unpack (rcAction r)
                <> ", not a reading of the key"
            ]

-- | The premise that the held key still reads Active, from a fresh inspect.
stillActive
    :: Theorem thm -> Target -> TheoremStory thm CliI [Receipt]
stillActive thm target =
    premiseClause
        thm
        "the key still reads Active, from a fresh inspect"
        ReachedActive
        (pure <$> action (Run Inspect target heldKey))

{- | How many actions a story runs outside any clause, and, for each
telling, its clauses in order with whether each one's check is a premise.
The story is walked with placeholder receipts; it never branches on one.
-}
shape :: Story () -> (Int, [(String, [(String, Bool)])])
shape = go
  where
    go :: Story a -> (Int, [(String, [(String, Bool)])])
    go program = case view program of
        Return _ -> (0, [])
        Action i :>>= next ->
            let (n, ts) = go (next (placeholderOf i)) in (n + 1, ts)
        Theorem thm body :>>= next ->
            let (cs, r) = walkClauses (clauses body)
                (n, ts) = go (next r)
            in  (n, (boName (theoremBinding thm), cs) : ts)

    walkClauses :: Program (Clause thm CliI) a -> ([(String, Bool)], a)
    walkClauses program = case view program of
        Return a -> ([], a)
        Clause title leanCheck body :>>= next ->
            let obs = result body
                usesPremise = any (`elem` premises) (requirementsOf (checkAction leanCheck obs))
                (rest, a) = walkClauses (next obs)
            in  ((title, usesPremise) : rest, a)

    result :: Story a -> a
    result program = case view program of
        Return a -> a
        Action i :>>= next -> result (next (placeholderOf i))
        Theorem _ _ :>>= _ -> error "shape: a statement nested inside a clause"

    requirementsOf :: Story a -> [Requirement]
    requirementsOf program = case view program of
        Return _ -> []
        Action (Require req _) :>>= next -> req : requirementsOf (next ())
        Action i :>>= next -> requirementsOf (next (placeholderOf i))
        Theorem _ _ :>>= _ -> []

    placeholderOf :: CliI a -> a
    placeholderOf i = case i of
        Require _ _ -> ()
        Run{} -> emptyReceipt 0 "" "" ""
        Book{} -> emptyReceipt 0 "" "" ""
        FoldUnevaluated{} -> emptyReceipt 0 "" "" ""
        Observe{} -> emptyReceipt 0 "" "" ""
        Craft{} -> emptyReceipt 0 "" "" ""

-- | One submission an ordinary command journalled, and the body it kept.
data Submission = Submission
    { suStep :: Text
    , suTxId :: Text
    , suBodyFile :: Text
    -- ^ Relative to the run's directory
    , suBodySha256 :: Text
    }
    deriving stock (Eq, Show)

instance ToJSON Submission where
    toJSON s =
        object
            [ "step" .= suStep s
            , "txId" .= suTxId s
            , "bodyFile" .= suBodyFile s
            , "bodySha256" .= suBodySha256 s
            ]

instance FromJSON Submission where
    parseJSON = withObject "submission" $ \o ->
        Submission
            <$> o .: "step"
            <*> o .: "txId"
            <*> o .: "bodyFile"
            <*> o .: "bodySha256"
