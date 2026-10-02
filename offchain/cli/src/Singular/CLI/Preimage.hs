{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.CLI.Preimage
Description : The envelopes a booking leaves for the fold that delivers them
License     : Apache-2.0

An insertion's request names only the hash of its envelope; the output
the fold delivers carries the envelope itself. The booking writes the
envelope under that hash in the registry directory before it submits,
and the fold reads it back and checks it against the hash the request
names before it builds, so a fold never delivers an envelope the request
does not name.
-}
module Singular.CLI.Preimage
    ( PreimageRefusal (..)
    , renderPreimageRefusal
    , preimagePath
    , storePreimage
    , loadPreimage
    , verifyPreimage
    ) where

import Control.Exception (IOException, try)
import Data.Aeson qualified as Aeson
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.Text qualified as T
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory, (</>))

import Singular.Application.OpenDatum.Envelope
    ( Envelope
    , envelopeFromJson
    , envelopeHash
    , envelopeToJson
    )
import Singular.CLI.Receipt (durableWrite)
import Singular.CLI.Registry (hexT)

-- | Why a stored envelope cannot be delivered.
data PreimageRefusal
    = -- | Nothing stored under the hash the request names
      PreimageMissing ByteString
    | -- | Stored, but not readable as an envelope
      PreimageUnreadable ByteString String
    | -- | The hash the request names, the hash of what was stored
      PreimageMismatch ByteString ByteString
    deriving stock (Eq, Show)

-- | One line naming the refusal.
renderPreimageRefusal :: PreimageRefusal -> String
renderPreimageRefusal = \case
    PreimageMissing h ->
        "no envelope is stored for hash 0x"
            <> T.unpack (hexT h)
            <> " in this registry directory: the request names only its hash, and the booking's envelope is not here"
    PreimageUnreadable h why ->
        "the envelope stored for hash 0x"
            <> T.unpack (hexT h)
            <> " cannot be read: "
            <> why
    PreimageMismatch want got ->
        "the request names envelope hash 0x"
            <> T.unpack (hexT want)
            <> " but the stored file holds another envelope, hash 0x"
            <> T.unpack (hexT got)

-- | Where the envelope with this hash is kept in the registry directory.
preimagePath :: FilePath -> ByteString -> FilePath
preimagePath dir h = dir </> "preimages" </> T.unpack (hexT h) <> ".json"

{- | Keep an envelope under its hash, durably, before the booking that names
it is submitted. Storing the same envelope again leaves the same file.
-}
storePreimage :: FilePath -> Envelope -> IO ()
storePreimage dir e = do
    let path = preimagePath dir (envelopeHash e)
    createDirectoryIfMissing True (takeDirectory path)
    durableWrite
        path
        (BL.toStrict (encodePretty (envelopeToJson e) <> "\n"))

-- | The envelope kept under a hash, checked against it.
loadPreimage
    :: FilePath -> ByteString -> IO (Either PreimageRefusal Envelope)
loadPreimage dir h = do
    let path = preimagePath dir h
    there <- doesFileExist path
    if not there
        then pure (Left (PreimageMissing h))
        else do
            read' <- try (Aeson.eitherDecodeFileStrict' path)
            pure $ case read' of
                Left (e :: IOException) -> Left (PreimageUnreadable h (show e))
                Right (Left why) -> Left (PreimageUnreadable h why)
                Right (Right v) -> case envelopeFromJson v of
                    Left why -> Left (PreimageUnreadable h why)
                    Right e -> verifyPreimage h e

-- | An envelope accepted only when it hashes to what the request names.
verifyPreimage
    :: ByteString -> Envelope -> Either PreimageRefusal Envelope
verifyPreimage want e
    | got == want = Right e
    | otherwise = Left (PreimageMismatch want got)
  where
    got = envelopeHash e
