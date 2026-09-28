{- |
Module      : Singular.Registry.Deployment.Manifest
Description : The deployment manifest and the paths around it
License     : Apache-2.0

One owner for the deployment record as a file: the manifest and
reference-script values with their JSON instances, reading and writing
one, choosing one from a command line or the environment, the
@txid#index@ spelling and its parse, an address as the exact hex bytes
the ledger serialises, the byte-rendering helper 'hex' and the shared
error helper 'die' the deployment family shares. Nothing here queries
a node.

This module is an internal owner behind the 'Singular.Registry.Deployment'
facade: callers import the facade, which re-exports the unchanged public
surface. See the deployment ownership guide for the dependency direction
between the owners.
-}
module Singular.Registry.Deployment.Manifest
    ( -- * The manifest
      Deployment (..)
    , ReferenceScript (..)
    , readDeployment
    , writeDeployment

      -- * Choosing one
    , deploymentPathFromArgs
    , deploymentPathFromEnvironment

      -- * Output references
    , renderOutRef
    , parseOutRef
    , renderAddrBytes

      -- * The mirror's path
    , mirrorPathFor

      -- * Shared rendering, for the deployment family only
    , die
    , hex
    ) where

import Control.Exception (ErrorCall (..), throwIO)
import Data.Aeson
    ( FromJSON (..)
    , ToJSON (..)
    , eitherDecodeFileStrict'
    )
import Data.Aeson qualified as Aeson
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.List (isPrefixOf)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word16, Word32)
import GHC.Generics (Generic)
import System.Environment (getArgs, lookupEnv)
import System.FilePath (dropExtension, (<.>))
import Text.Read (readMaybe)

import Cardano.Crypto.Hash (hashFromBytes, hashToBytes)
import Cardano.Ledger.Address (Addr, serialiseAddr)
import Cardano.Ledger.Api.Tx.In (TxId (..), TxIn (..))
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Hashes (extractHash, unsafeMakeSafeHash)

-- ---------------------------------------------------------
-- The manifest
-- ---------------------------------------------------------

{- | One reference-script output: what it carries, where it is, and the
hash a node must agree it holds.
-}
data ReferenceScript = ReferenceScript
    { refRole :: Text
    -- ^ Which script this is (@state@, @request@, @application@, …)
    , refHash :: Text
    -- ^ Hex script hash the output must carry
    , refOutRef :: Text
    -- ^ @txid#index@ of the output
    , refAddress :: Text
    {- ^ Address the output sits at, in the bech32 form a person reads.
    Informational: refAddressBytes is what the code queries.
    -}
    , refAddressBytes :: Text
    {- ^ The same address as the hex bytes the ledger serialises, which
    round-trips exactly
    -}
    }
    deriving (Eq, Show, Generic)

instance ToJSON ReferenceScript where
    toJSON = Aeson.genericToJSON Aeson.defaultOptions
instance FromJSON ReferenceScript where
    parseJSON = Aeson.genericParseJSON Aeson.defaultOptions

