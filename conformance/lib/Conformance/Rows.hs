{- |
Module      : Conformance.Rows
Description : The 41-row consumer inventory and its validation
License     : Apache-2.0

The complete consumer-row inventory from @rows.json@: id, group,
requirement, source, expected outcome and declared plan. @list@
prints it; @validateInventory@ enforces the denominator — 41 rows,
40 owned — so a truncated inventory fails loudly instead of printing
a smaller-but-plausible table.

@executed@ is not a value @rows.json@ can carry: the declared field
is the coverage plan (@uncovered@, @bound-elsewhere@,
@out-of-scope@) and the parser rejects @executed@. A row prints as
executed only when 'effectiveState' finds a matching run receipt
(see "Conformance.Receipt").
-}
module Conformance.Rows (
    Row (..),
    RowState (..),
    ShownState (..),
    expectedRowCount,
    ownedDenominator,
    loadRows,
    validateInventory,
    effectiveState,
    renderInventory,
    renderRow,
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

import Conformance.Receipt (Receipt (..))

{- | Total rows in @rows.json@: the 40 owned consumer rows plus CK06,
cardano-keri's checkpoint policy, recorded as out-of-scope so the
boundary is visible instead of forgotten.
-}
expectedRowCount :: Int
expectedRowCount = 41

{- | Rows Singular owns and must eventually evidence. Out-of-scope
rows (CK06) are carried for the boundary, never counted.
-}
ownedDenominator :: Int
ownedDenominator = 40

{- | A row's declared coverage plan. @executed@ is unrepresentable
here by construction: only a run receipt can establish it.
-}
data RowState
    = Uncovered
    | BoundElsewhere
    | OutOfScope
    deriving stock (Show, Eq, Ord)

instance FromJSON RowState where
    parseJSON = withText "RowState" $ \t -> case t of
        "uncovered" -> pure Uncovered
        "bound-elsewhere" -> pure BoundElsewhere
        "out-of-scope" -> pure OutOfScope
        "executed" ->
            fail
                "rejected: executed is a receipt, not a field — \
                \rows.json carries the plan; a run receipt establishes \
                \execution"
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

{- | Enforce the denominator: exactly 'expectedRowCount' rows of which
'exactly' 'ownedDenominator' are owned, unique ids, non-empty groups.
A count over a silently shortened set is a lower bound wearing the
denominator's name, so short is an error, not a smaller table.
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
    | owned /= ownedDenominator =
        Left
            ( "inventory owns "
                <> show owned
                <> " rows, expected owned denominator "
                <> show ownedDenominator
            )
    | length (nub ids) /= length ids =
        Left "inventory has duplicate row ids"
    | any T.null (map rowGroup rows) =
        Left "inventory has a row with an empty group"
    | otherwise = Right rows
  where
    ids = map rowId rows
    owned =
        length
            (filter ((/= OutOfScope) . rowState) rows)

{- | What @list@ prints for a row: executed iff a receipt for it
exists and matches the current base, else the declared plan.
-}
data ShownState
    = ShownExecuted
    | ShownPlanned RowState
    deriving stock (Show, Eq, Ord)

effectiveState :: Text -> [Receipt] -> Row -> ShownState
effectiveState base receipts row =
    case [ r
         | r <- receipts
         , receiptRow r == rowId row
         , receiptBase r == base
         ] of
        (_ : _) -> ShownExecuted
        [] -> ShownPlanned (rowState row)

{- | Render the full inventory table plus the state summary. The
summary counts effective states and names the owned denominator
with the out-of-scope rows excluded from it.
-}
renderInventory :: Text -> [Receipt] -> [Row] -> Text
renderInventory base receipts rows =
    T.unlines
        ( header
            : map (renderRow . shown) sorted
                <> ["", summary, ownedLine]
        )
  where
    sorted = sort rows
    shown r = (r, effectiveState base receipts r)
    header =
        "id\tgroup\texpected\tstate\trequirement"
    states =
        [ ShownExecuted
        , ShownPlanned BoundElsewhere
        , ShownPlanned Uncovered
        , ShownPlanned OutOfScope
        ]
    summary =
        T.pack (show (length rows))
            <> " rows: "
            <> T.intercalate ", " (map countFor states)
    countFor s =
        T.pack
            ( show
                ( length
                    ( filter
                        ((== s) . effectiveState base receipts)
                        rows
                    )
                )
            )
            <> " "
            <> shownName s
    ownedLine =
        "owned denominator: "
            <> T.pack (show ownedDenominator)
            <> " ("
            <> T.intercalate
                ", "
                [ rowId r
                | r <- rows
                , rowState r == OutOfScope
                ]
            <> " out of scope)"

renderRow :: (Row, ShownState) -> Text
renderRow (r, s) =
    T.intercalate
        "\t"
        [ rowId r
        , rowGroup r
        , rowExpected r
        , shownName s
        , rowRequirement r
        ]

shownName :: ShownState -> Text
shownName ShownExecuted = "executed"
shownName (ShownPlanned Uncovered) = "uncovered"
shownName (ShownPlanned BoundElsewhere) = "bound-elsewhere"
shownName (ShownPlanned OutOfScope) = "out-of-scope"

-- Rows sort by id for a stable table.
instance Ord Row where
    compare a b = compare (rowId a) (rowId b)
