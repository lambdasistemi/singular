{- |
Module      : Singular.Registry.Deployment
Description : One persistent registry, recorded and re-attached to
License     : Apache-2.0

A runner boots its own registry and publishes its own reference scripts
on every run. On a private devnet that is free and right. On a public
network it means every run pays to publish the same scripts again and
creates a registry nothing else will ever look at — a demonstration of
the code rather than of a deployment.

This module is the other half: a __deployment manifest__ recording one
registry booted once and one set of reference-script outputs published
once, and the means to attach a later run to them.

Three operations:

* __record__ — the @deploy@ command writes the manifest after booting
  and publishing ('writeDeployment').
* __check__ — 'verifyDeployment' asks a node whether it still agrees:
  every reference output is live and carries the hash the manifest
  pins, the registry's state output carries the recorded token, and the
  release in hand compiles to the hashes the manifest was made with.
* __attach__ — 'attach' rebuilds the cage configuration from the
  manifest and resolves the reference outputs, so a run uses them
  instead of creating its own.

__What the manifest cannot carry.__ Writing to a registry — folding a
claim in — means proving the key against the registry's current trie,
and that proof needs the whole trie, not the root the chain reports.
Nothing on chain hands it over in one query, so a deployment carries it
as a file beside the manifest ('mirrorPathFor'), written by each run
and read by the next.

That file is the deployment's one non-chain dependency: a second
machine needs a copy of it to fold, though not to read — proving a name
is alive needs the registry entry and the NFT, and no trie at all.
Rebuilding the trie from the chain instead, by following the registry
token from the bootstrap transaction and replaying each fold's request
datums, is the next milestone's work.

That file is a hazard, so it is checked rather than hoped away —
'attach' refuses when the mirror's root and the chain's root disagree,
so a mirror that drifted (a run that died mid-fold, a copy belonging to
another deployment) fails by name instead of building proofs against a
trie the chain does not have.
-}
module Singular.Registry.Deployment (
    -- * The manifest
    Deployment (..),
    ReferenceScript (..),
    readDeployment,
    writeDeployment,

    -- * Choosing one
    deploymentPathFromArgs,
    deploymentPathFromEnvironment,

    -- * The release halves the manifest pins only by hash
    CageParts (..),
    cageConfigFor,

    -- * Checking one against a node
    verifyDeployment,

    -- * Attaching a run to one
    Attached (..),
    attach,

    -- * The proof mirror beside the manifest
    mirrorPathFor,
    loadMirror,
    saveMirror,

    -- * Output references
    renderOutRef,
    parseOutRef,
    renderAddrBytes,
) where

import Control.Exception (ErrorCall (..), throwIO)
import Data.Aeson (
    FromJSON (..),
    ToJSON (..),
    eitherDecodeFileStrict',
 )
import Data.Aeson qualified as Aeson
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import Data.List (isPrefixOf)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word16, Word32)
import GHC.Generics (Generic)
import System.Directory (doesFileExist)
import System.Environment (getArgs, lookupEnv)
import System.FilePath (dropExtension, (<.>))
import Text.Read (readMaybe)

import Lens.Micro ((^.))

import Cardano.Crypto.Hash (hashFromBytes, hashToBytes)
import Cardano.Ledger.Address (Addr, decodeAddrEither, serialiseAddr)
import Cardano.Ledger.Api.Tx.In (TxId (..), TxIn (..))
import Cardano.Ledger.Api.Tx.Out (TxOut, referenceScriptTxOutL)
import Cardano.Ledger.BaseTypes (Network (..), StrictMaybe (..), TxIx (..))
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Hashes (extractHash, unsafeMakeSafeHash)

import MPF.Backend.Pure (MPFInMemoryDB (..))

import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (
    AssetName (..),
    Coin (..),
    ConwayEra,
    TokenId (..),
 )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.TxBuilder.Internal (
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    computeScriptHash,
    findStateUtxo,
    scriptHashBytes,
    txInToRef,
 )

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
    -- ^ Applied representative minting policy
    , depConsumerHash :: Text
    -- ^ Pinned consumer hash the state datum carries
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
-- The release halves the manifest pins only by hash
-- ---------------------------------------------------------

