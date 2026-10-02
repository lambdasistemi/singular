{- |
Module      : Conformance.Run.Control
Description : Split out of Conformance.Run (#263); see that module's header
License     : Apache-2.0
-}
module Conformance.Run.Control
    ( caRows
    , csRows
    , programRows
    , outsideRows
    , harnessRows
    , cgSessionRows
    , canonicalRows
    , Control (..)
    , readControl
    , ReasonControl (..)
    , parseReasonControl
    , controlledReason
    , cgDeposit
    ) where

import Data.Text (Text)
import Data.Text qualified as T
import System.Environment (lookupEnv)

import Conformance.Edge.Programs (Program (..), programs)
import Conformance.Mirror (failWith)

-- ---------------------------------------------------------
-- Row vocabulary and control modes
-- ---------------------------------------------------------

{- | Row families by explicit membership. Every partition below filters by
these lists, never by exclusion: a catch-all partition silently absorbs
the next family of rows (canonical-seed-identity-tokenless-output-authentication were once routed into the serialization
session by a notElem-registry-operations catch-all). A row in no family fails loudly.
-}
caRows, csRows :: [String]
caRows =
    [ "canonical-seed-identity"
    , "rival-seed-authentication"
    , "policy-address-only-authentication-control"
    , "applied-validator-identity"
    , "tokenless-output-authentication"
    ]
csRows =
    [ "blueprint-encoding-round-trip"
    , "submitted-datum-byte-round-trip"
    , "update-redeemer-constructor-witnesses"
    , "wrong-redeemer-constructor-index"
    , "request-and-mint-constructor-witnesses"
    , "script-parameter-application"
    , "proof-step-constructor-witnesses"
    , "state-fields-chain-round-trip"
    ]

-- | Every row a program runs, read off the programs themselves.
programRows :: [String]
programRows = map programRow programs

{- | The registry rows the model cannot express that a session still runs for
their chain evidence, each through its own runner.
-}
outsideRows :: [String]
outsideRows = ["fold-against-superseded-root", "surplus-fold-actions"]

{- | Harness runs a session executes beside the rows: no row in @rows.json@,
no chapter of the book and no receipt anything reads. @batch@ executes the story
language's batch instructions on the devnet (#344).
-}
harnessRows :: [String]
harnessRows = ["batch"]

-- | The rows one registry session runs: programs, outside rows and the harness.
cgSessionRows :: [String]
cgSessionRows = programRows <> outsideRows <> harnessRows

canonicalRows :: [String]
canonicalRows = caRows <> csRows <> cgSessionRows

data Control
    = Normal
    | WrongReason
    | FalseClaim
    | WrongIndex
    | WrongParams
    | FalseDatum
    | MissingWitness
    | {- | policy-address-only-authentication-control armed: the policy+address-only authenticator must
      reject the rival, which it cannot. Proves rival-seed-authentication's rejection
      is attributable to the derived name and nothing else.
      -}
      NaiveAuthenticator
    | {- | applied-validator-identity armed: the unapplied layer's address must pass for
      the deployed script, which it cannot. Proves the identity
      layers are genuinely distinct and the check can fail.
      -}
      UnappliedAddress
    | {- | blueprint-encoding-round-trip armed (#157 request-destination-binding): a three-element list must validate
      against the two-element destination pair, which it cannot —
      the fixed tuple is checked at exact arity. Proves the schema
      oracle was not loosened into a homogeneous list rule.
      -}
      BlueprintWrongArity
    | {- | state-fields-chain-round-trip armed (#157 X1): the retired SIX-field state encoding
      must decode the chain's datum, which it cannot — the datum has
      eight fields now. Proves the round-trip row is reading the new
      contract and would notice a regression to the old one.
      -}
      LegacySixField
    deriving stock (Eq, Show)

readControl :: IO Control
readControl = do
    mode <- lookupEnv "CONFORMANCE_CONTROL"
    case mode of
        Nothing -> pure Normal
        Just "wrong-reason" -> pure WrongReason
        Just "false-claim" -> pure FalseClaim
        Just "wrong-index" -> pure WrongIndex
        Just "wrong-params" -> pure WrongParams
        Just "false-datum" -> pure FalseDatum
        Just "missing-witness" -> pure MissingWitness
        Just "naive-authenticator" -> pure NaiveAuthenticator
        Just "unapplied-address" -> pure UnappliedAddress
        Just "legacy-six-field" -> pure LegacySixField
        Just "blueprint-wrong-arity" -> pure BlueprintWrongArity
        Just other ->
            failWith
                ("unknown CONFORMANCE_CONTROL value " <> other)

-- ---------------------------------------------------------
-- Keys and values
-- ---------------------------------------------------------

{- | The deposit a booking rides with, over and above the tip. The fold
returns it to the destination the request named, or locks it in the
custody an absence creates — it is never the folder's (T6, want-ledger R4).
-}
cgDeposit :: Integer
cgDeposit = 3_000_000

{- | The wrong-reason control (FR-12): in one row, at one compared step, Lean's
reason is replaced by another before the comparison, so a run whose chain-side
reason equals Lean's must fail naming both. Set by
@CONFORMANCE_REASON_CONTROL=ROW:STEP:REASON@; the step is the row's
zero-based compared step.
-}
data ReasonControl = ReasonControl
    { rcRow :: Text
    , rcStep :: Int
    , rcReason :: Text
    }
    deriving stock (Show, Eq)

-- | Read @ROW:STEP:REASON@; anything else is refused with what was wrong.
parseReasonControl :: String -> Either String ReasonControl
parseReasonControl text = case T.splitOn ":" (T.pack text) of
    [row, step, reason]
        | not (T.null row)
        , not (T.null reason)
        , [(index, "")] <- reads (T.unpack step)
        , index >= 0 ->
            Right (ReasonControl row index reason)
    _ ->
        Left
            ("CONFORMANCE_REASON_CONTROL is ROW:STEP:REASON, got " <> show text)

-- | Lean's reason for a step, replaced when the control names this step.
controlledReason :: Maybe ReasonControl -> Text -> Int -> Text -> Text
controlledReason control row step lean = case control of
    Just named
        | rcRow named == row, rcStep named == step -> rcReason named
    _ -> lean
