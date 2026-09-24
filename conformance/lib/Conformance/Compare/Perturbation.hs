-- | Discovered changes to every value the model declares observable.
module Conformance.Compare.Perturbation (
    Step (..),
    leafPaths,
    arrayPaths,
    perturbAt,
    appendAt,
    isLovelaceFloor,
    reportedDifferences,
    differingPaths,
    replacing,
    discoveredChanges,
    checkPerturbations,
) where

import Conformance.Compare.Registration (
    Declared (..),
    Difference (..),
    compareRegistration,
    outputFloorAgrees,
 )
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Foldable (toList)
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Vector qualified as V

data Step = Field Text | Index Int
    deriving (Eq, Show)

leafPaths :: Value -> [[Step]]
leafPaths value = case value of
    Object fields -> [Field (Key.toText name) : rest | (name, inner) <- KM.toList fields, rest <- leafPaths inner]
    Array entries -> [Index index : rest | (index, inner) <- zip [0 ..] (V.toList entries), rest <- leafPaths inner]
    _ -> [[]]

arrayPaths :: Value -> [[Step]]
arrayPaths value = case value of
    Object fields -> [Field (Key.toText name) : rest | (name, inner) <- KM.toList fields, rest <- arrayPaths inner]
    Array entries -> [] : [Index index : rest | (index, inner) <- zip [0 ..] (V.toList entries), rest <- arrayPaths inner]
    _ -> []

perturbAt :: [Step] -> Value -> Value
perturbAt [] value = case value of
    Number n -> Number (n + 1)
    String s -> String (s <> "-changed")
    Bool b -> Bool (not b)
    Null -> String "changed"
    other -> other
perturbAt (Field name : rest) value = case value of
    Object fields -> case KM.lookup (Key.fromText name) fields of
        Just inner -> Object (KM.insert (Key.fromText name) (perturbAt rest inner) fields)
        Nothing -> value
    _ -> value
