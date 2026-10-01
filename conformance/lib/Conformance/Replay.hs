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
    , ScriptFamily (..)
    , identifyScript

      -- * Comparison
    , ReasonComparison (..)
    , compareReason
    , stepComparison
    , comparisonName
    , admittedFor

      -- * Evidence
    , PurposeReplay (..)
    , acceptingControlGaps
    , TracedProvenance (..)
    , toolchainCause
    , captureIdOf
    ) where

import Crypto.Hash qualified as Hash
import Data.Aeson
    ( FromJSON (..)
    , ToJSON (..)
    , Value (..)
    , object
    , withObject
    , (.:)
    , (.=)
    )
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Foldable (toList)
import Data.List (nub, sortOn)
import Data.Map.Strict (Map)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

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
    | -- | the failing script's family is identified, but the replay traces none of it
      NoReplayRoute
    | -- | the family is identified by the capture; its applications do not reproduce the hash
      ParametersMismatch
    | -- | no family is identified and no application is claimed
      UnidentifiedScript
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
    NoReplayRoute -> "no-replay-route"
    ParametersMismatch -> "parameters-mismatch"
    UnidentifiedScript -> "unidentified-script"
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
admitReason deployed traced = \case
    Just cause -> Unobserved cause
    Nothing -> case (runOutcome deployed, runOutcome traced) of
        (Succeeded, _) -> Unobserved DeployedSucceeds
        (BudgetExhausted, _) -> Unobserved DeployedBudget
        (EvaluationError _, _) -> Unobserved EvaluatorFailed
        (ValidatorFailure, Succeeded) -> Unobserved TracedSucceeds
        (ValidatorFailure, BudgetExhausted) -> Unobserved TracedBudget
        (ValidatorFailure, EvaluationError _) -> Unobserved EvaluatorFailed
        (ValidatorFailure, ValidatorFailure) ->
            case userTraces (runLogs traced) of
                [] -> Unobserved NoUserTrace
                [reason] -> Admitted reason
                _ -> Unobserved SeveralUserTraces

{- | The user-defined lines of an evaluation log. The traced build keeps only
user-defined traces, so every non-blank line is one.
-}
userTraces :: [Text] -> [Text]
userTraces = filter (not . T.null . T.strip)

-- | A refused step's chain-side reason against the model's.
data ReasonComparison
    = Agrees
    | Differs {chainReason :: Text, leanReason :: Text}
    | Uncompared UnobservedCause
    deriving stock (Show, Eq)

-- | Compare an admitted reason with Lean's; an unobserved one is not compared.
compareReason :: Text -> ReplayClass -> ReasonComparison
compareReason lean = \case
    Admitted chain
        | chain == lean -> Agrees
        | otherwise -> Differs{chainReason = chain, leanReason = lean}
    Unobserved cause -> Uncompared cause

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
captureIdOf files =
    sha256Hex
        ( BS.concat
            [ BS8.pack name <> "\0" <> TE.encodeUtf8 (sha256Hex content) <> "\n"
            | (name, content) <- sortOn fst files
            ]
        )

sha256Hex :: ByteString -> Text
sha256Hex = T.pack . show . Hash.hashWith Hash.SHA256

{- | 'ToolchainMismatch' unless the deployed blueprint's validators are
exactly the ones the traced build's untraced twin produced, hash for hash.
-}
toolchainCause
    :: TracedProvenance -> Map Text Text -> Maybe UnobservedCause
toolchainCause provenance deployed
    | tpUntracedHashes provenance == deployed = Nothing
    | otherwise = Just ToolchainMismatch

instance ToJSON RunOutcome where
    toJSON = \case
        Succeeded -> "succeeded"
        ValidatorFailure -> "validator-failure"
        BudgetExhausted -> "budget-exhausted"
        EvaluationError message -> object ["evaluation-error" .= message]

instance ToJSON ReplayRun where
    toJSON r =
        object
            [ "bytesHash" .= runBytesHash r
            , "budgetLimit" .= units (runBudgetLimit r)
            , "budgetUsed" .= fmap units (runBudgetUsed r)
            , "outcome" .= runOutcome r
            , "logs" .= runLogs r
            ]
      where
        units (mem, steps) = object ["mem" .= mem, "steps" .= steps]

