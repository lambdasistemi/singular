{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}

{- |
Module      : Cardano.MPFS.Cage.TxBuilder.Update
Description : Update token transaction
License     : Apache-2.0

Builds the oracle update transaction that processes
all pending requests for a token. Consumes the State
UTxO and all request UTxOs, applies each operation
speculatively through the trie to generate proofs,
then outputs a new State UTxO with the updated root
and per-request refund outputs.
-}
module Cardano.MPFS.Cage.TxBuilder.Update (
    updateTokenImpl,
) where

import Control.Exception (SomeException, try)
import Control.Monad (when)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..))
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (
    utcTimeToPOSIXSeconds,
 )
import Data.Void (Void)
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Address (
    AccountAddress (..),
    AccountId (..),
    Addr,
 )
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
    valueTxOutL,
 )
import Cardano.Ledger.BaseTypes (
    Inject (..),
 )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway.Scripts (
    ConwayPlutusPurpose,
 )
import Cardano.Ledger.Core (Script)
import Cardano.Ledger.Credential (
    Credential (ScriptHashObj),
 )
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
    ConwayEra,
    PParams,
    Root (..),
    TokenId,
    TxIn,
 )
import Cardano.MPFS.Cage.Provider (
    Provider (..),
 )
import Cardano.MPFS.Cage.Trie (
    Trie (..),
    TrieManager (..),
 )
import Cardano.MPFS.Cage.TxBuilder.Internal
import Cardano.MPFS.Cage.Types (
    CageDatum (..),
    OnChainOperation (..),
    OnChainRequest (..),
    OnChainRoot (..),
    OnChainTokenState (..),
    ProofStep,
    RequestAction (..),
    UpdateRedeemer (..),
 )
import Cardano.Slotting.Slot (SlotNo)
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)

-- | Empty query GADT (no context needed).
data NoCtx a

-- | Build an update-token transaction (fair fee).
updateTokenImpl ::
    CageConfig ->
    Provider IO ->
    TrieManager IO ->
    TokenId ->
    Addr ->
    IO ConwayTx
updateTokenImpl cfg prov tm tid addr = do
    (stateUtxo, reqUtxos, feeUtxo, pp) <-
        queryContext cfg prov tid addr
    let (stateIn, stateOut) = stateUtxo
    (proofs, newRoot) <-
        computeProofs tm tid reqUtxos
    let (oldState, newStateOut, script, ownerKh) =
            prepareState
                cfg
                stateOut
                newRoot
        requestScript = mkRequestScript cfg tid
    upperSlot <-
        computeUpperSlot prov oldState reqUtxos
    let evalTx = mkEvalTx prov
        prog =
            buildProgram
                cfg
                pp
                stateIn
                stateOut
                reqUtxos
                feeUtxo
                oldState
                newStateOut
                script
                requestScript
                ownerKh
                proofs
                upperSlot
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
                "updateToken: build failed: "
                    <> show err

{- | Query cage UTxOs, find the state and request
UTxOs, pick a fee-paying wallet UTxO.
-}
queryContext ::
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
queryContext cfg prov tid addr = do
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
                "updateToken: state UTxO \
                \not found"
        Just x -> pure x
    let reqUtxos =
            sortOn fst $
                findRequestUtxos tid requestUtxos
    when (null reqUtxos) $
        error "updateToken: no pending requests"
    pp <- queryProtocolParams prov
    walletUtxos <- queryUTxOs prov addr
    feeUtxo <- case sortOn
        (Down . (^. coinTxOutL) . snd)
        walletUtxos of
        [] -> error "updateToken: no UTxOs"
        (u : _) -> pure u
    pure (stateUtxo, reqUtxos, feeUtxo, pp)

{- | Run speculative trie operations to compute
proofs and the new root hash.
-}
computeProofs ::
    TrieManager IO ->
    TokenId ->
    [(TxIn, TxOut ConwayEra)] ->
    IO ([[ProofStep]], Root)
computeProofs tm tid reqUtxos =
    withSpeculativeTrie tm tid $ \trie -> do
        ps <- mapM (processRequest trie) reqUtxos
        r <- getRoot trie
        pure (ps, r)

{- | Extract old state, build new state output,
cage script, and owner key hash.
-}
prepareState ::
    CageConfig ->
    TxOut ConwayEra ->
    Root ->
    ( OnChainTokenState
    , TxOut ConwayEra
    , Script ConwayEra
    , KeyHash Guard
    )
prepareState cfg stateOut newRoot =
    let scriptAddr =
            cageAddrFromCfg cfg (network cfg)
        oldState =
            case extractCageDatum stateOut of
                Just (StateDatum s) -> s
                _ ->
                    error
                        "updateToken: invalid \
                        \state datum"
        OnChainTokenState
            { stateOwner =
                BuiltinByteString ownerBs
            } = oldState
        newStateDatum =
            StateDatum
                oldState
                    { stateRoot =
                        OnChainRoot
                            (unRoot newRoot)
                    }
        newStateOut =
            mkBasicTxOut
                scriptAddr
                (stateOut ^. valueTxOutL)
                & datumTxOutL
                    .~ mkInlineDatum
                        (toPlcData newStateDatum)
        script = mkCageScript cfg
        ownerKh = addrWitnessKeyHash ownerBs
     in (oldState, newStateOut, script, ownerKh)

