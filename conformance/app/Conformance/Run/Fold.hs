{- |
Module      : Conformance.Run.Fold
Description : Split out of Conformance.Run (#263); see that module's header
License     : Apache-2.0
-}
module Conformance.Run.Fold
    ( FoldSpec (..)
    , assembleFoldSpec
    , assembleFoldWithFee
    , rowSpec
    , declaredSpec
    , rowRequestAndFold
    , declaredUnits
    , validProofs
    , calibrateFold
    , foldSpecContext
    , foldSpecProcessed
    , heldInput
    ) where

import Conformance.Run.Book
import Conformance.Run.Cage
import Conformance.Run.Control
import Conformance.Run.Environment
import Conformance.Run.Observe
import Conformance.Run.Submit
import Conformance.Run.Units
import Conformance.Run.Wallet

import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.IORef (readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text qualified as T
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Address
    ( AccountAddress (..)
    , Withdrawals (..)
    )
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))

import Cardano.Ledger.Api.PParams (ppMaxTxExUnitsL)
import Cardano.Ledger.Api.Tx
    ( bodyTxL
    , estimateMinFeeTx
    , mkBasicTx
    , mkBasicTxBody
    , witsTxL
    )
import Cardano.Ledger.Api.Tx.Body
    ( ValidityInterval (..)
    , collateralInputsTxBodyL
    , feeTxBodyL
    , inputsTxBodyL
    , mintTxBodyL
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , reqSignerHashesTxBodyL
    , scriptIntegrityHashTxBodyL
    , vldtTxBodyL
    , withdrawalsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( addrTxOutL
    , coinTxOutL
    , datumTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits
    ( Redeemers (..)
    , rdmrsTxWitsL
    , scriptTxWitsL
    )
import Cardano.Ledger.BaseTypes
    ( SlotNo (..)
    , StrictMaybe (..)
    )
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core
    ( KeyHash
    , Script
    , hashScript
    )
import Cardano.Ledger.Keys (KeyRole (..))
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)

import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins.Internal (BuiltinByteString (..))
import Singular.Registry.Blueprint
    ( NamingCodes (..)
    , applyBytesParam
    , applyDataParam
    )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger
    ( AssetName (..)
    , Coin (..)
    , ConwayEra
    , ExUnits (..)
    , Root (..)
    , TokenId (..)
    , TxOut
    )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Trie (TrieManager (..))
import Singular.Registry.Trie qualified as CageTrie
import Singular.Registry.TxBuilder.ConnectedFold
    ( ConnectedMint (..)
    , ConnectedSpend (..)
    )
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , addrKeyHashBytes
    , addrWitnessKeyHash
    , cageAddrFromCfg
    , computeScriptIntegrity
    , currentPosixMs
    , extractCageDatum
    , extractOwnerBytes
    , mkCageScript
    , mkInlineDatum
    , mkRequestScript
    , scriptFromBytes
    , scriptHashBytes
    , spendingIndex
    , toLedgerData
    , toPlcData
    , trySlots
    , txInToRef
    , walkEdge
    )
import Singular.Registry.TxBuilder.Update
    ( RegistryContext (..)
    , RegistryDuties (..)
    , registryDuties
    , updateTokenWithDuties
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , Edge
    , OnChainRequest (..)
    , OnChainRoot (..)
    , OnChainTokenState (..)
    , ProofStep (..)
    , RequestAction (Update)
    , UpdateRedeemer (..)
    , edgeInsertAbsent
    )
import Singular.Registry.Types qualified as CageTypes

import Conformance.Mirror
    ( emit
    , failWith
    , require
    )

-- ---------------------------------------------------------
-- Issue #70 fold assembly: one FoldSpec, every hand-built shape
-- ---------------------------------------------------------

