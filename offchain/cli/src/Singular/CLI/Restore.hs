{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.CLI.Restore
Description : Explicit needed-role restoration for opted-in writes
License     : Apache-2.0

Planning and funding shared by the @publish-references@ command and the
explicit @--publish-references@ opt-in on dependent writes: what
publication will send, the wallet it funds from, and the location of the
published outputs in their transaction. Nothing here attaches a write;
callers in @Singular.CLI.Attached@ and @Singular.CLI.References@ do.
-}
module Singular.CLI.Restore
    ( Planned (..)
    , planPublish
    , planPublishMaybe
    , plannedScript
    , plannedScriptList
    , acquireWallet
    , locateOutputs
    ) where

import Control.Exception (throwIO)
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T

import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body (outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Core (Script)
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import Lens.Micro ((^.))

import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Session (failWith)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (Addr, ConwayEra)
import Singular.Registry.LedgerProvider (Asset, Session)
import Singular.Registry.StateToken
    ( ReferenceRole
    , Release
    , checkedScript
    , expectedReferences
    , missingReferences
    , renderReferenceRefusal
    )
import Singular.Registry.WalletOutputs
    ( FundingViewRefusal (..)
    , WalletOutputs
    , narrowFunding
    , renderFundingRefusal
    , walletOutputs
    )

-- | What publication will send: the checked scripts for the missing roles.
data Planned = Planned
    { plannedToken :: Asset
    , plannedPayer :: Addr
    , plannedRoles :: [ReferenceRole]
    , plannedScripts :: [(ReferenceRole, Script ConwayEra)]
    , plannedFund :: Maybe TxIn
    }

{- | Resolve the token, find the missing roles among the requested ones
and hash-check what would be built. Refusals name their cause before
anything is built, signed or written.
-}
planPublish
    :: Session NoWitness IO
    -> Release
    -> Asset
    -> Addr
    -> [ReferenceRole]
    -> Maybe TxIn
    -> IO Planned
planPublish v release token payer requested fund =
    maybe
        (failWith ClientRefusal "no missing reference scripts to publish")
        pure
        =<< planPublishMaybe v release token payer requested fund

{- | The plan when roles are missing, or nothing when every requested
role is already present. The empty case is an ordinary outcome, not
a refusal: callers that must do work refuse it themselves.
-}
planPublishMaybe
    :: Session NoWitness IO
    -> Release
    -> Asset
    -> Addr
    -> [ReferenceRole]
    -> Maybe TxIn
    -> IO (Maybe Planned)
planPublishMaybe v release token payer requested fund = do
    let expected = expectedReferences release token
        wanted =
            if null requested
                then Map.keys expected
                else requested
    (_, missing) <-
        missingReferences v (Just payer) expected (Set.fromList wanted)
            >>= either
                (failWith ClientRefusal . T.unpack . renderReferenceRefusal)
                pure
    let selected = [r | r <- wanted, r `Set.member` missing]
    case selected of
        [] -> pure Nothing
        _ -> do
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
                ( Just
                    Planned
                        { plannedToken = token
                        , plannedPayer = payer
                        , plannedRoles = selected
                        , plannedScripts = scripts
                        , plannedFund = fund
                        }
                )

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
    :: Session NoWitness IO -> Planned -> IO WalletOutputs
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

{- | The published outputs located in their transaction, by exact output
equality; a built output the transaction does not carry fails closed.
-}
locateOutputs
    :: ConwayTx
    -> [TxOut ConwayEra]
    -> [ReferenceRole]
    -> IO [(ReferenceRole, (TxIn, TxOut ConwayEra))]
locateOutputs tx refouts roles = do
    let outs = toList (tx ^. bodyTxL . outputsTxBodyL)
        locate refout = case [ix | (ix, out) <- zip [0 ..] outs, out == refout] of
            ix : _ -> pure (TxIn (txIdTx tx) (TxIx ix), refout)
            [] ->
                failWith ClientRefusal "a published output is not in its transaction"
    zip roles <$> traverse locate refouts
