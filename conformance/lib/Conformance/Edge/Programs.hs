{- |
Module      : Conformance.Edge.Programs
Description : Every registry row as a program over the registry's operations
License     : Apache-2.0

The registry rows of the inventory, each either a program over the story
language's instructions — an edge composition, or a tamper of an edge's
transaction — or named outside the model's vocabulary with its reason. A
program says which registries it boots and which wallets it names, the requests
it books before its first instruction, what each compared record must show and
how its outcome stands against the consuming project's requirement. The live
runner executes it through the generic interpreter and the book renders the
same program; neither holds a second description of a row.
-}
module Conformance.Edge.Programs
    ( Program (..)
    , Registry (..)
    , Wallet (..)
    , WalletRole (..)
    , Expected (..)
    , Standing (..)
    , Chapter (..)
    , Kind (..)
    , Classification (..)
    , programs
    , programFor
    , outsideVocabulary
    , classify
    , classifyGroup
    , kindOf
    , recordsOf
    , displayStory
    , displayCohort
    ) where

import Conformance.Edge.EarlyReject qualified as EarlyReject
import Conformance.Edge.Exit qualified as Exit
import Conformance.Edge.Occupied qualified as Occupied
import Conformance.Edge.Register qualified as Register
import Conformance.Edge.Retire qualified as Retire
import Conformance.Edge.RetractionWindow qualified as RetractionWindow
import Conformance.Edge.Sequence qualified as Sequence
import Conformance.Story.Live
    ( Booking (..)
    , Context (..)
    , Edge (..)
    , EdgeRequest (..)
    , Instruction (..)
    , InstructionKind (..)
    , Placement (..)
    , RefundTamper (..)
    , Story
    , compareWithModel
    , foldBatch
    , liveInstructions
    , observe
    , rejectBookedBatchWithin
    , rejectWithin
    , retract
    , submit
    , tamperRejectBookedBatchWithin
    )
import Control.Monad ((>=>))
import Data.List (nub)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T

-- | A registry a program acts on, booted fresh for its row.
data Registry = Registry
    { registryName :: String
    -- ^ the name the run boots it under
    , registryReading :: String
    -- ^ the name the book reads
    , registryProcessingMs :: Integer
    , registryRetractionMs :: Integer
    }
    deriving stock (Eq, Show)

-- | Which wallet of the run a program's wallet is.
data WalletRole
    = -- | the wallet the run signs and funds every fold with
      RunnerWallet
    | -- | a second wallet the run funds once
      SecondWallet
    | {- | a wallet that books requests and receives no fold's change, funded
      with this lovelace when the row starts
      -}
      OwnerWallet Integer
    deriving stock (Eq, Show)

-- | A wallet a program names, beside the name the book reads.
data Wallet = Wallet
    { walletRole :: WalletRole
    , walletReading :: String
    }
    deriving stock (Eq, Show)

-- | What one compared record of a program must show.
data Expected
    = -- | the chain and the model reach the same outcome, for the same reason
      Agrees
    | {- | a recorded disagreement, never a pass: the chain's and the model's
      outcomes, the reason the traced replay admits for the chain, and the
      issue that tracks it
      -}
      Diverges
        { divergenceChain :: Text
        , divergenceModel :: Text
        , divergenceTrace :: Text
        , divergenceIssue :: Text
        }
    deriving stock (Eq, Show)

-- | How a program row stands against the consuming project's requirement.
data Standing
    = -- | the row's outcome is what the requirement asks
      Agreement
    | -- | the consuming project's theorem and the model disagree; held
      Held
        { heldFor :: String
        , heldLean :: String
        , heldConsumer :: String
        }
    | -- | the requirement is kept unmet by a ruling
      Unmet
        { unmetRuling :: String
        , unmetRegistry :: String
        , unmetConsumer :: String
        }
    deriving stock (Eq, Show)

