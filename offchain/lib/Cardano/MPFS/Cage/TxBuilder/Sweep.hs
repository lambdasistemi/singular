{- |
Module      : Cardano.MPFS.Cage.TxBuilder.Sweep
Description : Owner-sweep transaction
License     : Apache-2.0

Builds a sweep transaction. The cage owner spends a
non-legitimate UTxO at the per-cage request address
(no datum, a request datum targeting a different
token, or another malformed request UTxO) while
referencing the state UTxO from which the validator
reads the owner's public-key hash for the signature
check.

The sweep predicate is enforced on-chain: the
spent UTxO must NOT be the legitimate state UTxO
and must NOT be a legitimate request for this cage.
The redeemer points at the state UTxO so the
validator can locate it directly.
-}
module Cardano.MPFS.Cage.TxBuilder.Sweep (
    sweepUtxoImpl,
) where

import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Set qualified as Set
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Address (Addr)
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
 )
import Cardano.Ledger.Api.Tx.Out (
    coinTxOutL,
 )
import Cardano.Ledger.Api.Tx.Wits (
    Redeemers (..),
    rdmrsTxWitsL,
    scriptTxWitsL,
 )
import Cardano.Ledger.Conway.Scripts (
    ConwayPlutusPurpose (..),
 )
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.TxIn (TxIn)
import PlutusTx.Builtins.Internal (
    BuiltinByteString (..),
 )

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
    OnChainTokenState (..),
    UpdateRedeemer (..),
 )
import Cardano.Tx.Ledger (ConwayTx)

{- | Build a standalone sweep transaction.

Spends one non-legitimate UTxO at the cage's
address. References the state UTxO so the validator
can read the owner's verification-key hash.
Requires the state owner's signature.

Bundling sweep with @Modify@ in the same tx is also
supported by the on-chain validator (the state UTxO
is in @tx.inputs@ rather than @tx.reference_inputs@
in that case), but this builder produces only the
standalone shape.
-}
sweepUtxoImpl ::
    CageConfig ->
    Provider IO ->
    -- | Token whose cage's address is being swept
    TokenId ->
    -- | UTxO reference of the garbage to sweep
    TxIn ->
    {- | State owner's address (signs the tx; collateral
    and balancing come from this wallet)
    -}
    Addr ->
    IO ConwayTx
sweepUtxoImpl cfg prov tid garbTxIn addr = do
    let reqAddr =
            requestAddrFromCfg cfg tid (network cfg)
        stateAddr =
            cageAddrFromCfg cfg (network cfg)
    requestUtxos <- queryUTxOs prov reqAddr
    stateUtxos <- queryUTxOs prov stateAddr
    -- Locate the garbage UTxO being swept.
    garbUtxoPair <-
        case findUtxoByTxIn garbTxIn requestUtxos of
            Nothing ->
                error
                    "sweepUtxo: garbage UTxO not \
                    \found at the request address"
            Just x -> pure x
    let (garbIn, _garbOut) = garbUtxoPair
    -- Locate the legitimate state UTxO (carries
    -- the cage token under this validator's policy).
    let policyId = cagePolicyIdFromCfg cfg
    stateUtxo <-
        case findStateUtxo
            policyId
            tid
            stateUtxos of
            Nothing ->
                error
                    "sweepUtxo: state UTxO not \
                    \found at the state address"
            Just x -> pure x
    let (stateIn, stateOut) = stateUtxo
    pp <- queryProtocolParams prov
    walletUtxos <- queryUTxOs prov addr
    feeUtxo <- case sortOn
        (Down . (^. coinTxOutL) . snd)
        walletUtxos of
        [] -> error "sweepUtxo: no UTxOs in wallet"
        (u : _) -> pure u
    -- Read the state owner's verification-key hash.
    let stateDatum =
            case extractCageDatum stateOut of
                Just (StateDatum s) -> s
                _ ->
                    error
                        "sweepUtxo: invalid state \
                        \datum at state UTxO"
        OnChainTokenState
            { stateOwner =
                BuiltinByteString ownerBs
            } = stateDatum
        ownerKh = addrWitnessKeyHash ownerBs
    let script = mkRequestScript cfg tid
        scriptHash = hashScript script
        allInputs =
            Set.fromList [garbIn, fst feeUtxo]
        garbIx = spendingIndex garbIn allInputs
        stateRef = txInToRef stateIn
        redeemer = Sweep stateRef
        spendPurpose =
            ConwaySpending (AsIx garbIx)
        redeemers =
            Redeemers $
                Map.singleton
                    spendPurpose
                    ( toLedgerData redeemer
                    , placeholderExUnits
                    )
        integrity =
            computeScriptIntegrity pp redeemers
        body :: ConwayTxBody
        body =
            mkBasicTxBody
                & inputsTxBodyL
                    .~ Set.singleton garbIn
                & referenceInputsTxBodyL
                    .~ Set.singleton stateIn
                & collateralInputsTxBodyL
                    .~ Set.singleton
                        (fst feeUtxo)
                & reqSignerHashesTxBodyL
                    .~ Set.singleton ownerKh
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
        [feeUtxo, garbUtxoPair]
        addr
        tx
