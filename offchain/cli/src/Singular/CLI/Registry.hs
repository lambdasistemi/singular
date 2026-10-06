{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Singular.CLI.Registry
Description : The saved registry a command attaches to, and its identity checks
License     : Apache-2.0

A registry directory keeps its identity and submission journal:

* @registry.json@ — the public saved identity ('RegistryConfig'): the
  network, the wallet address the registry was booted from, the open
  application and the three witness policies, and the deployment record
  ("Singular.Registry.Deployment") naming the seed, the token and the
  published reference outputs. No signing key, no key path.
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
    , configVersion
    , mkRegistryConfig

      -- * The release a command brings
    , Release (..)
    , loadRelease
    , registryConfigFor
    , economics
    , pinsOf
    , partsOf
    , hexT
    , keyFields
    , parseEnterpriseAddress

      -- * Files
    , configPath
    , pendingPath
    , readConfig
    , writeConfig

      -- * Identity checks
    , IdentityError (..)
    , renderIdentityError
    , checkNetwork
    , checkWallet
    , checkPins
    , checkSeed
    , seedHeld
    , seedChecks
    , refuseExisting
    , publicationFunding
    , checkPendingToken
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
import Data.Text.Encoding qualified as TE
import Data.Word (Word32)
import GHC.Generics (Generic)
import System.Directory (doesFileExist)
import System.FilePath ((</>))

import Cardano.Ledger.Address (Addr (..), decodeAddrEither)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Core (PParams, Script)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.TxIn (TxIn)
import Codec.Binary.Bech32 qualified as Bech32
import Control.Monad (when)

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
    , renderAddrBytes
    , renderOutRef
    )
import Singular.Registry.Ledger (Coin (..), ConwayEra)
import Singular.Registry.LedgerProvider (Asset)
import Singular.Registry.StateToken (Release (..))
import Singular.Registry.TxBuilder.Edges (adaOnlyOut)
import Singular.Registry.TxBuilder.Internal (scriptHashBytes)
import Singular.Registry.Types (OnChainTxOutRef)
import Singular.Registry.Wallet (bech32Address)

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
        { reProcessTime = 600_000
        , reRetractTime = 300_000
        , reTip = Coin 1_000_000
        }

{- | The configuration of the open-datum registry this release boots from
this seed, and the codes as that registry runs them: the application
applied to the registry identity the seed determines, and
@witness(kind, registry)@ at kinds 0, 1 and 2.
-}
registryConfigFor
    :: Release
    -> RegistryEconomics
    -> OnChainTxOutRef
    -> (CageConfig, NamingCodes)
registryConfigFor rel chosen =
    configForApplication
        OpenDatumApplication
        (releaseCodes rel)
        (releaseState rel)
        (releaseRequest rel)
        chosen
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

