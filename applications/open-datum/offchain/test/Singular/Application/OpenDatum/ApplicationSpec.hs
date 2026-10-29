{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.ApplicationSpec
Description : Generic neutral and hash-pinned application values
License     : Apache-2.0

The neutral value names
nothing, the hash-pinned form pins its given hash with no application
script, and the neutral value resolves a registry reading the pin from
its state datum.
-}
module Singular.Application.OpenDatum.ApplicationSpec (spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.IORef (newIORef)
import Data.Maybe (isNothing)
import Test.Hspec

import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Coin (Coin (..))

import Singular.Application.OpenDatum.StateTokenFixture
    ( bootState
    , chainSession
    , honestChain
    , release
    , seedIn
    , token
    )
import Singular.Registry.Application
    ( Application (..)
    , ApplicationPin (..)
    , hashPinnedApplication
    , neutralApplication
    )
import Singular.Registry.Blueprint (ApplicationCodes (..))
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Config.Application
    ( RegistryEconomics (..)
    , configForApplication
    )
import Singular.Registry.StateToken
    ( Release (..)
    , ResolvedRegistry (..)
    , resolveRegistry
    )
import Singular.Registry.TxBuilder.Internal
    ( txInToRef
    )
import Singular.Registry.Types (stateAppPolicyBytes)

spec :: Spec
spec = do
    neutralValue
    hashPinned
    neutralResolution

econA :: RegistryEconomics
econA =
    RegistryEconomics
        { reProcessTime = 600_000
        , reRetractTime = 300_000
        , reTip = Coin 1_000_000
        }

-- | The neutral value names nothing.
neutralValue :: Spec
neutralValue =
    it "neutral value has no name, executable, decoder or holding rules" $ do
        let neutral = neutralApplication
        appName neutral `shouldBe` Nothing
        appExecutable neutral `shouldBe` Nothing
        appDecoder neutral `shouldSatisfy` isNothing
        appHolding neutral `shouldSatisfy` isNothing
        appPin neutral `shouldBe` PinFromState

-- | The hash-pinned form pins the given hash and carries no script.
hashPinned :: Spec
hashPinned =
    it
        "hash-pinned form pins the given hash and carries no application script"
        $ do
            let policy = SBS.toShort (BS.replicate 28 7)
                app = hashPinnedApplication policy
                (cfg, codes) =
                    configForApplication
                        (appPin app)
                        (releaseCodes release)
                        (releaseState release)
                        (releaseRequest release)
                        econA
                        Testnet
                        (txInToRef seedIn)
            appPin app `shouldBe` PinByHash policy
            appName app `shouldBe` Nothing
            cfgApplicationPolicy cfg `shouldBe` policy
            ncApplication codes `shouldBe` SBS.empty

-- | The neutral value resolves, reading the pin from the state datum.
neutralResolution :: Spec
neutralResolution =
    it
        "neutral value resolves a registry reading the pin from its state datum"
        $ do
            logRef <- newIORef []
            result <-
                resolveRegistry
                    neutralApplication
                    release
                    token
                    (chainSession logRef honestChain)
            case result of
                Left refusal ->
                    expectationFailure ("neutral resolution refused: " <> show refusal)
                Right resolved ->
                    SBS.fromShort (cfgApplicationPolicy (resolvedConfig resolved))
                        `shouldBe` stateAppPolicyBytes bootState
