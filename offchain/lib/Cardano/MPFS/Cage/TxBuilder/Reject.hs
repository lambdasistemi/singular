{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}

{- |
Module      : Cardano.MPFS.Cage.TxBuilder.Reject
Description : Reject transaction for Phase 3 requests
License     : Apache-2.0

Builds a reject transaction that consumes expired
(Phase 3) requests. The oracle keeps the tip and
refunds remaining ADA to request owners. The trie
root does NOT change.
-}
module Cardano.MPFS.Cage.TxBuilder.Reject (
    rejectRequestsImpl,
) where

import Control.Exception (SomeException, try)
import Control.Monad (when)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (
    utcTimeToPOSIXSeconds,
 )
import Data.Void (Void)
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Alonzo.Scripts (AsIx)
import Cardano.Ledger.Api.Tx (
    bodyTxL,
 )
import Cardano.Ledger.Api.Tx.Body (
    feeTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    coinTxOutL,
    datumTxOutL,
    getMinCoinTxOut,
    mkBasicTxOut,
    valueTxOutL,
 )
import Cardano.Ledger.BaseTypes (
    Inject (..),
 )
import Cardano.Ledger.Conway.Scripts (
    ConwayPlutusPurpose,
 )
import Cardano.Ledger.Core (Script)
import Cardano.Ledger.Keys (
    KeyHash,
    KeyRole (..),
 )
import Cardano.Ledger.Plutus.ExUnits (ExUnits)
import PlutusTx.Builtins.Internal (
    BuiltinByteString (..),
 )

import Cardano.MPFS.Cage.Config (
    CageConfig (..),
 )
import Cardano.MPFS.Cage.Ledger (
    Coin (..),
    ConwayEra,
    PParams,
    TokenId,
    TxIn,
 )
import Cardano.MPFS.Cage.Provider (
    Provider (..),
 )
import Cardano.MPFS.Cage.TxBuilder.Internal
import Cardano.MPFS.Cage.Types (
    CageDatum (..),
    OnChainRequest (..),
    OnChainTokenState (..),
    RequestAction (..),
    UpdateRedeemer (..),
 )
import Cardano.Slotting.Slot (SlotNo)
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)

-- | Empty query GADT (no context needed).
data NoCtx a

{- | Build a reject transaction for Phase 3
requests.
-}
rejectRequestsImpl ::
    CageConfig ->
    Provider IO ->
    TokenId ->
    Addr ->
    IO ConwayTx
rejectRequestsImpl cfg prov tid addr = do
    (stateUtxo, reqUtxos, feeUtxo, pp) <-
        queryRejectContext cfg prov tid addr
    let (_stateIn, stateOut) = stateUtxo
    let (oldState, newStateOut, script, ownerKh) =
            prepareRejectState cfg stateOut
        requestScript = mkRequestScript cfg tid
    lowerSlot <-
        computeLowerSlot prov oldState reqUtxos
    let evalTx = mkRejectEvalTx prov
        prog =
            buildRejectProgram
                cfg
                pp
                (fst stateUtxo)
                reqUtxos
                feeUtxo
                oldState
                newStateOut
                script
                requestScript
                ownerKh
                lowerSlot
    result <-
        Tx.build
            (Tx.mkPParamsBound pp)
            (Tx.InterpretIO (const (pure undefined)))
            evalTx
            (feeUtxo : stateUtxo : reqUtxos)
            []
            addr
            (prog :: Tx.TxBuild NoCtx Void ())
    case result of
        Right tx -> pure tx
        Left err ->
            error $
                "rejectRequests: build failed: "
                    <> show err

{- | Query cage UTxOs, find state, filter
rejectable requests, pick fee UTxO.
-}
queryRejectContext ::
    CageConfig ->
    Provider IO ->
    TokenId ->
    Addr ->
    IO
        ( (TxIn, TxOut ConwayEra)
        , [(TxIn, TxOut ConwayEra)]
        , (TxIn, TxOut ConwayEra)
        , PParams ConwayEra
        )
queryRejectContext cfg prov tid addr = do
    let stateAddr =
            cageAddrFromCfg cfg (network cfg)
        reqAddr =
            requestAddrFromCfg cfg tid (network cfg)
    stateUtxos <- queryUTxOs prov stateAddr
    requestUtxos <- queryUTxOs prov reqAddr
    let policyId = cagePolicyIdFromCfg cfg
    stateUtxo <- case findStateUtxo
        policyId
        tid
        stateUtxos of
        Nothing ->
            error
                "rejectRequests: state UTxO \
                \not found"
        Just x -> pure x
    let (_, stateOut) = stateUtxo
    now <- currentPosixMs
    let allReqs =
            sortOn fst $
                findRequestUtxos tid requestUtxos
        oldState =
            case extractCageDatum stateOut of
                Just (StateDatum s) -> s
                _ ->
                    error
                        "rejectRequests: invalid \
                        \state datum"
        pt = stateProcessTime oldState
        rt = stateRetractTime oldState
        isRejectable (_, rOut) =
            case extractCageDatum rOut of
                Just (RequestDatum r) ->
                    let sa = requestSubmittedAt r
                        deadline = sa + pt + rt
                     in now > deadline || sa > now
                _ -> False
        reqUtxos = filter isRejectable allReqs
    when (null reqUtxos) $
        error
            "rejectRequests: no rejectable \
            \requests"
    pp <- queryProtocolParams prov
    walletUtxos <- queryUTxOs prov addr
    feeUtxo <- case sortOn
        (Down . (^. coinTxOutL) . snd)
        walletUtxos of
        [] -> error "rejectRequests: no UTxOs"
        (u : _) -> pure u
    pure (stateUtxo, reqUtxos, feeUtxo, pp)

