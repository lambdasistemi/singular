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

The transaction library states no treasury donation, so the donation is set on
the balanced body (the folder's change gives it up, the fee is raised for the
bytes the field adds); the scripts are judged on that same body, change and
donation included, while the program is built and once more at the end.

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
    , syncFoldedRequests
    , generousUnits
    , skipEvalUnits
    ) where

import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Void (Void)
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC

import Cardano.Ledger.Address (Addr, decodeAddrEither)
import Cardano.Ledger.Api.PParams
    ( ppMaxBlockExUnitsL
    , ppMaxTxExUnitsL
    , ppTxFeePerByteL
    )
import Cardano.Ledger.Api.Tx (bodyTxL, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , mintTxBodyL
    , outputsTxBodyL
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
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.Coin
    ( Coin (..)
    , CoinPerByte (..)
    , CompactForm (..)
    )
import Cardano.Ledger.Core (Script, sizeTxF)
import Cardano.Ledger.Keys (KeyHash, KeyRole (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID
    )
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.Val (inject, (<+>), (<->))
import Cardano.Slotting.Slot (SlotNo)
import PlutusTx.Builtins.Internal (BuiltinData (..))
import PlutusTx.IsData.Class (ToData (..))

import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)
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
    , currentPosixMs
    , requestPolicyOf
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

{- | Build the connected fold transaction (unsigned), returning the
computed new root the state continuation carries.
-}
connectedFoldTx :: ConnectedFoldArgs -> IO (ConwayTx, Root)
connectedFoldTx args = do
    let cfg = cfaCfg args
        view = cfaSession args
        tm = cfaTrie args
        tid = cfaToken args
        feeAddr = cfaFeeAddr args
        (stateIn, stateOut) = cfaStateUtxo args
        feeUtxo = cfaFeeUtxo args
    members <- membersOf cfg tid (cfaReqUtxos args)
    -- the model orders the keyed mint before the pair of a batch
    when (cfaSkipEval args) $ guardMintMatch cfg members (cfaMints args)
    guardOneRequestPerKey members
    pp <- parameters view
    (proofs, newRoot) <- computeProofs tm tid members
    let adjustedRoot = cfaAdjustRoot args newRoot
        (oldState, newStateOut, script) =
            prepareState cfg stateOut adjustedRoot
        requestScript = mkRequestScript cfg tid
        processTime = stateProcessTime oldState
        registrations = registrationsOf members
        windowed = [(ref, regSubmittedAt r) | (ref, r) <- registrations]
        carriers = [carrierOutput cfg r | (_, r) <- registrations]
        donation = Coin (sum (map owedDonation members))
    observed <- Services.tip view
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
            donated <- withDonation pp feeAddr donation built
            unless (cfaSkipEval args) $ do
                judged <- evaluate donated
                case [(p, e) | (p, Left e) <- Map.toList judged] of
                    [] -> pure ()
                    (purpose, e) : _ ->
                        refuse
                            ( "the built fold is refused by its own scripts: "
                                <> show purpose
                                <> ": "
                                <> e
                            )
            pure (donated, newRoot)
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

{- | The transaction library states no treasury donation, so the donation is
set on the balanced body: the change output gives it up, and the fee is raised
for the bytes the donation field adds until it covers the body that carries
it. The folder's change must still carry its minimum ada.
-}
withDonation
    :: PParams ConwayEra -> Addr -> Coin -> ConwayTx -> IO ConwayTx
withDonation pp changeAddr donation tx0
    | donation == Coin 0 = pure tx0
    | otherwise = case tx0 ^. bodyTxL . outputsTxBodyL of
        rest StrictSeq.:|> change
            | change ^. addrTxOutL == changeAddr ->
                settle rest change (8 :: Int) originalFee
        _ ->
            refuse
                "the balanced fold has no change output of the folder to give the donation up"
  where
    originalFee = tx0 ^. bodyTxL . feeTxBodyL
    size0 = toInteger (tx0 ^. sizeTxF)
    perByte = case unCoinPerByte (pp ^. ppTxFeePerByteL) of
        CompactCoin w -> toInteger w
    lovelace (Coin c) = c
    settle rest change n fee
        | n == 0 = refuse "the donation's fee did not settle"
        | lovelace (change' ^. coinTxOutL)
            < lovelace (getMinCoinTxOut pp change') =
            refuse
                "the folder's funding cannot carry the change that the fee and the donation leave"
        | needed <= lovelace fee = pure tx
        | otherwise = settle rest change (n - 1) (Coin needed)
      where
        change' =
            change
                & coinTxOutL
                    .~ Coin
                        ( lovelace (change ^. coinTxOutL)
                            + lovelace originalFee
                            - lovelace fee
                            - lovelace donation
                        )
        tx =
            tx0
                & bodyTxL . treasuryDonationTxBodyL .~ donation
                & bodyTxL . feeTxBodyL .~ fee
                & bodyTxL . outputsTxBodyL .~ (rest StrictSeq.|> change')
        needed =
            lovelace originalFee + (toInteger (tx ^. sizeTxF) - size0) * perByte

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
computeProofs
    :: TrieManager IO
    -> TokenId
    -> [Member]
    -> IO ([[ProofStep]], Root)
computeProofs tm tid members =
    withSpeculativeTrie tm tid $ \trie -> do
        ps <- mapM (processMember trie) members
        r <- getRoot trie
        pure (ps, r)

-- | Walk one member's edge through the speculative trie.
processMember :: (Monad m) => Trie m -> Member -> m [ProofStep]
processMember trie m = walkEdge trie (memberKey m) $ case memberRequest m of
    BookedRegistration _ -> edgeInsertActive
    BookedTermination _ -> edgeUpdateTerminal

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