{- | One hand-built fold transaction, fully specified. The library
fold cannot emit transactions whose scripts do not evaluate, so
every refusal fold — and every fold whose payload
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
    , fsPurposeUnits :: Map.Map T.Text ExUnits
    , fsFee :: Maybe Integer
    -- ^ @Nothing@: the caller sizes the fee in a second pass
    , fsRefunds :: [Integer]
    {- ^ explicit per-request refunds, one per request, of which only the
    UNPROCESSED ones are emitted; @[]@: derive (bond - tip share -
    fee share, first request carries the remainder)
    -}
    , fsStateOverride :: Maybe OnChainTokenState
    {- ^ datum for the new state output; @Nothing@: preserve the old
    state with 'fsNewRoot'
    -}
    , fsWithdrawal :: Maybe (AccountAddress, Script ConwayEra)
    , fsSigners :: Maybe [KeyHash Guard]
    {- ^ required signers; @Nothing@: the harness key (the process
    signs with it; NOT an owner — the registry has no owner role);
    @Just []@: deliberately none.
    -}
    , fsCollateral :: Maybe TxIn
    {- ^ collateral input; @Nothing@: the fee funder. Refusing
    folds pass a dedicated 5 ADA pot instead — the
    whole collateral is taken on phase-2 failure, and the funder is
    the wallet's largest output.
    -}
    , fsUpper :: Maybe SlotNo
    -- ^ validity upper bound; @Nothing@: earliest request deadline
    , fsLower :: Maybe SlotNo
    , fsRefs :: [(TxIn, TxOut ConwayEra)]
    , fsHolderUtxos :: [(TxIn, TxOut ConwayEra)]
    , fsFunder :: Maybe (TxIn, TxOut ConwayEra)
    , fsExtraOutputs :: [TxOut ConwayEra]
    {- ^ outputs placed after the refunds and before the change, paid from the
    change: a control that pays an owner beside its refund. @[]@ for every
    ordinary fold.
    -}
    , fsOmitUnfundedBurn :: Bool
    {- ^ The cage's reference outputs, published once at its boot and
    copied here by `rowSpec`. Reading them rather than asking for them
    matters: asking publishes, and five awaited publications inside a
    fee loop spend the row's validity window.
    -}
    }

