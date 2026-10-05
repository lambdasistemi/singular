{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Registry.TxBuilder.Reject
Description : Reject transaction for a registry's pending requests
License     : Apache-2.0

Builds a reject transaction that consumes every pending request of the
registry, in any window: a reject carries no admission (Lean
@exitAdmission .reject = none@, #320). The folder keeps the tip and
refunds the remaining ADA to the request owners. The trie root does
NOT change.
-}
module Singular.Registry.TxBuilder.Reject
    ( rejectRequestsImpl
    , rejectRequestsWithRefs
    ) where

import Control.Monad (when)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Void (Void)
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Alonzo.Scripts (AsIx)
import Cardano.Ledger.Api.Tx
    ( bodyTxL
    )
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , coinTxOutL
    , datumTxOutL
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Conway.Scripts
    ( ConwayPlutusPurpose
    )
import Cardano.Ledger.Core (Script)
import Cardano.Ledger.Plutus.ExUnits (ExUnits)

import Cardano.Slotting.Slot (SlotNo)
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Config
    ( CageConfig (..)
    )
import Singular.Registry.Ledger
    ( Coin (..)
    , ConwayEra
    , PParams
    , TokenId
    , TxIn
    )
import Singular.Registry.Provider
    ( ChainPoint (..)
    , View (..)
    )
import Singular.Registry.TxBuilder.Internal.Identity
import Singular.Registry.TxBuilder.Internal.Lookup
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainTokenState (..)
    , RequestAction (..)
    , UpdateRedeemer (..)
    )

-- | Empty query generalized algebraic data type (no context needed).
data NoCtx a

{- | Build a reject transaction for every pending request
of the registry, attaching the state and request scripts
to the transaction itself.
-}
rejectRequestsImpl
    :: CageConfig
    -> View IO
    -> TokenId
    -> Addr
    -> IO ConwayTx
rejectRequestsImpl cfg view tid addr =
    rejectRequestsWithRefs cfg view tid addr []

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
rejectRequestsWithRefs
    :: CageConfig
    -> View IO
    -> TokenId
    -> Addr
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ Outputs carrying the reject's scripts as reference scripts
    -> IO ConwayTx
rejectRequestsWithRefs cfg view tid addr refUtxos = do
    (stateUtxo, reqUtxos, feeUtxo, pp) <-
        queryRejectContext cfg view tid addr
    let (_stateIn, stateOut) = stateUtxo
    let (oldState, newStateOut, script) =
            prepareRejectState cfg stateOut
        requestScript = mkRequestScript cfg tid
    (lowerSlot, upperSlot) <- rejectValidity view
    let evalTx = mkRejectEvalTx view
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
                upperSlot
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

{- | Query cage UTxOs, find state, select every pending
request of the registry, pick fee UTxO. A request is
pending when it sits at the registry's request address
with a request datum naming this registry's token; no
window selects among them.
-}
queryRejectContext
    :: CageConfig
    -> View IO
    -> TokenId
    -> Addr
    -> IO
        ( (TxIn, TxOut ConwayEra)
        , [(TxIn, TxOut ConwayEra)]
        , (TxIn, TxOut ConwayEra)
        , PParams ConwayEra
        )
queryRejectContext cfg view tid addr = do
    let stateAddr =
            cageAddrFromCfg cfg (network cfg)
        reqAddr =
            requestAddrFromCfg cfg tid (network cfg)
    stateUtxos <- viewUTxOsAt view stateAddr
    requestUtxos <- viewUTxOsAt view reqAddr
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
    let reqUtxos =
            sortOn fst $
                findRequestUtxos tid requestUtxos
    when (null reqUtxos) $
        error
            "rejectRequests: no pending \
            \requests"
    let pp = viewProtocolParams view
    walletUtxos <- viewUTxOsAt view addr
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
prepareRejectState
    :: CageConfig
    -> TxOut ConwayEra
    -> (OnChainTokenState, TxOut ConwayEra, Script ConwayEra)
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
    in  (oldState, newStateOut, script)

{- | The reject's validity starts at its acquired view's tip. The clock
chooses only the upper bound, with shorter horizons tried as needed.
Keep that bound after the tip even when the clock is behind it. No
request deadline selects the interval: a reject is admitted in every window.
-}
rejectValidity :: View IO -> IO (SlotNo, SlotNo)
rejectValidity view = do
    now <- currentPosixMs
    let lowerSlot = cpSlot (viewPoint view)
    upperSlot <-
        tryUpperSlots view $
            map
                (now +)
                [120_000, 60_000, 30_000, 10_000, 5_000, 2_000, 1_000]
    pure (lowerSlot, max (lowerSlot + 1) upperSlot)

-- | Wrap the Provider's viewEvaluateTx for the story language.
mkRejectEvalTx
    :: View IO
    -> ConwayTx
    -> IO
        ( Map.Map
            (ConwayPlutusPurpose AsIx ConwayEra)
            (Either String ExUnits)
        )
mkRejectEvalTx view tx = do
    r <- viewEvaluateTx view tx
    pure $
        Map.map
            ( \case
                Left e -> Left (show e)
                Right eu -> Right eu
            )
            r

-- | The TxBuild story language program for a reject tx.
buildRejectProgram
    :: CageConfig
    -> PParams ConwayEra
    -> TxIn
    -> [(TxIn, TxOut ConwayEra)]
    -> (TxIn, TxOut ConwayEra)
    -> OnChainTokenState
    -> TxOut ConwayEra
    -> Script ConwayEra
    -> Script ConwayEra
    -> SlotNo
    -> SlotNo
    -> [(TxIn, TxOut ConwayEra)]
    -> Tx.TxBuild NoCtx Void ()
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
    upperSlot
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
            in  if f > Coin 0
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
        -- #157 removed-consumer-encoding: the pinned consumer and its mandatory withdrawal are
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
        Tx.validTo upperSlot