-- | Compute the validity upper slot.
computeUpperSlot ::
    Provider IO ->
    OnChainTokenState ->
    [(TxIn, TxOut ConwayEra)] ->
    IO SlotNo
computeUpperSlot prov oldState reqUtxos = do
    let extractSubmittedAt (_, rOut) =
            case extractCageDatum rOut of
                Just (RequestDatum r) ->
                    requestSubmittedAt r
                _ -> 0
        earliestDeadline =
            minimum $
                map
                    ( \u ->
                        extractSubmittedAt u
                            + stateProcessTime
                                oldState
                    )
                    reqUtxos
    mUpperSlot <-
        try @SomeException
            (posixMsToSlot prov earliestDeadline)
    case mUpperSlot of
        Right s -> pure s
        Left _ -> do
            nowUtc <- getCurrentTime
            let posixSec =
                    utcTimeToPOSIXSeconds nowUtc
            trySlots prov $
                map
                    ( \d ->
                        round
                            ((posixSec + d) * 1000)
                    )
                    [30, 5, 2]

-- | Wrap the Provider's evaluateTx for the DSL.
mkEvalTx ::
    Provider IO ->
    ConwayTx ->
    IO
        ( Map.Map
            ( ConwayPlutusPurpose
                AsIx
                ConwayEra
            )
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

-- | The TxBuild DSL program for an update tx.
buildProgram ::
    CageConfig ->
    PParams ConwayEra ->
    TxIn ->
    TxOut ConwayEra ->
    [(TxIn, TxOut ConwayEra)] ->
    (TxIn, TxOut ConwayEra) ->
    OnChainTokenState ->
    TxOut ConwayEra ->
    Script ConwayEra ->
    Script ConwayEra ->
    KeyHash Guard ->
    [[ProofStep]] ->
    SlotNo ->
    Tx.TxBuild NoCtx Void ()
buildProgram
    cfg
    _pp
    stateIn
    _stateOut
    reqUtxos
    feeUtxo
    oldState
    newStateOut
    script
    requestScript
    ownerKh
    proofs
    upperSlot = do
        let stateRef = txInToRef stateIn
            OnChainTokenState
                { stateMaxFee = tipAmount
                } = oldState
            nReqs =
                fromIntegral (length reqUtxos) ::
                    Integer
        let actions = map Update proofs
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
            remainder = fee - perReqFee * nReqs
        mapM_
            ( \(i, (_, reqOut)) -> do
                let Coin reqVal =
                        reqOut ^. coinTxOutL
                    extra =
                        if i == (0 :: Int)
                            then remainder
                            else 0
                    rawRefund =
                        Coin
                            ( reqVal
                                - tipAmount
                                - perReqFee
                                - extra
                            )
                    refundAddr =
                        addrFromKeyHashBytes
                            (network cfg)
                            ( extractOwnerBytes
                                reqOut
                            )
                Tx.output $
                    mkBasicTxOut
                        refundAddr
                        (inject rawRefund)
            )
            (zip [0 ..] reqUtxos)
        Tx.attachScript script
        Tx.attachScript requestScript
        Tx.requireSignature ownerKh
        Tx.collateral (fst feeUtxo)
        Tx.validTo upperSlot
        case cfgStakeScript cfg of
            Nothing -> pure ()
            Just (stakeBytes, stakeHash) -> do
                let stakeScript =
                        scriptFromBytes
                            "updateToken.stakeScript"
                            stakeBytes
                    rewardAcct =
                        AccountAddress
                            (network cfg)
                            (AccountId (ScriptHashObj stakeHash))
                Tx.withdrawScript rewardAcct (Coin 0) (0 :: Integer)
                Tx.attachScript stakeScript

-- | Process a single request.
processRequest ::
    (Monad m) =>
    Trie m ->
    (TxIn, TxOut ConwayEra) ->
    m [ProofStep]
processRequest trie (_txIn, txOut) = do
    let OnChainRequest
            { requestKey = key
            , requestValue = op
            } = case extractCageDatum txOut of
                Just (RequestDatum r) -> r
                _ ->
                    error
                        "processRequest: \
                        \invalid request datum"
    case op of
        OpInsert v -> do
            _ <- insert trie key v
            mSteps <- getProofSteps trie key
            pure (fromMaybe [] mSteps)
        OpDelete _ -> do
            mSteps <- getProofSteps trie key
            _ <-
                Cardano.MPFS.Cage.Trie.delete
                    trie
                    key
            pure (fromMaybe [] mSteps)
        OpUpdate _ v -> do
            mSteps <- getProofSteps trie key
            _ <-
                Cardano.MPFS.Cage.Trie.delete
                    trie
                    key
            _ <- insert trie key v
            pure (fromMaybe [] mSteps)
