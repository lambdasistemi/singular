{-# LANGUAGE GADTs #-}
{-# LANGUAGE TemplateHaskell #-}

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
    , Indexer (..)
    , indexerName
    , IndexerRead (..)
    , Stated (..)
    , Account (..)
    , CliI (..)
    , Story

      -- * Statements
    , DuplicateRefused
    , ResurrectionRefused
    , duplicateRefused
    , resurrectionRefused
    , statementBindings
    , resolveStatement
    , obligationBindings
    , resolveObligation
    , cliSpecification

      -- * The stories
    , duplicateStory
    , resurrectionStory
    , lifecycleStory
    , boundaryStory
    , controlsStory
    , processStory
    , permanentStory
    , forbiddenInPermanent
    , actionsOf

      -- * Receipts
    , Receipt (..)
    , Observation (..)
    , Submission (..)
    , Resolved (..)
    , JournalSpan (..)
    , ProcessEvidence (..)
    , Provocation (..)
    , provocationName
    , emptyReceipt

      -- * Reading a node's rejection
    , rejectionEvidence
    , decodeIndexerRead
    , attribution

      -- * Verdicts and rendering, from receipts
    , ClauseStatus (..)
    , ClauseResult (..)
    , check
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
import Control.Monad (forM_, guard, unless, void, when)
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
import Data.Bifunctor qualified as Bifunctor
import Data.ByteString.Lazy qualified as BL
import Data.Char (isDigit, isHexDigit, ord)
import Data.Either (fromRight, lefts, rights)
import Data.Int (Int64)
import Data.List (intercalate, isInfixOf, isPrefixOf, nub)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing, listToMaybe)
import Data.Scientific qualified as Sci
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Data.Word (Word64)
import Language.Haskell.TH.Syntax (addDependentFile, lift, runIO)
import Text.Printf (printf)
import Text.Read (readMaybe)

import Conformance.Refusal
    ( RefusalMismatch (..)
    , matchRefusal
    , refusalScriptHashes
    )

-- ---------------------------------------------------------
-- Actions
-- ---------------------------------------------------------

{- | The ordinary commands, as a person runs them. An update names which
of the story's payloads it writes. A fold folds the registry's pending
request: the request names its key and edge, so the command takes no key,
payload, deposit or fold flag of its own.
-}
data Command = Create | Insert | Update Int | Terminate | Inspect | Fold
    deriving stock (Eq, Show)

commandName :: Command -> String
commandName c = case c of
    Create -> "create"
    Insert -> "insert"
    Update _ -> "update"
    Terminate -> "terminate"
    Inspect -> "inspect"
    Fold -> "fold"

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

{- | An ordinary command run under a condition of its process, not of the
ledger: another process, a changed or missing file, an absent node, or a
kill. What the command does then is the client's obligation under the
CLI's own specification; no model statement covers it.
-}
data Provocation
    = -- | @insert@, while another process holds the registry's lock
      WhileLocked
    | -- | @inspect@, with the public history it needs withheld
      WithoutHistory
    | -- | @inspect@, against a node socket that does not exist
      WithoutNode
    | -- | @terminate@, killed once the node accepted its fold
      TerminateKilled
    | -- | @update@ of another key, once the @terminate@ was killed
      UpdateAfterKill
    | -- | @create@ on a new registry, killed once the node accepted its boot
      CreateKilled
    | -- | @create@ again, on that interrupted registry
      CreateAgain
    | {- | @create@ from another wallet with its own live seed, held before
      the registry's lock while a first @create@ of the same registry
      completes
      -}
      LateCreate
    | -- | @create@, from a wallet that cannot fund every publication
      UnderfundedCreate
    | {- | @update@, held once the node accepted it while the node is stopped,
      then released; the last action of a story, since the node is gone
      -}
      NodeLost
    deriving stock (Eq, Show, Enum, Bounded)

provocationName :: Provocation -> String
provocationName p = case p of
    WhileLocked -> "insert-while-locked"
    WithoutHistory -> "inspect-without-history"
    WithoutNode -> "inspect-without-node"
    TerminateKilled -> "terminate-killed"
    UpdateAfterKill -> "update-after-kill"
    CreateKilled -> "create-killed"
    CreateAgain -> "create-again"
    LateCreate -> "create-late"
    UnderfundedCreate -> "create-underfunded"
    NodeLost -> "update-node-lost"

-- | A provoked command, in the description language.
provocationPhrase :: Provocation -> String
provocationPhrase p = case p of
    WhileLocked ->
        "Run `singular registry insert` while another process holds the registry's lock"
    WithoutHistory ->
        "Run `singular registry inspect` with the public history it needs withheld"
    WithoutNode ->
        "Run `singular registry inspect` against a node socket that does not exist"
    TerminateKilled ->
        "Run `singular registry terminate` and kill it once the node accepted its fold"
    UpdateAfterKill ->
        "Run `singular registry update` of another key once that terminate was killed"
    CreateKilled ->
        "Run `singular registry create` on a new registry and kill it once the node accepted its boot"
    CreateAgain -> "Run `singular registry create` again on that registry"
    LateCreate ->
        "Run `singular registry create` from another wallet with its own live seed, held before the registry's lock while a first create of the same registry completes"
    UnderfundedCreate ->
        "Run `singular registry create` from a wallet that cannot fund every publication"
    NodeLost ->
        "Run `singular registry update`, hold it once the node accepted it, stop the node, then release it"

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
      chain's root, or a readback whose public replay agrees with that root
      -}
      ReachedActive
    | -- | The same, reading the key Terminal
      ReachedTerminal
    | {- | One hand-built transaction the node rejected before any script ran,
      although its rejection names the applied open-datum script: the
      control that such a rejection is not counted as the script's refusal
      -}
      RejectedBeforeScripts
    | {- | A provoked command refused before submitting: its outcome is the
      class its condition names, and the registry's journal did not move
      -}
      RefusedBeforeSubmitting
    | {- | The create receipt of a wallet that cannot fund every
      publication: refused before anything was submitted, with the
      publication funding named, its directory untouched and its seed
      still unspent
      -}
      CreateUnderfunded
    | {- | An inspect by the registry's own actor and one by a second actor
      starting from an empty directory with only the state token: both
      succeeded and read the same registry
      -}
      TokenOnlyReading
    | {- | A booking, an ordinary token-only fold of that booking and an
      inspect after it: the booking was accepted, the fold succeeded on
      the booking's own request, and the key reads Active under the
      fold's envelope and root
      -}
      FoldConsumed
    | {- | A provoked @inspect@: its outcome is the class its condition
      names, and it printed no leaf
      -}
      NoLeafPrinted
    | {- | A killed command: the journal's last line when it stopped is the
      node's acceptance of the step it was killed at, and that submission's
      body was kept
      -}
      StoppedAfterAcceptance
    | {- | The killed @terminate@ and the @update@ after it: either the
      update succeeded, having replayed the killed fold at its chain root and
      observed it, or it was refused before submitting anything, naming the
      killed fold and its case
      -}
      ReconciledOrRefused
    | {- | The killed @terminate@, the @update@ after it and a later
      @inspect@ of its key: the key reads Terminal, and the killed fold was
      replayed at the chain root, never resubmitted and observed exactly once across
      the update's and the inspect's receipts
      -}
      ResolvedFromChain
    | {- | The killed @create@ and a later @inspect@ of its registry: the
      inspect reads the incomplete create's identity from its journal,
      observed the killed boot from the chain and printed no leaf
      -}
      IncompleteCreateRead
    | {- | The late @create@: refused because the registry exists, the first
      registry's saved files unchanged, and the late wallet's seed unspent
      -}
      LateCreateRefused
    | {- | The @update@ that lost its node: it ended within its confirmation
      bound, partial or timed out, naming the transaction it submitted, which
      the journal keeps unresolved
      -}
      BoundedAfterNodeLoss
    | {- | The retraction of a pending request: the insertion's receipt names
      it, the readbacks before and after agree that exactly that request
      left, the retained body spends exactly that request, the registry's
      root did not move, and the wallet gained the bond it released less the
      fee the retraction paid
      -}
      Reclaimed
    | {- | A node-judged transaction of a take on an existing registry: the
      operator set an explicit collateral allowance, and the body states a
      total collateral within it and a return of the rest of its funding
      output
      -}
      ExposureBounded
    | {- | The fresh inspect of an Active key and one public indexer's read
      of that key's token: the indexer found exactly one output holding
      exactly one of the token, under the policy and asset name the inspect
      names, and its output reference, datum bytes, datum hash and chain
      position are the node's, within the lag
      -}
      IndexerAgrees
    deriving stock (Eq, Show, Enum, Bounded)

{- | One step of the story. Every action but 'Require' leaves exactly one
receipt; 'Require' is computed from receipts and leaves none.
-}
data CliI res where
    -- | Run one ordinary command against a registry, for a key
    Run :: Command -> Target -> String -> CliI Receipt
    {- | Run one ordinary command from this actor's directory against the
    registry another target created, naming it only by its state token:
    the actor's directory starts empty and receives the token, nothing
    else of the registry
    -}
    RunByToken :: Target -> Target -> Command -> String -> CliI Receipt
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
    -- | Run an ordinary command under a condition of its process
    Provoke :: Provocation -> Target -> String -> CliI Receipt
    {- | Retract the request a refused insertion left pending, as its owner, in
    the request's own retract window, and read the registry back: the bond
    returns, the fee is paid. It carries the command receipt that names the
    request and the readback that saw it pending: the request is that one, in
    the state that readback saw, or nothing is retracted
    -}
    Reclaim :: Target -> String -> Receipt -> Receipt -> CliI Receipt
    {- | Ask one public indexer, read-only, for the Active key's token, from
    the policy and asset name the fresh inspect names, and compare what it
    finds with that inspect. It writes nothing; an indexer that is missing,
    unreachable, stale or in disagreement ends the take before its next
    write
    -}
    ReadIndexer :: Indexer -> Target -> String -> Receipt -> CliI Receipt
    Require :: Requirement -> [Receipt] -> CliI ()
    {- | The enclosing clause's promise is retired, for this reason. The clause
    keeps its words as history and is judged retired, never from a receipt;
    it leaves no receipt
    -}
    Retire :: String -> CliI ()

type Story = Specification.Story CliI

-- ---------------------------------------------------------
-- Statements
-- ---------------------------------------------------------

-- | @OpenDatumApplication.Statements.duplicate_refused_by_registry@
data DuplicateRefused

-- | @OpenDatumApplication.Statements.resurrection_refused_by_registry@
data ResurrectionRefused

{- | The application model revision the statements are read at: the one
commit in @model-revision@, read when this module compiles. The release
archive states the same file as @MODEL-REVISION@.
-}
modelRevision :: String
modelRevision =
    $( do
        let path = "model-revision"
        addDependentFile path
        revision <- runIO (readFile path)
        case lines revision of
            [commit]
                | length commit == 40 && all isHexDigit commit -> lift commit
            _ -> fail ("model-revision is not one commit: " <> show revision)
     )

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
        "844d0d9bdbc5bae7875fcd07950bd37919dac92e588a40da79368cbd3b776a18"

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
        "52ba3e1fa9dfe4b2fb19471ab5cac3e1ef6e4aa86b928f9b7aa6aec7399f1140"

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

{- | A client obligation: a row of the CLI's own specification. It is not a
model statement; what it covers is the command's behaviour under
conditions of its process, which no Lean statement describes.
-}
data ClientObligation

-- | The specification whose rows the client obligations are.
cliSpecification :: String
cliSpecification = "specs/299-singular-cli/spec.md"

