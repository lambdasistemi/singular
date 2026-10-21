{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.PlainJson
Description : A payload written as plain JSON, and read back as plain JSON
License     : Apache-2.0

A payload is Plutus data. The detailed schema ('datumFromJson') writes
any datum exactly and is how the previous release read every payload
file. The plain mapping lets a file hold ordinary JSON instead, mapped to
data by a table (#719):

* a whole number of at most 'plainDigitLimit' digits is the integer;
* a text is the byte string of its UTF-8;
* @true@ and @false@ are the constructors 1 and 0 without fields;
* an array is the list of its items;
* an object is the map from each key, as a byte string of its UTF-8, to
  its value, entries in ascending order of the key bytes;
* @null@ and a number with a fraction are refused.

'plainFromData' is the reading in the other direction: it returns the
JSON the table started from, and nothing for data the table could not
have produced. 'payloadView' chooses what a command prints: the plain
JSON when there is one, else the detailed schema, with the schema named.

Nothing here reads a file or names a command. The one place that reads a
payload file for a command is @Singular.CLI.Payload@.
-}
module Singular.Registry.PlainJson
    ( -- * The schema setting
      PayloadSchema (..)
    , schemaName
    , parseSchemaName

      -- * The plain mapping and its reading
    , plainDigitLimit
    , plainToData
    , plainFromData

      -- * Refusals
    , PlainRefusal (..)
    , PlainReason (..)
    , PathStep (..)
    , renderPlainRefusal

      -- * A payload document under a schema
    , payloadFromJson

      -- * What a command prints
    , PayloadView (..)
    , payloadView
    ) where

import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.List (sortOn)
import Data.Scientific (Scientific)
import Data.Scientific qualified as Sci
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import PlutusCore.Data qualified as PLC

import Singular.Registry.Application (datumFromJson, datumToJson)

-- | Which form a payload file is written in.
data PayloadSchema
    = -- | Plain JSON, mapped by the table
      PlainSchema
    | -- | The detailed Plutus data schema
      DetailedSchema
    deriving stock (Eq, Show)

-- | The lower-case name of a schema, as the flag spells it.
schemaName :: PayloadSchema -> Text
schemaName = \case
    PlainSchema -> "plain"
    DetailedSchema -> "detailed"

-- | The schema a flag value names: exactly the two names, in lower case.
parseSchemaName :: Text -> Maybe PayloadSchema
parseSchemaName = \case
    "plain" -> Just PlainSchema
    "detailed" -> Just DetailedSchema
    _ -> Nothing

-- | The most digits a stored whole number may have.
plainDigitLimit :: Int
plainDigitLimit = 1000

-- | One step from the document to the offending value.
data PathStep
    = -- | An object key
      KeyStep Text
    | -- | An array item
      IndexStep Int
    deriving stock (Eq, Show)

-- | Why a value has no Plutus data counterpart.
data PlainReason
    = -- | A number with a fraction
      HasFraction Scientific
    | -- | A whole number with more digits than the limit
      TooLarge Scientific
    | -- | @null@
      IsNull
    deriving stock (Eq, Show)

-- | A value the plain mapping refuses, and where it is.
data PlainRefusal = PlainRefusal
    { refusalPath :: [PathStep]
    -- ^ From the document: empty for the document itself
    , refusalReason :: PlainReason
    }
    deriving stock (Eq, Show)

{- | The sentence naming the value and its path, written as a path from
the document: @$@ is the whole document, @.name@ an object key, @[2]@ an
item.
-}
renderPlainRefusal :: PlainRefusal -> Text
renderPlainRefusal (PlainRefusal path reason) = case reason of
    IsNull ->
        "null at " <> at <> " has no Plutus data counterpart"
    HasFraction n ->
        "the number "
            <> renderNumber n
            <> " at "
            <> at
            <> " has a fraction; only whole numbers are stored"
    TooLarge n ->
        "the number at "
            <> at
            <> " is too large: more than "
            <> T.pack (show plainDigitLimit)
            <> " digits ("
            <> renderNumber n
            <> ")"
  where
    at = "$" <> T.concat (map step path)
    step = \case
        KeyStep k -> "." <> k
        IndexStep i -> "[" <> T.pack (show i) <> "]"

{- | A number as a reader writes it, without expanding a large exponent and
without printing thousands of digits.
-}
renderNumber :: Scientific -> Text
renderNumber n
    | abs exponent10 <= 30 =
        shorten (T.pack (Sci.formatScientific Sci.Fixed Nothing n))
    | otherwise =
        sign <> shortDigits <> "e" <> T.pack (show (exponent10 + zeros))
  where
    -- the exponent is an Int that may be minBound: all arithmetic on it is on Integer
    exponent10 = toInteger (Sci.base10Exponent n)
    (digits, zeros) = stripZeros (abs (Sci.coefficient n))
    sign = if Sci.coefficient n < 0 then "-" else ""
    shortDigits = shorten (T.pack (show digits))
    shorten t
        | T.length t <= shown = t
        | otherwise = T.take shown t <> "..."
    shown = 40

-- | What the digits and the sign of a number say about storing it.
data Whole
    = Whole Integer
    | Fractional
    | PastLimit

{- | A number judged by its size before it is expanded: normalised, a
number is whole when its exponent is not negative, and then it has the
digits of its coefficient followed by that many zeros.
-}
wholeOf :: Scientific -> Whole
wholeOf s
    | coefficient == 0 = Whole 0
    | e < 0 = Fractional
    | e >= toInteger plainDigitLimit = PastLimit
    | toInteger (integerDigits c) + e > toInteger plainDigitLimit =
        PastLimit
    | otherwise = Whole (c * 10 ^ e)
  where
    coefficient = Sci.coefficient s
    (c, zeros) = stripZeros coefficient
    -- the exponent is an Int that may be minBound or maxBound: the sum is an Integer
    e = toInteger (Sci.base10Exponent s) + zeros

{- | A coefficient without its trailing decimal zeros, and how many it had:
the zeros move into the exponent, which is then summed as an Integer so no
exponent an Int can hold overflows.
-}
stripZeros :: Integer -> (Integer, Integer)
stripZeros c =
    let stripped = Sci.normalize (Sci.scientific c 0)
    in  (Sci.coefficient stripped, toInteger (Sci.base10Exponent stripped))

-- | The number of decimal digits of an integer, its sign aside.
integerDigits :: Integer -> Int
integerDigits = length . show . abs

{- | The data a plain JSON document stands for, or the first value refused:
objects are walked in ascending order of the key bytes and arrays in
order, so the refusal is a function of the document.
-}
plainToData :: Value -> Either PlainRefusal PLC.Data
plainToData = go []
  where
    -- the path is kept last step first and written out only on a refusal
    go path = \case
        Null -> refuse path IsNull
        Bool b -> Right (PLC.Constr (if b then 1 else 0) [])
        String t -> Right (PLC.B (TE.encodeUtf8 t))
        Number n -> case wholeOf n of
            Whole i -> Right (PLC.I i)
            Fractional -> refuse path (HasFraction n)
            PastLimit -> refuse path (TooLarge n)
        Array xs ->
            PLC.List
                <$> traverse
                    (\(i, x) -> go (IndexStep i : path) x)
                    (zip [0 ..] (toList xs))
        Object o ->
            PLC.Map
                <$> traverse
                    ( \(bytes, key, x) -> do
                        value <- go (KeyStep key : path) x
                        pure (PLC.B bytes, value)
                    )
                    (keyed o)
    refuse path = Left . PlainRefusal (reverse path)
    keyed o =
        sortOn
            (\(bytes, _, _) -> bytes)
            [ (TE.encodeUtf8 key, key, x)
            | (k, x) <- KeyMap.toList o
            , let key = Key.toText k
            ]

{- | The plain JSON a datum stands for, when it has one: an integer of at
most 'plainDigitLimit' digits, a byte string that is UTF-8, a list of
items that have one, a map whose keys are UTF-8 byte strings in strictly
ascending order of bytes and whose values have one, and the constructors 0
and 1 without fields.
-}
plainFromData :: PLC.Data -> Maybe Value
plainFromData = \case
    PLC.I n
        | integerDigits n <= plainDigitLimit -> Just (Number (fromInteger n))
        | otherwise -> Nothing
    PLC.B bytes -> String <$> utf8 bytes
    PLC.List items -> Aeson.toJSON <$> traverse plainFromData items
    PLC.Map entries -> do
        keyed <- traverse entry entries
        let keys = [bytes | (bytes, _, _) <- keyed]
        if and (zipWith (<) keys (drop 1 keys))
            then
                Just $
                    Object $
                        KeyMap.fromList
                            [(Key.fromText key, x) | (_, key, x) <- keyed]
            else Nothing
    PLC.Constr 0 [] -> Just (Bool False)
    PLC.Constr 1 [] -> Just (Bool True)
    PLC.Constr _ _ -> Nothing
  where
    entry (k, v) = case k of
        PLC.B bytes -> do
            key <- utf8 bytes
            x <- plainFromData v
            Just (bytes, key, x)
        _ -> Nothing

-- | A byte string as text, when it is valid UTF-8.
utf8 :: ByteString -> Maybe Text
utf8 = either (const Nothing) Just . TE.decodeUtf8'

{- | A payload document read under a schema. The detailed schema is the
reader of the previous release, refusals unchanged. The plain schema
refuses a whole document that the detailed schema accepts, with the
instruction to say so, and only then maps.
-}
payloadFromJson :: PayloadSchema -> Value -> Either Text PLC.Data
payloadFromJson schema document = case schema of
    DetailedSchema -> either (Left . T.pack) Right (datumFromJson document)
    PlainSchema -> case datumFromJson document of
        Right _ -> Left detailedDocumentInPlainMode
        Left _ -> either (Left . renderPlainRefusal) Right (plainToData document)

-- | The sentence for a detailed-schema document read as plain JSON.
detailedDocumentInPlainMode :: Text
detailedDocumentInPlainMode =
    "the file is Plutus data in the detailed schema: say so with \
    \--payload-schema detailed, or nest it in an object to store it as plain \
    \JSON"

-- | What a command prints of a payload: the schema and the JSON in it.
data PayloadView = PayloadView
    { viewSchema :: PayloadSchema
    -- ^ The schema the JSON is in
    , viewJson :: Value
    -- ^ The payload: plain JSON, or the detailed schema of the data
    }
    deriving stock (Eq, Show)

{- | The plain reading when the data has one, else the detailed schema of
the data. Plain exactly when 'plainFromData' returns the JSON.
-}
payloadView :: PLC.Data -> PayloadView
payloadView d = case plainFromData d of
    Just json -> PayloadView PlainSchema json
    Nothing -> PayloadView DetailedSchema (datumToJson d)
