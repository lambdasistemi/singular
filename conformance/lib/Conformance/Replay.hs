{-# LANGUAGE LambdaCase #-}

{- |
Module      : Conformance.Replay
Description : What a traced replay of a live refusal admits as its reason
License     : Apache-2.0

A live phase-2 refusal carries no reason: the deployed validators are built
without traces. The runner replays the refused transaction's failing script
twice on the arguments the ledger built for it — the deployed bytes under the
transaction's declared units, then the traced bytes of the same source with
the same parameters under the protocol maximum — and this module decides what
those two runs establish.

A reason is admitted only when both runs fail as a validator and the traced
run leaves exactly one user-defined trace; that line, verbatim, is the reason.
Every other result is an unobserved reason with its cause, and every cause is
its own value. A reason is compared with the model's only once admitted.

Pure: the runs arrive as data. Capturing and evaluating are
"Conformance.Run.Replay"'s.
-}
module Conformance.Replay
    ( -- * Runs
      RunOutcome (..)
    , ReplayRun (..)

      -- * Classes
    , UnobservedCause (..)
    , causeName
    , ReplayClass (..)
    , admitReason
    , userTraces

      -- * Comparison
    , ReasonComparison (..)
    , compareReason

      -- * Evidence
    , PurposeReplay (..)
    , TracedProvenance (..)
    , captureIdOf
    ) where

import Data.Aeson
    ( FromJSON (..)
    , ToJSON (..)
    , object
    , withObject
    , (.:)
    , (.=)
    )
import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Text (Text)

-- | How one evaluation of one script on one purpose's arguments ended.
data RunOutcome
    = -- | the script returned
      Succeeded
    | -- | the script failed: an @error@, a failed builtin, a non-unit result
      ValidatorFailure
    | -- | the budget ran out before the script finished
      BudgetExhausted
    | -- | the evaluator could not run the script at all
      EvaluationError Text
    deriving stock (Show, Eq)

-- | One evaluation: which bytes, under which limit, using what, how it ended.
data ReplayRun = ReplayRun
    { runBytesHash :: Text
    -- ^ hash of the script bytes evaluated
    , runBudgetLimit :: (Integer, Integer)
    -- ^ memory and steps the evaluation was allowed
    , runBudgetUsed :: Maybe (Integer, Integer)
    -- ^ what a finished evaluation spent; 'Nothing' when it did not finish
    , runOutcome :: RunOutcome
    , runLogs :: [Text]
    -- ^ the evaluation's log lines, verbatim
    }
    deriving stock (Show, Eq)

-- | Why a replay admits no reason. Each is distinct; none stands for another.
data UnobservedCause
    = -- | the capture does not resolve every output the transaction names
      CaptureIncomplete
    | -- | the ledger's arguments for the failing purpose could not be built
      ContextUnavailable
    | -- | the deployed blueprint is not the one the traced build corresponds to
      ToolchainMismatch
    | -- | no deployed parameter set reproduces the failing hash on untraced code
      ParametersMismatch
    | DeployedSucceeds
    | DeployedBudget
    | TracedSucceeds
    | TracedBudget
    | -- | the traced run failed without a user-defined trace
      NoUserTrace
    | -- | the traced run failed with more than one user-defined trace
      SeveralUserTraces
    | -- | the node rejected the transaction before any script ran
      Phase1
    | -- | the run could not reach the evaluation
      SetupFailure
    | Timeout
    | ClientException
    | -- | the evaluator itself failed, on either run
      EvaluatorFailed
    deriving stock (Show, Eq, Ord, Enum, Bounded)

-- | The cause as the replay evidence spells it.
causeName :: UnobservedCause -> Text
causeName = \case
    CaptureIncomplete -> "capture-incomplete"
    ContextUnavailable -> "context-unavailable"
    ToolchainMismatch -> "toolchain-mismatch"
    ParametersMismatch -> "parameters-mismatch"
    DeployedSucceeds -> "deployed-succeeds"
    DeployedBudget -> "deployed-budget"
    TracedSucceeds -> "traced-succeeds"
    TracedBudget -> "traced-budget"
    NoUserTrace -> "no-user-trace"
    SeveralUserTraces -> "several-user-traces"
    Phase1 -> "phase-1"
    SetupFailure -> "setup-failure"
    Timeout -> "timeout"
    ClientException -> "client-exception"
    EvaluatorFailed -> "evaluation-error"

-- | What a replay establishes about the chain-side reason.
data ReplayClass
    = Admitted Text
    | Unobserved UnobservedCause
    deriving stock (Show, Eq)

instance ToJSON ReplayClass where
    toJSON (Admitted reason) = object ["admitted" .= reason]
    toJSON (Unobserved cause) = object ["unobserved" .= causeName cause]

{- | Decide what the deployed run and the traced run admit. An earlier cause
(capture, toolchain, parameters, or the run never reaching evaluation) wins.
-}
admitReason
    :: ReplayRun -> ReplayRun -> Maybe UnobservedCause -> ReplayClass
admitReason _ _ _ = error "admitReason: not implemented"

{- | The user-defined lines of an evaluation log. The traced build keeps only
user-defined traces, so every non-blank line is one.
-}
userTraces :: [Text] -> [Text]
userTraces _ = error "userTraces: not implemented"

-- | A refused step's chain-side reason against the model's.
data ReasonComparison
    = Agrees
    | Differs {chainReason :: Text, leanReason :: Text}
    | Uncompared UnobservedCause
    deriving stock (Show, Eq)

-- | Compare an admitted reason with Lean's; an unobserved one is not compared.
compareReason :: Text -> ReplayClass -> ReasonComparison
compareReason _ _ = error "compareReason: not implemented"

-- | One failing purpose of one rejected transaction, and its two runs.
data PurposeReplay = PurposeReplay
    { prPurpose :: Text
    -- ^ the purpose and its redeemer index, as the ledger names it
    , prDeployedHash :: Text
    -- ^ the failing hash the node reported
    , prTracedHash :: Maybe Text
    -- ^ the traced code's hash under the same parameters, once applied
    , prDeployed :: Maybe ReplayRun
    , prTraced :: Maybe ReplayRun
    , prClass :: ReplayClass
    }
    deriving stock (Show, Eq)

-- | The traced build's provenance, as the flake writes it beside it.
data TracedProvenance = TracedProvenance
    { tpSource :: Text
    , tpCompiler :: Text
    , tpFlags :: Text
    , tpUntracedHashes :: Map Text Text
    }
    deriving stock (Show, Eq)

instance FromJSON TracedProvenance where
    parseJSON = withObject "TracedProvenance" $ \o ->
        TracedProvenance
            <$> o .: "source"
            <*> o .: "compiler"
            <*> o .: "flags"
            <*> o .: "untracedHashes"

{- | The identity of a capture: SHA-256 over each file's canonical name and
content hash, in name order, so the order the files were written in does not
move it.
-}
captureIdOf :: [(FilePath, ByteString)] -> Text
captureIdOf _ = error "captureIdOf: not implemented"
