{- |
Module      : Conformance.Rows
Description : The 40-row consumer inventory and its validation
License     : Apache-2.0

The complete consumer-row inventory from @rows.json@: id, group,
requirement, source, expected outcome and state. @list@ prints it;
@validateInventory@ enforces the issue #63 denominator — exactly 40
rows, unique ids — so a truncated inventory fails loudly instead of
printing a smaller-but-plausible table.
-}
module Conformance.Rows (
    Row (..),
    RowState (..),
    expectedRowCount,
    loadRows,
    validateInventory,
    renderInventory,
) where

import Data.Aeson (
    FromJSON (..),
    eitherDecode,
    withObject,
    withText,
    (.:),
    (.:?),
 )
import Data.ByteString.Lazy qualified as BSL
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as T

{- | The issue #63 acceptance denominator: @list@ prints all 40 rows.
Fixed for the epic: CK06 (cardano-keri's checkpoint policy) is out of
scope and recorded in docs\/consumer-conformance.md, never claimed.
-}
expectedRowCount :: Int
expectedRowCount = 40

-- | Row execution state. Only rows actually executed on a devnet may
-- print @executed@.
data RowState
    = Executed
    | BoundElsewhere
    | Uncovered
    | OutOfScope
    deriving stock (Show, Eq, Ord)

instance FromJSON RowState where
    parseJSON = withText "RowState" $ \t -> case t of
        "executed" -> pure Executed
        "bound-elsewhere" -> pure BoundElsewhere
        "uncovered" -> pure Uncovered
        "out-of-scope" -> pure OutOfScope
        _ -> fail ("unknown row state: " <> T.unpack t)

-- | One consumer conformance row.
data Row = Row
    { rowId :: !Text
    , rowGroup :: !Text
    , rowRequirement :: !Text
    , rowSource :: !Text
    , rowExpected :: !Text
    , rowState :: !RowState
    , rowNote :: !(Maybe Text)
    , rowEvidence :: !(Maybe Text)
    }
    deriving stock (Show, Eq)

instance FromJSON Row where
    parseJSON = withObject "Row" $ \o ->
        Row
            <$> o .: "id"
            <*> o .: "group"
            <*> o .: "requirement"
            <*> o .: "source"
            <*> o .: "expected"
            <*> o .: "state"
            <*> o .:? "note"
            <*> o .:? "evidence"

newtype Inventory = Inventory {inventoryRows :: [Row]}

instance FromJSON Inventory where
    parseJSON = withObject "Inventory" $ \o ->
        Inventory <$> o .: "rows"

-- | Load and validate the inventory file.
loadRows :: FilePath -> IO (Either String [Row])
loadRows path = do
    content <- BSL.readFile path
    pure $ case eitherDecode content of
        Left err -> Left ("rows.json does not parse: " <> err)
        Right inv -> validateInventory (inventoryRows inv)

{- | Enforce the denominator: exactly 'expectedRowCount' rows, unique
ids, non-empty groups. A count over a silently shortened set is a
lower bound wearing the denominator's name, so short is an error,
not a smaller table.
-}
validateInventory :: [Row] -> Either String [Row]
validateInventory rows
    | null rows = Left "inventory is empty"
    | length rows /= expectedRowCount =
        Left
            ( "inventory carries "
                <> show (length rows)
                <> " rows, expected "
                <> show expectedRowCount
            )
    | length (nub ids) /= length ids =
        Left "inventory has duplicate row ids"
    | any T.null (map rowGroup rows) =
        Left "inventory has a row with an empty group"
    | otherwise = Right rows
  where
    ids = map rowId rows

-- | Render the full inventory table plus the state summary.
renderInventory :: [Row] -> Text
renderInventory rows =
    T.unlines (header : map renderRow sorted <> ["", summary])
  where
    sorted = sort rows
    header =
        "id\tgroup\texpected\tstate\trequirement"
    summary =
        T.pack (show (length rows))
            <> " rows: "
            <> T.intercalate ", " (map countFor states)
    states = [Executed, BoundElsewhere, Uncovered, OutOfScope]
    countFor s =
        T.pack (show (length (filter ((== s) . rowState) rows)))
            <> " "
            <> stateName s

renderRow :: Row -> Text
renderRow r =
    T.intercalate
        "\t"
        [ rowId r
        , rowGroup r
        , rowExpected r
        , stateName (rowState r)
        , rowRequirement r
        ]

stateName :: RowState -> Text
stateName Executed = "executed"
stateName BoundElsewhere = "bound-elsewhere"
stateName Uncovered = "uncovered"
stateName OutOfScope = "out-of-scope"

-- Rows sort by id for a stable table.
instance Ord Row where
    compare a b = compare (rowId a) (rowId b)
