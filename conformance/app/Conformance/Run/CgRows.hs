{- |
Module      : Conformance.Run.CgRows
Description : Split out of Conformance.Run (#263); see that module's header
License     : Apache-2.0
-}
module Conformance.Run.CgRows (runCG02, runCG03, runCG04, runCG05, controlFreshCage, sleepUntilMs, runCG07, runCG09, runCG10, runCG11, runCG12, runCG14, runCG15, runCG19, runCG19RejectedFloor, runCG21, runCG22, runSequence, ensurePresentV3, setupDelete, capturePreProofKey, waitPhase3, claimValue, seedDeleteKey, ensurePresentV1) where

import Conformance.Run.Control
import Conformance.Run.Live
import Conformance.Run.Receipts
import Conformance.Run.Fold
import Conformance.Run.Book
import Conformance.Run.Units
import Conformance.Run.Cage
import Conformance.Run.Wallet
import Conformance.Run.Submit
import Conformance.Run.Environment
import Conformance.Run.Observe

import Conformance.Story.Live qualified as Live
import Conformance.Edge.Register qualified as RegistrationStory
import Conformance.Edge.Retire qualified as RetirementStory
import Conformance.Edge.Sequence qualified as SequenceStory
import Control.Concurrent (threadDelay)
import Control.Exception (
    SomeException,
    displayException,
    try,
 )
import Control.Monad (when)
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson (
    Value (..),
    encode,
    object,
    (.=),
 )
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((&), (.~), (^.))
import System.Environment (lookupEnv)
import System.FilePath ((</>))

import Cardano.Ledger.Address (
    AccountAddress (..),
    AccountId (..),
 )
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))

import Cardano.Ledger.Api.Tx (
    bodyTxL,
    estimateMinFeeTx,
    mkBasicTx,
    mkBasicTxBody,
    witsTxL,
 )
import Cardano.Ledger.Api.Tx.Body (
    ValidityInterval (..),
    collateralInputsTxBodyL,
    feeTxBodyL,
    inputsTxBodyL,
    outputsTxBodyL,
    referenceInputsTxBodyL,
    reqSignerHashesTxBodyL,
    scriptIntegrityHashTxBodyL,
    vldtTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    coinTxOutL,
    datumTxOutL,
    getMinCoinTxOut,
    mkBasicTxOut,
 )
import Cardano.Ledger.Api.Tx.Wits (
    Redeemers (..),
    rdmrsTxWitsL,
    scriptTxWitsL,
 )
import Cardano.Ledger.BaseTypes (
    Network (..),
    StrictMaybe (..),
 )
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import MPF.Hashes (MPFHash)
import MPF.Proof.Insertion (MPFProof (..))

import Singular.Registry.Blueprint (
    NamingCodes (..),
    applyBytesParam,
    applyDataParam,
 )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (
    AssetName (..),
    Coin (..),
    ConwayEra,
    ExUnits (..),
    Root (..),
    TokenId (..),
 )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Trie (TrieManager (..))
import Singular.Registry.TxBuilder.Boot (bootTokenImpl)
import Singular.Registry.TxBuilder.Internal (
    leafAbsent,
    addrFromKeyHashBytes,
    addrWitnessKeyHash,
    computeScriptIntegrity,
    currentPosixMs,
    extractCageDatum,
    extractOwnerBytes,
    mkCageScript,
    mkRequestScript,
    mkInlineDatum,
    scriptHashBytes,
    scriptFromBytes,
    spendingIndex,
    toLedgerData,
    toPlcData,
    trySlots,
    txInToRef,
 )
import Singular.Registry.TxBuilder.Update (
    RegistryContext (..),
    updateTokenImpl,
    updateTokenWithDuties,
 )
import Singular.Registry.Types (
    CageDatum (..),
    edgeDeleteAbsent,
    edgeInsertAbsent,
    edgeUpdateActive,
    OnChainRequest (..),
    OnChainRoot (..),
    OnChainTokenState (..),
    RequestAction (Update),
    UpdateRedeemer (..),
 )
import Singular.Registry.Types qualified as CageTypes
import Cardano.Node.Client.E2E.Setup (addKeyWitness)
import Cardano.Node.Client.Submitter (SubmitResult (..))
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins.Internal (BuiltinByteString (..))

import Conformance.Mirror (
    emit,
    failWith,
    hex,
    inclusionProofFrom,
    newMirror,
    readChainState,
    require,
    txIdHex,
    verifyAbsentKey,
    verifyPresentValue,
 )
import Conformance.Receipt (
    Outcome (..),
    Verdict (..),
    maxReceiptBytes,
 )
import Conformance.Refusal (
    RefusalRole (..),
    attributeRefusalReceipt,
    refusalScriptHashes,
    trimRefusal,
 )

-- | CG02: Update v1->v2 folds; v2 reads back from the chain.
runCG02 :: Env -> IO ()
runCG02 env = do
    ensurePresentV1 env
    (foldTx, mem, cpu, size) <-
        requestAndFold env "CG02" edgeUpdateActive
    commitTm env edgeUpdateActive
    verifyPresentValue
        (envCfg env)
        (envProv env)
        (envMirror env)
        (envTid env)
        cgKey
        (claimValue env cgV2)
        forgedValue
    writeRowReceipt
        env
        "CG02"
        Accepted
        AgreesWithModel        [txIdHex foldTx]
        Nothing
        Nothing
        (Just mem)
        (Just cpu)
        (Just size)
        "node-submit"
        Nothing
    writeIORef (envKeys env) (True, cgV2)
    emit "row" "CG02: ACCEPTED update v1->v2, v2 reads back from chain"


-- | CG03: Delete folds; the key proves absent from the chain.
runCG03 :: Env -> IO ()
runCG03 env = do
    seedDeleteKey env
    (_, cur) <- readIORef (envDeleteKey env)
    (preProof, preRoot) <- capturePreProofKey env cgDeleteKey
    (foldTx, mem, cpu, size) <-
        requestAndFoldKey env "CG03" cgDeleteKey edgeDeleteAbsent
    commitTmKey env cgDeleteKey edgeDeleteAbsent
    verifyAbsentKey
        (envCfg env)
        (envProv env)
        (envMirror env)
        (envTid env)
        cgDeleteKey
        cur
        preProof
        preRoot
        (envControl env == FalseClaim)
    writeRowReceipt
        env
        "CG03"
        Accepted
        AgreesWithModel        [txIdHex foldTx]
        Nothing
        Nothing
        (Just mem)
        (Just cpu)
        (Just size)
        "node-submit"
        Nothing
    writeIORef (envDeleteKey env) (False, "")
    emit "row" "CG03: ACCEPTED delete, key absent on chain"


-- | CG04: re-Insert v3 folds; v3 reads back from the chain.
runCG04 :: Env -> IO ()
runCG04 env = do
    (present, _) <- readIORef (envDeleteKey env)
    when present $ do
        emit "setup" "delete key present; deleting as setup for re-Insert"
        setupDelete env
    (foldTx, mem, cpu, size) <-
        requestAndFoldKey env "CG04" cgDeleteKey edgeInsertAbsent
    commitTmKey env cgDeleteKey edgeInsertAbsent
    verifyPresentValue
        (envCfg env)
        (envProv env)
        (envMirror env)
        (envTid env)
        cgDeleteKey
        (claimValue env cgV3)
        forgedValue
    writeRowReceipt
        env
        "CG04"
        Accepted
        AgreesWithModel        [txIdHex foldTx]
        Nothing
        Nothing
        (Just mem)
        (Just cpu)
        (Just size)
        "node-submit"
        Nothing
    writeIORef (envDeleteKey env) (True, cgV3)
    emit "row" "CG04: ACCEPTED re-Insert, v3 reads back from chain"