{- | A registry that exists, recorded well enough to find it again and
to refuse to use the wrong one.
-}
data Deployment = Deployment
    { depRelease :: Text
    -- ^ Release tag or candidate commit the deployment was made from
    , depLeanRevision :: Text
    -- ^ Revision of the model that release was built against
    , depNetworkMagic :: Word32
    -- ^ Network the deployment lives on
    , depSeedOutRef :: Text
    -- ^ @txid#index@ the boot mint consumed; the registry's identity
    , depCageToken :: Text
    -- ^ Hex asset name of the registry token (SHA-256 of the seed)
    , depStatePolicy :: Text
    -- ^ Applied state script hash, which is the registry's policy id
    , depRequestHash :: Text
    -- ^ Applied request validator hash
    , depApplicationHash :: Text
    -- ^ Naming application validator hash
    , depRepresentativePolicy :: Text
    {- ^ The registry-bound ACTIVE token policy: `witness(1, registry)`
    applied (#157 C5/C7). Renamed from the representative policy it
    became; the manifest key keeps its spelling so existing manifests
    and the attach check still read it.
    -}
    , depProcessTime :: Integer
    -- ^ Phase-1 window (ms) the registry was booted with
    , depRetractTime :: Integer
    -- ^ Phase-2 window (ms) the registry was booted with
    , depTip :: Integer
    -- ^ Oracle tip (lovelace) the registry was booted with
    , depReferenceScripts :: [ReferenceScript]
    -- ^ The outputs published once and reused by every later run
    , depBootstrapTxs :: [Text]
    -- ^ Transaction ids that created all of the above, in order
    }
    deriving (Eq, Show, Generic)

instance ToJSON Deployment where
    toJSON = Aeson.genericToJSON Aeson.defaultOptions
instance FromJSON Deployment where
    parseJSON = Aeson.genericParseJSON Aeson.defaultOptions

-- | Read a manifest, naming the file when it will not parse.
readDeployment :: FilePath -> IO Deployment
readDeployment path = do
    parsed <- eitherDecodeFileStrict' path
    case parsed of
        Right d -> pure d
        Left err -> die ("deployment manifest " <> path <> ": " <> err)

-- | Write a manifest, formatted for a person to read in review.
writeDeployment :: FilePath -> Deployment -> IO ()
writeDeployment path = BL.writeFile path . (<> "\n") . encodePretty

{- | Where the proof mirror for a manifest lives: the manifest's own
path with a @.mirror.json@ extension, so the two travel together and
neither is guessed from a separate flag.
-}
mirrorPathFor :: FilePath -> FilePath
mirrorPathFor manifest = dropExtension manifest <.> "mirror" <.> "json"

-- ---------------------------------------------------------
-- Choosing one
-- ---------------------------------------------------------

{- | The manifest a command line names, if any. @--deployment PATH@ and
@--deployment=PATH@ are both accepted; absent, the caller keeps its
existing behaviour of booting its own registry.
-}
deploymentPathFromArgs :: [String] -> Maybe FilePath
deploymentPathFromArgs = go
  where
    name = "--deployment"
    go (a : rest)
        | a == name = case rest of
            (v : _) -> Just v
            [] -> Nothing
        | (name <> "=") `isPrefixOf` a = Just (drop (length name + 1) a)
        | otherwise = go rest
    go [] = Nothing

{- | 'deploymentPathFromArgs' for this process, falling back to
@SINGULAR_DEPLOYMENT@.
-}
deploymentPathFromEnvironment :: IO (Maybe FilePath)
deploymentPathFromEnvironment = do
    args <- getArgs
    case deploymentPathFromArgs args of
        Just p -> pure (Just p)
        Nothing -> lookupEnv "SINGULAR_DEPLOYMENT"

-- ---------------------------------------------------------
-- Output references
-- ---------------------------------------------------------

-- | @txid#index@, the spelling every Cardano tool prints.
renderOutRef :: TxIn -> Text
renderOutRef (TxIn (TxId h) (TxIx i)) =
    T.pack (hex (hashToBytes (extractHash h)) <> "#" <> show i)

-- | Parse @txid#index@ back, naming what was wrong with it.
parseOutRef :: Text -> Either String TxIn
parseOutRef t = case T.splitOn "#" t of
    [idT, ixT] -> do
        raw <- case B16.decode (BC.pack (T.unpack idT)) of
            Right b -> Right b
            Left _ -> Left ("transaction id is not hex: " <> T.unpack idT)
        h <- case hashFromBytes raw of
            Just h -> Right h
            Nothing ->
                Left
                    ( "transaction id is not 32 bytes: "
                        <> show (BS.length raw)
                    )
        ix <- case readMaybe (T.unpack ixT) :: Maybe Word16 of
            Just n -> Right n
            Nothing -> Left ("output index is not a number: " <> T.unpack ixT)
        Right (TxIn (TxId (unsafeMakeSafeHash h)) (TxIx ix))
    _ -> Left ("not a txid#index output reference: " <> T.unpack t)

-- ---------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------

-- | An address as the manifest records it: exact bytes, in hex.
renderAddrBytes :: Addr -> Text
renderAddrBytes = T.pack . hex . serialiseAddr

die :: String -> IO a
die = throwIO . ErrorCall

hex :: ByteString -> String
hex = BC.unpack . B16.encode
