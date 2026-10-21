{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Registry.TxBuilder.ConnectedFold
Description : Permissionless fold of booked requests with attached actions
License     : Apache-2.0

One transaction binding the fold of the registry's booked requests: the
registry state UTxO spent through @Modify@ with one trie proof per member, every
member spent through @Contribute@, plus caller-attached spends (naming claims),
mints (approvals, singular tags, the registration's application tag burn) and
outputs (naming records). No owner signature anywhere — the #79 permissionless
repair made @Modify@ owner-free, and this builder never asks for one.

A member is a genuine booked request ('bookedRequestOf'): a registration or a
termination at the registry's request address, holding the trie-ready tag its
own datum commits to under the request policy. A legacy untagged request, an
untagged output at the request address and a forged tag are refused before
anything is built; there is no fallback. The state is never spent to reject.

The fold states, in the ledger's input order, one update per member (an
insertion for a registration, the active-to-terminal replacement for a
termination); burns the trie-ready tag of every member under the request
policy; delivers each registration's carrier to its booked destination with
its booked datum; and donates each registration's cost and each termination's
held value less its tip to the treasury. A registration folds only inside its
processing window and not before it was booked; a termination has no window.
The caller attaches the mints of the selected members only: the application
tag burn of a registration and the singular tag moves.

The transaction library states no treasury donation and its balancer ignores
one. So the program holds the donation's lovelace in a placeholder output
beside the real ones, which makes the library balance, price and evaluate the
body as if that lovelace were paid out; the placeholder is then replaced by
the donation field and nothing else changes: the fee, the change, the declared
units and the script-integrity hash stay the ones the library settled. The
scripts, which check that lovelace is conserved, are shown that very body
(placeholder gone, donation set, the folder's change) in every evaluation, and
the finished body is evaluated once more: a fold whose scripts refuse it, or
whose declared units do not cover the units measured on it, is not returned.

A fold is also not returned when the ledger would refuse its final body for a
reason no script and no balancer here would catch ('finalBodyRefusals'): an
output under its minimum lovelace (the state continuation, a carrier, an
attached output, the change, the collateral return), declared units that add
up beyond the transaction limit, a transaction too large once its witnesses are
counted, scripts referenced by the inputs and the reference inputs that add up
beyond what the ledger lets one transaction reference, a fee under the minimum
(reference scripts of the inputs and of the reference inputs included),
collateral absent, insufficient or incoherent, and
a body that does not balance or whose script-integrity hash is not that of its
redeemers, together with the ledger's own tests of the rest of its rules for a
body of this shape (references against spent inputs, addresses against the
network, output values, the scripts, redeemers and datums a body needs). These
refuse to *build* and read the acquired session's parameters;
the booked allocations are exact and never changed to make a body pass, so
they say nothing against a booking's economic admission. With evaluation
skipped (the adversarial mode) none of them is applied.

This is the single canonical permissionless-fold implementation for
issue #77's runners (register, recovery, retirement). Its lineage is
@offchain/journey/repair/Main.hs@'s @foldRequestsTx@ \/
@buildPermissionlessProgram@ (issue #79, frozen): the registry program,
proof computation and upper-slot rule are transcribed from there, extended
with the attached naming actions. The repair runner keeps its own copy;
nothing here changes it.
-}
module Singular.Registry.TxBuilder.ConnectedFold
    ( RawRedeemer (..)
    , ConnectedSpend (..)
    , ConnectedMint (..)
    , ConnectedFoldArgs (..)
    , connectedFoldTx
    , FoldProofs
    , managerProofs
    , connectedFoldWith
    , connectedFoldAt
    , FinalFacts (..)
    , finalBodyRefusals
    , bookedMove
    , syncFoldedRequests
    , generousUnits
    , skipEvalUnits
    ) where

import Control.Monad (forM_, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.List (intercalate, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Void (Void)
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC

import Cardano.Ledger.Address (Addr (..), decodeAddrEither)
import Cardano.Ledger.Alonzo.Rules
    ( hasExactSetOfRedeemers
    , missingRequiredDatums
    , validateOutputTooBigUTxO
    )
import Cardano.Ledger.Alonzo.TxBody (scriptIntegrityHashTxBodyL)
import Cardano.Ledger.Api.PParams
    ( ppCollateralPercentageL
    , ppMaxBlockExUnitsL
    , ppMaxCollateralInputsL
    , ppMaxTxExUnitsL
    , ppMaxTxSizeL
    )
import Cardano.Ledger.Api.Tx (bodyTxL, estimateMinFeeTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , collateralReturnTxBodyL
    , feeTxBodyL
    , inputsTxBodyL
    , mintTxBodyL
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , totalCollateralTxBodyL
    , treasuryDonationTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , coinTxOutL
    , datumTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits
    ( Redeemers (..)
    , rdmrsTxWitsL
    , scriptTxWitsL
    )
import Cardano.Ledger.Babbage.Rules
    ( babbageMissingScripts
    , disjointRefInputs
    , validateFailedBabbageScripts
    , validateScriptsWellFormed
    )
import Cardano.Ledger.Babbage.UTxO (getReferenceScripts)
import Cardano.Ledger.BaseTypes (Network, StrictMaybe (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway.PParams (ConwayEraPParams (..))
import Cardano.Ledger.Conway.UTxO (txNonDistinctRefScriptsSize)
import Cardano.Ledger.Core (Script, sizeTxF)
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Keys (KeyHash, KeyRole (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID
    )
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.Rules.ValidationMode (Test)
import Cardano.Ledger.Shelley.Rules
    ( validateOutputBootAddrAttrsTooBig
    , validateWrongNetwork
    )
import Cardano.Ledger.State
    ( EraUTxO (getScriptsHashesNeeded, getScriptsNeeded, getScriptsProvided)
    , UTxO (..)
    )
import Cardano.Ledger.Tools (addDummyWitsTx)
import Cardano.Ledger.Val (inject, (<+>), (<->))
import Cardano.Slotting.Slot (SlotNo)
import PlutusTx.Builtins.Internal (BuiltinData (..))
import PlutusTx.IsData.Class (ToData (..))
import Validation (Validation (..))

import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)
import Cardano.Tx.Witnesses (estimatedKeyWitnessCount)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.FoldAdmission
    ( admissionReason
    , admissionSource
    , foldAdmission
    , mintReason
    , mintSource
    , refusalBound
    , refusalDeadline
    , refusalRef
    )
import Singular.Registry.Ledger
    ( ConwayEra
    , PParams
    , Root (..)
    , TokenId (..)
    , TxIn
    )
import Singular.Registry.LedgerProvider (Session, TipObservation (..))
import Singular.Registry.SessionIO (parameters)
import Singular.Registry.SessionIO qualified as Services
import Singular.Registry.Trie
    ( Trie (..)
    , TrieManager (..)
    )
import Singular.Registry.TxBuilder.Internal.Edges
import Singular.Registry.TxBuilder.Internal.Identity
import Singular.Registry.TxBuilder.Internal.Lookup
    ( BookedRequest (..)
    , bookedRequestOf
    , computeScriptIntegrity
    , currentPosixMs
    , requestPolicyOf
    , totalWithinLimit
    , tryUpperSlots
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRegistrationRequest (..)
    , OnChainRequest (..)
    , OnChainRoot (..)
    , OnChainTerminationRequest (..)
    , OnChainTokenState (..)
    , ProofStep
    , RequestAction (..)
    , UpdateRedeemer (..)
    , edgeInsertActive
    , edgeUpdateTerminal
    , terminationTrieReadyTagName
    , trieReadyTagName
    )

-- | A raw Plutus-data redeemer for attached (non-registry) purposes.
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
    , cfaSession :: Session NoWitness IO
    -- ^ The view the fold is built from: parameters, evaluation, slots
    , cfaTrie :: TrieManager IO
    , cfaToken :: TokenId
    , cfaFeeAddr :: Addr
    , cfaStateUtxo :: (TxIn, TxOut ConwayEra)
    , cfaReqUtxos :: [(TxIn, TxOut ConwayEra)]
    , cfaFeeUtxo :: (TxIn, TxOut ConwayEra)
    , cfaSpends :: [ConnectedSpend]
    , cfaMints :: [ConnectedMint]
    , cfaOutputs :: [TxOut ConwayEra]
    , cfaSigners :: [KeyHash Guard]
    , cfaRefUtxos :: [(TxIn, TxOut ConwayEra)]
    , cfaAttachScripts :: [Script ConwayEra]
    , cfaSkipEval :: Bool
    {- ^ Skip local script evaluation, stating generous budgets instead,
    so the LEDGER executes every purpose for real. Adversarial use
    only: the duplicate fold must be refused on-chain (attributed to
    the refusing script) rather than at local estimation.
    -}
    , cfaAdjustRoot :: Root -> Root
    }

-- | One member of the fold: a genuine booked request, with the output that holds it.
data Member = Member
    { memberRef :: TxIn
    , memberOut :: TxOut ConwayEra
    , memberRequest :: BookedRequest
    }

-- | The key the member's request names.
memberKey :: Member -> ByteString
memberKey m = case memberRequest m of
    BookedRegistration r -> regKey r
    BookedTermination t -> termKey t

-- | The trie-ready tag the member's own datum commits to.
memberTag :: Member -> ByteString
memberTag m = case memberRequest m of
    BookedRegistration r -> trieReadyTagName r
    BookedTermination t -> terminationTrieReadyTagName t

-- | The registrations among the members, with the output reference that holds each.
registrationsOf :: [Member] -> [(TxIn, OnChainRegistrationRequest)]
registrationsOf members =
    [ (memberRef m, r)
    | m <- members
    , BookedRegistration r <- [memberRequest m]
    ]

refuse :: String -> IO a
refuse = ioError . userError . ("connectedFold: " <>)

{- | The members of a fold, in the ledger's input order: every request must be
a genuine booked request of this registry.
-}
membersOf
    :: CageConfig -> TokenId -> [(TxIn, TxOut ConwayEra)] -> IO [Member]
membersOf cfg tid requests = do
    members <-
        traverse
            ( \(ref, out) -> case bookedRequestOf cfg tid out of
                Just booked -> pure (Member ref out booked)
                Nothing ->
                    refuse
                        ( "request "
                            <> show ref
                            <> " is not a genuine tagged request of this registry"
                        )
            )
            (sortOn fst requests)
    when (null members) $ refuse "no request to fold"
    pure members

{- | At most one request per key in a fold: the selection leaves a second
request on an included key out, so a batch that names a key twice, as two
registrations or as a registration and the termination of what it creates, is
a directly chosen set, refused before anything is built.
-}
guardOneRequestPerKey :: [Member] -> IO ()
guardOneRequestPerKey members =
    unless (Set.size (Set.fromList keys) == length keys) $
        refuse "two requests name the same key (key-in-batch)"
  where
    keys = map memberKey members

{- | In the mode that skips evaluation the scripts do not check the mint, so
the batch's claimed mint under the registry's own token policies must equal
the keyed delta of its members: one singular tag created per registration and
one burned per termination. A mint under any other policy is attached
application business, neither counted nor refused.
-}
guardMintMatch :: CageConfig -> [Member] -> [ConnectedMint] -> IO ()
guardMintMatch cfg members mints =
    unless (strip claimed == strip owed) $
        refuse
            ( "the batch's claimed mint differs from its members' keyed delta: "
                <> mintReason
                <> " ("
                <> mintSource
                <> ")"
            )
  where
    active = policyIdFromPin (cfgActivePolicy cfg)
    registryPolicies =
        map
            policyIdFromPin
            [cfgActivePolicy cfg, cfgAbsentPolicy cfg, cfgTerminalPolicy cfg]
    strip = Map.filter (/= 0)
    summed = Map.fromListWith (+)
    claimed =
        summed
            [ ((cmPolicy m, asset), quantity)
            | m <- mints
            , cmPolicy m `elem` registryPolicies
            , (asset, quantity) <- Map.toList (cmAssets m)
            ]
    owed =
        summed
            [ ((active, AssetName (SBS.toShort (memberKey m))), delta m)
            | m <- members
            ]
    delta m = case memberRequest m of
        BookedRegistration _ -> 1
        BookedTermination _ -> -1

{- | The proofs a fold states for its members, given in the ledger's input
order, and the root they lead to.
-}
type FoldProofs = [(TxIn, BookedRequest)] -> IO ([[ProofStep]], Root)

{- | The key a booked request names and the edge the model takes it through:
an insertion for a registration, the active-to-terminal replacement for a
termination.
-}
bookedMove :: BookedRequest -> (ByteString, Integer)
bookedMove = \case
    BookedRegistration r -> (regKey r, edgeInsertActive)
    BookedTermination t -> (termKey t, edgeUpdateTerminal)

{- | Build the connected fold transaction (unsigned), returning the
computed new root the state continuation carries. The proofs come from the
manager's speculative trie.
-}
connectedFoldTx :: ConnectedFoldArgs -> IO (ConwayTx, Root)
connectedFoldTx args =
    connectedFoldWith (managerProofs (cfaTrie args) (cfaToken args)) args

{- | The fold of 'connectedFoldTx' with the proofs supplied by the caller, for a
caller whose proofs come from an authenticated trie snapshot rather than a
manager; the manager of the arguments is then never read.
-}
connectedFoldWith
    :: FoldProofs -> ConnectedFoldArgs -> IO (ConwayTx, Root)
connectedFoldWith proofsFor args = do
    observed <- Services.tip (cfaSession args)
    connectedFoldAt observed proofsFor args

{- | The fold of 'connectedFoldWith' built from a tip the caller has already
observed, for a caller that judged its requests against that same observation:
a build takes one observation of the tip, and a wait for the ledger's horizon
reads the tip again only from there.
-}
connectedFoldAt
    :: TipObservation
    -> FoldProofs
    -> ConnectedFoldArgs
    -> IO (ConwayTx, Root)
connectedFoldAt observed proofsFor args = do
    let cfg = cfaCfg args
        view = cfaSession args
        tid = cfaToken args
        feeAddr = cfaFeeAddr args
        (stateIn, stateOut) = cfaStateUtxo args
        feeUtxo = cfaFeeUtxo args
    members <- membersOf cfg tid (cfaReqUtxos args)
    -- the model orders the keyed mint before the pair of a batch
    when (cfaSkipEval args) $ guardMintMatch cfg members (cfaMints args)
    guardOneRequestPerKey members
    pp <- parameters view
    (proofs, newRoot) <-
        proofsFor [(memberRef m, memberRequest m) | m <- members]
    let adjustedRoot = cfaAdjustRoot args newRoot
        (oldState, newStateOut, script) =
            prepareState cfg stateOut adjustedRoot
        requestScript = mkRequestScript cfg tid
        processTime = stateProcessTime oldState
        registrations = registrationsOf members
        windowed = [(ref, regSubmittedAt r) | (ref, r) <- registrations]
        carriers = [carrierOutput cfg r | (_, r) <- registrations]
        donation = Coin (sum (map owedDonation members))
        -- the donation's lovelace, paid out in the library's eyes
        placeholder = [mkBasicTxOut feeAddr (inject donation) | donation /= Coin 0]
    tipStartMs <- Services.slotStart view (observedSlot observed)
    -- a registration folds only while its window is open
    maybe
        (pure ())
        refuseWindow
        (foldAdmission processTime tipStartMs windowed)
    (lowerSlot, upperSlot) <-
        foldInterval
            view
            (observedSlot observed)
            processTime
            (map snd registrations)
    boundMs <- Services.slotStart view upperSlot
    maybe
        (pure ())
        refuseWindow
        (foldAdmission processTime boundMs windowed)
    unless (lowerSlot < upperSlot) $ refuse "the fold's interval is empty"
    let spendUtxos = map csUtxo (cfaSpends args)
        known =
            Map.fromList
                ( feeUtxo
                    : cfaStateUtxo args
                    : map (\m -> (memberRef m, memberOut m)) members <> spendUtxos
                )
        programOutputs = 1 + length carriers + length (cfaOutputs args)
        -- the scripts judge the body with its change and its donation
        settled = settledForScripts known programOutputs feeAddr donation
        evaluate tx = do
            r <- Services.evaluateTx view (settled tx)
            pure $
                Map.map
                    ( \case
                        Left e -> Left (show e)
                        Right eu -> Right eu
                    )
                    r
        evalTx
            | cfaSkipEval args = \tx -> do
                let Redeemers rdmrs = tx ^. witsTxL . rdmrsTxWitsL
                    units =
                        skipEvalUnits
                            (pp ^. ppMaxTxExUnitsL)
                            (pp ^. ppMaxBlockExUnitsL)
                            (Map.size rdmrs)
                pure (Map.map (const (Right units)) rdmrs)
            | otherwise = evaluate
        prog =
            buildProgram
                (requestPolicyOf cfg tid)
                stateIn
                members
                feeUtxo
                newStateOut
                carriers
                script
                requestScript
                proofs
                lowerSlot
                upperSlot
                (cfaSpends args)
                (cfaMints args)
                (cfaOutputs args)
                placeholder
                (cfaSigners args)
                (cfaRefUtxos args)
                (cfaAttachScripts args)
    result <-
        Tx.build
            (Tx.mkPParamsBound pp)
            (Tx.InterpretIO (const (pure undefined)))
            evalTx
            (Map.toList known)
            (cfaRefUtxos args)
            feeAddr
            (prog :: Tx.TxBuild NoCtx Void ())
    case result of
        Left err -> refuse ("build failed: " <> show err)
        Right built -> do
            final <- settleDonation pp known programOutputs feeAddr donation built
            unless (cfaSkipEval args) $ do
                let facts =
                        FinalFacts
                            { ffParams = pp
                            , ffNetwork = network cfg
                            , ffInputs = known
                            , ffReferences = cfaRefUtxos args
                            , ffLabel = outputLabel members carriers programOutputs
                            }
                case finalBodyRefusals facts final of
                    [] -> pure ()
                    refusals ->
                        refuse
                            ( "the fold is not built, because the ledger would refuse its final body (the booked allocation is exact and unchanged): "
                                <> intercalate "; " refusals
                            )
                judged <- evaluate final
                let Redeemers declared = final ^. witsTxL . rdmrsTxWitsL
                unless (Map.keysSet judged == Map.keysSet declared) $
                    refuse
                        ( "the built fold declares units for "
                            <> show (Map.size declared)
                            <> " purposes but "
                            <> show (Map.size judged)
                            <> " were evaluated on it"
                        )
                forM_ (Map.toList judged) $ \(purpose, outcome) -> case outcome of
                    Left e ->
                        refuse
                            ( "the built fold is refused by its own scripts: "
                                <> show purpose
                                <> ": "
                                <> e
                            )
                    Right measured@(ExUnits m s) -> case Map.lookup purpose declared of
                        Just (_, ExUnits dm ds) | m <= dm && s <= ds -> pure ()
                        other ->
                            refuse
                                ( "the built fold declares units that do not cover those measured on it: "
                                    <> show purpose
                                    <> ": measured "
                                    <> show measured
                                    <> ", declared "
                                    <> show (fmap snd other)
                                )
            pure (final, newRoot)
  where
    refuseWindow refusal =
        refuse
            ( "the fold is not built: "
                <> admissionReason
                <> " ("
                <> admissionSource
                <> "): request "
                <> show (refusalRef refusal)
                <> " has processing deadline "
                <> show (refusalDeadline refusal)
                <> " ms, which the fold's bound "
                <> show (refusalBound refusal)
                <> " ms passes"
            )

{- | The validity interval of a fold. With registrations it opens no earlier
than the latest booking and closes at the earliest processing deadline, held
inside the ledger's horizon. With none, a termination has no window: as the
retired reject was, it is admitted in every window, so it starts at the
acquired view's tip, the clock choosing only the upper bound with shorter
horizons tried as needed, and keeps that bound after the tip even when the
clock is behind it.
-}
foldInterval
    :: Session NoWitness IO
    -> SlotNo
    -> Integer
    -> [OnChainRegistrationRequest]
    -> IO (SlotNo, SlotNo)
foldInterval view tipSlot processTime = \case
    [] -> do
        -- A tip supplies the lower slot directly, but both ledger bounds
        -- must remain inside this view's validated finite conversion context.
        _ <- Services.slotStart view tipSlot
        now <- currentPosixMs
        clockSlot <-
            tryUpperSlots view $
                map (now +) [120_000, 60_000, 30_000, 10_000, 5_000, 2_000, 1_000]
        let wanted = max (tipSlot + 1) clockSlot
        _ <- Services.slotStart view wanted
        upper <- Services.validityUpper view tipSlot (Just tipSlot) wanted
        pure (tipSlot, upper)
    registrations -> do
        lower <-
            Services.ceilingSlot view (maximum (map regSubmittedAt registrations))
        deadline <-
            Services.floorSlot
                view
                (minimum [regSubmittedAt r + processTime | r <- registrations])
        upper <- Services.validityUpper view tipSlot (Just lower) deadline
        pure (lower, upper)

{- | What a member owes the treasury: a registration its cost, a termination
the value its request holds less its tip.
-}
owedDonation :: Member -> Integer
owedDonation m = case memberRequest m of
    BookedRegistration r -> regRegistrationCost r
    BookedTermination t ->
        let Coin held = memberOut m ^. coinTxOutL in held - termDeclaredTip t

{- | The body the scripts are judged on: the program's own outputs, then one
change output to the folder carrying what the inputs and the mint leave after
the outputs, the fee and the donation, and the donation. The transaction
library balances without a donation and judges the body before it has a
change, so the scripts, which check that lovelace is conserved, are shown the
body as it will be.
-}
settledForScripts
    :: Map TxIn (TxOut ConwayEra)
    -> Int
    -> Addr
    -> Coin
    -> ConwayTx
    -> ConwayTx
settledForScripts known programOutputs changeAddr donation tx =
    tx
        & bodyTxL . outputsTxBodyL .~ (kept StrictSeq.|> change)
        & bodyTxL . treasuryDonationTxBodyL .~ donation
  where
    body = tx ^. bodyTxL
    kept = StrictSeq.take programOutputs (body ^. outputsTxBodyL)
    Coin fee = body ^. feeTxBodyL
    Coin owed = donation
    consumed =
        foldl'
            (<+>)
            (MaryValue (Coin 0) (body ^. mintTxBodyL))
            [ o ^. valueTxOutL
            | i <- Set.toList (body ^. inputsTxBodyL)
            , Just o <- [Map.lookup i known]
            ]
    paid =
        foldl'
            (<+>)
            (inject (Coin (fee + owed)))
            (map (^. valueTxOutL) (toList kept))
    MaryValue (Coin left) (MultiAsset assets) = consumed <-> paid
    change =
        mkBasicTxOut
            changeAddr
            ( MaryValue
                (Coin (max 0 left))
                ( MultiAsset
                    (Map.filter (not . Map.null) (Map.map (Map.filter (> 0)) assets))
                )
            )

{- | Replace the donation's placeholder by the donation. The placeholder sits
right after the program's own outputs and the library's change right after it;
removing it and stating its lovelace as the donation leaves lovelace conserved
by construction, and leaves the fee, the change, the declared units, the
collateral and the script-integrity hash as the library settled them for a body
that paid the same lovelace out. What is returned is refused when it does not
conserve lovelace, or when the folder's change cannot carry its minimum ada.
-}
settleDonation
    :: PParams ConwayEra
    -> Map TxIn (TxOut ConwayEra)
    -> Int
    -> Addr
    -> Coin
    -> ConwayTx
    -> IO ConwayTx
settleDonation pp known programOutputs changeAddr donation built
    | donation == Coin 0 = pure built
    | otherwise = do
        unless holdsPlaceholder $
            refuse
                "the balanced body does not hold the donation's placeholder where it was put"
        unless (conserves final) $
            refuse "the finished body does not conserve lovelace"
        case toList after of
            [change]
                | change ^. addrTxOutL == changeAddr
                    && change ^. coinTxOutL >= getMinCoinTxOut pp change ->
                    pure final
            _ ->
                refuse
                    "the folder's funding cannot carry the change that the fee and the donation leave"
  where
    outs = built ^. bodyTxL . outputsTxBodyL
    before = StrictSeq.take programOutputs outs
    after = StrictSeq.drop (programOutputs + 1) outs
    holdsPlaceholder = case StrictSeq.lookup programOutputs outs of
        Just o -> o ^. addrTxOutL == changeAddr && o ^. coinTxOutL == donation
        Nothing -> False
    final =
        built
            & bodyTxL . outputsTxBodyL .~ (before <> after)
            & bodyTxL . treasuryDonationTxBodyL .~ donation
    conserves tx =
        let body = tx ^. bodyTxL
            lovelace (Coin c) = c
            inputs =
                sum
                    [ lovelace (o ^. coinTxOutL)
                    | i <- Set.toList (body ^. inputsTxBodyL)
                    , Just o <- [Map.lookup i known]
                    ]
            paid =
                sum
                    (map (lovelace . (^. coinTxOutL)) (toList (body ^. outputsTxBodyL)))
                    + lovelace (body ^. treasuryDonationTxBodyL)
                    + lovelace (body ^. feeTxBodyL)
        in  inputs == paid

{- | What the finished body is judged against: the acquired protocol
parameters, every input the body spends or offers as collateral resolved to
its output, the outputs its reference inputs name, and what each output is.
-}
data FinalFacts = FinalFacts
    { ffParams :: PParams ConwayEra
    , ffNetwork :: Network
    -- ^ The network the registry lives on, which every output's address must name
    , ffInputs :: Map TxIn (TxOut ConwayEra)
    , ffReferences :: [(TxIn, TxOut ConwayEra)]
    , ffLabel :: Int -> String
    }

{- | Everything the ledger's rules would refuse about the finished body that
the transaction library does not itself enforce, each refusal worded for what
it is: the fold cannot be built, the booked allocation being exact and
unchanged, which says nothing against the booking's economic admission. An
empty list is a body that satisfies every one of them. The rules are the
protocol's, read from the parameters the acquired session gave, and they are
judged on the body that will be signed, with the witnesses it still needs:

* every output, the collateral return included, holds its minimum lovelace;
* the declared execution units, summed, fit the transaction limit in memory and
  in steps (each purpose fitting its own declaration is not that);
* the serialized transaction, with the key witnesses it still needs, fits the
  transaction size limit;
* the scripts that the inputs and the reference inputs carry, each occurrence
  counted as the ledger counts it, add up to no more than the ledger allows
  one transaction to reference (an era constant, read through the
  parameters), which neither the serialized size nor the fee bounds;
* the fee covers the minimum of that transaction, reference scripts of the
  inputs and of the reference inputs included;
* collateral is present, key-locked, not more inputs than allowed, returns what
  it does not collateralise, states a total that agrees with them, and covers
  the fee at the protocol's percentage;
* inputs, mint, outputs, donation and fee balance in lovelace and in every
  asset;
* the script-integrity hash is that of the redeemers the body declares;
* the rest of the rules of the ledger that a body of this shape can still
  break, asked of the ledger's own tests (the functions its rules call): no
  input also referenced where the protocol forbids it, every output's address on
  the registry's network, no bootstrap address with attributes over the limit,
  no output whose value is over the limit, the scripts the body needs
  provided and none other (native scripts validating), the redeemers and
  datums those scripts need present and no others, and every script well
  formed.

Not established here, because nothing before the signature can: the signatures
themselves, the validity of the interval against a future slot, and inclusion.
-}
finalBodyRefusals :: FinalFacts -> ConwayTx -> [String]
finalBodyRefusals facts tx =
    concat
        [ minima
        , executionTotal
        , serializedSize
        , referenceScriptCap
        , minimumFee
        , collateral
        , conservation
        , integrity
        , ledgerRules
        ]
  where
    pp = ffParams facts
    body = tx ^. bodyTxL
    Redeemers declared = tx ^. witsTxL . rdmrsTxWitsL
    outs = toList (body ^. outputsTxBodyL)
    spent = body ^. inputsTxBodyL
    collateralIns = body ^. collateralInputsTxBodyL
    resolved = ffInputs facts
    coinOf (Coin c) = c
    fee = coinOf (body ^. feeTxBodyL)
    unresolved =
        [ i
        | i <- Set.toList (spent <> collateralIns)
        , Map.notMember i resolved
        ]
    keyWitnesses =
        estimatedKeyWitnessCount
            body
            (spent <> collateralIns)
            (Map.toList resolved)

    minima =
        [ "the ledger would refuse an output of the fold: "
            <> intercalate
                "; "
                [ what
                    <> " holds "
                    <> show held
                    <> " lovelace, under the "
                    <> show needed
                    <> " the ledger requires of it"
                | (what, held, needed) <- short
                ]
        | not (null short)
        ]
      where
        short =
            [ (what, coinOf (out ^. coinTxOutL), coinOf (getMinCoinTxOut pp out))
            | (what, out) <-
                zip (map (ffLabel facts) [0 ..]) outs
                    <> [ ("the collateral return", r)
                       | SJust r <- [body ^. collateralReturnTxBodyL]
                       ]
            , out ^. coinTxOutL < getMinCoinTxOut pp out
            ]

    executionTotal =
        case totalWithinLimit
            (pp ^. ppMaxTxExUnitsL)
            (map snd (Map.elems declared)) of
            Right _ -> []
            Left (ExUnits m st) ->
                let ExUnits lm ls = pp ^. ppMaxTxExUnitsL
                in  [ "the declared execution units add up to memory "
                        <> show m
                        <> ", steps "
                        <> show st
                        <> ", over the transaction limit of memory "
                        <> show lm
                        <> ", steps "
                        <> show ls
                    ]

    serializedSize =
        let witnessed = addDummyWitsTx pp tx keyWitnesses []
            size = toInteger (witnessed ^. sizeTxF)
            limit = toInteger (pp ^. ppMaxTxSizeL)
        in  [ "the transaction is "
                <> show size
                <> " bytes with the "
                <> show keyWitnesses
                <> " key witnesses it still needs, over the limit of "
                <> show limit
            | size > limit
            ]

    -- the ledger's own count of the scripts the spent and the reference inputs
    -- carry: one occurrence per input, so copies at distinct inputs all count
    refBytes =
        txNonDistinctRefScriptsSize
            (UTxO (Map.fromList (Map.toList resolved <> ffReferences facts)))
            tx

    -- The rules of the ledger that a body of this shape can still break, asked
    -- of the ledger's own tests (the functions its rules call), over the
    -- resolved inputs and the reference outputs: the references against the
    -- spent inputs, each output's address, bootstrap attributes and value, the
    -- scripts the body needs against those it provides, the redeemers and
    -- datums those scripts need, and every script's form.
    ledgerView = UTxO (Map.fromList (Map.toList resolved <> ffReferences facts))
    allOutputs = outs <> [r | SJust r <- [body ^. collateralReturnTxBodyL]]
    scriptsNeeded' = getScriptsNeeded ledgerView body
    scriptsProvided' = getScriptsProvided ledgerView tx
    neededHashes = getScriptsHashesNeeded scriptsNeeded'
    referenceScripts =
        Map.keysSet
            ( getReferenceScripts
                ledgerView
                (spent <> body ^. referenceInputsTxBodyL)
            )
    witnessScripts = Map.keysSet (tx ^. witsTxL . scriptTxWitsL)
    ledgerRules
        | not (null unresolved) = []
        | otherwise =
            concat
                [ ledgerTest
                    (disjointRefInputs pp spent (body ^. referenceInputsTxBodyL))
                , ledgerTest (validateOutputTooBigUTxO pp allOutputs)
                , ledgerTest (validateOutputBootAddrAttrsTooBig allOutputs)
                , ledgerTest (validateWrongNetwork (ffNetwork facts) allOutputs)
                , ledgerTest
                    (babbageMissingScripts pp neededHashes referenceScripts witnessScripts)
                , ledgerTest
                    (validateFailedBabbageScripts tx scriptsProvided' neededHashes)
                , ledgerTest (missingRequiredDatums ledgerView tx)
                , ledgerTest (hasExactSetOfRedeemers tx scriptsProvided' scriptsNeeded')
                , ledgerTest (validateScriptsWellFormed pp tx)
                ]

    referenceScriptCap
        | not (null unresolved) = []
        | otherwise =
            let limit = toInteger (pp ^. ppMaxRefScriptSizePerTxG)
            in  [ "the scripts the inputs and the reference inputs carry add up to "
                    <> show refBytes
                    <> " bytes, over the ledger's limit of "
                    <> show limit
                    <> " bytes of reference scripts in one transaction"
                | toInteger refBytes > limit
                ]

    minimumFee
        | not (null unresolved) = []
        | otherwise =
            let needed = coinOf (estimateMinFeeTx pp tx keyWitnesses 0 refBytes)
            in  [ "the fee of "
                    <> show fee
                    <> " lovelace is under the "
                    <> show needed
                    <> " the ledger requires of this transaction ("
                    <> show keyWitnesses
                    <> " key witnesses, "
                    <> show refBytes
                    <> " bytes of reference scripts)"
                | fee < needed
                ]

    collateral
        | Map.null declared = []
        | Set.null collateralIns =
            ["the transaction runs scripts and offers no collateral input"]
        | not (null unresolvedCollateral) =
            [ "a collateral input is not among the inputs the build was given: "
                <> show unresolvedCollateral
            ]
        | otherwise =
            concat
                [ [ "collateral names "
                        <> show (Set.size collateralIns)
                        <> " inputs, over the limit of "
                        <> show (pp ^. ppMaxCollateralInputsL)
                  | toInteger (Set.size collateralIns)
                        > toInteger (pp ^. ppMaxCollateralInputsL)
                  ]
                , [ "a collateral input is locked by a script"
                  | not (all keyLocked collateralOuts)
                  ]
                , [ "collateral inputs hold assets the collateral return does not give back"
                  | assetsOf collateralValue /= maybe mempty assetsOf returnValue
                  ]
                , case body ^. totalCollateralTxBodyL of
                    SJust (Coin stated)
                        | stated /= collateralised ->
                            [ "the stated total collateral of "
                                <> show stated
                                <> " is not what the collateral inputs less the return leave: "
                                <> show collateralised
                            ]
                    _ -> []
                , [ "collateral of "
                        <> show collateralised
                        <> " lovelace does not cover "
                        <> show (pp ^. ppCollateralPercentageL)
                        <> "% of the fee of "
                        <> show fee
                  | collateralised * 100 < toInteger (pp ^. ppCollateralPercentageL) * fee
                  ]
                ]
      where
        unresolvedCollateral =
            [i | i <- Set.toList collateralIns, Map.notMember i resolved]
        collateralOuts =
            [o | i <- Set.toList collateralIns, Just o <- [Map.lookup i resolved]]
        keyLocked o = case o ^. addrTxOutL of
            Addr _ (KeyHashObj _) _ -> True
            _ -> False
        collateralValue =
            foldl' (<+>) (inject (Coin 0)) (map (^. valueTxOutL) collateralOuts)
        returnValue = case body ^. collateralReturnTxBodyL of
            SJust r -> Just (r ^. valueTxOutL)
            SNothing -> Nothing
        assetsOf (MaryValue _ assets) = assets
        collateralised =
            coinOf (coinOfValue collateralValue)
                - maybe 0 (coinOf . coinOfValue) returnValue
        coinOfValue (MaryValue c _) = c

    conservation
        | not (null unresolved) =
            [ "an input is not among the inputs the build was given: "
                <> show unresolved
            ]
        | consumed == produced = []
        | otherwise =
            [ "inputs and mint do not balance outputs, donation and fee: lovelace differ by "
                <> show (coinOfValue' consumed - coinOfValue' produced)
                <> ( if assetsOfValue consumed == assetsOfValue produced
                        then ""
                        else ", and assets differ"
                   )
            ]
      where
        consumed =
            foldl'
                (<+>)
                (MaryValue (Coin 0) (body ^. mintTxBodyL))
                [ o ^. valueTxOutL
                | i <- Set.toList spent
                , Just o <- [Map.lookup i resolved]
                ]
        produced =
            foldl'
                (<+>)
                (inject (body ^. feeTxBodyL <+> body ^. treasuryDonationTxBodyL))
                (map (^. valueTxOutL) outs)
        coinOfValue' (MaryValue (Coin c) _) = c
        assetsOfValue (MaryValue _ a) = a

    integrity =
        [ "the script-integrity hash is not that of the redeemers the body declares"
        | body ^. scriptIntegrityHashTxBodyL
            /= computeScriptIntegrity pp (tx ^. witsTxL . rdmrsTxWitsL)
        , not (Map.null declared)
        ]

{- | What one of the ledger's own tests refuses, each failure as the ledger
reports it.
-}
ledgerTest :: (Show e) => Test e -> [String]
ledgerTest = \case
    Success () -> []
    Failure failures ->
        [ "the ledger would refuse the body: " <> take 400 (show failure)
        | failure <- toList failures
        ]

{- | What an output of the finished body is, for a refusal that names it: the
state continuation first, then each registration's carrier in the order the
registrations were given, then the caller's own outputs, then the folder's
change.
-}
outputLabel :: [Member] -> [TxOut ConwayEra] -> Int -> Int -> String
outputLabel members carriers programOutputs index
    | index == 0 = "the state continuation"
    | index <= length carriers =
        "the carrier of the registration of key "
            <> show (keyOfNth (index - 1))
    | index < programOutputs =
        "an attached output (number " <> show (index - length carriers) <> ")"
    | otherwise = "the folder's change"
  where
    keyOfNth n = case drop n [regKey r | (_, r) <- registrationsOf members] of
        key : _ -> key
        [] -> mempty

{- | Generous per-purpose budget stated when local evaluation is
skipped (adversarial path only); the ledger re-executes for real.
Sized 2026-09-13 from MEASURED minima (NOTE-023): the crosswired
exhibit tx overspent 3M mem (needed 5.39M+ and counting — the error
reports the next step only, not completion) and 200M cpu (needed
200.05M+); the honest consumer measures 295M cpu on tiny Aiken
fixtures; the full-fold app script likewise exceeds 3M/200M (double
budget failure on the same tx). 14M mem / 1B steps per purpose sits
at 10% of this devnet's tx limits (140M mem / 10B steps) with ~3x
headroom over every measured minimum; stated fees (~0.9 ADA/purpose)
stay covered by folder funding (balance fails loudly otherwise).
Revisit if ledgers tighten limits or scripts grow.
-}
generousUnits :: ExUnits
generousUnits = ExUnits 14_000_000 1_000_000_000

{- | The units stated for each of @n@ purposes when local evaluation is
skipped: 'generousUnits', lowered where needed so that their sum fits both
the transaction limit and the block limit. A transaction whose stated
units exceed the block limit passes the mempool's per-transaction check
yet can never be included in a block, so it waits for ever.
-}
skipEvalUnits :: ExUnits -> ExUnits -> Int -> ExUnits
skipEvalUnits txLimit blockLimit n =
    let share limit = limit `div` fromIntegral (max 1 n)
        ExUnits gMem gSteps = generousUnits
        ExUnits tMem tSteps = txLimit
        ExUnits bMem bSteps = blockLimit
    in  ExUnits
            (minimum [gMem, share tMem, share bMem])
            (minimum [gSteps, share tSteps, share bSteps])

-- | Empty query generalized algebraic data type (no context needed).
data NoCtx a

-- | Run speculative trie operations to compute proofs and the new root.
managerProofs :: TrieManager IO -> TokenId -> FoldProofs
managerProofs tm tid booked =
    withSpeculativeTrie tm tid $ \trie -> do
        ps <- mapM (uncurry (walkEdge trie) . bookedMove . snd) booked
        r <- getRoot trie
        pure (ps, r)

-- | Replay one accepted request into a trie: a booking by its model edge, a legacy request by its own.
processRequest
    :: (Monad m)
    => Trie m
    -> (TxIn, TxOut ConwayEra)
    -> m [ProofStep]
processRequest trie (_txIn, txOut) = case extractCageDatum txOut of
    Just (RegistrationDatum r) -> walkEdge trie (regKey r) edgeInsertActive
    Just (TerminationDatum t) -> walkEdge trie (termKey t) edgeUpdateTerminal
    Just (RequestDatum req) -> walkEdge trie (requestKey req) (requestEdge req)
    _ -> error "connectedFold: invalid request datum"

-- | Extract old state, build the new state output and the cage script.
prepareState
    :: CageConfig
    -> TxOut ConwayEra
    -> Root
    -> (OnChainTokenState, TxOut ConwayEra, Script ConwayEra)
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
    in  (oldState, newStateOut, script)

{- | A registration's carrier: the key's singular tag alone with the declared
carrier lovelace, at the booked destination, with the booked datum inline.
-}
carrierOutput
    :: CageConfig -> OnChainRegistrationRequest -> TxOut ConwayEra
carrierOutput cfg r =
    withBookedDatum $
        mkBasicTxOut
            destination
            ( MaryValue
                (Coin (regCarrierAda r))
                ( MultiAsset
                    ( Map.singleton
                        (policyIdFromPin (cfgActivePolicy cfg))
                        (Map.singleton (AssetName (SBS.toShort (regKey r))) 1)
                    )
                )
            )
  where
    destination = case decodeAddrEither (regDestination r) of
        Right a -> a
        Left why ->
            error
                ( "connectedFold: a registration's destination is not an address: "
                    <> why
                )
    withBookedDatum out = case regDatum r of
        Just d -> out & datumTxOutL .~ mkInlineDatum d
        Nothing -> out

{- | The TxBuild program: the state spent through @Modify@, each member through
@Contribute@, the caller's spends and mints, the burn of every member's
trie-ready tag, the state continuation, the registrations' carriers and the
caller's outputs, the witnesses and the validity interval. No owner signature.
-}
buildProgram
    :: PolicyID
    -> TxIn
    -> [Member]
    -> (TxIn, TxOut ConwayEra)
    -> TxOut ConwayEra
    -> [TxOut ConwayEra]
    -> Script ConwayEra
    -> Script ConwayEra
    -> [[ProofStep]]
    -> SlotNo
    -> SlotNo
    -> [ConnectedSpend]
    -> [ConnectedMint]
    -> [TxOut ConwayEra]
    -> [TxOut ConwayEra]
    -> [KeyHash Guard]
    -> [(TxIn, TxOut ConwayEra)]
    -> [Script ConwayEra]
    -> Tx.TxBuild NoCtx Void ()
buildProgram
    requestPolicy
    stateIn
    members
    feeUtxo
    newStateOut
    carriers
    script
    requestScript
    proofs
    lowerSlot
    upperSlot
    extraSpends
    extraMints
    extraOutputs
    placeholder
    extraSigners
    refUtxos
    attachScripts = do
        let stateRef = txInToRef stateIn
            actions = map Update proofs
            burns =
                Map.fromList
                    [(AssetName (SBS.toShort (memberTag m)), -1) | m <- members]
        _ <- Tx.spendScript stateIn (Modify actions)
        mapM_
            (\m -> Tx.spendScript (memberRef m) (Contribute stateRef))
            members
        mapM_
            (\sp -> Tx.spendScript (fst (csUtxo sp)) (csRedeemer sp))
            extraSpends
        Tx.mint requestPolicy burns (RawRedeemer (PLC.Constr 0 []))
        mapM_
            (\m -> Tx.mint (cmPolicy m) (cmAssets m) (cmRedeemer m))
            extraMints
        _ <- Tx.output newStateOut
        Coin _fee <- Tx.peek $ \tx ->
            let f = tx ^. bodyTxL . feeTxBodyL
            in  if f > Coin 0 then Tx.Ok f else Tx.Iterate f
        mapM_ Tx.output carriers
        mapM_ Tx.output extraOutputs
        mapM_ Tx.output placeholder
        -- Scripts arrive by witness or by reference, never both: with
        -- reference UTxOs every purpose resolves through them (a fold
        -- carries four scripts and would otherwise breach the max tx size);
        -- without, every script is attached (small transactions).
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
        Tx.validFrom lowerSlot
        Tx.validTo upperSlot

{- | Replay accepted fold inputs into the manager's persistent trie so
later proof computations start from the chain's root. Call only with
inputs the ledger accepted, in fold order.
-}
syncFoldedRequests
    :: TrieManager IO
    -> TokenId
    -> [(TxIn, TxOut ConwayEra)]
    -> IO ()
syncFoldedRequests tm tok reqUtxos =
    withTrie tm tok $ \trie -> mapM_ (processRequest trie) reqUtxos