{- | CG05: Insert on the occupied key must be refused, attributed to
the state script in phase 2 — a node verdict on a submitted
transaction, the li-refusals bar. The fold is hand-built (the
library builder cannot emit a transaction whose scripts do not
evaluate) and calibrated against the library builder on every valid
fold, so the refused shape differs from a library fold only in the
operation under test. The executing control is a fresh cage that
accepts a valid insert: a cage that refuses everything would pass
the refusal vacuously.
-}
runCG05 :: Env -> String -> IO ()
runCG05 env marker = do
    ensurePresentV3 env
    let cfg = envCfg env
        prov = envProv env
        tid = envTid env
    -- CG05: padded 5M bond (hook-era fold fees exceed the library
    -- default bond's refund headroom; bond size is irrelevant to
    -- the occupied-key property).
    tidRef05 <- newIORef (Just tid)
    unitsRef05 <- newIORef (0, 0)
    sessionRefs <- sessionRefUtxos env
    let cage05 = RowCage cfg tidRef05 unitsRef05 sessionRefs
    _ <-
        paddedRequest env cage05 genesisAddr genesisSignKey cgKey cgV4 5_000_000
    emit "row" "CG05: occupied insert requested; folding must refuse"
    -- The eval-time observation: genuine evidence about the same
    -- rules, kept as a line, never as the verdict.
    evalNote <-
        try @SomeException
            (updateTokenImpl cfg prov (envTm env) tid genesisAddr)
    case evalNote of
        Left err ->
            -- Genuine evidence about the same rules, whether it comes from
            -- the ledger evaluating the fold or from the builder refusing
            -- to derive duties for an edge that is not one of the seven.
            emit
                "eval-observation"
                (trimRefusal (displayException err))
        Right _ ->
            emit
                "eval-observation"
                "unexpected: the poisoned fold evaluated; submitting anyway"
    handTx <- buildRefusedFold env
    let signed = addKeyWitness genesisSignKey handTx
    result <- submitTxResilient (envSubmit env) signed
    case result of
        Rejected reason ->
            attributeSubmitRefusal
                env
                "CG05"
                AgreesWithModel
                marker
                (T.unpack (TE.decodeUtf8Lenient reason))
                (txIdHex signed)
        Submitted txid ->
            failWith
                ( "CG05 FINDING: the fold accepted an Insert on an \
                  \occupied key (txid "
                    <> txInHex txid
                    <> ") — the contract claims the fold MUST NOT; \
                       \reported, not relabelled"
                )
    controlFreshCage env


-- | The live-cage control: a fresh cage accepts a valid insert.
controlFreshCage :: Env -> IO ()
controlFreshCage env = do
    let cfg0 = envCfg env
        prov = envProv env
    -- Sweep first: carving splits only the largest output, so any small
    -- one left over from the row survives, sits first in the set, and is
    -- what the boot builder picks to fund and collateralise with. After
    -- a sweep the wallet is exactly the carved seed and the funding.
    consolidateFunding env
    seedTxIn <- carveSeed env
    -- #157 D-BOOT: a fresh cage is a fresh registry identity, so its four
    -- pins are derived for ITS seed. Patching only the seed onto the
    -- session.s config would pin the session.s token policies and every
    -- fold of this cage would refuse on the delta.
    let (stateBytes, requestBytes, codes) = envCodes env
        cfg =
            cageCfgWith
                stateBytes
                requestBytes
                codes
                (txInToRef seedTxIn)
                (defaultProcessTime cfg0)
                (defaultRetractTime cfg0)
    unsignedBoot <- bootTokenImpl cfg prov genesisAddr
    signedBoot <- submitWithGenesis (envSubmit env) unsignedBoot
    tid <- extractTokenId cfg signedBoot
    createTrie (envTm env) tid
    -- #157: a valid insert is a booked edge. The control cage is its own
    -- registry — its own token, its own request script and its own three
    -- token policies — so it gets its own reference outputs and its own
    -- approval, and the fold discharges the duties the edge creates.
    --
    -- The references go up FIRST. Publishing five scripts is five awaited
    -- submissions, and a request booked before them would spend its
    -- phase-1 window waiting for them.
    refs <- cageRefUtxos env cfg tid
    dest <- edgeDestination env edgeInsertAbsent
    _ <-
        bookEdge
            env
            cfg
            tid
            genesisAddr
            genesisSignKey
            controlKey
            edgeInsertAbsent
            dest
            []
            (defaultTipCoin cfg + cgDeposit)
    utxos <- cageUtxosOf env cfg
    let registryId =
            scriptHashBytes (cfgScriptHash cfg)
                <> SBS.fromShort (assetNameBytes (unTokenId tid))
        witnessAt kind =
            scriptFromBytes
                ("witness-" <> show kind)
                ( applyBytesParam
                    registryId
                    (applyDataParam (PLC.I kind) (ncWitness codes))
                )
        ctx =
            RegistryContext
                { rcWitnessScripts = Map.fromList [(k, witnessAt k) | k <- [0, 1, 2]]
                , rcCageScript = Just (mkCageScript cfg)
                , rcCageUtxos = utxos
                , rcDatums = [(recordDatumHash, recordDatum)]
                , rcAllowInadmissible = False
                , rcHolderUtxos = []
                , rcRefUtxos = refs
                }
    foldTx <-
        updateTokenWithDuties cfg prov (envTm env) tid genesisAddr ctx
    _ <- submitWithGenesis (envSubmit env) foldTx
    mirror <- newMirror
    verifyPresentValue
        cfg
        prov
        mirror
        tid
        controlKey
        controlVal
        forgedValue
    emit
        "control"
        "CG05 control: fresh cage accepted a valid insert — \
        \the refusal discriminates"


-- | Sleep until the devnet's POSIX-ms clock reaches @targetMs@.
sleepUntilMs :: Env -> Integer -> IO ()
sleepUntilMs _env targetMs = do
    now <- currentPosixMs
    let remaining = targetMs - now
    when (remaining > 0) $ do
        emit "wait" (show remaining <> " ms to the next phase boundary")
        threadDelay (fromIntegral remaining * 1000)


{- | CG07: Retract outside phase 2 (R9_retract_needs_phase2). The
request owner's retract, validity declared inside phase 1, is
refused by the request script; the same retract re-declared inside
phase 2 is accepted (the control that proves the refusal
discriminates). Both verdicts are the node's on submitted
transactions.
-}
runCG07 :: Env -> IO ()
runCG07 env = do
    cage <- ensureRowCage env "cg07" 30_000 60_000
    let cfg = rcCfg cage
        prov = envProv env
    tid <- cageTid cage
    (reqIn, reqOut) <- rowRequestInsert env cage "cg07-key" "cg07-value"
    let (_, submittedAt) = requestDatumOf reqOut
    -- A hand-built phase-2 retract plays the control (the library
    -- builder converts the phase-2 end 60s ahead, past this devnet's
    -- conversion horizon). The refused attempt's units come from the
    -- declared fallback: no valid fold has run in this cage.
    units <- declaredSpec env cage
    (pot, (funderIn, funderOut)) <- collateralPotWithChange env
    (stateIn, _) <- cageStateUtxo env cage
    pp <- Cage.queryProtocolParams prov
    nowMs0 <- currentPosixMs
    upper <- trySlots prov [nowMs0 + 2_000, nowMs0 + 1_500, nowMs0 + 1_000]
    let stateRef = txInToRef stateIn
        script = mkRequestScript cfg tid
        inputs = Set.fromList [reqIn, funderIn]
        ownerKh = addrWitnessKeyHash (extractOwnerBytes reqOut)
        purpose = ConwaySpending (AsIx (spendingIndex reqIn inputs))
        rdmrs =
            Redeemers
                ( Map.singleton
                    purpose
                    (toLedgerData (Retract stateRef), units)
                )
        integrity = computeScriptIntegrity pp rdmrs
    let Coin reqVal = reqOut ^. coinTxOutL
        draft =
            mkBasicTx
                ( mkBasicTxBody
                    & inputsTxBodyL .~ inputs
                    & referenceInputsTxBodyL .~ Set.singleton stateIn
                    & collateralInputsTxBodyL .~ Set.singleton pot
                    & reqSignerHashesTxBodyL .~ Set.singleton ownerKh
                    & vldtTxBodyL
                        .~ ValidityInterval SNothing (SJust upper)
                    & scriptIntegrityHashTxBodyL .~ integrity
                )
                & witsTxL . scriptTxWitsL
                    .~ Map.singleton (hashScript script) script
                & witsTxL . rdmrsTxWitsL .~ rdmrs
        Coin estFee = estimateMinFeeTx pp draft 1 0 0
        fee = estFee + 50_000
        refundCoin = reqVal
        Coin funding = funderOut ^. coinTxOutL
        changeOut = mkBasicTxOut genesisAddr (MaryValue (Coin (funding - fee)) mempty)
        -- A retracted booking is not folded, so the approval that
        -- certified its edge comes back with the deposit.
        refundOut =
            mkBasicTxOut
                (addrFromKeyHashBytes (network cfg) (extractOwnerBytes reqOut))
                (MaryValue (Coin refundCoin) (MultiAsset (rawAssets reqOut)))
                & datumTxOutL .~ mkInlineDatum (toPlcData (txInToRef reqIn))
        Coin minAda = getMinCoinTxOut @ConwayEra pp refundOut
    require
        "CG07 hand retract: refund under min-ADA"
        (refundCoin >= minAda)
    let handTx =
            draft
                & bodyTxL . feeTxBodyL .~ Coin fee
                & bodyTxL . outputsTxBodyL .~ StrictSeq.fromList [refundOut, changeOut]
    emit
        "row"
        ( "CG07: retract with validity inside phase 1 submitted; the \
           \request script must refuse (R9_retract_needs_phase2)"
        )
    submitExpectRefused env "CG07" AgreesWithModel (requestMarkerOf cfg tid) handTx
    -- Control: the same request retracted with validity INSIDE phase
    -- 2, built only once the boundary is near so every slot
    -- conversion stays inside the interpreter's horizon.
    sleepUntilMs env (submittedAt + 30_000 + 500)
    lower <- Cage.posixMsCeilSlot prov (submittedAt + 30_000)
    nowMs1 <- currentPosixMs
    upperCtrl <- trySlots prov [nowMs1 + 2_000, nowMs1 + 1_500, nowMs1 + 1_000]
    let ctrlTx =
            handTx
                & bodyTxL . vldtTxBodyL
                    .~ ValidityInterval (SJust lower) (SJust upperCtrl)
    _ <- submitExpectAccepted env (addKeyWitness genesisSignKey ctrlTx)
    emit
        "control"
        "CG07 control: the same retract, validity in phase 2, is \
         \accepted — the refusal discriminates"


