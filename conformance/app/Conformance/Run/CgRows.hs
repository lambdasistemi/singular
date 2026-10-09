{-# LANGUAGE LambdaCase #-}

{- |
Module      : Conformance.Run.CgRows
Description : The registry rows' programs and the rows outside the model, on a devnet
License     : Apache-2.0

Every registry row with a program ("Conformance.Edge.Programs") runs through
'runProgram': its registries booted fresh, its wallets funded, its cohort
booked, its story interpreted by the generic live interpreter, each compared
record held to what the program expects, and one receipt written whose verdict
the program's standing gives. Two rows the model cannot express still run for
their chain evidence, each through its own runner: fold-against-superseded-root, a fold against a
superseded root, and surplus-fold-actions, a fold whose actions do not pair with its requests.
The batch harness executes the story language's batch instructions and belongs
to no row.
-}
module Conformance.Run.CgRows
    ( runProgram
    , runFoldAgainstSupersededRoot
    , runSurplusFoldActions
    , runBatchHarness
    ) where

import Conformance.Edge.Programs
    ( Expected (..)
    , Program (..)
    , Registry (..)
    , Standing (..)
    , Wallet (..)
    , WalletRole (..)
    , displayStory
    )
import Conformance.Run.Book
import Conformance.Run.Cage
import Conformance.Run.Environment
import Conformance.Run.Fold
import Conformance.Run.Live
import Conformance.Run.Observe
import Conformance.Run.Receipts
import Conformance.Run.Submit
import Conformance.Run.Units
import Conformance.Run.Wallet

import Cardano.Ledger.Address (Addr)
import Cardano.Node.Client.E2E.Setup (Ed25519DSIGN, SignKeyDSIGN)
import Conformance.Story.Live qualified as Live

import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KM
import Data.Foldable (toList)
import Data.IORef (readIORef, writeIORef)
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import System.Environment (lookupEnv)

import Singular.Registry.Ledger (ExUnits (..))
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.Signing (signTx)
import Singular.Registry.TxBuilder.Internal
    ( extractCageDatum
    , leafActive
    )
import Singular.Registry.TxBuilder.Update (updateTokenWithDuties)
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRequest (..)
    , RequestAction (Update)
    , edgeInsertActive
    )

import Conformance.Mirror
    ( emit
    , failWith
    , require
    , txIdHex
    )
import Conformance.Receipt (Verdict (..))

{- | Run one row's program on the devnet and write its receipt. The program is
validated over its display handles before anything is submitted; every record
the interpreter compares is held to the program's expectation for it, in order;
the receipt's verdict follows the row's standing, and a held or unmet row is
recorded as such, so the session cannot end as a pass while it stands.
-}
runProgram :: Env -> Program -> IO ()
runProgram env program = do
    let row = programRow program
    either failWith pure (displayStory program >>= Live.validateLive)
    writeIORef (envLiveRecords env) []
    writeIORef (envLiveMeasurements env) []
    control <- lookupEnv "CONFORMANCE_STORY_CONTROL"
    require
        ("unknown story control for " <> row)
        (maybe True (`elem` programControls program) control)
    cages <-
        mapM
            ( \registry ->
                ensureRowCage
                    env
                    (registryName registry)
                    (registryProcessingMs registry)
                    (registryRetractionMs registry)
            )
            (programRegistries program)
    wallets <- mapM (walletOf env . walletRole) (programWallets program)
    let addresses = map snd wallets
    cohort <- either failWith pure (programCohort program cages addresses)
    story <- either failWith pure (programStory program cages addresses)
    _ <-
        runLiveNamed
            env
            row
            cohort
            [(address, key) | (key, address) <- wallets]
            story
    records <- readIORef (envLiveRecords env)
    let expected = programExpected program
    require
        ( row
            <> " compared "
            <> show (length records)
            <> " records, its program expects "
            <> show (length expected)
        )
        (length records == length expected)
    mapM_ (expect row) (zip3 [0 :: Int ..] expected records)
    writeStoryReceipt
        env
        (T.pack row)
        (verdictOf (programStanding program))
        records
    case programStanding program of
        Agreement -> pure ()
        Held holdId lean consumer -> recordHold env row holdId lean consumer
        Unmet ruling registry consumer -> recordUnmet env row ruling registry consumer

-- | The verdict a row's receipt carries for its standing.
verdictOf :: Standing -> Verdict
verdictOf = \case
    Agreement -> AgreesWithModel
    Held{} -> HeldQ002
    Unmet{} -> UnmetByRuling

