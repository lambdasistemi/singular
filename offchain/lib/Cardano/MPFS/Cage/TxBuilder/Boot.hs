{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Cardano.MPFS.Cage.TxBuilder.Boot
Description : Boot token minting transaction
License     : Apache-2.0

Builds the minting transaction for a new cage
token. Picks a wallet UTxO as seed for asset-name
derivation, mints +1 token at the cage policy, and
creates a State UTxO with empty root and configured
default parameters.
-}
module Cardano.MPFS.Cage.TxBuilder.Boot (
    bootTokenImpl,
) where

import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Lens.Micro ((&), (.~))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Alonzo.TxBody (
    scriptIntegrityHashTxBodyL,
 )
import Cardano.Ledger.Api.Tx (
    mkBasicTx,
    witsTxL,
 )
import Cardano.Ledger.Api.Tx.Body (
    collateralInputsTxBodyL,
    inputsTxBodyL,
    mintTxBodyL,
    mkBasicTxBody,
    outputsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    datumTxOutL,
    mkBasicTxOut,
 )
import Cardano.Ledger.Api.Tx.Wits (
    Redeemers (..),
    rdmrsTxWitsL,
    scriptTxWitsL,
 )
import Cardano.Ledger.Conway.Scripts (
    ConwayPlutusPurpose (..),
 )
import Cardano.Ledger.Core (TxOut, hashScript)
import Cardano.Ledger.Mary.Value (
    MaryValue (..),
    MultiAsset (..),
 )
import Cardano.Ledger.TxIn (TxIn)
import Data.List (find)
import PlutusTx.Builtins.Internal (
    BuiltinByteString (..),
 )

import Cardano.MPFS.Cage.AssetName (deriveAssetName)
import Cardano.MPFS.Cage.Config (
    CageConfig (..),
 )
import Cardano.MPFS.Cage.Ledger (
    AssetName (..),
    Coin (..),
    ConwayEra,
 )
import Cardano.MPFS.Cage.Provider (Provider (..))
import Cardano.MPFS.Cage.TxBuilder.Internal
import Cardano.MPFS.Cage.Types (
    CageDatum (..),
    MintRedeemer (..),
    OnChainRoot (..),
    OnChainTokenState (..),
    OnChainTxOutRef,
 )
import Cardano.Tx.Ledger (ConwayTx)

-- | Locate the wallet UTxO whose on-chain reference matches @cageSeed@.
lookupSeed ::
    OnChainTxOutRef ->
    [(TxIn, TxOut ConwayEra)] ->
    Maybe (TxIn, TxOut ConwayEra)
lookupSeed target =
    find (\(tin, _) -> txInToRef tin == target)

-- | Build a boot-token minting transaction.
bootTokenImpl ::
    CageConfig ->
    Provider IO ->
    Addr ->
    IO ConwayTx
bootTokenImpl cfg prov addr = do
    pp <- queryProtocolParams prov
    utxos <- queryUTxOs prov addr
    -- The seed UTxO is carried in the mint redeemer. We MUST consume
    -- that exact UTxO -- any other input would fail the validator's
    -- `find_input(inputs, seed)` check. Locate it in the caller's
    -- wallet and use it as the seed input.
    let seedRefOnChain = cageSeed cfg
    seedUtxo <- case lookupSeed seedRefOnChain utxos of
        Just u -> pure u
        Nothing ->
            error
                "bootToken: cfg's cageSeed UTxO is not in the\
                \ caller's wallet — cfg may have been built for\
                \ a different seed than the wallet currently\
                \ holds"
    let (seedRef, _seedOut) = seedUtxo
        rest = filter (/= seedUtxo) utxos
        allInputUtxos = case rest of
            [] -> [seedUtxo]
            (u : _) -> [seedUtxo, u]
        assetNameBs =
            deriveAssetName seedRefOnChain
        assetName =
            AssetName
                (SBS.toShort assetNameBs)
    let policyId =
            cagePolicyIdFromCfg cfg
        mintMA =
            MultiAsset
                $ Map.singleton
                    policyId
                $ Map.singleton
                    assetName
                    1
    let stateDatum =
            StateDatum
                OnChainTokenState
                    { stateOwner =
                        BuiltinByteString
                            ( addrKeyHashBytes
                                addr
                            )
                    , stateStakeScript =
                        fmap
                            ( BuiltinByteString
                                . scriptHashBytes
                                . snd
                            )
                            (cfgStakeScript cfg)
                    , stateRoot =
                        OnChainRoot emptyRoot
                    , stateMaxFee =
                        let Coin c =
                                defaultTip cfg
                         in c
                    , stateProcessTime =
                        defaultProcessTime
                            cfg
                    , stateRetractTime =
                        defaultRetractTime
                            cfg
                    }
        datumData = toPlcData stateDatum
    let scriptAddr =
            cageAddrFromCfg
                cfg
                (network cfg)
        outValue =
            MaryValue
                (Coin 2_000_000)
                mintMA
        txOut =
            mkBasicTxOut
                scriptAddr
                outValue
                & datumTxOutL
                    .~ mkInlineDatum
                        datumData
    let script = mkCageScript cfg
        scriptHash = hashScript script
        redeemer = Minting seedRefOnChain
        mintPurpose =
            ConwayMinting (AsIx 0)
        redeemers =
            Redeemers $
                Map.singleton
                    mintPurpose
                    ( toLedgerData redeemer
                    , placeholderExUnits
                    )
    let integrity =
            computeScriptIntegrity
                pp
                redeemers
        body =
            mkBasicTxBody
                & inputsTxBodyL
                    .~ Set.singleton
                        seedRef
                & outputsTxBodyL
                    .~ StrictSeq.singleton
                        txOut
                & mintTxBodyL .~ mintMA
                & collateralInputsTxBodyL
                    .~ Set.singleton
                        ( fst $
                            last
                                allInputUtxos
                        )
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
        allInputUtxos
        addr
        tx
