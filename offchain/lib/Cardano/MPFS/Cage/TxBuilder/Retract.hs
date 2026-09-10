{- |
Module      : Cardano.MPFS.Cage.TxBuilder.Retract
Description : Retract request transaction
License     : Apache-2.0

Builds the retract transaction that cancels a
pending request. The requester spends their request
UTxO (recovering locked ADA) while referencing the
State UTxO. Validity interval is Phase 2.
-}
module Cardano.MPFS.Cage.TxBuilder.Retract (
    retractRequestImpl,
) where

import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Set qualified as Set
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Allegra.Scripts (
    ValidityInterval (..),
 )
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Alonzo.TxBody (
    reqSignerHashesTxBodyL,
    scriptIntegrityHashTxBodyL,
 )
import Cardano.Ledger.Api.Tx (
    mkBasicTx,
    witsTxL,
 )
import Cardano.Ledger.Api.Tx.Body (
    collateralInputsTxBodyL,
    inputsTxBodyL,
    mkBasicTxBody,
    referenceInputsTxBodyL,
    vldtTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    coinTxOutL,
 )
import Cardano.Ledger.Api.Tx.Wits (
    Redeemers (..),
    rdmrsTxWitsL,
    scriptTxWitsL,
 )
import Cardano.Ledger.BaseTypes (
    SlotNo (..),
    StrictMaybe (SJust),
 )
import Cardano.Ledger.Conway.Scripts (
    ConwayPlutusPurpose (..),
 )
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.TxIn (TxIn)

import Cardano.MPFS.Cage.Config (
    CageConfig (..),
 )
import Cardano.MPFS.Cage.Ledger (
    ConwayTxBody,
    TokenId,
 )
import Cardano.MPFS.Cage.Provider (Provider (..))
import Cardano.MPFS.Cage.TxBuilder.Internal
import Cardano.MPFS.Cage.Types (
    CageDatum (..),
    OnChainRequest (..),
    OnChainTokenState (..),
    UpdateRedeemer (..),
 )
import Cardano.Tx.Ledger (ConwayTx)
import PlutusTx.Builtins.Internal (
    BuiltinByteString (..),
 )

{- | Build a retract-request transaction.

The requester spends their request UTxO
(returning locked ADA) while referencing the
state UTxO. Requires Phase 2 validity.
-}
retractRequestImpl ::
    CageConfig ->
    Provider IO ->
    -- | Token the request belongs to
    TokenId ->
    -- | UTxO reference of the request to retract
    TxIn ->
    -- | Requester's address (receives refund)
    Addr ->
    IO ConwayTx
retractRequestImpl cfg prov tid reqTxIn addr = do
    let reqAddr =
            requestAddrFromCfg cfg tid (network cfg)
        stateAddr =
            cageAddrFromCfg cfg (network cfg)
    requestUtxos <- queryUTxOs prov reqAddr
    stateUtxos <- queryUTxOs prov stateAddr
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
    pp <- queryProtocolParams prov
    walletUtxos <- queryUTxOs prov addr
    feeUtxo <- case sortOn
        (Down . (^. coinTxOutL) . snd)
        walletUtxos of
        [] -> error "retractRequest: no UTxOs"
        (u : _) -> pure u
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
    lowerSlot <-
        posixMsCeilSlot prov phase2Start
    SlotNo s <-
        posixMsToSlot prov phase2End
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
        body :: ConwayTxBody
        body =
            mkBasicTxBody
                & inputsTxBodyL
                    .~ Set.singleton reqIn
                & referenceInputsTxBodyL
                    .~ Set.singleton stateIn
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
        prov
        pp
        [feeUtxo, reqUtxoPair]
        addr
        tx