instance ToJSON PurposeReplay where
    toJSON p =
        object
            [ "purpose" .= prPurpose p
            , "deployedHash" .= prDeployedHash p
            , "tracedHash" .= prTracedHash p
            , "deployed" .= prDeployed p
            , "traced" .= prTraced p
            , "class" .= prClass p
            ]

-- | A validator family the replay can recognise a failing hash by.
data ScriptFamily = ScriptFamily
    { sfTitle :: Text
    , sfRouted :: Bool
    -- ^ whether the replay has a traced counterpart for it
    , sfCandidates :: [Text]
    -- ^ hashes of its untraced applications built from the capture
    }
    deriving stock (Show, Eq)

{- | Which family a failing hash belongs to: a routed family whose candidate
reproduces it is replayed; an unrouted one is 'NoReplayRoute'; a family the
capture records for the script (its role), none of whose candidates reproduce
it, is 'ParametersMismatch'; otherwise 'UnidentifiedScript'.
-}
identifyScript
    :: [ScriptFamily] -> Maybe Text -> Text -> Either UnobservedCause Text
identifyScript families role hash =
    case [sfTitle f | f <- families, sfRouted f, hash `elem` sfCandidates f] of
        title : _ -> Right title
        []
            | any (\f -> not (sfRouted f) && hash `elem` sfCandidates f) families ->
                Left NoReplayRoute
            | maybe False (`elem` map sfTitle families) role ->
                Left ParametersMismatch
            | otherwise -> Left UnidentifiedScript

{- | A refused step's comparison: the purposes of the script the step is
judged by (its marker hash) against Lean's reason. It agrees only when every
such purpose agrees; any purpose that differs makes it differ; otherwise it
is uncompared, with the first cause — or 'ContextUnavailable' when the
marker's script is not among the failing purposes at all.
-}
stepComparison
    :: Text -> Text -> [(Text, ReplayClass)] -> ReasonComparison
stepComparison marker lean purposes =
    case [compareReason lean cls | (hash, cls) <- purposes, hash == marker] of
        [] -> Uncompared ContextUnavailable
        comparisons -> case [d | d@Differs{} <- comparisons] of
            differing : _ -> differing
            [] -> case [cause | Uncompared cause <- comparisons] of
                cause : _ -> Uncompared cause
                [] -> Agrees

-- | The comparison as the replay index spells it.
comparisonName :: ReasonComparison -> Text
comparisonName = \case
    Agrees -> "agrees"
    Differs{} -> "differs"
    Uncompared _ -> "uncompared"

{- | The reason the marker's script admitted, when every purpose of it admits
the same one.
-}
admittedFor :: Text -> [(Text, ReplayClass)] -> Maybe Text
admittedFor marker purposes =
    case [cls | (hash, cls) <- purposes, hash == marker] of
        [] -> Nothing
        classes -> case [reason | Admitted reason <- classes] of
            reasons@(reason : _)
                | length reasons == length classes
                , all (== reason) reasons ->
                    Just reason
            _ -> Nothing

{- | What the replay index lacks for FR-13: every script role a refusal names
(a validator title — a bare hash names no family a control could replay) needs
an @accepting-control@ entry in which that role's deployed and traced runs
both succeeded. One line per missing or failing role; none when complete.
-}
acceptingControlGaps :: [Value] -> [Text]
acceptingControlGaps entries = mapMaybe gap refusingRoles
  where
    field name = \case
        Object o -> KM.lookup name o
        _ -> Nothing
    kindIs kind entry = field "kind" entry == Just (String kind)
    refusingRoles =
        nub
            [ role
            | entry <- entries
            , kindIs "refusal" entry
            , Just (String roles) <- [field "role" entry]
            , role <- T.splitOn "+" roles
            , "." `T.isInfixOf` role
            ]
    controls =
        [ control
        | entry <- entries
        , kindIs "accepting-control" entry
        , Just (Array listed) <- [field "controls" entry]
        , control <- toList listed
        ]
    succeeded run control =
        (field run control >>= field "outcome") == Just (String "succeeded")
    gap role = case [c | c <- controls, field "role" c == Just (String role)] of
        [] -> Just (role <> ": no accepting control")
        ofRole
            | any (\c -> succeeded "deployed" c && succeeded "traced" c) ofRole ->
                Nothing
            | otherwise ->
                Just (role <> ": no accepting control with both runs succeeded")