-- | A row, bound by its identifier and the SHA-256 of its exact line.
obligationRow :: String -> String -> Theorem ClientObligation
obligationRow name digest =
    bindTheorem (mkBoundObligation name digest cliSpecification)

-- | Every submission survives; concurrent writers, lost nodes and repeated creates halt.
haltsAttributably :: Theorem ClientObligation
haltsAttributably =
    obligationRow
        "R299-05"
        "0c79da4ca0f30b7e225d13cceff5ea6e4cf92cd2b197cdf267f35754ef3bfb47"

-- | Submissions and partial state survive interruption; nothing is resubmitted.
partialSurvives :: Theorem ClientObligation
partialSurvives =
    obligationRow
        "INV299-PARTIAL"
        "3dc6a0b02d40eb86f251b9451729c3d55a1a37fadfb624153956819944c745eb"

-- | A leaf is reported only against the observed commitment.
authenticated :: Theorem ClientObligation
authenticated =
    obligationRow
        "INV299-AUTHENTICATED"
        "f35b175f8df8140f9a947178c375c1627864d4fa91fd39cc14234ee95b17b2aa"

-- | The state token, release, network and selected key bind every write and read.
identityBinds :: Theorem ClientObligation
identityBinds =
    obligationRow
        "INV299-IDENTITY"
        "4ca4b7b81ec111c58ea1d066d60cd89adbd7ad8b7c363710ec58b9531c3ac982"

-- | An unavailable read never prints confirmed status.
readOnly :: Theorem ClientObligation
readOnly =
    obligationRow
        "INV299-READONLY"
        "ada685ce0cafbdaaa2c0c500d26bf53c51d990c851108cc3e7b802257c3fe6d8"

-- | The clause an indexer's read is told under.
indexerTitle :: Indexer -> String
indexerTitle ix =
    indexerName ix
        <> " finds exactly one output holding exactly one of the key's token, and its output, datum bytes, datum hash and chain position are the node's"

-- | An indexer's read of the Active key counts only when it agrees with the node.
indexerReads :: Theorem ClientObligation
indexerReads =
    obligationRow
        "INV300-INDEXER"
        "3b78a7a63946e3d2796c9d4792f7c2bf451762a2909019bc3166ee7614dedd70"

-- | The client obligations the controls bind.
obligationBindings :: [Binding]
obligationBindings =
    [ theoremBinding haltsAttributably
    , theoremBinding partialSurvives
    , theoremBinding authenticated
    , theoremBinding identityBinds
    , theoremBinding readOnly
    , theoremBinding indexerReads
    ]

{- | Whether the CLI's specification carries the bound row exactly once,
its line hashing (by the given SHA-256) to the bound digest.
-}
resolveObligation
    :: (Text -> Text) -> Text -> Binding -> Either String ()
resolveObligation sha256 specification b =
    case [ l
         | l <- T.lines specification
         , let firstCell = case drop 1 (T.splitOn "|" l) of
                cell : _ -> T.strip cell
                [] -> ""
         , firstCell == T.pack (boName b)
            || (" (" <> T.pack (boName b) <> ")") `T.isSuffixOf` firstCell
         ] of
        [l]
            | sha256 l == T.pack (boDigest b) -> Right ()
            | otherwise ->
                Left
                    ( boName b
                        <> ": the specification's row hashes to "
                        <> T.unpack (sha256 l)
                        <> ", not the bound "
                        <> boDigest b
                    )
        [] -> Left (boName b <> ": not a row of " <> cliSpecification)
        _ -> Left (boName b <> ": more than one row of " <> cliSpecification)

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

{- | The clause that bounds what a refused transaction put at risk, told after
the refusal it follows: the operator's explicit allowance is on the receipt,
the body states its total collateral within it and returns the rest.
-}
exposureBounded
    :: Theorem thm -> [Receipt] -> TheoremStory thm CliI ()
exposureBounded thm refused =
    void $
        clause
            "the refused transaction states its collateral within the operator's explicit allowance and returns the rest of its funding output"
            (requirement thm ExposureBounded)
            (pure refused)

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
                "the other key still reads Active, from a readback whose public replay agrees with the chain's root"
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
        >> processStory

{- | One take on a registry that already exists, through a node someone else
runs: the four refusals the demonstration shows, each beside its accepting
control, on one fresh key.

The key is inserted by the ordinary command, which is also the accepting
control of the two insertion refusals; a second insertion of the Active key is
booked and its fold refused by the registry, then the request it left pending
is retracted by its owner; the update another wallet's signature stands for is
refused, beside the controller's own ordinary update; a release outside any
fold is refused, beside the ordinary terminate that releases the same holding
inside one; an insertion of the now Terminal key is booked, refused and its
request retracted likewise.

No registry is created and no node is started, stopped or reset: the story
contains none of those actions, which 'forbiddenInPermanent' names.
-}
permanentStory :: String -> Story ()
permanentStory key = do
    let target = Target "permanent"
        again =
            "the ordinary insert of the Active key is booked, stops partial and names its pending request"
        folded =
            "that request's fold, submitted without local evaluation, is refused by the registry's state validator"
        unchanged =
            "the registry's root, the key's holding, the pending request and the wallet are unchanged"
        absent = "the ordinary insert of the absent key is accepted"
    inserted <- theorem duplicateRefused $ do
        opened <-
            clause
                "the key reached Active through the ordinary insert, and inspect reads it Active"
                ( bindCheck duplicateRefused $ \(ins, seen) ->
                    action (Require ReachedActive [ins, seen])
                )
                ( do
                    ins <- action (Run Insert target key)
                    seen <- action (Run Inspect target key)
                    pure (ins, seen)
                )
        let (ins, _) = opened
        _ <-
            clause
                absent
                (requirement duplicateRefused CommandSucceeded)
                (pure [ins])
        refusedInsertion duplicateRefused target key again folded unchanged
        pure ins
    finalInspect <- theorem updateRequiresController $ do
        _ <-
            premiseClause
                updateRequiresController
                "the key still reads Active, from a fresh inspect"
                ReachedActive
                (pure <$> action (Run Inspect target key))
        before <- readbackOf updateRequiresController target key
        refusedUpdate <-
            clause
                "the same update, requiring another wallet's signature instead of the controller's, is refused by the application"
                (requirement updateRequiresController RefusedByApplication)
                (pure <$> action (Craft UpdateByStranger target key))
        exposureBounded updateRequiresController refusedUpdate
        unchangedOf
            updateRequiresController
            HoldingUnchanged
            "the registry's root, the key's holding and the wallet are unchanged by the refusal"
            target
            key
            before
        (_, _, final) <-
            clause
                "the controller's own update, by the ordinary command, is accepted"
                ( bindCheck updateRequiresController $ \(b, u, a) ->
                    action (Require PayloadReplaced [b, u, a])
                )
                ( do
                    b <- action (Run Inspect target key)
                    u <- action (Run (Update 2) target key)
                    a <- action (Run Inspect target key)
                    pure (b, u, a)
                )
        pure final
    theorem indexerReads $ do
        _ <-
            premiseClause
                indexerReads
                "the key still reads Active, from the fresh inspect that follows its final update"
                ReachedActive
                (pure [finalInspect])
        forM_ [minBound .. maxBound :: Indexer] $ \ix ->
            clause
                (indexerTitle ix)
                (requirement indexerReads IndexerAgrees)
                ( do
                    r <- action (ReadIndexer ix target key finalInspect)
                    pure [finalInspect, r]
                )
    terminated <- theorem onlyFoldReleases $ do
        _ <-
            premiseClause
                onlyFoldReleases
                "the key still reads Active, from a fresh inspect"
                ReachedActive
                (pure <$> action (Run Inspect target key))
        before <- readbackOf onlyFoldReleases target key
        refusedRelease <-
            clause
                "a release of the live holding outside any fold is refused by the application"
                (requirement onlyFoldReleases RefusedByApplication)
                (pure <$> action (Craft EarlyWithdrawal target key))
        exposureBounded onlyFoldReleases refusedRelease
        unchangedOf
            onlyFoldReleases
            HoldingUnchanged
            "the registry's root, the key's holding and the wallet are unchanged by the refusal"
            target
            key
            before
        clause
            "the same holding, released inside the registry's fold by the ordinary terminate, is accepted"
            (requirement onlyFoldReleases CommandSucceeded)
            (pure <$> action (Run Terminate target key))
    theorem resurrectionRefused $ do
        _ <-
            premiseClause
                resurrectionRefused
                "the key reached Terminal through the ordinary commands, and inspect reads it Terminal"
                ReachedTerminal
                ( do
                    seen <- action (Run Inspect target key)
                    pure (terminated <> [seen])
                )
        _ <-
            clause
                absent
                (requirement resurrectionRefused CommandSucceeded)
                (pure [inserted])
        refusedInsertion
            resurrectionRefused
            target
            key
            "the ordinary insert of the Terminal key is booked, stops partial and names its pending request"
            folded
            unchanged

{- | A second insertion of a key the registry holds, refused at its fold, and
the request it left pending retracted by its owner.
-}
refusedInsertion
    :: Theorem thm
    -> Target
    -> String
    -> String
    -> String
    -> String
    -> TheoremStory thm CliI ()
refusedInsertion thm target key again folded unchanged = do
    (cli0, before) <-
        clause
            again
            ( bindCheck thm $ \(cli, seen) ->
                action (Require PartialPending [cli, seen])
            )
            ( do
                cli <- action (Run Insert target key)
                seen <- action (Observe target key)
                pure (cli, seen)
            )
    refusedFold <-
        clause
            folded
            (requirement thm RefusedByState)
            (pure <$> action (FoldUnevaluated target key))
    exposureBounded thm refusedFold
    both <-
        clause
            unchanged
            (requirement thm Unchanged)
            ( do
                after <- action (Observe target key)
                pure [before, after]
            )
    let pending = case both of
            [_, after] -> after
            _ -> error "refusedInsertion: two readbacks"
        partial = cli0
    void $
        clause
            "the owner's retraction of that request, inside its retract window, is accepted and returns its bond"
            ( bindCheck thm $ \(p, b, r, a) ->
                action (Require Reclaimed [p, b, r, a])
            )
            ( do
                r <- action (Reclaim target key partial pending)
                a <- action (Observe target key)
                pure (partial, pending, r, a)
            )

-- | The actions a story runs, by the name their receipts carry, in order.
actionsOf :: Story () -> [Text]
actionsOf = go
  where
    go :: Story a -> [Text]
    go program = case view program of
        Return _ -> []
        Action i :>>= next -> names i <> go (next (blank i))
        Theorem _ body :>>= next -> inClauses (clauses body) next
    inClauses
        :: Program (Clause thm CliI) b -> (b -> Story a) -> [Text]
    inClauses p k = case view p of
        Return b -> go (k b)
        Clause _ leanCheck body :>>= next ->
            let obs = resultOf body
            in  go body <> go (checkAction leanCheck obs) <> inClauses (next obs) k
    names i = maybe [] (\(a, _, _) -> [a]) (identify i)
    resultOf :: Story a -> a
    resultOf program = case view program of
        Return a -> a
        Action i :>>= next -> resultOf (next (blank i))
        Theorem _ _ :>>= _ -> error "actionsOf: a statement nested inside a clause"
    blank :: CliI a -> a
    blank i = case i of
        Require _ _ -> ()
        Retire _ -> ()
        Run{} -> emptyReceipt 0 "" "" ""
        RunByToken{} -> emptyReceipt 0 "" "" ""
        Book{} -> emptyReceipt 0 "" "" ""
        FoldUnevaluated{} -> emptyReceipt 0 "" "" ""
        Observe{} -> emptyReceipt 0 "" "" ""
        Craft{} -> emptyReceipt 0 "" "" ""
        Provoke{} -> emptyReceipt 0 "" "" ""
        Reclaim{} -> emptyReceipt 0 "" "" ""
        ReadIndexer{} -> emptyReceipt 0 "" "" ""

