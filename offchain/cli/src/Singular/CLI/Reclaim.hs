{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.Reclaim
Description : Return the owner's pending request inside its retract window
License     : Apache-2.0

Reclaim uses the existing retract builder without changing the registry
root. Its admission is decided before building from one view, and the
built interval and request-bound owner return are checked before signing.
The receipt reports the locked request and the return as the chain holds
them, without asserting a deposit that the request never held.
-}
module Singular.CLI.Reclaim (runReclaim) where

import Control.Monad (unless, when)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.Foldable (toList)
import Data.Set qualified as Set
import Data.Text qualified as T
import Lens.Micro ((^.))

import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( ValidityInterval (..)
    , inputsTxBodyL
    , mintTxBodyL
    , outputsTxBodyL
    , reqSignerHashesTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (addrTxOutL, datumTxOutL)
import Cardano.Ledger.BaseTypes
    ( Network (Testnet)
    , StrictMaybe (..)
    , TxIx (..)
    )
import Cardano.Ledger.TxIn (TxIn (..))

import Cardano.Slotting.Slot qualified as Cage
import Singular.CLI.Attached
import Singular.CLI.Command
    ( Command (..)
    , ReclaimArgs (..)
    , neededRoles
    )
import Singular.CLI.Fold (slotAt)
import Singular.CLI.FoldRules (boundStartMs, fundedView, placedEdge)
import Singular.CLI.Live
import Singular.CLI.Outlay (updateOutlay)
import Singular.CLI.Plan (refuseOver)
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.ReclaimRules
import Singular.CLI.Registry (hexT)
import Singular.CLI.RequestWindow (Bounds (..), windowOf)
import Singular.CLI.Session
import Singular.CLI.Trace
    ( EdgeAction (..)
    , Scope (..)
    , What (EdgeStarted, Reclaimed, RequestSeen, RootSeen)
    , report
    )
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.SessionIO qualified as Services
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , addrWitnessKeyHash
    , extractCageDatum
    , extractOwnerBytes
    , findRequestUtxos
    , mkInlineDatum
    , requestAddrFromCfg
    , toPlcData
    , txInToRef
    )
import Singular.Registry.TxBuilder.Retract (retractRequestAtTipImpl)
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRequest (..)
    , OnChainTokenState (..)
    , edgeName
    )
import Singular.Registry.Wallet (Wallet (..), bech32Address)

