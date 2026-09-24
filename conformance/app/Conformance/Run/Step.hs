{- |
Module      : Conformance.Run.Step
Description : What the chain answered to a live step, and which transaction the model judges
License     : Apache-2.0
-}
module Conformance.Run.Step (
    StepOutcome (..),
    StepRejection (..),
    refusedOutcome,
    judgedTransaction,
    storyRefusalTag,
) where

import Data.Aeson (Value (..))
import Data.List (isInfixOf)
import Data.Text qualified as T

import Cardano.Tx.Ledger (ConwayTx)

import Conformance.PurposeUnits (
    PurposeMeasurements,
    PurposeUnits,
 )
import Conformance.Refusal (
    matchRefusal,
    refusalScriptHashes,
 )

-- The live interpreter's handles contain values observed during this run.
-- They cannot be constructed by a story or supplied by a JSON fixture.
data StepOutcome
    = StepAccepted ConwayTx (Integer, Integer, Integer)
    | StepRefused ConwayTx (Maybe T.Text) [T.Text] StepRejection
    | -- | Nothing a script refused: the submitted transaction, if one was.
      StepUnsupported (Maybe ConwayTx) T.Text (Maybe StepRejection)

data StepRejection = StepRejection
    { srText :: T.Text
    , srMeasured :: PurposeMeasurements
    , srDeclared :: PurposeUnits
    , srBudgetExceeded :: [T.Text]
    }

{- | The chain's answer to a submitted transaction the node rejected: a budget
refusal, a refusal attributed to the script whose applied hash is @marker@, or
an unattributed rejection.
-}
refusedOutcome :: String -> ConwayTx -> StepRejection -> StepOutcome
refusedOutcome marker signed diagnostic =
    if not (null (srBudgetExceeded diagnostic))
        then StepRefused signed Nothing [] diagnostic
        else case matchRefusal marker explanation of
            Right () -> StepRefused signed (storyRefusalTag explanation)
                (map T.pack (refusalScriptHashes explanation)) diagnostic
            Left _ -> StepUnsupported (Just signed) (T.pack ("unattributed node rejection: " <> explanation)) (Just diagnostic)
  where
    explanation = T.unpack (srText diagnostic)

{- | The transaction the driver judges once the law accepts the step: the one
submitted, whatever the chain answered to it.
-}
judgedTransaction :: Value -> StepOutcome -> Maybe ConwayTx
judgedTransaction lawOutcome outcome = case (lawOutcome, outcome) of
    (String "accepted", StepAccepted transaction _) -> Just transaction
    (String "accepted", StepRefused transaction _ _ _) -> Just transaction
    (String "accepted", StepUnsupported submitted _ _) -> submitted
    _ -> Nothing

storyRefusalTag :: String -> Maybe T.Text
storyRefusalTag text =
    case [n | n <- ["key-exists", "not-booked", "key-unknown"], n `isInfixOf` text] of
        (n : _) -> Just (T.pack n)
        [] -> Nothing
