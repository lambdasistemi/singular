{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.Application.OpenDatum.ManagedStateSpec
Description : External signer and library fold admission before provider access
License     : Apache-2.0

Direct library checks keep their signer and provider assertions without parsing
retired command routes. Identity partitioning is checked by PartitionLibrarySpec.
-}
module Singular.Application.OpenDatum.ManagedStateSpec (spec) where

import Control.Exception (try)
import Data.ByteString qualified as BS
    ( readFile
    , replicate
    , writeFile
    )
import Data.List (isInfixOf)
import Data.Text qualified as T (pack)
import Singular.Application.OpenDatum.Command
    ( ProviderSettings (..)
    , Signer (..)
    , WriteSettings (..)
    )
import Singular.Application.OpenDatum.StateTokenFixture
    ( token
    )
import Singular.CLI.FlagGroup (signerAddress)
import Singular.CLI.ManagedState
    ( addressPartition
    , managedDir
    , resolveSignerDir
    )
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Session (CommandFailure (..))
import Singular.Registry.Wallet
    ( Wallet (..)
    , bech32Address
    , loadWallet
    )
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldReturn
    , shouldSatisfy
    )

spec :: Spec
spec = describe "external signer admission at the library boundary" $ do
    it
        "refuses an existing bundle before any chain read and leaves its bytes untouched"
        $ withExternalDir
        $ \root addr bundlePath -> do
            BS.writeFile bundlePath "sentinel bytes"
            let ws = settings addr bundlePath
            stopped <-
                try (resolveSignerDir (Just root) 42 token (writeSigner ws))
            stopped `shouldSatisfy` namesTheTakenBundle bundlePath
            BS.readFile bundlePath `shouldReturn` "sentinel bytes"
            noJournal root addr
  where
    settings addr bundlePath =
        WriteSettings
            { writeProvider =
                ProviderSettings "http://127.0.0.1:1" 42 Nothing Nothing
            , writeSigner = SignerExternal (T.pack addr) bundlePath
            , writeConfirmTimeout = Nothing
            }
    namesTheTakenBundle bundle = \case
        Left (CommandFailure ClientRefusal why _) -> bundle `isInfixOf` why && "already exists" `isInfixOf` why
        _ -> False
    noJournal root addr =
        doesFileExist (partitionOf root addr </> "journal.jsonl")
            `shouldReturn` False
    partitionOf root addr =
        managedDir
            root
            42
            token
            ( either
                (error . ("partitionOf: " <>))
                addressPartition
                (signerAddress (T.pack addr))
            )
    withExternalDir use = withSystemTempDirectory "external-write" $ \root -> do
        let path = root </> "payment.skey"
        BS.writeFile path (BS.replicate 32 0xa5)
        signing <- loadWallet 42 path
        use root (bech32Address (walletAddr signing)) (root </> "run.bundle")