{- | The compiled bytes a release ships. The manifest records their
hashes; the bytes themselves come from the blueprints in hand, so a
manifest can never be used to smuggle in a different validator.
-}
data CageParts = CageParts
    { partsStateBytes :: SBS.ShortByteString
    , partsRequestBytes :: SBS.ShortByteString
    , partsRepPolicy :: SBS.ShortByteString
    , partsConsumerPin :: SBS.ShortByteString
    , partsConsumerScript :: SBS.ShortByteString
    }

{- | The cage configuration a manifest describes: this release's
compiled scripts, with the seed and the economics the deployment was
booted with.

Refuses when the release in hand compiles the state validator to a
different hash than the deployment was made with — the manifest then
belongs to another release and attaching to it would spend against a
registry whose validator this code does not implement.
-}
cageConfigFor :: Deployment -> CageParts -> Either String CageConfig
cageConfigFor dep parts = do
    seedIn <- parseOutRef (depSeedOutRef dep)
    let stateHash = computeScriptHash (partsStateBytes parts)
        stateHex = T.pack (hex (scriptHashBytes stateHash))
    if stateHex /= depStatePolicy dep
        then
            Left
                ( "this release compiles the state validator to 0x"
                    <> T.unpack stateHex
                    <> " but the deployment was made with 0x"
                    <> T.unpack (depStatePolicy dep)
                    <> ": the manifest belongs to another release"
                )
        else
            Right
                CageConfig
                    { cageScriptBytes = partsStateBytes parts
                    , requestScriptBytes = partsRequestBytes parts
                    , cfgScriptHash = stateHash
                    , cageSeed = txInToRef seedIn
                    , defaultProcessTime = depProcessTime dep
                    , defaultRetractTime = depRetractTime dep
                    , defaultTip = Coin (depTip dep)
                    , cfgRepPolicy = partsRepPolicy parts
                    , cfgConsumerPin = partsConsumerPin parts
                    , cfgConsumerScript = partsConsumerScript parts
                    , network = Testnet
                    }

{- | The registry token a seed determines. Derived, never trusted from
the file: the manifest's own claim is checked against it.
-}
tokenFor :: Deployment -> Either String TokenId
tokenFor dep = do
    seedIn <- parseOutRef (depSeedOutRef dep)
    let name = deriveAssetName (txInToRef seedIn)
        nameHex = T.pack (hex name)
    if nameHex /= depCageToken dep
        then
            Left
                ( "the seed "
                    <> T.unpack (depSeedOutRef dep)
                    <> " determines registry token 0x"
                    <> T.unpack nameHex
                    <> " but the manifest records 0x"
                    <> T.unpack (depCageToken dep)
                )
        else Right (TokenId (AssetName (SBS.toShort name)))

-- ---------------------------------------------------------
-- Checking a manifest against a node
-- ---------------------------------------------------------

{- | Ask a node whether it still agrees with a manifest, and return what
it answered, one line per claim.

Every claim is about the chain or about the compiled release, never
about the file restating itself: the seed determines the recorded
token, this release compiles to the recorded state hash, every recorded
reference output is live at its recorded address carrying the hash the
manifest pins, and the registry's state output carries the recorded
token under the recorded policy. The first claim that fails is raised
by name.
-}
verifyDeployment ::
    Cage.Provider IO ->
    Deployment ->
    CageParts ->
    IO [String]
verifyDeployment prov dep parts = do
    cfg <- either die pure (cageConfigFor dep parts)
    tok <- either die pure (tokenFor dep)
    refs <- resolveReferenceScripts prov dep
    (stateIn, _) <- resolveStateUtxo prov cfg tok
    pure
        ( [ "release "
                <> T.unpack (depRelease dep)
                <> " compiles the state validator to the recorded 0x"
                <> T.unpack (depStatePolicy dep)
          , "seed "
                <> T.unpack (depSeedOutRef dep)
                <> " determines the recorded registry token 0x"
                <> T.unpack (depCageToken dep)
          ]
            <> [ "reference script "
                    <> T.unpack (refRole r)
                    <> " live at "
                    <> T.unpack (refOutRef r)
                    <> " carrying 0x"
                    <> T.unpack (refHash r)
               | (r, _) <- refs
               ]
            <> [ "registry state output "
                    <> T.unpack (renderOutRef stateIn)
                    <> " carries the recorded token"
               ]
        )

{- | The recorded reference outputs, as the node reports them, checked
one by one against the hash the manifest pins.
-}
resolveReferenceScripts ::
    Cage.Provider IO ->
    Deployment ->
    IO [(ReferenceScript, (TxIn, TxOut ConwayEra))]
