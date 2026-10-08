{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.References
Description : Publish a registry's missing reference scripts
License     : Apache-2.0

@singular registry publish-references@ rebuilds the registry's reference
scripts from its state token and the bound release, hash-checks each
against its expected role hash, publishes the missing ones to minimum-ADA
outputs the payer controls, reads them back and receipts them. It creates
no registry, mints no token and changes no registry state. Preview builds
what submission would send — destination, hash, output ADA and fee — and
signs, submits, journals and writes nothing.
-}
module Singular.CLI.References (runPublishReferences) where

import Control.Monad (when)
import Control.Exception (throwIO)
import Data.Aeson (Value, toJSON)
import Data.Aeson qualified as Aeson
import Cardano.Tx.Ledger (ConwayTx)
import Data.Foldable (toList)
import Lens.Micro ((^.))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body (feeTxBodyL, outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (TxOut, valueTxOutL)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn (..))

import Singular.CLI.Attached (atWrite, attached, reading)
import Singular.CLI.Command
    ( EntryMode (..)
    , ProviderSettings (..)
    , PublishArgs (..)
    , RegistryAccess (..)
    )
import Singular.CLI.Create (observeReference)
import Singular.CLI.Live (receipt)
import Singular.CLI.Live qualified as Live (txInText)
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Session
    ( Env (..)
    , WriteContext (..)
    , expecting
    , failWith
    , readOnce
    , submitBuilt
    , txIdHex
    )
import Singular.Registry.Capabilities (sessionReceipt)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (Addr, Coin (..), ConwayEra)
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.CLI.Registry (hexT, loadRelease, parseEnterpriseAddress)
import Singular.Registry.LedgerProvider (Asset)
import Singular.Registry.StateToken
    ( ReferenceRole (..)
    , Release
    , checkedScript
    , expectedReferences
    , missingReferences
    , renderReferenceRefusal
    , renderStateToken
    , roleName
    )
import Singular.Registry.TxBuilder.Edges (publishReferencesTx)
import Singular.Registry.TxBuilder.Internal (scriptHashBytes)
import Singular.Registry.Wallet (bech32Address, walletAddr)
import Singular.Registry.WalletOutputs
    ( FundingViewRefusal (..)
    , WalletOutputs
    , narrowFunding
    , renderFundingRefusal
    , walletOutputs
    )

-- | @singular registry publish-references@: preview or publish.
runPublishReferences :: Env -> PublishArgs -> IO Value
runPublishReferences env a = case publishMode a of
    Preview node addr -> runPublishPreview env a node addr
    Submit _ -> runPublish env a

-- | Read-only preview: what submission would send, signed, submitted,
-- journalled and written nothing.
runPublishPreview :: Env -> PublishArgs -> ProviderSettings -> String -> IO Value
runPublishPreview env a settings addrText = do
    release <-
        loadRelease (publishBlueprint a)
            >>= either (failWith ClientRefusal) pure
    addr <-
        either
            (failWith ClientRefusal)
            pure
            (parseEnterpriseAddress (providerMagic settings) addrText)
    readOnce env settings ["wallet outputs", "reference scripts"] $ \caps v -> do
        planned <-
            planPublish
                v
                release
                (accessToken (publishAccess a))
                addr
                (publishRoles a)
                Nothing
        scope <- sessionReceipt caps v
        w <- acquireWallet v planned
        (built, refouts) <- publishReferencesTx v addr w (plannedScriptList planned)
        pure $
            receipt
                "publish-references"
                Success
                ( [("preview", toJSON True), ("sessionEvidence", scope)]
                    <> previewFields planned built refouts
                )

-- | Publish through the actor's write session, journalled and confirmed.
runPublish :: Env -> PublishArgs -> IO Value
runPublish env a =
    attached
        env
        (publishStateDir a)
        (publishBlueprint a)
        (publishAccess a)
        mempty
        (publishWrite a)
        "publish-references"
        $ \at -> do
            let wc = atWrite at
                wallet = walletAddr (wcWallet wc)
            release <-
                loadRelease (publishBlueprint a)
                    >>= either (failWith ClientRefusal) pure
            planned <-
                reading at $ \v ->
                    planPublish
                        v
                        release
                        (accessToken (publishAccess a))
                        wallet
                        (publishRoles a)
                        (publishFund a)
            (tx, refouts) <-
                submitBuilt wc "publish-references" (const (expecting "publish-references")) $ \v -> do
                    w <- acquireWallet v planned
                    publishReferencesTx v (plannedPayer planned) w (plannedScriptList planned)
            published <- locateOutputs tx refouts (plannedRoles planned)
            mapM_
                (\(role, out) -> observeReference wc ("publish-" <> roleName role) (plannedScript planned role) out)
                published
            pure
                ( receipt
                    "publish-references"
                    Success
                    (receiptFields planned tx published)
                )
  where
    publishWrite args = case publishMode args of
        Submit ws -> ws
        Preview _ _ -> error "publish-references preview takes no write session"