-- | A program the book renders as a chapter of its own.
data Chapter = Chapter
    { chapterTitle :: String
    , chapterIntroduction :: String
    , chapterSummary :: String
    -- ^ how the run's results open, before the counts
    }
    deriving stock (Eq, Show)

-- | One row's program.
data Program = Program
    { programRow :: String
    , programRegistries :: [Registry]
    , programWallets :: [Wallet]
    , programCohort
        :: forall reg wal
         . [reg]
        -> [wal]
        -> Either String [(reg, EdgeRequest wal)]
    {- ^ requests booked before the first instruction, each in its registry;
    a story that needs no request pending before it starts books none
    -}
    , programStory
        :: forall reg wal step obs cmp
         . [reg]
        -> [wal]
        -> Either String (Story reg wal step obs cmp ())
    , programExpected :: [Expected]
    -- ^ one per compared record, in order
    , programStanding :: Standing
    , programControls :: [String]
    -- ^ the story controls the row admits
    , programChapter :: Maybe Chapter
    }

-- | Whether a program composes edges or tampers with an edge's transaction.
data Kind = EdgeComposition | Tamper
    deriving stock (Eq, Show)

-- | How a registry row is run.
data Classification
    = -- | a program of this kind
      Composed Kind
    | -- | outside the model's vocabulary, for this reason
      Outside Text
    deriving stock (Eq, Show)

-- | Every program, the book's chapters first, in book order.
programs :: [Program]
programs =
    [ registration
    , occupied
    , retirement
    , exits
    , earlyRejection
    , retractionWindow
    , sequenceProgram
    , insertion
    , phase2Retraction
    , lateRejection
    , processingRejection
    , emptyFold
    , refundRouting
    ]

-- | The program of a row, if it has one.
programFor :: String -> Maybe Program
programFor row = case [p | p <- programs, programRow p == row] of
    [p] -> Just p
    _ -> Nothing

{- | The registry rows the model cannot express, each with its reason. A row
here has no program; the ones a run still executes for their chain evidence
do so through their own runner.
-}
outsideVocabulary :: [(Text, Text)]
outsideVocabulary =
    [
        ( "update-existing-key"
        , "The original broader update requirement remains uncovered. Its insertAbsent/updateActive success setup is excluded by the current two-edge law. No excluded-edge refusal certifies that requirement."
        )
    ,
        ( "delete-existing-key"
        , "The original deletion requirement remains uncovered: the current two-edge law refuses deletion and cannot return a key to absence."
        )
    ,
        ( "reinsert-deleted-key"
        , "The original reincarnation requirement remains uncovered: the current two-edge law cannot reach its successful deletion prefix."
        )
    ,
        ( "retire-active-key"
        , "The original retirement requirement remains uncovered because it also requires an Absent starting key. A separate current retirement story certifies Active to Terminal and excluded encodings, without claiming that unreachable prefix or the former deletion-refund chapter."
        )
    ,
        ( "fold-against-superseded-root"
        , "a fold whose proof was built against a root the registry has since superseded. The model takes no proof and no authenticated root, so it has no reason to compare with the chain's refusal (lambdasistemi/singular#346). The conformance session runs the refusal and its accepting control on the devnet; the model comparison stays unmet by ruling."
        )
    ,
        ( "surplus-fold-actions"
        , "a fold carrying an action beyond its requests, and one missing an action. The model takes requests, not an action list, so it has no reason to compare with the chain's refusals (lambdasistemi/singular#345). The conformance session runs both refusals and an accepting control on the devnet; the model comparison stays unmet by ruling."
        )
    ,
        ( "historical-owner-change"
        , "a fold that changes the registry's owner. The registry has no owner role (the ownerless-registry ruling of 2026-09-12, commit f3a68b1b) and the model has none either; the earlier observation is history and the claim is withdrawn."
        )
    ,
        ( "retired-stake-hook-with-withdrawal"
        , "a fold carrying a withdrawal under a stake_script hook. The registry interface has no stake_script hook (registry mode, no hook) and the model has no withdrawal; the row is retired and nothing runs it."
        )
    ,
        ( "retired-stake-hook-without-withdrawal"
        , "the same fold with its withdrawal absent. The registry interface has no stake_script hook (registry mode, no hook) and the model has no withdrawal; the row is retired and nothing runs it."
        )
    ,
        ( "historical-owner-signed-sweep"
        , "an owner-signed sweep of an output that is not a request. The registry has no owner role and no sweep: its scripts refuse a sweep for every party (the ownerless-registry ruling of 2026-09-12, commit f3a68b1b), and the model has no sweep. The earlier observation is history and the claim is withdrawn; no run sweeps a registry."
        )
    ,
        ( "historical-non-owner-sweep"
        , "a sweep by someone other than the owner. The registry has no owner role and no sweep (the ownerless-registry ruling of 2026-09-12, commit f3a68b1b), and the model has no sweep; the earlier observation is history and the claim is withdrawn."
        )
    ,
        ( "historical-registry-termination"
        , "ending the registry by burning its state token. The registry has no termination: its state script refuses End for every party (the ownerless-registry ruling of 2026-09-12, commit f3a68b1b), and the model has no termination exit. The claim that End is accepted is withdrawn; no run ends a registry."
        )
    ,
        ( "historical-permissionless-fold"
        , "a fold whose owner's required signer is removed. The registry has no owner role, so there is no owner signer to remove; that no fold requires a signer is compared on every fold the programs run, through the transaction's required signers."
        )
    ]

