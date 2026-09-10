{-# LANGUAGE LambdaCase #-}

{- |
Module      : Cardano.MPFS.Cage.TxBuilder.End
Description : End token (burn) transaction
License     : Apache-2.0

Builds the burn transaction that retires a cage
token. Consumes the State UTxO with an @End@
spending redeemer, mints -1 with @Burning@, and
returns remaining ADA to the owner. When
'cfgStakeScript' is set, includes a withdraw-zero
from the configured staking credential.
-}
module Cardano.MPFS.Cage.TxBuilder.End (
    endTokenImpl,
) where

import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Void (Void)
import Lens.Micro ((^.))

import Cardano.Ledger.Address (
    AccountAddress (..),
    AccountId (..),
 )
import Cardano.Ledger.Alonzo.Scripts (AsIx)
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    coinTxOutL,
 )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway.Scripts (
    ConwayPlutusPurpose,
 )
import Cardano.Ledger.Credential (
    Credential (ScriptHashObj),
 )
import Cardano.Ledger.Keys (
    KeyHash,
    KeyRole (Guard),
 )
import Cardano.Ledger.Plutus.ExUnits (ExUnits)
import PlutusTx.Builtins.Internal (
    BuiltinByteString (..),
 )

import Cardano.MPFS.Cage.Config (
    CageConfig (..),
 )
import Cardano.MPFS.Cage.Ledger (
    Addr,
    ConwayEra,
    TokenId (..),
    TxIn,
 )
import Cardano.MPFS.Cage.Provider (Provider (..))
import Cardano.MPFS.Cage.TxBuilder.Internal
import Cardano.MPFS.Cage.Types (
    CageDatum (..),
    MintRedeemer (..),
    OnChainTokenState (..),
    UpdateRedeemer (..),
 )
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)

-- | Empty query GADT (no context needed).
data NoCtx a

-- | Build an end-token (burn) transaction.
endTokenImpl ::
    CageConfig ->
    Provider IO ->
    TokenId ->
    Addr ->
    IO ConwayTx
endTokenImpl cfg prov tid addr = do
    let scriptAddr = cageAddrFromCfg cfg (network cfg)
    cageUtxos <- queryUTxOs prov scriptAddr
    let policyId = cagePolicyIdFromCfg cfg
    stateUtxo <-
        case findStateUtxo policyId tid cageUtxos of
            Nothing -> error "endToken: state UTxO not found"
            Just x -> pure x
    let (stateIn, stateOut) = stateUtxo
        OnChainTokenState
            { stateOwner = BuiltinByteString ownerBs
            } = case extractCageDatum stateOut of
                Just (StateDatum s) -> s
                _ -> error "endToken: invalid state datum"
        ownerKh = addrWitnessKeyHash ownerBs
    pp <- queryProtocolParams prov
    walletUtxos <- queryUTxOs prov addr
    feeUtxo <- case sortOn (Down . (^. coinTxOutL) . snd) walletUtxos of
        [] -> error "endToken: no UTxOs"
        (u : _) -> pure u
    let evalTx = mkEvalTx prov
        prog =
            buildEndProgram
                cfg
                stateIn
                tid
                ownerKh
                feeUtxo
    result <-
        Tx.build
            (Tx.mkPParamsBound pp)
            (Tx.InterpretIO (const (pure undefined)))
            evalTx
            (feeUtxo : [stateUtxo])
            []
            addr
            (prog :: Tx.TxBuild NoCtx Void ())
    case result of
        Right tx -> pure tx
        Left err ->
            error $ "endToken: build failed: " <> show err

buildEndProgram ::
    CageConfig ->
    TxIn ->
    TokenId ->
    KeyHash Guard ->
    (TxIn, TxOut ConwayEra) ->
    Tx.TxBuild NoCtx Void ()
buildEndProgram cfg stateIn tid ownerKh feeUtxo = do
    let policyId = cagePolicyIdFromCfg cfg
        assetName = unTokenId tid
    _ <- Tx.spendScript stateIn End
    Tx.mint policyId (Map.singleton assetName (-1)) (Burning (onChainTokenId tid))
    Tx.requireSignature ownerKh
    Tx.collateral (fst feeUtxo)
    Tx.attachScript (mkCageScript cfg)
    case cfgStakeScript cfg of
        Nothing -> pure ()
        Just (stakeBytes, stakeHash) -> do
            let stakeScript =
                    scriptFromBytes
                        "endToken.stakeScript"
                        stakeBytes
                rewardAcct =
                    AccountAddress
                        (network cfg)
                        (AccountId (ScriptHashObj stakeHash))
            Tx.withdrawScript rewardAcct (Coin 0) (0 :: Integer)
            Tx.attachScript stakeScript

mkEvalTx ::
    Provider IO ->
    ConwayTx ->
    IO
        ( Map.Map
            (ConwayPlutusPurpose AsIx ConwayEra)
            (Either String ExUnits)
        )
mkEvalTx prov tx = do
    r <- evaluateTx prov tx
    pure $
        Map.map
            ( \case
                Left e -> Left (show e)
                Right eu -> Right eu
            )
            r