perturbAt (Index index : rest) value = case value of
    Array entries | index < V.length entries -> Array (entries V.// [(index, perturbAt rest (entries V.! index))])
    _ -> value

appendAt :: [Step] -> Value -> Value
appendAt [] value = case value of
    Array entries -> Array (V.snoc entries (String "appended"))
    other -> other
appendAt (Field name : rest) value = case value of
    Object fields -> case KM.lookup (Key.fromText name) fields of
        Just inner -> Object (KM.insert (Key.fromText name) (appendAt rest inner) fields)
        Nothing -> value
    _ -> value
appendAt (Index index : rest) value = case value of
    Array entries | index < V.length entries -> Array (entries V.// [(index, appendAt rest (entries V.! index))])
    _ -> value

{- | A leaf the model states as a lovelace floor: a transaction output's
lovelace, and a payment's value in @paid@ and in the transaction's refunds.
-}
isLovelaceFloor :: Text -> [Step] -> Bool
isLovelaceFloor "tx" [Field "outputs", Index _, Field "lovelace"] = True
isLovelaceFloor "tx" [Field "refunds", Index _, Field "value"] = True
isLovelaceFloor "paid" [Index _, Field "value"] = True
isLovelaceFloor _ _ = False

{- | Every path at which a reported difference's two sides differ, down to a
leaf or to an array whose length differs.
-}
reportedDifferences :: [Difference] -> [(Text, [Step])]
reportedDifferences differences =
    [ (name, path)
    | difference <- differences
    , let name = differenceObservation difference
    , path <- differingPaths (differenceExpected difference) (differenceObserved difference)
    , not (surplusFloor name path difference)
    ]

surplusFloor :: Text -> [Step] -> Difference -> Bool
surplusFloor name path difference
    | isLovelaceFloor name path = case ( valueAt path (differenceExpected difference)
                                       , valueAt path (differenceObserved difference)
                                       ) of
        (Just expected, Just observed) -> outputFloorAgrees expected observed
        _ -> False
    | otherwise = False

differingPaths :: Value -> Value -> [[Step]]
differingPaths left right
    | left == right = []
    | otherwise = case (left, right) of
        (Object l, Object r) ->
            [ Field (Key.toText name) : rest
            | name <- nub (KM.keys l <> KM.keys r)
            , rest <- case (KM.lookup name l, KM.lookup name r) of
                (Just a, Just b) -> differingPaths a b
                _ -> [[]]
            ]
        (Array l, Array r)
            | length l == length r ->
                [ Index index : rest
                | (index, a, b) <- zip3 [0 ..] (toList l) (toList r)
                , rest <- differingPaths a b
                ]
        _ -> [[]]

replacing :: Text -> Value -> Value -> Value
replacing name inner value = case value of
    Object fields -> Object (KM.insert (Key.fromText name) inner fields)
    _ -> value

-- | The same walk is used by the appendix and every live comparison.
discoveredChanges :: Declared -> Value -> [(Text, [Step], Value)]
discoveredChanges declared observations =
    [ (name, path, replacing name (perturbAt path inner) observations)
    | name <- declaredObservations declared
    , Just inner <- [observationAt name observations]
    , path <- leafPaths inner
    ]
        <> [ (name, path, replacing name (appendAt path inner) observations)
           | name <- declaredObservations declared
           , Just inner <- [observationAt name observations]
           , path <- arrayPaths inner
           ]

observationAt :: Text -> Value -> Maybe Value
observationAt name value = case value of
    Object fields -> KM.lookup (Key.fromText name) fields
    _ -> Nothing

valueAt :: [Step] -> Value -> Maybe Value
valueAt [] value = Just value
valueAt (Field name : rest) value = case value of
    Object fields -> KM.lookup (Key.fromText name) fields >>= valueAt rest
    _ -> Nothing
valueAt (Index index : rest) value = case value of
    Array entries | index >= 0 && index < V.length entries -> valueAt rest (entries V.! index)
    _ -> Nothing

replaceAt :: [Step] -> Value -> Value -> Value
replaceAt [] replacement _ = replacement
replaceAt (Field name : rest) replacement value = case value of
    Object fields -> case KM.lookup (Key.fromText name) fields of
        Just inner ->
            Object (KM.insert (Key.fromText name) (replaceAt rest replacement inner) fields)
        Nothing -> value
    _ -> value
replaceAt (Index index : rest) replacement value = case value of
    Array entries
        | index >= 0 && index < V.length entries ->
            Array (entries V.// [(index, replaceAt rest replacement (entries V.! index))])
    _ -> value

loweredOutputFloors :: Declared -> Value -> Value -> [(Text, [Step], Value)]
loweredOutputFloors declared expected observed =
    [ (name, path, replacing name (replaceAt path (Number (modelFloor - 1)) actual) observed)
    | name <- declaredObservations declared
    , Just model <- [observationAt name expected]
    , Just actual <- [observationAt name observed]
    , path <- leafPaths model
    , isLovelaceFloor name path
    , Just (Number modelFloor) <- [valueAt path model]
    ]

{- | Count every refused change by the observation the comparator named.
The sole allowed passing change is surplus above a lovelace floor.
-}
checkPerturbations :: Declared -> Value -> Value -> Either String (Int, Map.Map Text Int, [String])
checkPerturbations declared expected observed = do
    let changes = discoveredChanges declared observed
        lowerings = loweredOutputFloors declared expected observed
        absent = [name | name <- declaredObservations declared, all (\(n, _, _) -> n /= name) changes]
    if null absent then pure () else Left ("no discovered changes for " <> show absent)
    results <- mapM check changes
    lowered <- mapM checkLowering lowerings
    let refused = [name | Just name <- results <> lowered]
        exempt = [show path | ((name, path, _), Nothing) <- zip changes results, isLovelaceFloor name path]
    pure (length refused, Map.fromListWith (+) [(name, 1) | name <- refused], exempt)
  where
    check (name, path, changed)
        | isLovelaceFloor name path = case compareRegistration declared expected changed of
            Right _ -> Right Nothing
            Left differences -> Left ("outputMinimumAda was compared at " <> show path <> ": " <> show differences)
        | otherwise = case compareRegistration declared expected changed of
            Right _ -> Left ("changed " <> show name <> " at " <> show path <> " was accepted")
            Left differences
                | name `elem` map differenceObservation differences -> Right (Just name)
                | otherwise -> Left ("changed " <> show name <> " at " <> show path <> " was attributed elsewhere: " <> show differences)
    checkLowering (name, path, changed) = case compareRegistration declared expected changed of
        Right _ -> Left ("lowered output lovelace below the model floor at " <> show path <> " was accepted")
        Left differences
            | name `elem` map differenceObservation differences -> Right (Just name)
            | otherwise -> Left ("lowered output lovelace at " <> show path <> " was attributed elsewhere: " <> show differences)