-- | A program's kind, read off its instructions.
kindOf :: Program -> Either String Kind
kindOf p = do
    story <- displayStory p
    pure $
        if any (isJust . instructionTamper) (liveInstructions story)
            then Tamper
            else EdgeComposition

-- | How many records a program compares: one per compared request, one per batch.
recordsOf :: Program -> Either String Int
recordsOf p = do
    story <- displayStory p
    pure
        ( length
            [ ()
            | Instruction kind _ <- liveInstructions story
            , kind `elem` [CompareInstruction, BatchInstruction]
            ]
        )

-- | How one registry row is run.
classify :: Text -> Either String Classification
classify row = case (programFor (T.unpack row), lookup row outsideVocabulary) of
    (Just p, Nothing) -> Composed <$> kindOf p
    (Nothing, Just reason) -> Right (Outside reason)
    (Just _, Just _) ->
        Left (T.unpack row <> " is both a program and outside the vocabulary")
    (Nothing, Nothing) -> Left (T.unpack row <> " is not classified")

{- | Every row of the registry group classified exactly once. An empty group,
or a program or reason for a row the group does not hold, is refused.
-}
classifyGroup :: [Text] -> Either String [(Text, Classification)]
classifyGroup group
    | null group = Left "there is no registry row to classify"
    | length (nub group) /= length group =
        Left "a registry row is listed twice"
    | not (null strays) =
        Left
            ( "classified rows the inventory does not hold: "
                <> unwords (map T.unpack strays)
            )
    | otherwise = traverse (\row -> (,) row <$> classify row) group
  where
    strays =
        [ row
        | row <-
            [T.pack (programRow p) | p <- programs, programRow p /= "sequence"]
                <> map fst outsideVocabulary
        , row `notElem` group
        ]

-- | A program's story over the display names the book reads.
displayStory
    :: Program -> Either String (Story String String String String String ())
displayStory p =
    programStory
        p
        (map registryReading (programRegistries p))
        (map walletReading (programWallets p))

-- | A program's cohort over the display names the book reads.
displayCohort
    :: Program -> Either String [(String, EdgeRequest String)]
displayCohort p =
    programCohort
        p
        (map registryReading (programRegistries p))
        (map walletReading (programWallets p))

-- ---------------------------------------------------------
-- The programs
-- ---------------------------------------------------------

