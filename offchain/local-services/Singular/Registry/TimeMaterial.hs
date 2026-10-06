{- | Time-source selection without node-derived conversions.
Preprod reads the reviewed immutable package. Magic 42 reads the actual
generated directory's public genesis bytes, then binds the held raw history.
-}
module Singular.Registry.TimeMaterial
    ( TimeMaterial (..)
    , loadTimeMaterial
    , timeFromRaw
    ) where

import Cardano.Slotting.Time (SystemStart)
import Control.Exception (throwIO)
import Control.Monad (unless)
import Data.Aeson (eitherDecodeStrict')
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word32, Word64)
import Paths_singular_registry (getDataFileName)
import Singular.Registry.NetworkTime
    ( NetworkTime
    , NetworkTimeFailure (..)
    , generatedNetworkTime
    , networkMagic
    , networkSystemStart
    , validateNetworkTime
    , validateProtocolMajor
    )
import System.FilePath ((</>))

-- | Explicit immutable source; synthetic test material must name itself.
data TimeMaterial
    = PackagedTime NetworkTime
    | GeneratedGenesis ByteString

loadTimeMaterial :: Word32 -> FilePath -> IO TimeMaterial
loadTimeMaterial magic generated = case magic of
    1 -> do
        manifestBytes <- packaged "time-manifest.json"
        manifest <-
            either
                (throwIO . TimeSourceMismatch . Text.pack)
                pure
                (eitherDecodeStrict' manifestBytes)
        genesis <- packaged "shelley-genesis.json"
        history <- packaged "era-history.cbor"
        PackagedTime
            <$> either throwIO pure (validateNetworkTime 1 manifest genesis history)
    42 ->
        GeneratedGenesis
            <$> BS.readFile (generated </> "shelley-genesis.json")
    other -> throwIO (UnknownTimeNetwork other)
  where
    packaged name = getDataFileName ("data/network/preprod/" <> name) >>= BS.readFile

{- | Validate the acquired system start against the source before use. The
raw preprod history never replaces the reviewed package's history or horizon.
-}
timeFromRaw
    :: Word32
    -> Word64
    -> Text
    -> TimeMaterial
    -> SystemStart
    -> ByteString
    -> Either NetworkTimeFailure NetworkTime
timeFromRaw magic major source material start history = do
    context <- case material of
        PackagedTime reviewed -> Right reviewed
        GeneratedGenesis genesis -> generatedNetworkTime magic major source genesis history
    unless
        (networkMagic context == magic)
        (Left (WrongTimeNetwork magic (networkMagic context)))
    unless
        (networkSystemStart context == start)
        (Left (TimeSourceMismatch "acquired system start differs from source"))
    validateProtocolMajor context major
    pure context
