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

import Control.Exception (SomeException, try)
import Control.Tracer (Tracer (..))
import Data.ByteString qualified as BS
    ( readFile
    , replicate
    , writeFile
    )
import Data.List (isInfixOf)
import Data.Text qualified as T (pack)
import Singular.Application.OpenDatum.Command
    ( FoldArgs (..)
    , ProviderSettings (..)
    , RegistryAccess (..)
    , Signer (..)
    , WriteSettings (..)
    )
import Singular.Application.OpenDatum.StateTokenFixture
    ( release
    , token
    )
import Singular.Application.OpenDatum.Value
    ( openDatumApplication
    )
import Singular.CLI.FlagGroup (signerAddress)
import Singular.CLI.Fold (runFold)
import Singular.CLI.ManagedState
    ( addressPartition
    , managedDir
    , resolveSignerDir
    )
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Session (CommandFailure (..), Env (..))
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
    it
        "a fold onto an existing bundle stops before the provider is contacted"
        $ withExternalDir
        $ \root addr bundlePath -> do
            BS.writeFile bundlePath "sentinel bytes"
            stopped <-
                try
                    ( runFold
                        openDatumApplication
                        notListening
                        (foldArgs root addr bundlePath)
                    )
            stopped `shouldSatisfy` namesTheTakenBundle bundlePath
            BS.readFile bundlePath `shouldReturn` "sentinel bytes"
            noJournal root addr
    it
        "a complete library fold against a provider that is not listening writes nothing"
        $ withExternalDir
        $ \root addr bundlePath -> do
            stopped <-
                try
                    ( runFold
                        openDatumApplication
                        notListening
                        (foldArgs root addr bundlePath)
                    )
            stopped `shouldSatisfy` \case
                Left (_ :: SomeException) -> True
                Right _ -> False
            doesFileExist bundlePath `shouldReturn` False
            noJournal root addr
  where
    settings addr bundlePath =
        WriteSettings
            { writeProvider =
                ProviderSettings "http://127.0.0.1:1" 42 Nothing Nothing
            , writeSigner = SignerExternal (T.pack addr) bundlePath
            , writeConfirmTimeout = Nothing
            }
    foldArgs root addr bundlePath =
        FoldArgs
            { foldStateDir = Just root
            , foldAccess = RegistryAccess token
            , foldBlueprint = "b.json"
            , foldWrite = settings addr bundlePath
            , foldRequest = Nothing
            , foldFund = Nothing
            , foldMaxOutlay = Nothing
            , foldReceipt = Nothing
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
    notListening =
        Env
            { envTracer = Tracer (\_ -> pure ())
            , envSource = "test"
            , envLoadRelease = \_ _ -> pure (Right release)
            , envReads = \_ _ -> fail "the provider is not listening: no chain read"
            , envWrites = \_ _ -> fail "the provider is not listening: no chain write"
            }
