{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.PartitionLibrarySpec
Description : Stable wallet partitions and refusal before chain access
License     : Apache-2.0
-}
module Singular.Application.OpenDatum.PartitionLibrarySpec (spec) where

import Control.Exception (try)
import Control.Tracer (Tracer (..))
import Data.Aeson (Value)
import Data.ByteString qualified as BS
    ( ByteString
    , replicate
    , writeFile
    )
import Data.ByteString.Short qualified as SBS (toShort)
import Data.List (isInfixOf)
import Data.Text qualified as T (unpack)
import Data.Word (Word32)
import Singular.Application.OpenDatum.StateTokenFixture
    ( release
    , seedIn
    , token
    )
import Singular.Application.OpenDatum.Value
    ( openDatumApplication
    )
import Singular.CLI.Command
    ( CreateArgs
        ( CreateArgs
        , createBlueprint
        , createMode
        , createPreview
        , createProcessTime
        , createReceipt
        , createRetractTime
        , createSaveStateTokenTo
        , createSeed
        , createStateDir
        )
    , EntryMode (Submit)
    , ProviderSettings
        ( ProviderSettings
        , providerMagic
        , providerTimeDirectory
        , providerTokenFile
        , providerUrl
        )
    , WriteSettings
        ( WriteSettings
        , writeConfirmTimeout
        , writeProvider
        , writeSigner
        )
    )
import Singular.CLI.Create (runCreate, stateTokenOf)
import Singular.CLI.FlagGroup (Signer (SignerKeyFile))
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
import Singular.Registry.Wallet (Wallet (walletAddr), loadWallet)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (splitDirectories, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldNotBe
    , shouldSatisfy
    )

spec :: Spec
spec = do
    identityPartition
    existingPartitionRefusal

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

existingPartitionRefusal :: Spec
existingPartitionRefusal = do
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
            , createSaveStateTokenTo = Nothing
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
                \_ _ ->
                    fail
                        "the early existing-state refusal must fire before any chain write"
            }
