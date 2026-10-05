{- | Immutable private-devnet time publications. The symlink changes only
after all three public files have been written and validated. A command's
loadPinnedSource resolves that link once per acquisition. Neither a held
session nor this publisher extends the node's finite era-history horizon.
-}
module Singular.Registry.Private.TimePublication
    ( publishTime
    ) where

import Cardano.Slotting.Time (SystemStart (..))
import Codec.Serialise (DeserialiseFailure, deserialiseOrFail)
import Control.Exception (throwIO)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (encode, object, (.=))
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Unique (hashUnique, newUnique)
import Ouroboros.Consensus.HardFork.History.Summary
    ( Bound (..)
    , EraEnd (..)
    , EraSummary (..)
    )
import Singular.Registry.NetworkTime
    ( NetworkTime
    , NetworkTimeFailure (..)
    , NetworkTimeManifest (..)
    , validateNetworkTime
    )
import Singular.Registry.Private.Source (LedgerSource (..))
import System.Directory (createDirectoryIfMissing, renameFile)
import System.FilePath ((</>))
import System.Posix.Files (createSymbolicLink, setFileMode)

publishTime
    :: FilePath -> ByteString -> LedgerSource -> IO NetworkTime
publishTime root genesis source = do
    eras <-
        either
            (fail . show)
            pure
            ( deserialiseOrFail (LBS.fromStrict history)
                :: Either DeserialiseFailure [EraSummary]
            )
    horizon <- case reverse eras of
        EraSummary{eraEnd = EraEnd end} : _ -> pure (boundSlot end)
        _ -> throwIO MissingTimeHorizon
    let SystemStart start = sourceSystemStart source
        startMs = floor (utcTimeToPOSIXSeconds start * 1000)
        identity = "private devnet raw LSQ " <> Text.pack (show (sourcePoint source))
        manifest =
            NetworkTimeManifest
                42
                startMs
                (digest genesis)
                (digest history)
                horizon
                identity
        value =
            object
                [ "networkMagic" .= (42 :: Int)
                , "systemStartMs" .= startMs
                , "genesisSha256" .= hex (digest genesis)
                , "eraHistorySha256" .= hex (digest history)
                , "horizonSlot" .= horizon
                , "sourceIdentity" .= identity
                ]
    context <-
        either throwIO pure (validateNetworkTime 42 manifest genesis history)
    unique <- show . hashUnique <$> newUnique
    let directory = root </> ("publication-" <> unique)
        next = root </> ("link-" <> unique)
    createDirectoryIfMissing True directory
    BS.writeFile (directory </> "shelley-genesis.json") genesis
    BS.writeFile (directory </> "era-history.cbor") history
    LBS.writeFile (directory </> "time-manifest.json") (encode value)
    mapM_
        (\name -> setFileMode (directory </> name) 0o444)
        ["shelley-genesis.json", "era-history.cbor", "time-manifest.json"]
    createSymbolicLink directory next
    renameFile next (root </> "current")
    pure context
  where
    history = sourceEraHistory source
    digest bytes = convert (hash bytes :: Digest SHA256)
    hex = decodeUtf8 . B16.encode
