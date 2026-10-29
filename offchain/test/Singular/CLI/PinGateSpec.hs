{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.PinGateSpec
Description : Retained pin-resolution assertions run against a synthetic state datum and
recorded mint transaction. The fixture establishes neither a creation
lifecycle nor validator or ledger acceptance.
-}
module Singular.CLI.PinGateSpec (spec) where

import Cardano.Ledger.Api.Tx (mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( inputsTxBodyL
    , mintTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (datumTxOutL, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Network (Testnet), TxIx (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn (..))
import Control.Monad (forM_)
import Data.ByteString qualified as BS (ByteString, replicate)
import Data.ByteString.Short qualified as SBS (toShort)
import Data.Map.Strict qualified as Map
    ( delete
    , insert
    , map
    , singleton
    )
import Data.Sequence.Strict qualified as StrictSeq (singleton)
import Data.Set qualified as Set (singleton)
import Data.Text qualified as T (pack, unpack)
import Lens.Micro ((&), (.~))
import PlutusTx.Builtins.Internal (BuiltinByteString (..))
import Singular.CLI.CommandRunSpec
    ( Rig (rigBlueprint, rigChain)
    , readWallet
    , scriptPinned
    , withRig
    )
import Singular.CLI.Registry
    ( economics
    , loadReleaseCodes
    , registryConfigFor
    )
import Singular.Registry.Application
    ( Application (..)
    , ApplicationPin (..)
    , hashPinnedApplication
    , neutralApplication
    )
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Config (bootStateFromCfg)
import Singular.Registry.Deployment (parseOutRef, renderOutRef)
import Singular.Registry.RawChainFixture
    ( ChainFacts (..)
    , advanceChain
    , rawChainProvider
    , recordTransaction
    )
import Singular.Registry.SessionIO qualified as SessionIO
    ( withLatest
    )
import Singular.Registry.StateToken
    ( IdentityRefusal (..)
    , PinField (..)
    , Release (..)
    , parseStateToken
    , renderStateToken
    , resolveRegistry
    )
import Singular.Registry.TxBuilder.Internal
    ( cageAddrFromCfg
    , computeScriptHash
    , emptyRoot
    , extractCageDatum
    , mkInlineDatum
    , toPlcData
    , txInToRef
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRoot (..)
    , OnChainTokenState (..)
    )
import Test.Hspec (Spec, describe, it, shouldReturn)

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

{- | Synthetic registry state with the application policy given as a hash.
Its token is derived from the supplied seed and release.
-}
createdByHash :: Rig -> String -> String -> IO String
createdByHash rig =
    createdByScript
        rig
        (hashPinnedApplication (SBS.toShort givenPolicy))

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

-- | Synthetic state and mint data for the retained pin-resolution helper.
createdByScript :: Rig -> Application -> String -> String -> IO String
createdByScript rig app _ seed = do
    release <-
        loadReleaseCodes app (rigBlueprint rig) >>= either fail pure
    seedIn <- either fail pure (parseOutRef (T.pack seed))
    let (cfg, _) = registryConfigFor app release economics (txInToRef seedIn)
        name = AssetName (SBS.toShort (deriveAssetName (txInToRef seedIn)))
        policy = PolicyID (computeScriptHash (releaseState release))
        minted = MultiAsset (Map.singleton policy (Map.singleton name 1))
        state =
            mkBasicTxOut
                (cageAddrFromCfg cfg Testnet)
                (MaryValue (Coin 2_000_000) minted)
                & datumTxOutL
                    .~ mkInlineDatum
                        (toPlcData (StateDatum (bootStateFromCfg cfg (OnChainRoot emptyRoot))))
        transaction =
            mkBasicTx $
                mkBasicTxBody
                    & inputsTxBodyL .~ Set.singleton seedIn
                    & mintTxBodyL .~ minted
                    & outputsTxBodyL .~ StrictSeq.singleton state
        stateIn = TxIn (txIdTx transaction) (TxIx 0)
    recordTransaction (rigChain rig) transaction
    advanceChain (rigChain rig) $ \facts ->
        facts
            { csUTxO = Map.insert stateIn state (Map.delete seedIn (csUTxO facts))
            }
    pure (T.unpack (renderStateToken (policy, name)))