{- | The story controls every program admits: the model's answer altered, or an
observation the chain gives perturbed, each of which must fail the row.
-}
generalControls :: [String]
generalControls = ["wrong-fee", "wrong-timing", "wrong-delivery", "unknown-identity"]

-- | Every story control the interpreter knows.
allControls :: [String]
allControls = generalControls <> ["inside-phase-2", "signed-owner"]

-- | A registry with thirty seconds for processing and thirty for retraction.
standard :: String -> String -> Registry
standard name reading = Registry name reading 30_000 30_000

runner :: String -> Wallet
runner = Wallet RunnerWallet

noCohort :: [reg] -> [wal] -> Either String [(reg, EdgeRequest wal)]
noCohort _ _ = Right []

-- | A story over one registry and one wallet.
single
    :: (Context reg wal -> Story reg wal step obs cmp ())
    -> [reg]
    -> [wal]
    -> Either String (Story reg wal step obs cmp ())
single story registries wallets = case (registries, wallets) of
    ([registry], [wallet]) -> Right (story (Context registry wallet))
    _ -> Left "the story names one registry and one wallet"

-- | A story over two registries and one wallet.
double
    :: (Context reg wal -> Context reg wal -> Story reg wal step obs cmp ())
    -> [reg]
    -> [wal]
    -> Either String (Story reg wal step obs cmp ())
double story registries wallets = case (registries, wallets) of
    ([first, second], [wallet]) ->
        Right (story (Context first wallet) (Context second wallet))
    _ -> Left "the story names two registries and one wallet"

-- | Submit, observe and compare each request in turn.
compared :: reg -> [EdgeRequest wal] -> Story reg wal step obs cmp ()
compared registry = mapM_ (submit registry >=> checked)

-- | Observe and compare a step already taken.
checked :: step -> Story reg wal step obs cmp ()
checked step = do
    observation <- observe step
    _ <- compareWithModel step observation
    pure ()

chapter :: String -> String -> String -> Maybe Chapter
chapter title introduction summary = Just (Chapter title introduction summary)

registration :: Program
registration =
    Program
        { programRow = "register-active-key"
        , programRegistries = [standard "story-registration" "registration"]
        , programWallets = [Wallet SecondWallet "recipient wallet"]
        , programCohort = noCohort
        , programStory = single Register.story
        , programExpected = replicate 8 Agrees
        , programStanding = Agreement
        , programControls = generalControls
        , programChapter =
            chapter
                "Register a key and receive its active token"
                "A requester submits two distinct active registrations and then repeats one key. The delivery is then sent to another address, and paid one lovelace short, beside the same untampered request. Every step is compared with the executable registry model."
                "Registration compared"
        }

occupied :: Program
occupied =
    Program
        { programRow = "insert-occupied-key"
        , programRegistries = [standard "occupied-insert" "occupied insert"]
        , programWallets = [runner "holder wallet"]
        , programCohort = noCohort
        , programStory = single Occupied.story
        , programExpected = replicate 3 Agrees
        , programStanding = Agreement
        , programControls = allControls
        , programChapter =
            chapter
                "Insert on a key the registry already holds"
                "A key is registered Active in this run. Registering that key again is refused beside its accepting control. The excluded updateActive encoding is also refused without changing the registration. Each result is compared with the executable registry model."
                "Occupied-key insertion compared"
        }

retirement :: Program
retirement =
    Program
        { programRow = "permanent-retire-active-key"
        , programRegistries =
            [ standard "story-retirement" "retirement"
            , standard "story-unknown-key comparison" "comparison"
            ]
        , programWallets = [runner "holder wallet"]
        , programCohort = noCohort
        , programStory = double Retire.story
        , programExpected = replicate 11 Agrees
        , programStanding = Agreement
        , programControls = generalControls
        , programChapter =
            chapter
                "Retire a registration and burn its active token"
                "The holder registers a key in this run, then termination consumes and burns that very token and changes the key to Terminal. Unknown-key termination is refused beside a reached accepting control. Excluded insertion and deletion encodings are refused. After a refused deletion the same Active key can still terminate; its Terminal key cannot register again. The original broader Absent and deletion-refund requirements stay published as uncovered."
                "Retirement compared"
        }

