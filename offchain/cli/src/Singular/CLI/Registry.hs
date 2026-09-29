{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Singular.CLI.Registry
Description : The saved registry a command attaches to, and its identity checks
License     : Apache-2.0

A registry directory holds four files, each with one owner:

* @registry.json@ — the public saved identity ('RegistryConfig'): the
  network, the wallet address the registry was booted from, the open
  application and the three witness policies, and the deployment record
  ("Singular.Registry.Deployment") naming the seed, the token and the
  published reference outputs. No signing key, no key path.
* @registry.mirror.json@ — the authenticated trie, the deployment
  family's own proof mirror.
* @state.json@ — the commitment the last confirmed write left
  ('LocalState'), kept apart from the mirror so an altered mirror and a
  moved chain are told apart.
* @journal.jsonl@ — every submission and confirmation, appended
  ("Singular.CLI.Receipt").

Every check here is pure or reads only these files: which network,
wallet, seed and pins a command may use is decided before a node is
contacted.
-}
module Singular.CLI.Registry
    ( -- * Saved identity
      RegistryConfig (..)
    , Pins (..)
    , LocalState (..)
    , configVersion
    , mkRegistryConfig

      -- * The release a command brings
    , Release (..)
    , loadRelease
    , registryConfigFor
    , pinsOf
    , partsOf
    , hexT

      -- * Files
    , configPath
    , statePath
    , readConfig
    , writeConfig
    , readLocalState
    , writeLocalState

      -- * Identity checks
    , IdentityError (..)
    , renderIdentityError
    , checkNetwork
    , checkWallet
    , checkPins
    , checkSeed
    , refuseExisting
    ) where

import Control.Exception (ErrorCall (..), throwIO)
import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word32, Word64)
import GHC.Generics (Generic)
import System.Directory (doesFileExist)
import System.FilePath ((</>))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.TxIn (TxIn)

import Singular.Application.OpenDatum.Script
    ( Application (..)
    , applicationTitle
    , loadApplicationCodes
    )
import Singular.Registry.Blueprint
    ( NamingCodes (..)
    , extractCompiledCode
    , loadBlueprint
    )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Config.Application
    ( RegistryEconomics (..)
    , configForApplication
    )
import Singular.Registry.Deployment
    ( CageParts (..)
    , Deployment
    , mirrorPathFor
    , renderAddrBytes
    , renderOutRef
    )
import Singular.Registry.Ledger (Coin (..), ConwayEra)
import Singular.Registry.Node (bech32Address)
import Singular.Registry.TxBuilder.Edges (adaOnlyOut)
import Singular.Registry.TxBuilder.Internal (scriptHashBytes)
import Singular.Registry.Types (OnChainTxOutRef)

-- | The pins a registry identity carries, as hex.
data Pins = Pins
    { pinState :: Text
    , pinApplication :: Text
    , pinAbsent :: Text
    , pinActive :: Text
    , pinTerminal :: Text
    }
    deriving stock (Eq, Show, Generic)

instance ToJSON Pins where
    toJSON = Aeson.genericToJSON Aeson.defaultOptions
instance FromJSON Pins where
    parseJSON = Aeson.genericParseJSON Aeson.defaultOptions

-- | The public saved identity of one registry.
data RegistryConfig = RegistryConfig
    { confVersion :: Int
    , confNetworkMagic :: Word32
    , confWalletAddress :: Text
    -- ^ Hex bytes of the address the registry was booted from
    , confWalletBech32 :: Text
    , confApplication :: Text
    -- ^ The blueprint validator the application policy is compiled from
    , confPins :: Pins
    , confDeployment :: Deployment
    }
    deriving stock (Eq, Show, Generic)

instance ToJSON RegistryConfig where
    toJSON = Aeson.genericToJSON Aeson.defaultOptions
instance FromJSON RegistryConfig where
    parseJSON = Aeson.genericParseJSON Aeson.defaultOptions

-- | The commitment the last confirmed write left.
data LocalState = LocalState
    { localVersion :: Int
    , localToken :: Text
    , localRoot :: Text
    , localLastTx :: Maybe Text
    , localLastSlot :: Maybe Word64
    }
    deriving stock (Eq, Show, Generic)

instance ToJSON LocalState where
    toJSON = Aeson.genericToJSON Aeson.defaultOptions