resolveReferenceScripts prov dep =
    mapM one (depReferenceScripts dep)
  where
    one r = do
        wanted <- either die pure (parseOutRef (refOutRef r))
        addr <- addrOf r
        utxos <- Cage.queryUTxOs prov addr
        case [u | u@(i, _) <- utxos, i == wanted] of
            [] ->
                die
                    ( "the deployment's "
                        <> T.unpack (refRole r)
                        <> " reference output "
                        <> T.unpack (refOutRef r)
                        <> " is not live at "
                        <> T.unpack (refAddress r)
                        <> ". A reference output that has been spent cannot \
                           \be attached to; the deployment must be made again."
                    )
            ((i, o) : _) -> do
                onChain <- case o ^. referenceScriptTxOutL of
                    SJust s -> pure (T.pack (hex (scriptHashBytes (hashScript s))))
                    SNothing ->
                        die
                            ( "the deployment's "
                                <> T.unpack (refRole r)
                                <> " output "
                                <> T.unpack (refOutRef r)
                                <> " carries no reference script"
                            )
                if onChain == refHash r
                    then pure (r, (i, o))
                    else
                        die
                            ( "the deployment's "
                                <> T.unpack (refRole r)
                                <> " output "
                                <> T.unpack (refOutRef r)
                                <> " carries 0x"
                                <> T.unpack onChain
                                <> " but the manifest pins 0x"
                                <> T.unpack (refHash r)
                            )
    addrOf r = case decodeAddrText (refAddressBytes r) of
        Just a -> pure a
        Nothing ->
            die
                ( "the deployment's "
                    <> T.unpack (refRole r)
                    <> " address is not readable: "
                    <> T.unpack (refAddress r)
                )

-- | The registry's state output, by the token it must carry.
resolveStateUtxo ::
    Cage.Provider IO ->
    CageConfig ->
    TokenId ->
    IO (TxIn, TxOut ConwayEra)
resolveStateUtxo prov cfg tok = do
    let stateAddr = cageAddrFromCfg cfg Testnet
    utxos <- Cage.queryUTxOs prov stateAddr
    case findStateUtxo (cagePolicyIdFromCfg cfg) tok utxos of
        Just u -> pure u
        Nothing ->
            die
                ( "no output at the registry address carries the recorded \
                  \token; the node does not know this deployment (wrong \
                  \network, or the registry was never booted here)"
                )

-- ---------------------------------------------------------
-- Attaching
-- ---------------------------------------------------------

-- | What a run gets instead of booting and publishing.
data Attached = Attached
    { attCfg :: CageConfig
    -- ^ The deployed registry's configuration
    , attToken :: TokenId
    -- ^ The deployed registry's token
    , attRefUtxos :: [(TxIn, TxOut ConwayEra)]
    -- ^ The published reference outputs, in manifest order
    , attStateUtxo :: (TxIn, TxOut ConwayEra)
    -- ^ The registry's current state output
    }

{- | Attach a run to a recorded deployment: same checks as
'verifyDeployment', plus the resolved outputs a runner needs in hand.
-}
attach ::
    Cage.Provider IO ->
    Deployment ->
    CageParts ->
    IO Attached
attach prov dep parts = do
    cfg <- either die pure (cageConfigFor dep parts)
    tok <- either die pure (tokenFor dep)
    refs <- resolveReferenceScripts prov dep
    state <- resolveStateUtxo prov cfg tok
    pure
        Attached
            { attCfg = cfg
            , attToken = tok
            , attRefUtxos = map snd refs
            , attStateUtxo = state
            }

-- ---------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------

{- | The authoritative address bytes of a recorded reference output.

The bech32 spelling beside it is for the reader; this is what is
queried, because it round-trips through the manifest exactly.
-}
decodeAddrText :: Text -> Maybe Addr
decodeAddrText t = case B16.decode (BC.pack (T.unpack t)) of
    Right raw -> case decodeAddrEither raw of
        Right a -> Just a
        Left _ -> Nothing
    Left _ -> Nothing

-- | An address as the manifest records it: exact bytes, in hex.
renderAddrBytes :: Addr -> Text
renderAddrBytes = T.pack . hex . serialiseAddr

die :: String -> IO a
die = throwIO . ErrorCall

hex :: ByteString -> String
hex = BC.unpack . B16.encode

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
'attach' compares it with the chain's root, so an empty mirror against
a registry that has grown is refused rather than assumed.
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
