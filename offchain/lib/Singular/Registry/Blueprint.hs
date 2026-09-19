{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.Blueprint
Description : CIP-57 blueprint schema validation
License     : Apache-2.0

Minimal CIP-57 Plutus blueprint parser and validator.
Loads a @plutus.json@ blueprint file produced by the
Aiken compiler, extracts type schemas and script
hashes, and validates 'PlutusCore.Data.Data' values
against the declared schemas.

The blueprint also carries optional @compiledCode@
fields (hex-encoded double-CBOR PlutusV3 scripts).
'extractCompiledCode' decodes these into
'ShortByteString' suitable for 'PlutusBinary'.
The state script is parameterized by
@previousPolicies@ (a predecessor-policy allowlist)
via 'applyPreviousPolicies'; the request script is
parameterized by @(statePolicyId, cageToken)@ via
'applyRequestParams'.
-}
module Singular.Registry.Blueprint (
    -- * Schema types
    Blueprint (..),
    Validator (..),
    Schema (..),
    Constructor (..),

    -- * Loading
    loadBlueprint,

    -- * The naming partition's compiled code
    NamingCodes (..),
    loadNamingCodesFromEnv,

    -- * The registry partition's own compiled code (#173 A173-BOOT)
    loadRegistryCodesFromEnv,

    -- * Validation
    validateData,

    -- * Script hash extraction
    extractScriptHash,

    -- * Compiled code extraction
    extractCompiledCode,

    -- * Parameter application
    applyDataParam,
    applyIntParam,
    applyBytesParam,
    applyOutputRef,
    applyPreviousPolicies,
    applyRequestParams,
) where

import Control.Exception (ErrorCall (..), throwIO)
import Data.Aeson (
    FromJSON (..),
    withObject,
    (.:),
    (.:?),
 )
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Char (isDigit)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word8)
import PlutusCore qualified as PLC
import PlutusCore.Data (Data (..))
import PlutusLedgerApi.V3 (
    serialiseUPLC,
    uncheckedDeserialiseUPLC,
 )
import PlutusTx.Builtins.Internal (
    BuiltinByteString (..),
    BuiltinData (..),
 )
import PlutusTx.IsData.Class (ToData (..))
import System.Environment (lookupEnv)
import UntypedPlutusCore (
    Program (..),
    applyProgram,
 )
import UntypedPlutusCore qualified as UPLC
import UntypedPlutusCore.DeBruijn ()