exits :: Program
exits =
    Program
        { programRow = "reject-and-retract-refund-controls"
        , programRegistries =
            [ Registry "story-rejection" "rejection" 1_000 1_000
            , Registry "story-retraction" "retraction" 1_000 30_000
            ]
        , programWallets = [runner "holder wallet"]
        , programCohort = noCohort
        , programStory = double Exit.story
        , programExpected = replicate 10 Agrees
        , programStanding = Agreement
        , programControls = generalControls <> ["signed-owner"]
        , programChapter =
            chapter
                "A request that is never folded"
                "A request can leave the queue without a fold. After its owner's retraction window has closed, a folder rejects it and must refund its owner the deposit, keeping the tip; while it is still retractable, its owner retracts it and must get back everything it held, deposit and tip, through an output whose inline datum is the retracted request's own output reference. Each refund paid one lovelace short or to another address, a return bound to another request, and a retraction spending the registry's state beside it must be refused, each beside the untampered exit of the same request."
                "Rejection and retraction compared"
        }

earlyRejection :: Program
earlyRejection =
    Program
        { programRow = "reject-inside-processing-and-retraction-windows"
        , programRegistries =
            [Registry "story-early-rejection" "early rejection" 120_000 120_000]
        , programWallets = [runner "holder wallet"]
        , programCohort = \registries wallets -> case (registries, wallets) of
            ([registry], [holder]) ->
                let (first, second) = EarlyReject.requests holder
                in  Right [(registry, first), (registry, second)]
            _ -> Left "the early rejection names one registry and one wallet"
        , programStory = single EarlyReject.story
        , programExpected = replicate 6 Agrees
        , programStanding = Agreement
        , programControls = allControls
        , programChapter =
            chapter
                "A folder rejects a request before its retraction deadline"
                "A reject carries no admission: the model accepts it in every window, and the chain does too. Two insertion requests from the same owner are booked together in a registry of their own. The first is rejected while it can still be folded, the second while its owner can still retract it. In each window a reject refunding the owner one lovelace short, and one refunding another key, must be refused by both, leaving the request pending; the untampered reject of the same request must be accepted by both, refund the owner the deposit and leave the registry state as it was. Each reject's validity interval is checked to lie inside the window its step names before it is submitted."
                "Early rejection compared"
        }

retractionWindow :: Program
retractionWindow =
    Program
        { programRow = "retract-outside-window"
        , programRegistries =
            [standard "story-retraction-window" "retraction window"]
        , programWallets = [runner "owner wallet"]
        , programCohort = \registries wallets -> case (registries, wallets) of
            ([registry], [owner]) ->
                let (first, second) = RetractionWindow.requests owner
                in  Right [(registry, first), (registry, second)]
            _ -> Left "the retraction window names one registry and one wallet"
        , programStory = single RetractionWindow.story
        , programExpected = replicate 3 Agrees
        , programStanding = Agreement
        , programControls = ["inside-phase-2"]
        , programChapter =
            chapter
                "Retract only inside phase 2"
                "Two insertion requests from the same owner are booked in one registry before either exits. The first is retracted before phase 2, then inside it; the second is retracted after its window closes. Both outside-window retractions must be refused, and the in-window retraction must be accepted. The second request shares the first's accepting control: once its own window is over it cannot have an in-window retry. The registry allows thirty seconds for processing and thirty more for retraction; waits follow each request's recorded submission time."
                "Retraction window compared"
        }

