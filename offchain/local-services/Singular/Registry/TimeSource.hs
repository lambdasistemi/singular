{- | Public pinned source bytes. The terminal reads one immutable directory
per acquisition. A private facade may publish a new directory for a later
acquisition; a session never changes its source. The common interpreter opens
the pinned final era under NOTE030, with a major-version guard before building.
-}
module Singular.Registry.TimeSource
    ( TimeSource (..)
    , loadPinnedSource
    ) where

import Control.Exception (IOException, try)
import Data.Aeson (eitherDecodeStrict')
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text qualified as Text
import Data.Word (Word32)
import Paths_singular_registry (getDataFileName)
import Singular.Registry.LedgerProvider (ReadFailure (..))
import Singular.Registry.NetworkTime
    ( NetworkTimeFailure (..)
    , NetworkTimeManifest
    )
import System.Directory (canonicalizePath)
import System.FilePath ((</>))

-- | Exact manifest, genesis and raw era-history material for one session.
data TimeSource = TimeSource NetworkTimeManifest ByteString ByteString

{- | Magic 1 defaults to the reviewed package. Other networks require an
explicit source. Resolving the directory once keeps an atomic facade link
from mixing files from different immutable publications.
-}
loadPinnedSource
    :: Word32 -> Maybe FilePath -> IO (Either ReadFailure TimeSource)
loadPinnedSource magic selected = case selected of
    Nothing
        | magic /= 1 ->
            pure (Left (NetworkTimeRefusal (UnknownTimeNetwork magic)))
    _ -> do
        result <- try @IOException $ do
            directory <- case selected of
                Just path -> canonicalizePath path
                Nothing -> getDataFileName "data/network/preprod" >>= canonicalizePath
            manifestBytes <- BS.readFile (directory </> "time-manifest.json")
            genesis <- BS.readFile (directory </> "shelley-genesis.json")
            eras <- BS.readFile (directory </> "era-history.cbor")
            pure $ case eitherDecodeStrict' manifestBytes of
                Left failure ->
                    Left (NetworkTimeRefusal (TimeSourceMismatch (Text.pack failure)))
                Right manifest -> Right (TimeSource manifest genesis eras)
        pure $ case result of
            Left failure -> Left (BackendReadFailure (Text.pack (show failure)))
            Right source -> source
