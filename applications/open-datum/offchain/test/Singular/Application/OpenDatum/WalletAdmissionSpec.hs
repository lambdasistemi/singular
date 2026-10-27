{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.Application.OpenDatum.WalletAdmissionSpec
Description : Wallet admission through the funding and session library functions
License     : Apache-2.0
-}
module Singular.Application.OpenDatum.WalletAdmissionSpec (spec) where

import Cardano.Ledger.Api.Tx.Out (EraTxOut (mkBasicTxOut))
import Cardano.Ledger.Mary.Value (MaryValue (MaryValue))
import Cardano.Ledger.TxIn (TxIn (..))
import Control.Exception (SomeException, try)
import Control.Tracer (nullTracer)
import Data.ByteString qualified as BS (writeFile)
import Data.ByteString.Base16 qualified as B16 (encode)
import Data.ByteString.Char8 qualified as BC (replicate)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text qualified as T (pack, unpack)
import Singular.CLI.Outlay (walletShortfall)
import Singular.CLI.Plan (refuseUnderfunded)
import Singular.CLI.Receipt (OutcomeClass (ClientRefusal))
import Singular.CLI.Session (CommandFailure (CommandFailure))
import Singular.Provider.Koios.FakeServer qualified as Fake
    ( replayFixtures
    , withFakeKoios
    )
import Singular.Provider.Koios.Recorded (loadFixtureSet)
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger (Coin (Coin))
import Singular.Registry.Lifecycle (protocolFeeReserve)
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.Terminal (withWritesObserved)
import Singular.Registry.TxBuilder.BookingFixture
    ( payer
    , preprodParams
    )
import Singular.Registry.Wallet (loadWallet)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
    ( Spec
    , expectationFailure
    , it
    , shouldBe
    , shouldReturn
    , shouldSatisfy
    )

spec :: Spec
spec = do
    it "refuses a wallet under the fold reserve before building" $ do
        let outs =
                [ (fundOutput 11, mkBasicTxOut payer (MaryValue (Coin 500_000) mempty))
                , (fundOutput 12, mkBasicTxOut payer (MaryValue (Coin 500_000) mempty))
                ]
            Coin reserve = protocolFeeReserve preprodParams []
            held = 500_000 + 500_000
        held `shouldSatisfy` (< reserve)
        walletShortfall outs reserve `shouldBe` Just (held, reserve - held)
        reached <- newIORef False
        result <-
            try $ do
                refuseUnderfunded
                    payer
                    outs
                    reserve
                    "fold reserve"
                writeIORef reached True
        case result of
            Left (CommandFailure ClientRefusal why _) ->
                why `shouldSatisfy` ("(client policy)" `isSuffixOf`)
            Left other ->
                expectationFailure ("wrong refusal: " <> show other)
            Right _ ->
                expectationFailure "a wallet under the reserve reached the builder"
        readIORef reached `shouldReturn` False
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

fundOutput :: Int -> TxIn
fundOutput n =
    either
        (error . ("fundOutput: " <>))
        id
        (parseOutRef (T.pack (replicate 64 'f' <> "#" <> show n)))

isSuffixOf :: String -> String -> Bool
isSuffixOf suffix whole = reverse suffix `isPrefixOf` reverse whole
  where
    isPrefixOf [] _ = True
    isPrefixOf _ [] = False
    isPrefixOf (x : xs) (y : ys) = x == y && isPrefixOf xs ys

requireRight :: (Show e) => Either e a -> IO a
requireRight = either (fail . show) pure
