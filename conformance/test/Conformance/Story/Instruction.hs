{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The language shared by the executing and rendering interpreters.
module Conformance.Story.Instruction (
    Reason,
    LegName (..),
    AssetsI (..),
    KeysI (..),
    MintI (..),
    RefundsI (..),
    SignersI (..),
    ConfigI (..),
    SequenceI (..),
    HashesI (..),
    LegI (..),
    EditI (..),
    CaseI (..),
    SelectI (..),
    ClauseI (..),
    StoryI (..),
    EvidenceBoundary (..),
    UnexercisedClause (..),
    FailureReport (..),
    duplicate,
    keyedMint,
    renderLeg,
    renderBoundary,
    unexercisedChecks,
    groupNames
) where

import Control.Monad.Operational (Program, ProgramViewT (Return, (:>>=)), view)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Aeson (Value)
import Conformance.Story.Binding (Binding)

-- | A rejection reason. Required by 'rejects'.
type Reason = Text

-- | Refusal legs under observation.
data LegName = Duplicate | KeyedMint
    deriving stock (Show, Eq)

-- | The duplicate leg.
duplicate :: LegName
duplicate = Duplicate

-- | The keyed-mint leg.
keyedMint :: LegName
keyedMint = KeyedMint

-- | Render a leg name as the fixture spells it.
renderLeg :: LegName -> String
renderLeg Duplicate = "duplicate"
renderLeg KeyedMint = "keyedMint"

-- | Asset collections as programs. 'LitAssets' is the negative control
-- instrument: a collection built as a literal rather than a program.
-- Validators refuse it and 'runStory' will not execute it.
data AssetsI a where
    ActiveToken :: Value -> Integer -> AssetsI ()
    Token :: Value -> Value -> Integer -> AssetsI ()
    NoAssets :: AssetsI ()
    LitAssets :: [Value] -> AssetsI ()

-- | Key collections as programs.
data KeysI a where
    Key :: Value -> KeysI ()

-- | Mint collections as programs.
data MintI a where
    Mint :: Value -> Value -> Integer -> MintI ()
    NoMints :: MintI ()

-- | Refund collections as programs.
data RefundsI a where
    Lovelace :: Integer -> RefundsI ()
    NoRefunds :: RefundsI ()

-- | Signer collections as programs.
data SignersI a where
    Signer :: Value -> SignersI ()
    NoSigners :: SignersI ()

-- | Configuration pins as programs.
data ConfigI a where
    MaxFee :: Integer -> ConfigI ()
    RestUnchanged :: ConfigI ()
    NoPins :: ConfigI ()

-- | Landed-fold sequences as programs.
data SequenceI a where
    Step :: Value -> Value -> Value -> Value -> SequenceI ()
    NoSteps :: SequenceI ()

-- | Failing-script hashes as programs.
data HashesI a where
    Hash :: Value -> HashesI ()
    NoHashes :: HashesI ()

-- | Leg edits as programs. 'OmitTrace' names the ledger reality that a
-- script-execution failure carries an empty log list, so absence of the
-- field is the normal case.
data LegI a where
    LegKeys :: Program KeysI () -> LegI ()
    LegClaimed :: Program MintI () -> LegI ()
    LegEntailed :: Program MintI () -> LegI ()
    LegControl :: Program MintI () -> LegI ()
    LegDistinguisher :: Text -> LegI ()
    LegTxid :: Value -> LegI ()
    LegControlTxid :: Value -> LegI ()
    LegHashes :: Program HashesI () -> LegI ()
    OmitTrace :: LegI ()

-- | Receipt edits as programs.
data EditI a where
    Deliver :: Program AssetsI () -> EditI ()
    Minted :: Program AssetsI () -> EditI ()
    ObservedAddress :: Value -> EditI ()
    OpenParameters :: Integer -> EditI ()
    RequestLovelace :: Integer -> EditI ()
    ApprovalRecomputed :: Value -> EditI ()
    Refunds :: Program RefundsI () -> EditI ()
    Signers :: Program SignersI () -> EditI ()
    ConfigAfter :: Program ConfigI () -> EditI ()
    ConfigBefore :: Program ConfigI () -> EditI ()
    LandedFolds :: Program SequenceI () -> EditI ()
    OnLeg :: LegName -> Program LegI () -> EditI ()
    DropLeg :: LegName -> EditI ()
    Unchanged :: EditI ()

-- | Cases as programs. The outcome is named here; what it means lives
-- in the interpreters.
data CaseI a where
    Accepts :: Text -> Program EditI () -> CaseI ()
    AcceptsBecause :: Text -> Program EditI () -> Reason -> CaseI ()
    Rejects :: Text -> Reason -> Program EditI () -> CaseI ()

-- | Clause selections as programs: conjunct anchors quoted verbatim
-- from the bound statement.
data SelectI a where
    Conjunct :: Text -> SelectI ()

-- | Clauses as programs, selecting the Lean promises they exercise.
data ClauseI a where
    Clause :: Text -> Program SelectI () -> Program CaseI () -> ClauseI ()
    Unexercised :: Text -> Text -> ClauseI ()

-- | Stories as programs: one bound obligation read through clauses.
data StoryI a where
    Theorem :: Binding -> Program ClauseI () -> StoryI ()

-- | Where the example's evidence was observed.
data EvidenceBoundary
    = ReceiptValidation
    | TransactionExecution
    deriving stock (Show, Eq)

-- | Render the boundary as the failure report names it.
renderBoundary :: EvidenceBoundary -> String
renderBoundary ReceiptValidation =
    "receipt evidence \183 subject: Conformance.Receipt.loadReceipts"
renderBoundary TransactionExecution =
    "transaction execution \183 subject: Singular.Registry.Driver"

-- ---------------------------------------------------------
-- Smart constructors: one instruction is already a program
-- ---------------------------------------------------------

-- | A clause the slice does not exercise. Recorded with its alias and
-- what exercising it would need; it contributes no check and earns no
-- coverage, so a theorem pointer alone never reads as evidence.
data UnexercisedClause = UnexercisedClause
    { unAlias :: !String
    , unWhatMissing :: !String
    }
    deriving stock (Show, Eq)

-- | The executable checks an unexercised clause contributes: none. The
-- type leaves no other option; this pins it.
unexercisedChecks :: UnexercisedClause -> Int
unexercisedChecks _ = 0

-- | The failure report: subject, condition, example and observed outcome, then the reason
-- distinguishing the defect and the edit line rendered from the
-- instructions that ran.
data FailureReport = FailureReport
    { frTheorem :: !String
    , frClause :: !String
    , frExample :: !String
    , frBoundary :: !String
    , frExpected :: !String
    , frActual :: !String
    , frBecause :: !(Maybe String)
    , frEdit :: !String
    }
    deriving stock (Show, Eq)

-- | Every clause alias and example name the story declares, read out
-- of the program for the name-hygiene check. Never hand-listed.
groupNames :: Program StoryI () -> [String]
groupNames prog = case view prog of
    Return () -> []
    Theorem _ clauses :>>= rest -> clauseNames clauses <> groupNames (rest ())
  where
    clauseNames :: Program ClauseI () -> [String]
    clauseNames p = case view p of
        Return () -> []
        Clause alias _ cases :>>= rest -> T.unpack alias : caseNames cases <> clauseNames (rest ())
        Unexercised alias _ :>>= rest -> T.unpack alias : clauseNames (rest ())
    caseNames :: Program CaseI () -> [String]
    caseNames p = case view p of
        Return () -> []
        Accepts name _ :>>= rest -> T.unpack name : caseNames (rest ())
        AcceptsBecause name _ _ :>>= rest -> T.unpack name : caseNames (rest ())
        Rejects name _ _ :>>= rest -> T.unpack name : caseNames (rest ())

