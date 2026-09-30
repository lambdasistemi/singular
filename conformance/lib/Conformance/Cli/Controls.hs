{-# LANGUAGE GADTs #-}

{- | The registry's refusals of an insertion the open-datum application
books: a second insertion of a key that is Active, and an insertion of a
key that is already Terminal.

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
    , controlsStory

      -- * Receipts
    , Receipt (..)
    , Observation (..)
    , emptyReceipt

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
import Data.List (intercalate, nub)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import Data.Text qualified as T

-- ---------------------------------------------------------
-- Actions
-- ---------------------------------------------------------

-- | The ordinary commands, as a person runs them.
data Command = Create | Insert | Terminate | Inspect
    deriving stock (Eq, Show, Enum, Bounded)

commandName :: Command -> String
commandName c = case c of
    Create -> "create"
    Insert -> "insert"
    Terminate -> "terminate"
    Inspect -> "inspect"

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

-- | Every statement the stories bind.
statementBindings :: [Binding]
statementBindings =
    [theoremBinding duplicateRefused, theoremBinding resurrectionRefused]

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

{- | Boot a registry and bring 'heldKey' to Active with the ordinary
commands, then, when asked, to Terminal.
-}
prefix :: Bool -> Target -> Story ()
prefix terminal target = do
    _ <- action (Run Create target "")
    _ <- action (Run Insert target heldKey)
    when terminal $ void (action (Run Terminate target heldKey))

{- | The shared shape of both refusals. On a control registry, an absent
key booked through the application and folded without local evaluation
is accepted. On the target, the ordinary @insert@ of the held key is
booked, stops partial and names its pending request; that request's fold,
submitted without local evaluation, is refused by the registry's state
validator; and nothing changes.
-}
refusal
    :: Theorem thm
    -> Target
    -> Target
    -> String
    -> TheoremStory thm CliI ()
refusal thm control target keyWhat = do
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
duplicateStory = do
    prefix False (Target "duplicate-control")
    prefix False (Target "duplicate")
    theorem duplicateRefused $
        refusal
            duplicateRefused
            (Target "duplicate-control")
            (Target "duplicate")
            "the Active key"

-- | An insertion of a key already Terminal.
resurrectionStory :: Story ()
resurrectionStory = do
    prefix True (Target "resurrection-control")
    prefix True (Target "resurrection")
    theorem resurrectionRefused $
        refusal
            resurrectionRefused
            (Target "resurrection-control")
            (Target "resurrection")
            "the Terminal key"

controlsStory :: Story ()
controlsStory = duplicateStory >> resurrectionStory

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
    , rcRefusingScripts :: [Text]
    -- ^ The script hashes the node's refusal names
    , rcReason :: Maybe Text
    -- ^ The node's or the command's own words, bounded
    , rcObservation :: Maybe Observation
    , rcEvidence :: [Text]
    -- ^ Files beside the receipt: command output, transaction bodies
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
        , rcRefusingScripts = []
        , rcReason = Nothing
        , rcObservation = Nothing
        , rcEvidence = []
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
            , "refusingScripts" .= rcRefusingScripts r
            , "reason" .= rcReason r
            , "observation" .= rcObservation r
            , "evidence" .= rcEvidence r
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
            <*> o .: "refusingScripts"
            <*> o .:? "reason"
            <*> o .:? "observation"
            <*> o .: "evidence"

-- | The action name, target and key a receipt for this action must carry.
identify :: CliI res -> Maybe (Text, Text, Text)
identify i = case i of
    Run c (Target t) k -> Just ("run " <> T.pack (commandName c), T.pack t, T.pack k)
    Book (Target t) k -> Just ("book", T.pack t, T.pack k)
    FoldUnevaluated (Target t) k -> Just ("fold-unevaluated", T.pack t, T.pack k)
    Observe (Target t) k -> Just ("observe", T.pack t, T.pack k)
    Require _ _ -> Nothing

-- ---------------------------------------------------------
-- Checks
-- ---------------------------------------------------------

-- | The requirement's failures on these receipts; none means it holds.
check :: Requirement -> [Receipt] -> [String]
check req rs = case (req, rs) of
    (CommandSucceeded, [r]) ->
        [ "the command's outcome is " <> show (rcOutcome r) <> ", not success"
        | rcOutcome r /= "success"
        ]
    (Accepted, [r]) ->
        [ "the outcome is " <> show (rcOutcome r) <> ", not accepted"
        | rcOutcome r /= "accepted"
        ]
            <> ["no transaction id is recorded" | isNothing (rcTxId r)]
    (RefusedByState, [r]) ->
        [ "the fold was evaluated locally, so the node never judged it"
        | rcEvaluation r /= Just "skipped"
        ]
            <> [ "the outcome is "
                    <> show (rcOutcome r)
                    <> ", not a refusal by the node"
               | rcOutcome r /= "ledger-refused"
               ]
            <> case rcStateValidator r of
                Nothing -> ["the registry's state validator is not recorded"]
                Just h ->
                    [ "the refusal does not name the state validator "
                        <> T.unpack h
                        <> "; it names "
                        <> show (rcRefusingScripts r)
                    | h `notElem` rcRefusingScripts r
                    ]
            <> ["no transaction id is recorded" | isNothing (rcTxId r)]
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
            <> (if req `elem` [Unchanged, PartialPending] then "two" else "one")
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
            case goClauses (boName (theoremBinding thm)) st (clauses body) of
                (Just r, st') -> go st' (next r)
                (Nothing, st') -> (Nothing, st')

    goClauses
        :: String
        -> Replay
        -> Program (Clause thm CliI) a
        -> (Maybe a, Replay)
    goClauses _ st@(Replay _ _ (Just _)) _ = (Nothing, st)
    goClauses name st program = case view program of
        Return a -> (Just a, st)
        Clause title leanCheck body :>>= next ->
            let (inner, Replay n rs stop) = collect st body
            in  case (inner, stop) of
                    (Just (obs, bodyFailures), Nothing) ->
                        let (checked, Replay n' _ stop') =
                                collect (Replay n [] Nothing) (checkAction leanCheck obs)
                            failures =
                                bodyFailures <> maybe [] snd checked
                            status
                                | Just why <- stop' = Uncovered why
                                | null failures = Held
                                | otherwise = NotHeld failures
                            result = ClauseResult name title status
                        in  goClauses name (Replay n' (result : rs) stop') (next obs)
                    _ ->
                        ( Nothing
                        , Replay n rs (Just (fromMaybe "no receipt" stop))
                        )

    -- Walk a program, collecting the failures of the requirements in it.
    collect :: Replay -> Story a -> (Maybe (a, [String]), Replay)
    collect st0 = walk st0 []
      where
        walk :: Replay -> [String] -> Story a -> (Maybe (a, [String]), Replay)
        walk st@(Replay _ _ (Just _)) _ _ = (Nothing, st)
        walk st acc program = case view program of
            Return a -> (Just (a, acc), st)
            Action (Require req rs) :>>= next ->
                walk st (acc <> check req rs) (next ())
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
        unless (any (("is accepted" `T.isSuffixOf`) . T.pack) titles) $
            Left (s <> " has a refusal without an accepting control")
    Right ()

-- ---------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------

{- | The section a reader sees: each statement, what was done, and the
verdict of each clause as the receipts give it. Uncovered clauses are
listed, with the reason, beside the rest.
-}
renderControls :: [ClauseResult] -> Story () -> String
renderControls results story =
    unlines $
        [ "## The registry refuses an insertion it already holds"
        , ""
        , "The open-datum application books a second insertion of an Active key, and an insertion of a key that is already Terminal. The registry refuses to fold either, because the key exists. Each refusal below sits beside a control that differs only in the key, and readbacks before and after the refused fold."
        , ""
        , "The refusal is the node's, reached by submitting the fold without evaluating its scripts locally, and it names the script that failed: the registry's state validator. The model's reason, `key-exists`, is not something the node reports, and it is not claimed as observed."
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