{- | What a take on an existing registry never does: create one, or provoke a
command by stopping a process or a node. Quantified over every command and
every provocation this module defines, so a provocation added later is
forbidden until a ruling admits it.
-}
forbiddenInPermanent :: [Text]
forbiddenInPermanent =
    ["run create"]
        <> [ "provoke " <> T.pack (provocationName p) | p <- [minBound .. maxBound]
           ]

-- | Why the saved-selector promise is retired.
selectorRetired :: String
selectorRetired =
    "Retired: a registry is joined from its state token alone; there is no saved selector file to change."

{- | The client's obligations under conditions of its process, each told
under the row of the CLI's specification it bears on: a changed selector,
withheld public history and an absent node; a terminate and a create killed
once the node accepted them; and, last because it stops the node, a
concurrent writer, a racing create and an update that loses its node.
-}
processStory :: Story ()
processStory = do
    let target = Target "process"
        interrupted = Target "interrupted"
        raced = Target "raced"
        second = "second"
        third = "third"
        reader = Target "reader"
        reading key title thm =
            premiseClause
                thm
                title
                ReachedActive
                (pure <$> action (Run Inspect target key))
    theorem identityBinds $ do
        _ <-
            premiseClause
                identityBinds
                "the key reached Active through the ordinary commands, and inspect reads it Active"
                ReachedActive
                (reach False target)
        _ <-
            clause
                "a second actor, starting from an empty directory with only the state token, reads the same registry"
                (requirement identityBinds TokenOnlyReading)
                ( do
                    mine <- action (Run Inspect target heldKey)
                    theirs <- action (RunByToken reader target Inspect heldKey)
                    pure [mine, theirs]
                )
        _ <-
            clause
                "a second actor, starting from an empty directory with only the state token, folds Alice's pending request and reads it Active"
                (requirement identityBinds FoldConsumed)
                ( do
                    booking <- action (Book target freshKey)
                    folded <- action (RunByToken reader target Fold freshKey)
                    seen <- action (RunByToken reader target Inspect freshKey)
                    pure [booking, folded, seen]
                )
        -- Retired by operator ruling: no command reads a saved selector. The
        -- second key is still inserted, for the clauses below that use it.
        _ <-
            clause
                "an insert with the saved application selector changed is refused before submitting"
                (requirement identityBinds RefusedBeforeSubmitting)
                ([] <$ action (Retire selectorRetired))
        void $
            clause
                "the same insert, with the selector restored, is accepted"
                (requirement identityBinds CommandSucceeded)
                ( action (Retire selectorRetired)
                    >> (pure <$> action (Run Insert target second))
                )
    theorem authenticated $ do
        _ <- reading heldKey "inspect reads the key Active" authenticated
        void $
            clause
                "inspect with the public history it needs withheld prints no leaf and names HistoryIncomplete"
                (requirement authenticated NoLeafPrinted)
                (pure <$> action (Provoke WithoutHistory target heldKey))
    theorem readOnly $ do
        _ <- reading heldKey "inspect reads the key Active" readOnly
        void $
            clause
                "inspect against a node socket that does not exist prints no leaf"
                (requirement readOnly NoLeafPrinted)
                (pure <$> action (Provoke WithoutNode target heldKey))
    theorem partialSurvives $ do
        _ <- reading heldKey "inspect reads the key Active" partialSurvives
        killed <-
            clause
                "a terminate killed once the node accepted its fold stopped there, its body kept"
                (requirement partialSurvives StoppedAfterAcceptance)
                (pure <$> action (Provoke TerminateKilled target heldKey))
        updated <-
            clause
                "an update of another key then reconciles the fold from the chain and proceeds, or, while the fold is not yet on chain, is refused before submitting, naming the fold and its case"
                ( bindCheck partialSurvives $ \seen ->
                    action (Require ReconciledOrRefused (take 1 killed <> seen))
                )
                (pure <$> action (Provoke UpdateAfterKill target second))
        _ <-
            clause
                "inspect reads the key Terminal, the fold replayed at the chain root, never resubmitted and observed once across every receipt: the killed terminate's fold is accepted"
                ( bindCheck partialSurvives $ \seen ->
                    action
                        (Require ResolvedFromChain (take 1 killed <> take 1 updated <> [seen]))
                )
                (action (Run Inspect target heldKey))
        booted <-
            clause
                "a create killed once the node accepted its boot stopped there, its body kept"
                (requirement partialSurvives StoppedAfterAcceptance)
                (pure <$> action (Provoke CreateKilled interrupted ""))
        _ <-
            clause
                "a second create of that registry is refused before submitting"
                (requirement partialSurvives RefusedBeforeSubmitting)
                (pure <$> action (Provoke CreateAgain interrupted ""))
        void $
            clause
                "inspect reads the incomplete create from its journal and observes its boot, printing no leaf"
                ( bindCheck partialSurvives $ \seen ->
                    action (Require IncompleteCreateRead (take 1 booted <> [seen]))
                )
                (action (Run Inspect interrupted heldKey))
    theorem haltsAttributably $ do
        _ <-
            reading second "inspect reads a second key Active" haltsAttributably
        _ <-
            clause
                "an insert while another process holds the registry's lock is refused before submitting"
                (requirement haltsAttributably RefusedBeforeSubmitting)
                (pure <$> action (Provoke WhileLocked target third))
        _ <-
            clause
                "the same insert, once the lock is released, is accepted"
                (requirement haltsAttributably CommandSucceeded)
                (pure <$> action (Run Insert target third))
        _ <-
            clause
                "the same wallet starts create on the same seed twice; the second is held before the lock while the first completes, and is refused because the registry exists"
                (requirement haltsAttributably LateCreateRefused)
                (pure <$> action (Provoke LateCreate raced ""))
        _ <-
            clause
                "a create from a wallet that cannot fund every publication is refused before it submits anything, leaving its directory untouched and its seed unspent"
                (requirement haltsAttributably CreateUnderfunded)
                (pure <$> action (Provoke UnderfundedCreate raced ""))
        void $
            clause
                "an update held once the node accepted it, with the node stopped, ends within its bound naming its transaction"
                (requirement haltsAttributably BoundedAfterNodeLoss)
                (pure <$> action (Provoke NodeLost target second))

-- ---------------------------------------------------------
-- Receipts
-- ---------------------------------------------------------

-- | A readback of one registry, for one key.

{- | What a submitted transaction states about its fee and collateral, read
from the body the receipt retained and never from the receipt's own words:
only admission sets it.
-}
data Account = Account
    { acFee :: Integer
    , acCollateralInputs :: [Text]
    , acCollateralTotal :: Maybe Integer
    -- ^ The total collateral the body declares, if it declares one
    , acCollateralReturn :: Maybe Integer
    -- ^ The lovelace of the collateral return the body declares, if any
    , acSpends :: [Text]
    -- ^ The outputs the body spends, as output references
    }
    deriving stock (Eq, Show)

-- | A public indexer the take asks about its Active key.
data Indexer = Koios | Blockfrost
    deriving stock (Eq, Show, Enum, Bounded)

indexerName :: Indexer -> String
indexerName ix = case ix of
    Koios -> "koios"
    Blockfrost -> "blockfrost"

{- | What an indexer's readback record keeps, as read from the record's retained
bytes by admission and never from the receipt's own words: the policy and asset
name it was asked about, the provider's own answers counted into the outputs
that hold the token, the output, datum bytes and tip it reports, what the node
read, the maximum lag it was run under, and the summary it states. The verdict
recomputes every comparison from these facts; the stated summary is only checked
against them.
-}
data IndexerRead = IndexerRead
    { irProvider :: Text
    , irPolicy :: Text
    , irAssetName :: Text
    , irHolders :: Maybe [(Text, Integer)]
    {- ^ Every output the provider's answer says holds the token, with how many
    of it; nothing when the record keeps no such answer
    -}
    , irHolderAddresses :: Maybe Int
    -- ^ How many addresses the provider's answer says hold the token (Blockfrost)
    , irAnswerDatum :: Maybe Text
    -- ^ The inline datum bytes the provider's answer carries for its holder
    , irAnswerTip :: Maybe Integer
    -- ^ The tip slot the provider's own answer reports
    , irIndexerOutput :: Text
    , irIndexerDatumCbor :: Text
    , irIndexerDatumHashRecorded :: Text
    -- ^ The hash the record says it recomputed from the indexer's datum
    , irIndexerDatumHashComputed :: Maybe Text
    {- ^ The blake2b-256 of the indexer's datum bytes, computed by admission from
    the record's bytes; nothing until admitted, or when the bytes are not hex
    -}
    , irIndexerTipSlot :: Maybe Integer
    , irMaxLagSlots :: Maybe Integer
    , irNodeOutput :: Text
    , irNodeDatumCbor :: Text
    , irNodeDatumHash :: Text
    , irNodeChainPoint :: Text
    , irStated :: Stated
    , irMalformed :: [Text]
    {- ^ Every whole-number fact the record keeps that is not an exact whole number
    of its domain, named with its raw value. A malformed quantity or index of an
    output holding the token withholds the provider's whole answer.
    -}
    }
    deriving stock (Eq, Show)

{- | The domain a whole-number fact of a readback record lies in: a quantity or
a slot (0 to 2^64-1), an output index (0 to 65535), or a lag, negative when the
indexer is ahead of the node (within 64 signed bits).
-}
data Whole = Count | OutputIndex | Lag
    deriving stock (Eq, Show)

wholeBounds :: Whole -> (Integer, Integer)
wholeBounds d = case d of
    Count -> (0, toInteger (maxBound :: Word64))
    OutputIndex -> (0, 65535)
    Lag -> (toInteger (minBound :: Int64), toInteger (maxBound :: Int64))

{- | A whole number of its domain, exactly, from a JSON number or the decimal
digits of one: a fraction is never rounded into one, and a number outside the
domain is not one.
-}
wholeIn :: Whole -> Aeson.Value -> Maybe Integer
wholeIn d raw = do
    n <- case raw of
        Aeson.Number s -> case d of
            Lag -> toInteger <$> (Sci.toBoundedInteger s :: Maybe Int64)
            _ -> toInteger <$> (Sci.toBoundedInteger s :: Maybe Word64)
        Aeson.String t -> case T.uncons t of
            Just ('-', ds) | d == Lag -> negate <$> digits ds
            _ -> digits t
        _ -> Nothing
    n <$ guard (lo <= n && n <= hi)
  where
    (lo, hi) = wholeBounds d
    digits ds = do
        guard (not (T.null ds) && T.length ds <= 20 && T.all isDigit ds)
        readMaybe (T.unpack ds)

-- | A fact outside its domain, named with its raw value and the domain it misses.
notWhole :: Text -> Whole -> Aeson.Value -> Text
notWhole what d raw =
    what
        <> " is "
        <> TE.decodeUtf8 (BL.toStrict (Aeson.encode raw))
        <> ", not "
        <> case d of
            OutputIndex -> "an exact output index from 0 to 65535"
            _ ->
                "an exact whole number from "
                    <> T.pack (show lo)
                    <> " to "
                    <> T.pack (show hi)
  where
    (lo, hi) = wholeBounds d

-- | The summary a readback record states about itself.
data Stated = Stated
    { stHolds :: Bool
    , stSameOutput :: Bool
    , stSameDatumBytes :: Bool
    , stSameDatumHash :: Bool
    , stWithinLag :: Bool
    , stLagSlots :: Maybe Integer
    }
    deriving stock (Eq, Show)

