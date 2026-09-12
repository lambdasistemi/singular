{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}

{- |
Module      : Cardano.MPFS.Cage.TxBuilder.ConnectedFold
Description : Permissionless connected fold with attached actions
License     : Apache-2.0

One transaction binding the full insert journey: the registry state
UTxO spent through @Modify@ with trie proofs, every MPFS request
consumed with @Contribute@, plus caller-attached spends (naming claims),
mints (approvals, representatives) and outputs (naming records). No
owner signature anywhere — the #79 permissionless repair made @Modify@
owner-free, and this builder never asks for one.

This is the single canonical permissionless-fold implementation for
issue #77's runners (register, recovery, retirement). Its lineage is
@offchain/journey/repair/Main.hs@'s @foldRequestsTx@ \/
@buildPermissionlessProgram@ (issue #79, frozen): the MPFS program,
proof computation, upper-slot rule and refund rule are transcribed from
there, extended with the attached naming actions. The repair runner
keeps its own copy; nothing here changes it.
-}
module Cardano.MPFS.Cage.TxBuilder.ConnectedFold (
    RawRedeemer (..),
    ConnectedSpend (..),
    ConnectedMint (..),
    ConnectedFoldArgs (..),
    connectedFoldTx,
    syncFoldedRequests,
) where

import Control.Exception (SomeException, try)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Void (Void)
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (bodyTxL, witsTxL)
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.Api.Tx.Body (feeTxBodyL)
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    datumTxOutL,
    mkBasicTxOut,
    valueTxOutL,
 )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (Script)
import Cardano.Ledger.Keys (KeyHash, KeyRole (..))
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.Mary.Value (AssetName, PolicyID)
import Cardano.Slotting.Slot (SlotNo)
import PlutusTx.Builtins.Internal (BuiltinData (..))
import PlutusTx.IsData.Class (ToData (..))

import Cardano.MPFS.Cage.Config (CageConfig (..))
import Cardano.MPFS.Cage.Ledger (
    ConwayEra,
    PParams,
    Root (..),
    TokenId,
    TxIn,
 )
import Cardano.MPFS.Cage.Provider (Provider (..))
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
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)

-- | A raw Plutus-data redeemer for attached (non-MPFS) purposes.
newtype RawRedeemer = RawRedeemer PLC.Data
    deriving stock (Eq, Show)

instance ToData RawRedeemer where
    toBuiltinData (RawRedeemer d) = BuiltinData d

-- | An attached script spend (a naming claim).
data ConnectedSpend = ConnectedSpend
    { csUtxo :: (TxIn, TxOut ConwayEra)
    , csRedeemer :: RawRedeemer
    , csScript :: Script ConwayEra
    }

-- | An attached mint or burn under a caller script.
data ConnectedMint = ConnectedMint
    { cmPolicy :: PolicyID
    , cmAssets :: Map.Map AssetName Integer
    , cmRedeemer :: RawRedeemer
    , cmScript :: Script ConwayEra
    }

-- | Everything one connected fold binds.
data ConnectedFoldArgs = ConnectedFoldArgs
    { cfaCfg :: CageConfig
    , cfaProvider :: Provider IO
    , cfaTrie :: TrieManager IO
    , cfaToken :: TokenId
    , cfaFeeAddr :: Addr
    , cfaStateUtxo :: (TxIn, TxOut ConwayEra)
    , cfaReqUtxos :: [(TxIn, TxOut ConwayEra)]
    , cfaFeeUtxo :: (TxIn, TxOut ConwayEra)
    , cfaPp :: PParams ConwayEra
    , cfaSpends :: [ConnectedSpend]
    , cfaMints :: [ConnectedMint]
    , cfaOutputs :: [TxOut ConwayEra]
    , cfaSigners :: [KeyHash Guard]
    , cfaRefUtxos :: [(TxIn, TxOut ConwayEra)]
    , cfaAttachScripts :: [Script ConwayEra]
    -- | Skip local script evaluation, stating generous budgets instead,
    -- so the LEDGER executes every purpose for real. Adversarial use
    -- only: the duplicate fold must be refused on-chain (attributed to
    -- the refusing script) rather than at local estimation.
    , cfaSkipEval :: Bool
    , cfaAdjustRoot :: Root -> Root
    }