{- | Assemble one fold from one view of the chain: every read the
assembly makes is served by the same acquired state, and the chain
inputs the spec names are checked against it ('heldInputs').
-}
assembleFoldSpec :: Env -> FoldSpec -> IO ConwayTx
assembleFoldSpec env0 fs = Cage.withView (envProv env0) $ \held -> do
    let env = pinnedTo held env0
    heldInputs held fs
    -- Every purpose resolves through the cage's reference outputs, which
    -- went up at its boot: a fold that attached the state validator
    -- instead would be refused for size before any script could speak.
    let refs = fsRefs fs
    ctx <- foldSpecContext env held fs
    let prov = envProv env

    pp <- Cage.withView prov (pure . Cage.viewProtocolParams)
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
    let duties =
            if fsOmitUnfundedBurn fs
                then duties0{rdMints = []}
                else duties0
    -- A near-now upper bound: the tx is submitted immediately after
    -- assembly, and a slot 30s+ ahead lands past the node's ledger
    -- translation horizon (epoch-safe-zone) and fails phase 1.
    nowMs <- currentPosixMs
    upperSlot <- case fsUpper fs of
        Just s -> pure s
        Nothing ->
            Cage.withView
                prov
                (\v -> trySlots v [nowMs + 2_000, nowMs + 1_500, nowMs + 1_000])
    let tipAmount = stateMaxFee oldState
        feeAmt = fromMaybe 0 (fsFee fs)
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
    changeOut <-
        makeChange
            pp
            funder
            feeAmt
            (map outCoin (refundOuts refunds <> fsExtraOutputs fs))
            duties
    redeemers <- makeRedeemers fs funder duties
    scripts <- makeScripts fs refs duties
    let signers = fromMaybe harnessSigners (fsSigners fs)
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
                                <> fsExtraOutputs fs
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
        -- #157 removed-consumer-encoding: no consumer withdrawal rides a fold any more; only a
        -- row that asks for its own stake withdrawal carries one.
        withWd =
            body
                & withdrawalsTxBodyL
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
    deriveRefunds tipAmount _feeAmt
        | null (fsReqs fs) = pure []
        | otherwise =
            pure
                [ let Coin reqVal = o ^. coinTxOutL
                  in  reqVal - tipAmount
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
        in  mkBasicTxOut
                scriptAddr
                (snd (fsState fs) ^. valueTxOutL)
                & datumTxOutL .~ mkInlineDatum (toPlcData newDatum)
    makeStateOutOverride overridden =
        let scriptAddr = cageAddrFromCfg (fsCfg fs) (network (fsCfg fs))
            newDatum =
                StateDatum
                    overridden{stateRoot = OnChainRoot (unRoot (fsNewRoot fs))}
        in  mkBasicTxOut
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
    makeRedeemers
        :: FoldSpec
        -> (TxIn, TxOut ConwayEra)
        -> RegistryDuties
        -> IO (Redeemers ConwayEra)
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
            unitsFor purpose =
                Map.findWithDefault
                    (fsUnits fs')
                    (T.pack (show purpose))
                    (fsPurposeUnits fs')
            stateRef = txInToRef (fst (fsState fs'))
            requestPairs =
                [ let purpose = ConwaySpending (AsIx (spendingIndex reqIn inputs))
                  in  (purpose, (toLedgerData (Contribute stateRef), unitsFor purpose))
                | (reqIn, _) <- fsReqs fs'
                ]
            -- #157 removed-consumer-encoding: the consumer rewarding purpose is gone; a row that
            -- asks for its own stake withdrawal is the only one left.
            hookPairs = case fsWithdrawal fs' of
                Nothing -> []
                Just _ ->
                    [ let purpose = ConwayRewarding (AsIx 0)
                      in  (purpose, (toLedgerData (0 :: Integer), unitsFor purpose))
                    ]
            -- #157: the token policies this fold moves tokens under.
            mintPolicies = map cmPolicy (rdMints duties)
            mintIndex p =
                AsIx
                    ( fromIntegral
                        ( length
                            ( takeWhile
                                (/= p)
                                (Map.keys (Map.fromList [(q, ()) | q <- mintPolicies]))
                            )
                        )
                    )
            mintPairs =
                [ let purpose = ConwayMinting (mintIndex (cmPolicy m))
                  in  (purpose, (toLedgerData (cmRedeemer m), unitsFor purpose))
                | m <- rdMints duties
                ]
            pairs =
                ( statePurpose
                , (toLedgerData (Modify (fsActions fs')), unitsFor statePurpose)
                )
                    : requestPairs
                        <> hookPairs
                        <> mintPairs
                        <> [ let purpose = ConwaySpending (AsIx (spendingIndex (fst (csUtxo sp)) inputs))
                             in  (purpose, (toLedgerData (csRedeemer sp), unitsFor purpose))
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
            -- ExtraneousScriptWitnesses phase-1 failure (empty-fold's empty
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
                       | null refs
                       , m <- rdMints duties
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
            in  AssetName (SBS.toShort bs) == unTokenId (fsTid fs)
        _ -> False

{- | Assemble with an iterated fee: assemble, let the ledger price
the transaction, and repeat until the declared fee exceeds the
estimate by a fixed margin. Too small a margin fails loudly at
submit (phase 1, no script named); too large fails loudly in
assembly (a refund under min-ADA).
-}
assembleFoldWithFee :: Env -> FoldSpec -> IO ConwayTx
assembleFoldWithFee env0 fs =
    Cage.withView (envProv env0) $ \held -> go (pinnedTo held env0) (0 :: Int) 1_500_000
  where
    go env n fee = do
        tx <- assembleFoldSpec env fs{fsFee = Just fee}
        pp <- Cage.withView (envProv env) (pure . Cage.viewProtocolParams)
        -- Conway charges for the reference scripts a transaction reads,
        -- by their size. Estimating against zero of them stops this loop
        -- one fee short and the node refuses the result.
        let refBytes = sum (map (refScriptSize . snd) (fsRefs fs))
            Coin est = estimateMinFeeTx pp tx 1 0 refBytes
            needed = est + 50_000
        if fee >= needed || n >= (5 :: Int)
            then pure tx
            else go env (n + 1) needed

{- | The spec's chain inputs as the held view has them. A row reads its
state, requests, funder and holders before it assembles, and computes
refunds and roots from them; the assembly finds each again in its own view
and refuses, by name, an input that is gone there or holds something
else — so every chain value the transaction carries is the held view's.
-}
heldInputs :: Cage.View IO -> FoldSpec -> IO ()
heldInputs v fs = do
    heldInput v "state" (fsState fs)
    mapM_ (heldInput v "request") (fsReqs fs)
    mapM_ (heldInput v "holder") (fsHolderUtxos fs)
    mapM_ (heldInput v "funder") (fsFunder fs)

{- | One input the assembly spends, found in the held view at its address
with the address, value, datum and reference script the row read;
refused by name when it is not unspent there or holds something else.
-}
heldInput
    :: Cage.View IO -> String -> (TxIn, TxOut ConwayEra) -> IO ()
heldInput v what (i, o) = do
    here <- Cage.viewUTxOsAt v (o ^. addrTxOutL)
    case lookup i here of
        Nothing ->
            failWith
                ( "hand-build: the "
                    <> what
                    <> " input "
                    <> show i
                    <> " is not unspent at the assembly's chain point"
                )
        Just o'
            | carried o' /= carried o ->
                failWith
                    ( "hand-build: the "
                        <> what
                        <> " input "
                        <> show i
                        <> " changed between the row's read and the assembly's view"
                    )
            | otherwise -> pure ()
  where
    carried out =
        ( out ^. addrTxOutL
        , out ^. valueTxOutL
        , out ^. datumTxOutL
        , out ^. referenceScriptTxOutL
        )

{- | A FoldSpec with this cage's defaults: derive refunds and
signers, no withdrawal, no state override, deadline validity.
-}
rowSpec
    :: RowCage
    -> TokenId
    -> (TxIn, TxOut ConwayEra)
    -> [(TxIn, TxOut ConwayEra)]
    -> [RequestAction]
    -> Root
    -> ExUnits
    -> FoldSpec
rowSpec cage tid state reqs actions root units =
    FoldSpec
        { fsCfg = rcCfg cage
        , fsTid = tid
        , fsState = state
        , fsReqs = reqs
        , fsActions = actions
        , fsNewRoot = root
        , fsUnits = units
        , fsPurposeUnits = Map.empty
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
        , fsExtraOutputs = []
        }

{- | Twice the measured units: the declared budget of a refusing
fold. A cage with no measured fold yet (its rows refuse before
above anything a script consumes before erroring, far below the
per-purpose phase-2 ceiling, and small enough that the node's
rejection payload stays inside the local channel's limits.
-}
declaredSpec :: Env -> RowCage -> IO ExUnits
declaredSpec env cage = do
    (mem, cpu) <- readIORef (rcUnits cage)
    case (mem, cpu) of
        (m, c) | m > 0 -> pure (declaredUnits (m, c))
        _ -> do
            pp <- Cage.withView (envProv env) (pure . Cage.viewProtocolParams)
            let ExUnits maxMem maxSteps = pp ^. ppMaxTxExUnitsL
                fallback =
                    ExUnits
                        (maxMem `div` 100)
                        (maxSteps `div` 20)
            emit
                "units"
                "no measured fold in this cage; declaring 1% mem / 5% cpu of the maxima"
            pure fallback

{- | One row cage's request-and-fold cycle through the library
builder, with the calibration the hand-built shapes inherit their
credibility from: submit the request, build the library fold over
all pending requests, build the hand parallel, compare, measure,
submit, commit the trie.
-}
rowRequestAndFold
    :: Env
    -> RowCage
    -> String
    -> ByteString
    -> ByteString
    -> Edge
    -> IO (ConwayTx, Integer, Integer, Integer)
rowRequestAndFold env cage label key _val _op = do
    let cfg = rcCfg cage
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
    -- The library fold and the hand model it is calibrated against are
    -- assembled from one view.
    (unsignedFold, stateIn, handFold) <- withHeldView env $ \held -> do
        lib <- Cage.withView (envProv held) $ \v -> do
            ctx <- rowRegistryContext held v cage tid
            updateTokenWithDuties cfg v (envTm held) tid genesisAddr ctx
        state@(stateIn, _) <- cageStateUtxo held cage
        reqUtxos <- pendingRequests held cage
        (handProofs, handRoot) <- speculativeApplyAll held cage tid reqUtxos
        pp <- Cage.withView (envProv held) (pure . Cage.viewProtocolParams)
        let ExUnits maxMem maxSteps = pp ^. ppMaxTxExUnitsL
            calibSpec =
                ( rowSpec
                    cage
                    tid
                    state
                    reqUtxos
                    (map Update handProofs)
                    handRoot
                    (ExUnits maxMem maxSteps)
                )
                    { fsFee = Just 700_000
                    }
        hand <- assembleFoldSpec held calibSpec
        pure (lib, stateIn, hand)
    calibrateFold stateIn handFold unsignedFold
    emit "calibration" (label <> ": hand model matches the library fold")
    (mem, cpu) <- measureUnits env unsignedFold
    writeIORef (rcUnits cage) (mem, cpu)
    signed <- submitWithGenesis (envCaps env) unsignedFold
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

{- | Proofs and root for valid folds, replicating the library's
per-request processing through the same speculative trie.
-}
validProofs
    :: Env -> [(TxIn, TxOut ConwayEra)] -> IO ([[ProofStep]], Root)
validProofs env reqUtxos =
    withSpeculativeTrie (envTm env) (envTid env) $ \trie -> do
        ps <- mapM (processOne trie) reqUtxos
        r <- CageTrie.getRoot trie
        pure (ps, r)
  where
    -- The key and the edge are the request's own, read from its datum
    -- exactly as the library builder reads them: the rows no longer
    -- share one (#157 read-preserves-intermediate-root: a read proves its key and leaves it alone,
    -- which `walkEdge` already knows).
    processOne trie (_, txOut) = walkEdge trie key edge
      where
        (key, edge) = case extractCageDatum txOut of
            Just (RequestDatum rq) -> (requestKey rq, requestEdge rq)
            _ -> error "hand-build: pending UTxO has no request datum"

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
        in  Map.lookup (ConwaySpending (AsIx idx)) m
    redeemerKeys tx =
        let Redeemers m = tx ^. witsTxL . rdmrsTxWitsL
        in  Map.keys m

{- | The duties context for a fold spec, from its own cage configuration
and the reference outputs it carries, read from the view the fold is
built in.
-}
foldSpecContext
    :: Env -> Cage.View IO -> FoldSpec -> IO RegistryContext
foldSpecContext env0 v fs = do
    let env = pinnedTo v env0
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
            , rcHolderReleases = Map.empty
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
