-- | Discovered changes to every value the model declares observable.
module Conformance.Compare.Perturbation (
    Step (..), leafPaths, arrayPaths, perturbAt, appendAt,
    isOutputMinimumAda, replacing, discoveredChanges, checkPerturbations,
) where

import Conformance.Compare.Registration (Declared (..), Difference (..), compareRegistration)
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
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

isOutputMinimumAda :: Text -> [Step] -> Bool
isOutputMinimumAda "tx" [Field "outputs", Index _, Field "lovelace"] = True
isOutputMinimumAda _ _ = False

replacing :: Text -> Value -> Value -> Value
replacing name inner value = case value of
    Object fields -> Object (KM.insert (Key.fromText name) inner fields)
    _ -> value

-- | The same walk is used by the appendix and every live comparison.
discoveredChanges :: Declared -> Value -> [(Text, [Step], Value)]
discoveredChanges declared observations =
    [ (name, path, replacing name (perturbAt path inner) observations)
    | name <- declaredObservations declared
    , Just inner <- [at name observations]
    , path <- leafPaths inner
    ]
    <> [ (name, path, replacing name (appendAt path inner) observations)
       | name <- declaredObservations declared
       , Just inner <- [at name observations]
       , path <- arrayPaths inner
       ]
  where
    at name value = case value of
        Object fields -> KM.lookup (Key.fromText name) fields
        _ -> Nothing

-- | Count every refused change by the observation the comparator named.
-- The sole allowed passing change is a transaction output's minimum ada.
checkPerturbations :: Declared -> Value -> Value -> Either String (Int, Map.Map Text Int, [String])
checkPerturbations declared expected observed = do
    let changes = discoveredChanges declared observed
        absent = [name | name <- declaredObservations declared, all (\(n, _, _) -> n /= name) changes]
    if null absent then pure () else Left ("no discovered changes for " <> show absent)
    results <- mapM check changes
    let refused = [name | Just name <- results]
        exempt = [show path | ((name, path, _), Nothing) <- zip changes results, isOutputMinimumAda name path]
    pure (length refused, Map.fromListWith (+) [(name, 1) | name <- refused], exempt)
  where
    check (name, path, changed)
        | isOutputMinimumAda name path = case compareRegistration declared expected changed of
            Right _ -> Right Nothing
            Left differences -> Left ("outputMinimumAda was compared at " <> show path <> ": " <> show differences)
        | otherwise = case compareRegistration declared expected changed of
            Right _ -> Left ("changed " <> show name <> " at " <> show path <> " was accepted")
            Left differences
                | name `elem` map differenceObservation differences -> Right (Just name)
                | otherwise -> Left ("changed " <> show name <> " at " <> show path <> " was attributed elsewhere: " <> show differences)