-- | Build the connected fold transaction (unsigned), returning the
-- computed new root the state continuation carries.
connectedFoldTx :: ConnectedFoldArgs -> IO (ConwayTx, Root)
connectedFoldTx args = do
    let cfg = cfaCfg args
        prov = cfaProvider args
        tm = cfaTrie args
        tid = cfaToken args
        feeAddr = cfaFeeAddr args
        (stateIn, stateOut) = cfaStateUtxo args
        reqUtxos = cfaReqUtxos args
        feeUtxo = cfaFeeUtxo args
        pp = cfaPp args
    (proofs, newRoot) <- computeProofs tm tid reqUtxos
    let adjustedRoot = cfaAdjustRoot args newRoot
        (oldState, newStateOut, script) =
            prepareState cfg stateOut adjustedRoot
        requestScript = mkRequestScript cfg tid
    upperSlot <- computeUpperSlot prov oldState reqUtxos
    let evalTx
            | cfaSkipEval args = \tx -> do
                let Redeemers rdmrs = tx ^. witsTxL . rdmrsTxWitsL
                pure (Map.map (const (Right generousUnits)) rdmrs)
            | otherwise = \tx -> do
                r <- evaluateTx prov tx
                pure $
                    Map.map
                        ( \case
                            Left e -> Left (show e)
                            Right eu -> Right eu
                        )
                        r
        prog =
            buildProgram
                cfg
                stateIn
                reqUtxos
                feeUtxo
                oldState
                newStateOut
                script
                requestScript
                proofs
                upperSlot
                (cfaSpends args)
                (cfaMints args)
                (cfaOutputs args)
                (cfaSigners args)
                (cfaRefUtxos args)
                (cfaAttachScripts args)
        spendUtxos = map csUtxo (cfaSpends args)
    result <-
        Tx.build
            (Tx.mkPParamsBound pp)
            (Tx.InterpretIO (const (pure undefined)))
            evalTx
            (feeUtxo : cfaStateUtxo args : reqUtxos ++ spendUtxos)
            (cfaRefUtxos args)
            feeAddr
            (prog :: Tx.TxBuild NoCtx Void ())
    case result of
        Right tx -> pure (tx, newRoot)
        Left err -> error ("connectedFold: build failed: " <> show err)

-- | Generous per-purpose budget stated when local evaluation is
-- skipped (adversarial path only); the ledger re-executes for real.
generousUnits :: ExUnits
generousUnits = ExUnits 3_000_000 200_000_000

-- | Empty query GADT (no context needed).
data NoCtx a

-- | Run speculative trie operations to compute proofs and the new root.
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

-- | Process a single MPFS request through the speculative trie.
processRequest ::
    (Monad m) =>
    Trie m ->
    (TxIn, TxOut ConwayEra) ->
    m [ProofStep]
processRequest trie (_txIn, txOut) = do
    let req = case extractCageDatum txOut of
            Just (RequestDatum r) -> r
            _ -> error "connectedFold: invalid request datum"
    case requestValue req of
        OpInsert v -> do
            _ <- insert trie (requestKey req) v
            mSteps <- getProofSteps trie (requestKey req)
            pure (fromMaybe [] mSteps)
        OpDelete _ -> do
            mSteps <- getProofSteps trie (requestKey req)
            _ <- Cardano.MPFS.Cage.Trie.delete trie (requestKey req)
            pure (fromMaybe [] mSteps)
        OpUpdate _ v -> do
            mSteps <- getProofSteps trie (requestKey req)
            _ <- Cardano.MPFS.Cage.Trie.delete trie (requestKey req)
            _ <- insert trie (requestKey req) v
            pure (fromMaybe [] mSteps)

-- | Extract old state, build the new state output and the cage script.
prepareState ::
    CageConfig ->
    TxOut ConwayEra ->
    Root ->
    (OnChainTokenState, TxOut ConwayEra, Script ConwayEra)
prepareState cfg stateOut newRoot =
    let scriptAddr = cageAddrFromCfg cfg (network cfg)
        oldState = case extractCageDatum stateOut of
            Just (StateDatum s) -> s
            _ -> error "connectedFold: invalid state datum"
        newStateDatum =
            StateDatum oldState{stateRoot = OnChainRoot (unRoot newRoot)}
        newStateOut =
            mkBasicTxOut
                scriptAddr
                (stateOut ^. valueTxOutL)
                & datumTxOutL .~ mkInlineDatum (toPlcData newStateDatum)
        script = mkCageScript cfg
     in (oldState, newStateOut, script)

