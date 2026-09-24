{- |
Module      : Conformance.Run.Fold
Description : Split out of Conformance.Run (#263); see that module's header
License     : Apache-2.0
-}
module Conformance.Run.Fold (FoldSpec (..), assembleFoldSpec, assembleFoldWithFee, rowSpec, declaredSpec, rowRequestAndFold, declaredUnits, buildRefusedFold, buildValidFold, foldUtxos, poisonProofs, validProofs, assembleFold, foldUpperSlot, calibrateFold, requestAndFold, requestAndFoldKey, foldSpecContext, foldSpecProcessed) where

import Conformance.Run.Control
import Conformance.Run.Book
import Conformance.Run.Units
import Conformance.Run.Cage
import Conformance.Run.Wallet
import Conformance.Run.Submit
import Conformance.Run.Environment
import Conformance.Run.Observe

import Control.Exception (
    SomeException,
    try,
 )
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.IORef (readIORef, writeIORef)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Time (getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Address (
    AccountAddress (..),
    Withdrawals (..),
 )
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))

import Cardano.Ledger.Api.PParams (ppMaxTxExUnitsL)
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
    mintTxBodyL,
    outputsTxBodyL,
    referenceInputsTxBodyL,
    reqSignerHashesTxBodyL,
    scriptIntegrityHashTxBodyL,
    vldtTxBodyL,
    withdrawalsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    addrTxOutL,
    coinTxOutL,
    datumTxOutL,
    getMinCoinTxOut,
    mkBasicTxOut,
    valueTxOutL,
 )
import Cardano.Ledger.Api.Tx.Wits (
    Redeemers (..),
    rdmrsTxWitsL,
    scriptTxWitsL,
 )
import Cardano.Ledger.BaseTypes (
    SlotNo (..),
    StrictMaybe (..),
 )
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (
    KeyHash,
    Script,
    hashScript,
 )
import Cardano.Ledger.Keys (KeyRole (..))
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)

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
    TxOut,
 )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Trie (TrieManager (..))
import Singular.Registry.Trie qualified as CageTrie
import Singular.Registry.TxBuilder.Internal (
    walkEdge,
    addrFromKeyHashBytes,
    addrKeyHashBytes,
    addrWitnessKeyHash,
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    computeScriptIntegrity,
    currentPosixMs,
    extractCageDatum,
    extractOwnerBytes,
    findRequestUtxos,
    findStateUtxo,
    mkCageScript,
    mkInlineDatum,
    mkRequestScript,
    requestAddrFromCfg,
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
    RegistryDuties (..),
    registryDuties,
    updateTokenWithDuties,
 )
import Singular.Registry.TxBuilder.ConnectedFold (
    ConnectedMint (..),
    ConnectedSpend (..),
 )
import Singular.Registry.Types (
    CageDatum (..),
    Edge,
    edgeInsertAbsent,
    OnChainRequest (..),
    OnChainRoot (..),
    OnChainTokenState (..),
    ProofStep (..),
    RequestAction (Update),
    UpdateRedeemer (..),
 )
import Singular.Registry.Types qualified as CageTypes
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins.Internal (BuiltinByteString (..))

import Conformance.Mirror (
    emit,
    failWith,
    require,
 )

-- ---------------------------------------------------------
-- Issue #70 fold assembly: one FoldSpec, every hand-built shape
-- ---------------------------------------------------------

{- | One hand-built fold transaction, fully specified. The library
fold cannot emit transactions whose scripts do not evaluate (CG05's
finding), so every refusal fold — and every fold whose payload
exercises an unchecked validator path (surplus actions, a changed
owner, crossed refunds) — is assembled here. Every accepting
hand-built fold is calibrated against the library fold it parallels
('calibrateFold'); a refusal fold differs from a calibrated one only
in the field under test.

Withdrawals carry redeemer @0::Integer@: the blueprint's staking
validator ignores its redeemer (@withdraw(_redeemer: Data ...) { True }@).
-}
data FoldSpec = FoldSpec
    { fsCfg :: CageConfig
    , fsTid :: TokenId
    , fsState :: (TxIn, TxOut ConwayEra)
    , fsReqs :: [(TxIn, TxOut ConwayEra)]
    -- ^ the requests this fold consumes, in tx-input order
    , fsActions :: [RequestAction]
    -- ^ one per request, same order
    , fsNewRoot :: Root
    , fsUnits :: ExUnits
    , fsFee :: Maybe Integer
    -- ^ @Nothing@: the caller sizes the fee in a second pass
    , fsRefunds :: [Integer]
    -- ^ explicit per-request refunds, one per request, of which only the
    -- UNPROCESSED ones are emitted; @[]@: derive (bond - tip share -
    -- fee share, first request carries the remainder)
    , fsStateOverride :: Maybe OnChainTokenState
    -- ^ datum for the new state output; @Nothing@: preserve the old
    -- state with 'fsNewRoot'
    , fsWithdrawal :: Maybe (AccountAddress, Script ConwayEra)
    , fsSigners :: Maybe [KeyHash Guard]
    {- ^ required signers; @Nothing@: the harness key (the process
    signs with it; NOT an owner — the registry has no owner role);
    @Just []@: deliberately none.
    -}
    , fsCollateral :: Maybe TxIn
    {- ^ collateral input; @Nothing@: the fee funder (the CG05
    shape). Refusing folds pass a dedicated 5 ADA pot instead — the
    whole collateral is taken on phase-2 failure, and the funder is
    the wallet's largest output.
    -}
    , fsUpper :: Maybe SlotNo
    -- ^ validity upper bound; @Nothing@: earliest request deadline
    , fsLower :: Maybe SlotNo
    , fsRefs :: [(TxIn, TxOut ConwayEra)]
    , fsHolderUtxos :: [(TxIn, TxOut ConwayEra)]
    , fsFunder :: Maybe (TxIn, TxOut ConwayEra)
    , fsOmitUnfundedBurn :: Bool
    -- ^ The cage's reference outputs, published once at its boot and
    -- copied here by `rowSpec`. Reading them rather than asking for them
    -- matters: asking publishes, and five awaited publications inside a
    -- fee loop spend the row's validity window.
    }


