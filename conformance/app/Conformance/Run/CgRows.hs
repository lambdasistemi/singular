{-# LANGUAGE LambdaCase #-}

{- |
Module      : Conformance.Run.CgRows
Description : Split out of Conformance.Run (#263); see that module's header
License     : Apache-2.0
-}
module Conformance.Run.CgRows
    ( runCG02
    , runCG03
    , runCG04
    , runCG05
    , sleepUntilMs
    , runCG07
    , runCG09
    , runCG10
    , runCG11
    , runCG12
    , runCG14
    , runCG15
    , runCG19
    , runCG19RejectedFloor
    , runCG21
    , runCG22
    , runCG23
    , runCG24
    , runSequence
    , runBatchHarness
    , ensurePresentV3
    , setupDelete
    , capturePreProofKey
    , waitPhase3
    , claimValue
    , seedDeleteKey
    , ensurePresentV1
    ) where

import Conformance.Run.Book
import Conformance.Run.Cage
import Conformance.Run.Control
import Conformance.Run.Environment
import Conformance.Run.Fold
import Conformance.Run.Live
import Conformance.Run.Observe
import Conformance.Run.Receipts
import Conformance.Run.Submit
import Conformance.Run.Units
import Conformance.Run.Wallet

import Conformance.Edge.EarlyReject qualified as EarlyRejectStory
import Conformance.Edge.Exit qualified as ExitStory
import Conformance.Edge.Occupied qualified as OccupiedStory
import Conformance.Edge.Register qualified as RegistrationStory
import Conformance.Edge.Retire qualified as RetirementStory
import Conformance.Edge.RetractionWindow qualified as WindowStory
import Conformance.Edge.Sequence qualified as SequenceStory
import Conformance.Story.Live qualified as Live
import Control.Concurrent (threadDelay)
import Control.Monad (when)
import Data.Aeson
    ( Value (..)
    , encode
    , object
    , (.=)
    )
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.IORef (readIORef, writeIORef)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((^.))
import System.Environment (lookupEnv)
import System.FilePath ((</>))

import Cardano.Ledger.Address
    ( AccountAddress (..)
    , AccountId (..)
    , Addr
    )

import Cardano.Ledger.Api.Tx.Out
    ( coinTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( Network (..)
    )
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Node.Client.E2E.Setup (Ed25519DSIGN, SignKeyDSIGN)
import MPF.Hashes (MPFHash)
import MPF.Proof.Insertion (MPFProof (..))

import PlutusTx.Builtins.Internal (BuiltinByteString (..))
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger
    ( AssetName (..)
    , Coin (..)
    , ExUnits (..)
    , Root (..)
    , TokenId (..)
    )
import Singular.Registry.Node
    ( SubmitResult (..)
    , signTx
    , signedTx
    )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.TxBuilder.Internal
    ( currentPosixMs
    , extractCageDatum
    , extractOwnerBytes
    , leafAbsent
    , scriptFromBytes
    , scriptHashBytes
    , trySlots
    )
import Singular.Registry.TxBuilder.Update
    ( updateTokenWithDuties
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRequest (..)
    , OnChainRoot (..)
    , OnChainTokenState (..)
    , RequestAction (Update)
    , edgeDeleteAbsent
    , edgeInsertAbsent
    , edgeUpdateActive
    )
import Singular.Registry.Types qualified as CageTypes

import Conformance.Mirror
    ( emit
    , failWith
    , hex
    , inclusionProofFrom
    , readChainState
    , require
    , txIdHex
    , verifyAbsentKey
    , verifyPresentValue
    )
import Conformance.Receipt
    ( Outcome (..)
    , Verdict (..)
    , maxReceiptBytes
    )
import Conformance.Refusal
    ( RefusalRole (..)
    , attributeRefusalReceipt
    , refusalScriptHashes
    , trimRefusal
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
        AgreesWithModel
        [txIdHex foldTx]
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
        AgreesWithModel
        [txIdHex foldTx]
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
        AgreesWithModel
        [txIdHex foldTx]
        Nothing
        Nothing
        (Just mem)
        (Just cpu)
        (Just size)
        "node-submit"
        Nothing
    writeIORef (envDeleteKey env) (True, cgV3)
    emit "row" "CG04: ACCEPTED re-Insert, v3 reads back from chain"

-- | Sleep until the devnet's POSIX-ms clock reaches @targetMs@.
sleepUntilMs :: Env -> Integer -> IO ()
sleepUntilMs _env targetMs = do
    now <- currentPosixMs
    let remaining = targetMs - now
    when (remaining > 0) $ do
        emit "wait" (show remaining <> " ms to the next phase boundary")
        threadDelay (fromIntegral remaining * 1000)

{- | Retractions before, inside and after phase 2, in a registry of their own.
Both requests are booked before any exit. Thirty seconds of processing leave
time to submit the first refusal; thirty more admit its accepting control.
-}
runCG07 :: Env -> IO ()
runCG07 env = do
    either
        failWith
        pure
        ( Live.validateLive
            ( WindowStory.story
                (Live.Context "retraction window" "owner wallet")
            )
        )
    writeIORef (envLiveRecords env) []
    writeIORef (envLiveMeasurements env) []
    control <- lookupEnv "CONFORMANCE_STORY_CONTROL"
    require
        "unknown retraction window story control"
        (control `elem` [Nothing, Just "inside-phase-2"])
    cage <- ensureRowCage env "story-retraction-window" 30_000 30_000
    let (first, second) = WindowStory.requests genesisAddr
    _ <-
        runLiveWithRequests
            env
            [(cage, first), (cage, second)]
            (WindowStory.story (Live.Context cage genesisAddr))
    records <- readIORef (envLiveRecords env)
    require
        "retraction window did not compare its three steps"
        (length records == 3)
    require
        "retraction window has a disagreement or unsupported step"
        ( all
            ( \case
                Object fields -> KM.lookup "comparison" fields == Just (String "agrees")
                _ -> False
            )
            records
        )
    writeStoryReceipt env "CG07" records

{- | CG09: @Rejected@ when not rejectable (R9_reject_needs_rejectable).
The consumer requires a reject inside the request's process window to be
refused. Singular's Lean gives a reject no admission
(@exitAdmission .reject = none@) and the chain accepts it (#320). By
operator ruling 2026-10-01 the consumer requirement is kept unmet: the row
is recorded @unmet-by-ruling@, never as agreement and never as a pass.
Its control comes first, on the same request: the same
processing-window reject refunding the owner one lovelace short, which
the state script must refuse. Both carry the units of a full fold, so a
budget failure cannot pass for a refusal by rule.
-}
runCG09 :: Env -> IO ()
runCG09 env = do
    writeIORef (envLiveRecords env) []
    live <- newLiveState "CG09"
    cage <- ensureRowCage env "cg09" 30_000 5_000
    let cfg = rcCfg cage
        prov = envProv env
    tid <- cageTid cage
    -- The request's owner is not the genesis wallet a fold returns its change
    -- to, so the outputs crediting the owner are exactly its refund.
    (ownerSk, owner) <- ownerWallet env 10_000_000
    (reqIn, reqOut) <-
        paddedRequest
            env
            cage
            owner
            ownerSk
            "cg09-key"
            "cg09-value"
            (defaultTipCoin cfg + cgDeposit)
    let (_, submittedAt) = requestDatumOf reqOut
        processDeadline = submittedAt + 30_000
    state <- cageStateUtxo env cage
    oldState <- extractState (snd state)
    let Coin reqVal = reqOut ^. coinTxOutL
        -- A rejection owes the owner input minus the tip, with no share
        -- of the fee: the folder funds that separately.
        owed = reqVal - stateMaxFee oldState
        -- The full fold of one rejected request, measured at
        -- (572573, 193235963): a refusal-sized budget would exhaust, and
        -- the ledger would report a script failure for the budget.
        units = ExUnits 2_000_000 600_000_000
        rejectWithin upper refund collateral =
            ( rowSpec
                cage
                tid
                state
                [(reqIn, reqOut)]
                [CageTypes.Rejected]
                (Root (unOnChainRoot (stateRoot oldState)))
                units
            )
                { fsUpper = Just upper
                , fsRefunds = [refund]
                , fsCollateral = collateral
                }
        insideProcessWindow = do
            now <- currentPosixMs
            require
                "CG09: the request's process window closed before its \
                \reject was built"
                (now + 2_000 < processDeadline)
            Cage.withView prov $ \v ->
                trySlots v [now + 2_000, now + 1_500, now + 1_000]
    pot <- collateralPot env
    shortUpper <- insideProcessWindow
    short <-
        assembleFoldWithFee
            env
            (rejectWithin shortUpper (owed - 1) (Just pot))
    emit
        "row"
        "CG09 control: the request's processing-window reject refunding \
        \its owner one lovelace short; the state script must refuse it"
    let shortWitnessed = signTx genesisSignKey short
        shortSigned = signedTx shortWitnessed
    shortResult <- submitTxResilient (envSubmit env) shortWitnessed
    -- The model's reject batch of this one request, judged on the refund the
    -- control pays: refused for the reason the traced replay must admit.
    shortCompared <-
        compareHandBatch
            env
            live
            cage
            Live.Reject
            [
                ( Live.EdgeRequest Live.InsertAbsent "cg09-key" owner
                , owner
                , (reqIn, reqOut)
                )
            ]
            shortSigned
            shortResult
    case shortResult of
        Rejected reason ->
            attributeControlRefusal
                env
                "CG09"
                AgreesWithModel
                (stateMarkerOf cfg)
                (T.unpack (TE.decodeUtf8Lenient reason))
                (txIdHex shortSigned)
        Submitted txid ->
            failWith
                ( "CG09 FINDING: the node ACCEPTED the control transaction "
                    <> "expected to refuse (txid "
                    <> txInHex txid
                    <> ") — reported, not relabelled"
                )
    require
        "CG09: the model and the chain do not agree on the short reject"
        (agreed shortCompared)
    upper <- insideProcessWindow
    hand <- assembleFoldWithFee env (rejectWithin upper owed Nothing)
    -- Every purpose's units as the node evaluates them, before submitting.
    handEval <- Cage.withView (envProv env) (`Cage.viewEvaluateTx` hand)
    mapM_
        ( \(p, r) ->
            emit
                "diag"
                ( "CG09 "
                    <> show p
                    <> " => "
                    <> either show (\(ExUnits m c) -> show (m, c)) r
                )
        )
        (Map.toList handEval)
    emit
        "row"
        ( "CG09: Rejected action while the request is still inside its \
          \process window; the consumer requires a refusal "
            <> "(R9_reject_needs_rejectable), Singular's Lean admits it"
        )
    -- Measured before it is submitted: once the reject lands, its request is
    -- spent and the node can no longer evaluate it.
    (mem, cpu) <- measureUnits env hand
    let signedWitnessed = signTx genesisSignKey hand
        signed = signedTx signedWitnessed
    result <- submitTxResilient (envSubmit env) signedWitnessed
    case result of
        Submitted txid -> do
            let size = txSizeBytes signed
            emitMeasure env "CG09" mem cpu size
            writeRowReceipt
                env
                "CG09"
                Accepted
                UnmetByRuling
                [txInHex txid]
                Nothing
                Nothing
                (Just mem)
                (Just cpu)
                (Just size)
                "node-submit"
                Nothing
            recordUnmet
                env
                "CG09"
                "kept unmet by operator ruling 2026-10-01 (singular#320; \
                \alignment: cardano-keri#468)"
                ( "Singular's Lean gives a reject no admission "
                    <> "(Model.lean exitAdmission .reject = none): a folder "
                    <> "may reject a request inside its process window"
                )
                "R9_reject_needs_rejectable — a reject is refused until the request's retract window has passed"
            emit
                "row"
                ( "CG09: the chain ACCEPTED the processing-window reject "
                    <> "(tx="
                    <> txInHex txid
                    <> "), refunding its owner "
                    <> show owed
                    <> " lovelace; unmet by ruling, never read as a pass: the "
                    <> "consumer requirement stays unmet"
                )
        Rejected reason ->
            failWith
                ( "CG09 FINDING: the node REFUSED the processing-window "
                    <> "reject Singular's Lean admits: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )

{- | CG10: Stale fold against a superseded root
(R7_stale_fold_refused). The stale claims are captured against the
cage's root BEFORE any fold; one request folds normally and the
root advances; then a fold for the remaining request is assembled
from the captured claims — a fold that was valid when built,
against a root the chain has since superseded. The state script's
proof check refuses it. The control re-folds the same request
against the live root, the hand shape calibrated against the
library fold.
The model takes no proof and no authenticated root, and admits the
insertion on that unoccupied key, so there is no model reason to compare:
the model comparison is unmet (#346).
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
            ( rowSpec
                cage
                tid
                state
                [reqC]
                [Update staleSteps]
                staleRoot
                units
            )
                { fsCollateral = Just pot
                }
    staleTx <- assembleFoldWithFee env staleSpec
    emit
        "row"
        ( "CG10: fold carrying proof steps captured against the \
          \superseded root submitted; the state script must refuse "
            <> "(R7_stale_fold_refused)"
        )
    submitExpectRefused
        env
        "CG10"
        AgreesWithModel
        (stateMarkerOf cfg)
        staleTx
    -- Control: the same request folded against the live root, the
    -- hand shape calibrated against the library fold.
    libFold <-
        Cage.withView (envProv env) $ \v -> do
            ctxLive <- rowRegistryContext env v cage tid
            updateTokenWithDuties
                cfg
                v
                (envTm env)
                tid
                genesisAddr
                ctxLive
    (freshSteps, freshRoot) <-
        speculativeInsert env cage tid "cg10-key-c" leafAbsent
    let freshSpec =
            ( rowSpec
                cage
                tid
                state
                [reqC]
                [Update freshSteps]
                freshRoot
                units
            )
                { fsCollateral = Just pot
                }
    handFresh <- assembleFoldWithFee env freshSpec
    calibrateFold (fst state) handFresh libFold
    emit "calibration" "CG10 control: hand model matches the library fold"
    (mem, cpu) <- measureUnits env handFresh
    signed <-
        submitExpectAccepted env (signTx genesisSignKey handFresh)
    let size = txSizeBytes signed
    emitMeasure env "CG10-control" mem cpu size
    rowCommit env cage "cg10-key-c" edgeInsertAbsent
    emit
        "control"
        "CG10 control: the same request folded against the live root \
        \is accepted — the refusal is the staleness, not the shape"

{- | CG11: Empty fold (R8_empty_fold_refused; expected consumer gap,
cardano-mpfs-onchain#100). A Modify over no requests, no actions,
unchanged root, in a registry of its own — the accepted candidate REFUSES
it (registry/modify.ak `empty-fold`). The refusal is compared with the
model's @foldBatch@ question over no request, which refuses it for
@empty-fold@, and the reason the traced replay admits for the state script
must be that same reason; the comparison joins the row's receipt. The
control is a nonempty fold on the same path that accepts, proving the
refusal is specific to the empty batch. The consumer's requirement stays
held pending Q-002, never a pass.
-}
runCG11 :: Env -> IO ()
runCG11 env = do
    writeIORef (envLiveRecords env) []
    live <- newLiveState "CG11"
    cage <- ensureRowCage env "cg11" 30_000 30_000
    let cfg = rcCfg cage
    tid <- cageTid cage
    state <- cageStateUtxo env cage
    oldState <- extractState (snd state)
    pot <- collateralPot env
    units <- declaredSpec env cage
    let emptySpec =
            ( rowSpec
                cage
                tid
                state
                []
                []
                (Root (unOnChainRoot (stateRoot oldState)))
                units
            )
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
    let signedWitnessed = signTx genesisSignKey hand
        signed = signedTx signedWitnessed
    result <- submitTxResilient (envSubmit env) signedWitnessed
    compared <- compareHandBatch env live cage Live.Fold [] signed result
    case result of
        Rejected reason ->
            attributeSubmitRefusal
                env
                "CG11"
                HeldQ002
                (stateMarkerOf cfg)
                (T.unpack (TE.decodeUtf8Lenient reason))
                (txIdHex signed)
        Submitted txid ->
            failWith
                ( "CG11 FINDING: the node ACCEPTED the empty fold the model "
                    <> "refuses (txid "
                    <> txInHex txid
                    <> ") — reported, not relabelled"
                )
    addReceiptSteps env "CG11" [compared]
    require
        "CG11: the model and the chain do not agree on the empty fold"
        (agreed compared)
    recordHold
        env
        "CG11"
        "Q-002 (story 2)"
        ( "Singular's Lean refuses the empty fold for empty-fold "
            <> "(foldBatch over no request), the reason the traced replay "
            <> "admits for the state script"
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
            ( rowSpec
                cage
                tid
                stateC
                [req]
                [Update stepsC]
                rootC
                unitsC
            )
                { fsCollateral = Just potC
                }
    ctrlTx <- assembleFoldWithFee env ctrlSpec
    (memC, cpuC) <- measureUnits env ctrlTx
    signedC <-
        submitExpectAccepted env (signTx genesisSignKey ctrlTx)
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
The model takes no action list, so neither refusal has a model reason to
compare: the model comparison is unmet (#345).
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
            ( rowSpec
                cage
                tid
                state
                [req]
                [Update steps12, Update []]
                root12
                units
            )
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
        ( "Singular's Lean takes no action list (its step and foldBatch "
            <> "consume requests only), so it gives no reason to compare: the "
            <> "model comparison is unmet (#345); the chain's reason is the "
            <> "traced replay's"
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
            ( rowSpec
                cage
                tid
                state2
                [firstSorted2, secondSorted2]
                [Update firstSteps]
                rootFirst
                units
            )
                { fsCollateral = Just pot2
                }
    ctrlTx <- assembleFoldWithFee env deficitSpec
    emit
        "row"
        "CG12 control: two requests, one action — the deficit must be \
        \refused"
    submitExpectRefusedControl
        env
        "CG12"
        AgreesWithModel
        (stateMarkerOf cfg)
        ctrlTx
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
            ( rowSpec
                cage
                tid
                state3
                [reqD]
                [Update stepsD]
                rootD
                units
            )
                { fsCollateral = Just pot3
                , -- The refusal rows only reach their refusal; this one runs
                  -- the fold to the end, minting and locking custody.
                  fsUnits = ExUnits 2_000_000 800_000_000
                }
    exactTx <- assembleFoldWithFee env exactSpec
    (memD, cpuD) <- measureUnits env exactTx
    signedD <-
        submitExpectAccepted env (signTx genesisSignKey exactTx)
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
    unsigned <-
        Cage.withView prov $ \v -> do
            ctx <- rowRegistryContext env v cage tid
            updateTokenWithDuties cfg v (envTm env) tid genesisAddr ctx
    evalMap <-
        Cage.withView (envProv env) (`Cage.viewEvaluateTx` unsigned)
    mapM_
        ( \(p, r) ->
            emit
                "diag"
                (show p <> " => " <> either show (\(ExUnits m c) -> show (m, c)) r)
        )
        (Map.toList evalMap)
    (mem, cpu) <- measureUnits env unsigned
    writeIORef (rcUnits cage) (mem, cpu)
    signed <- submitExpectAccepted env (signTx genesisSignKey unsigned)
    let size = txSizeBytes signed
    emitMeasure env "CG14-hook-fold" mem cpu size
    writeRowReceipt
        env
        "CG14"
        Accepted
        AgreesWithModel
        [txIdHex signed]
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
            ( rowSpec
                cage
                tid
                state
                [reqB]
                [Update stepsB]
                rootB
                units
            )
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
    submitExpectRefusedControl
        env
        "CG14"
        AgreesWithModel
        (stateMarkerOf cfg)
        ctrlTx
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
            ( rowSpec
                cage
                tid
                state
                [req]
                [Update steps15]
                root15
                units
            )
                { fsCollateral = Just pot
                }
    hand <- assembleFoldWithFee env spec
    emit
        "row"
        "CG15: the hook is set but the fold carries no withdrawal; \
        \the state script must refuse"
    submitExpectRefused
        env
        "CG15"
        AgreesWithModel
        (stateMarkerOf cfg)
        hand
    -- Control: the library fold carries the withdrawal; it consumes
    -- this request and CG14's parked control request together.
    libFold <-
        Cage.withView prov $ \v -> do
            ctx <- rowRegistryContext env v cage tid
            updateTokenWithDuties cfg v (envTm env) tid genesisAddr ctx
    (mem, cpu) <- measureUnits env libFold
    signed <- submitExpectAccepted env (signTx genesisSignKey libFold)
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
    writeIORef (envLiveRecords env) []
    live <- newLiveState "CG19"
    cage <- ensureRowCage env "cg19" 30_000 30_000
    let cfg = rcCfg cage
    tid <- cageTid cage
    (sk2, addr2) <- secondWallet env
    -- The first owner is not the genesis wallet a fold returns its change
    -- to, so the outputs crediting each owner are exactly its refunds.
    (sk3, addr3) <- ownerWallet env 25_000_000
    let Coin tip = defaultTip cfg
    -- #157 A-009: both bookings are edges, each binding the address its
    -- own payer gets the deposit back at, and the bonds stay unequal so
    -- the row still has two different amounts to cross.
    destA <- edgeDestinationFor env addr3 edgeInsertAbsent
    reqA <-
        bookEdge
            env
            cfg
            tid
            addr3
            sk3
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
    -- The fold is placed after every request's retract window has closed,
    -- where this row has always rejected: it waits for the last of them and
    -- declares a lower bound past it.
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
    lowerSlot <-
        Cage.withView
            (envProv env)
            (`Cage.viewPosixMsCeilSlot` (deadline + 1000))
    pot <- collateralPot env
    units <- declaredSpec env cage
    let crossedSpec =
            ( rowSpec
                cage
                tid
                state
                sorted
                [CageTypes.Rejected, CageTypes.Rejected]
                newRoot
                units
            )
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
    let signedCrossedWitnessed = signTx genesisSignKey hand
        signedCrossed = signedTx signedCrossedWitnessed
    crossResult <-
        submitTxResilient (envSubmit env) signedCrossedWitnessed
    let owned =
            [ (Live.EdgeRequest Live.InsertAbsent "cg19-key-a" addr3, addr3, reqA)
            , (Live.EdgeRequest Live.InsertAbsent "cg19-key-b" addr2, addr2, reqB)
            ]
    crossed <-
        compareHandBatch
            env
            live
            cage
            Live.Reject
            owned
            signedCrossed
            crossResult
    case crossResult of
        Submitted txid ->
            failWith
                ( "CG19 FINDING: the chain ACCEPTED crossed refunds (bonds 5 ada "
                    <> "and 3 ada refunded "
                    <> show c1
                    <> " and "
                    <> show c2
                    <> " lovelace; tx="
                    <> txInHex txid
                    <> ") that the model's reject batch refuses — reported, "
                    <> "not relabelled"
                )
        Rejected reason -> do
            attributeSubmitRefusal
                env
                "CG19"
                HeldQ002
                (stateMarkerOf cfg)
                (T.unpack (TE.decodeUtf8Lenient reason))
                (txIdHex signedCrossed)
            addReceiptSteps env "CG19" [crossed]
            require
                "CG19: the model and the chain do not agree on the crossed refunds"
                (agreed crossed)
            recordHold
                env
                "CG19"
                "Q-002 (story 2)"
                ( "Singular's Lean refuses the crossed refunds: its reject "
                    <> "batch owes each owner its deposit back and the first "
                    <> "is paid short, deposit-returned, the reason the traced "
                    <> "replay admits for the state script"
                )
                "R11 — action-dependent routing (E18 disposition): processed Update value routes to the checkpoint/consumer hook (Update contributes no Rejected-owner obligations); Rejected owes input-tip per owner under a no-underpayment floor (upstream cardano-mpfs-onchain#101 is the partition fix)"
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
                    ( rowSpec
                        cage
                        tid
                        state
                        sorted
                        [CageTypes.Rejected, CageTypes.Rejected]
                        newRoot
                        units
                    )
                        { fsCollateral = Just potA
                        , fsRefunds = honest
                        , fsLower = Just lowerSlot
                        , -- The refusal leg only reaches its refusal; this
                          -- one runs the fold to the end.
                          fsUnits = ExUnits 2_000_000 800_000_000
                        }
            acceptTx <- assembleFoldWithFee env acceptSpec
            (memA, cpuA) <- measureUnits env acceptTx
            signedA <-
                submitExpectAccepted env (signTx genesisSignKey acceptTx)
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
    runCG19RejectedFloor env live cage tid (sk2, addr2) (sk3, addr3)

{- | CG19-rejected-floor control (NOTE-073/074/077/080/181, E18 disposition):
the Rejected-action refund floor as a separately named
instrument. Phase-3 Rejected pair: underpaying one owner below
input-tip refuses (state script); funding both at/above accepts.
Owner obligations derive by pairing the actual Rejected actions
with their matching request datums/token in sorted consumed
order and are asserted nonempty with the actual pair length
before any destructure. Owed is input-tip with no fee share;
funding pays fees separately. Both legs share
requests/actions/order/phase/Hook; collateral/funding/timing
freshness necessarily differs and is recorded as such. Evidence
travels in control-CG19-rejected-floor.json (not a row receipt).
Must not imply processed value returns to owners.
-}
runCG19RejectedFloor
    :: Env
    -> LiveState
    -> RowCage
    -> TokenId
    -> (SignKeyDSIGN Ed25519DSIGN, Addr)
    -> (SignKeyDSIGN Ed25519DSIGN, Addr)
    -> IO ()
runCG19RejectedFloor env live cage tid (skR2, addrR2) (skR3, addrR3) = do
    let cfg = rcCfg cage
        prov = envProv env
    (reqRa, outRa) <-
        paddedRequest
            env
            cage
            addrR3
            skR3
            "cg19-rej-a"
            "cg19-rej-va"
            5_000_000
    (reqRb, outRb) <-
        paddedRequest
            env
            cage
            addrR2
            skR2
            "cg19-rej-b"
            "cg19-rej-vb"
            3_000_000
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
                pure
                    (reqIn, reqOut, hex (extractOwnerBytes reqOut), owed, requestKey rq)
            _ ->
                failWith
                    "CG19-rejected-floor: unmatched action/datum pair (want Rejected over RequestDatum)"
    matched <- mapM matchObligation (zip sortedReqs actions)
    let obligations = [(owner, owed) | (_, _, owner, owed, _) <- matched]
    require
        "CG19-rejected-floor: owner obligations empty"
        (not (null obligations))
    require
        "CG19-rejected-floor: expected a pair of obligations"
        (length obligations == 2)
    [(_, _, _, owed1, _), (_, _, _, owed2, _)] <- case matched of
        pair@[_, _] -> pure pair
        _ ->
            failWith
                "CG19-rejected-floor: pair destructure failed after length check"
    emit
        "control"
        ("CG19-rejected-floor: obligations " <> show obligations)
    -- Phase-3 wait: past the latest request deadline.
    submittedAts <- mapM (submittedAtDatum . snd) sortedReqs
    let deadline =
            maximum submittedAts
                + stateProcessTime oldState
                + stateRetractTime oldState
    waitPhase3 deadline
    lowerSlot <-
        Cage.withView prov (`Cage.viewPosixMsCeilSlot` (deadline + 1000))
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
    upperU <-
        Cage.withView
            prov
            (\v -> trySlots v [nowMsU + 2_000, nowMsU + 1_500, nowMsU + 1_000])
    underTx <-
        assembleFoldWithFee
            env
            (baseSpec state matchedReqs [owed1 - 1000, owed2] pot lowerSlot upperU)
    let signedUnderWitnessed = signTx genesisSignKey underTx
        signedUnder = signedTx signedUnderWitnessed
    underResult <- submitTxResilient (envSubmit env) signedUnderWitnessed
    underCompared <-
        compareHandBatch
            env
            live
            cage
            Live.Reject
            [
                ( Live.EdgeRequest Live.InsertAbsent "cg19-rej-a" addrR3
                , addrR3
                , (reqRa, outRa)
                )
            ,
                ( Live.EdgeRequest Live.InsertAbsent "cg19-rej-b" addrR2
                , addrR2
                , (reqRb, outRb)
                )
            ]
            signedUnder
            underResult
    require
        "CG19-rejected-floor: the model and the chain do not agree on the underpaid reject"
        (agreed underCompared)
    underReason <- case underResult of
        Rejected reason -> pure (T.unpack (TE.decodeUtf8Lenient reason))
        Submitted txid ->
            failWith
                ( "CG19-rejected-floor FINDING: underpaid leg ACCEPTED (txid "
                    <> txInHex txid
                    <> ") — reported, not relabelled"
                )
    traced <-
        tracedRefusal env (stateMarkerOf cfg) (txIdHex signedUnder)
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
            traced
    case underAttr of
        Right () -> pure ()
        Left mismatch ->
            failWith
                ( "CG19-rejected-floor: underpaid refusal did not attribute: "
                    <> show mismatch
                )
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
    upperO <-
        Cage.withView
            prov
            (\v -> trySlots v [nowMsO + 2_000, nowMsO + 1_500, nowMsO + 1_000])
    overTx <-
        assembleFoldWithFee
            env
            (baseSpec state2 matchedReqs [owed1, owed2] pot2 lowerSlot upperO)
    (memO, cpuO) <- measureUnits env overTx
    signedO <-
        submitExpectAccepted env (signTx genesisSignKey overTx)
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
                            .= ( "no named validator branch in this compiled trace; attribution is script hash plus phase-2 only"
                                    :: Text
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
                    .= ( "same rejected requests/actions/order/phase/Hook; allocation differs (underpaid vs exact owed); fresh collateral, separate funding and per-leg near-now validity bounds necessarily differ"
                            :: Text
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
Each request runs through the same builder and driver comparison. Last, two
registrations are folded in one transaction that mints both tokens at the first
key, asked of the model's fold batch question; the chain and the model must each
refuse it, for the same reason. The receipt records the seven steps and the
batch, with their chain outcomes.
-}
runCG21 :: Env -> IO ()
runCG21 env = do
    either
        failWith
        pure
        ( Live.validateLive
            ( RegistrationStory.story
                (Live.Context "registration" "recipient wallet")
            )
        )
    writeIORef (envLiveRecords env) []
    writeIORef (envLiveMeasurements env) []
    control <- lookupEnv "CONFORMANCE_STORY_CONTROL"
    require
        "unknown registration story control"
        ( control
            `elem` [ Nothing
                   , Just "wrong-fee"
                   , Just "wrong-timing"
                   , Just "wrong-delivery"
                   , Just "unknown-identity"
                   ]
        )
    registry <- ensureRowCage env "story-registration" 30_000 30_000
    (_, recipient) <- secondWallet env
    _ <-
        runLive
            env
            (RegistrationStory.story (Live.Context registry recipient))
    -- The generic interpreter writes one record per request. The receipt is
    -- emitted only after all seven outcomes and comparisons have completed.
    records <- readIORef (envLiveRecords env)
    require
        "CG21 did not compare its seven requests and its batch"
        (length records == 8)
    require
        "registration chapter has a disagreement or unsupported step"
        ( all
            ( \case
                Object fields -> KM.lookup "comparison" fields == Just (String "agrees")
                _ -> False
            )
            records
        )
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
    either
        failWith
        pure
        ( Live.validateLive
            ( RetirementStory.story
                (Live.Context "retirement" "holder wallet")
                (Live.Context "comparison" "holder wallet")
            )
        )
    writeIORef (envLiveRecords env) []
    writeIORef (envLiveMeasurements env) []
    control <- lookupEnv "CONFORMANCE_STORY_CONTROL"
    require
        "unknown retirement story control"
        ( control
            `elem` [ Nothing
                   , Just "wrong-fee"
                   , Just "wrong-timing"
                   , Just "wrong-delivery"
                   , Just "unknown-identity"
                   ]
        )
    registry <- ensureRowCage env "story-retirement" 30_000 30_000
    comparison <-
        ensureRowCage env "story-unknown-key comparison" 30_000 30_000
    _ <- largestWalletUtxo (envProv env)
    _ <-
        runLive
            env
            ( RetirementStory.story
                (Live.Context registry genesisAddr)
                (Live.Context comparison genesisAddr)
            )
    records <- readIORef (envLiveRecords env)
    require
        "CG22 did not compare its eleven requests"
        (length records == 11)
    require
        "retirement chapter has a disagreement or unsupported step"
        ( all
            ( \case
                Object fields -> KM.lookup "comparison" fields == Just (String "agrees")
                _ -> False
            )
            records
        )
    writeStoryReceipt env "CG22" records

-- ---------------------------------------------------------
-- CG23 (#258): requests that leave the queue unfolded
-- ---------------------------------------------------------

{- | CG23: a request that is never folded, in two registries of its own: one
whose rejects are placed after their owner's retraction window, which closes a
second after it opens,
where a reject refunding the owner one lovelace short and to another address is
refused before the untampered reject; and one whose requests stay retractable
for thirty seconds, where the owner's return one lovelace short, to another
address, bound to another output reference and beside a spent state are
refused, as are a retraction of an update and one missing the owner's signature,
before the owner-signed retraction of that same insertion request.

The exits are a row of their own so that each chapter's receipt stays under
the bound every receipt is written under.
-}
runCG23 :: Env -> IO ()
runCG23 env = do
    either
        failWith
        pure
        ( Live.validateLive
            ( ExitStory.story
                (Live.Context "rejection" "holder wallet")
                (Live.Context "retraction" "holder wallet")
            )
        )
    writeIORef (envLiveRecords env) []
    writeIORef (envLiveMeasurements env) []
    control <- lookupEnv "CONFORMANCE_STORY_CONTROL"
    require
        "unknown exit story control"
        ( control
            `elem` [ Nothing
                   , Just "wrong-fee"
                   , Just "wrong-timing"
                   , Just "wrong-delivery"
                   , Just "unknown-identity"
                   , Just "signed-owner"
                   ]
        )
    rejection <- ensureRowCage env "story-rejection" 1_000 1_000
    retraction <- ensureRowCage env "story-retraction" 1_000 30_000
    _ <- largestWalletUtxo (envProv env)
    _ <-
        runLiveNamed
            env
            "CG23"
            []
            ( ExitStory.story
                (Live.Context rejection genesisAddr)
                (Live.Context retraction genesisAddr)
            )
    records <- readIORef (envLiveRecords env)
    require "CG23 did not compare its ten requests" (length records == 10)
    require
        "exit chapter has a disagreement or unsupported step"
        ( all
            ( \case
                Object fields -> KM.lookup "comparison" fields == Just (String "agrees")
                _ -> False
            )
            records
        )
    writeStoryReceipt env "CG23" records

{- | CG05: an insertion on a key the registry already holds, in a registry of
its own. Two accepted requests make the key active — the state the shared
session key is in when this row follows CG02 — and are compared with the
model; the same insertion on that key is then submitted, and the ledger and
the model must both refuse it. The receipt records the three steps.
-}
runCG05 :: Env -> IO ()
runCG05 env = do
    either
        failWith
        pure
        ( Live.validateLive
            (OccupiedStory.story (Live.Context "occupied insert" "holder wallet"))
        )
    writeIORef (envLiveRecords env) []
    writeIORef (envLiveMeasurements env) []
    registry <- ensureRowCage env "occupied-insert" 30_000 30_000
    _ <-
        runLive env (OccupiedStory.story (Live.Context registry genesisAddr))
    records <- readIORef (envLiveRecords env)
    require
        "CG05 did not compare its three requests"
        (length records == 3)
    require
        "occupied-key insertion has a disagreement or unsupported step"
        ( all
            ( \case
                Object fields -> KM.lookup "comparison" fields == Just (String "agrees")
                _ -> False
            )
            records
        )
    writeStoryReceipt env "CG05" records

{- | CG24 (#320): a folder rejects a pending request before its owner's
retraction deadline. Two insertion requests are booked together in a registry
of their own. The first is rejected while it can still be folded, the second
while its owner can still retract it; in each window a reject refunding the
owner one lovelace short and one refunding another key are refused before the
untampered reject of the same request. A processing and a retraction window of
two minutes each leave time for three rejects inside each.
-}
runCG24 :: Env -> IO ()
runCG24 env = do
    either
        failWith
        pure
        ( Live.validateLive
            ( EarlyRejectStory.story
                (Live.Context "early rejection" "holder wallet")
            )
        )
    writeIORef (envLiveRecords env) []
    writeIORef (envLiveMeasurements env) []
    cage <- ensureRowCage env "story-early-rejection" 120_000 120_000
    let (first, second) = EarlyRejectStory.requests genesisAddr
    _ <-
        runLiveNamed
            env
            "CG24"
            [(cage, first), (cage, second)]
            (EarlyRejectStory.story (Live.Context cage genesisAddr))
    records <- readIORef (envLiveRecords env)
    require "CG24 did not compare its six requests" (length records == 6)
    require
        "early rejection chapter has a disagreement or unsupported step"
        ( all
            ( \case
                Object fields -> KM.lookup "comparison" fields == Just (String "agrees")
                _ -> False
            )
            records
        )
    writeStoryReceipt env "CG24" records

{- | An unnamed seven-edge program using exactly the chapter interpreter.
The receipt is required by the running book before it renders success.
-}
runSequence :: Env -> IO ()
runSequence env = do
    either
        failWith
        pure
        ( Live.validateLive
            ( SequenceStory.story
                (Live.Context "sequence" "holder wallet")
            )
        )
    writeIORef (envLiveRecords env) []
    writeIORef (envLiveMeasurements env) []
    registry <- ensureRowCage env "unnamed-sequence" 30_000 30_000
    _ <-
        runLive env (SequenceStory.story (Live.Context registry genesisAddr))
    records <- readIORef (envLiveRecords env)
    require
        "unnamed sequence has no compared requests"
        (not (null records))
    require
        "unnamed sequence did not report the required edge outcomes"
        (all expectedSequenceOutcome records)
    writeStoryReceipt env "sequence" records
  where
    expectedSequenceOutcome (Object fields) =
        case (KM.lookup "edge" fields, KM.lookup "comparison" fields) of
            (Just (String edge), Just (String "agrees")) ->
                edge
                    `elem` [ "insertAbsent"
                           , "insertActive"
                           , "updateActive"
                           , "updateTerminal"
                           , "deleteAbsent"
                           , "deleteActive"
                           , "witnessTerminal"
                           ]
            _ -> False
    expectedSequenceOutcome _ = False

{- | The batch harness (#344): the story language's two batch instructions,
executed on the devnet — a fold of two registrations in one transaction, then a
reject of two more in one transaction while they can still be folded — and each
asked of the model's matching batch question through the transport. It belongs
to no requirement and its receipt is read by no row. Both batches are lawful, so
it requires that both ran and that the chain and the model each accepted each
one.
-}
runBatchHarness :: Env -> IO ()
runBatchHarness env = do
    either
        failWith
        pure
        (Live.validateLive (batchStory (Live.Context "batch" "holder wallet")))
    writeIORef (envLiveRecords env) []
    registry <- ensureRowCage env "batch-harness" 30_000 30_000
    _ <- runLive env (batchStory (Live.Context registry genesisAddr))
    records <- readIORef (envLiveRecords env)
    require
        "batch harness did not run both batch instructions"
        (map (field "batch") records == [Just "foldBatch", Just "rejectBatch"])
    -- The story is lawful, so each side must accept each batch on its own:
    -- agreement alone would pass a lawful batch both sides refused.
    require
        "batch harness: the chain refused a lawful batch"
        (all ((== Just "accepted") . outcome "chain") records)
    require
        "batch harness: the model refused a lawful batch"
        (all ((== Just "accepted") . outcome "model") records)
    require
        "batch harness: the chain and the model disagree on a batch's outcome"
        (all ((== Just "agrees") . field "comparison") records)
  where
    batchStory (Live.Context registry holder) = do
        _ <-
            Live.foldBatch
                registry
                [ Live.EdgeRequest Live.InsertActive "batch-folded-one" holder
                , Live.EdgeRequest Live.InsertActive "batch-folded-two" holder
                ]
        _ <-
            Live.rejectBatchWithin
                Live.InProcessingWindow
                registry
                [ Live.EdgeRequest Live.InsertActive "batch-rejected-one" holder
                , Live.EdgeRequest Live.InsertActive "batch-rejected-two" holder
                ]
        pure ()
    field name (Object fields) = case KM.lookup name fields of
        Just (String text) -> Just text
        _ -> Nothing
    field _ _ = Nothing
    outcome side (Object fields) = KM.lookup side fields >>= field "outcome"
    outcome _ _ = Nothing

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
capturePreProofKey
    :: Env -> ByteString -> IO (MPFProof MPFHash, OnChainRoot)
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

{- | Wait until two seconds past the given deadline ms (after the windows,
where these rows place their Rejected folds), sleeping exactly the
remaining time. A deadline more than a hundred seconds away fails closed
rather than submitting a transaction outside that placement.
-}
waitPhase3 :: Integer -> IO ()
waitPhase3 deadline = do
    now <- currentPosixMs
    let remaining = deadline + 2001 - now
    when (remaining > 100_000) $
        failWith
            "phase-3 wait timed out; refusing to submit a wrong-phase fold"
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

-- | Whether a compared record found the model and the chain to agree.
agreed :: Value -> Bool
agreed = \case
    Object fields -> KM.lookup "comparison" fields == Just (String "agrees")
    _ -> False