-- | The wallet of the run a program's wallet is, with its signing key.
walletOf
    :: Env -> WalletRole -> IO (SignKeyDSIGN Ed25519DSIGN, Addr)
walletOf env = \case
    RunnerWallet -> pure (genesisSignKey env, genesisAddr env)
    SecondWallet -> secondWallet env
    OwnerWallet funding -> ownerWallet env funding

{- | Hold one compared record to what its program expects: agreement, or the
recorded divergence with its outcomes and the reason the traced replay admits
for the chain, logged as a known divergence and never a pass.
-}
expect :: String -> (Int, Expected, Value) -> IO ()
expect row (index, expected, record) = case expected of
    Agrees ->
        require
            (row <> " record " <> show index <> " does not agree with the model")
            (field ["comparison"] record == Just (String "agrees"))
    Diverges
        { divergenceChain
        , divergenceModel
        , divergenceTrace
        , divergenceIssue
        } -> do
            require
                ( row
                    <> " record "
                    <> show index
                    <> " did not come out as the recorded divergence ("
                    <> T.unpack divergenceIssue
                    <> ")"
                )
                ( field ["comparison"] record == Just (String "disagrees")
                    && field ["chain", "outcome"] record == Just (String divergenceChain)
                    && field ["model", "outcome"] record == Just (String divergenceModel)
                    && divergenceTrace `elem` replayReasons record
                )
            emit
                "divergence"
                ( row
                    <> " KNOWN DIVERGENCE ("
                    <> T.unpack divergenceIssue
                    <> "): the chain "
                    <> T.unpack divergenceChain
                    <> " it for "
                    <> T.unpack divergenceTrace
                    <> " (tx="
                    <> maybe "?" T.unpack (text ["chain", "txid"] record)
                    <> ") and the model "
                    <> T.unpack divergenceModel
                    <> " it; recorded, never a pass"
                )
  where
    field [] value = Just value
    field (key : path) (Object fields) = KM.lookup key fields >>= field path
    field _ _ = Nothing
    text path value = case field path value of
        Just (String t) -> Just t
        _ -> Nothing
    replayReasons value = case field ["chain", "refusal", "replay"] value of
        Just (Array entries) ->
            [ reason
            | entry <- toList entries
            , Just reason <- [text ["reason"] entry]
            ]
        _ -> [] :: [Text]