-- | Compute the validity upper slot from the earliest request deadline.
computeUpperSlot ::
    Provider IO ->
    OnChainTokenState ->
    [(TxIn, TxOut ConwayEra)] ->
    IO SlotNo
computeUpperSlot prov oldState reqUtxos = do
    let extractSubmittedAt (_, rOut) = case extractCageDatum rOut of
            Just (RequestDatum r) -> requestSubmittedAt r
            _ -> 0
        earliestDeadline =
            minimum $
                map
                    (\u -> extractSubmittedAt u + stateProcessTime oldState)
                    reqUtxos
    mUpperSlot <-
        try (posixMsToSlot prov earliestDeadline) :: IO (Either SomeException SlotNo)
    case mUpperSlot of
        Right s -> pure s
        Left _ -> do
            nowUtc <- getCurrentTime
            let posixSec = utcTimeToPOSIXSeconds nowUtc
            trySlots prov $
                map
                    (\d -> round ((posixSec + d) * 1000))
                    [30, 5, 2]

-- | The TxBuild program: MPFS spends, attached spends and mints,
-- outputs, witnesses. Processed requests lock into the state output
-- (see `prepareState`); no refund outputs are emitted here because
-- connected folds only ever process (`Update`); rejected rows are built
-- by the reject path with `computeRefund`. No owner signature.
buildProgram ::
    CageConfig ->
    TxIn ->
    [(TxIn, TxOut ConwayEra)] ->
    (TxIn, TxOut ConwayEra) ->
    OnChainTokenState ->
    TxOut ConwayEra ->
    Script ConwayEra ->
    Script ConwayEra ->
    [[ProofStep]] ->
    SlotNo ->
    [ConnectedSpend] ->
    [ConnectedMint] ->
    [TxOut ConwayEra] ->
    [KeyHash Guard] ->
    [(TxIn, TxOut ConwayEra)] ->
    [Script ConwayEra] ->
    Tx.TxBuild NoCtx Void ()
buildProgram
    _cfg
    stateIn
    reqUtxos
    feeUtxo
    _oldState
    newStateOut
    script
    requestScript
    proofs
    upperSlot
    extraSpends
    extraMints
    extraOutputs
    extraSigners
    refUtxos
    attachScripts = do
        let stateRef = txInToRef stateIn
            actions = map Update proofs
        _ <- Tx.spendScript stateIn (Modify actions)
        mapM_
            (\(rIn, _) -> Tx.spendScript rIn (Contribute stateRef))
            reqUtxos
        mapM_
            (\sp -> Tx.spendScript (fst (csUtxo sp)) (csRedeemer sp))
            extraSpends
        mapM_
            (\m -> Tx.mint (cmPolicy m) (cmAssets m) (cmRedeemer m))
            extraMints
        _ <- Tx.output newStateOut
        Coin _fee <- Tx.peek $ \tx ->
            let f = tx ^. bodyTxL . feeTxBodyL
             in if f > Coin 0 then Tx.Ok f else Tx.Iterate f
        mapM_ Tx.output extraOutputs
        -- Scripts arrive by witness or by reference, never both: with
        -- reference UTxOs every purpose resolves through them (connected
        -- folds carry four scripts and would otherwise breach the max tx
        -- size); without, every script is attached (small transactions).
        if null refUtxos
            then do
                Tx.attachScript script
                Tx.attachScript requestScript
                mapM_ (Tx.attachScript . csScript) extraSpends
                mapM_ (Tx.attachScript . cmScript) extraMints
            else mapM_ (Tx.reference . fst) refUtxos
        -- Fault hook: scripts attached unconditionally (e.g. a tampered
        -- mint script no reference output carries). Empty in honest folds.
        mapM_ Tx.attachScript attachScripts
        mapM_ Tx.requireSignature extraSigners
        Tx.collateral (fst feeUtxo)
        Tx.validTo upperSlot
-- | Replay accepted fold inputs into the manager's persistent trie so
-- later proof computations start from the chain's root. Call only with
-- inputs the ledger accepted, in fold order.
syncFoldedRequests ::
    TrieManager IO ->
    TokenId ->
    [(TxIn, TxOut ConwayEra)] ->
    IO ()
syncFoldedRequests tm tok reqUtxos =
    withTrie tm tok $ \trie -> mapM_ (processRequest trie) reqUtxos