-- | The record the readback script writes, in the fields the verdict reads.
decodeIndexerRead :: Aeson.Value -> Maybe IndexerRead
decodeIndexerRead v = do
    provider <- str v ["provider"]
    policy <- str v ["policy"]
    name <- str v ["assetName"]
    holds <- bool ["holds"]
    sameOut <- bool ["comparisons", "sameOutput"]
    bytes <- bool ["comparisons", "sameDatumBytes"]
    hash <- bool ["comparisons", "sameDatumHash"]
    lagOk <- bool ["comparisons", "withinLag"]
    found <- str v ["indexer", "output"]
    cbor <- str v ["indexer", "datumCbor"]
    recomputed <- str v ["indexer", "datumHashRecomputed"]
    nodeOut <- str v ["inspect", "output"]
    nodeCbor <- str v ["inspect", "datumCbor"]
    nodeHash <- str v ["inspect", "datumHash"]
    point <- str v ["inspect", "observedTip"]
    let unit = policy <> name
        answers =
            [ (url, response)
            | Just (Aeson.Array rs) <- [path v ["requests"]]
            , r <- V.toList rs
            , Just (Aeson.String url) <- [path r ["url"]]
            , Just (Aeson.Number 200) <- [path r ["status"]]
            , Just response <- [path r ["response"]]
            ]
        lastAnswer p = case [a | (url, a) <- answers, p url] of
            [] -> Nothing
            as -> Just (last as)
        -- Every output of an answer, as its reference and how many of the token
        -- it holds, or the fact that makes it unreadable: an entry for the token
        -- whose quantity is not exact withholds the whole answer, and never drops
        -- out of the sum.
        census what entries matches answer = case answer of
            Just (Aeson.Array os) -> case lefts outputs of
                [] -> (Just (rights outputs), [])
                bad -> (Nothing, bad)
              where
                outputs = map (holding what entries matches) (V.toList os)
            _ -> (Nothing, [])
        holding what entries matches o = do
            let tx = fromMaybe "" (str o ["tx_hash"])
                index = case path o ["tx_index"] of
                    Just i -> Just i
                    Nothing -> path o ["output_index"]
            ix <- whole (what <> "'s output index of " <> tx) OutputIndex index
            r <- case (str o ["tx_hash"], ix) of
                (Just t, Just i) -> Right (t <> "#" <> T.pack (show i))
                _ ->
                    Left (what <> " names an output without its transaction and index")
            qs <-
                traverse
                    (quantityAt r)
                    [ a
                    | Just (Aeson.Array as) <- [path o [entries]]
                    , a <- V.toList as
                    , matches a
                    ]
            pure (r, sum qs)
          where
            quantityAt r a =
                whole
                    (what <> "'s quantity of the token at " <> r)
                    Count
                    (path a ["quantity"])
                    >>= maybe
                        (Left (what <> " states no quantity of the token at " <> r))
                        Right
        (holders, holderFaults) = case provider of
            "koios" ->
                census
                    "the koios answer"
                    "asset_list"
                    ( \a ->
                        str a ["policy_id"] == Just policy
                            && str a ["asset_name"] == Just name
                    )
                    (lastAnswer ("/asset_utxos" `T.isSuffixOf`))
            _ ->
                census
                    "the blockfrost answer"
                    "amount"
                    (\a -> str a ["unit"] == Just unit)
                    (lastAnswer (("/utxos/" <> unit) `T.isSuffixOf`))
        answerDatum = case provider of
            "koios" -> do
                Aeson.Array os <- lastAnswer ("/asset_utxos" `T.isSuffixOf`)
                case V.toList os of
                    [o] -> str o ["inline_datum", "bytes"]
                    _ -> Nothing
            _ -> do
                Aeson.Array os <- lastAnswer (("/utxos/" <> unit) `T.isSuffixOf`)
                case V.toList os of
                    [o] -> str o ["inline_datum"]
                    _ -> Nothing
        answerTip = case provider of
            "koios" -> case lastAnswer ("/tip" `T.isSuffixOf`) of
                Just (Aeson.Array ts)
                    | Just t <- ts V.!? 0 ->
                        whole "the koios answer's tip slot" Count (path t ["abs_slot"])
                _ -> Right Nothing
            _ -> case lastAnswer ("/blocks/latest" `T.isSuffixOf`) of
                Just b -> whole "the blockfrost answer's tip slot" Count (path b ["slot"])
                Nothing -> Right Nothing
        tipSlot =
            whole
                "the record's indexer tip slot"
                Count
                (path v ["indexer", "tipSlot"])
        maxLag = whole "the record's maximum lag" Count (path v ["maxLagSlots"])
        lagSlots = whole "the record's stated lag" Lag (path v ["lagSlots"])
        exact = fromRight Nothing
        addresses = case provider of
            "koios" -> Nothing
            _ -> case lastAnswer (("/assets/" <> unit <> "/addresses") `T.isSuffixOf`) of
                Just (Aeson.Array as) -> Just (V.length as)
                _ -> Nothing
    pure
        IndexerRead
            { irProvider = provider
            , irPolicy = policy
            , irAssetName = name
            , irHolders = holders
            , irHolderAddresses = addresses
            , irAnswerDatum = answerDatum
            , irAnswerTip = exact answerTip
            , irIndexerOutput = found
            , irIndexerDatumCbor = cbor
            , irIndexerDatumHashRecorded = recomputed
            , irIndexerDatumHashComputed = Nothing
            , irIndexerTipSlot = exact tipSlot
            , irMaxLagSlots = exact maxLag
            , irNodeOutput = nodeOut
            , irNodeDatumCbor = nodeCbor
            , irNodeDatumHash = nodeHash
            , irNodeChainPoint = point
            , irStated =
                Stated
                    { stHolds = holds
                    , stSameOutput = sameOut
                    , stSameDatumBytes = bytes
                    , stSameDatumHash = hash
                    , stWithinLag = lagOk
                    , stLagSlots = exact lagSlots
                    }
            , irMalformed =
                holderFaults <> lefts [answerTip, tipSlot, maxLag, lagSlots]
            }
  where
    path :: Aeson.Value -> [Text] -> Maybe Aeson.Value
    path = go . Just
      where
        go cur [] = cur
        go (Just (Aeson.Object o)) (k : ks) = go (KeyMap.lookup (Key.fromText k) o) ks
        go _ _ = Nothing
    str o p = case path o p of
        Just (Aeson.String s) -> Just s
        _ -> Nothing
    bool p = case path v p of
        Just (Aeson.Bool b) -> Just b
        _ -> Nothing
    {- A whole-number fact the record may keep, as text ("135000000") or as a
    number: absent (no value, null, or the empty text the script writes for a
    tip it did not read), exact, or malformed and named with its raw value. -}
    whole
        :: Text -> Whole -> Maybe Aeson.Value -> Either Text (Maybe Integer)
    whole what d raw = case raw of
        Nothing -> Right Nothing
        Just Aeson.Null -> Right Nothing
        Just (Aeson.String "") -> Right Nothing
        Just x -> maybe (Left (notWhole what d x)) (Right . Just) (wholeIn d x)

