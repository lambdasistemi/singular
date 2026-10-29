{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.PartitionLibrarySpec
Description : Stable wallet partitions and refusal before chain access
License     : Apache-2.0
-}
module Singular.Application.OpenDatum.PartitionLibrarySpec (spec) where

import Data.ByteString qualified as BS
    ( ByteString
    , replicate
    , writeFile
    )
import Data.ByteString.Short qualified as SBS (toShort)
import Data.List (isInfixOf)
import Data.Word (Word32)
import Singular.Application.OpenDatum.StateTokenFixture (token)
import Singular.CLI.ManagedState
    ( addressPartition
    , managedDir
    , statelessDir
    , walletPartition
    )
import Singular.Registry.Ledger (AssetName (..))
import Singular.Registry.LedgerProvider (Asset)
import Singular.Registry.Wallet (Wallet (walletAddr), loadWallet)
import System.FilePath (splitDirectories)
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
