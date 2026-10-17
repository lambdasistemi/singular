{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.ManagedStateSpec
Description : #485 managed state: commands run without a directory argument
License     : Apache-2.0

Bob receives Carl's public state token and runs inspect, booking, fold and
readback with no directory argument and no pre-created per-registry state:
every existing-registry command works without @--state-dir@, which remains
only as an optional state-root override with the same identity partitioning.
A new participant's lack of files is never a refusal.

These rows run the effect-free parser over the real module. Each identity is
spelled inline; the token is a well-formed POLICY.NAME the real token reader
accepts. Resolver identity partitioning (network, complete token, stable
wallet identity) and the connected fresh-Bob proof are the track's next rows,
not these.
-}
module Singular.Application.OpenDatum.ManagedStateSpec (spec) where

import Control.Exception (try)
import Control.Tracer (Tracer (..))
import Data.Aeson (Value)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Either (isLeft, isRight)
import Data.List (isInfixOf)
import Data.Text qualified as T
import Data.Word (Word32)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (splitDirectories, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Singular.Application.OpenDatum.Command
    ( CLIError (..)
    , CreateArgs (..)
    , EntryMode (..)
    , ProviderSettings (..)
    , Signer (..)
    , WriteSettings (..)
    , openDatumUsage
    , parseOpenDatumCommand
    )
import Singular.Application.OpenDatum.StateTokenFixture
    ( release
    , seedIn
    , token
    )
import Singular.Application.OpenDatum.Value (openDatumApplication)
import Singular.CLI.Create (runCreate, stateTokenOf)
import Singular.CLI.Live (txInText)
import Singular.CLI.ManagedState
    ( addressPartition
    , managedDir
    , statelessDir
    , walletPartition
    )
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Session (CommandFailure (..), Env (..))
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger (AssetName (..))
import Singular.Registry.LedgerProvider (Asset)
import Singular.Registry.Wallet (Wallet (..), loadWallet)

spec :: Spec
spec = describe "managed state command line (#485)" $ do
    directoryOptional
    rootOverride
    identityPartition
    noWeakening

provider :: [String]
provider =
    [ "--koios-url"
    , "http://127.0.0.1:8080/api/v1"
    , "--network-magic"
    , "42"
    ]

wallet :: [String]
wallet = ["--wallet-skey", "/keys/payment.skey"]

-- | A well-formed state token POLICY.NAME: 28 policy bytes, 32 name bytes.
tokenSpelling :: String
tokenSpelling = replicate 56 'a' <> "." <> replicate 64 'b'

tokenArgs :: [String]
tokenArgs = ["--state-token", tokenSpelling]

seedText :: String
seedText = replicate 64 'b' <> "#1"

directoryOptional :: Spec
directoryOptional = describe "every command works without --state-dir" $ do
    it "create books from seed, blueprint, provider and wallet alone" $
        parseOpenDatumCommand
            ( [ "open-datum"
              , "create"
              , "--seed"
              , seedText
              , "--blueprint"
              , "/srv/plutus.json"
              ]
                <> provider
                <> wallet
            )
            `shouldSatisfy` isRight
    it "insert books from token, key, payload, provider and wallet alone" $
        parseOpenDatumCommand
            ( [ "open-datum"
              , "insert"
              , "--key"
              , "bob"
              , "--payload"
              , "/srv/doc.json"
              , "--blueprint"
              , "/srv/plutus.json"
              ]
                <> tokenArgs
                <> provider
                <> wallet
            )
            `shouldSatisfy` isRight
    it "fold runs from token, provider and wallet alone" $
        parseOpenDatumCommand
            ( ["open-datum", "fold", "--blueprint", "/srv/plutus.json"]
                <> tokenArgs
                <> provider
                <> wallet
            )
            `shouldSatisfy` isRight
    it
        "inspect reads from token, key, blueprint and provider alone, key-free"
        $ parseOpenDatumCommand
            ( [ "open-datum"
              , "inspect"
              , "--key"
              , "bob"
              , "--blueprint"
              , "/srv/plutus.json"
              ]
                <> tokenArgs
                <> provider
            )
            `shouldSatisfy` isRight
    it "terminate books from token, key, provider and wallet alone" $
        parseOpenDatumCommand
            ( [ "open-datum"
              , "terminate"
              , "--key"
              , "bob"
              , "--blueprint"
              , "/srv/plutus.json"
              ]
                <> tokenArgs
                <> provider
                <> wallet
            )
            `shouldSatisfy` isRight
    it "usage documents the managed default state location" $
        openDatumUsage `shouldSatisfy` isInfixOf "XDG_STATE_HOME"

rootOverride :: Spec
rootOverride = describe "an explicit --state-dir stays a root override" $ do
    it "insert still accepts --state-dir" $
        parseOpenDatumCommand
            ( [ "open-datum"
              , "insert"
              , "--key"
              , "bob"
              , "--payload"
              , "/srv/doc.json"
              , "--blueprint"
              , "/srv/plutus.json"
              , "--state-dir"
              , "/srv/root"
              ]
                <> tokenArgs
                <> provider
                <> wallet
            )
            `shouldSatisfy` isRight
    it "inspect still accepts --state-dir" $
        parseOpenDatumCommand
            ( [ "open-datum"
              , "inspect"
              , "--key"
              , "bob"
              , "--blueprint"
              , "/srv/plutus.json"
              , "--state-dir"
              , "/srv/root"
              ]
                <> tokenArgs
                <> provider
            )
            `shouldSatisfy` isRight

identityPartition :: Spec
identityPartition =
    describe "one partition per network, token and wallet identity" $ do
        it "reuses the same journal across key-file paths for one wallet" $ do
            first <- tempWallet 42 (BS.replicate 32 0x01)
            second <- tempWallet 42 (BS.replicate 32 0x01)
            managedDir "/root" 42 token (walletPartition first)
                `shouldBe` managedDir "/root" 42 token (walletPartition second)
        it "separates two wallets under one root" $ do
            first <- tempWallet 42 (BS.replicate 32 0x01)
            second <- tempWallet 42 (BS.replicate 32 0x02)
            managedDir "/root" 42 token (walletPartition first)
                `shouldNotBe` managedDir "/root" 42 token (walletPartition second)
        it "separates two tokens for one wallet" $ do
            me <- tempWallet 42 (BS.replicate 32 0x01)
            managedDir "/root" 42 token (walletPartition me)
                `shouldNotBe` managedDir "/root" 42 otherToken (walletPartition me)
        it "separates two networks for one wallet and token" $ do
            me <- tempWallet 42 (BS.replicate 32 0x01)
            managedDir "/root" 42 token (walletPartition me)
                `shouldNotBe` managedDir "/root" 43 token (walletPartition me)
        it "resolves an address to the same partition as that wallet's writes" $ do
            me <- tempWallet 42 (BS.replicate 32 0x01)
            addressPartition (walletAddr me) `shouldBe` walletPartition me
        it "keeps every generated component path-safe and the sentinel apart" $ do
            let mine = managedDir "/root" 42 token (BS.replicate 28 0x09)
                free = statelessDir "/root" 42 token
            mine `shouldNotBe` free
            free `shouldSatisfy` isInfixOf "read-only"
            all
                genSafe
                (drop (length (splitDirectories "/root")) (splitDirectories mine))
                `shouldBe` True
  where
    tempWallet :: Word32 -> BS.ByteString -> IO Wallet
    tempWallet magic bytes =
        withSystemTempDirectory "managed-keys" $ \dir -> do
            let path = dir <> "/key.skey"
            BS.writeFile path bytes
            loadWallet magic path
    otherToken :: Asset
    otherToken = case token of
        (policy, _) -> (policy, AssetName (SBS.toShort (BS.replicate 32 0x07)))
    genSafe = all (`elem` (['0' .. '9'] <> ['a' .. 'z'] <> "-"))

noWeakening :: Spec
noWeakening = describe "no refusal is weakened" $ do
    it "still refuses --registry with its rename" $
        parseOpenDatumCommand
            ( [ "open-datum"
              , "inspect"
              , "--key"
              , "bob"
              , "--blueprint"
              , "b"
              , "--registry"
              , "/srv/reg"
              ]
                <> provider
                <> tokenArgs
            )
            `shouldSatisfy` isLeftWithRename
    it "insert without a key is still refused" $
        parseOpenDatumCommand
            ( [ "open-datum"
              , "insert"
              , "--payload"
              , "/srv/doc.json"
              , "--blueprint"
              , "/srv/plutus.json"
              ]
                <> tokenArgs
                <> provider
                <> wallet
            )
            `shouldSatisfy` isLeft
    it "insert without a state token is still refused" $
        parseOpenDatumCommand
            ( [ "open-datum"
              , "insert"
              , "--key"
              , "bob"
              , "--payload"
              , "/srv/doc.json"
              , "--blueprint"
              , "/srv/plutus.json"
              ]
                <> provider
                <> wallet
            )
            `shouldSatisfy` isLeft
    it
        "an explicit seed against an existing partition journal is refused before any chain read"
        $ withSystemTempDirectory "managed-early-refusal"
        $ \root ->
            withSystemTempDirectory "managed-early-keys" $ \keys -> do
                let magic = 42
                    keyPath = keys </> "payment.skey"
                BS.writeFile keyPath (BS.replicate 32 0x01)
                caller <- loadWallet magic keyPath
                named <- either fail pure (parseOutRef (txInText seedIn))
                let dir =
                        managedDir
                            root
                            magic
                            (stateTokenOf release named)
                            (walletPartition caller)
                createDirectoryIfMissing True dir
                writeFile (dir </> "journal.jsonl") "{}\n"
                outcome <-
                    try
                        ( runCreate
                            openDatumApplication
                            noChainEnv
                            (earlyArgs root keyPath magic)
                        )
                        :: IO (Either CommandFailure Value)
                outcome `shouldSatisfy` isExistingStateRefusal
  where
    isLeftWithRename = \case
        Left (BadValue "--registry" _) -> True
        _ -> False
    isExistingStateRefusal = \case
        Left (CommandFailure ClientRefusal why _) ->
            "already holds your state" `isInfixOf` why
        _ -> False
    earlyArgs root keyPath magic =
        CreateArgs
            { createStateDir = Just root
            , createBlueprint = "test-blueprint.json"
            , createMode =
                Submit
                    WriteSettings
                        { writeProvider =
                            ProviderSettings
                                { providerUrl = "http://127.0.0.1:1"
                                , providerMagic = magic
                                , providerTokenFile = Nothing
                                , providerTimeDirectory = Nothing
                                }
                        , writeSigner = SignerKeyFile keyPath
                        , writeConfirmTimeout = Nothing
                        }
            , createSeed = Just (T.unpack (txInText seedIn))
            , createPreview = False
            , createReceipt = Nothing
            , createProcessTime = 1000
            , createRetractTime = 1000
            }
    noChainEnv =
        Env
            { envTracer = Tracer (\_ -> pure ())
            , envSource = "test"
            , envLoadRelease = \_ _ -> pure (Right release)
            , envReads =
                \_ _ ->
                    fail
                        "the early existing-state refusal must fire before any chain read"
            , envWrites =
                \_ _ _ ->
                    fail
                        "the early existing-state refusal must fire before any chain write"
            }
