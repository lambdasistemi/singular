{- |
Module      : Singular.Registry.Blueprint.Load
Description : blueprint loading, code selection and registry naming codes
License     : Apache-2.0

Loads a @plutus.json@ blueprint produced by the Aiken compiler,
selects validators by title prefix ('extractScriptHash',
'extractCompiledCode'). The shared compiled-code carrier is 'NamingCodes'.

This is the loading-and-code-selection owner extracted from
@Singular.Registry.Blueprint@; the public module re-exports it and is
its only intended consumer surface.
-}
module Singular.Registry.Blueprint.Load
    ( -- * Loading
      loadBlueprint

      -- * The compiled codes the four registry pins derive from
    , NamingCodes (..)

      -- * Script hash extraction
    , extractScriptHash

      -- * Compiled code extraction
    , extractCompiledCode
    ) where

import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word8)
import Singular.Registry.Blueprint.Schema
    ( Blueprint (..)
    , Validator (..)
    )

-- ---------------------------------------------------------
-- Loading
-- ---------------------------------------------------------

{- | Load and parse a CIP-57 blueprint from a file
path.
-}
loadBlueprint
    :: FilePath
    -- ^ Path to the @plutus.json@ file
    -> IO (Either String Blueprint)
loadBlueprint path = do
    bs <- BS.readFile path
    pure $ Aeson.eitherDecodeStrict' bs

-- ---------------------------------------------------------
-- Script hash extraction
-- ---------------------------------------------------------

{- | Find the first validator whose title starts with
the given prefix and return its hash.
-}
extractScriptHash
    :: Text
    -- ^ Title prefix to match
    -> Blueprint
    -- ^ Blueprint to search
    -> Maybe Text
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
extractCompiledCode
    :: Text
    -- ^ Title prefix to match
    -> Blueprint
    -- ^ Blueprint to search
    -> Maybe SBS.ShortByteString
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
consumer of the application — the conformance rows, the devnet end-to-end and the
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
