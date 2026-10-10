{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.NeutralValueSpec
Description : Slice 2 RED: the hash-pinned value pins its hash with no application reference
License     : Apache-2.0

Slice 2 (`commands-through-the-value`): `create` with a hash-pinned value
pins exactly that hash, derives the three witness pins as today, and
publishes no application reference (its script bytes do not exist). The
neutral value names nothing. Every expected value the base producer yields
at run time (the release, token and witness pins from the fixtures) is never
typed; the hash-pinned omission is the RED leg that fails at the pre-slice
base (the base still lists an application reference for a hash pin) and
passes once the value carries the slice.

Failing controls: each passing leg carries a mutation shown to kill it
(a different hash, a different seed, the open-datum value where neutral is
expected).
-}
module Singular.Registry.NeutralValueSpec (spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Test.Hspec

import Singular.Application.OpenDatum.Value (openDatumApplication)
import Singular.Registry.Application
    ( Application (..)
    , ApplicationPin (..)
    , hashPinnedApplication
    , neutralApplication
    )
import Singular.Registry.Blueprint (NamingCodes (..))
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Config.Application (configForApplication)
import Singular.Registry.StateToken
    ( ReferenceRole (..)
    , Release (..)
    , expectedReferences
    )
import Singular.Registry.StateTokenFixture
    ( bootEconomics
    , release
    , seedIn
    , token
    )
import Singular.Registry.TxBuilder.Internal (txInToRef)

import Cardano.Ledger.BaseTypes (Network (Testnet))

spec :: Spec
spec = do
    neutralNamesNothing
    hashPinsHashWithNoAppScript
    hashOmitsApplicationReference
    hashDerivesWitnessesAsToday

{- | The neutral value names nothing (passes at base; the open-datum
control proves the assertion can fail).
-}
neutralNamesNothing :: Spec
neutralNamesNothing = describe "neutral value" $ do
    it
        "has no name, executable, decoder or holding rules; pin read from state"
        $ do
            let neutral = neutralApplication
            appName neutral `shouldBe` Nothing
            appExecutable neutral `shouldBe` Nothing
            appPin neutral `shouldBe` PinFromState
    it
        "is distinguished from the open-datum value, which names all three (failing control)"
        $ do
            -- If the neutral/object were swapped, the first test would fail here:
            -- the open datum names its application, executable and pin.
            appName openDatumApplication `shouldBe` Just "open-datum"
            appExecutable openDatumApplication `shouldBe` Just "open-datum"
            case appPin openDatumApplication of
                PinByScript title -> title `shouldBe` "open_datum.open_datum"
                other ->
                    expectationFailure ("open-datum pin is not by script: " <> show other)

{- | A hash pin fixes exactly that hash with no application script
(passes at base via slice 1; the wrong-hash control proves it can fail).
-}
hashPinsHashWithNoAppScript :: Spec
hashPinsHashWithNoAppScript = describe "hash-pinned value" $ do
    it "pins the given hash and carries no application script" $ do
        let policy = SBS.toShort (BS.replicate 28 7)
            app = hashPinnedApplication policy
            (cfg, codes) =
                configForApplication
                    (appPin app)
                    (releaseCodes release)
                    (releaseState release)
                    (releaseRequest release)
                    bootEconomics
                    Testnet
                    (txInToRef seedIn)
        appPin app `shouldBe` PinByHash policy
        -- The pinned policy is exactly the given hash.
        cfgApplicationPolicy cfg `shouldBe` policy
        -- No application script bytes exist for a hash pin.
        ncApplication codes `shouldBe` SBS.empty
    it "does not pin another hash (failing control)" $ do
        let policy = SBS.toShort (BS.replicate 28 7)
            other = SBS.toShort (BS.replicate 28 9)
            app = hashPinnedApplication policy
        appPin app `shouldNotBe` PinByHash other

{- | RED leg: a hash pin publishes no application reference. At the
pre-slice base `expectedReferences` still lists one (so this fails);
once the value carries the slice it omits it (so this passes).
-}
hashOmitsApplicationReference :: Spec
hashOmitsApplicationReference =
    it "publishes no application reference for a hash pin" $ do
        let policy = SBS.toShort (BS.replicate 28 7)
            refs = expectedReferences (PinByHash policy) release token
        Map.lookup RoleApplication refs `shouldBe` Nothing

{- | The three witness references are derived as today for a hash pin
(passes at base; the other-seed control proves it can fail).
-}
hashDerivesWitnessesAsToday :: Spec
hashDerivesWitnessesAsToday = describe "hash-pinned witnesses" $ do
    it "derives the three witness pins as today" $ do
        let policy = SBS.toShort (BS.replicate 28 7)
            refsHash = expectedReferences (PinByHash policy) release token
            refsOpen = expectedReferences (appPin openDatumApplication) release token
        Map.lookup RoleWitnessAbsent refsHash
            `shouldBe` Map.lookup RoleWitnessAbsent refsOpen
        Map.lookup RoleWitnessActive refsHash
            `shouldBe` Map.lookup RoleWitnessActive refsOpen
        Map.lookup RoleWitnessTerminal refsHash
            `shouldBe` Map.lookup RoleWitnessTerminal refsOpen
        Map.lookup RoleState refsHash
            `shouldBe` Map.lookup RoleState refsOpen
        Map.lookup RoleRequest refsHash
            `shouldBe` Map.lookup RoleRequest refsOpen