import Singular.Registry.Types (
    OnChainTokenId (..),
    OnChainTxOutRef,
 )

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
        pure
            Validator
                { vTitle = title
                , vDatum = datum
                , vRedeemer = redeemer
                , vHash = h
                , vCompiledCode = code
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
-- Loading
-- ---------------------------------------------------------

{- | Load and parse a CIP-57 blueprint from a file
path.
-}
loadBlueprint ::
    -- | Path to the @plutus.json@ file
    FilePath ->
    IO (Either String Blueprint)
loadBlueprint path = do
    bs <- BS.readFile path
    pure $ Aeson.eitherDecodeStrict' bs

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

-- ---------------------------------------------------------
-- Script hash extraction
-- ---------------------------------------------------------

{- | Find the first validator whose title starts with
the given prefix and return its hash.
-}
extractScriptHash ::
    -- | Title prefix to match
    Text ->
    -- | Blueprint to search
    Blueprint ->
    Maybe Text
extractScriptHash prefix bp =
    case filter
        (T.isPrefixOf prefix . vTitle)
        (validators bp) of
        (v : _) -> Just (vHash v)
        [] -> Nothing

-- ---------------------------------------------------------
-- Compiled code extraction
-- ---------------------------------------------------------

{- | Find the first validator whose title starts with
the given prefix and return its compiled script
bytes as a 'ShortByteString'. The hex-encoded
@compiledCode@ is decoded to raw bytes suitable
for 'PlutusBinary'.
-}
extractCompiledCode ::
    -- | Title prefix to match
    Text ->
    -- | Blueprint to search
    Blueprint ->
    Maybe SBS.ShortByteString
extractCompiledCode prefix bp = do
    v <-
        case filter
            (T.isPrefixOf prefix . vTitle)
            (validators bp) of
            (x : _) -> Just x
            [] -> Nothing
    hex <- vCompiledCode v
    SBS.toShort <$> decodeHex hex

{- | Decode a hex 'Text' to 'ByteString'.
Returns 'Nothing' on invalid input.
-}
decodeHex :: Text -> Maybe BS.ByteString
decodeHex t
    | odd (T.length t) = Nothing
    | otherwise =
        BS.pack <$> go (T.unpack t)
  where
    go [] = Just []
    go (a : b : rest) = do
        hi <- hexDigit a
        lo <- hexDigit b
        (hi * 16 + lo :) <$> go rest
    go _ = Nothing

    hexDigit :: Char -> Maybe Word8
    hexDigit c
        | isDigit c =
            Just $
                fromIntegral
                    (fromEnum c - fromEnum '0')
        | c >= 'a' && c <= 'f' =
            Just $
                fromIntegral
                    ( fromEnum c
                        - fromEnum 'a'
                        + 10
                    )
        | c >= 'A' && c <= 'F' =
            Just $
                fromIntegral
                    ( fromEnum c
                        - fromEnum 'A'
                        + 10
                    )
        | otherwise = Nothing

{- | Apply a 'Data' parameter to a UPLC script.
The blueprint's @compiledCode@ is a flat-encoded
UPLC program that expects one parameter. This
function applies the supplied 'Data' value to that
parameter slot, producing the final script bytes.
-}
applyDataParam ::
    -- | Encoded parameter value
    Data ->
    -- | Flat-encoded UPLC program
    SBS.ShortByteString ->
    SBS.ShortByteString
applyDataParam d sbs =
    let
        prog = uncheckedDeserialiseUPLC sbs
        argProg =
            Program
                ()
                (progVer prog)
                ( UPLC.Constant
                    ()
                    ( PLC.Some
                        ( PLC.ValueOf
                            PLC.DefaultUniData
                            d
                        )
                    )
                )
        applied = case applyProgram prog argProg of
            Right p -> p
            Left e ->
                error $
                    "applyDataParam: "
                        <> show e
     in
        serialiseUPLC applied
  where
    progVer (Program _ v _) = v

{- | Apply an integer parameter to a UPLC script.

`witness(kind, registry)` (#157 C5) takes its kind as a plain integer, and
the deployment applies it three times. Wrapping the `Data` encoding here
keeps the 'PlutusCore.Data' vocabulary inside this module, where the rest
of the blueprint's encoding already lives.
-}
applyIntParam ::
    -- | Encoded integer parameter
    Integer ->
    -- | Flat-encoded UPLC program
    SBS.ShortByteString ->
    SBS.ShortByteString
applyIntParam = applyDataParam . I

-- | Apply a raw bytes parameter to a UPLC script.
applyBytesParam ::
    -- | Encoded bytes parameter
    BS.ByteString ->
    -- | Flat-encoded UPLC program
    SBS.ShortByteString ->
    SBS.ShortByteString
applyBytesParam bs =
    applyDataParam (B bs)

{- | Apply an 'OnChainTxOutRef' parameter to a UPLC
script. Wraps 'applyDataParam' with the canonical
@Constr 0 [bytes, integer]@ encoding produced by the
'ToData OnChainTxOutRef' instance — matching what the
on-chain validator's parameter slot expects when the
Aiken validator is parameterized by an
@OutputReference@.
-}
applyOutputRef ::
    -- | Output reference to apply as the seed parameter
    OnChainTxOutRef ->
    -- | Flat-encoded UPLC program
    SBS.ShortByteString ->
    SBS.ShortByteString
applyOutputRef ref sbs =
    let BuiltinData d = toBuiltinData ref
     in applyDataParam d sbs

{- | Apply the state validator's @previousPolicies@
allowlist parameter. The on-chain parameter type is
@List\<PolicyId\>@, encoded as
@List [B pid0, B pid1, …]@ (an empty @List []@ for a
genesis cage, which makes migration into it
impossible).
-}
applyPreviousPolicies ::
    -- | Predecessor policy-id bytes (28 bytes each); @[]@ for genesis
    [BS.ByteString] ->
    -- | Flat-encoded raw state UPLC program
    SBS.ShortByteString ->
    SBS.ShortByteString
applyPreviousPolicies pids =
    applyDataParam (List (map B pids))

{- | Apply request-validator parameters in source
order: @statePolicyId@ first, then @cageTokenName@.
-}
applyRequestParams ::
    -- | State policy id bytes
    BS.ByteString ->
    -- | Cage token asset name
    OnChainTokenId ->
    -- | Flat-encoded request UPLC program
    SBS.ShortByteString ->
    SBS.ShortByteString
applyRequestParams statePolicyId (OnChainTokenId (BuiltinByteString token)) sbs =
    applyBytesParam token $
        applyBytesParam statePolicyId sbs

{- | The naming partition's compiled code: the application whose mint arm
certifies an edge, and the witness policy the three token kinds are
derived from.

The four policy pins of a registry are derived from these two, so every
consumer of the application — the conformance rows, the devnet E2E and the
bounded journey — binds to one source and moves together.
-}
data NamingCodes = NamingCodes
    { ncApplication :: SBS.ShortByteString
    , ncWitness :: SBS.ShortByteString
    }

{- | Read the naming blueprint @NAMING_BLUEPRINT@ names and extract the
two compiled codes the pins derive from.
-}
loadNamingCodesFromEnv :: IO NamingCodes
loadNamingCodesFromEnv = do
    mPath <- lookupEnv "NAMING_BLUEPRINT"
    path <- case mPath of
        Just p | not (null p) -> pure p
        _ -> die "NAMING_BLUEPRINT is not set"
    ebp <- loadBlueprint path
    bp <- case ebp of
        Left err -> die ("naming blueprint does not parse: " <> err)
        Right bp -> pure bp
    case ( extractCompiledCode "application.application" bp
         , extractCompiledCode "witness.witness" bp
         ) of
        (Just appCode, Just witnessCode) ->
            pure NamingCodes{ncApplication = appCode, ncWitness = witnessCode}
        _ ->
            die
                "naming blueprint has no application.application/witness.witness \
                \code (the four pins are derived from them)"
  where
    die :: String -> IO a
    die = throwIO . ErrorCall

{- | #173 A173-BOOT: the four pins of an OPEN registry, read from the
registry partition's own blueprint and nothing else.

The open registry's application is @open.open@ — parameterless, so its
compiled hash IS its policy id, with no applied hash to derive (A-001
row 1; Lean @openPolicyParameters = []@). Its three token witnesses are
@witness.witness@ in the SAME blueprint, which moved here from the
naming partition in this ticket (I2). A boot therefore consults
@REGISTRY_BLUEPRINT@ alone: no naming blueprint participates, and
@NAMING_BLUEPRINT@ need not be set at all.

Both codes are read from the SAME blueprint, so a consumer cannot
silently pair an open application from one build with witnesses from
another.
-}
loadRegistryCodesFromEnv :: IO NamingCodes
loadRegistryCodesFromEnv = do
    mPath <- lookupEnv "REGISTRY_BLUEPRINT"
    path <- case mPath of
        Just p | not (null p) -> pure p
        _ -> die "REGISTRY_BLUEPRINT is not set"
    ebp <- loadBlueprint path
    bp <- case ebp of
        Left err -> die ("registry blueprint does not parse: " <> err)
        Right bp -> pure bp
    case ( extractCompiledCode "open.open" bp
         , extractCompiledCode "witness.witness" bp
         ) of
        (Just openCode, Just witnessCode) ->
            pure NamingCodes{ncApplication = openCode, ncWitness = witnessCode}
        (Nothing, _) ->
            die
                "registry blueprint has no open.open code: the open \
                \application is not in the registry partition (#173 I1)"
        (_, Nothing) ->
            die
                "registry blueprint has no witness.witness code: the three \
                \witness policies have not moved here (#173 I2)"
  where
    die :: String -> IO a
    die = throwIO . ErrorCall