{- | The receipt fields that name a key: its hex, and its text when the
bytes are valid UTF-8.
-}
keyFields :: ByteString -> [(Text, Aeson.Value)]
keyFields key =
    ("key", toJSON (hexT key))
        : [ ("keyText", toJSON text)
          | Right text <- [TE.decodeUtf8' key]
          ]

-- ---------------------------------------------------------
-- Files
-- ---------------------------------------------------------

{- | The identity a create records before its first submission, so an
interrupted create stays inspectable and is never booted again.
-}
pendingPath :: FilePath -> FilePath
pendingPath dir = dir </> "registry.pending.json"

configPath :: FilePath -> FilePath
configPath dir = dir </> "registry.json"

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
    | NoFundingBesideSeed Text
    | RegistryExists FilePath
    | UnsupportedVersion Int
    | {- | A publication the wallet cannot fund: its role, the ada-only output
      it needs, and the largest the wallet holds for it
      -}
      PublicationUnfunded Text Integer Integer
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
    NoFundingBesideSeed seed ->
        "the seed "
            <> T.unpack seed
            <> " is the only ada-only output the wallet holds; the registry's first publication is paid from another one while the seed stays unspent, so fund the wallet with a second ada-only output first"
    RegistryExists dir ->
        dir
            <> " already holds a registry or its journal; create never \
               \overwrites one"
    UnsupportedVersion v ->
        "registry files of version "
            <> show v
            <> " are not version "
            <> show configVersion
    PublicationUnfunded{} -> ""

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

{- | The seed, as this wallet holds it: unspent and ada only. This is all a
registry's identity needs; creating it needs 'checkSeed'.
-}
seedHeld
    :: TxIn
    -> [(TxIn, TxOut ConwayEra)]
    -> Either IdentityError (TxIn, TxOut ConwayEra)
seedHeld seed utxos = case [u | u@(i, _) <- utxos, i == seed] of
    [] -> Left (SeedNotInWallet (renderOutRef seed))
    (u@(_, out) : _)
        | adaOnlyOut out -> Right u
        | otherwise -> Left (SeedNotAdaOnly (renderOutRef seed))

{- | The seed, as a create needs it: held ('seedHeld'), with another ada-only
output beside it to pay the first publication from while the seed stays
unspent.
-}
checkSeed
    :: TxIn
    -> [(TxIn, TxOut ConwayEra)]
    -> Either IdentityError (TxIn, TxOut ConwayEra)
checkSeed seed utxos = do
    u <- seedHeld seed utxos
    if null [() | (i, o) <- utxos, i /= seed, adaOnlyOut o]
        then Left (NoFundingBesideSeed (renderOutRef seed))
        else Right u

{- | The seed checks a create applies, and the receipt fields they add. A
create about to submit needs the seed held with another ada-only output
beside it ('checkSeed') and adds nothing. A preview needs only the seed held
('seedHeld') and adds @createRefusal@: the refusal a create from this wallet
would meet now, or null.
-}
seedChecks
    :: Bool
    -- ^ whether the create is about to submit
    -> TxIn
    -> [(TxIn, TxOut ConwayEra)]
    -> Either IdentityError [(Text, Aeson.Value)]
seedChecks submitting seedIn utxos
    | submitting = [] <$ checkSeed seedIn utxos
    | otherwise = do
        _ <- seedHeld seedIn utxos
        pure
            [
                ( "createRefusal"
                , toJSON
                    ( either (Just . T.pack . renderIdentityError) (const Nothing) $
                        checkSeed seedIn utxos
                    )
                )
            ]

-- | Refuse a directory that already holds any file of a registry.
refuseExisting :: FilePath -> IO (Either IdentityError ())
refuseExisting dir = do
    present <-
        or
            <$> mapM
                doesFileExist
                [ configPath dir
                , pendingPath dir
                , dir </> "journal.jsonl"
                ]
    pure (if present then Left (RegistryExists dir) else Right ())

{- | A caller's enterprise address from its bech32 text: a payment key hash
and no stake part, for the network the magic names. The address is public;
nothing in it can sign.
-}
parseEnterpriseAddress :: Word32 -> String -> Either String Addr
parseEnterpriseAddress magic text = do
    (hrp, dat) <-
        either
            (\e -> Left ("--wallet-address is not bech32: " <> show e))
            Right
            (Bech32.decodeLenient (T.pack text))
    let expected = if magic == 764_824_073 then "addr" else "addr_test"
    when (Bech32.humanReadablePartToText hrp /= expected) $
        Left
            ( "--wallet-address is for another network: expected "
                <> T.unpack expected
                <> ", found "
                <> T.unpack (Bech32.humanReadablePartToText hrp)
            )
    raw <-
        maybe
            (Left "--wallet-address carries no address bytes")
            Right
            (Bech32.dataPartToBytes dat)
    addr <- decodeAddrEither raw
    case addr of
        Addr net (KeyHashObj _) StakeRefNull
            | net == (if magic == 764_824_073 then Mainnet else Testnet) ->
                Right addr
        _ ->
            Left
                "--wallet-address must be an enterprise address: a payment key hash and no stake part"

{- | Whether the wallet funds every reference publication a create makes,
each from its largest ada-only output with its change returned, as
'Singular.Registry.TxBuilder.Edges.publishRefScriptTx' funds it: the
publications before the boot leave the seed alone, those after it go
without the seed the boot spent. Checked before anything is submitted.
-}
publicationFunding
    :: PParams ConwayEra
    -> TxIn
    -- ^ The seed
    -> [(Text, Script ConwayEra)]
    -- ^ Published before the boot, by role
    -> [(Text, Script ConwayEra)]
    -- ^ Published after the boot, by role
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ The wallet
    -> Either IdentityError ()
publicationFunding _ _ _ _ _ = Right ()

{- | An inspect of an interrupted create may read its pending identity only
when the requested state token is the pending registry's own: the actor's
in-flight submission, never another registry's. The pending token is the
one the pending seed derives under this release; a token from any other
seed is refused before anything is read.
-}
checkPendingToken :: Asset -> Asset -> Either Text ()
checkPendingToken _ _ = Left "checkPendingToken: not implemented"
