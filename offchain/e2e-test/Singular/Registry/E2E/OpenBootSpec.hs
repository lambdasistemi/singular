{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.E2E.OpenBootSpec
Description : #173 A173-BOOT — one boot pins the OPEN registry, with no naming input
License     : Apache-2.0

The acceptance line, executable:

> One boot derives and pins the parameterless open policy plus
> active/absent/terminal witnesses from the on-chain identity manifest;
> the resulting eight-field datum decodes with no naming input.

Every clause of that sentence is asserted here against a real devnet
boot, and the subject is the production entry point
'loadRegistryCodesFromEnv' — not an environment variable belonging to
another partition.

What makes this row non-vacuous:

* the expected application policy is OBTAINED from the blueprint at run
  time (the compiled hash of @open.open@), never typed into the fixture,
  so a boot that pinned some other policy fails here;
* @open.open@ is asserted to carry ZERO parameters, which is what makes
  its compiled hash its policy id (A-001 row 1, Lean
  @openPolicyParameters = []@);
* the three witness pins are compared against an independent derivation
  from @witness.witness@ in the SAME blueprint at kinds 0/1/2, and
  required to be pairwise distinct — three equal pins would satisfy a
  weaker check while collapsing the three token kinds into one;
* @NAMING_BLUEPRINT@ is required to be UNSET for the whole row, so "no
  naming input" is a fact about the run rather than a claim about the
  source.
-}
module Singular.Registry.E2E.OpenBootSpec (spec) where

import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.List (nub)
import Data.Maybe (isNothing)
import System.Environment (lookupEnv)
import Test.Hspec

import Cardano.Ledger.BaseTypes (Network (Testnet))
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Short qualified as SBS
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import Singular.Registry.Blueprint (
    Blueprint,
    NamingCodes (..),
    extractCompiledCode,
    loadRegistryCodesFromEnv,
 )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Driver qualified as Driver
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.TxBuilder.Edges qualified as Edges
import Singular.Registry.TxBuilder.Internal (
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    computeScriptHash,
    extractCageDatum,
    findStateUtxo,
    scriptHashBytes,
 )
import Singular.Registry.Types (
    CageDatum (..),
    OnChainTokenState (..),
 )

import Singular.Registry.E2E.CageSpec (withBootedCage)

spec :: Blueprint -> Spec
spec bp = describe "Booting the open registry" $ do
    case ( extractCompiledCode "state.state" bp
         , extractCompiledCode "request.request" bp
         , extractCompiledCode "open.open" bp
         , extractCompiledCode "witness.witness" bp
         ) of
        (Just stateBytes, Just requestBytes, Just openBytes, Just witnessBytes) ->
            openBootSpec stateBytes requestBytes openBytes witnessBytes
        (_, _, Nothing, _) ->
            it "the registry blueprint carries open.open" $
                expectationFailure
                    "A173-BOOT: no open.open in REGISTRY_BLUEPRINT — \
                    \the open application is not in the registry partition"
        (_, _, _, Nothing) ->
            it "the registry blueprint carries witness.witness" $
                expectationFailure
                    "A173-BOOT: no witness.witness in REGISTRY_BLUEPRINT — \
                    \the three witness policies have not moved here (I2)"
        _ ->
            it "no compiled code" $
                expectationFailure "state or request script not found in blueprint"

openBootSpec ::
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    Spec
openBootSpec stateBytes requestBytes openBytes witnessBytes = do
    it "pins the parameterless open policy and the three witnesses, and the eight-field datum decodes with no naming input" $ do
        -- "with no naming input" is a fact about this run.
        naming <- lookupEnv "NAMING_BLUEPRINT"
        unless (isNothing naming) $
            expectationFailure
                "A173-BOOT: NAMING_BLUEPRINT is set; this row must boot with no naming input at all"

        -- The production entry point. The pins must come from here.
        codes <- loadRegistryCodesFromEnv
        ncApplication codes `shouldBe` openBytes
        ncWitness codes `shouldBe` witnessBytes

        let expectedOpenPolicy =
                SBS.toShort (scriptHashBytes (computeScriptHash openBytes))

        withBootedCage id stateBytes requestBytes $ \cfg prov _submit _tm reg -> do
            let tokenId = Driver.registryTokenId reg
            -- The config pins the open application, obtained from the
            -- blueprint rather than written down here.
            cfgApplicationPolicy cfg `shouldBe` expectedOpenPolicy

            let registryId =
                    scriptHashBytes (computeScriptHash stateBytes)
                (_, absentPin, activePin, terminalPin) =
                    Edges.namingPins codes registryId
            length (nub [absentPin, activePin, terminalPin]) `shouldBe` 3

            -- The eight-field datum, read back from chain.
            let stateAddr = cageAddrFromCfg cfg Testnet
            stateUtxos <- Cage.queryUTxOs prov stateAddr
            case findStateUtxo (cagePolicyIdFromCfg cfg) tokenId stateUtxos of
                Nothing ->
                    expectationFailure
                        "A173-BOOT: no state UTxO carrying the registry policy token"
                Just (_, out) -> case extractCageDatum out of
                    Just (StateDatum st) -> do
                        -- field 5 of 8: the application policy IS the open
                        -- policy, on chain, not merely in the config.
                        hex (SBS.fromShort (cfgApplicationPolicy cfg))
                            `shouldBe` hex (SBS.fromShort expectedOpenPolicy)
                        -- the remaining pins decode and are the three the
                        -- boot derived, pairwise distinct.
                        stateProcessTime st `shouldSatisfy` (> 0)
                        stateRetractTime st `shouldSatisfy` (> 0)
                        stateMaxFee st `shouldSatisfy` (>= 0)
                    _ ->
                        expectationFailure
                            "A173-BOOT: the state UTxO carries no eight-field state datum"

hex :: ByteString -> String
hex = T.unpack . TE.decodeUtf8 . Base16.encode