-- | Reclaim, signed and funded by the command's own wallet, then observed.
runReclaim :: Env -> ReclaimArgs -> IO Value
runReclaim env a = attached
    env
    (reclaimStateDir a)
    (reclaimBlueprint a)
    (reclaimAccess a)
    (neededRoles (Reclaim a))
    (reclaimWrite a)
    "reclaim"
    $ \at -> do
        let s = savedOf at
            wc = atWrite at
            caller = callerKey at
            wallet = walletAddr (wcWallet wc)
            cfg = savedCfg s
            requestAddr = requestAddrFromCfg cfg (savedToken s) Testnet
            named = reclaimRequest a
            recipient = addrFromKeyHashBytes Testnet caller
            boundDatum = mkInlineDatum (toPlcData (txInToRef named))
            requestField = [("request", toJSON (txInText named))]
            stop why = failWithFields ClientRefusal why requestField
            edgeText = T.pack . edgeName . requestEdge
            placed r =
                [InRequest (txInText named), InEdge (Reclaiming (edgeText r))]
        root <- selectedTrieRoot (atTrie at)
        (tx, (locked, req, bounds, tipSlot, opens, closes, returned)) <-
            submitBuiltIn
                wc
                "reclaim"
                ["requests", "state"]
                (const (expecting ("reclaim:" <> txInText named)))
                $ \building v -> do
                    allRequests <- Cage.outputsAt v requestAddr
                    let pending = findRequestUtxos (savedToken s) allRequests
                    locked <-
                        maybe
                            (stop (renderReclaimRefusal NotPending))
                            pure
                            (lookup named pending)
                    req <- case extractCageDatum locked of
                        Just (RequestDatum r) -> pure r
                        _ -> stop "the named pending request has no request datum"
                    live <- attachLive v s
                    st <- case extractCageDatum (snd (liveState live)) of
                        Just (StateDatum st) -> pure st
                        _ -> stop "the registry's state output carries no state datum"
                    observed <- Cage.tip v
                    let b =
                            windowOf
                                (requestSubmittedAt req)
                                (stateProcessTime st)
                                (stateRetractTime st)
                        tip = Cage.observedSlot observed
                        tipSlot = toInteger (Cage.unSlotNo tip)
                    opens <-
                        fmap (toInteger . Cage.unSlotNo) <$> slotAt v (processingEnds b)
                    closes <-
                        fmap (toInteger . Cage.unSlotNo) <$> slotAt v (retractEnds b)
                    found
                        building
                        [InRequest (txInText named)]
                        ( RequestSeen
                            (txInText named)
                            (edgeText req)
                            (requestKey req)
                            (Just (processingEnds b))
                            (fromInteger <$> opens)
                        )
                    place building (placed req) (EdgeStarted (Reclaiming (edgeText req)))
                    bounds <-
                        either (stop . renderReclaimRefusal) pure $
                            reclaimGate
                                caller
                                (Just (extractOwnerBytes locked, requestEdge req, b, opens, closes))
                                tipSlot
                    -- Opening needs a conversion; reject's shared reading keeps
                    -- an unconverted retract deadline open, without a clock estimate.
                    start <- case opens of
                        Just start -> pure start
                        _ -> stop "the view cannot establish the opening of the retract window"
                    ceilStart <-
                        toInteger . Cage.unSlotNo
                            <$> Services.ceilingSlot v (processingEnds bounds)
                    funded <-
                        fundedView (reclaimFund a) wallet v
                            >>= either (stop . ("the wallet cannot fund the reclaim: " <>)) pure
                    unsigned <-
                        retractRequestAtTipImpl tip cfg funded (savedToken s) named wallet
                    let body = unsigned ^. bodyTxL
                        interval = body ^. vldtTxBodyL
                        slot = \case
                            SJust n -> Just (toInteger (Cage.unSlotNo n))
                            SNothing -> Nothing
                        upper = slot (invalidHereafter interval)
                    upperLimit <- case closes of
                        Just end -> pure (DeadlineSlot end)
                        Nothing -> do
                            let slotOf ms =
                                    fmap (toInteger . Cage.unSlotNo) <$> slotAt v ms
                            high <- placedEdge slotOf (processingEnds bounds) (retractEnds bounds)
                            boundTime <- case (high, upper) of
                                (Just hi, Just u) -> boundStartMs slotOf (processingEnds bounds) hi u
                                _ -> pure Nothing
                            pure (DeadlineTime (retractEnds bounds) boundTime)
                    unless
                        ( reclaimValidity
                            (max start ceilStart)
                            upperLimit
                            (slot (invalidBefore interval))
                            upper
                        )
                        $ stop
                            "not-phase2: the built reclaim has no nonempty validity interval inside the retract window; it is not signed"
                    -- Fees come from this wallet. No state or another request may be spent.
                    walletOuts <- Cage.outputsAt funded wallet
                    let spent = Set.fromList (toList (body ^. inputsTxBodyL))
                        allowed = Set.fromList (named : map fst walletOuts)
                    unless
                        ( named `Set.member` spent
                            && spent `Set.isSubsetOf` allowed
                            && body ^. mintTxBodyL == mempty
                        )
                        $ stop
                            "the built reclaim does not spend only the named request and this wallet's funding, without minting; it is not signed"
                    unless
                        ( addrWitnessKeyHash caller
                            `Set.member` (body ^. reqSignerHashesTxBodyL)
                        )
                        $ stop
                            "retract-owner: the built reclaim does not require the owner's signature; it is not signed"
                    returned <- case toList (body ^. outputsTxBodyL) of
                        out : _
                            | out ^. addrTxOutL == recipient
                            , out ^. datumTxOutL == boundDatum
                            , coinOf out >= coinOf locked ->
                                pure out
                        _ ->
                            stop
                                "deposit-returned: the built reclaim has no whole owner return bound to the named request in output 0; it is not signed"
                    refuseOver (reclaimMaxOutlay a) (updateOutlay unsigned)
                    pure
                        (unsigned, (locked, req, bounds, tipSlot, opens, closes, returned))
        (pendingAfter, liveAfter, ownerOuts) <- readingBack at "reclaim" tx ["requests", "state", "owner outputs"] $ \v -> do
            requests <- Cage.outputsAt v requestAddr
            live <- attachLive v s
            ownerOuts <- Cage.outputsAt v recipient
            pure (requests, live, ownerOuts)
        when (named `elem` map fst pendingAfter) $
            failWith
                Partial
                "the reclaim confirmed but its request output is still live"
        let output = TxIn (txIdTx tx) (TxIx 0)
        unless (lookup output ownerOuts == Just returned) $
            failWith
                Partial
                "the reclaim confirmed but its bound owner return is not live as built"
        rootAfter <- either (failWith Partial) pure (observedRoot liveAfter)
        unless (rootAfter == root) $
            failWith StaleState "the registry's root moved during a reclaim"
        journalObserved
            wc
            "reclaim"
            tx
            "the request is gone and its whole bound owner return is live; root unchanged"
        report
            (wcTracer wc)
            (placed req)
            (Reclaimed (txInText named) (coinOf returned))
        report (wcTracer wc) [] (RootSeen (hexT root) (hexT rootAfter))
        pure $
            receipt
                "reclaim"
                Success
                [ ("request", toJSON (txInText named))
                , ("retract", toJSON (txIdHex tx))
                , ("owner", toJSON (hexT caller))
                , ("key", toJSON (hexT (requestKey req)))
                , ("edge", toJSON (edgeName (requestEdge req)))
                , ("locked", valueJson locked)
                ,
                    ( "returned"
                    , object
                        [ "recipient" .= T.pack (bech32Address recipient)
                        , "output" .= txInText output
                        , "index" .= (0 :: Int)
                        , "lovelace" .= coinOf returned
                        , "value" .= valueJson returned
                        , "request" .= txInText named
                        ]
                    )
                , ("topUp", toJSON (coinOf returned - coinOf locked))
                , ("processingEnds", toJSON (processingEnds bounds))
                , ("retractEnds", toJSON (retractEnds bounds))
                , ("processingEndsSlot", toJSON opens)
                , ("retractEndsSlot", toJSON closes)
                , ("tipSlot", toJSON tipSlot)
                , ("root", toJSON (hexT rootAfter))
                ]