instance FromJSON LocalState where
    parseJSON = Aeson.genericParseJSON Aeson.defaultOptions

-- | The file format version this build reads and writes.
configVersion :: Int
configVersion = 1

-- | The saved identity of a registry booted from this wallet.
mkRegistryConfig
    :: Word32 -> Addr -> Pins -> Deployment -> RegistryConfig
mkRegistryConfig magic addr pins dep =
    RegistryConfig
        { confVersion = configVersion
        , confNetworkMagic = magic
        , confWalletAddress = renderAddrBytes addr
        , confWalletBech32 = T.pack (bech32Address addr)
        , confApplication = applicationTitle OpenDatumApplication
        , confPins = pins
        , confDeployment = dep
        }

-- ---------------------------------------------------------
-- The release a command brings
-- ---------------------------------------------------------

-- | The compiled code a registry command needs from the blueprint.
data Release = Release
    { releaseState :: SBS.ShortByteString
    , releaseRequest :: SBS.ShortByteString
    , releaseCodes :: NamingCodes
    {- ^ @open_datum.open_datum@ unapplied and @witness.witness@, from the
    same blueprint
    -}
    }

-- | Read the registry blueprint a command was given.
loadRelease :: FilePath -> IO (Either String Release)
loadRelease path = do
    loaded <- loadBlueprint path
    pure $ do
        bp <-
            either (Left . ("the blueprint does not parse: " <>)) Right loaded
        let code name =
                maybe
                    (Left ("the blueprint carries no " <> name))
                    Right
                    (extractCompiledCode (T.pack name) bp)
        Release
            <$> code "state.state"
            <*> code "request.request"
            <*> loadApplicationCodes OpenDatumApplication bp

-- | The windows and tip a registry this command creates is booted with.
economics :: RegistryEconomics
economics =
    RegistryEconomics
        { reProcessTime = 120_000
        , reRetractTime = 30_000
        , reTip = Coin 1_000_000
        }

{- | The configuration of the open-datum registry this release boots from
this seed, and the codes as that registry runs them: the application
applied to the registry identity the seed determines, and
@witness(kind, registry)@ at kinds 0, 1 and 2.
-}
registryConfigFor
    :: Release -> OnChainTxOutRef -> (CageConfig, NamingCodes)
registryConfigFor rel =
    configForApplication
        OpenDatumApplication
        (releaseCodes rel)
        (releaseState rel)
        (releaseRequest rel)
        economics
        Testnet

-- | The pins a configuration carries, as a saved identity names them.
pinsOf :: CageConfig -> Pins
pinsOf cfg =
    Pins
        { pinState = hexT (scriptHashBytes (cfgScriptHash cfg))
        , pinApplication = hexT (SBS.fromShort (cfgApplicationPolicy cfg))
        , pinAbsent = hexT (SBS.fromShort (cfgAbsentPolicy cfg))
        , pinActive = hexT (SBS.fromShort (cfgActivePolicy cfg))
        , pinTerminal = hexT (SBS.fromShort (cfgTerminalPolicy cfg))
        }

-- | The compiled halves 'attach' checks a deployment record against.
partsOf :: CageConfig -> CageParts
partsOf cfg =
    CageParts
        { partsStateBytes = cageScriptBytes cfg
        , partsRequestBytes = requestScriptBytes cfg
        , partsApplicationPolicy = cfgApplicationPolicy cfg
        , partsActivePolicy = cfgActivePolicy cfg
        , partsAbsentPolicy = cfgAbsentPolicy cfg
        , partsTerminalPolicy = cfgTerminalPolicy cfg
        , partsConsumerScript = cfgConsumerScript cfg
        }

hexT :: ByteString -> Text
hexT = T.pack . BC.unpack . B16.encode

-- ---------------------------------------------------------
-- Files
-- ---------------------------------------------------------

configPath, statePath :: FilePath -> FilePath
configPath dir = dir </> "registry.json"
statePath dir = dir </> "state.json"

readJsonFile :: (FromJSON a) => String -> FilePath -> IO a
readJsonFile what path =
    Aeson.eitherDecodeFileStrict' path
        >>= either
            (\err -> throwIO (ErrorCall (what <> " " <> path <> ": " <> err)))
            pure

writeJsonFile :: (ToJSON a) => FilePath -> a -> IO ()
writeJsonFile path = BL.writeFile path . (<> "\n") . encodePretty

