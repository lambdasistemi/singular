{- |
Module      : Singular.Registry.Blueprint.Load
Description : blueprint loading, code selection and application code
License     : Apache-2.0

Loads a @plutus.json@ blueprint produced by the Aiken compiler,
selects validators by title prefix ('extractScriptHash',
'extractCompiledCode'). The shared compiled-code carrier is 'ApplicationCodes'.

This is the loading-and-code-selection owner extracted from
@Singular.Registry.Blueprint@; the public module re-exports it and is
its only intended consumer surface.
-}
module Singular.Registry.Blueprint.Load
    ( -- * Loading
      loadBlueprint

      -- * Supplied application and token-policy code
    , ApplicationCodes (..)

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

{- | Supplied application and active-token-policy code for the shared
identity adapters. The caller chooses the application; no application
is built into the registry library.
-}
data ApplicationCodes = ApplicationCodes
    { ncApplication :: SBS.ShortByteString
    , ncWitness :: SBS.ShortByteString
    }