instance ToJSON Account where
    toJSON a =
        object
            [ "fee" .= acFee a
            , "collateralInputs" .= acCollateralInputs a
            , "collateralTotal" .= acCollateralTotal a
            , "collateralReturn" .= acCollateralReturn a
            , "spends" .= acSpends a
            ]

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
    {- ^ The key's leaf, authenticated by public replay at the root the
    chain holds: @active@, @terminal@ or @absent@; nothing when the
    acquired history does not prove it
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
    , rcResolved :: [Resolved]
    {- ^ For an ordinary command: every live output its journal read back
    without submitting it (a reference an earlier command published)
    -}
    , rcJournal :: Maybe JournalSpan
    {- ^ For an ordinary command: the lines its registry's journal gained
    while it ran, bound by digest
    -}
    , rcProcess :: Maybe ProcessEvidence
    -- ^ For a provoked command: what its process left, as recorded
    , rcAdmission :: Maybe [Text]
    {- ^ What reading the retained body and rejection back found wrong;
    nothing until the receipt is admitted. Never read from a receipt file:
    only admission sets it.
    -}
    , rcReason :: Maybe Text
    -- ^ The node's or the command's own words, bounded
    , rcObservation :: Maybe Observation
    , rcAllowance :: Maybe Integer
    {- ^ The most collateral a node-judged transaction of this run may state;
    none when the run set no bound
    -}
    , rcAccount :: Maybe Account
    {- ^ Its fee and collateral, read back from the retained body by
    admission; nothing until the receipt is admitted
    -}
    , rcReadbackFile :: Maybe Text
    -- ^ For an indexer read: the readback record kept beside the receipt
    , rcReadbackSha256 :: Maybe Text
    , rcIndexer :: Maybe IndexerRead
    , rcMaxLag :: Maybe Integer
    -- ^ For an indexer read: the maximum lag in slots the take was configured with
    , -- \^ What the retained readback record says, read back from its bytes by
      --    admission; nothing until the receipt is admitted
      --
      rcEvidence :: [Text]
    -- ^ Files beside the receipt: command output, transaction bodies
    , rcCommand :: Maybe Aeson.Value
    -- ^ A command's own printed receipt, as it printed it
    , rcWithheldReads :: Maybe Int
    {- ^ For an @inspect@ run with the public history it needs withheld:
    how many of the targeted registry's history reads the forwarder in
    front of its provider answered empty
    -}
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
        , rcResolved = []
        , rcJournal = Nothing
        , rcProcess = Nothing
        , rcAdmission = Nothing
        , rcReason = Nothing
        , rcObservation = Nothing
        , rcAllowance = Nothing
        , rcAccount = Nothing
        , rcReadbackFile = Nothing
        , rcReadbackSha256 = Nothing
        , rcIndexer = Nothing
        , rcMaxLag = Nothing
        , rcEvidence = []
        , rcCommand = Nothing
        , rcWithheldReads = Nothing
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
            , "resolved" .= rcResolved r
            , "journal" .= rcJournal r
            , "process" .= rcProcess r
            , "reason" .= rcReason r
            , "observation" .= rcObservation r
            , "allowance" .= rcAllowance r
            , "readbackFile" .= rcReadbackFile r
            , "readbackSha256" .= rcReadbackSha256 r
            , "maxLag" .= rcMaxLag r
            , "evidence" .= rcEvidence r
            , "command" .= rcCommand r
            , "withheldReads" .= rcWithheldReads r
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
            <*> (fromMaybe [] <$> o .:? "resolved")
            <*> o .:? "journal"
            <*> o .:? "process"
            <*> pure Nothing
            <*> o .:? "reason"
            <*> o .:? "observation"
            <*> o .:? "allowance"
            <*> pure Nothing
            <*> o .:? "readbackFile"
            <*> o .:? "readbackSha256"
            <*> pure Nothing
            <*> o .:? "maxLag"
            <*> o .: "evidence"
            <*> o .:? "command"
            <*> o .:? "withheldReads"

-- | The action name, target and key a receipt for this action must carry.
identify :: CliI res -> Maybe (Text, Text, Text)
identify i = case i of
    Run c (Target t) k -> Just ("run " <> T.pack (commandName c), T.pack t, T.pack k)
    RunByToken (Target actor) _ c k ->
        Just
            ( "run " <> T.pack (commandName c) <> " by token"
            , T.pack actor
            , T.pack k
            )
    Book (Target t) k -> Just ("book", T.pack t, T.pack k)
    FoldUnevaluated (Target t) k -> Just ("fold-unevaluated", T.pack t, T.pack k)
    Observe (Target t) k -> Just ("observe", T.pack t, T.pack k)
    Craft c (Target t) k ->
        Just ("craft " <> T.pack (craftedName c), T.pack t, T.pack k)
    Provoke p (Target t) k ->
        Just ("provoke " <> T.pack (provocationName p), T.pack t, T.pack k)
    Reclaim (Target t) k _ _ -> Just ("reclaim", T.pack t, T.pack k)
    ReadIndexer ix (Target t) k _ ->
        Just ("read-indexer " <> T.pack (indexerName ix), T.pack t, T.pack k)
    Require _ _ -> Nothing
    Retire _ -> Nothing

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

-- | Fail unless the receipt's outcome is the one named.
outcomeIs :: Receipt -> Text -> [String]
outcomeIs r expected =
    [ "the outcome is " <> show (rcOutcome r) <> ", not " <> show expected
    | rcOutcome r /= expected
    ]

-- | The outcome class a provoked command's condition calls for.
expectedOutcome :: Receipt -> Text
expectedOutcome r = case T.stripPrefix "provoke " (rcAction r) of
    Just "insert-while-locked" -> "concurrent-writer"
    Just "inspect-without-history" -> "stale-state"
    Just "inspect-without-node" -> "node-unavailable"
    Just "create-again" -> "client-refusal"
    _ -> "a provoked command's outcome"

-- | The step a killed command was killed at, by the node's acceptance of it.
killedStep :: Receipt -> Text
killedStep r = case T.stripPrefix "provoke " (rcAction r) of
    Just "terminate-killed" -> "fold"
    Just "create-killed" -> "boot"
    _ -> "step"

-- | The checks on what a provoked command's process left, if it was recorded.
withProcess :: Receipt -> (ProcessEvidence -> [String]) -> [String]
withProcess r f =
    maybe
        ["what the command's process left is not recorded"]
        f
        (rcProcess r)

{- | A provoked @inspect@: its outcome is the class its condition names,
and it printed no leaf.
-}
noLeaf :: Receipt -> [String]
noLeaf r =
    outcomeIs r (expectedOutcome r)
        <> [ "a leaf was printed: " <> maybe "" show leaf
           | let leaf = at [field "leaf"] r
           , leaf `notElem` [Nothing, Just Aeson.Null]
           ]

{- | An @inspect@ run with the public history it needs withheld. The
forwarder in front of its provider must have withheld at least one of the
targeted registry's history reads; then the command ends stale-state,
prints no leaf and names @HistoryIncomplete@. A withholding that never
reached the history read is judged for that alone: what the command then
printed is its consequence, not a second finding. In every case the
registry's journal must not have moved.
-}
withheldHistory :: Receipt -> [String]
withheldHistory r =
    reached <> withProcess r journalStill
  where
    reached = case rcWithheldReads r of
        Nothing -> ["no forwarder recorded withholding the command's history reads"]
        Just n
            | n < 1 -> [neverReached]
            | otherwise ->
                noLeaf r
                    <> [ "the refusal does not name HistoryIncomplete: "
                            <> maybe "no reason" T.unpack (rcReason r)
                       | not (maybe False ("HistoryIncomplete" `T.isInfixOf`) (rcReason r))
                       ]

-- | The one finding of a withholding that missed the command's history read.
neverReached :: String
neverReached =
    "the withholding never reached the command's history read: none of the registry's history reads was withheld"

-- | Fail unless the registry's journal did not move while the command ran.
journalStill :: ProcessEvidence -> [String]
journalStill p =
    [ "the registry's journal moved from "
        <> show (peJournalBefore p)
        <> " to "
        <> show (peJournalAfter p)
        <> " lines"
    | peJournalAfter p /= peJournalBefore p
    ]

-- | Fail unless the command submitted nothing.
nothingSubmitted :: Receipt -> ProcessEvidence -> [String]
nothingSubmitted r p =
    [ "the command submitted "
        <> show (length (peSubmitted p))
        <> " transactions"
    | not (null (peSubmitted p)) || not (null (rcSubmissions r))
    ]

{- | Fail unless the inspect observed, from the chain, the transaction the
killed command submitted (its first or last, as chosen).
-}
observedKilled :: Receipt -> Receipt -> ([Text] -> [Text]) -> [String]
observedKilled killed seen pick =
    withProcess killed $ \p -> case pick (peSubmitted p) of
        [] -> ["the killed command's journal records no submission"]
        t : _ ->
            [ "the inspect did not observe the killed command's transaction "
                <> T.unpack t
            | Aeson.String t
                `notElem` maybe [] toList' (at [field "observed"] seen)
            ]
  where
    toList' v = case v of
        Aeson.Array a -> V.toList a
        _ -> []

-- | The strings of a receipt list value; anything else holds none.
strings :: Maybe Aeson.Value -> [Text]
strings v = case v of
    Just (Aeson.Array a) -> [t | Aeson.String t <- V.toList a]
    _ -> []

-- | Fail unless two receipt values are present and equal.
same :: String -> Maybe Aeson.Value -> Maybe Aeson.Value -> [String]
same what a b = case (a, b) of
    (Just x, Just y) | x == y -> []
    (Nothing, _) -> [what <> ": the first receipt does not carry it"]
    (_, Nothing) -> [what <> ": the second receipt does not carry it"]
    _ -> [what <> " differs"]

{- | An actor identity usable for comparison: present text, never an
absent or wrongly typed value a distinct-wallet claim could skip.
-}
usableIdentity :: Maybe Aeson.Value -> Maybe Text
usableIdentity (Just (Aeson.String t)) = Just t
usableIdentity _ = Nothing

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

{- | A node-judged transaction of a run that set a collateral bound states its
collateral, within the bound, and returns the rest of its funding output. The
statement is read from the body admission retained: a refusal that would have
put the whole funding output at risk does not pass.
-}
collateralBounded :: Receipt -> [String]
collateralBounded r = case rcAllowance r of
    Nothing -> []
    Just allowance -> case rcAccount r of
        Nothing -> ["the collateral the transaction states is not recorded"]
        Just a ->
            case acCollateralTotal a of
                Nothing ->
                    [ "the transaction states no total collateral, so the collateral it puts at risk is not bounded"
                    ]
                Just total ->
                    [ "the transaction states a total collateral of "
                        <> show total
                        <> ", over the bound of "
                        <> show allowance
                    | total > allowance
                    ]
                        <> [ "the transaction returns no part of its collateral input"
                           | isNothing (acCollateralReturn a)
                           ]

{- | One indexer's read of the Active key, against the fresh inspect that named
the key's token, recomputed from the facts the retained record keeps and never
from the summary it states: every whole number the record keeps (a quantity, an
output index, a slot, a lag) is exact in its domain, never a rounded fraction or
a malformed entry left out of a sum; the provider's own answer counts exactly one output
holding exactly one of the token under the policy and asset name the inspect
names, and that output is the one the record reports and the inspect's; the
indexer's datum bytes are the inspect's and their blake2b-256, computed at
admission, is the inspect's datum hash; the indexer's tip is no further behind
the inspect's separately observed tip than the maximum lag the take was configured with.
The inspect side of the record must be the inspect's own, and a stated summary its
facts contradict is itself a failure. What this cannot establish is that the
provider answered honestly: the record's digest proves the bytes judged are the
bytes kept, not where they came from.
-}
indexerAgrees :: Receipt -> Receipt -> [String]
indexerAgrees inspect r =
    check ReachedActive [inspect]
        <> [ "the read's outcome is " <> show (rcOutcome r) <> ", not success"
           | rcOutcome r /= "success"
           ]
        <> admitted r
        <> maybe
            ["the receipt's retained readback record was not read back"]
            facts
            (rcIndexer r)
  where
    inspected p = case at p inspect of
        Just (Aeson.String s) -> Just s
        _ -> Nothing
    inspectOutput = inspected [field "applicationOutput", field "output"]
    inspectCbor = inspected [field "applicationOutput", field "datumCbor"]
    inspectHash = inspected [field "applicationOutput", field "datumHash"]
    inspectPoint = inspected [field "observedTip"]
    nodeSlot :: Maybe Integer
    nodeSlot = inspectPoint >>= readMaybe . T.unpack . T.takeWhile (/= '.')
    facts ir =
        [ "the record is of "
            <> T.unpack (irProvider ir)
            <> ", not of the indexer asked"
        | ("read-indexer " <> irProvider ir) /= rcAction r
        ]
            <> map
                (("the record keeps a malformed fact: " <>) . T.unpack)
                (irMalformed ir)
            <> map ("the token census: " <>) censusProblems
            <> [ "the indexer's output "
                    <> T.unpack (irIndexerOutput ir)
                    <> " is not the node's"
               | not outputOk
               ]
            <> [ "the indexer's datum bytes are not the node's"
               | not bytesOk
               ]
            <> [ "the record reports datum bytes the provider's answer does not carry"
               | irAnswerDatum ir /= Just (irIndexerDatumCbor ir)
               ]
            <> [ "the record reports a tip of "
                    <> maybe "none" show (irIndexerTipSlot ir)
                    <> ", but the provider's answer says "
                    <> maybe "none" show (irAnswerTip ir)
               | irAnswerTip ir /= irIndexerTipSlot ir
               ]
            <> hashProblems
            <> lagProblems
            <> same
                "the policy the indexer was asked about"
                (Just (Aeson.String (irPolicy ir)))
                ( at
                    [ field "applicationOutput"
                    , field "envelope"
                    , Left "fields"
                    , Right 0
                    , Left "fields"
                    , Right 2
                    , Left "bytes"
                    ]
                    inspect
                )
            <> same
                "the asset name the indexer was asked about"
                (Just (Aeson.String (irAssetName ir)))
                (at [field "key"] inspect)
            <> [ "the record's node " <> what <> " is not the inspect's"
               | (what, recorded, fresh) <-
                    [ ("output", irNodeOutput ir, inspectOutput)
                    , ("datum bytes", irNodeDatumCbor ir, inspectCbor)
                    , ("datum hash", irNodeDatumHash ir, inspectHash)
                    , ("chain point", irNodeChainPoint ir, inspectPoint)
                    ]
               , Just recorded /= fresh
               ]
            <> [ "the record states "
                    <> claim
                    <> " "
                    <> show stated
                    <> ", but its facts say "
                    <> show actual
               | (claim, stated, actual) <-
                    [
                        ( "holds"
                        , stHolds st
                        , censusOk && outputOk && bytesOk && hashOk && lagOk && rawOk
                        )
                    , ("sameOutput", stSameOutput st, outputOk)
                    , ("sameDatumBytes", stSameDatumBytes st, bytesOk)
                    , ("sameDatumHash", stSameDatumHash st, hashOk)
                    , ("withinLag", stWithinLag st, lagOk)
                    ]
               , stated /= actual
               ]
            <> [ "the record states a lag of "
                    <> maybe "none" show (stLagSlots st)
                    <> " slots, but its tip and the inspect's chain point give "
                    <> maybe "none" show lag
               | stLagSlots st /= lag
               ]
      where
        st = irStated ir
        censusProblems = case irHolders ir of
            Nothing -> ["the record keeps no provider answer to count the holders from"]
            Just [(ref, 1)]
                | ref /= irIndexerOutput ir ->
                    [ "the provider's answer names "
                        <> T.unpack ref
                        <> ", not the output the record reports"
                    ]
                | otherwise -> addressProblems
            Just [(_, q)] ->
                [ "the provider's answer holds "
                    <> show q
                    <> " of the token in its one output; exactly one must"
                ]
            Just hs ->
                [ "the provider's answer counts "
                    <> show (length hs)
                    <> " outputs holding the token; exactly one must"
                ]
        addressProblems = case irHolderAddresses ir of
            Just n
                | n /= 1 ->
                    [ "the provider's answer counts "
                        <> show n
                        <> " addresses holding the token; exactly one must"
                    ]
            _ -> []
        censusOk = null censusProblems
        outputOk = Just (irIndexerOutput ir) == inspectOutput
        bytesOk =
            not (T.null (irIndexerDatumCbor ir))
                && Just (irIndexerDatumCbor ir) == inspectCbor
        hashProblems = case irIndexerDatumHashComputed ir of
            Nothing -> ["admission computed no hash of the indexer's datum bytes"]
            Just h ->
                [ "the hash of the indexer's datum bytes is not the node's datum hash"
                | Just h /= inspectHash
                ]
                    <> [ "the record's recomputed datum hash is not the hash of its own datum bytes"
                       | h /= irIndexerDatumHashRecorded ir
                       ]
        hashOk = case irIndexerDatumHashComputed ir of
            Just h -> Just h == inspectHash && h == irIndexerDatumHashRecorded ir
            Nothing -> False
        lag = (-) <$> nodeSlot <*> irIndexerTipSlot ir
        lagProblems = case (rcMaxLag r, lag) of
            (Nothing, _) -> ["the read carries no maximum lag the take was configured with"]
            (_, Nothing) -> ["the record keeps no indexer tip to measure the lag from"]
            (Just allowed, Just l) ->
                [ "the record was run under a maximum lag of "
                    <> maybe "none" show (irMaxLagSlots ir)
                    <> ", not the "
                    <> show allowed
                    <> " the take configured"
                | irMaxLagSlots ir /= Just allowed
                ]
                    <> [ "the indexer is "
                            <> show l
                            <> " slots behind the node, beyond the "
                            <> show allowed
                            <> " allowed"
                       | l > allowed
                       ]
        rawOk =
            null (irMalformed ir)
                && irAnswerDatum ir == Just (irIndexerDatumCbor ir)
                && irAnswerTip ir == irIndexerTipSlot ir
        lagOk = case (rcMaxLag r, lag) of
            (Just allowed, Just l) -> l <= allowed && irMaxLagSlots ir == Just allowed
            _ -> False

{- | The bound a take on an existing registry owes every node-judged
transaction: the operator's explicit allowance is on the receipt (a missing
one is a failure, never a pass), and the body states its total collateral
within it and returns the rest.
-}
collateralBoundedRequired :: Receipt -> [String]
collateralBoundedRequired r = case rcAllowance r of
    Nothing ->
        [ "no collateral allowance was set for the transaction, so the collateral it puts at risk is not bounded"
        ]
    Just _ -> collateralBounded r

