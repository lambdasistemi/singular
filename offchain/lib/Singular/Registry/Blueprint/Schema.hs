{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.Blueprint.Schema
Description : CIP-57 blueprint schema types, JSON parsing and validation
License     : Apache-2.0

The CIP-57 schema model behind 'Singular.Registry.Blueprint': the
'Blueprint', 'Validator', 'Schema' and 'Constructor' types with their
Aeson parsers, and 'validateData' for checking 'PlutusCore.Data.Data'
values against a declared schema.

This is the schema-and-validation owner extracted from
@Singular.Registry.Blueprint@; the public module re-exports it and is
its only intended consumer surface.
-}
module Singular.Registry.Blueprint.Schema (
    -- * Schema types
    Blueprint (..),
    Validator (..),
    Schema (..),
    Constructor (..),

    -- * Validation
    validateData,
) where

import Data.Aeson (
    FromJSON (..),
    Value,
    withObject,
    (.:),
    (.:?),
 )
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import PlutusCore.Data (Data (..))

-- | A single constructor alternative in a schema.
data Constructor = Constructor
    { conIndex :: Integer
    -- ^ Constructor tag (matches Aiken's Constr index)
    , conFields :: [Schema]
    -- ^ Schemas for each positional field
    }
    deriving stock (Show, Eq)

-- | CIP-57 schema for a Plutus data type.
data Schema
    = -- | @{"dataType": "bytes"}@
      SBytes
    | -- | @{"dataType": "integer"}@
      SInteger
    | {- | @{"dataType": "list", "items": <one schema>}@ — a
      homogeneous list of any length.
      -}
      SList Schema
    | {- | @{"dataType": "list", "items": [<schema>, ...]}@ — Aiken's
      FIXED TUPLE (#157 D-DEST): an ARRAY of positional item
      schemas. On the wire it is a Plutus @List@ of exactly that
      arity, each element of its own declared type, which is what
      distinguishes it from 'SList' and why it cannot share that
      case: a homogeneous rule would accept a three-element pair.
      -}
      STuple [Schema]
    | -- | @{"anyOf": [...constructors...]}@
      SConstructors [Constructor]
    | -- | @{"$ref": "#/definitions/..."}@
      SRef Text
    deriving stock (Show, Eq)

-- | A validator entry in the blueprint.
data Validator = Validator
    { vTitle :: Text
    -- ^ Human-readable validator name
    , vDatum :: Maybe Schema
    -- ^ Datum schema, absent for minting validators
    , vRedeemer :: Schema
    -- ^ Redeemer schema
    , vHash :: Text
    -- ^ Hex-encoded script hash (28 bytes)
    , vCompiledCode :: Maybe Text
    -- ^ Hex-encoded double-CBOR PlutusV3 script
    , vParameters :: Int
    {- ^ How many parameters this validator applies. A blueprint omits
    the array entirely for a parameterless validator, so an absent
    `parameters` key reads as zero. This is what makes a
    parameterless policy's compiled hash its policy id, with no
    applied hash to derive, so a consumer that wants to state it
    should READ it here rather than write the number down.
    -}
    }
    deriving stock (Show, Eq)

-- | A parsed CIP-57 blueprint.
data Blueprint = Blueprint
    { validators :: [Validator]
    -- ^ All validator entries in the blueprint
    , definitions :: Map Text Schema
    -- ^ Named type definitions referenced by @$ref@
    }
    deriving stock (Show, Eq)

-- ---------------------------------------------------------
-- JSON parsing
-- ---------------------------------------------------------

instance FromJSON Constructor where
    parseJSON = withObject "Constructor" $ \o -> do
        idx <- o .: "index"
        fields <- o .: "fields"
        pure
            Constructor
                { conIndex = idx
                , conFields = fields
                }

instance FromJSON Schema where
    parseJSON = withObject "Schema" $ \o -> do
        mRef <- o .:? "$ref"
        case mRef of
            Just ref -> pure $ SRef (parseRef ref)
            Nothing -> do
                mAnyOf <- o .:? "anyOf"
                case mAnyOf of
                    Just cs ->
                        pure $ SConstructors cs
                    Nothing -> do
                        mDataType <-
                            o .:? "dataType" ::
                                Parser
                                    (Maybe Text)
                        case mDataType of
                            Just "bytes" ->
                                pure SBytes
                            Just "integer" ->
                                pure SInteger
                            Just "list" -> do
                                -- The JSON itself says which one this
                                -- is: an ARRAY of item schemas is
                                -- Aiken's fixed tuple, anything else is
                                -- a homogeneous list. Branching on the
                                -- shape rather than trying one and
                                -- falling back keeps both cases exact —
                                -- a malformed tuple stays an error
                                -- instead of silently becoming a list.
                                items <-
                                    o .: "items" ::
                                        Parser Aeson.Value
                                case items of
                                    Aeson.Array _ ->
                                        STuple <$> parseJSON items
                                    _ -> SList <$> parseJSON items
                            Just "constructor" -> do
                                idx <- o .: "index"
                                fields <-
                                    o .: "fields"
                                pure $
                                    SConstructors
                                        [ Constructor
                                            idx
                                            fields
                                        ]
                            _ -> pure SBytes

instance FromJSON Validator where
    parseJSON = withObject "Validator" $ \o -> do
        title <- o .: "title"
        datumObj <- o .:? "datum"
        datum <- case datumObj of
            Just d -> do
                s <- d .: "schema"
                pure (Just s)
            Nothing -> pure Nothing
        redeemerObj <- o .: "redeemer"
        redeemer <- redeemerObj .: "schema"
        h <- o .: "hash"
        code <- o .:? "compiledCode"
        params <- o .:? "parameters"
        pure
            Validator
                { vTitle = title
                , vDatum = datum
                , vRedeemer = redeemer
                , vHash = h
                , vCompiledCode = code
                , vParameters = maybe 0 length (params :: Maybe [Value])
                }

instance FromJSON Blueprint where
    parseJSON = withObject "Blueprint" $ \o -> do
        vs <- o .: "validators"
        defs <- o .: "definitions"
        pure
            Blueprint
                { validators = vs
                , definitions = defs
                }

{- | Strip the @#/definitions/@ prefix and unescape
tilde-encoded slashes (@~1@ -> @/@).
-}
parseRef :: Text -> Text
parseRef =
    T.replace "~1" "/"
        . T.replace "~0" "~"
        . stripPrefix "#/definitions/"

stripPrefix :: Text -> Text -> Text
stripPrefix pfx t =
    fromMaybe t (T.stripPrefix pfx t)

-- ---------------------------------------------------------
-- Validation
-- ---------------------------------------------------------

{- | Validate a 'Data' value against a 'Schema',
resolving @$ref@ through the definitions map.
-}
validateData ::
    -- | Named definitions for @$ref@ resolution
    Map Text Schema ->
    -- | Schema to validate against
    Schema ->
    -- | Value to validate
    Data ->
    Bool
validateData defs schema d = case (schema, d) of
    (SBytes, B _) -> True
    (SInteger, I _) -> True
    (SList s, List xs) ->
        all (validateData defs s) xs
    -- A fixed tuple is a list of EXACTLY its declared arity, validated
    -- element by element against its own position's schema. Wrong
    -- arity and wrong element types both refuse.
    (STuple ss, List xs) ->
        length ss == length xs
            && and (zipWith (validateData defs) ss xs)
    (SRef ref, _) ->
        case Map.lookup ref defs of
            Just s -> validateData defs s d
            Nothing -> False
    (SConstructors cs, Constr ix fields) ->
        any
            ( \c ->
                conIndex c
                    == ix
                    && length (conFields c)
                        == length fields
                    && and
                        ( zipWith
                            (validateData defs)
                            (conFields c)
                            fields
                        )
            )
            cs
    _ -> False
