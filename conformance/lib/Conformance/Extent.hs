{-# LANGUAGE LambdaCase #-}

{- |
Module      : Conformance.Extent
Description : Every live refusal of a run, classified against the model
License     : Apache-2.0

The replay index of a run names every refusal its live rows met. A refusal
whose step carried an executed model reason is class A by fact: the runner
records it, and its reason must agree with the traced replay's or be
uncompared with a named cause. Every other refusal must be listed, by its
row, in the committed table of the extent document as B, C or D; one that is
not is unclassified, and fails. The index must also name each refusal the
run's receipts record exactly once, and an accepting control for each script
role that refused.

Pure: the index entries, the receipts and the document arrive as data.
-}
module Conformance.Extent
    ( ExtentClass (..)
    , Listed (..)
    , committedClasses
    , ExtentCount (..)
    , extentProblems
    , extentCount
    ) where

import Conformance.Receipt (Outcome (..), Receipt (..))
import Conformance.Replay (acceptingControlGaps)
import Control.Applicative ((<|>))
import Control.Monad (foldM)
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Foldable (find, toList)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T

-- | A class the committed table gives a refusal no model reason was executed for.
data ExtentClass
    = -- | Lean returns a reason; no consumer executes the model on the behavior
      ClassB
    | -- | Lean cannot express the behavior
      ClassC
    | -- | Lean's outcome differs from the chain's or the consumer model's
      ClassD
    deriving stock (Show, Eq, Ord)

{- | What the committed table says of one row: its class, and the traced
reasons and unobserved causes its refusals may carry, the backquoted names of
its traced-reason cell. A refusal of a listed row whose replay records any
other reason or cause is not the refusal the table classified.
-}
data Listed = Listed
    { listedClass :: ExtentClass
    , listedTraces :: [Text]
    }
    deriving stock (Show, Eq)

{- | The committed table of the extent document — the section headed
@Discovered table@ — as what it lists of each row. A class cell must start with
B, C or D; a row listed twice must keep its class, and its traces accumulate.
-}
committedClasses :: Text -> Either String (Map Text Listed)
committedClasses document = case break discovered (T.lines document) of
    (_, []) -> Left "the document has no discovered table"
    (_, _ : section) -> do
        let rows =
                [ cells line
                | line <- takeWhile (not . ("## " `T.isPrefixOf`)) section
                , "|" `T.isPrefixOf` T.strip line
                , not ("|---" `T.isPrefixOf` T.strip line)
                ]
        classes <- traverse classOf (drop 1 rows)
        if null classes
            then Left "the discovered table lists no row"
            else foldM insertOnce Map.empty classes
  where
    discovered = ("## Discovered table" `T.isPrefixOf`)
    cells =
        map T.strip
            . reverse
            . drop 1
            . reverse
            . drop 1
            . T.splitOn "|"
            . T.strip
    classOf row = case (row, reverse row) of
        (name : _, cell : _) -> case T.uncons cell of
            Just ('B', _) -> Right (name, Listed ClassB (traces row))
            Just ('C', _) -> Right (name, Listed ClassC (traces row))
            Just ('D', _) -> Right (name, Listed ClassD (traces row))
            _ ->
                Left
                    ( "row "
                        <> T.unpack name
                        <> ": class "
                        <> show cell
                        <> " is not B, C or D"
                    )
        _ -> Left "a table row with no cells"
    -- The backquoted names of the traced-reason cell, the third.
    traces = \case
        _ : _ : cell : _ ->
            [name | (i, name) <- zip [0 :: Int ..] (T.splitOn "`" cell), odd i]
        _ -> []
    insertOnce acc (name, listed) = case Map.lookup name acc of
        Just other
            | listedClass other /= listedClass listed ->
                Left ("row " <> T.unpack name <> " is listed with two classes")
            | otherwise ->
                Right
                    ( Map.insert
                        name
                        other{listedTraces = listedTraces other <> listedTraces listed}
                        acc
                    )
        Nothing -> Right (Map.insert name listed acc)

-- | How many refusals of a run fall in each class.
data ExtentCount = ExtentCount
    { countA :: Int
    , countTable :: Map ExtentClass Int
    }
    deriving stock (Show, Eq)

-- | The refusals of a run, by class: A by fact, the others by the table.
extentCount :: Map Text Listed -> [Value] -> ExtentCount
extentCount table entries =
    ExtentCount
        { countA = length [() | e <- refusals entries, isJust (modelReasonOf e)]
        , countTable =
            Map.fromListWith
                (+)
                [ (cls, 1)
                | e <- refusals entries
                , isNothing (modelReasonOf e)
                , Just cls <-
                    [listedClass <$> (flip Map.lookup table =<< textOf "row" e)]
                ]
        }

{- | What a run's replay index and receipts lack for the extent: one line per
problem, none when every refusal is accounted for.
-}
extentProblems
    :: Map Text Listed -> [Value] -> [Receipt] -> [Text]
extentProblems table entries receipts =
    [ "no refusal in the replay index: the run proves nothing"
    | null indexed
    ]
        <> [ "refusal "
                <> txid
                <> " is named "
                <> T.pack (show n)
                <> " times in the replay index"
           | (txid, n) <-
                Map.toList (Map.fromListWith (+) [(t, 1 :: Int) | t <- txids])
           , n > 1
           ]
        <> [ "refusal "
                <> txid
                <> " of "
                <> receiptRow r
                <> " is in its receipt but not in the replay index"
           | (r, txid, _) <- recorded
           , txid `notElem` txids
           ]
        <> [ "refusal "
                <> txid
                <> " of "
                <> receiptRow r
                <> ": its step carries the model's reason "
                <> reason
                <> ", the replay index records "
                <> fromMaybe "none" (modelReasonOf =<< entryOf txid)
           | (r, txid, Just reason) <- recorded
           , txid `elem` txids
           , (modelReasonOf =<< entryOf txid) /= Just reason
           ]
        <> concatMap classProblems indexed
        <> acceptingControlGaps entries
  where
    indexed = refusals entries
    txids = mapMaybe (textOf "rejectedTxId") indexed
    entryOf txid = find ((== Just txid) . textOf "rejectedTxId") indexed
    recorded =
        concat
            [ case receiptSteps r of
                Just steps ->
                    [ (r, txid, stepReason step)
                    | step <- steps
                    , (jsonText "outcome" =<< jsonField "chain" step)
                        == Just "refused"
                    , Just txid <- [jsonText "txid" =<< jsonField "chain" step]
                    ]
                Nothing ->
                    [ (r, txid, Nothing)
                    | receiptOutcome r == Refused
                    , Just txid <- [receiptRejected r]
                    ]
            | r <- receipts
            ]
    stepReason step = case jsonField "model" step of
        Just model
            | jsonText "outcome" model == Just "refused" ->
                jsonText "reason" model
        _ -> Nothing
    classProblems e =
        let txid = fromMaybe "?" (textOf "rejectedTxId" e)
            row = fromMaybe "?" (textOf "row" e)
            name = "refusal " <> txid <> " of " <> row
            label = textOf "extentClass" e
        in  case modelReasonOf e of
                Just reason
                    | label /= Just "A" ->
                        [ name
                            <> " carries the executed model reason "
                            <> reason
                            <> " but is labelled "
                            <> fromMaybe "nothing" label
                            <> ", not A"
                        ]
                    | otherwise -> case textOf "comparison" e of
                        Just "agrees" -> []
                        Just "uncompared"
                            | namesCause e -> []
                            | otherwise -> [name <> " is uncompared without a named cause"]
                        Just "differs" ->
                            [name <> ": the replay's reason differs from the model's"]
                        other ->
                            [ name
                                <> " is class A with no comparison ("
                                <> fromMaybe "none" other
                                <> ")"
                            ]
                Nothing
                    | label == Just "A" ->
                        [name <> " is labelled A without an executed model reason"]
                    | Just listed <- Map.lookup row table ->
                        [ name
                            <> " records "
                            <> trace
                            <> ", which the committed table does not list for "
                            <> row
                        | trace <- recordedTraces e
                        , trace `notElem` listedTraces listed
                        ]
                    | otherwise ->
                        [ name
                            <> " is unclassified: "
                            <> row
                            <> " is not in the committed table"
                        ]
    -- What a refusal's replay recorded, purpose by purpose: the reason it
    -- admitted or the cause it admits none.
    recordedTraces e = case jsonField "classes" e of
        Just (Array classes) ->
            [ t
            | c <- toList classes
            , Just t <- [jsonText "admitted" c <|> jsonText "unobserved" c]
            ]
        _ -> ["no replay"]
    namesCause e = case jsonField "classes" e of
        Just (Array classes) ->
            any (isJust . jsonText "unobserved") classes
        _ -> False

refusals :: [Value] -> [Value]
refusals = filter ((== Just "refusal") . textOf "kind")

modelReasonOf :: Value -> Maybe Text
modelReasonOf = textOf "modelReason"

textOf :: Key.Key -> Value -> Maybe Text
textOf = jsonText

jsonText :: Key.Key -> Value -> Maybe Text
jsonText name value = case jsonField name value of
    Just (String t) -> Just t
    _ -> Nothing

jsonField :: Key.Key -> Value -> Maybe Value
jsonField name = \case
    Object fields -> KM.lookup name fields
    _ -> Nothing