{- | A retraction, against the insertion's receipt that names the request and
the readbacks on either side of it: the request that receipt names is the one
the retained body spends and the one that left, no other left, the root did
not move, and the wallet holds exactly the bond released less the fee paid.
-}
reclaimed :: Receipt -> Receipt -> Receipt -> Receipt -> [String]
reclaimed partial before r after =
    [ "the retraction's outcome is "
        <> show (rcOutcome r)
        <> ", not accepted"
    | rcOutcome r /= "accepted"
    ]
        <> submitted r
        <> admitted r
        <> collateralBoundedRequired r
        <> [ "the retraction names the request "
                <> maybe "none" T.unpack (rcPendingRequest r)
                <> ", not the "
                <> maybe "none" T.unpack (rcPendingRequest partial)
                <> " the insertion's receipt names"
           | rcPendingRequest r /= rcPendingRequest partial
           ]
        <> case (rcPendingRequest partial, rcAccount r) of
            (Just p, Just a) ->
                [ "the retained body does not spend the request "
                    <> T.unpack p
                    <> " the insertion's receipt names"
                | filter (== p) (acSpends a) /= [p]
                ]
            _ ->
                [ "the insertion's receipt names no request, or the retraction records no body to read its spends from"
                ]
        <> case ( rcObservation before
                , rcObservation after
                , rcPendingRequest r
                , rcAccount r
                ) of
            (Just x, Just y, Just p, Just a) ->
                [ "the request "
                    <> T.unpack p
                    <> " was not pending before the retraction"
                | p `notElem` obPending x
                ]
                    <> [ "the request "
                            <> T.unpack p
                            <> " is still pending after the retraction"
                       | p `elem` obPending y
                       ]
                    <> [ "a request other than the retracted one left: "
                            <> show (filter (`notElem` obPending y) (obPending x))
                       | filter (`notElem` obPending y) (obPending x) /= [p]
                       ]
                    <> ["the registry's root moved" | obRoot x /= obRoot y]
                    <> [ "the wallet holds "
                            <> show (obWalletLovelace y)
                            <> ", not the "
                            <> show (obWalletLovelace x)
                            <> " it held plus the "
                            <> show released
                            <> " the request released less the "
                            <> show (acFee a)
                            <> " the retraction paid"
                       | obWalletLovelace y /= obWalletLovelace x + released - acFee a
                       ]
              where
                released = obPendingLovelace x - obPendingLovelace y
            _ ->
                [ "the retraction names no pending request, records no fee, or a readback carries no observation"
                ]
        <> [ "the readbacks are of other registries or keys"
           | (rcTarget before, rcKey before) /= (rcTarget after, rcKey after)
           ]

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
            <> collateralBounded r
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
    (TokenOnlyReading, [mine, theirs]) ->
        succeeded "the actor's own inspect" mine
            <> succeeded "the second actor's inspect" theirs
            <> same
                "the registry's root"
                (at [field "root"] mine)
                (at [field "root"] theirs)
            <> same
                "the key's leaf"
                (at [field "leaf"] mine)
                (at [field "leaf"] theirs)
    (FoldConsumed, [booking, folded, seen]) ->
        [ "the booking's outcome is "
            <> show (rcOutcome booking)
            <> ", not accepted"
        | rcOutcome booking /= "accepted"
        ]
            <> submitted booking
            <> succeeded "the token-only fold" folded
            <> same
                "the folded request"
                (Aeson.String . (<> "#0") <$> rcTxId booking)
                (at [field "request"] folded)
            <> [ "the fold is of another key"
               | rcKey booking /= rcKey folded
               ]
            <> succeeded "the token-only inspect" seen
            <> [ "the inspect is of another key"
               | rcKey folded /= rcKey seen
               ]
            <> is "the key's leaf" "active" (at [field "leaf"] seen)
            <> same
                "the holding's inline envelope"
                (at [field "envelope"] folded)
                (at [field "applicationOutput", field "envelope"] seen)
            <> same
                "the registry's root"
                (at [field "root"] folded)
                (at [field "root"] seen)
            <> [ "the fold names no usable folder"
               | isNothing (usableIdentity (at [field "folder"] folded))
               ]
            <> [ "the inspect names no usable holding controller"
               | isNothing
                    ( usableIdentity
                        (at [field "applicationOutput", field "controller"] seen)
                    )
               ]
            <> [ "the token-only fold was funded by the booking controller's own wallet"
               | Just f <- [usableIdentity (at [field "folder"] folded)]
               , Just c <-
                    [ usableIdentity
                        (at [field "applicationOutput", field "controller"] seen)
                    ]
               , f == c
               ]
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
    (Reclaimed, [p, b, r, a]) -> reclaimed p b r a
    (ExposureBounded, [r]) -> collateralBoundedRequired r
    (IndexerAgrees, [i, r]) -> indexerAgrees i r
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
            <> collateralBounded r
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
    (RefusedBeforeSubmitting, [r]) ->
        outcomeIs r (expectedOutcome r)
            <> withProcess r (\p -> journalStill p <> nothingSubmitted r p)
            <> admitted r
    (NoLeafPrinted, [r])
        | rcAction r == "provoke inspect-without-history" ->
            withheldHistory r <> admitted r
        | otherwise -> noLeaf r <> admitted r
    (StoppedAfterAcceptance, [r]) ->
        withProcess
            r
            ( \p ->
                [ "the process was not killed: it exited " <> show (peExit p)
                | peExit p >= 0
                ]
                    <> [ "the journal's last line when it stopped is "
                            <> show (peLastEvent p)
                            <> ", not the node's acceptance of its "
                            <> T.unpack (killedStep r)
                       | peLastEvent p /= killedStep r <> "/submitted"
                       ]
                    <> case reverse (peSubmitted p) of
                        [] -> ["the journal records no submission of the command"]
                        t : _ ->
                            [ "the accepted transaction "
                                <> T.unpack t
                                <> " has no kept body"
                            | t `notElem` map suTxId (rcSubmissions r)
                            ]
            )
            <> admitted r
    (ReconciledOrRefused, [killed, r]) ->
        withProcess killed $ \pk -> case reverse (peSubmitted pk) of
            [] -> ["the killed command's journal records no submission"]
            t : _ -> case rcOutcome r of
                "success" ->
                    succeeded "the update" r
                        <> same
                            "the replayed root and the included fold's chain root"
                            (at [field "root"] r)
                            (Aeson.String . obRoot <$> rcObservation killed)
                        <> [ "the killed fold was submitted again"
                           | t `elem` map suTxId (rcSubmissions r)
                           ]
                        <> [ "the update did not observe the killed fold " <> T.unpack t
                           | t `notElem` strings (at [field "reconciled", field "observed"] r)
                           ]
                "partial" ->
                    withProcess r (\p -> journalStill p <> nothingSubmitted r p)
                        <> is
                            "the refused transaction"
                            (Aeson.String t)
                            (at [field "unresolved", field "tx"] r)
                        <> is
                            "the refused transaction's case"
                            "acknowledged"
                            (at [field "unresolved", field "case"] r)
                        <> admitted r
                other ->
                    [ "the outcome is "
                        <> show other
                        <> ", neither success nor partial"
                    ]
    (ResolvedFromChain, [killed, updated, seen]) ->
        succeeded "the inspect" seen
            <> is "the key's leaf" "terminal" (at [field "leaf"] seen)
            <> withProcess
                killed
                ( \pk -> case reverse (peSubmitted pk) of
                    [] -> ["the killed command's journal records no submission"]
                    t : _ ->
                        let times what xs =
                                [ "the killed fold "
                                    <> T.unpack t
                                    <> " was "
                                    <> what
                                    <> " "
                                    <> show n
                                    <> " times, not once"
                                | let n = length (filter (== t) xs)
                                , n /= 1
                                ]
                        in  times
                                "observed"
                                ( strings (at [field "reconciled", field "observed"] updated)
                                    <> strings (at [field "observed"] seen)
                                )
                                <> [ "the killed fold was submitted again"
                                   | t
                                        `elem` ( map suTxId (rcSubmissions updated <> rcSubmissions seen)
                                                    <> maybe [] peSubmitted (rcProcess updated)
                                                    <> maybe [] peSubmitted (rcProcess seen)
                                               )
                                   ]
                                <> same
                                    "the replayed root and the included fold's chain root"
                                    (at [field "root"] seen)
                                    (Aeson.String . obRoot <$> rcObservation killed)
                                <> same
                                    "the replayed root and inspect's chain root"
                                    (at [field "root"] seen)
                                    (Aeson.String . obRoot <$> rcObservation seen)
                )
            <> admitted killed
    (IncompleteCreateRead, [killed, seen]) ->
        outcomeIs seen "partial"
            <> [ "the inspect did not read the incomplete create's seed"
               | at [field "incompleteCreate", field "seed"] seen
                    `elem` [Nothing, Just Aeson.Null]
               ]
            <> [ "the inspect printed a leaf for an incomplete create"
               | at [field "leaf"] seen `notElem` [Nothing, Just Aeson.Null]
               ]
            <> observedKilled killed seen id
            <> admitted seen
            <> admitted killed
    (LateCreateRefused, [r]) ->
        outcomeIs r "client-refusal"
            <> [ "the refusal is not that the registry exists: "
                    <> maybe "no reason" T.unpack (rcReason r)
               | not
                    ( maybe
                        False
                        ( "already holds your state or its journal; create never overwrites one"
                            `T.isSuffixOf`
                        )
                        (rcReason r)
                    )
               ]
            <> withProcess
                r
                ( \p ->
                    [ "the first registry's saved files are not recorded"
                    | null (peFilesBefore p)
                    ]
                        <> [ "the first registry's saved files changed"
                           | byName (peFilesBefore p) /= byName (peFilesAfter p)
                           ]
                        <> [ "the late wallet's seed was not probed afterwards"
                           | isNothing (peSeedProbe p)
                           ]
                )
            <> admitted r
    (CreateUnderfunded, [r]) ->
        outcomeIs r "client-refusal"
            <> [ "the refusal is not publication funding: "
                    <> maybe "no reason" T.unpack (rcReason r)
               | not
                    ( maybe
                        False
                        ("publication-unfunded" `T.isPrefixOf`)
                        (rcReason r)
                    )
               ]
            <> withProcess
                r
                ( \p ->
                    journalStill p
                        <> nothingSubmitted r p
                        <> [ "the refused create wrote to its directory"
                           | byName (peFilesBefore p) /= byName (peFilesAfter p)
                           ]
                        <> [ "the underfunded wallet's seed was not probed afterwards"
                           | isNothing (peSeedProbe p)
                           ]
                )
            <> admitted r
    (BoundedAfterNodeLoss, [r]) ->
        [ "the outcome is " <> show (rcOutcome r) <> ", not partial or timeout"
        | rcOutcome r `notElem` ["partial", "timeout"]
        ]
            <> withProcess
                r
                ( \p ->
                    [ "the command ran "
                        <> maybe "an unknown time" (\s -> show s <> "s") (peWaited p)
                        <> " past its release, beyond its 30-second bound and teardown"
                    | maybe True (> 90) (peWaited p)
                    ]
                        <> [ "the journal does not keep the submitted update unresolved: its last line is "
                                <> show (peLastEvent p)
                           | not ("/unconfirmed" `T.isSuffixOf` peLastEvent p)
                           ]
                        <> case peSubmitted p of
                            [] -> ["the journal records no submission of the update"]
                            ts ->
                                [ "the receipt does not name the submitted transaction"
                                | not (any (\t -> maybe False (t `T.isInfixOf`) (rcReason r)) ts)
                                ]
                )
            <> admitted r
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
                           , ReconciledOrRefused
                           , IncompleteCreateRead
                           , IndexerAgrees
                           ]
                    then "two"
                    else
                        if req `elem` [PayloadReplaced, Released, ResolvedFromChain]
                            then "three"
                            else
                                if req == Reclaimed
                                    then "four"
                                    else "one"
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
    | -- | The promise is retired, for this reason; no receipt judges it
      Retired String
    deriving stock (Eq, Show)

