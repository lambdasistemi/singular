{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.PinGateSpec
Description : Retained library pin-form checks
License     : Apache-2.0

Retained library pin-form checks are exercised against a
chain fixture. A legacy registry is prepared through the shared create helper
still used by application commands; no retired Singular parser route is invoked. This
establishes library identity refusals over the exercised fixtures,
not a new-line registry reader or ledger acceptance.
-}
module Singular.CLI.PinGateSpec (spec) where

import Cardano.Ledger.Api.Tx.Out (datumTxOutL)
import Control.Monad (forM_)
import Data.ByteString qualified as BS
    ( ByteString
    , replicate
    )
import Data.ByteString.Short qualified as SBS (toShort)
import Data.Map.Strict qualified as Map (map)
import Data.Text qualified as T (pack, unpack)
import Lens.Micro ((&), (.~))
import PlutusTx.Builtins.Internal (BuiltinByteString (..))
import Singular.CLI.Command
    ( ApplicationPolicy (..)
    , CreateArgs (..)
    , EntryMode (..)
    , ProviderSettings (..)
    , WriteSettings (..)
    )
import Singular.CLI.CommandRunSpec
    ( Rig (rigBlueprint, rigChain, rigDir, rigKey)
    , envOf
    , outcomeOf
    , readWallet
    , scriptPinned
    , textAt
    , withRig
    )
import Singular.CLI.Create (createApplication, runCreate)
import Singular.CLI.FlagGroup (Signer (..))
import Singular.CLI.Registry (economics, loadReleaseCodes)
import Singular.Registry.Application
    ( Application (..)
    , ApplicationPin (..)
    , hashPinnedApplication
    , neutralApplication
    )
import Singular.Registry.Config.Application
    ( RegistryEconomics (..)
    )
import Singular.Registry.Deployment (renderOutRef)
import Singular.Registry.RawChainFixture
    ( ChainFacts (..)
    , advanceChain
    , rawChainProvider
    )
import Singular.Registry.SessionIO qualified as SessionIO
    ( withLatest
    )
import Singular.Registry.StateToken
    ( IdentityRefusal (..)
    , PinField (..)
    , parseStateToken
    , resolveRegistry
    )
import Singular.Registry.TxBuilder.Internal
    ( extractCageDatum
    , mkInlineDatum
    , toPlcData
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainTokenState (..)
    )
import System.FilePath ((</>))
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldReturn
    )

spec :: Spec
spec = describe "retained pin library" formRows

-- ---------------------------------------------------------------------------
-- The registries and the forgery
-- ---------------------------------------------------------------------------

-- | A seed the rig's wallet funds: the first six outputs of the chain.
seedAt :: Int -> String
seedAt n = replicate 64 'f' <> "#" <> show n

-- | The application policy a create gives as a hash.
foreignPolicy :: BS.ByteString
foreignPolicy = BS.replicate 28 0xee

{- | A registry created by the retained create helper over the neutral value with
the application policy given as a hash. Its token, as a person passes it.
-}
createdByHash :: Rig -> String -> String -> IO String
createdByHash rig dir seed = do
    let args =
            CreateArgs
                { createStateDir = Just (rigDir rig </> dir)
                , createBlueprint = rigBlueprint rig
                , createMode =
                    Submit
                        ( WriteSettings
                            (ProviderSettings "http://fixture.invalid" 42 Nothing Nothing)
                            (SignerKeyFile (rigKey rig))
                            Nothing
                        )
                , createSeed = Just seed
                , createPreview = False
                , createReceipt = Nothing
                , createSaveStateTokenTo = Nothing
                , createProcessTime = reProcessTime economics
                , createRetractTime = reRetractTime economics
                }
    effective <-
        createApplication
            neutralApplication
            (Just (ApplicationPolicy (SBS.toShort (BS.replicate 28 7))))
    receipt <- runCreate effective (envOf rig) args
    maybe
        (fail "create fixture has no token")
        (pure . T.unpack)
        (textAt "stateToken" receipt)

-- | Rewrite the registry state datum while preserving the fixture transaction history.
forgeState :: Rig -> (OnChainTokenState -> OnChainTokenState) -> IO ()
forgeState rig change = advanceChain (rigChain rig) $ \facts ->
    facts{csUTxO = Map.map forgeOutput (csUTxO facts)}
  where
    forgeOutput out = case extractCageDatum out of
        Just (StateDatum st) ->
            out
                & datumTxOutL .~ mkInlineDatum (toPlcData (StateDatum (change st)))
        _ -> out

forgeActive :: OnChainTokenState -> OnChainTokenState
forgeActive st = st{stateActivePolicy = BuiltinByteString foreignPolicy}