{- | CG09: @Rejected@ when not rejectable (R9_reject_needs_rejectable).
Inside the process window the request still contributes (phase 1),
but the fold's Rejected action fails @is_rejectable@ in the state
script: a request is only rejectable once its retract window has
passed. The control folds the same request in phase 3, where the
library's reject is accepted.
-}
runCG09 :: Env -> IO ()
runCG09 env = do
    cage <- ensureRowCage env "cg09" 30_000 5_000
    let cfg = rcCfg cage
        prov = envProv env
    tid <- cageTid cage
    (reqIn, reqOut) <- rowRequestInsert env cage "cg09-key" "cg09-value"
    let (_, submittedAt) = requestDatumOf reqOut
    units <- pure (ExUnits 1_400_000 100_000_000)
    pot <- collateralPot env
    state <- cageStateUtxo env cage
    oldState <- extractState (snd state)
    nowMs <- currentPosixMs
    upper <- trySlots prov [nowMs + 2_000, nowMs + 1_500, nowMs + 1_000]
    let spec =
            (rowSpec
                cage
                tid
                state
                [(reqIn, reqOut)]
                [CageTypes.Rejected]
                (Root (unOnChainRoot (stateRoot oldState)))
                units)
                { fsUpper = Just upper
                , fsCollateral = Just pot
                }
    hand <- assembleFoldWithFee env spec
    emit
        "row"
        ( "CG09: Rejected action while the request is still inside its \
           \process window; the state script must refuse "
            <> "(R9_reject_needs_rejectable)"
        )
    submitExpectRefused env "CG09" AgreesWithModel (stateMarkerOf cfg) hand
    -- Control: the SAME request and the SAME Rejected action, rebuilt
    -- with phase-3 bounds once the retract window has passed. The hand
    -- model is used rather than the library reject for the reason CG07
    -- already uses it: the library attaches the state validator, and
    -- fifteen kilobytes of it does not fit in a transaction.
    sleepUntilMs env (submittedAt + 30_000 + 5_000 + 500)
    nowCtrl <- currentPosixMs
    -- The lower bound must fall AFTER the retract window closes, or the
    -- request script reads the fold as neither phase 1 nor rejectable.
    lower <-
        trySlots
            prov
            [ submittedAt + 30_000 + 5_000 + 400
            , submittedAt + 30_000 + 5_000 + 200
            , submittedAt + 30_000 + 5_000 + 100
            ]
    upperCtrl <- trySlots prov [nowCtrl + 2_000, nowCtrl + 1_500, nowCtrl + 1_000]
    let Coin reqVal = reqOut ^. coinTxOutL
        ctrlSpec =
            spec
                { fsLower = Just lower
                , fsUpper = Just upperCtrl
                , fsCollateral = Nothing
                , -- A rejection owes the owner input minus the tip, with no
                  -- share of the fee: the folder funds that separately.
                  fsRefunds = [reqVal - stateMaxFee oldState]
                , -- The refusal row only has to reach its refusal; the
                  -- control runs the fold to the end. Measured at
                  -- (572573, 193235963), so the row's 100M cpu budget
                  -- exhausts and the ledger reports a script failure the
                  -- local evaluation never sees.
                  fsUnits = ExUnits 2_000_000 600_000_000
                }
    ctrl <- assembleFoldWithFee env ctrlSpec
    -- Measure the control before submitting it: every purpose, with its
    -- units or the error the ledger evaluates it to, so a refusal is read
    -- rather than guessed at.
    ctrlEval <- Cage.evaluateTx (envProv env) ctrl
    mapM_
        ( \(p, r) ->
            emit
                "diag"
                ( "CG09 control "
                    <> show p
                    <> " => "
                    <> either show (\(ExUnits m c) -> show (m, c)) r
                )
        )
        (Map.toList ctrlEval)
    _ <- submitExpectAccepted env (addKeyWitness genesisSignKey ctrl)
    emit
        "control"
        "CG09 control: the same request rejected in phase 3 is \
         \accepted — the refusal discriminates"


{- | CG10: Stale fold against a superseded root
(R7_stale_fold_refused). The stale claims are captured against the
cage's root BEFORE any fold; one request folds normally and the
root advances; then a fold for the remaining request is assembled
from the captured claims — a fold that was valid when built,
against a root the chain has since superseded. The state script's
proof check refuses it. The control re-folds the same request
against the live root, the hand shape calibrated against the
library fold.
-}
runCG10 :: Env -> IO ()
runCG10 env = do
    cage <- ensureRowCage env "cg-main" 30_000 30_000
    let cfg = rcCfg cage
    tid <- cageTid cage
    -- The stale claims: k-c's insertion proof against the pre-fold
    -- (empty) root, captured before any fold advances it.
    (staleSteps, staleRoot) <-
        speculativeInsert env cage tid "cg10-key-c" leafAbsent
    _ <-
        rowRequestAndFold
            env
            cage
            "CG10"
            "cg10-key-a"
            "cg10-value-a"
            edgeInsertAbsent
    reqC <- rowRequestInsert env cage "cg10-key-c" "cg10-value-c"
    state <- cageStateUtxo env cage
    pot <- collateralPot env
    units <- declaredSpec env cage
    let staleSpec =
            (rowSpec
                cage
                tid
                state
                [reqC]
                [Update staleSteps]
                staleRoot
                units)
                { fsCollateral = Just pot
                }
    staleTx <- assembleFoldWithFee env staleSpec
    emit
        "row"
        ( "CG10: fold carrying proof steps captured against the \
           \superseded root submitted; the state script must refuse "
            <> "(R7_stale_fold_refused)"
        )
    submitExpectRefused env "CG10" AgreesWithModel (stateMarkerOf cfg) staleTx
    -- Control: the same request folded against the live root, the
    -- hand shape calibrated against the library fold.
    ctxLive <- rowRegistryContext env cage tid
    libFold <-
        updateTokenWithDuties cfg (envProv env) (envTm env) tid genesisAddr ctxLive
    (freshSteps, freshRoot) <-
        speculativeInsert env cage tid "cg10-key-c" leafAbsent
    let freshSpec =
            (rowSpec
                cage
                tid
                state
                [reqC]
                [Update freshSteps]
                freshRoot
                units)
                { fsCollateral = Just pot
                }
    handFresh <- assembleFoldWithFee env freshSpec
    calibrateFold (fst state) handFresh libFold
    emit "calibration" "CG10 control: hand model matches the library fold"
    (mem, cpu) <- measureUnits env handFresh
    signed <-
        submitExpectAccepted env (addKeyWitness genesisSignKey handFresh)
    let size = txSizeBytes signed
    emitMeasure env "CG10-control" mem cpu size
    rowCommit env cage "cg10-key-c" edgeInsertAbsent
    emit
        "control"
        "CG10 control: the same request folded against the live root \
         \is accepted — the refusal is the staleness, not the shape"


