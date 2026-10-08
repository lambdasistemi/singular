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

import Cardano.Tx.Ledger (ConwayTx)
import Data.Aeson (Value, toJSON)
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Lens.Micro ((^.))

import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (feeTxBodyL)
import Cardano.Ledger.Api.Tx.Out (TxOut, valueTxOutL)
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn (..))

import Singular.CLI.Attached (atWrite, attached, reading)
import Singular.CLI.Command
    ( EntryMode (..)
    , ProviderSettings (..)
    , PublishArgs (..)
    , RegistryAccess (..)
    , WriteSettings (..)
    )
import Singular.CLI.Create (observeReference)
import Singular.CLI.Live (receipt)
import Singular.CLI.Live qualified as Live (txInText)
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Registry
    ( hexT
    , loadRelease
    , parseEnterpriseAddress
    )
import Singular.CLI.Restore
    ( Planned (..)
    , acquireWallet
    , locateOutputs
    , planPublish
    , plannedScript
    , plannedScriptList
    )
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
import Singular.Registry.Ledger (Addr, Coin (..), ConwayEra)
import Singular.Registry.StateToken
    ( ReferenceRole (..)
    , renderStateToken
    , roleName
    )
import Singular.Registry.TxBuilder.Edges (publishReferencesTx)
import Singular.Registry.TxBuilder.Internal (scriptHashBytes)
import Singular.Registry.Wallet
    ( bech32Address
    , loadWallet
    , walletAddr
    )

-- | @singular registry publish-references@: preview or publish.
runPublishReferences :: Env -> PublishArgs -> IO Value
runPublishReferences env a
    | publishPreview a = case publishMode a of
        Preview node addr -> runPublishPreview env a node addr
        Submit ws -> do
            wallet <-
                loadWallet (providerMagic (writeProvider ws)) (writeWalletKey ws)
            runPublishPreviewAt env a (writeProvider ws) (walletAddr wallet)
    | otherwise = case publishMode a of
        Submit _ -> runPublish env a
        Preview _ _ -> error "publish-references preview takes no write session"

{- | Read-only preview: what submission would send, with nothing signed,
submitted, journalled or written.
-}
runPublishPreview
    :: Env -> PublishArgs -> ProviderSettings -> String -> IO Value
runPublishPreview env a settings addrText = do
    addr <-
        either
            (failWith ClientRefusal)
            pure
            (parseEnterpriseAddress (providerMagic settings) addrText)
    runPublishPreviewAt env a settings addr

{- | Read-only preview at a resolved payer address: what submission would
send, with nothing signed, submitted, journalled or written.
-}
runPublishPreviewAt
    :: Env -> PublishArgs -> ProviderSettings -> Addr -> IO Value
runPublishPreviewAt env a settings payer = do
    release <-
        loadRelease (publishBlueprint a)
            >>= either (failWith ClientRefusal) pure
    readOnce env settings ["wallet outputs", "reference scripts"] $ \caps v -> do
        planned <-
            planPublish
                v
                release
                (accessToken (publishAccess a))
                payer
                (publishRoles a)
                Nothing
        scope <- sessionReceipt caps v
        w <- acquireWallet v planned
        (built, refouts) <-
            publishReferencesTx v payer w (plannedScriptList planned)
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
                submitBuilt
                    wc
                    "publish-references"
                    (const (expecting "publish-references"))
                    $ \v -> do
                        w <- acquireWallet v planned
                        publishReferencesTx
                            v
                            (plannedPayer planned)
                            w
                            (plannedScriptList planned)
            published <- locateOutputs tx refouts (plannedRoles planned)
            mapM_
                ( \(role, out) ->
                    observeReference
                        wc
                        "publish-references"
                        (plannedScript planned role)
                        out
                )
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

-- | Preview fields: what submission would send, per missing role.
previewFields
    :: Planned -> ConwayTx -> [TxOut ConwayEra] -> [(Text, Value)]
previewFields planned built refouts =
    [ ("token", toJSON (renderStateToken (plannedToken planned)))
    ,
        ( "publications"
        , toJSON
            [ Aeson.object
                [ "role" Aeson..= roleName role
                , "destination" Aeson..= bech32Address (plannedPayer planned)
                , "scriptHash" Aeson..= hexT (scriptHashBytes (hashScript script))
                , "outputAda" Aeson..= coinOf out
                ]
            | (role, script, out) <-
                zip3 (plannedRoles planned) (plannedScriptList planned) refouts
            ]
        )
    , ("fee", toJSON (feeOf built))
    ]
  where
    coinOf out = let MaryValue (Coin c) _ = out ^. valueTxOutL in c
    feeOf tx = let Coin c = tx ^. bodyTxL . feeTxBodyL in c

-- | Receipt fields: the confirmed publications with their identities.
receiptFields
    :: Planned
    -> ConwayTx
    -> [(ReferenceRole, (TxIn, TxOut ConwayEra))]
    -> [(Text, Value)]
receiptFields planned tx published =
    [ ("token", toJSON (renderStateToken (plannedToken planned)))
    , ("transaction", toJSON (txIdHex tx))
    ,
        ( "publications"
        , toJSON
            [ Aeson.object
                [ "role" Aeson..= roleName role
                , "destination" Aeson..= bech32Address (plannedPayer planned)
                , "scriptHash"
                    Aeson..= hexT (scriptHashBytes (hashScript (plannedScript planned role)))
                , "transaction" Aeson..= txIdHex tx
                , "output" Aeson..= Live.txInText out
                ]
            | (role, (out, _)) <- published
            ]
        )
    ,
        ( "references"
        , toJSON
            [ Aeson.object
                [ "role" Aeson..= roleName role
                , "output" Aeson..= Live.txInText out
                , "scriptHash"
                    Aeson..= hexT (scriptHashBytes (hashScript (plannedScript planned role)))
                ]
            | (role, (out, _)) <- published
            ]
        )
    ]