-- | What publication will send: the checked scripts for the missing roles.
data Planned = Planned
    { plannedToken :: Asset
    , plannedPayer :: Addr
    , plannedRoles :: [ReferenceRole]
    , plannedScripts :: [(ReferenceRole, Script ConwayEra)]
    , plannedFund :: Maybe TxIn
    }

-- | Resolve the token, find the missing roles among the requested ones
-- and hash-check what would be built. Refusals name their cause before
-- anything is built, signed or written.
planPublish
    :: Cage.Session NoWitness IO
    -> Release
    -> Asset
    -> Addr
    -> [ReferenceRole]
    -> Maybe TxIn
    -> IO Planned
planPublish v release token payer requested fund = do
    let expected = expectedReferences release token
        wanted =
            if null requested
                then Map.keys expected
                else requested
    (_, missing) <-
        missingReferences v (Just payer) expected (Set.fromList wanted)
            >>= either (failWith ClientRefusal . T.unpack . renderReferenceRefusal) pure
    let selected = [r | r <- wanted, r `Set.member` missing]
    when (null selected) $
        failWith ClientRefusal "no missing reference scripts to publish"
    scripts <-
        traverse
            ( \role ->
                (,) role
                    <$> either
                        (failWith ClientRefusal . T.unpack . renderReferenceRefusal)
                        pure
                        (checkedScript release token role)
            )
            selected
    pure
        Planned
            { plannedToken = token
            , plannedPayer = payer
            , plannedRoles = selected
            , plannedScripts = scripts
            , plannedFund = fund
            }

-- | The checked script for one planned role.
plannedScript :: Planned -> ReferenceRole -> Script ConwayEra
plannedScript planned role = case lookup role (plannedScripts planned) of
    Just script -> script
    Nothing -> error "publish-references planned a role it did not check"

-- | The scripts to publish, in role order.
plannedScriptList :: Planned -> [Script ConwayEra]
plannedScriptList planned = map snd (plannedScripts planned)

-- | The wallet publication funds from, narrowed to the chosen input.
acquireWallet
    :: Cage.Session NoWitness IO -> Planned -> IO WalletOutputs
acquireWallet v planned = do
    w0 <-
        walletOutputs v (plannedPayer planned)
            >>= either throwIO pure
    case plannedFund planned of
        Nothing -> pure w0
        Just chosen -> do
            narrowed <-
                narrowFunding (plannedPayer planned) chosen v
                    >>= either refuse pure
            walletOutputs narrowed (plannedPayer planned) >>= either throwIO pure
  where
    refuse = \case
        FundingReadFailure e -> throwIO e
        FundingInputRefusal r -> failWith ClientRefusal (renderFundingRefusal r)

-- | Preview fields: what submission would send, per missing role.
previewFields :: Planned -> ConwayTx -> [TxOut ConwayEra] -> [(Text, Value)]
previewFields planned built refouts =
    [ ("token", toJSON (renderStateToken (plannedToken planned)))
    , ( "publications"
      , toJSON
            [ Aeson.object
                [ "role" Aeson..= roleName role
                , "destination" Aeson..= bech32Address (plannedPayer planned)
                , "scriptHash" Aeson..= hexT (scriptHashBytes (hashScript script))
                , "outputAda" Aeson..= coinOf out
                ]
            | (role, script, out) <- zip3 (plannedRoles planned) (plannedScriptList planned) refouts
            ]
        )
    , ("fee", toJSON (feeOf built))
    ]
  where
    coinOf out = let MaryValue (Coin c) _ = out ^. valueTxOutL in c
    feeOf tx = let Coin c = tx ^. bodyTxL . feeTxBodyL in c

-- | Receipt fields: the confirmed publications with their identities.
receiptFields
    :: Planned -> ConwayTx -> [(ReferenceRole, (TxIn, TxOut ConwayEra))] -> [(Text, Value)]
receiptFields planned tx published =
    [ ("token", toJSON (renderStateToken (plannedToken planned)))
    , ("transaction", toJSON (txIdHex tx))
    ,
        ( "publications"
        , toJSON
            [ Aeson.object
                [ "role" Aeson..= roleName role
                , "destination" Aeson..= bech32Address (plannedPayer planned)
                , "scriptHash" Aeson..= hexT (scriptHashBytes (hashScript (plannedScript planned role)))
                , "transaction" Aeson..= txIdHex tx
                , "output" Aeson..= Live.txInText out
                ]
            | (role, (out, _)) <- published
            ]
        )
    ]

-- | The published outputs located in their transaction, by exact output
-- equality; a built output the transaction does not carry fails closed.
locateOutputs
    :: ConwayTx -> [TxOut ConwayEra] -> [ReferenceRole] -> IO [(ReferenceRole, (TxIn, TxOut ConwayEra))]
locateOutputs tx refouts roles = do
    let outs = toList (tx ^. bodyTxL . outputsTxBodyL)
        locate refout = case [ix | (ix, out) <- zip [0 ..] outs, out == refout] of
            ix : _ -> pure (TxIn (txIdTx tx) (TxIx ix), refout)
            [] -> failWith ClientRefusal "a published output is not in its transaction"
    zip roles <$> traverse locate refouts