-- | Extract state, build new state output.
prepareRejectState ::
    CageConfig ->
    TxOut ConwayEra ->
    ( OnChainTokenState
    , TxOut ConwayEra
    , Script ConwayEra
    , KeyHash Guard
    )
prepareRejectState cfg stateOut =
    let scriptAddr =
            cageAddrFromCfg cfg (network cfg)
        oldState =
            case extractCageDatum stateOut of
                Just (StateDatum s) -> s
                _ ->
                    error
                        "rejectRequests: invalid \
                        \state datum"
        OnChainTokenState
            { stateOwner =
                BuiltinByteString ownerBs
            } = oldState
        newStateOut =
            mkBasicTxOut
                scriptAddr
                (stateOut ^. valueTxOutL)
                & datumTxOutL
                    .~ mkInlineDatum
                        ( toPlcData
                            (StateDatum oldState)
                        )
        script = mkCageScript cfg
        ownerKh = addrWitnessKeyHash ownerBs
     in (oldState, newStateOut, script, ownerKh)

-- | Compute the validity lower slot.
computeLowerSlot ::
    Provider IO ->
    OnChainTokenState ->
    [(TxIn, TxOut ConwayEra)] ->
    IO SlotNo
computeLowerSlot prov oldState reqUtxos = do
    let pt = stateProcessTime oldState
        rt = stateRetractTime oldState
        latestDeadline =
            maximum $
                map
                    ( \(_, rOut) ->
                        case extractCageDatum
                            rOut of
                            Just (RequestDatum r) ->
                                requestSubmittedAt r
                                    + pt
                                    + rt
                            _ -> 0
                    )
                    reqUtxos
    mLowerSlot <-
        try @SomeException
            (posixMsCeilSlot prov latestDeadline)
    case mLowerSlot of
        Right s -> pure s
        Left _ -> do
            nowUtc <- getCurrentTime
            let posixSec =
                    utcTimeToPOSIXSeconds nowUtc
            trySlots prov $
                map
                    ( \d ->
                        round
                            ((posixSec - d) * 1000)
                    )
                    [0, 5, 30]

-- | Wrap the Provider's evaluateTx for the DSL.
mkRejectEvalTx ::
    Provider IO ->
    ConwayTx ->
    IO
        ( Map.Map
            (ConwayPlutusPurpose AsIx ConwayEra)
            (Either String ExUnits)
        )
mkRejectEvalTx prov tx = do
    r <- evaluateTx prov tx
    pure $
        Map.map
            ( \case
                Left e -> Left (show e)
                Right eu -> Right eu
            )
            r

-- | The TxBuild DSL program for a reject tx.
buildRejectProgram ::
    CageConfig ->
    PParams ConwayEra ->
    TxIn ->
    [(TxIn, TxOut ConwayEra)] ->
    (TxIn, TxOut ConwayEra) ->
    OnChainTokenState ->
    TxOut ConwayEra ->
    Script ConwayEra ->
    Script ConwayEra ->
    KeyHash Guard ->
    SlotNo ->
    Tx.TxBuild NoCtx Void ()
buildRejectProgram
    cfg
    pp
    stateIn
    reqUtxos
    feeUtxo
    oldState
    newStateOut
    script
    requestScript
    ownerKh
    lowerSlot = do
        let stateRef = txInToRef stateIn
            OnChainTokenState
                { stateMaxFee = tipAmount
                } = oldState
            nReqs =
                fromIntegral (length reqUtxos) ::
                    Integer
        let actions =
                replicate (length reqUtxos) Rejected
        _ <- Tx.spendScript stateIn (Modify actions)
        mapM_
            ( \(rIn, _) ->
                Tx.spendScript
                    rIn
                    (Contribute stateRef)
            )
            reqUtxos
        _ <- Tx.output newStateOut
        Coin fee <- Tx.peek $ \tx ->
            let f = tx ^. bodyTxL . feeTxBodyL
             in if f > Coin 0
                    then Tx.Ok f
                    else Tx.Iterate f
        let perReqFee = fee `div` nReqs
        mapM_
            ( \(_, reqOut) -> do
                let Coin reqVal =
                        reqOut ^. coinTxOutL
                    rawRefund =
                        Coin
                            ( reqVal
                                - tipAmount
                                - perReqFee
                            )
                    refundAddr =
                        addrFromKeyHashBytes
                            (network cfg)
                            ( extractOwnerBytes
                                reqOut
                            )
                    draft =
                        mkBasicTxOut
                            refundAddr
                            (inject rawRefund)
                    minCoin =
                        getMinCoinTxOut pp draft
                Tx.output $
                    mkBasicTxOut
                        refundAddr
                        ( inject
                            (max rawRefund minCoin)
                        )
            )
            reqUtxos
        Tx.attachScript script
        Tx.attachScript requestScript
        Tx.requireSignature ownerKh
        Tx.collateral (fst feeUtxo)
        Tx.validFrom lowerSlot
