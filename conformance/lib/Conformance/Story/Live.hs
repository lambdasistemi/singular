{-# LANGUAGE GADTs #-}

{- | Programs over the nine exits of the model: seven folds, a reject and a
retract, and over the model's two batch questions: several requests folded in one
transaction, and several rejected in one. Handles remain opaque to stories.
-}
module Conformance.Story.Live
    ( Edge (..)
    , edgeName
    , Exit (..)
    , exitName
    , EdgeRequest (..)
    , Tamper (..)
    , tamperName
    , BatchTamper (..)
    , batchTamperName
    , RefundTamper (..)
    , refundTamperName
    , refundShortfall
    , Booking (..)
    , Placement (..)
    , placementName
    , placementReading
    , placementWindow
    , LiveI (..)
    , Story
    , Context (..)
    , submit
    , tamper
    , rejectWithin
    , tamperRejectWithin
    , retract
    , tamperExit
    , foldBatch
    , tamperFoldBatch
    , rejectBatchWithin
    , rejectBookedBatchWithin
    , tamperRejectBookedBatchWithin
    , observe
    , compareWithModel
    , renderLive
    , validateLive
    , Instruction (..)
    , InstructionKind (..)
    , liveInstructions
    ) where

import Conformance.Story.Binding (Binding, BoundObligation (..))
import Conformance.Story.Specification
    ( Clause (..)
    , Step (..)
    , TheoremStory
    , action
    , checkAction
    , clauses
    , theoremBinding
    )
import Conformance.Story.Specification qualified as Specification
import Control.Monad.Operational
    ( Program
    , ProgramViewT (Return, (:>>=))
    , view
    )
import Data.List (intercalate)

data Edge
    = InsertAbsent
    | InsertActive
    | UpdateActive
    | UpdateTerminal
    | DeleteAbsent
    | DeleteActive
    | WitnessTerminal
    deriving stock (Eq, Ord, Show, Enum, Bounded)

edgeName :: Edge -> String
edgeName edge = case edge of
    InsertAbsent -> "insertAbsent"
    InsertActive -> "insertActive"
    UpdateActive -> "updateActive"
    UpdateTerminal -> "updateTerminal"
    DeleteAbsent -> "deleteAbsent"
    DeleteActive -> "deleteActive"
    WitnessTerminal -> "witnessTerminal"

{- | How a request leaves the queue: folded by its own edge, rejected by a folder
in a window its story names, or retracted by its owner.
-}
data Exit = Fold | Reject | Retract
    deriving stock (Eq, Show, Enum, Bounded)

-- | An exit's operation name: a fold is named by the edge it folds.
exitName :: Exit -> Edge -> String
exitName Fold edge = edgeName edge
exitName Reject _ = "reject"
exitName Retract _ = "retract"

data EdgeRequest wal = EdgeRequest
    { requestEdge :: Edge
    , requestKey :: String
    , requestWallet :: wal
    }
    deriving stock (Eq, Show)

{- | A change to the submitted transaction the model's request does not make.
'OtherAddress' sends the payment the exit owes to another address, and
'ShortByOne' pays it one lovelace short; the ledger must refuse both, and the
model must refuse them for the reason it gives. 'ExtraSigner' adds one
required signer the model does not require; the ledger accepts it, and the
comparison must report the transaction's signers.
'Unsigned' removes the owner's required signature from a retraction; its
admission witness tells the model which signatures that transaction requires.
-}
data Tamper
    = OtherAddress
    | ShortByOne
    | ExtraSigner
    | OtherReference
    | StateSpent
    | Unsigned
    | BeforePhase2
    | AfterPhase2
    deriving stock (Eq, Show, Enum, Bounded)

tamperName :: Tamper -> String
tamperName OtherAddress = "other-address"
tamperName ShortByOne = "short-by-one"
tamperName ExtraSigner = "extra-signer"
tamperName OtherReference = "other-reference"
tamperName StateSpent = "state-spent"
tamperName Unsigned = "unsigned"
tamperName BeforePhase2 = "before-phase-2"
tamperName AfterPhase2 = "after-phase-2"

{- | A change to the transaction of a fold batch. 'MintOnFirstKey' mints every
token the batch delivers at the key of its first request, the deliveries
carrying it: the same quantity of each kind, at the wrong keys.
-}
data BatchTamper = MintOnFirstKey
    deriving stock (Eq, Show, Enum, Bounded)

batchTamperName :: BatchTamper -> String
batchTamperName MintOnFirstKey = "mint-on-first-key"

-- | The batch tamper as the book reads it.
batchTamperReading :: BatchTamper -> String
batchTamperReading MintOnFirstKey =
    "every token the transaction mints moved onto the first request's key"

{- | A change to the refunds of a reject batch, in the transaction's input
order. 'CrossedRefunds' pays each request's owner, at its refund's position,
what the next request's owner is owed. 'ShortFirstRefund' pays the first
request's owner the given lovelace short, the rest going to the transaction's
change. 'SplitFirstRefund' pays it short at its refund's position too, with two
ada more in another output at the same owner's key.
-}
data RefundTamper
    = CrossedRefunds
    | ShortFirstRefund Integer
    | SplitFirstRefund Integer
    deriving stock (Eq, Show)

refundTamperName :: RefundTamper -> String
refundTamperName CrossedRefunds = "crossed-refunds"
refundTamperName (ShortFirstRefund _) = "short-first-refund"
refundTamperName (SplitFirstRefund _) = "split-first-refund"

-- | The lovelace a refund tamper takes from the first refund, if any.
refundShortfall :: RefundTamper -> Maybe Integer
refundShortfall CrossedRefunds = Nothing
refundShortfall (ShortFirstRefund lovelace) = Just lovelace
refundShortfall (SplitFirstRefund lovelace) = Just lovelace

-- | The refund tamper as the book reads it.
refundTamperReading :: RefundTamper -> String
refundTamperReading CrossedRefunds =
    "each owner refunded, in its refund's position, what the next request's owner is owed"
refundTamperReading (ShortFirstRefund lovelace) =
    "the first request's refund " <> show lovelace <> " lovelace short"
refundTamperReading (SplitFirstRefund lovelace) =
    "the first request's refund "
        <> show lovelace
        <> " lovelace short in its own position and two ada more in another output at the same owner's key"

{- | Who books a request and what it holds beyond the processing tip. A request
without a booking is booked by the runner's own wallet with the default
deposit.
-}
data Booking wal = Booking
    { bookingOwner :: wal
    , bookingDeposit :: Integer
    }
    deriving stock (Eq, Show)

{- | Where a reject is placed: a fact about the submitted transaction, not a
tamper. The model gives a reject no admission, so its answer does not depend
on it; the chain is asked in the window the story names.
-}
data Placement = InProcessingWindow | InRetractionWindow | AfterTheWindows
    deriving stock (Eq, Show, Enum, Bounded)

-- | The placement as the run log names it.
placementName :: Placement -> String
placementName InProcessingWindow = "in the processing window"
placementName InRetractionWindow = "in the owner's retraction window"
placementName AfterTheWindows = "after the windows"

-- | The placement as the book reads it.
placementReading :: Placement -> String
placementReading InProcessingWindow = "while the request can still be folded"
placementReading InRetractionWindow = "while its owner can still retract it"
placementReading AfterTheWindows = "after its owner's retraction window has closed"

{- | The window a placement names, in POSIX milliseconds, for a request
submitted at @submittedAt@ under a registry's processing and retraction
times: from its start to its excluded end, open-ended after the windows.
-}
placementWindow
    :: Placement -> Integer -> Integer -> Integer -> (Integer, Maybe Integer)
placementWindow placement submittedAt processTime retractTime =
    case placement of
        InProcessingWindow -> (submittedAt, Just processDeadline)
        InRetractionWindow -> (processDeadline, Just retractDeadline)
        AfterTheWindows -> (retractDeadline, Nothing)
  where
    processDeadline = submittedAt + processTime
    retractDeadline = processDeadline + retractTime

type Story reg wal step obs cmp =
    Specification.Story (LiveI reg wal step obs cmp)

data Context reg wal = Context reg wal

data LiveI reg wal step obs cmp result where
    Submit
        :: Exit -> reg -> EdgeRequest wal -> LiveI reg wal step obs cmp step
    Tamper
        :: Tamper
        -> Exit
        -> reg
        -> EdgeRequest wal
        -> LiveI reg wal step obs cmp step
    RejectWithin
        :: Placement
        -> Maybe Tamper
        -> reg
        -> EdgeRequest wal
        -> LiveI reg wal step obs cmp step
    Observe :: step -> LiveI reg wal step obs cmp obs
    Compare :: step -> obs -> LiveI reg wal step obs cmp cmp
    FoldBatch
        :: Maybe BatchTamper
        -> reg
        -> [EdgeRequest wal]
        -> LiveI reg wal step obs cmp cmp
    RejectBatchWithin
        :: Placement
        -> Maybe RefundTamper
        -> reg
        -> [(EdgeRequest wal, Maybe (Booking wal))]
        -> LiveI reg wal step obs cmp cmp

submit :: reg -> EdgeRequest wal -> Story reg wal step obs cmp step
submit registry request = action (Submit Fold registry request)

tamper
    :: Tamper -> reg -> EdgeRequest wal -> Story reg wal step obs cmp step
tamper alteration = tamperExit alteration Fold

-- | A folder rejects the request in the window the placement names.
rejectWithin
    :: Placement -> reg -> EdgeRequest wal -> Story reg wal step obs cmp step
rejectWithin placement registry request =
    action (RejectWithin placement Nothing registry request)

-- | A folder rejects the request in that window, through a tampered transaction.
tamperRejectWithin
    :: Tamper
    -> Placement
    -> reg
    -> EdgeRequest wal
    -> Story reg wal step obs cmp step
tamperRejectWithin alteration placement registry request =
    action (RejectWithin placement (Just alteration) registry request)

-- | The request's owner retracts it.
retract :: reg -> EdgeRequest wal -> Story reg wal step obs cmp step
retract registry request = action (Submit Retract registry request)

-- | The request leaves by this exit through a transaction changed by the tamper.
tamperExit
    :: Tamper
    -> Exit
    -> reg
    -> EdgeRequest wal
    -> Story reg wal step obs cmp step
tamperExit alteration exit registry request = action (Tamper alteration exit registry request)

{- | Fold these requests in one transaction, each on its own edge, and ask the
model the same batch: its @foldBatch@ question. The batch is submitted and asked
as one instruction; its answer is what the model and the chain each said.
-}
foldBatch
    :: reg -> [EdgeRequest wal] -> Story reg wal step obs cmp cmp
foldBatch registry requests = action (FoldBatch Nothing registry requests)

{- | Fold these requests in one transaction changed by the batch tamper, and ask
the model the same batch, each request claiming what that transaction mints at
its key.
-}
tamperFoldBatch
    :: BatchTamper
    -> reg
    -> [EdgeRequest wal]
    -> Story reg wal step obs cmp cmp
tamperFoldBatch alteration registry requests =
    action (FoldBatch (Just alteration) registry requests)

{- | A folder rejects these requests in one transaction, in the window the
placement names, and the model is asked the same batch: its @rejectBatch@
question.
-}
rejectBatchWithin
    :: Placement
    -> reg
    -> [EdgeRequest wal]
    -> Story reg wal step obs cmp cmp
rejectBatchWithin placement registry requests =
    action
        ( RejectBatchWithin
            placement
            Nothing
            registry
            [(r, Nothing) | r <- requests]
        )

{- | A folder rejects these requests in one transaction, in the window the
placement names, each booked by the owner and with the deposit its booking
names, and the model is asked the same batch.
-}
rejectBookedBatchWithin
    :: Placement
    -> reg
    -> [(EdgeRequest wal, Booking wal)]
    -> Story reg wal step obs cmp cmp
rejectBookedBatchWithin placement registry requests =
    action
        ( RejectBatchWithin
            placement
            Nothing
            registry
            [(r, Just booking) | (r, booking) <- requests]
        )

{- | A folder rejects these booked requests in one transaction changed by the
refund tamper, and the model is asked the same batch, judged on the refunds
that transaction pays.
-}
tamperRejectBookedBatchWithin
    :: RefundTamper
    -> Placement
    -> reg
    -> [(EdgeRequest wal, Booking wal)]
    -> Story reg wal step obs cmp cmp
tamperRejectBookedBatchWithin alteration placement registry requests =
    action
        ( RejectBatchWithin
            placement
            (Just alteration)
            registry
            [(r, Just booking) | (r, booking) <- requests]
        )

observe :: step -> Story reg wal step obs cmp obs
observe = action . Observe

compareWithModel :: step -> obs -> Story reg wal step obs cmp cmp
compareWithModel step observation = action (Compare step observation)

{- | Check instruction order over the same program with display-only handles,
before a runner can submit a transaction.
-}
validateLive
    :: Story String String String String String res -> Either String ()
validateLive program = do
    (end, _) <- walk Ready program
    if end == Ready
        then Right ()
        else Left "live story ended before Observe and Compare"
  where
    walk
        :: PreflightPhase
        -> Story String String String String String a
        -> Either String (PreflightPhase, a)
    walk phase body = case view body of
        Return result -> Right (phase, result)
        Action instruction :>>= rest -> case instruction of
            Submit Reject _ _ -> Left unplaced
            Submit{} -> advance Ready NeedObserve "preflight step"
            Tamper _ Reject _ _ -> Left unplaced
            Tamper{} -> advance Ready NeedObserve "preflight step"
            RejectWithin{} -> advance Ready NeedObserve "preflight step"
            Observe _ -> advance NeedObserve NeedCompare "preflight observation"
            Compare _ _ -> advance NeedCompare Ready "preflight comparison"
            FoldBatch{} -> batch "preflight batch"
            RejectBatchWithin _ alteration _ requests ->
                case refundProblem alteration requests of
                    Just problem -> Left problem
                    Nothing -> batch "preflight batch"
          where
            advance expected nextPhase value
                | phase == expected = walk nextPhase (rest value)
                | otherwise =
                    Left "live story must Submit or Tamper, Observe, then Compare"
            unplaced =
                "a live story's reject must name the window it is placed in"
            -- A batch is submitted and asked as one instruction, so it stands
            -- between complete steps, never inside one.
            batch value
                | phase == Ready = walk Ready (rest value)
                | otherwise =
                    Left
                        "a live story's batch stands between complete steps, not inside one"
        Theorem _ body' :>>= rest -> do
            (afterClauses, result) <-
                walkClauses phase (Specification.clauses body')
            walk afterClauses (rest result)
    walkClauses
        :: PreflightPhase
        -> Program (Clause thm (LiveI String String String String String)) a
        -> Either String (PreflightPhase, a)
    walkClauses phase body = case view body of
        Return result -> Right (phase, result)
        Clause _ check actions :>>= rest -> do
            (afterActions, observation) <- walk phase actions
            (afterCheck, ()) <-
                walk afterActions (Specification.checkAction check observation)
            walkClauses afterCheck (rest observation)

data PreflightPhase = Ready | NeedObserve | NeedCompare
    deriving stock (Eq)

{- | Why a reject batch's bookings or refund tamper cannot be built, if they
cannot: a deposit must be positive, a shortfall positive, a crossed allocation
needs two requests to cross, and a tampered first refund needs a first request.
-}
refundProblem
    :: Maybe RefundTamper
    -> [(EdgeRequest wal, Maybe (Booking wal))]
    -> Maybe String
refundProblem alteration requests
    | any ((<= 0) . bookingDeposit) [b | (_, Just b) <- requests] =
        Just "a booked request's deposit must be positive"
    | otherwise = case alteration of
        Nothing -> Nothing
        Just CrossedRefunds
            | length requests < 2 ->
                Just "crossed refunds need two requests to cross"
        Just changed
            | Just lovelace <- refundShortfall changed
            , lovelace <= 0 ->
                Just "a refund's shortfall must be positive"
            | null requests -> Just "a tampered refund needs a request to refund"
        _ -> Nothing

renderLive :: Story String String String String String res -> String
renderLive = fst . renderWithResult

renderWithResult
    :: Story String String String String String res -> (String, res)
renderWithResult program = case view program of
    Return result -> ("", result)
    Action instruction :>>= rest -> renderAction instruction rest
    Theorem binding body :>>= rest ->
        let (text, result) = renderClauses body
        in  prepend
                (formal (theoremBinding binding) <> text)
                (renderWithResult (rest result))

renderClauses
    :: TheoremStory thm (LiveI String String String String String) res
    -> (String, res)
renderClauses = renderClauseProgram . clauses

renderClauseProgram
    :: Program (Clause thm (LiveI String String String String String)) res
    -> (String, res)
renderClauseProgram program = case view program of
    Return result -> ("", result)
    Clause title check body :>>= rest ->
        let (text, result) = renderWithResult body
            (checked, ()) = renderWithResult (checkAction check result)
        in  prepend
                ("### " <> title <> "\n\n" <> text <> checked)
                (renderClauseProgram (rest result))

renderAction
    :: LiveI String String String String String obs
    -> (obs -> Story String String String String String res)
    -> (String, res)
renderAction instruction rest = case instruction of
    Submit exit registry request ->
        step
            ( subject exit registry request
                <> ", using the "
                <> requestWallet request
                <> "."
            )
            (rest (requestKey request))
    Tamper alteration exit registry request ->
        step
            (subject exit registry request <> altered alteration)
            (rest (requestKey request))
    RejectWithin placement alteration registry request ->
        step
            ( "Reject the "
                <> named request registry
                <> " "
                <> placementReading placement
                <> maybe
                    (", using the " <> requestWallet request <> ".")
                    altered
                    alteration
            )
            (rest (requestKey request))
    Observe handle ->
        step
            ( "Observe the complete registry, token, leaf and transaction boundary after **"
                <> handle
                <> "**."
            )
            (rest ("observations for " <> handle))
    Compare handle _ ->
        step
            ( "Compare **"
                <> handle
                <> "** and its observation with the executable registry model."
            )
            (rest ("comparison for " <> handle))
    FoldBatch alteration registry requests ->
        step
            ( "Fold, in one transaction"
                <> maybe
                    ""
                    (\changed -> " with " <> batchTamperReading changed)
                    alteration
                <> ", "
                <> batched requests registry
                <> ", and ask the executable registry model the same batch."
            )
            (rest ("batch in " <> registry))
    RejectBatchWithin placement alteration registry requests ->
        step
            ( "Reject, in one transaction "
                <> placementReading placement
                <> maybe
                    ""
                    (\changed -> " with " <> refundTamperReading changed)
                    alteration
                <> ", "
                <> batched (map fst requests) registry
                <> booked requests
                <> ", and ask the executable registry model the same batch."
            )
            (rest ("batch in " <> registry))
  where
    step sentence next = prepend ("- " <> sentence <> "\n\n") (renderWithResult next)
    named request registry =
        "**"
            <> edgeName (requestEdge request)
            <> "** for **"
            <> requestKey request
            <> "** in **"
            <> registry
            <> "**"
    -- Every request of a batch is named, in order; an empty batch says so.
    batched [] registry = "no request in **" <> registry <> "**"
    batched requests registry =
        intercalate
            ", "
            [ "**"
                <> edgeName (requestEdge request)
                <> "** for **"
                <> requestKey request
                <> "**"
            | request <- requests
            ]
            <> " in **"
            <> registry
            <> "**, using "
            <> intercalate ", " (map (("the " <>) . requestWallet) requests)
    -- Who booked each request and what it holds, when the story names it.
    booked requests = case [ "**"
                                <> requestKey request
                                <> "** by the "
                                <> bookingOwner booking
                                <> " with a deposit of "
                                <> show (bookingDeposit booking)
                                <> " lovelace"
                           | (request, Just booking) <- requests
                           ] of
        [] -> ""
        bookings -> ", booked " <> intercalate ", " bookings
    subject Fold registry request = "Submit " <> named request registry
    subject Reject registry request =
        "Reject the "
            <> named request registry
            <> " with no placement, which story validation refuses"
    subject Retract registry request = "Retract the " <> named request registry <> " as its owner"
    refused =
        " The ledger and the model must both refuse it; the same request untampered is its control."
    altered OtherAddress = " with the payment it owes sent to another address." <> refused
    altered ShortByOne = " with the payment it owes one lovelace short." <> refused
    altered OtherReference =
        " with its return bound to another request's output reference."
            <> refused
    altered StateSpent = " spending the registry's state beside it." <> refused
    altered Unsigned =
        " without requiring its owner's signature; the ledger and the model must refuse it, with the owner-signed retraction of that request as its control."
    altered BeforePhase2 =
        " with a finite validity interval before phase 2; the ledger and the model must refuse it, with the same request retracted inside phase 2 as its control."
    altered AfterPhase2 =
        " with a finite validity interval after phase 2; the ledger and the model must refuse it, with the earlier in-window retraction of its owner's other request as its control."
    altered ExtraSigner =
        " with one required signer the model does not require. The ledger accepts it; the comparison must report the difference in the transaction's signers."

-- | What one instruction of a program is.
data InstructionKind
    = StepInstruction
    | ObserveInstruction
    | CompareInstruction
    | BatchInstruction
    deriving stock (Eq, Show)

-- | One instruction of a program, with the tamper it carries, if any.
data Instruction = Instruction
    { instructionKind :: InstructionKind
    , instructionTamper :: Maybe String
    -- ^ the name of the tamper, batch tamper or refund tamper
    }
    deriving stock (Eq, Show)

{- | Every instruction of a program over display handles, in order, theorem
clauses included. The walk feeds each instruction the result the book's
renderer feeds it, so it meets the instructions the book prints.
-}
liveInstructions
    :: Story String String String String String res -> [Instruction]
liveInstructions = fst . instructionsWithResult

instructionsWithResult
    :: Story String String String String String res -> ([Instruction], res)
instructionsWithResult program = case view program of
    Return result -> ([], result)
    Action instruction :>>= rest -> case instruction of
        Submit _ _ request ->
            one StepInstruction Nothing (rest (requestKey request))
        Tamper alteration _ _ request ->
            one
                StepInstruction
                (Just (tamperName alteration))
                (rest (requestKey request))
        RejectWithin _ alteration _ request ->
            one
                StepInstruction
                (tamperName <$> alteration)
                (rest (requestKey request))
        Observe handle ->
            one ObserveInstruction Nothing (rest ("observations for " <> handle))
        Compare handle _ ->
            one CompareInstruction Nothing (rest ("comparison for " <> handle))
        FoldBatch alteration registry _ ->
            one
                BatchInstruction
                (batchTamperName <$> alteration)
                (rest ("batch in " <> registry))
        RejectBatchWithin _ alteration registry _ ->
            one
                BatchInstruction
                (refundTamperName <$> alteration)
                (rest ("batch in " <> registry))
    Theorem _ body :>>= rest ->
        let (inner, result) = clauseInstructions (clauses body)
            (after, final) = instructionsWithResult (rest result)
        in  (inner <> after, final)
  where
    one kind alteration next =
        let (after, result) = instructionsWithResult next
        in  (Instruction kind alteration : after, result)

clauseInstructions
    :: Program (Clause thm (LiveI String String String String String)) res
    -> ([Instruction], res)
clauseInstructions program = case view program of
    Return result -> ([], result)
    Clause _ check body :>>= rest ->
        let (inBody, result) = instructionsWithResult body
            (inCheck, ()) = instructionsWithResult (checkAction check result)
            (after, final) = clauseInstructions (rest result)
        in  (inBody <> inCheck <> after, final)

prepend :: String -> (String, res) -> (String, res)
prepend prefix (text, result) = (prefix <> text, result)

formal :: Binding -> String
formal binding =
    "Formal specification: `"
        <> boName binding
        <> "` @ `"
        <> boRevision binding
        <> "`. Statement digest: `"
        <> boDigest binding
        <> "`.\n\n"