sequenceProgram :: Program
sequenceProgram =
    Program
        { programRow = "sequence"
        , programRegistries = [standard "unnamed-sequence" "sequence"]
        , programWallets = [runner "holder wallet"]
        , programCohort = noCohort
        , programStory = single Sequence.story
        , programExpected = replicate 8 Agrees
        , programStanding = Agreement
        , programControls = allControls
        , programChapter =
            chapter
                "A sequence no chapter names"
                "This program uses the same live interpreter for each listed request. Each step records its own model and chain outcome; any unsupported result carries the reason observed at the booking or fold boundary."
                "Unnamed sequence compared"
        }

-- | A program over one fresh registry, comparing each request it submits.
foldsOf :: String -> String -> String -> [(Edge, String)] -> Program
foldsOf row name reading requests =
    Program
        { programRow = row
        , programRegistries = [standard name reading]
        , programWallets = [runner "holder wallet"]
        , programCohort = noCohort
        , programStory = single $ \(Context registry holder) ->
            compared
                registry
                [EdgeRequest edge key holder | (edge, key) <- requests]
        , programExpected = map (const Agrees) requests
        , programStanding = Agreement
        , programControls = generalControls
        , programChapter = Nothing
        }

insertion :: Program
insertion =
    foldsOf "insert-key" "cg01" "insertion" [(InsertActive, "cg01-key")]

-- | The owner retracts an insertion request inside phase 2.
phase2Retraction :: Program
phase2Retraction =
    Program
        { programRow = "retract-inside-window"
        , programRegistries =
            [Registry "cg06" "retraction in phase 2" 1_000 30_000]
        , programWallets = [runner "owner wallet"]
        , programCohort = noCohort
        , programStory = single $ \(Context registry owner) ->
            retract registry (EdgeRequest InsertActive "cg06-key" owner)
                >>= checked
        , programExpected = [Agrees]
        , programStanding = Agreement
        , programControls = generalControls
        , programChapter = Nothing
        }

-- | A folder rejects an insertion request after its owner's retraction window.
lateRejection :: Program
lateRejection =
    Program
        { programRow = "reject-after-window"
        , programRegistries =
            [Registry "cg08" "rejection after the windows" 1_000 1_000]
        , programWallets = [runner "holder wallet"]
        , programCohort = noCohort
        , programStory = single $ \(Context registry holder) ->
            rejectWithin
                AfterTheWindows
                registry
                (EdgeRequest InsertActive "cg08-key" holder)
                >>= checked
        , programExpected = [Agrees]
        , programStanding = Agreement
        , programControls = generalControls
        , programChapter = Nothing
        }