{- | fold-against-superseded-root: Stale fold against a superseded root
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
runFoldAgainstSupersededRoot :: Env -> IO ()
runFoldAgainstSupersededRoot env = do
    cage <- ensureRowCage env "cg-main" 30_000 30_000
    let cfg = rcCfg cage
    tid <- cageTid cage
    -- The stale claims: k-c's insertion proof against the pre-fold
    -- (empty) root, captured before any fold advances it.
    (staleSteps, staleRoot) <-
        speculativeInsert env cage tid "cg10-key-c" leafActive
    _ <-
        rowRequestAndFold
            env
            cage
            "fold-against-superseded-root"
            "cg10-key-a"
            "cg10-value-a"
            edgeInsertActive
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
        ( "fold-against-superseded-root: fold carrying proof steps captured against the \
          \superseded root submitted; the state script must refuse "
            <> "(R7_stale_fold_refused)"
        )
    submitExpectRefused
        env
        "fold-against-superseded-root"
        UnmetByRuling
        (stateMarkerOf cfg)
        staleTx
    recordUnmet
        env
        "fold-against-superseded-root"
        "kept unmet by operator ruling 2026-10-02 (narrowed #287; model follow-up lambdasistemi/singular#346)"
        ( "Singular's Lean takes no proof and no authenticated root and "
            <> "admits the insertion on that unoccupied key, so it gives no "
            <> "reason to compare with the chain's"
        )
        "R7_stale_fold_refused — a fold against a superseded root is refused; the chain refuses it, the model comparison stays unmet"
    -- Control: the same request folded against the live root, the
    -- hand shape calibrated against the library fold.
    libFold <-
        Cage.withLatest (envProv env) $ \v -> do
            ctxLive <- rowRegistryContext env v cage tid
            updateTokenWithDuties
                cfg
                v
                (envTm env)
                tid
                (genesisAddr env)
                ctxLive
    (freshSteps, freshRoot) <-
        speculativeInsert env cage tid "cg10-key-c" leafActive
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
    emit
        "calibration"
        "fold-against-superseded-root control: hand model matches the library fold"
    (mem, cpu) <- measureUnits env handFresh
    signed <-
        submitExpectAccepted env (signTx (genesisSignKey env) handFresh)
    let size = txSizeBytes signed
    emitMeasure env "fold-against-superseded-root-control" mem cpu size
    rowCommit env cage "cg10-key-c" edgeInsertActive
    emit
        "control"
        "fold-against-superseded-root control: the same request folded against the live root \
        \is accepted — the refusal is the staleness, not the shape"

{- | surplus-fold-actions: Surplus actions beyond the matched request inputs (the
2026-09-03 audit; upstream cardano-mpfs-onchain#100). The accepted
candidate REFUSES the surplus tail (state.ak validModify `expect
actionsTail == []`): every supplied action must pair with an actual
matching request. The held observation is the attributed refusal.
The controls: one action FEWER than there are requests is refused
(the deficit), and an exact 1:1 fold on the same path accepts —
proving exact pairing is enforced both directions and the refusals
are specific. Row contract is observe-and-report; recorded unmet
by ruling (2026-10-02), never a pass.
The model takes no action list, so neither refusal has a model reason to
compare: the model comparison is unmet (#345).
-}
runSurplusFoldActions :: Env -> IO ()
runSurplusFoldActions env = do
    cage <- ensureRowCage env "cg-main" 30_000 30_000
    let cfg = rcCfg cage
    tid <- cageTid cage
    req <-
        rowRequestInsert env cage "cg12-key" "cg12-value"
    (steps12, root12) <-
        speculativeInsert env cage tid "cg12-key" leafActive
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
        "surplus-fold-actions: submitting the surplus fold for its candidate-bound observation"
    submitExpectRefused
        env
        "surplus-fold-actions"
        UnmetByRuling
        (stateMarkerOf cfg)
        hand
    recordUnmet
        env
        "surplus-fold-actions"
        "kept unmet by operator ruling 2026-10-02 (narrowed #287; model follow-up lambdasistemi/singular#345)"
        ( "Singular's Lean takes no action list (its step and foldBatch "
            <> "consume requests only), so it gives no reason to compare; the "
            <> "chain's reason is the traced replay's"
        )
        ( "one action per request, no surplus — the consumer audit's "
            <> "finding (upstream cardano-mpfs-onchain#100 is the "
            <> "partition fix)"
        )
    emit
        "row"
        ( "surplus-fold-actions: the chain REFUSED a fold with a surplus action (one "
            <> "request, two actions) — recorded, unmet by ruling (#345), "
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
        _ ->
            failWith "surplus-fold-actions control: expected exactly two requests"
    (firstSteps, rootFirst) <- case extractCageDatum (snd firstSorted) of
        Just (RequestDatum rq)
            | requestEdge rq == edgeInsertActive ->
                speculativeInsert env cage tid (requestKey rq) leafActive
        Just (RequestDatum _) ->
            failWith
                "surplus-fold-actions control: expected an insertActive request"
        _ -> failWith "surplus-fold-actions control: no request datum"
    pot2 <- collateralPot env
    let (firstSorted2, secondSorted2) = case sortOn fst [reqB, reqC] of
            [a, b] -> (a, b)
            _ -> error "surplus-fold-actions control: exactly two requests"
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
        "surplus-fold-actions control: two requests, one action — the deficit must be \
        \refused"
    submitExpectRefusedControl
        env
        "surplus-fold-actions"
        AgreesWithModel
        (stateMarkerOf cfg)
        ctrlTx
    emit
        "control"
        "surplus-fold-actions control: the deficit is refused; the surplus is refused — \
        \exact pairing is enforced both directions"
    -- Accepting control: one fresh request, exactly one action — the
    -- same path accepts. A refusal is only informative next to an
    -- acceptance.
    reqD <-
        rowRequestInsert env cage "cg12-key-d" "cg12-value-d"
    state3 <- cageStateUtxo env cage
    (stepsD, rootD) <-
        speculativeInsert env cage tid "cg12-key-d" leafActive
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
        submitExpectAccepted env (signTx (genesisSignKey env) exactTx)
    let sizeD = txSizeBytes signedD
    emitMeasure env "surplus-fold-actions-exact" memD cpuD sizeD
    rowCommit env cage "cg12-key-d" edgeInsertActive
    emit
        "control"
        ( "surplus-fold-actions control: exact 1:1 fold accepted (tx="
            <> txIdHex signedD
            <> ") — the refusals are specific to surplus and deficit"
        )

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
    _ <-
        runLive env (batchStory (Live.Context registry (genesisAddr env)))
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