{- | CG11: Empty fold (R8_empty_fold_refused; expected consumer gap,
cardano-mpfs-onchain#100). A Modify over no requests, no actions,
unchanged root — the accepted candidate REFUSES it (state.ak
validModify `expect consumed > 0`; protected 196 empty_fold_error /
empty_fold_never_ok). The held observation is the attributed refusal
with its transaction shape; the control is a nonempty fold on the
same path that accepts, proving the refusal is specific to the
empty batch. Row contract is observe-and-report; recorded held
pending Q-002, never a pass.
-}
runCG11 :: Env -> IO ()
runCG11 env = do
    cage <- ensureRowCage env "cg-main" 30_000 30_000
    let cfg = rcCfg cage
    tid <- cageTid cage
    state <- cageStateUtxo env cage
    oldState <- extractState (snd state)
    pot <- collateralPot env
    units <- declaredSpec env cage
    let emptySpec =
            (rowSpec
                cage
                tid
                state
                []
                []
                (Root (unOnChainRoot (stateRoot oldState)))
                units)
                { fsCollateral = Just pot
                }
    hand <- assembleFoldWithFee env emptySpec
    -- Candidate-bound observation (NOTE-108, E18 disposition): the
    -- accepted candidate REFUSES the empty fold (state.ak
    -- validModify `expect consumed > 0`; protected 196
    -- empty_fold_error/empty_fold_never_ok). The attributed refusal
    -- is the held observation — never fulfilment, never debt
    -- reduction. Row contract is observe-and-report; no accept
    -- declared.
    emit
        "row"
        "CG11: submitting the empty fold for its candidate-bound observation"
    submitExpectRefused env "CG11" HeldQ002 (stateMarkerOf cfg) hand
    recordHold
        env
        "CG11"
        "Q-002 (story 2)"
        ( "Singular's Lean refuses the empty fold (consumed>0 guard; "
            <> "protected empty_fold_error/empty_fold_never_ok) — the "
            <> "refusal agrees with Singular's model"
        )
        ( "R8_empty_fold_refused — the empty batch must be refused "
            <> "(consumer-side; upstream cardano-mpfs-onchain#100 is the "
            <> "partition fix)"
        )
    emit
        "row"
        ( "CG11: the chain REFUSED the empty fold — recorded, held "
            <> "pending Q-002, never read as a pass"
        )
    -- Accepting control: the same path with one live request folds
    -- normally. A refusal is only informative next to an acceptance.
    req <-
        rowRequestInsert env cage "cg11-key" "cg11-value"
    stateC <- cageStateUtxo env cage
    (stepsC, rootC) <-
        speculativeInsert env cage tid "cg11-key" leafAbsent
    potC <- collateralPot env
    unitsC <- declaredSpec env cage
    let ctrlSpec =
            (rowSpec
                cage
                tid
                stateC
                [req]
                [Update stepsC]
                rootC
                unitsC)
                { fsCollateral = Just potC
                }
    ctrlTx <- assembleFoldWithFee env ctrlSpec
    (memC, cpuC) <- measureUnits env ctrlTx
    signedC <- submitExpectAccepted env (addKeyWitness genesisSignKey ctrlTx)
    let sizeC = txSizeBytes signedC
    emitMeasure env "CG11-control" memC cpuC sizeC
    rowCommit env cage "cg11-key" edgeInsertAbsent
    emit
        "control"
        ( "CG11 control: nonempty fold accepted (tx="
            <> txIdHex signedC
            <> ") — the refusal is specific to the empty fold"
        )


{- | CG12: Surplus actions beyond the matched request inputs (the
2026-09-03 audit; upstream cardano-mpfs-onchain#100). The accepted
candidate REFUSES the surplus tail (state.ak validModify `expect
actionsTail == []`): every supplied action must pair with an actual
matching request. The held observation is the attributed refusal.
The controls: one action FEWER than there are requests is refused
(the deficit), and an exact 1:1 fold on the same path accepts —
proving exact pairing is enforced both directions and the refusals
are specific. Row contract is observe-and-report; recorded held
pending Q-002, never a pass.
-}
runCG12 :: Env -> IO ()
runCG12 env = do
    cage <- ensureRowCage env "cg-main" 30_000 30_000
    let cfg = rcCfg cage
    tid <- cageTid cage
    req <-
        rowRequestInsert env cage "cg12-key" "cg12-value"
    (steps12, root12) <-
        speculativeInsert env cage tid "cg12-key" leafAbsent
    state <- cageStateUtxo env cage
    pot <- collateralPot env
    units <- declaredSpec env cage
    let surplusSpec =
            (rowSpec
                cage
                tid
                state
                [req]
                [Update steps12, Update []]
                root12
                units)
                { fsCollateral = Just pot
                }
    hand <- assembleFoldWithFee env surplusSpec
    -- Candidate-bound observation (NOTE-108, E18 disposition): the
    -- accepted candidate REFUSES the surplus tail (state.ak
    -- validModify `expect actionsTail == []`). The attributed
    -- refusal is the held observation — never fulfilment, never
    -- debt reduction. Row contract is observe-and-report.
    emit
        "row"
        "CG12: submitting the surplus fold for its candidate-bound observation"
    submitExpectRefused env "CG12" HeldQ002 (stateMarkerOf cfg) hand
    recordHold
        env
        "CG12"
        "Q-002 (story 2)"
        ( "Singular's Lean pairs each request with its action 1:1 in "
            <> "its FoldItem and refuses the surplus tail — the refusal "
            <> "agrees with Singular's model"
        )
        ( "one action per request, no surplus — the consumer audit's "
            <> "finding (upstream cardano-mpfs-onchain#100 is the "
            <> "partition fix)"
        )
    emit
        "row"
        ( "CG12: the chain REFUSED a fold with a surplus action (one "
            <> "request, two actions) — recorded, held pending Q-002, "
            <> "never read as a pass"
        )
    -- Control: two fresh requests, one action — the deficit.
    reqB <-
        rowRequestInsert env cage "cg12-key-b" "cg12-value-b"
    reqC <-
        rowRequestInsert env cage "cg12-key-c" "cg12-value-c"
    state2 <- cageStateUtxo env cage
    (firstSorted, _) <- case sortOn fst [reqB, reqC] of
        [a, b] -> pure (a, b)
        _ -> failWith "CG12 control: expected exactly two requests"
    (firstSteps, rootFirst) <- case extractCageDatum (snd firstSorted) of
        Just (RequestDatum rq)
            | requestEdge rq == edgeInsertAbsent ->
                speculativeInsert env cage tid (requestKey rq) leafAbsent
        Just (RequestDatum _) ->
            failWith "CG12 control: expected an insertAbsent request"
        _ -> failWith "CG12 control: no request datum"
    pot2 <- collateralPot env
    let (firstSorted2, secondSorted2) = case sortOn fst [reqB, reqC] of
            [a, b] -> (a, b)
            _ -> error "CG12 control: exactly two requests"
        deficitSpec =
            (rowSpec
                cage
                tid
                state2
                [firstSorted2, secondSorted2]
                [Update firstSteps]
                rootFirst
                units)
                { fsCollateral = Just pot2
                }
    ctrlTx <- assembleFoldWithFee env deficitSpec
    emit
        "row"
        "CG12 control: two requests, one action — the deficit must be \
         \refused"
    submitExpectRefusedControl env "CG12" AgreesWithModel (stateMarkerOf cfg) ctrlTx
    emit
        "control"
        "CG12 control: the deficit is refused; the surplus is refused — \
         \exact pairing is enforced both directions"
    -- Accepting control: one fresh request, exactly one action — the
    -- same path accepts. A refusal is only informative next to an
    -- acceptance.
    reqD <-
        rowRequestInsert env cage "cg12-key-d" "cg12-value-d"
    state3 <- cageStateUtxo env cage
    (stepsD, rootD) <-
        speculativeInsert env cage tid "cg12-key-d" leafAbsent
    pot3 <- collateralPot env
    let exactSpec =
            (rowSpec
                cage
                tid
                state3
                [reqD]
                [Update stepsD]
                rootD
                units)
                { fsCollateral = Just pot3
                , -- The refusal rows only reach their refusal; this one runs
                  -- the fold to the end, minting and locking custody.
                  fsUnits = ExUnits 2_000_000 800_000_000
                }
    exactTx <- assembleFoldWithFee env exactSpec
    (memD, cpuD) <- measureUnits env exactTx
    signedD <- submitExpectAccepted env (addKeyWitness genesisSignKey exactTx)
    let sizeD = txSizeBytes signedD
    emitMeasure env "CG12-exact" memD cpuD sizeD
    rowCommit env cage "cg12-key-d" edgeInsertAbsent
    emit
        "control"
        ( "CG12 control: exact 1:1 fold accepted (tx="
            <> txIdHex signedD
            <> ") — the refusals are specific to surplus and deficit"
        )


{- | CG14: the stake_script hook set, a fold carrying the matching
withdraw-zero (the partition's shared.ak/types.ak hook; first ever
ledger execution — epic 16 found two validator defects exactly by
executing what green Aiken suites had already passed). The library
fold adds the withdrawal and the staking script witness when the
config carries the hook; the credential is registered first (a
withdrawal from an unregistered account is a phase-1 error, not a
verdict on the hook). The control: the same fold carrying the
withdrawal but declaring NO owner — the hook must accompany the
owner signature, never replace it — must be refused.
-}
{- | CG14: the stake_script hook set, a fold carrying the matching
withdraw-zero (the partition's shared.ak/types.ak hook; first ever
ledger execution — epic 16 found two validator defects exactly by
executing what green Aiken suites had already passed). The library
fold adds the withdrawal and the staking script witness when the
config carries the hook; the credential is registered first (a
withdrawal from an unregistered account is a phase-1 error, not a
verdict on the hook). The control: the same fold carrying the
withdrawal but declaring NO owner — the hook must accompany the
owner signature, never replace it — must be refused.
-}
runCG14 :: Env -> IO ()
runCG14 env = do
    kit <- ensureStakeKit env
    let cage = skCage kit
        cfg = rcCfg cage
        prov = envProv env
    tid <- cageTid cage
    _ <- rowRequestInsert env cage "cg14-key" "cg14-value"
    ctx <- rowRegistryContext env cage tid
    unsigned <-
        updateTokenWithDuties cfg prov (envTm env) tid genesisAddr ctx
    evalMap <- Cage.evaluateTx (envProv env) unsigned
    mapM_ (\(p, r) -> emit "diag" (show p <> " => " <> either show (\(ExUnits m c) -> show (m, c)) r)) (Map.toList evalMap)
    (mem, cpu) <- measureUnits env unsigned
    writeIORef (rcUnits cage) (mem, cpu)
    signed <- submitExpectAccepted env unsigned
    let size = txSizeBytes signed
    emitMeasure env "CG14-hook-fold" mem cpu size
    writeRowReceipt
        env
        "CG14"
        Accepted
        AgreesWithModel        [txIdHex signed]
        Nothing
        Nothing
        (Just mem)
        (Just cpu)
        (Just size)
        "node-submit"
        Nothing
    emit
        "row"
        ( "CG14: the stake_script hook executed on a ledger for the \
           \first time — fold accepted with the owner signature and \
           \a withdraw-zero under staking credential 0x"
            <> hex (scriptHashBytes (skHash kit))
            <> " (tx="
            <> txIdHex signed
            <> ")"
        )
    -- Control: the withdrawal present, the owner declaration absent.
    reqB <- rowRequestInsert env cage "cg14-key-b" "cg14-value-b"
    (stepsB, rootB) <-
        speculativeInsert env cage tid "cg14-key-b" leafAbsent
    state <- cageStateUtxo env cage
    pot <- collateralPot env
    units <- declaredSpec env cage
    let rewardAcct = AccountAddress Testnet (AccountId (ScriptHashObj (skHash kit)))
        stakeScript = scriptFromBytes "cg14-control" (skBytes kit)
        ctrlSpec =
            (rowSpec
                cage
                tid
                state
                [reqB]
                [Update stepsB]
                rootB
                units)
                { fsWithdrawal = Just (rewardAcct, stakeScript)
                , fsSigners = Just []
                , fsCollateral = Just pot
                }
    ctrlTx <- assembleFoldWithFee env ctrlSpec
    emit
        "row"
        "CG14 control: withdrawal present but no owner declared — must \
         \be refused"
    -- CG14 never executes (superseded could-not-execute history), but
    -- its refused control is the same clobber class as CG11/12/19: the
    -- accept row's receipt must survive it (A-002 policy).
    submitExpectRefusedControl env "CG14" AgreesWithModel (stateMarkerOf cfg) ctrlTx
    emit
        "control"
        "CG14 control: the hook does not replace the owner signature — \
         \both legs of validateOwnership are load-bearing"


{- | CG15: the stake_script hook set, the withdrawal absent — the
same fold the library builds, minus exactly the withdrawal, must be
refused by @validateOwnership@'s withdrawal check. The control: the
library fold (withdrawal present) over the pending requests is
accepted — the refusal is the missing withdrawal, nothing else.
-}
runCG15 :: Env -> IO ()
runCG15 env = do
    kit <- ensureStakeKit env
    let cage = skCage kit
        cfg = rcCfg cage
        prov = envProv env
    tid <- cageTid cage
    req <-
        rowRequestInsert env cage "cg15-key" "cg15-value"
    (steps15, root15) <-
        speculativeInsert env cage tid "cg15-key" leafAbsent
    state <- cageStateUtxo env cage
    pot <- collateralPot env
    units <- declaredSpec env cage
    let spec =
            (rowSpec
                cage
                tid
                state
                [req]
                [Update steps15]
                root15
                units)
                { fsCollateral = Just pot
                }
    hand <- assembleFoldWithFee env spec
    emit
        "row"
        ( "CG15: the hook is set but the fold carries no withdrawal; \
           \the state script must refuse"
        )
    submitExpectRefused env "CG15" AgreesWithModel (stateMarkerOf cfg) hand
    -- Control: the library fold carries the withdrawal; it consumes
    -- this request and CG14's parked control request together.
    ctx <- rowRegistryContext env cage tid
    libFold <-
        updateTokenWithDuties cfg prov (envTm env) tid genesisAddr ctx
    (mem, cpu) <- measureUnits env libFold
    signed <- submitExpectAccepted env libFold
    let size = txSizeBytes signed
    emitMeasure env "CG15-control" mem cpu size
    emit
        "control"
        ( "CG15 control: the same fold with the matching withdrawal is \
           \accepted (tx="
            <> txIdHex signed
            <> ", size="
            <> show size
            <> ") — the refusal is the missing withdrawal"
        )


{- | CG19: Refund routing (R11_contribute_value, R11_retract_value;
upstream cardano-mpfs-onchain#101). Two requests with unequal
bonds (5 ada from the genesis wallet, 3 ada from a second wallet)
are REJECTED in phase 3, with the refund OUTPUTS at the correct
owners in the correct order but the AMOUNTS crossed. `sumRefunds`
runs exactly when Rejected actions create owner payouts, so this
row is where refund routing is decided at all. Whatever the
candidate does with the crossed pair is recorded with its
transaction; an exact-routing control accepts beside it. Row
contract is observe-and-report; recorded held pending Q-002, never
a pass.
-}
runCG19 :: Env -> IO ()
runCG19 env = do
    cage <- ensureRowCage env "cg19" 30_000 30_000
    let cfg = rcCfg cage
    tid <- cageTid cage
    (sk2, addr2) <- secondWallet env
    let Coin tip = defaultTip cfg
    -- #157 A-009: both bookings are edges, each binding the address its
    -- own payer gets the deposit back at, and the bonds stay unequal so
    -- the row still has two different amounts to cross.
    destA <- edgeDestinationFor env genesisAddr edgeInsertAbsent
    reqA <-
        bookEdge
            env
            cfg
            tid
            genesisAddr
            genesisSignKey
            "cg19-key-a"
            edgeInsertAbsent
            destA
            []
            5_000_000
    destB <- edgeDestinationFor env addr2 edgeInsertAbsent
    reqB <-
        bookEdge
            env
            cfg
            tid
            addr2
            sk2
            "cg19-key-b"
            edgeInsertAbsent
            destB
            []
            3_000_000
    let sorted = sortOn fst [reqA, reqB]
    -- D-001: this row folds REJECTIONS, so the trie does not move and no
    -- edge duty arises. What it exercises is where the refunds a rejection
    -- owes actually go.
    state <- cageStateUtxo env cage
    liveState <- extractState (snd state)
    let newRoot = Root (unOnChainRoot (stateRoot liveState))
    -- A rejection is only rejectable once every request's retract window
    -- has closed, so the fold waits for the last of them and declares a
    -- lower bound past it.
    let submittedAts =
            [ submitted
            | (_, o) <- sorted
            , let (_, submitted) = requestDatumOf o
            ]
        deadline =
            maximum submittedAts
                + stateProcessTime liveState
                + stateRetractTime liveState
    (firstSorted, secondSorted) <- case sorted of
        [a, b] -> pure (a, b)
        _ -> failWith "CG19: expected exactly two requests"
    let Coin bond1 = snd firstSorted ^. coinTxOutL
        Coin bond2 = snd secondSorted ^. coinTxOutL
        honest = [bond1 - tip, bond2 - tip]
        (c1, c2) = case reverse honest of
            [x, y] -> (x, y)
            _ -> error "CG19: two requests yield two crossed refunds"
    waitPhase3 deadline
    lowerSlot <- Cage.posixMsCeilSlot (envProv env) (deadline + 1000)
    pot <- collateralPot env
    units <- declaredSpec env cage
    let crossedSpec =
            (rowSpec
                cage
                tid
                state
                sorted
                [CageTypes.Rejected, CageTypes.Rejected]
                newRoot
                units)
                { fsRefunds = [c1, c2]
                , fsCollateral = Just pot
                , fsLower = Just lowerSlot
                }
    hand <- assembleFoldWithFee env crossedSpec
    -- Candidate-bound observation (NOTE-108, E18 disposition): the
    -- crossed-refund fold is submitted and WHATEVER the candidate
    -- does is recorded with its transaction — observe and report.
    -- Either outcome stays held; neither fulfils nor reduces debt.
    emit
        "row"
        "CG19: submitting the crossed-refund fold for its candidate-bound observation"
    signedCrossed <- pure (addKeyWitness genesisSignKey hand)
    crossResult <- submitTxResilient (envSubmit env) signedCrossed
    case crossResult of
        Submitted txid -> do
            (mem, cpu) <- measureUnits env hand
            let size = txSizeBytes signedCrossed
            emitMeasure env "CG19-crossed" mem cpu size
            writeRowReceipt
                env
                "CG19"
                Accepted
                HeldQ002
                [txInHex txid]
                Nothing
                Nothing
                (Just mem)
                (Just cpu)
                (Just size)
                "node-submit"
                Nothing
            recordHold
                env
                "CG19"
                "Q-002 (story 2)"
                ( "Singular's Lean's fold action carries no refund routing at "
                    <> "all (Model.lean, Action.fold) — the model constrains "
                    <> "nothing here"
                )
                ( "R11 — action-dependent routing (E18 disposition): processed Update value routes to the checkpoint/consumer hook (Update contributes no Rejected-owner obligations); Rejected owes input-tip per owner under a no-underpayment floor (upstream cardano-mpfs-onchain#101 is the partition fix)"
                )
            emit
                "row"
                ( "CG19: the chain ACCEPTED crossed refunds (bonds 5 ada and "
                    <> "3 ada refunded "
                    <> show c1
                    <> " and "
                    <> show c2
                    <> " lovelace; tx="
                    <> txInHex txid <> ") — processed Update value routes to the checkpoint/consumer hook, not to request owners (no owner floor applies); "
                       <> "recorded, held pending Q-002, never read as a pass"
                )
        Rejected reason -> do
            attributeSubmitRefusal
                env
                "CG19"
                HeldQ002
                (stateMarkerOf cfg)
                (T.unpack (TE.decodeUtf8Lenient reason))
                (txIdHex signedCrossed)
            recordHold
                env
                "CG19"
                "Q-002 (story 2)"
                ( "Singular's Lean's fold action carries no refund routing at "
                    <> "all (Model.lean, Action.fold) — the model constrains "
                    <> "nothing here"
                )
                ( "R11 — action-dependent routing (E18 disposition): processed Update value routes to the checkpoint/consumer hook (Update contributes no Rejected-owner obligations); Rejected owes input-tip per owner under a no-underpayment floor (upstream cardano-mpfs-onchain#101 is the partition fix)"
                )
            emit
                "row"
                ( "CG19: the chain REFUSED crossed refunds — recorded with "
                    <> "attribution, held pending Q-002, never read as a pass"
                )
            -- Accepting control (NOTE-065): the same live requests
            -- and state with CORRECT per-owner routing (default
            -- honest refunds). Fresh collateral: the refused
            -- submission slashed its pot. A refusal is only
            -- informative next to an acceptance.
            potA <- collateralPot env
            let acceptSpec =
                    (rowSpec
                        cage
                        tid
                        state
                        sorted
                        [CageTypes.Rejected, CageTypes.Rejected]
                        newRoot
                        units)
                        { fsCollateral = Just potA
                        , fsRefunds = honest
                        , fsLower = Just lowerSlot
                        , -- The refusal leg only reaches its refusal; this
                          -- one runs the fold to the end.
                          fsUnits = ExUnits 2_000_000 800_000_000
                        }
            acceptTx <- assembleFoldWithFee env acceptSpec
            (memA, cpuA) <- measureUnits env acceptTx
            signedA <- submitExpectAccepted env (addKeyWitness genesisSignKey acceptTx)
            let sizeA = txSizeBytes signedA
            emitMeasure env "CG19-routed" memA cpuA sizeA
            emit
                "control"
                ( "CG19 control: correctly routed refunds accepted (tx="
                    <> txIdHex signedA
                    <> ") — routing to the owners a rejection owes"
                )
    -- Rejected-action refund floor, as a separately named instrument
    -- (NOTE-073/181): the legs above cross two owners' amounts against
    -- each other, which says nothing about whether either clears the
    -- floor it is owed. This control arms an underpayment directly — one
    -- owner a thousand lovelace short — beside a funded counterpart.
    runCG19RejectedFloor env cage tid


-- | CG19-rejected-floor control (NOTE-073/074/077/080/181, E18 disposition):
-- the Rejected-action refund floor as a separately named
-- instrument. Phase-3 Rejected pair: underpaying one owner below
-- input-tip refuses (state script); funding both at/above accepts.
-- Owner obligations derive by pairing the actual Rejected actions
-- with their matching request datums/token in sorted consumed
-- order and are asserted nonempty with the actual pair length
-- before any destructure. Owed is input-tip with no fee share;
-- funding pays fees separately. Both legs share
-- requests/actions/order/phase/Hook; collateral/funding/timing
-- freshness necessarily differs and is recorded as such. Evidence
-- travels in control-CG19-rejected-floor.json (not a row receipt).
-- Must not imply processed value returns to owners.
runCG19RejectedFloor :: Env -> RowCage -> TokenId -> IO ()
runCG19RejectedFloor env cage tid = do
    let cfg = rcCfg cage
        prov = envProv env
    (skR2, addrR2) <- secondWallet env
    (reqRa, outRa) <-
        paddedRequest env cage genesisAddr genesisSignKey "cg19-rej-a" "cg19-rej-va" 5_000_000
    (reqRb, outRb) <-
        paddedRequest env cage addrR2 skR2 "cg19-rej-b" "cg19-rej-vb" 3_000_000
    state <- cageStateUtxo env cage
    oldState <- extractState (snd state)
    let tip = stateMaxFee oldState
        -- Sorted consumed order FIRST (NOTE-077): validator
        -- consumption and owner order follow sorted tx inputs.
        -- Every amount/owner/refund below derives from this list.
        sortedReqs = sortOn fst [(reqRa, outRa), (reqRb, outRb)]
        actions = [CageTypes.Rejected, CageTypes.Rejected]
        -- Pair each action with its matching datum/token (NOTE-080):
        -- derive obligations from the actual pairs, never a literal.
        matchObligation ((reqIn, reqOut), act) = case (extractCageDatum reqOut, act) of
            (Just (RequestDatum rq), CageTypes.Rejected) -> do
                let CageTypes.OnChainTokenId (BuiltinByteString tokBs) = requestToken rq
                require
                    "CG19-rejected-floor: request token mismatch"
                    (AssetName (SBS.toShort tokBs) == unTokenId tid)
                let Coin bond = reqOut ^. coinTxOutL
                    owed = bond - tip
                require "CG19-rejected-floor: nonpositive owed" (owed > 0)
                pure (reqIn, reqOut, hex (extractOwnerBytes reqOut), owed, requestKey rq)
            _ ->
                failWith
                    "CG19-rejected-floor: unmatched action/datum pair (want Rejected over RequestDatum)"
    matched <- mapM matchObligation (zip sortedReqs actions)
    let obligations = [(owner, owed) | (_, _, owner, owed, _) <- matched]
    require "CG19-rejected-floor: owner obligations empty" (not (null obligations))
    require "CG19-rejected-floor: expected a pair of obligations" (length obligations == 2)
    [(_, _, _, owed1, _), (_, _, _, owed2, _)] <- case matched of
        pair@[_, _] -> pure pair
        _ -> failWith "CG19-rejected-floor: pair destructure failed after length check"
    emit
        "control"
        ( "CG19-rejected-floor: obligations " <> show obligations
        )
    -- Phase-3 wait: past the latest request deadline.
    submittedAts <- mapM submittedAtDatum (map snd sortedReqs)
    let deadline =
            maximum submittedAts
                + stateProcessTime oldState
                + stateRetractTime oldState
    waitPhase3 deadline
    lowerSlot <- Cage.posixMsCeilSlot prov (deadline + 1000)
    nowAfter <- currentPosixMs
    require
        "CG19-rejected-floor: wait did not reach the lower bound"
        (nowAfter > deadline + 1000)
    pot <- collateralPot env
    units <- declaredSpec env cage
    let rootNow = Root (unOnChainRoot (stateRoot oldState))
        baseSpec st reqs refunds potX lowerX upperX =
            (rowSpec cage tid st reqs actions rootNow units)
                { fsRefunds = refunds
                , fsLower = Just lowerX
                , fsUpper = Just upperX
                , fsCollateral = Just potX
                }
        matchedReqs = [(a, b) | (a, b, _, _, _) <- matched]
    -- Adverse leg: underpay the first owner by 1000. Near-now
    -- upper bound at submit time (NOTE-077: stale far-future
    -- uppers fail at the horizon).
    nowMsU <- currentPosixMs
    upperU <- trySlots prov [nowMsU + 2_000, nowMsU + 1_500, nowMsU + 1_000]
    underTx <- assembleFoldWithFee env (baseSpec state matchedReqs [owed1 - 1000, owed2] pot lowerSlot upperU)
    let signedUnder = addKeyWitness genesisSignKey underTx
    underResult <- submitTxResilient (envSubmit env) signedUnder
    underReason <- case underResult of
        Rejected reason -> pure (T.unpack (TE.decodeUtf8Lenient reason))
        Submitted txid ->
            failWith
                ( "CG19-rejected-floor FINDING: underpaid leg ACCEPTED (txid "
                    <> txInHex txid
                    <> ") — reported, not relabelled"
                )
    underAttr <-
        attributeRefusalReceipt
            RefusalControl
            (envReceiptsDir env)
            "CG19"
            AgreesWithModel
            "state"
            (stateMarkerOf cfg)
            underReason
            (txIdHex signedUnder)
            (envBase env)
            (envDirty env)
            (envNode env)
            (envBlueprint env)
    case underAttr of
        Right () -> pure ()
        Left mismatch ->
            failWith ("CG19-rejected-floor: underpaid refusal did not attribute: " <> show mismatch)
    emit
        "control"
        "CG19-rejected-floor: underpaid leg REFUSED, attributed to state script"
    -- Accepting counterpart: fund both at owed. Fresh collateral,
    -- fresh state read ASSERTED same unspent input (NOTE-080), fresh
    -- near-now upper (the await timing can expire a reused bound —
    -- recorded, not byte-identical).
    pot2 <- collateralPot env
    state2 <- cageStateUtxo env cage
    require
        "CG19-rejected-floor: state moved between legs"
        (fst state2 == fst state)
    nowMsO <- currentPosixMs
    upperO <- trySlots prov [nowMsO + 2_000, nowMsO + 1_500, nowMsO + 1_000]
    overTx <- assembleFoldWithFee env (baseSpec state2 matchedReqs [owed1, owed2] pot2 lowerSlot upperO)
    (memO, cpuO) <- measureUnits env overTx
    signedO <- submitExpectAccepted env (addKeyWitness genesisSignKey overTx)
    let sizeO = txSizeBytes signedO
    emitMeasure env "CG19-rejected-floor-funded" memO cpuO sizeO
    -- Root unchanged (Rejected Inserts were never in the trie):
    -- assert from the chain, preserve the mirror (no deletes).
    state3 <- cageStateUtxo env cage
    postRoot <- stateRoot <$> extractState (snd state3)
    require
        "CG19-rejected-floor: state root moved although rejected keys were never committed"
        (postRoot == stateRoot oldState)
    -- Control receipt (NOTE-074/181): only after both outcomes
    -- observed and the nonempty check passed above. Trimmed
    -- attribution plus structured fields; raw node rejection stays
    -- in runtime evidence. Readability-bounded like row receipts.
    base <- requireBase
    -- #157 C8/C10: `consumer.ak` is deleted and every rule it re-walked
    -- beside the fold is the cage's own, so the control records the
    -- authority that actually refuses this pair — the state script
    -- (A-015) — not a hook the registry no longer has.
    let authorityHex = hex (scriptHashBytes (cfgScriptHash cfg))
        underHashes = map T.pack (refusalScriptHashes underReason)
        orderedReqs =
            [ object
                [ "outref" .= T.pack (show reqIn)
                , "key" .= hex key
                , "owner" .= owner
                , "owed" .= owed
                ]
            | (reqIn, _, owner, owed, key) <- matched
            ]
        controlDoc =
            object
                [ "control" .= ("CG19-rejected-floor" :: Text)
                , "row" .= ("CG19" :: Text)
                , "base" .= base
                , "blueprint" .= envBlueprint env
                , "node" .= envNode env
                , "dirty" .= envDirty env
                , "ordered-requests" .= orderedReqs
                , "actions" .= (["Rejected", "Rejected"] :: [Text])
                , "bounds"
                    .= object
                        [ "lowerSlot" .= show lowerSlot
                        , "upperUnderpaid" .= show upperU
                        , "upperFunded" .= show upperO
                        ]
                , "authority" .= authorityHex
                , "obligations"
                    .= [object ["owner" .= o, "owed" .= w] | (o, w) <- obligations]
                , "underpaid"
                    .= object
                        [ "outcome" .= ("refused" :: Text)
                        , "txid" .= txIdHex signedUnder
                        , "phase" .= ("phase-2" :: Text)
                        , "hashes" .= underHashes
                        , "reason" .= T.pack (trimRefusal underReason)
                        , "limit"
                            .= ( "no named validator branch in this compiled trace; attribution is script hash plus phase-2 only" ::
                                    Text
                               )
                        , "paid" .= [owed1 - 1000, owed2]
                        ]
                , "funded"
                    .= object
                        [ "outcome" .= ("accepted" :: Text)
                        , "txid" .= txIdHex signedO
                        , "paid" .= [owed1, owed2]
                        , "mem" .= memO
                        , "cpu" .= cpuO
                        , "size" .= sizeO
                        ]
                , "pairing"
                    .= ( "same rejected requests/actions/order/phase/Hook; allocation differs (underpaid vs exact owed); fresh collateral, separate funding and per-leg near-now validity bounds necessarily differ" ::
                            Text
                       )
                ]
        controlBytes = encode controlDoc
    require
        "CG19-rejected-floor: control receipt over readability bound"
        (BSL.length controlBytes <= fromIntegral maxReceiptBytes)
    BSL.writeFile
        (envReceiptsDir env </> "control-CG19-rejected-floor.json")
        controlBytes
    emit
        "control"
        ( "CG19-rejected-floor: funded counterpart accepted (tx="
            <> txIdHex signedO
            <> "); control receipt written"
        )


-- ---------------------------------------------------------
-- CG21 (#173 A173-EDGE/A173-REFUSALS, completed in #184)
-- ---------------------------------------------------------
{- | The live registration program submits two distinct active registrations,
a duplicate-key request, a registration whose delivery is sent to another
address and one paying it one lovelace short beside their untampered control,
and a registration carrying one required signer the model does not require.
Each request runs through the same builder and driver comparison. The receipt
records all seven steps and their chain outcomes. A two-request batch is outside
this program and remains a published gap.
-}
runCG21 :: Env -> IO ()
runCG21 env = do
    either failWith pure (Live.validateLive (RegistrationStory.story
        (Live.Context "registration" "recipient wallet")))
    writeIORef (envLiveRecords env) []
    writeIORef (envLiveMeasurements env) []
    control <- lookupEnv "CONFORMANCE_STORY_CONTROL"
    require "unknown registration story control"
        (control `elem` [Nothing, Just "wrong-fee", Just "wrong-timing",
            Just "wrong-delivery", Just "unknown-identity"])
    registry <- ensureRowCage env "story-registration" 30_000 30_000
    (_, recipient) <- secondWallet env
    _ <- runLive env (RegistrationStory.story (Live.Context registry recipient))
    -- The generic interpreter writes one record per request. The receipt is
    -- emitted only after all seven outcomes and comparisons have completed.
    records <- readIORef (envLiveRecords env)
    require "CG21 did not compare its seven requests" (length records == 7)
    require "registration chapter has a disagreement or unsupported step"
        (all (\record -> case record of
            Object fields -> KM.lookup "comparison" fields == Just (String "agrees")
            _ -> False) records)
    writeStoryReceipt env "CG21" records


-- ---------------------------------------------------------
-- CG22 (#177): the retirement, and the two leaves that refuse it
-- ---------------------------------------------------------

{- | CG22: `insertActive` then `updateTerminal` at the SAME key, in one
real open-registry session, with the two refusals the Lean row names.

The lifecycle is connected on purpose (constitution III): the token this
row burns is the token it booked a moment earlier, at a WALLET — the
open application has no spending arm, so a token routed to it could
never be retired. A fixture dropped into the final state would evidence
nothing about the transition.

Each refusal is measured against an ACCEPTING CONTROL taken first, in
the same cage and through the same builder, differing in exactly one
fact: the control's key IS active, the unknown key was never inserted,
and the absent key was witnessed absent by a real fold. Without the
control, "refused" is consistent with "this harness cannot fold at all".

The reason NAMES are not asserted from the node. A phase-2 failure
carries an empty Plutus log list, so the receipt records honest `null`
with script-hash attribution; the names live in the compiled Aiken suite
against `state.terminalRefusal`.

The same session then deletes a registration: its deposit is paid back one
lovelace short and to another address, each refused, before the untampered
deletion pays it.
-}
runCG22 :: Env -> IO ()
runCG22 env = do
    either failWith pure (Live.validateLive (RetirementStory.story
        (Live.Context "retirement" "holder wallet")
        (Live.Context "comparison" "holder wallet")))
    writeIORef (envLiveRecords env) []
    writeIORef (envLiveMeasurements env) []
    control <- lookupEnv "CONFORMANCE_STORY_CONTROL"
    require "unknown retirement story control"
        (control `elem` [Nothing, Just "wrong-fee", Just "wrong-timing",
            Just "wrong-delivery", Just "unknown-identity"])
    registry <- ensureRowCage env "story-retirement" 30_000 30_000
    comparison <- ensureRowCage env "story-unknown-key comparison" 30_000 30_000
    _ <- largestWalletUtxo (envProv env)
    _ <- runLive env (RetirementStory.story
        (Live.Context registry genesisAddr) (Live.Context comparison genesisAddr))
    records <- readIORef (envLiveRecords env)
    require "CG22 did not compare its eleven requests" (length records == 11)
    require "retirement chapter has a disagreement or unsupported step"
        (all (\record -> case record of
            Object fields -> KM.lookup "comparison" fields == Just (String "agrees")
            _ -> False) records)
    writeStoryReceipt env "CG22" records


-- | An unnamed seven-edge program using exactly the chapter interpreter.
-- The receipt is required by the running book before it renders success.
runSequence :: Env -> IO ()
runSequence env = do
    either failWith pure (Live.validateLive (SequenceStory.story
        (Live.Context "sequence" "holder wallet")))
    writeIORef (envLiveRecords env) []
    writeIORef (envLiveMeasurements env) []
    registry <- ensureRowCage env "unnamed-sequence" 30_000 30_000
    _ <- runLive env (SequenceStory.story (Live.Context registry genesisAddr))
    records <- readIORef (envLiveRecords env)
    require "unnamed sequence has no compared requests" (not (null records))
    require "unnamed sequence did not report the required edge outcomes"
        (all expectedSequenceOutcome records)
    writeStoryReceipt env "sequence" records
  where
    expectedSequenceOutcome (Object fields) =
        case (KM.lookup "edge" fields, KM.lookup "comparison" fields) of
            (Just (String edge), Just (String "agrees")) ->
                edge `elem` ["insertAbsent", "insertActive", "updateActive", "updateTerminal", "deleteAbsent", "deleteActive", "witnessTerminal"]
            _ -> False
    expectedSequenceOutcome _ = False


{- | CG05 needs its key OCCUPIED, whatever leaf it holds: the row is about
inserting on a key the trie already has, and the seven edges admit an
insert only against a key that is absent from the trie entirely. CG02
leaves the shared key active; a session that runs CG05 alone witnesses an
absence first.
-}
ensurePresentV3 :: Env -> IO ()
ensurePresentV3 env = do
    (present, _) <- readIORef (envKeys env)
    if present
        then pure ()
        else do
            emit "setup" "key absent; witnessing its absence as setup"
            (_, _, _, _) <-
                requestAndFold env "CG05-setup" edgeInsertAbsent
            commitTm env edgeInsertAbsent
            verifyPresentValue
                (envCfg env)
                (envProv env)
                (envMirror env)
                (envTid env)
                cgKey
                (claimValue env cgV1)
                forgedValue
            writeIORef (envKeys env) (True, cgV1)


setupDelete :: Env -> IO ()
setupDelete env = do
    (present, cur) <- readIORef (envDeleteKey env)
    require "setup delete needs the delete key present" present
    (preProof, preRoot) <- capturePreProofKey env cgDeleteKey
    (_, _, _, _) <-
        requestAndFoldKey env "CG04-setup" cgDeleteKey edgeDeleteAbsent
    commitTmKey env cgDeleteKey edgeDeleteAbsent
    verifyAbsentKey
        (envCfg env)
        (envProv env)
        (envMirror env)
        (envTid env)
        cgDeleteKey
        cur
        preProof
        preRoot
        (envControl env == FalseClaim)
    writeIORef (envDeleteKey env) (False, "")


{- | Capture the pre-delete inclusion proof and chain root for the
absence control: the proof bound to the deleted value must not
imply the post-delete root.
-}

capturePreProofKey ::
    Env -> ByteString -> IO (MPFProof MPFHash, OnChainRoot)
capturePreProofKey env cgKey' = do
    preRoot <-
        stateRoot
            <$> readChainState
                (envCfg env)
                (envProv env)
                (envTid env)
    db <- readIORef (envMirror env)
    case inclusionProofFrom db cgKey' of
        Just p -> pure (p, preRoot)
        Nothing ->
            failWith
                "setup: key has no inclusion proof before delete"


{- | Wait until two seconds past the given deadline ms (phase-3 entry
for Rejected folds), sleeping exactly the remaining time. A deadline
more than a hundred seconds away fails closed rather than submitting
a wrong-phase transaction.
-}
waitPhase3 :: Integer -> IO ()
waitPhase3 deadline = do
    now <- currentPosixMs
    let remaining = deadline + 2001 - now
    when (remaining > 100_000) $
        failWith "phase-3 wait timed out; refusing to submit a wrong-phase fold"
    when (remaining > 0) $ threadDelay (fromIntegral remaining * 1000)


-- | The claimed value under test; false-claim mode binds the forgery.
claimValue :: Env -> ByteString -> ByteString
claimValue env val = case envControl env of
    FalseClaim -> forgedValue
    _ -> val


{- | CG03's own key, seeded at the absent leaf.

The delete row needs a key it can actually delete: the registry certifies
the deletion of a WITNESSED ABSENCE (edge 4) and never the deletion of an
active name (edge 5, `never-certified`, N5). So the row books an absence on
its own key and deletes that — the same proposition it always made, that a
delete folds and the key then proves absent from the chain root.
-}
seedDeleteKey :: Env -> IO ()
seedDeleteKey env = do
    (present, _) <- readIORef (envDeleteKey env)
    if present
        then pure ()
        else do
            emit "setup" "delete key absent; witnessing its absence as setup"
            (_, _, _, _) <-
                requestAndFoldKey env "CG03-setup" cgDeleteKey edgeInsertAbsent
            commitTmKey env cgDeleteKey edgeInsertAbsent
            verifyPresentValue
                (envCfg env)
                (envProv env)
                (envMirror env)
                (envTid env)
                cgDeleteKey
                (claimValue env cgV1)
                forgedValue
            writeIORef (envDeleteKey env) (True, cgV1)


-- ---------------------------------------------------------
-- Setup folds (prerequisites, never rows)
-- ---------------------------------------------------------


ensurePresentV1 :: Env -> IO ()
ensurePresentV1 env = do
    (present, val) <- readIORef (envKeys env)
    case (present, val) of
        (True, v) | v == cgV1 -> pure ()
        (True, _) ->
            failWith "CG02 setup: key holds an unexpected value"
        _ -> do
            emit "setup" "key absent; inserting v1 as setup"
            (_, _, _, _) <-
                requestAndFold env "CG02-setup" edgeInsertAbsent
            commitTm env edgeInsertAbsent
            verifyPresentValue
                (envCfg env)
                (envProv env)
                (envMirror env)
                (envTid env)
                cgKey
                (claimValue env cgV1)
                forgedValue
            writeIORef (envKeys env) (True, cgV1)