assembleFoldSpec :: Env -> FoldSpec -> IO ConwayTx
assembleFoldSpec env fs = do
    -- Every purpose resolves through the cage's reference outputs, which
    -- went up at its boot: a fold that attached the state validator
    -- instead would be refused for size before any script could speak.
    let refs = fsRefs fs
    ctx <- foldSpecContext env fs
    let prov = envProv env

    pp <- Cage.queryProtocolParams prov
    funder <- maybe (largestWalletUtxo prov) pure (fsFunder fs)
    require "hand-build: funder carries tokens" (adaOnly (snd funder))
    -- #157: a booked request carries the approval that certifies its
    -- edge, so it is no longer ada-only.
    -- NOTE-002: the request address is shared by every request ever
    -- parked for this cage, so a fold asserts that every request it
    -- consumes carries THIS cage's token — the extent is the
    -- consumed set itself, quantified, not a sample.
    require
        "hand-build: a consumed request does not carry this cage's token"
        (all (\(_, o) -> requestTokenMatches o) (fsReqs fs))
    oldState <- case extractCageDatum (snd (fsState fs)) of
        Just (StateDatum s) -> pure s
        _ -> failWith "hand-build: state output has no StateDatum"
    duties0 <-
        case registryDuties
            (fsCfg fs)
            pp
            oldState
            ctx
            (fsReqs fs)
            (foldSpecProcessed fs) of
            Right d -> pure d
            Left err -> failWith ("hand-build: " <> err)
    -- A retirement request against an Absent or unknown key has no active
    -- witness to burn. Remove that impossible mint from the refusal probe so
    -- the balanced transaction can reach the state script. An accepted
    -- submission is a finding in submitEdge, never a passing refusal.
    let duties = if fsOmitUnfundedBurn fs
            then duties0{rdMints = []}
            else duties0
    -- A near-now upper bound: the tx is submitted immediately after
    -- assembly, and a slot 30s+ ahead lands past the node's ledger
    -- translation horizon (epoch-safe-zone) and fails phase 1.
    nowMs <- currentPosixMs
    upperSlot <- case fsUpper fs of
        Just s -> pure s
        Nothing -> trySlots prov [nowMs + 2_000, nowMs + 1_500, nowMs + 1_000]
    let tipAmount = stateMaxFee oldState
        feeAmt = case fsFee fs of
            Just f -> f
            Nothing -> 0
        nReqs = toInteger (length (fsReqs fs))
    refunds <- case fsRefunds fs of
        [] -> deriveRefunds tipAmount feeAmt
        explicit
            | toInteger (length explicit) == nReqs -> pure explicit
            | otherwise ->
                failWith
                    ( "hand-build: "
                        <> show (length explicit)
                        <> " explicit refunds for "
                        <> show nReqs
                        <> " requests"
                    )
    -- Every refund output must clear min-ADA on its own, counting the
    -- approval it carries back: a shortfall here is a harness bug, never
    -- a row verdict.
    mapM_
        ( \out -> do
            let Coin minAda = getMinCoinTxOut @ConwayEra pp out
                Coin c = out ^. coinTxOutL
            require
                ("hand-build: refund under min-ADA: " <> show c)
                (c >= minAda)
        )
        (refundOuts refunds)
    newStateOut <- case fsStateOverride fs of
        Nothing -> pure (makeStateOut oldState)
        Just s -> pure (makeStateOutOverride s)
    changeOut <- makeChange pp funder feeAmt (map outCoin (refundOuts refunds)) duties
    redeemers <- makeRedeemers fs funder duties
    scripts <- makeScripts fs refs duties
    let signers = case fsSigners fs of
            Nothing -> harnessSigners
            Just ss -> ss
        inputs =
            Set.fromList
                ( fst (fsState fs)
                    : fst funder
                    : map fst (fsReqs fs)
                        <> map fst (rdInputs duties)
                        <> map (fst . csUtxo) (rdSpends duties)
                )
        integrity = computeScriptIntegrity pp redeemers
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ inputs
                & outputsTxBodyL
                    .~ StrictSeq.fromList
                        ( newStateOut
                            : rdOutputs duties
                            <> refundOuts refunds
                            <> [changeOut]
                        )
                & feeTxBodyL .~ Coin feeAmt
                & mintTxBodyL
                    .~ MultiAsset
                        ( foldr
                            ( \m acc ->
                                Map.insertWith
                                    (Map.unionWith (+))
                                    (cmPolicy m)
                                    (cmAssets m)
                                    acc
                            )
                            Map.empty
                            (rdMints duties)
                        )
                & collateralInputsTxBodyL
                    .~ Set.singleton (fromMaybe (fst funder) (fsCollateral fs))
                & reqSignerHashesTxBodyL
                    .~ Set.fromList (signers <> rdSigners duties)
                & referenceInputsTxBodyL
                    .~ Set.fromList (map fst refs)
                & scriptIntegrityHashTxBodyL .~ integrity
                & vldtTxBodyL
                    .~ ValidityInterval
                        (maybe SNothing SJust (fsLower fs))
                        (SJust upperSlot)
        -- #157 C10: no consumer withdrawal rides a fold any more; only a
        -- row that asks for its own stake withdrawal carries one.
        withWd =
            body & withdrawalsTxBodyL
                .~ Withdrawals
                    ( Map.fromList
                        [ (stakeAcct, Coin 0)
                        | Just (stakeAcct, _) <- [fsWithdrawal fs]
                        ]
                    )
    pure $
        mkBasicTx withWd
            & witsTxL . scriptTxWitsL .~ scripts
            & witsTxL . rdmrsTxWitsL .~ redeemers
  where
    units = fsUnits fs
    deriveRefunds tipAmount _feeAmt
        | null (fsReqs fs) = pure []
        | otherwise =
            pure
                [ let Coin reqVal = o ^. coinTxOutL
                   in reqVal - tipAmount
                | (_, o) <- fsReqs fs
                ]
    {- The refunds a fold owes: one per request it does NOT process.
    A processed request's deposit goes to the carriers its edge creates and
    its approval returns through them; an unprocessed one — rejected, or
    left unmatched by a deficit of actions — owes its owner the deposit and
    the approval that certified it, which was never spent. -}
    refundOuts :: [Integer] -> [TxOut ConwayEra]
    refundOuts explicit =
        [ mkBasicTxOut
            ( addrFromKeyHashBytes
                (network (fsCfg fs))
                (extractOwnerBytes o)
            )
            (MaryValue (Coin c) (MultiAsset (rawAssets o)))
        | (c, ((_, o), isProcessed)) <-
            zip explicit (zip (fsReqs fs) (foldSpecProcessed fs <> repeat False))
        , not isProcessed
        ]
    makeStateOut oldState =
        let scriptAddr = cageAddrFromCfg (fsCfg fs) (network (fsCfg fs))
            newDatum =
                StateDatum
                    oldState{stateRoot = OnChainRoot (unRoot (fsNewRoot fs))}
         in mkBasicTxOut
                scriptAddr
                (snd (fsState fs) ^. valueTxOutL)
                & datumTxOutL .~ mkInlineDatum (toPlcData newDatum)
    makeStateOutOverride overridden =
        let scriptAddr = cageAddrFromCfg (fsCfg fs) (network (fsCfg fs))
            newDatum =
                StateDatum
                    overridden{stateRoot = OnChainRoot (unRoot (fsNewRoot fs))}
         in mkBasicTxOut
                scriptAddr
                (snd (fsState fs) ^. valueTxOutL)
                & datumTxOutL .~ mkInlineDatum (toPlcData newDatum)
    makeChange pp funder' feeAmt refunds duties = do
        let reqCoins = [outCoin o | (_, o) <- fsReqs fs]
            funderCoin = outCoin (snd funder')
            -- Custody an edge consumes is an input too, and the carriers it
            -- owes take the deposit that rode its request; what is left
            -- over is change.
            custodyCoins = [outCoin o | sp <- rdSpends duties, let (_, o) = csUtxo sp]
            witnessCoins = [outCoin o | (_, o) <- rdInputs duties]
            dutyCoins = map outCoin (rdOutputs duties)
            change =
                sum reqCoins
                    + funderCoin
                    + sum custodyCoins
                    + sum witnessCoins
                    - sum refunds
                    - sum dutyCoins
                    - feeAmt
            out = mkBasicTxOut genesisAddr (MaryValue (Coin change) mempty)
            Coin minAda = getMinCoinTxOut @ConwayEra pp out
        require
            ("hand-build: change under min-ADA: " <> show change)
            (change >= minAda)
        pure out
    makeRedeemers :: FoldSpec -> (TxIn, TxOut ConwayEra) -> RegistryDuties -> IO (Redeemers ConwayEra)
    makeRedeemers fs' funder' duties = do
        -- The same input set the body builds, custody included: a spending
        -- index is a position in it, and two different sets give two
        -- different positions.
        let inputs =
                Set.fromList
                    ( fst (fsState fs')
                        : fst funder'
                        : map fst (fsReqs fs')
                            <> map fst (rdInputs duties)
                            <> map (fst . csUtxo) (rdSpends duties)
                    )
            statePurpose =
                ConwaySpending (AsIx (spendingIndex (fst (fsState fs')) inputs))
            stateRef = txInToRef (fst (fsState fs'))
            requestPairs =
                [ ( ConwaySpending (AsIx (spendingIndex reqIn inputs))
                  , (toLedgerData (Contribute stateRef), units)
                  )
                | (reqIn, _) <- fsReqs fs'
                ]
            -- #157 C10: the consumer rewarding purpose is gone; a row that
            -- asks for its own stake withdrawal is the only one left.
            hookPairs = case fsWithdrawal fs' of
                Nothing -> []
                Just _ ->
                    [ (ConwayRewarding (AsIx 0), (toLedgerData (0 :: Integer), units))
                    ]
            -- #157: the token policies this fold moves tokens under.
            mintPolicies = map cmPolicy (rdMints duties)
            mintIndex p =
                AsIx (fromIntegral (length (takeWhile (/= p) (Map.keys (Map.fromList [(q, ()) | q <- mintPolicies])))))
            mintPairs =
                [ (ConwayMinting (mintIndex (cmPolicy m)), (toLedgerData (cmRedeemer m), units))
                | m <- rdMints duties
                ]
            pairs =
                ( statePurpose
                , (toLedgerData (Modify (fsActions fs')), units)
                )
                    : requestPairs
                    <> hookPairs
                    <> mintPairs
                    <> [ ( ConwaySpending (AsIx (spendingIndex (fst (csUtxo sp)) inputs))
                         , (toLedgerData (csRedeemer sp), units)
                         )
                       | sp <- rdSpends duties
                       ]
        pure (Redeemers (Map.fromList pairs))
    makeScripts fs' refs duties = do
        let stateScript = mkCageScript (fsCfg fs')
            reqScript = mkRequestScript (fsCfg fs') (fsTid fs')

            stakeScript = case fsWithdrawal fs' of
                Nothing -> []
                Just (_, s) -> [(hashScript s, s)]
            -- A request script witness with no request redeemer is an
            -- ExtraneousScriptWitnesses phase-1 failure (CG11's empty
            -- fold consumes no requests).
            requestScripts =
                [ (hashScript reqScript, reqScript)
                | not (null (fsReqs fs'))
                ]
        pure
            ( Map.fromList
                ( [ (hashScript stateScript, stateScript)
                  | null refs
                  ]
                    <> (if null refs then requestScripts else [])
                    <> stakeScript
                    <> [ (hashScript (cmScript m), cmScript m)
                       | m <- rdMints duties
                       , null refs
                       ]
                )
            )
    -- Harness-key signers (NOTE-046): every hand-built fold carries
    -- the test harness's own signing key hash as its required
    -- signer — the key this process signs with — NOT an owner. The
    -- registry has no owner role; the bytes are unchanged from the
    -- old owner-derived list because the old boot pinned the harness
    -- key as the state owner, so measurements and refusal reasons
    -- are unaffected.
    harnessSigners :: [KeyHash Guard]
    harnessSigners =
        [addrWitnessKeyHash (addrKeyHashBytes genesisAddr)]
    adaOnly out = case out ^. valueTxOutL of
        MaryValue _ (MultiAsset ma) -> Map.null ma
    requestTokenMatches out = case extractCageDatum out of
        Just (RequestDatum rq) ->
            let CageTypes.OnChainTokenId (BuiltinByteString bs) = requestToken rq
             in AssetName (SBS.toShort bs) == unTokenId (fsTid fs)
        _ -> False


-- | Assemble with an iterated fee: assemble, let the ledger price
-- the transaction, and repeat until the declared fee exceeds the
-- estimate by a fixed margin. The margin discipline is CG05's: too
-- small fails loudly at submit (phase 1, no script named); too large
-- fails loudly in assembly (a refund under min-ADA).
assembleFoldWithFee :: Env -> FoldSpec -> IO ConwayTx
assembleFoldWithFee env fs = go (0 :: Int) 1_500_000
  where
    go n fee = do
        tx <- assembleFoldSpec env fs{fsFee = Just fee}
        pp <- Cage.queryProtocolParams (envProv env)
        -- Conway charges for the reference scripts a transaction reads,
        -- by their size. Estimating against zero of them stops this loop
        -- one fee short and the node refuses the result.
        let refBytes = sum (map (refScriptSize . snd) (fsRefs fs))
            Coin est = estimateMinFeeTx pp tx 1 0 refBytes
            needed = est + 50_000
        if fee >= needed || n >= (5 :: Int)
            then pure tx
            else go (n + 1) needed


{- | A FoldSpec with this cage's defaults: derive refunds and
signers, no withdrawal, no state override, deadline validity.
-}
rowSpec ::
    RowCage ->
    TokenId ->
    (TxIn, TxOut ConwayEra) ->
    [(TxIn, TxOut ConwayEra)] ->
    [RequestAction] ->
    Root ->
    ExUnits ->
    FoldSpec
rowSpec cage tid state reqs actions root units =
    FoldSpec
        { fsCfg = rcCfg cage
        , fsTid = tid
        , fsState = state
        , fsReqs = reqs
        , fsActions = actions
        , fsNewRoot = root
        , fsUnits = units
        , fsFee = Nothing
        , fsRefunds = []
        , fsStateOverride = Nothing
        , fsWithdrawal = Nothing
        , fsSigners = Nothing
        , fsCollateral = Nothing
        , fsUpper = Nothing
        , fsLower = Nothing
        , fsRefs = rcRefs cage
        , fsHolderUtxos = []
        , fsFunder = Nothing
        , fsOmitUnfundedBurn = False
        }


-- | Twice the measured units: the declared budget of a refusing
-- fold. A cage with no measured fold yet (its rows refuse before
-- above anything a script consumes before erroring, far below the
-- per-purpose phase-2 ceiling, and small enough that the node's
-- rejection payload stays inside the local channel's limits.
declaredSpec :: Env -> RowCage -> IO ExUnits
declaredSpec env cage = do
    (mem, cpu) <- readIORef (rcUnits cage)
    case (mem, cpu) of
        (m, c) | m > 0 -> pure (declaredUnits (m, c))
        _ -> do
            pp <- Cage.queryProtocolParams (envProv env)
            let ExUnits maxMem maxSteps = pp ^. ppMaxTxExUnitsL
                fallback =
                    ExUnits
                        (maxMem `div` 100)
                        (maxSteps `div` 20)
            emit "units" "no measured fold in this cage; declaring 1% mem / 5% cpu of the maxima"
            pure fallback


{- | One row cage's request-and-fold cycle through the library
builder, with the calibration the hand-built shapes inherit their
credibility from: submit the request, build the library fold over
all pending requests, build the hand parallel, compare, measure,
submit, commit the trie.
-}
rowRequestAndFold ::
    Env ->
    RowCage ->
    String ->
    ByteString ->
    ByteString ->
    Edge ->
    IO (ConwayTx, Integer, Integer, Integer)
rowRequestAndFold env cage label key _val _op = do
    let cfg = rcCfg cage
        prov = envProv env
    tid <- cageTid cage
    -- #157 A-009: the row books an edge. The absence witness is the one
    -- edge that needs no signature, and it is what every issue-70 row
    -- asks of the trie.
    dest <- edgeDestination env edgeInsertAbsent
    _ <-
        bookEdge
            env
            cfg
            tid
            genesisAddr
            genesisSignKey
            key
            edgeInsertAbsent
            dest
            []
            (defaultTipCoin cfg + cgDeposit)
    ctx <- rowRegistryContext env cage tid
    unsignedFold <-
        updateTokenWithDuties cfg prov (envTm env) tid genesisAddr ctx
    state@(stateIn, _) <- cageStateUtxo env cage
    reqUtxos <- pendingRequests env cage
    (handProofs, handRoot) <- speculativeApplyAll env cage tid reqUtxos
    pp <- Cage.queryProtocolParams prov
    let ExUnits maxMem maxSteps = pp ^. ppMaxTxExUnitsL
        calibSpec =
            (rowSpec
                cage
                tid
                state
                reqUtxos
                (map Update handProofs)
                handRoot
                (ExUnits maxMem maxSteps))
                { fsFee = Just 700_000
                }
    handFold <- assembleFoldSpec env calibSpec
    calibrateFold stateIn handFold unsignedFold
    emit "calibration" (label <> ": hand model matches the library fold")
    (mem, cpu) <- measureUnits env unsignedFold
    writeIORef (rcUnits cage) (mem, cpu)
    signed <- submitWithGenesis (envSubmit env) unsignedFold
    let size = txSizeBytes signed
    emitMeasure env label mem cpu size
    -- Commit what was FOLDED, which is the absence this row booked: the
    -- caller.s value never reached the chain, and a trie holding it
    -- would prove against a root the chain does not have.
    rowCommit env cage key edgeInsertAbsent
    pure (signed, mem, cpu, size)


-- ---------------------------------------------------------
-- Hand-built folds
-- ---------------------------------------------------------

{- | Declared units for the poisoned fold: twice the last valid
fold's measured units. The refusing script errors before a full
run's work, so 2x covers the consumed-at-error budget with room;
the fee math below keeps the refund above min-ADA regardless. If
the node ever reports a budget overrun instead of the script
error, this factor is the first thing to revisit — the run fails
loudly either way.
-}
declaredUnits :: (Integer, Integer) -> ExUnits
declaredUnits (mem, cpu) =
    ExUnits (fromIntegral (mem * 2)) (fromIntegral (cpu * 2))


{- | The hand-built poisoned fold for CG05: spends the state and the
sole pending occupied-insert request exactly as the library fold
would — same inputs, state output, refunds, redeemers, scripts,
signers and validity — with the overwrite root the library itself
would declare, but balanced by hand so the unevaluatable scripts
never gate emission. The node rules on it at submit.
-}
buildRefusedFold :: Env -> IO ConwayTx
buildRefusedFold env = do
    (stateUtxo, reqUtxos) <- foldUtxos env
    reqUtxo <- case reqUtxos of
        [u] -> pure u
        _ ->
            failWith
                ( "CG05 hand-build: expected one pending request, found "
                    <> show (length reqUtxos)
                )
    (proofs, newRoot) <- poisonProofs env
    (memU, cpuU) <- readIORef (envValidUnits env)
    require
        "CG05 hand-build: no valid fold measured yet"
        (memU > 0 && cpuU > 0)
    let units = declaredUnits (memU, cpuU)
    draft <- assembleFold env stateUtxo [reqUtxo] [proofs] newRoot units 0
    pp <- Cage.queryProtocolParams (envProv env)
    -- Conway charges for the reference scripts a transaction reads, by
    -- their size, so the estimate is given that size rather than zero.
    refs <- sessionRefUtxos env
    let refBytes = sum (map (refScriptSize . snd) refs)
        Coin estFee = estimateMinFeeTx pp draft 1 0 refBytes
        fee1 = estFee + feeMargin
    assembleFold env stateUtxo [reqUtxo] [proofs] newRoot units fee1
  where
    -- \| Small margin over the ledger's own minimum-fee estimate
    -- (which prices the declared units exactly). Too small fails
    -- loudly at submit (phase 1, no script named); too large fails
    -- loudly in assembly (refund under min-ADA). Neither can
    -- masquerade as the row's verdict.
    feeMargin = 50_000


{- | The hand-built valid fold for calibration: same assembly as the
poisoned fold but over the valid pending requests, with maximal
declared units (it is never submitted, so its fee is irrelevant).
Compared field-by-field against the library fold it parallels.
-}
buildValidFold :: Env -> IO (TxIn, ConwayTx)
buildValidFold env = do
    pp <- Cage.queryProtocolParams (envProv env)
    let ExUnits maxMem maxSteps = pp ^. ppMaxTxExUnitsL
    (stateUtxo@(stateIn, _), reqUtxos) <- foldUtxos env
    (proofLists, newRoot) <- validProofs env reqUtxos
    -- Calibration builds never submit: any fee keeping the outputs
    -- above min-ADA serves; fee-dependent fields are uncompared.
    hand <- assembleFold env stateUtxo reqUtxos proofLists newRoot (ExUnits maxMem maxSteps) 700_000
    pure (stateIn, hand)


{- | The fold's inputs as the library discovers them: the state UTxO
by policy token, the pending requests sorted. Shared by the
calibration build so both builders consume the same UTxOs.
-}
foldUtxos ::
    Env -> IO ((TxIn, TxOut ConwayEra), [(TxIn, TxOut ConwayEra)])
foldUtxos env = do
    let cfg = envCfg env
        prov = envProv env
        tid = envTid env
    stateUtxos <-
        Cage.queryUTxOs prov (cageAddrFromCfg cfg (network cfg))
    stateUtxo <- case findStateUtxo (cagePolicyIdFromCfg cfg) tid stateUtxos of
        Nothing -> failWith "hand-build: no state UTxO"
        Just u -> pure u
    reqUtxos <-
        Cage.queryUTxOs
            prov
            (requestAddrFromCfg cfg tid (network cfg))
    let reqs = sortOn fst (findRequestUtxos tid reqUtxos)
    require "hand-build: no pending requests" (not (null reqs))
    pure (stateUtxo, reqs)


{- | Proofs and root for the poisoned fold: the overwrite the library
itself would declare (insert over the occupied key, proof steps,
new root), computed through the same speculative trie the library
folds use.
-}
poisonProofs :: Env -> IO ([ProofStep], Root)
poisonProofs env =
    withSpeculativeTrie (envTm env) (envTid env) $ \trie -> do
        _ <- CageTrie.insert trie cgKey cgV4
        mSteps <- CageTrie.getProofSteps trie cgKey
        r <- CageTrie.getRoot trie
        pure (fromMaybe [] mSteps, r)


{- | Proofs and root for valid folds, replicating the library's
per-request processing through the same speculative trie.
-}
validProofs :: Env -> [(TxIn, TxOut ConwayEra)] -> IO ([[ProofStep]], Root)
validProofs env reqUtxos =
    withSpeculativeTrie (envTm env) (envTid env) $ \trie -> do
        ps <- mapM (processOne trie) reqUtxos
        r <- CageTrie.getRoot trie
        pure (ps, r)
  where
    -- The key and the edge are the request's own, read from its datum
    -- exactly as the library builder reads them: the rows no longer
    -- share one (#157 C3: a read proves its key and leaves it alone,
    -- which `walkEdge` already knows).
    processOne trie (_, txOut) = walkEdge trie key edge
      where
        (key, edge) = case extractCageDatum txOut of
            Just (RequestDatum rq) -> (requestKey rq, requestEdge rq)
            _ -> error "hand-build: pending UTxO has no request datum"


{- | Assemble a fold transaction by hand: the library fold's shape
with hand-computed fee, change and declared units. Two-pass fee
sizing against the devnet minima plus a flat margin; the refund and
change are asserted above min-ADA, never defaulted.
-}

{- | Assemble a fold transaction by hand: the library fold's shape
with caller-computed fee, change and declared units. The refund and
change are asserted above min-ADA, never defaulted.
-}
assembleFold ::
    Env ->
    (TxIn, TxOut ConwayEra) ->
    [(TxIn, TxOut ConwayEra)] ->
    [[ProofStep]] ->
    Root ->
    ExUnits ->
    Integer ->
    IO ConwayTx
assembleFold env (stateIn, stateOut) reqUtxos proofLists newRoot units fee = do
    let prov = envProv env
    pp <- Cage.queryProtocolParams prov
    funder <- largestWalletUtxo prov
    require "hand-build: funder carries tokens" (adaOnly (snd funder))
    -- #157: a booked request carries its approval, so it is no longer
    -- ADA-only; the fold checks the binding, not the emptiness.
    oldState <- extractState stateOut
    upperSlot <- foldUpperSlot prov oldState (map snd reqUtxos)
    -- #157 C5/C6/T1-T6: the same obligations the library fold
    -- discharges. The derivation is shared because the duties are a
    -- protocol fact, not a builder opinion; what CL01 compares is the
    -- two assemblies of them.
    ctx0 <- registryContext env
    let ctx = ctx0 {rcAllowInadmissible = True}
    duties <- case registryDuties (envCfg env) pp oldState ctx reqUtxos (map (const True) reqUtxos) of
        Right d -> pure d
        Left err -> failWith ("hand-build: " <> err)
    -- #157 C10: there is no pinned consumer and no mandatory
    -- withdrawal left to attach.
    assembleBody pp funder oldState upperSlot fee duties (rcRefUtxos ctx)
  where
    assembleBody pp funder oldState upperSlot feeAmt duties refs = do
        newStateOut <- makeStateOut oldState newRoot
        let dutyOuts = rdOutputs duties
            custodyIns = map (fst . csUtxo) (rdSpends duties)
            mintValue =
                foldr
                    (\m acc -> Map.insertWith (Map.unionWith (+)) (cmPolicy m) (cmAssets m) acc)
                    Map.empty
                    (rdMints duties)
            inputs =
                Set.fromList
                    (stateIn : fst funder : map fst reqUtxos <> custodyIns)
        changeOut <- makeChange pp funder feeAmt (newStateOut : dutyOuts) (rdSpends duties)
        redeemers <-
            makeRedeemers
                stateIn
                funder
                reqUtxos
                proofLists
                units
                duties
                inputs
                mintValue
        scripts <- makeScripts duties refs
        -- Harness-key signer (NOTE-046): see harnessSigners above.
        let ownerKh = addrWitnessKeyHash (addrKeyHashBytes genesisAddr)
            integrity = computeScriptIntegrity pp redeemers
            body =
                mkBasicTxBody
                    & inputsTxBodyL .~ inputs
                    & outputsTxBodyL
                        .~ StrictSeq.fromList
                            ([newStateOut] <> dutyOuts <> [changeOut])
                    & feeTxBodyL .~ Coin feeAmt
                    & mintTxBodyL .~ MultiAsset mintValue
                    & collateralInputsTxBodyL
                        .~ Set.singleton (fst funder)
                    & reqSignerHashesTxBodyL
                        .~ Set.fromList (ownerKh : rdSigners duties)
                    & referenceInputsTxBodyL
                        .~ Set.fromList (map fst refs)
                    & scriptIntegrityHashTxBodyL .~ integrity
                    & vldtTxBodyL
                        .~ ValidityInterval SNothing (SJust upperSlot)
        pure $
            mkBasicTx body
                & witsTxL . scriptTxWitsL .~ scripts
                & witsTxL . rdmrsTxWitsL .~ redeemers
    makeStateOut oldState newRoot' = do
        let scriptAddr = cageAddrFromCfg (envCfg env) (network (envCfg env))
            newDatum =
                StateDatum
                    oldState{stateRoot = OnChainRoot (unRoot newRoot')}
        pure $
            mkBasicTxOut
                scriptAddr
                (stateOut ^. valueTxOutL)
                & datumTxOutL .~ mkInlineDatum (toPlcData newDatum)
    {- The fold's change: everything its inputs bring, less everything its
    outputs take and the fee. The state UTxO and any custody it spends are
    inputs too — the earlier shape counted only the requests, and the
    lovelace the state carries went missing from the balance. -}
    makeChange pp funder' feeAmt outs spends = do
        let inCoins =
                outCoin (snd funder')
                    : outCoin stateOut
                    : [outCoin o | (_, o) <- reqUtxos]
                        <> [outCoin o | sp <- spends, let (_, o) = csUtxo sp]
            change = sum inCoins - sum (map outCoin outs) - feeAmt
            out =
                mkBasicTxOut
                    genesisAddr
                    (MaryValue (Coin change) mempty)
            Coin minAda = getMinCoinTxOut @ConwayEra pp out
        require
            ("hand-build: change under min-ADA: " <> show change)
            (change >= minAda)
        pure out
    makeRedeemers stateIn' _funder' reqUtxos' proofLists' units' duties inputs mintValue = do
        let statePurpose =
                ConwaySpending (AsIx (spendingIndex stateIn' inputs))
            stateRef = txInToRef stateIn'
            actions =
                zipWith (\_ proofs -> Update proofs) reqUtxos' proofLists'
            modRedeemer = Modify actions
            -- #157: minting purposes are indexed by the policy's position
            -- in the transaction's own sorted mint map.
            mintIndex policy =
                AsIx (fromIntegral (length (takeWhile (/= policy) (Map.keys mintValue))))
            pairs =
                ( statePurpose
                , (toLedgerData modRedeemer, units')
                )
                    : [ ( ConwaySpending (AsIx (spendingIndex reqIn inputs))
                        , (toLedgerData (Contribute stateRef), units')
                        )
                      | (reqIn, _) <- reqUtxos'
                      ]
                    <> [ ( ConwaySpending (AsIx (spendingIndex (fst (csUtxo sp)) inputs))
                         , (toLedgerData (csRedeemer sp), units')
                         )
                       | sp <- rdSpends duties
                       ]
                    <> [ ( ConwayMinting (mintIndex (cmPolicy m))
                         , (toLedgerData (cmRedeemer m), units')
                         )
                       | m <- rdMints duties
                       ]
        pure (Redeemers (Map.fromList pairs))
    -- The state validator alone is fifteen kilobytes: with the session.s
    -- reference outputs in view every purpose resolves through them, and
    -- the hand model attaches nothing. Without them it attaches all three.
    makeScripts duties refs
        | not (null refs) = pure Map.empty
        | otherwise = do
            let stateScript = mkCageScript (envCfg env)
                reqScript = mkRequestScript (envCfg env) (envTid env)
            pure
                ( Map.fromList
                    ( [ (hashScript stateScript, stateScript)
                      , (hashScript reqScript, reqScript)
                      ]
                        <> [ (hashScript (cmScript m), cmScript m)
                           | m <- rdMints duties
                           ]
                    )
                )
    adaOnly out = case out ^. valueTxOutL of
        MaryValue _ (MultiAsset ma) -> Map.null ma


{- | The fold's validity upper slot, replicating the library's
deadline: the earliest request deadline mapped to a slot, with the
library's own fallbacks.
-}
foldUpperSlot ::
    Cage.Provider IO -> OnChainTokenState -> [TxOut ConwayEra] -> IO SlotNo
foldUpperSlot prov oldState reqOuts = do
    deadlines <- mapM submittedAt reqOuts
    let earliest = minimum deadlines + stateProcessTime oldState
    r <- try @SomeException (Cage.posixMsToSlot prov earliest)
    case r of
        Right s -> pure s
        Left _ -> do
            nowUtc <- getCurrentTime
            let posixSec = utcTimeToPOSIXSeconds nowUtc
            trySlots
                prov
                [ round ((posixSec + d) * 1000)
                | d <- [30, 5, 2]
                ]
  where
    submittedAt out = case extractCageDatum out of
        Just (RequestDatum rq) -> pure (requestSubmittedAt rq)
        _ -> failWith "hand-build: pending UTxO has no request datum"


{- | The calibration: the hand-built valid fold must match the
library fold on everything the validator rules on — same inputs,
same state output, same refund destinations, same Modify proofs.
Fee, change and declared units differ by construction (hand
balancing) and validity may differ by slot timing; those are not
compared. A mismatch means the hand model drifted from the library
and fails the run before any verdict is read.
-}
calibrateFold :: TxIn -> ConwayTx -> ConwayTx -> IO ()
calibrateFold stateIn hand dsl = do
    let handBody = hand ^. bodyTxL
        dslBody = dsl ^. bodyTxL
    require
        "calibration: inputs differ"
        ((handBody ^. inputsTxBodyL) == (dslBody ^. inputsTxBodyL))
    case ( toList (handBody ^. outputsTxBodyL)
         , toList (dslBody ^. outputsTxBodyL)
         ) of
        (handState : handRefund : _, dslState : dslRefund : _) -> do
            require
                "calibration: state output differs"
                (handState == dslState)
            require
                "calibration: refund destination differs"
                ((handRefund ^. addrTxOutL) == (dslRefund ^. addrTxOutL))
        _ -> failWith "calibration: missing outputs"
    case (modifyData hand, modifyData dsl) of
        (Just (handData, _), Just (dslData, _)) ->
            unless (handData == dslData) $
                failWith
                    ( "calibration: modify proofs differ:\nhand: "
                        <> show handData
                        <> "\ndsl:  "
                        <> show dslData
                    )
        _ ->
            failWith
                ( "calibration: modify redeemer missing: hand="
                    <> show (redeemerKeys hand)
                    <> " dsl="
                    <> show (redeemerKeys dsl)
                    <> " wanted="
                    <> show (spendingIndex stateIn (hand ^. bodyTxL . inputsTxBodyL))
                )
  where
    modifyData tx =
        let Redeemers m = tx ^. witsTxL . rdmrsTxWitsL
            idx =
                spendingIndex stateIn (tx ^. bodyTxL . inputsTxBodyL)
         in Map.lookup (ConwaySpending (AsIx idx)) m
    redeemerKeys tx =
        let Redeemers m = tx ^. witsTxL . rdmrsTxWitsL
         in Map.keys m


-- ---------------------------------------------------------
-- Fold plumbing (the E2E code path)
-- ---------------------------------------------------------

{- | Submit one request of the given op and fold it. Units are
measured on the unsigned fold while its inputs are still unspent
(the node cannot evaluate spent inputs); the size is taken from
the signed transaction that lands on chain. Every valid fold is
calibrated: the hand-built parallel must match the library fold on
inputs, state output, refund destinations and Modify proofs, or
the hand model drifted and the run fails before reading verdicts.
-}
requestAndFold ::
    Env -> String -> Edge -> IO (ConwayTx, Integer, Integer, Integer)
requestAndFold env label = requestAndFoldKey env label cgKey


-- | `requestAndFold` on a named key: the delete and re-insert rows own
-- their own, because their edges need a witnessed absence to act on.
requestAndFoldKey ::
    Env ->
    String ->
    ByteString ->
    Edge ->
    IO (ConwayTx, Integer, Integer, Integer)
requestAndFoldKey env label key op = do
    let cfg = envCfg env
        prov = envProv env
        tid = envTid env
        Coin tipVal = defaultTip cfg
    -- #157: a tree edge is booked, not merely requested. The approval the
    -- naming application mints certifies which edge this is, for whom, and
    -- where it delivers; the request carries it to the fold.
    _ <- sessionRefUtxos env
    dest <- edgeDestination env op
    refIns <- edgeReferences env key op
    _ <-
        bookEdge
            env
            cfg
            tid
            genesisAddr
            genesisSignKey
            key
            op
            dest
            refIns
            (tipVal + cgDeposit)
    ctx <- registryContext env
    unsignedFold <-
        updateTokenWithDuties cfg prov (envTm env) tid genesisAddr ctx
    (stateIn, handFold) <- buildValidFold env
    calibrateFold stateIn handFold unsignedFold
    emit "calibration" (label <> ": hand model matches the library fold")
    (mem, cpu) <- measureUnits env unsignedFold
    writeIORef (envValidUnits env) (mem, cpu)
    signed <- submitWithGenesis (envSubmit env) unsignedFold
    let size = txSizeBytes signed
    emitMeasure env label mem cpu size
    pure (signed, mem, cpu, size)


{- | The duties context for a fold spec, from its own cage configuration
and the reference outputs it carries.
-}
foldSpecContext :: Env -> FoldSpec -> IO RegistryContext
foldSpecContext env fs = do
    let cfg = fsCfg fs
        (_, _, codes) = envCodes env
        registryId =
            scriptHashBytes (cfgScriptHash cfg)
                <> SBS.fromShort (assetNameBytes (unTokenId (fsTid fs)))
        witnessAt kind =
            scriptFromBytes
                ("witness-" <> show kind)
                ( applyBytesParam
                    registryId
                    (applyDataParam (PLC.I kind) (ncWitness codes))
                )
    utxos <- cageUtxosOf env cfg
    pure
        RegistryContext
            { rcWitnessScripts = Map.fromList [(k, witnessAt k) | k <- [0, 1, 2]]
            , rcCageScript = Just (mkCageScript cfg)
            , rcCageUtxos = utxos
            , rcDatums = [(recordDatumHash, recordDatum)]
            , rcHolderUtxos = fsHolderUtxos fs
            , -- A refusal row exists to watch the chain refuse a fold the
              -- builder cannot discharge duties for; it must still be built.
              rcAllowInadmissible = True
            , rcRefUtxos = fsRefs fs
            }


-- | Which of a fold's requests it PROCESSES, as opposed to rejects.
foldSpecProcessed :: FoldSpec -> [Bool]
foldSpecProcessed fs =
    [ case a of
        CageTypes.Rejected -> False
        _ -> True
    | a <- fsActions fs
    ]
