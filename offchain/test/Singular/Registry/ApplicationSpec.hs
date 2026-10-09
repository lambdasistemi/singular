{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.ApplicationSpec
Description : The registry's application value, pinned like the enumeration pins it
License     : Apache-2.0

The pin-equivalence proof derives every pin and code twice at run time,
once through the application value and once through the enumeration
composition the base runs, over two seeds and two economics, and asserts
byte-identity; it types no expected value. The neutral value names
nothing, the hash-pinned form pins its given hash with no application
script, and the neutral value resolves a registry reading the pin from
its state datum.
-}
module Singular.Registry.ApplicationSpec (spec) where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.IORef (newIORef)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Test.Hspec

import Data.ByteString.Base16 qualified as B16

import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.TxIn (TxIn)

import Singular.Application.OpenDatum.Script qualified as Script
import Singular.Application.OpenDatum.Value (openDatumApplication)
import Singular.Registry.Application
    ( Application (..)
    , ApplicationPin (..)
    , hashPinnedApplication
    , neutralApplication
    )
import Singular.Registry.Blueprint (NamingCodes (..))
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Config.Application
    ( RegistryEconomics (..)
    , configForApplication
    , registryIdentity
    )
import Singular.Registry.StateToken
    ( Release (..)
    , ResolvedRegistry (..)
    , resolveRegistry
    )
import Singular.Registry.StateTokenFixture
    ( bootEconomics
    , bootState
    , chainSession
    , honestChain
    , refOf
    , release
    , seedIn
    , token
    )
import Singular.Registry.TxBuilder.Edges (namingPins)
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , scriptHashBytes
    , txInToRef
    )
import Singular.Registry.Types (stateAppPolicyBytes)

spec :: Spec
spec = do
    pinEquivalence
    neutralValue
    hashPinned
    neutralResolution

-- | Two seeds and two economics: process time, retract time and tip vary.
seedB :: TxIn
seedB = refOf (T.replicate 64 "9" <> "#0")

econA :: RegistryEconomics
econA =
    RegistryEconomics
        { reProcessTime = 600_000
        , reRetractTime = 300_000
        , reTip = Coin 1_000_000
        }

runs :: [(Text, TxIn, RegistryEconomics)]
runs =
    [ ("seedIn/cli", seedIn, econA)
    , ("second/fixture", seedB, bootEconomics)
    ]

hex :: ByteString -> Text
hex = TE.decodeUtf8 . B16.encode

{- | The open-datum value derives byte-identical pins and codes to the
enumeration composition the base runs.
-}
pinEquivalence :: Spec
pinEquivalence =
    it
        "derives the open-datum value's pins, codes and identity like the enumeration"
        $ forM_ runs
        $ \(label, seed, econ) -> do
            let rel = release
                seedRef = txInToRef seed
                ident = registryIdentity (releaseState rel) seedRef
                pinnedOld =
                    Script.applicationCodes
                        Script.OpenDatumApplication
                        ident
                        (releaseCodes rel)
                (appOld, absOld, actOld, terOld) = namingPins pinnedOld ident
                (cfgNew, codesNew) =
                    configForApplication
                        (appPin openDatumApplication)
                        (releaseCodes rel)
                        (releaseState rel)
                        (releaseRequest rel)
                        econ
                        Testnet
                        seedRef
            putStrLn
                ( T.unpack label
                    <> " identity="
                    <> T.unpack (hex ident)
                    <> " application="
                    <> T.unpack (hex (SBS.fromShort (cfgApplicationPolicy cfgNew)))
                    <> " absent="
                    <> T.unpack (hex (SBS.fromShort (cfgAbsentPolicy cfgNew)))
                    <> " active="
                    <> T.unpack (hex (SBS.fromShort (cfgActivePolicy cfgNew)))
                    <> " terminal="
                    <> T.unpack (hex (SBS.fromShort (cfgTerminalPolicy cfgNew)))
                    <> " application-code="
                    <> T.unpack
                        (hex (scriptHashBytes (computeScriptHash (ncApplication codesNew))))
                    <> " witness-code="
                    <> T.unpack
                        (hex (scriptHashBytes (computeScriptHash (ncWitness codesNew))))
                )
            cfgApplicationPolicy cfgNew `shouldBe` appOld
            cfgAbsentPolicy cfgNew `shouldBe` absOld
            cfgActivePolicy cfgNew `shouldBe` actOld
            cfgTerminalPolicy cfgNew `shouldBe` terOld
            ncApplication codesNew `shouldBe` ncApplication pinnedOld
            ncWitness codesNew `shouldBe` ncWitness pinnedOld

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
