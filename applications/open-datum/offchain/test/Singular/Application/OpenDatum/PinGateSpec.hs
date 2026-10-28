{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.PinGateSpec
Description : Library application-pin resolution
License     : Apache-2.0

The library compares application pins stated by hash or compiled script.
Direct registry resolution retains every form assertion independently of public
command routing.
-}
module Singular.Application.OpenDatum.PinGateSpec (spec) where

import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Coin (Coin (..))
import Data.Aeson qualified as Aeson ()
import Data.Aeson.Key qualified as Key ()
import Data.Aeson.KeyMap qualified as KeyMap ()
import Data.ByteString qualified as BS (replicate)
import Data.ByteString.Char8 qualified as BC ()
import Data.ByteString.Short qualified as SBS (toShort)
import Data.IORef (newIORef)
import Data.Map.Strict qualified as Map (singleton)
import Data.Text qualified as T ()
import PlutusTx.Builtins.Internal (BuiltinByteString (..))
import Singular.Application.OpenDatum.StateTokenFixture qualified as Fixture
    ( Chain (chainOutputs)
    , bootState
    , chainSession
    , honestChain
    , release
    , seedIn
    , stateIn
    , stateOutput
    , token
    )
import Singular.Application.OpenDatum.Value
    ( openDatumApplication
    )
import Singular.Registry.Application
    ( Application (..)
    , ApplicationPin (..)
    , hashPinnedApplication
    , neutralApplication
    )
import Singular.Registry.Config (bootStateFromCfg)
import Singular.Registry.Config.Application
    ( RegistryEconomics (..)
    , configForApplication
    )
import Singular.Registry.LedgerProvider qualified as LP ()
import Singular.Registry.StateToken
    ( IdentityRefusal (..)
    , PinField (..)
    , Release (..)
    , resolveRegistry
    )
import Singular.Registry.TxBuilder.Internal
    ( emptyRoot
    , txInToRef
    )
import Singular.Registry.Types
    ( OnChainRoot (..)
    , OnChainTokenState (..)
    )
import Test.Hspec (Spec, describe, it, shouldReturn)

spec :: Spec
spec = describe "The pin gate" $ do
    describe
        "the application pin is compared however the application states it"
        formRows

-- ---------------------------------------------------------------------------
-- Forged registries
-- ---------------------------------------------------------------------------

economics :: RegistryEconomics
economics =
    RegistryEconomics
        { reProcessTime = 600_000
        , reRetractTime = 300_000
        , reTip = Coin 1_000_000
        }

{- | The datum a boot pinning the compiled script of the release (the
parameterless form) leaves.
-}
compiledState :: OnChainTokenState
compiledState =
    bootStateFromCfg
        ( fst
            ( configForApplication
                (PinAsCompiled "open_datum.open_datum")
                (releaseCodes Fixture.release)
                (releaseState Fixture.release)
                (releaseRequest Fixture.release)
                economics
                Testnet
                (txInToRef Fixture.seedIn)
            )
        )
        (OnChainRoot emptyRoot)

refusalOver
    :: Application -> OnChainTokenState -> IO (Maybe IdentityRefusal)
refusalOver app datum = do
    logRef <- newIORef []
    let chain =
            Fixture.honestChain
                { Fixture.chainOutputs =
                    Map.singleton Fixture.stateIn (Fixture.stateOutput datum)
                }
    resolved <-
        resolveRegistry
            app
            Fixture.release
            Fixture.token
            (Fixture.chainSession logRef chain)
    pure (either Just (const Nothing) resolved)

compiledApplication :: Application
compiledApplication =
    openDatumApplication{appPin = PinAsCompiled "open_datum.open_datum"}

formRows :: Spec
formRows = do
    it
        "accepts a registry whose application pin is the hash the application states"
        $ refusalOver
            (hashPinnedApplication (SBS.toShort (appBytes Fixture.bootState)))
            Fixture.bootState
            `shouldReturn` Nothing
    it
        "accepts a registry whose application pin is the compiled script the application states"
        $ refusalOver compiledApplication compiledState `shouldReturn` Nothing
    it
        "refuses, naming the application, a registry pinning another policy than the hash the application states"
        $ refusalOver
            (hashPinnedApplication (SBS.toShort (BS.replicate 28 0xdd)))
            Fixture.bootState
            `shouldReturn` Just (RegistryPinMismatch PinApplication)
    it
        "refuses, naming the application, a registry pinning another policy than the compiled script the application states"
        $ refusalOver compiledApplication Fixture.bootState
            `shouldReturn` Just (RegistryPinMismatch PinApplication)
    it
        "refuses, naming the application, a registry pinning another policy than the script applied to its identity"
        $ refusalOver openDatumApplication compiledState
            `shouldReturn` Just (RegistryPinMismatch PinApplication)
    it
        "does not compare the application pin of a program that cannot derive it"
        $ refusalOver neutralApplication Fixture.bootState
            `shouldReturn` Nothing
  where
    appBytes st = case stateAppPolicy st of
        BuiltinByteString b -> b
