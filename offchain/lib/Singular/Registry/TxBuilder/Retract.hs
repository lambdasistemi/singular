{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Singular.Registry.TxBuilder.Retract
Description : Retract request transaction
License     : Apache-2.0

Builds the retract transaction that cancels a
pending request. The requester spends their request
UTxO (recovering locked ADA) while referencing the
State UTxO. Validity interval is Phase 2.
-}
module Singular.Registry.TxBuilder.Retract
    ( retractRequestImpl
    , retractRequestAtTipImpl
    ) where

import Control.Monad (when)
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Allegra.Scripts
    ( ValidityInterval (..)
    )
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Alonzo.TxBody
    ( reqSignerHashesTxBodyL
    , scriptIntegrityHashTxBodyL
    )
import Cardano.Ledger.Api.Tx
    ( mkBasicTx
    , witsTxL
    )
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , inputsTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( coinTxOutL
    , datumTxOutL
    , getMinCoinTxOut
    )
import Cardano.Ledger.Api.Tx.Wits
    ( Redeemers (..)
    , rdmrsTxWitsL
    , scriptTxWitsL
    )
import Cardano.Ledger.BaseTypes
    ( SlotNo (..)
    , StrictMaybe (SJust)
    )
import Cardano.Ledger.Conway.Scripts
    ( ConwayPlutusPurpose (..)
    )
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.TxIn (TxIn)

import Cardano.Tx.Ledger (ConwayTx)
import PlutusTx.Builtins.Internal
    ( BuiltinByteString (..)
    )
import Singular.Registry.Config
    ( CageConfig (..)
    )
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger
    ( ConwayTxBody
    , TokenId
    )
import Singular.Registry.LedgerProvider
    ( Session (..)
    , TipObservation (..)
    )
import Singular.Registry.SessionIO (outputsAt, parameters)
import Singular.Registry.SessionIO qualified as Services
import Singular.Registry.TxBuilder.Edges (selectFunding)
import Singular.Registry.TxBuilder.Internal
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRequest (..)
    , OnChainTokenState (..)
    , UpdateRedeemer (..)
    )

{- | Build a retract-request transaction.

The requester spends their request UTxO while referencing the
state UTxO. All its lovelace is paid to the request owner's key,
with the consumed request reference as the return's inline datum.
Wallet funding pays fees separately. Requires Phase 2 validity.
-}
retractRequestImpl
    :: CageConfig
    -> Session NoWitness IO
    -> TokenId
    -- ^ Token the request belongs to
    -> TxIn
    -- ^ UTxO reference of the request to retract
    -> Addr
    -- ^ Fee payer and change address
    -> IO ConwayTx
retractRequestImpl = retractRequestAtTipImpl (SlotNo 0)

{- | Use the caller's tip as the lower validity bound, while staying
inside phase 2. Refuse @lower-bound-ahead-of-view@ if that bound or the
phase-two opening is later than the acquired view's own tip.
-}
retractRequestAtTipImpl
    :: SlotNo
    -> CageConfig
    -> Session NoWitness IO
    -> TokenId
    -> TxIn
    -> Addr
    -> IO ConwayTx
