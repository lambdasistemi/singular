{- |
Module      : Singular.Registry.Deployment.Mirror
Description : The proof mirror a deployment carries beside its manifest
License     : Apache-2.0

One owner for the deployment's one non-chain dependency: the proof
mirror written beside a manifest, per registry token, as the four
hex-encoded key\/value maps an in-memory MPF database is. Reading and
writing the file live here; loading one never queries a node, and the
caller — not this module — compares a loaded trie's root against the
chain's after attaching.

This module is an internal owner behind the 'Singular.Registry.Deployment'
facade: callers import the facade, which re-exports the unchanged public
surface. It reads 'mirrorPathFor', 'hex' and 'die' from
"Singular.Registry.Deployment.Manifest", so the mirror's path has one
owner.
-}
module Singular.Registry.Deployment.Mirror (
    -- * The proof mirror
    Mirror (..),
    MirrorTrie (..),
    loadMirror,
    saveMirror,
) where

import Data.Aeson (
    FromJSON (..),
    ToJSON (..),
    eitherDecodeFileStrict',
 )
import Data.Aeson qualified as Aeson
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import System.Directory (doesFileExist)

import MPF.Backend.Pure (MPFInMemoryDB (..))

import Singular.Registry.Deployment.Manifest (die, hex, mirrorPathFor)
import Singular.Registry.Ledger (AssetName (..), TokenId (..))

-- ---------------------------------------------------------
-- The proof mirror
-- ---------------------------------------------------------

{- | The tries a run needs, as the file beside the manifest carries
them: per registry token, the four key/value maps an in-memory MPF
database is, hex-encoded so the file stays diffable.
-}
newtype Mirror = Mirror {mirrorTries :: [MirrorTrie]}
    deriving (Eq, Show, Generic)

instance ToJSON Mirror where
    toJSON = Aeson.genericToJSON Aeson.defaultOptions
instance FromJSON Mirror where
    parseJSON = Aeson.genericParseJSON Aeson.defaultOptions

-- | One registry's trie.
data MirrorTrie = MirrorTrie
    { mtToken :: Text
    -- ^ Hex asset name of the registry this trie belongs to
    , mtMpf :: [(Text, Text)]
    , mtKv :: [(Text, Text)]
    , mtJournal :: [(Text, Text)]
    , mtMetrics :: [(Text, Text)]
    }
    deriving (Eq, Show, Generic)

instance ToJSON MirrorTrie where
    toJSON = Aeson.genericToJSON Aeson.defaultOptions
instance FromJSON MirrorTrie where
    parseJSON = Aeson.genericParseJSON Aeson.defaultOptions

{- | Read the mirror beside a manifest. A missing file is the empty
mirror, which is what a registry booted a moment ago actually has —
the caller that attaches compares the loaded root with the chain's, so
an empty mirror against a registry that has grown is refused by that
comparison rather than assumed.
-}
loadMirror :: FilePath -> IO (Map.Map TokenId MPFInMemoryDB)
loadMirror manifest = do
    let path = mirrorPathFor manifest
    there <- doesFileExist path
    if not there
        then pure Map.empty
        else do
            parsed <- eitherDecodeFileStrict' path
            case parsed of
                Left err -> die ("proof mirror " <> path <> ": " <> err)
                Right (Mirror tries) ->
                    Map.fromList <$> mapM one tries
  where
    one mt = do
        name <- unhex (mtToken mt)
        db <-
            MPFInMemoryDB
                <$> pairs (mtMpf mt)
                <*> pairs (mtKv mt)
                <*> pairs (mtJournal mt)
                <*> pairs (mtMetrics mt)
                <*> pure Map.empty
        pure (TokenId (AssetName (SBS.toShort name)), db)
    pairs kvs = Map.fromList <$> mapM (\(k, v) -> (,) <$> unhex k <*> unhex v) kvs
    unhex t = case B16.decode (BC.pack (T.unpack t)) of
        Right b -> pure b
        Left _ -> die ("proof mirror: not hex: " <> T.unpack t)

-- | Write the mirror beside a manifest, replacing what was there.
saveMirror :: FilePath -> Map.Map TokenId MPFInMemoryDB -> IO ()
saveMirror manifest tries =
    BL.writeFile
        (mirrorPathFor manifest)
        (encodePretty (Mirror (map one (Map.toList tries))) <> "\n")
  where
    one (TokenId (AssetName n), db) =
        MirrorTrie
            { mtToken = T.pack (hex (SBS.fromShort n))
            , mtMpf = pairs (mpfInMemoryMPF db)
            , mtKv = pairs (mpfInMemoryKV db)
            , mtJournal = pairs (mpfInMemoryJournal db)
            , mtMetrics = pairs (mpfInMemoryMetrics db)
            }
    pairs =
        map (\(k, v) -> (T.pack (hex k), T.pack (hex v))) . Map.toList
