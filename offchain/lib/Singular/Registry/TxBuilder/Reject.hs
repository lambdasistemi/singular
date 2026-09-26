{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Registry.TxBuilder.Reject
Description : Reject transaction for Phase 3 requests
License     : Apache-2.0

Builds a reject transaction that consumes expired
(Phase 3) requests. The oracle keeps the tip and
refunds remaining ADA to request owners. The trie
root does NOT change.
-}
module Singular.Registry.TxBuilder.Reject (
    rejectRequestsImpl,
    rejectRequestsWithRefs,
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
    mkBasicTxOut,
    referenceScriptTxOutL,
    valueTxOutL,
 )
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Conway.Scripts (
    ConwayPlutusPurpose,
 )
import Cardano.Ledger.Core (Script)
import Cardano.Ledger.Plutus.ExUnits (ExUnits)

import Cardano.Slotting.Slot (SlotNo)
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Config (
    CageConfig (..),
 )
import Singular.Registry.Ledger (
    Coin (..),
    ConwayEra,
    PParams,
    TokenId,
    TxIn,
 )
import Singular.Registry.Provider (
    Provider (..),
 )
import Singular.Registry.TxBuilder.Internal.Identity
import Singular.Registry.TxBuilder.Internal.Lookup
import Singular.Registry.Types (
    CageDatum (..),
    OnChainRequest (..),
    OnChainTokenState (..),
    RequestAction (..),
    UpdateRedeemer (..),
 )

-- | Empty query GADT (no context needed).
data NoCtx a

{- | Build a reject transaction for Phase 3
requests, attaching the state and request scripts
to the transaction itself.
-}
rejectRequestsImpl ::
    CageConfig ->
    Provider IO ->
    TokenId ->
    Addr ->
    IO ConwayTx
rejectRequestsImpl cfg prov tid addr =
    rejectRequestsWithRefs cfg prov tid addr []

{- | Build a reject transaction resolving its scripts through reference
outputs when the caller has published them.

The state validator alone is fifteen kilobytes and the request validator
another two and a half, so a reject that carries both inline is 18317
bytes against the protocol's `MaxTxSizeUTxO` of 16384 and the ledger
refuses it before a script runs. Given outputs that carry those scripts,
every purpose resolves through them instead and the transaction carries
neither. An empty list keeps the attaching form, for a caller that has
nothing published.
-}
rejectRequestsWithRefs ::
    CageConfig ->
    Provider IO ->
    TokenId ->
    Addr ->
    -- | Outputs carrying the reject's scripts as reference scripts
    [(TxIn, TxOut ConwayEra)] ->
    IO ConwayTx
rejectRequestsWithRefs cfg prov tid addr refUtxos = do
    (stateUtxo, reqUtxos, feeUtxo, pp) <-
        queryRejectContext cfg prov tid addr
    let (_stateIn, stateOut) = stateUtxo
    let (oldState, newStateOut, script) =
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
                lowerSlot
                refUtxos
    result <-
        Tx.build
            (Tx.mkPParamsBound pp)
            (Tx.InterpretIO (const (pure undefined)))
            evalTx
            (feeUtxo : stateUtxo : reqUtxos)
            refUtxos
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
    -- A published reference output lives in this same wallet. Spending
    -- one to pay the fee would destroy the script the transaction is
    -- resolving through, and collateral must be ada-only besides.
    let spendableUtxos =
            [ u
            | u@(_, o) <- walletUtxos
            , o ^. referenceScriptTxOutL == SNothing
            ]
    feeUtxo <- case sortOn
        (Down . (^. coinTxOutL) . snd)
        spendableUtxos of
        [] -> error "rejectRequests: no UTxOs"
        (u : _) -> pure u
    pure (stateUtxo, reqUtxos, feeUtxo, pp)

-- | Extract state, build new state output.
prepareRejectState ::
    CageConfig ->
    TxOut ConwayEra ->
    (OnChainTokenState, TxOut ConwayEra, Script ConwayEra)
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
     in (oldState, newStateOut, script)

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
    SlotNo ->
    [(TxIn, TxOut ConwayEra)] ->
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
    lowerSlot
    refUtxos = do
        let stateRef = txInToRef stateIn
            OnChainTokenState
                { stateMaxFee = tipAmount
                } = oldState
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
        Coin _fee <- Tx.peek $ \tx ->
            let f = tx ^. bodyTxL . feeTxBodyL
             in if f > Coin 0
                    then Tx.Ok f
                    else Tx.Iterate f
        -- Rejected rows refund exactly `input − tip` floored at min-UTxO
        -- (NOTE-014 item A2) via the single shared helper — no fee share.
        let refundOuts =
                map
                    ( \(_, reqOut) ->
                        computeRefund pp (network cfg) tipAmount reqOut
                    )
                    reqUtxos
        mapM_ Tx.output refundOuts
        -- #157 C10: the pinned consumer and its mandatory withdrawal are
        -- gone. Every rule it re-walked beside the fold — request value
        -- coverage, the mint binding — is the cage's own now, checked
        -- once from the transaction's own evidence.
        if null refUtxos
            then do
                Tx.attachScript script
                Tx.attachScript requestScript
            else mapM_ (Tx.reference . fst) refUtxos
        Tx.collateral (fst feeUtxo)
        Tx.validFrom lowerSlot