data ClauseResult = ClauseResult
    { crStatement :: String
    , crTitle :: String
    , crStatus :: ClauseStatus
    }
    deriving stock (Eq, Show)

-- | Every clause's verdict holds, or its promise is retired.
held :: [ClauseResult] -> Bool
held = all (\r -> crStatus r == Held || isRetired (crStatus r))

-- | Whether a clause's promise is retired.
isRetired :: ClauseStatus -> Bool
isRetired s = case s of
    Retired _ -> True
    _ -> False

{- | Interpret the story over receipts. A receipt answers the action at its
step exactly when it names that action, target and key; the first missing
or misplaced receipt leaves every later clause uncovered, naming why, but
a clause whose promise is retired, which reads retired from its description.
Requirements inside a clause's body fail the clause; its check decides it.
-}
judge :: [Receipt] -> Story () -> [ClauseResult]
judge receipts story =
    let byStep = Map.fromListWith (<>) [(rcStep r, [r]) | r <- receipts]
        (reached, stop) = replay byStep story
        names = described story
        missing = drop (length reached) names
        why = fromMaybe "no receipt" stop
    in  reached
            <> [ ClauseResult s t (maybe (Uncovered why) Retired retired)
               | ((s, t), retired) <- missing
               ]

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
                    (Just (obs, (bodyFailures, _, retired)), Nothing) ->
                        let (checked, Replay n' _ stop') =
                                collect (Replay n [] Nothing) (checkAction leanCheck obs)
                            failures =
                                bodyFailures <> maybe [] (\(_, (fs, _, _)) -> fs) checked
                            isPremise = maybe False (\(_, (_, p, _)) -> p) checked
                            status
                                | Just why <- retired = Retired why
                                | Just why <- stop' = Uncovered why
                                | Just failed <- premise =
                                    Uncovered ("its premise does not hold: " <> failed)
                                | null failures = Held
                                | otherwise = NotHeld failures
                            premise'
                                | Just _ <- premise = premise
                                | isPremise
                                , NotHeld why <- status =
                                    Just (title <> ", because " <> intercalate "; " why)
                                | isPremise
                                , Uncovered why <- status =
                                    Just (title <> ", because " <> why)
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
    collect
        :: Replay
        -> Story a
        -> (Maybe (a, ([String], Bool, Maybe String)), Replay)
    collect st0 = walk st0 ([], False, Nothing)
      where
        walk
            :: Replay
            -> ([String], Bool, Maybe String)
            -> Story a
            -> (Maybe (a, ([String], Bool, Maybe String)), Replay)
        walk st@(Replay _ _ (Just _)) _ _ = (Nothing, st)
        walk st acc@(fs, p, retired) program = case view program of
            Return a -> (Just (a, acc), st)
            Action (Require req rs) :>>= next ->
                walk
                    st
                    (fs <> check req rs, p || req `elem` premises, retired)
                    (next ())
            Action (Retire why) :>>= next ->
                walk st (fs, p, Just why) (next ())
            Action i :>>= next -> case perform st i of
                (Just r, st') -> walk st' acc (next r)
                (Nothing, st') -> (Nothing, st')
            Theorem _ _ :>>= _ ->
                (Nothing, stopAt st "a statement nested inside a clause")

    perform :: Replay -> CliI a -> (Maybe a, Replay)
    perform st i = case i of
        Require _ _ -> (Just (), st)
        Retire _ -> (Just (), st)
        Run{} -> answer st i
        RunByToken{} -> answer st i
        Book{} -> answer st i
        FoldUnevaluated{} -> answer st i
        Observe{} -> answer st i
        Craft{} -> answer st i
        Provoke{} -> answer st i
        Reclaim{} -> answer st i
        ReadIndexer{} -> answer st i

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
outline = map fst . described

{- | Every clause the story states, as 'outline' gives it, with the reason
its promise is retired, read from the description itself: a clause whose
body retires its promise is retired whether or not a receipt reaches it.
-}
described :: Story () -> [((String, String), Maybe String)]
described story = snd (walk 0 story)
  where
    walk :: Int -> Story a -> (Int, [((String, String), Maybe String)])
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
        -> (Int, [((String, String), Maybe String)], a)
    walkClauses name n program = case view program of
        Return a -> (n, [], a)
        Clause title leanCheck body :>>= next ->
            let (n1, obs, retired) = retiring n body
                (n2, _) = run n1 (checkAction leanCheck obs)
                (n3, rows, a) = walkClauses name n2 (next obs)
            in  (n3, ((name, title), retired) : rows, a)

    run :: Int -> Story a -> (Int, a)
    run n program = let (n', a, _) = retiring n program in (n', a)

    -- A clause body, with the reason it retires its promise, if it does.
    retiring :: Int -> Story a -> (Int, a, Maybe String)
    retiring n program = case view program of
        Return a -> (n, a, Nothing)
        Action (Retire why) :>>= next ->
            let (n', a, _) = retiring n (next ()) in (n', a, Just why)
        Action i :>>= next -> let (n', r) = placeholder n i in retiring n' (next r)
        Theorem _ _ :>>= _ -> error "outline: a statement nested inside a clause"

    placeholder :: Int -> CliI a -> (Int, a)
    placeholder n i = case i of
        Require _ _ -> (n, ())
        Retire _ -> (n, ())
        Run{} -> (n + 1, emptyReceipt n "" "" "")
        RunByToken{} -> (n + 1, emptyReceipt n "" "" "")
        Book{} -> (n + 1, emptyReceipt n "" "" "")
        FoldUnevaluated{} -> (n + 1, emptyReceipt n "" "" "")
        Observe{} -> (n + 1, emptyReceipt n "" "" "")
        Craft{} -> (n + 1, emptyReceipt n "" "" "")
        Provoke{} -> (n + 1, emptyReceipt n "" "" "")
        Reclaim{} -> (n + 1, emptyReceipt n "" "" "")
        ReadIndexer{} -> (n + 1, emptyReceipt n "" "" "")

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
        unless (s `elem` map boName (statementBindings <> obligationBindings)) $
            Left (s <> " is not a statement or obligation this domain binds")
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
        , "The last tellings are the client's own obligations, not model statements: rows of the CLI's specification (`"
            <> cliSpecification
            <> "`), each bound by the SHA-256 of its line. They cover what the commands do when another process holds the registry's lock, a saved file is changed or missing, the node is absent or stops, or a command is killed after the node accepted its transaction. Each claim is computed from the command's printed receipt and the registry's journal, both read back from the run's files."
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
               , ""
               , "### Replaced clauses"
               , ""
               , "A clause a ruling replaced is listed here with the clause that replaces it, so a verdict published under the old wording can be read against the new one."
               , ""
               ]
            <> [ "- Under `"
                    <> obligation
                    <> "`, \""
                    <> old
                    <> "\" is replaced by \""
                    <> new
                    <> "\": "
                    <> why
                    <> "."
               | (obligation, old, new, why) <- replacedClauses
               ]
  where
    verdictText s = case s of
        Held -> "holds"
        NotHeld why -> "does not hold: " <> intercalate "; " why
        Uncovered why -> "uncovered: " <> why
        Retired why -> why
    judged = results
    uncovered = length [() | ClauseResult _ _ (Uncovered _) <- judged]
    notHeld = length [() | ClauseResult _ _ (NotHeld _) <- judged]
    retired = length [() | ClauseResult _ _ (Retired _) <- judged]
    summary =
        show (length judged - uncovered - notHeld - retired)
            <> " of "
            <> show (length judged)
            <> " clauses hold; "
            <> show notHeld
            <> " do not; "
            <> show uncovered
            <> " are uncovered"
            <> (if retired > 0 then "; " <> show retired <> " are retired." else ".")
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
                [Retired why] -> why
                [NotHeld why] -> "not covered: the clause does not hold: " <> intercalate "; " why
                _ -> "uncovered: its clause did not run"
        ByObligations rows ->
            let statusOf (row, title) =
                    [ crStatus r
                    | r <- results
                    , crStatement r == row
                    , crTitle r == title
                    ]
                wanted = [(row, title) | (row, titles) <- rows, title <- titles]
            in  case concatMap statusOf wanted of
                    ss
                        | length ss /= length wanted ->
                            "uncovered: a clause of it did not run"
                        | otherwise ->
                            -- The live obligations decide the case; a retired
                            -- promise among them is named beside, never
                            -- standing for them.
                            let live = filter (not . isRetired) ss
                                retirement = [why | Retired why <- ss]
                                beside = case retirement of
                                    why : _ -> "; " <> why
                                    [] -> ""
                            in  case live of
                                    [] -> concat (take 1 retirement)
                                    _
                                        | all (== Held) live ->
                                            "covered: the clause holds" <> beside
                                        | (Uncovered why : _) <- filter (/= Held) live ->
                                            "uncovered: " <> why <> beside
                                        | (NotHeld why : _) <- filter (/= Held) live ->
                                            "not covered: a clause does not hold: "
                                                <> intercalate "; " why
                                                <> beside
                                        | otherwise ->
                                            "uncovered: a clause of it did not run" <> beside
    covered =
        length
            [ ()
            | (_, _, cov) <- approvedCases
            , "covered: the clause holds" `isPrefixOf` coverage cov
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
    | -- | A row of the CLI's specification, covered when every clause named holds
      ByObligations [(String, [String])]
    | NotLive String

qualified :: String -> String
qualified = ("OpenDatumApplication.Statements." <>)

{- | Clauses a ruling replaced: the obligation, the clause as it read, the
clause that replaces it, and why. Printed at the end of the verdict
section, so the old wording stays visible beside the new one.
-}
replacedClauses :: [(String, String, String, String)]
replacedClauses =
    [
        ( "INV299-AUTHENTICATED"
        , "inspect with the saved proof material moved aside prints no leaf"
        , "inspect with the public history it needs withheld prints no leaf and names HistoryIncomplete"
        , "inspect now reads no saved proof material; it rebuilds a root-checked trie from public history, so the witness withholds that history instead, while the obligation, that inspect never prints a leaf it cannot authenticate, is unchanged (operator ruling of 7 October 2026). Named limit: history is withheld by a test forwarder answering empty; a provider that errors instead produces a client refusal, which this witness does not cover"
        )
    ]

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
                    "the live suite runs no transaction for it: with one active token per Active key and no active mint in an update, the ledger's conservation of value keeps two carriers from forming, so the application never sees the case. Not tested live; recorded by operator ruling in `specs/299-singular-cli/ruling-duplicate-carrier.md`, which states the argument's limits; the model's and the validator's own tests of it are kept"
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
             , "client obligation `" <> row <> "`, no model statement"
             , ByObligations [(row, titles)]
             )
           | (name, row, titles) <-
                [
                    ( "a second create racing for one seed with one wallet"
                    , "R299-05"
                    ,
                        [ "the same wallet starts create on the same seed twice; the second is held before the lock while the first completes, and is refused because the registry exists"
                        ]
                    )
                ,
                    ( "a create interrupted after its first accepted submission"
                    , "INV299-PARTIAL"
                    ,
                        [ "a create killed once the node accepted its boot stopped there, its body kept"
                        , "a second create of that registry is refused before submitting"
                        , "inspect reads the incomplete create from its journal and observes its boot, printing no leaf"
                        ]
                    )
                ,
                    ( "a node lost after an accepted submission"
                    , "R299-05"
                    ,
                        [ "an update held once the node accepted it, with the node stopped, ends within its bound naming its transaction"
                        ]
                    )
                ,
                    ( "a fold killed after the node accepted it"
                    , "INV299-PARTIAL"
                    ,
                        [ "a terminate killed once the node accepted its fold stopped there, its body kept"
                        , "an update of another key then reconciles the fold from the chain and proceeds, or, while the fold is not yet on chain, is refused before submitting, naming the fold and its case"
                        , "inspect reads the key Terminal, the fold replayed at the chain root, never resubmitted and observed once across every receipt: the killed terminate's fold is accepted"
                        ]
                    )
                ,
                    ( "the Active key read from two public indexers before its termination"
                    , "INV300-INDEXER"
                    , map indexerTitle [minBound .. maxBound]
                    )
                ,
                    ( "a concurrent writer holding the target's lock"
                    , "R299-05"
                    ,
                        [ "an insert while another process holds the registry's lock is refused before submitting"
                        , "the same insert, once the lock is released, is accepted"
                        ]
                    )
                ]
           ]
        <> [
               ( "withheld public history, a changed application selector, an unavailable node"
               , "client obligations `INV299-AUTHENTICATED`, `INV299-IDENTITY`, `INV299-READONLY`, no model statement"
               , ByObligations
                    [
                        ( "INV299-AUTHENTICATED"
                        ,
                            [ "inspect with the public history it needs withheld prints no leaf and names HistoryIncomplete"
                            ]
                        )
                    ,
                        ( "INV299-IDENTITY"
                        ,
                            [ "an insert with the saved application selector changed is refused before submitting"
                            , "the same insert, with the selector restored, is accepted"
                            ]
                        )
                    ,
                        ( "INV299-READONLY"
                        , ["inspect against a node socket that does not exist prints no leaf"]
                        )
                    ]
               )
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
        Retire why -> (n, (), Just why)
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
        RunByToken (Target actor) (Target registry) c k ->
            ( n + 1
            , emptyReceipt n "" "" ""
            , Just
                ( numbered
                    n
                    ( "Run `singular registry "
                        <> commandName c
                        <> "` from **"
                        <> actor
                        <> "**, an empty directory, naming **"
                        <> registry
                        <> "** only by its state token"
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
        Provoke p (Target t) k ->
            ( n + 1
            , emptyReceipt n "" "" ""
            , Just
                ( numbered
                    n
                    (provocationPhrase p <> ", on **" <> t <> "**" <> forKey k <> ".")
                )
            )
        Reclaim (Target t) k _ _ ->
            ( n + 1
            , emptyReceipt n "" "" ""
            , Just
                ( numbered
                    n
                    ( "Retract, as its owner and inside its retract window, the request the refused insertion left pending, for **"
                        <> k
                        <> "** in **"
                        <> t
                        <> "**."
                    )
                )
            )
        ReadIndexer ix (Target t) k _ ->
            ( n + 1
            , emptyReceipt n "" "" ""
            , Just
                ( numbered
                    n
                    ( "Ask "
                        <> indexerName ix
                        <> ", read only, for the Active key's token, and compare its output, datum and chain position with the fresh inspect, for **"
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
        Retire _ -> ()
        Run{} -> emptyReceipt 0 "" "" ""
        RunByToken{} -> emptyReceipt 0 "" "" ""
        Book{} -> emptyReceipt 0 "" "" ""
        FoldUnevaluated{} -> emptyReceipt 0 "" "" ""
        Observe{} -> emptyReceipt 0 "" "" ""
        Craft{} -> emptyReceipt 0 "" "" ""
        Provoke{} -> emptyReceipt 0 "" "" ""
        Reclaim{} -> emptyReceipt 0 "" "" ""
        ReadIndexer{} -> emptyReceipt 0 "" "" ""

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

{- | Fail unless the receipt shows the expected script executed and failed —
and failed on its own terms, not because it ran out of the budget the
transaction stated for it.
-}
attributedTo :: String -> Maybe Text -> Receipt -> [String]
attributedTo what expected r =
    case expected of
        Nothing -> ["the " <> what <> " is not recorded"]
        Just _
            | overBudget `elem` rcPhaseWords r ->
                [ "a script ran out of the budget the transaction stated for it, so its failure is not a refusal"
                ]
                    <> submitted r
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
        <> [overBudget | "overspending the budget" `isInfixOf` text]
    , map T.pack (refusalScriptHashes text)
    )

-- | The word recorded when a script failed by exhausting its stated budget.
overBudget :: Text
overBudget = "OverBudget"

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
                        [ "public replay does not authenticate the key's leaf at the chain's root"
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
        Retire _ -> ()
        Run{} -> emptyReceipt 0 "" "" ""
        RunByToken{} -> emptyReceipt 0 "" "" ""
        Book{} -> emptyReceipt 0 "" "" ""
        FoldUnevaluated{} -> emptyReceipt 0 "" "" ""
        Observe{} -> emptyReceipt 0 "" "" ""
        Craft{} -> emptyReceipt 0 "" "" ""
        Provoke{} -> emptyReceipt 0 "" "" ""
        Reclaim{} -> emptyReceipt 0 "" "" ""
        ReadIndexer{} -> emptyReceipt 0 "" "" ""

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

{- | A live output an ordinary command's journal read back without
submitting it: the transaction that published it, and the step that read it.
-}
data Resolved = Resolved
    { reStep :: Text
    , reTxId :: Text
    }
    deriving stock (Eq, Show)

instance ToJSON Resolved where
    toJSON x = object ["step" .= reStep x, "txId" .= reTxId x]

instance FromJSON Resolved where
    parseJSON = withObject "resolved" $ \o ->
        Resolved <$> o .: "step" <*> o .: "txId"

{- | The lines an ordinary command's registry journal gained while it ran:
the journal, relative to the run's directory, the line counts before and
after, and the SHA-256 of those lines as they stand in the file. Admission
re-derives from them what the command submitted and what it only read back.
-}
data JournalSpan = JournalSpan
    { jsFile :: Text
    , jsBefore :: Int
    , jsAfter :: Int
    , jsSha256 :: Text
    }
    deriving stock (Eq, Show)

instance ToJSON JournalSpan where
    toJSON j =
        object
            [ "file" .= jsFile j
            , "before" .= jsBefore j
            , "after" .= jsAfter j
            , "sha256" .= jsSha256 j
            ]

instance FromJSON JournalSpan where
    parseJSON = withObject "journal" $ \o ->
        JournalSpan
            <$> o .: "file"
            <*> o .: "before"
            <*> o .: "after"
            <*> o .: "sha256"

{- | What a provoked command's process left, as the backend recorded it.
Admission reads each part back from the run's files — the registry's
journal, the saved files, the printed receipts — and a recorded part that
differs from them is a problem, never a fact.
-}
data ProcessEvidence = ProcessEvidence
    { peJournal :: Text
    -- ^ The registry's journal, relative to the run's directory
    , peJournalBefore :: Int
    -- ^ Its lines before the command started
    , peJournalAfter :: Int
    -- ^ Its lines once the command had stopped
    , peLastEvent :: Text
    -- ^ @step/event@ of the journal's last line once the command had stopped
    , peSubmitted :: [Text]
    -- ^ The transactions the journal says the command submitted
    , peExit :: Int
    -- ^ The exit status; the negated signal for a process killed by one
    , peWaited :: Maybe Int
    -- ^ Seconds from the command's release to its exit
    , peFilesBefore :: [(Text, Text)]
    -- ^ Saved files of a registry the command must not touch, and digests, before
    , peFilesAfter :: [(Text, Text)]
    -- ^ The same, once the command had stopped
    , peSeedProbe :: Maybe Text
    {- ^ The printed receipt of a preview naming the command's seed, run
    once the command had stopped: it succeeds only while the seed is unspent
    -}
    }
    deriving stock (Eq, Show)

instance ToJSON ProcessEvidence where
    toJSON p =
        object
            [ "journal" .= peJournal p
            , "journalBefore" .= peJournalBefore p
            , "journalAfter" .= peJournalAfter p
            , "lastEvent" .= peLastEvent p
            , "submitted" .= peSubmitted p
            , "exit" .= peExit p
            , "waitedSeconds" .= peWaited p
            , "filesBefore" .= peFilesBefore p
            , "filesAfter" .= peFilesAfter p
            , "seedProbe" .= peSeedProbe p
            ]

instance FromJSON ProcessEvidence where
    parseJSON = withObject "process" $ \o ->
        ProcessEvidence
            <$> o .: "journal"
            <*> o .: "journalBefore"
            <*> o .: "journalAfter"
            <*> o .: "lastEvent"
            <*> o .: "submitted"
            <*> o .: "exit"
            <*> o .:? "waitedSeconds"
            <*> o .: "filesBefore"
            <*> o .: "filesAfter"
            <*> o .:? "seedProbe"

-- | Saved files by name and digest, wherever they were read.
byName :: [(Text, Text)] -> [(Text, Text)]
byName = map (Bifunctor.first (T.takeWhileEnd (/= '/')))