retractRequestAtTipImpl tip cfg view tid reqTxIn addr = do
    let reqAddr =
            requestAddrFromCfg cfg tid (network cfg)
        stateAddr =
            cageAddrFromCfg cfg (network cfg)
    requestUtxos <- outputsAt view reqAddr
    stateUtxos <- outputsAt view stateAddr
    let reqUtxo =
            findUtxoByTxIn reqTxIn requestUtxos
    reqUtxoPair <- case reqUtxo of
        Nothing ->
            error
                "retractRequest: request UTxO \
                \not found on chain"
        Just x -> pure x
    let (reqIn, reqOut) = reqUtxoPair
    let policyId = cagePolicyIdFromCfg cfg
    stateUtxo <-
        case findStateUtxo
            policyId
            tid
            stateUtxos of
            Nothing ->
                error
                    "retractRequest: state UTxO \
                    \not found"
            Just x -> pure x
    let (stateIn, stateOut) = stateUtxo
    pp <- parameters view
    walletUtxos <- outputsAt view addr
    -- The funding output is also the collateral, so it must hold ada and
    -- nothing else, and must not be a published reference script.
    feeUtxo <- case selectFunding Nothing walletUtxos of
        Left why -> error ("retractRequest: " <> why)
        Right u -> pure u
    let reqDatum = case extractCageDatum reqOut of
            Just (RequestDatum r) -> r
            _ ->
                error
                    "retractRequest: invalid \
                    \request datum"
        OnChainRequest
            { requestOwner =
                BuiltinByteString ownerBs
            , requestSubmittedAt = submAt
            } = reqDatum
        ownerKh = addrWitnessKeyHash ownerBs
    let stateDatum =
            case extractCageDatum stateOut of
                Just (StateDatum s) -> s
                _ ->
                    error
                        "retractRequest: invalid \
                        \state datum"
        OnChainTokenState
            { stateProcessTime = procTime
            , stateRetractTime = retrTime
            } = stateDatum
    let phase2Start = submAt + procTime
        phase2End = submAt + procTime + retrTime
    phase2Slot <-
        Services.ceilingSlot view phase2Start
    let lowerSlot = max tip phase2Slot
    observed <- Services.tip view
    when (lowerSlot > observedSlot observed) $
        fail "retractRequest: lower-bound-ahead-of-view"
    _ <- Services.slotStart view lowerSlot
    -- The window's end may lie past what the node can translate to a slot
    -- (its horizon). A validity upper bound anywhere inside the window is as
    -- correct as its end, so a nearer bound stands in: the window's end first,
    -- then thirty, ten and three seconds from now, never past the end.
    nowMs <- currentPosixMs
    SlotNo s <-
        tryUpperSlots
            view
            ( nub
                [ phase2End
                , min phase2End (nowMs + 30_000)
                , min phase2End (nowMs + 10_000)
                , min phase2End (nowMs + 3_000)
                ]
            )
    let upperSlot = SlotNo (max 0 (s - 1))
        script = mkRequestScript cfg tid
        scriptHash = hashScript script
        allInputs =
            Set.fromList [reqIn, fst feeUtxo]
        reqIx = spendingIndex reqIn allInputs
        stateRef = txInToRef stateIn
        redeemer = Retract stateRef
        spendPurpose =
            ConwaySpending (AsIx reqIx)
        redeemers =
            Redeemers $
                Map.singleton
                    spendPurpose
                    ( toLedgerData redeemer
                    , placeholderExUnits
                    )
        integrity =
            computeScriptIntegrity pp redeemers
        vldt =
            ValidityInterval
                (SJust lowerSlot)
                (SJust upperSlot)
        boundRefund =
            computeRefund pp (network cfg) 0 reqOut
                & datumTxOutL .~ mkInlineDatum (toPlcData (txInToRef reqIn))
        refund =
            boundRefund
                & coinTxOutL
                    .~ max (boundRefund ^. coinTxOutL) (getMinCoinTxOut pp boundRefund)
        body :: ConwayTxBody
        body =
            mkBasicTxBody
                & inputsTxBodyL
                    .~ Set.singleton reqIn
                & referenceInputsTxBodyL
                    .~ Set.singleton stateIn
                & outputsTxBodyL
                    .~ StrictSeq.singleton
                        refund
                & collateralInputsTxBodyL
                    .~ Set.singleton
                        (fst feeUtxo)
                & reqSignerHashesTxBodyL
                    .~ Set.singleton ownerKh
                & vldtTxBodyL .~ vldt
                & scriptIntegrityHashTxBodyL
                    .~ integrity
        tx =
            mkBasicTx body
                & witsTxL . scriptTxWitsL
                    .~ Map.singleton
                        scriptHash
                        script
                & witsTxL . rdmrsTxWitsL
                    .~ redeemers
    evaluateAndBalance
        view
        pp
        [feeUtxo, reqUtxoPair]
        addr
        tx
