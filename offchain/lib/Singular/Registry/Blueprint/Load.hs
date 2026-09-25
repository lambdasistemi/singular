{- |
Module      : Singular.Registry.Blueprint.Load
Description : blueprint loading, code selection and registry naming codes
License     : Apache-2.0

Loads a @plutus.json@ blueprint produced by the Aiken compiler,
selects validators by title prefix ('extractScriptHash',
'extractCompiledCode'), and reads the registry partition's own
compiled codes ('NamingCodes', 'loadRegistryCodesFromEnv').

This is the loading-and-code-selection owner extracted from
@Singular.Registry.Blueprint@; the public module re-exports it and is
its only intended consumer surface.
-}
module Singular.Registry.Blueprint.Load (
    -- * Loading
    loadBlueprint,

    -- * The compiled codes the four registry pins derive from
    NamingCodes (..),

    -- * The registry partition's own compiled code (#173 A173-BOOT)
    loadRegistryCodesFromEnv,

    -- * Script hash extraction
    extractScriptHash,

    -- * Compiled code extraction
    extractCompiledCode,
) where

import Control.Exception (ErrorCall (..), throwIO)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word8)
import Singular.Registry.Blueprint.Schema (Blueprint (..), Validator (..))
import System.Environment (lookupEnv)

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

{- | The compiled codes the four registry pins derive from: the
application whose mint arm certifies an edge, and the witness policy the
three token kinds are derived from.

The four policy pins of a registry are derived from these two, so every
consumer of the application — the conformance rows, the devnet E2E and the
bounded journey — binds to one source and moves together.

#173 I2: for the OPEN registry both now come from the registry
partition's own blueprint. The record keeps its name because every
consumer names its fields; renaming it is a sweep this ticket does not
need.
-}
data NamingCodes = NamingCodes
    { ncApplication :: SBS.ShortByteString
    , ncWitness :: SBS.ShortByteString
    }

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
