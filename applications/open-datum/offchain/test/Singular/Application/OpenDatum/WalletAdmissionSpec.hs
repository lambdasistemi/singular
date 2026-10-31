{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.Application.OpenDatum.WalletAdmissionSpec
Description : Wallet admission through the funding and session library functions
License     : Apache-2.0
-}
module Singular.Application.OpenDatum.WalletAdmissionSpec (spec) where

import Control.Exception (SomeException, try)
import Control.Tracer (nullTracer)
import Data.ByteString qualified as BS (writeFile)
import Data.ByteString.Base16 qualified as B16 (encode)
import Data.ByteString.Char8 qualified as BC (replicate)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text qualified as T (unpack)
import Singular.Provider.Koios.FakeServer qualified as Fake
    ( replayFixtures
    , withFakeKoios
    )
import Singular.Provider.Koios.Recorded (loadFixtureSet)
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.Terminal (withWritesObserved)
import Singular.Registry.Wallet (loadWallet)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
    ( Spec
    , it
    , shouldReturn
    )

spec :: Spec
spec = do
    it "opens a write session for 20 ada in two outputs with no threshold" $ do
        withSystemTempDirectory "wallet-floor-open" $ \dir -> do
            let keyPath = dir </> "payment.skey"
            BS.writeFile keyPath (B16.encode (BC.replicate 32 'w'))
            _ <- loadWallet 1 keyPath
            set <- loadFixtureSet "test/fixtures/koios/preprod" >>= requireRight
            Fake.withFakeKoios (Fake.replayFixtures set) $ \url _ -> do
                let settings = ProviderSettings (T.unpack url) 1 Nothing Nothing
                ran <- newIORef False
                _ <-
                    try @SomeException
                        $ withWritesObserved
                            nullTracer
                            nullTracer
                            (const (pure ()))
                            settings
                        $ \_ ->
                            writeIORef ran True
                readIORef ran `shouldReturn` True

requireRight :: (Show e) => Either e a -> IO a
requireRight = either (fail . show) pure