-- | Read a saved identity, refusing a version this build does not know.
readConfig :: FilePath -> IO RegistryConfig
readConfig dir = do
    conf <- readJsonFile "registry configuration" (configPath dir)
    if confVersion conf == configVersion
        then pure conf
        else
            throwIO
                ( ErrorCall
                    (renderIdentityError (UnsupportedVersion (confVersion conf)))
                )

writeConfig :: FilePath -> RegistryConfig -> IO ()
writeConfig dir = writeJsonFile (configPath dir)

readLocalState :: FilePath -> IO LocalState
readLocalState dir = readJsonFile "registry state" (statePath dir)

writeLocalState :: FilePath -> LocalState -> IO ()
writeLocalState dir = writeJsonFile (statePath dir)

-- ---------------------------------------------------------
-- Identity checks
-- ---------------------------------------------------------

-- | Why a command may not use this registry, wallet, network or seed.
data IdentityError
    = NetworkMismatch Word32 Word32
    | WalletMismatch Text Text
    | PinMismatch String Text Text
    | SeedNotInWallet Text
    | SeedNotAdaOnly Text
    | RegistryExists FilePath
    | UnsupportedVersion Int
    deriving stock (Eq, Show)

renderIdentityError :: IdentityError -> String
renderIdentityError = \case
    NetworkMismatch saved given ->
        "the registry was saved on network magic "
            <> show saved
            <> " but this command names "
            <> show given
    WalletMismatch saved given ->
        "the registry was booted from wallet "
            <> T.unpack saved
            <> " but this command signs with "
            <> T.unpack given
    PinMismatch name saved given ->
        "the "
            <> name
            <> " pin differs: the registry saved 0x"
            <> T.unpack saved
            <> " but this blueprint and seed give 0x"
            <> T.unpack given
    SeedNotInWallet seed ->
        "the seed "
            <> T.unpack seed
            <> " is not an unspent output of this wallet"
    SeedNotAdaOnly seed ->
        "the seed "
            <> T.unpack seed
            <> " carries a token or a reference script; a seed must hold ada only"
    RegistryExists dir ->
        dir
            <> " already holds a registry or its journal; create never \
               \overwrites one"
    UnsupportedVersion v ->
        "registry files of version "
            <> show v
            <> " are not version "
            <> show configVersion

checkNetwork :: RegistryConfig -> Word32 -> Either IdentityError ()
checkNetwork conf magic
    | confNetworkMagic conf == magic = Right ()
    | otherwise = Left (NetworkMismatch (confNetworkMagic conf) magic)

checkWallet :: RegistryConfig -> Addr -> Either IdentityError ()
checkWallet conf addr
    | confWalletAddress conf == renderAddrBytes addr = Right ()
    | otherwise =
        Left
            (WalletMismatch (confWalletBech32 conf) (T.pack (bech32Address addr)))

-- | Every pin the saved identity names, compared in a fixed order.
checkPins :: RegistryConfig -> Pins -> Either IdentityError ()
checkPins conf given = mapM_ one fields
  where
    saved = confPins conf
    one (name, field)
        | field saved == field given = Right ()
        | otherwise = Left (PinMismatch name (field saved) (field given))
    fields =
        [ ("state", pinState)
        , ("application", pinApplication)
        , ("absent", pinAbsent)
        , ("active", pinActive)
        , ("terminal", pinTerminal)
        ]

-- | The seed, as this wallet holds it: unspent, ada only.
checkSeed
    :: TxIn
    -> [(TxIn, TxOut ConwayEra)]
    -> Either IdentityError (TxIn, TxOut ConwayEra)
checkSeed seed utxos = case [u | u@(i, _) <- utxos, i == seed] of
    [] -> Left (SeedNotInWallet (renderOutRef seed))
    (u@(_, out) : _)
        | adaOnlyOut out -> Right u
        | otherwise -> Left (SeedNotAdaOnly (renderOutRef seed))

-- | Refuse a directory that already holds any file of a registry.
refuseExisting :: FilePath -> IO (Either IdentityError ())
refuseExisting dir = do
    present <-
        or
            <$> mapM
                doesFileExist
                [ configPath dir
                , statePath dir
                , mirrorPathFor (configPath dir)
                , dir </> "journal.jsonl"
                ]
    pure (if present then Left (RegistryExists dir) else Right ())