gateRefusal
    :: Rig -> Application -> String -> IO (Maybe IdentityRefusal)
gateRefusal rig app tokenText = do
    release <-
        loadReleaseCodes app (rigBlueprint rig) >>= either fail pure
    asset <-
        either (fail . T.unpack) pure (parseStateToken (T.pack tokenText))
    resolved <-
        SessionIO.withLatest (rawChainProvider (rigChain rig)) $ \view ->
            resolveRegistry app release asset view
    pure (either Just (const Nothing) resolved)

compiledPinned :: Application
compiledPinned = scriptPinned{appPin = PinAsCompiled "script-app.script-app"}

formRows :: Spec
formRows = do
    it "accepts each form's own registry" $ withRig $ \rig -> do
        byHash <- createdByHash rig "by-hash" (seedAt 1)
        seed2 <- freshSeed rig
        byScript <- createdByScript rig scriptPinned "by-script" seed2
        seed3 <- freshSeed rig
        byCompiled <- createdByScript rig compiledPinned "by-compiled" seed3
        gateRefusal
            rig
            (hashPinnedApplication (SBS.toShort givenPolicy))
            byHash
            `shouldReturn` Nothing
        gateRefusal rig scriptPinned byScript `shouldReturn` Nothing
        gateRefusal rig compiledPinned byCompiled `shouldReturn` Nothing
    it
        "refuses a registry pinning another policy, naming the application, in the script form"
        $ withRig
        $ \rig -> do
            byHash <- createdByHash rig "by-hash" (seedAt 1)
            gateRefusal rig scriptPinned byHash
                `shouldReturn` Just (RegistryPinMismatch PinApplication)
    it
        "refuses a registry pinning another policy, naming the application, in the hash form"
        $ withRig
        $ \rig -> do
            byHash <- createdByHash rig "by-hash" (seedAt 1)
            gateRefusal
                rig
                (hashPinnedApplication (SBS.toShort foreignPolicy))
                byHash
                `shouldReturn` Just (RegistryPinMismatch PinApplication)
    it
        "refuses a registry pinning another policy, naming the application, in the compiled form"
        $ withRig
        $ \rig -> do
            byScript <- createdByScript rig scriptPinned "by-script" (seedAt 1)
            gateRefusal rig compiledPinned byScript
                `shouldReturn` Just (RegistryPinMismatch PinApplication)
    it
        "refuses a forged application pin in the hash form after the datum is rewritten"
        $ withRig
        $ \rig -> do
            byHash <- createdByHash rig "by-hash" (seedAt 1)
            forgeState rig forgeApplication
            gateRefusal
                rig
                (hashPinnedApplication (SBS.toShort givenPolicy))
                byHash
                `shouldReturn` Just (RegistryPinMismatch PinApplication)
    it
        "still refuses a forged active policy whichever way the application is stated"
        $ withRig
        $ \rig -> do
            byHash <- createdByHash rig "by-hash" (seedAt 1)
            forgeState rig forgeActive
            forM_
                [ hashPinnedApplication (SBS.toShort givenPolicy)
                , neutralApplication
                ]
                $ \app ->
                    gateRefusal rig app byHash
                        `shouldReturn` Just (RegistryPinMismatch PinActive)

forgeApplication :: OnChainTokenState -> OnChainTokenState
forgeApplication st = st{stateAppPolicy = BuiltinByteString foreignPolicy}

-- | A fresh funded output for another library fixture.
freshSeed :: Rig -> IO String
freshSeed rig = do
    held <- readWallet rig
    case reverse (map fst held) of
        i : _ -> pure (T.unpack (renderOutRef i))
        [] -> fail "the wallet holds nothing for another registry"

givenPolicy :: BS.ByteString
givenPolicy = BS.replicate 28 7

-- | The script-pinned library fixture uses the retained builder directly.
createdByScript :: Rig -> Application -> String -> String -> IO String
createdByScript rig app dir seed = do
    effective <- createApplication app Nothing
    receipt <-
        runCreate
            effective
            (envOf rig)
            CreateArgs
                { createStateDir = Just (rigDir rig </> dir)
                , createBlueprint = rigBlueprint rig
                , createMode =
                    Submit
                        ( WriteSettings
                            (ProviderSettings "http://fixture.invalid" 42 Nothing Nothing)
                            (SignerKeyFile (rigKey rig))
                            Nothing
                        )
                , createSeed = Just seed
                , createPreview = False
                , createReceipt = Nothing
                , createSaveStateTokenTo = Nothing
                , createProcessTime = reProcessTime economics
                , createRetractTime = reRetractTime economics
                }
    outcomeOf receipt `shouldBe` Just "success"
    maybe
        (fail "script fixture has no token")
        (pure . T.unpack)
        (textAt "stateToken" receipt)