{- | A folder rejects a request while it can still be folded. Its control comes
first, on the same request: the reject refunding the owner one lovelace short,
refused by both. Then the known divergence: one lovelace short at the refund's
position and two ada more in another output at the owner's key, which the
chain refuses and the model accepts (lambdasistemi/singular#361). Last the
reject itself, accepted by both, while the consuming project requires it
refused: its requirement is kept unmet by ruling.
-}
processingRejection :: Program
processingRejection =
    Program
        { programRow = "reject-before-deadline-consumer-requirement"
        , programRegistries =
            [Registry "cg09" "processing-window rejection" 30_000 5_000]
        , programWallets = [Wallet (OwnerWallet 10_000_000) "owner wallet"]
        , programCohort = noCohort
        , programStory = single $ \(Context registry owner) -> do
            let booked =
                    [
                        ( EdgeRequest InsertAbsent "cg09-key" owner
                        , Booking owner 3_000_000
                        )
                    ]
            _ <-
                tamperRejectBookedBatchWithin
                    (ShortFirstRefund 1)
                    InProcessingWindow
                    registry
                    booked
            _ <-
                tamperRejectBookedBatchWithin
                    (SplitFirstRefund 1)
                    InProcessingWindow
                    registry
                    booked
            _ <- rejectBookedBatchWithin InProcessingWindow registry booked
            pure ()
        , programExpected =
            [ Agrees
            , Diverges
                { divergenceChain = "refused"
                , divergenceModel = "accepted"
                , divergenceTrace = "deposit-returned"
                , divergenceIssue = "lambdasistemi/singular#361"
                }
            , Agrees
            ]
        , programStanding =
            Unmet
                { unmetRuling =
                    "kept unmet by operator ruling 2026-10-01 (singular#320; alignment: cardano-keri#468)"
                , unmetRegistry =
                    "Singular's Lean gives a reject no admission (Model.lean exitAdmission .reject = none): a folder may reject a request inside its process window"
                , unmetConsumer =
                    "R9_reject_needs_rejectable — a reject is refused until the request's retract window has passed"
                }
        , programControls = generalControls
        , programChapter = Nothing
        }

{- | A fold of no request, refused by both for the empty batch, beside its
accepting control: one insertion folded on the same registry.
-}
emptyFold :: Program
emptyFold =
    Program
        { programRow = "empty-fold"
        , programRegistries = [standard "cg11" "empty fold"]
        , programWallets = [runner "holder wallet"]
        , programCohort = noCohort
        , programStory = single $ \(Context registry holder) -> do
            _ <- foldBatch registry []
            compared registry [EdgeRequest InsertAbsent "cg11-key" holder]
        , programExpected = [Agrees, Agrees]
        , programStanding =
            Held
                { heldFor = "Q-002 (story 2)"
                , heldLean =
                    "Singular's Lean refuses the empty fold for empty-fold (foldBatch over no request), the reason the traced replay admits for the state script"
                , heldConsumer =
                    "R8_empty_fold_refused — the empty batch must be refused (consumer-side; upstream cardano-mpfs-onchain#100 is the partition fix)"
                }
        , programControls = generalControls
        , programChapter = Nothing
        }

{- | Two requests owned by two wallets, holding unequal deposits, rejected
together after the windows with each owner refunded what the other is owed:
refused by both, beside the same two requests refunded as owed. Then two more,
the first refunded a thousand lovelace short of its floor, refused by both,
beside the same two refunded as owed.
-}
refundRouting :: Program
refundRouting =
    Program
        { programRow = "request-value-and-refund-routing"
        , programRegistries = [standard "cg19" "refund routing"]
        , programWallets =
            [ Wallet (OwnerWallet 25_000_000) "first owner wallet"
            , Wallet SecondWallet "second owner wallet"
            ]
        , programCohort = noCohort
        , programStory = \registries wallets -> case (registries, wallets) of
            ([registry], [first, second]) -> Right $ do
                let pair a b =
                        [ (EdgeRequest InsertAbsent a first, Booking first 4_000_000)
                        , (EdgeRequest InsertAbsent b second, Booking second 2_000_000)
                        ]
                    crossed = pair "cg19-key-a" "cg19-key-b"
                    floored = pair "cg19-rej-a" "cg19-rej-b"
                _ <-
                    tamperRejectBookedBatchWithin
                        CrossedRefunds
                        AfterTheWindows
                        registry
                        crossed
                _ <- rejectBookedBatchWithin AfterTheWindows registry crossed
                _ <-
                    tamperRejectBookedBatchWithin
                        (ShortFirstRefund 1_000)
                        AfterTheWindows
                        registry
                        floored
                _ <- rejectBookedBatchWithin AfterTheWindows registry floored
                pure ()
            _ -> Left "refund routing names one registry and two wallets"
        , programExpected = replicate 4 Agrees
        , programStanding =
            Held
                { heldFor = "Q-002 (story 2)"
                , heldLean =
                    "Singular's Lean refuses the crossed refunds: its reject batch owes each owner its deposit back and the first is paid short, deposit-returned, the reason the traced replay admits for the state script"
                , heldConsumer =
                    "R11 — action-dependent routing (E18 disposition): processed Update value routes to the checkpoint/consumer hook (Update contributes no Rejected-owner obligations); Rejected owes input-tip per owner under a no-underpayment floor (upstream cardano-mpfs-onchain#101 is the partition fix)"
                }
        , programControls = generalControls
        , programChapter = Nothing
        }
