{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE GADTs #-}

{- |
Module      : Conformance.Run
Description : CA01-CA05, CG02-CG05 and the ten generic rows (issue #70) devnet sessions
License     : Apache-2.0

One @run@ boots a cage on an isolated devnet and executes the
requested generic rows in canonical order, each with its executing
negative control and its measurements. Every result is read back
from the chain; the mirror ("Conformance.Mirror") builds the proofs
and the chain-read root is the only comparison target.

The CA rows (issue #69) run as their own session: a designation
split publishes a canonical seed, CA01 boots the canonical registry
and matches its on-chain token name against the SHA-256 derivation,
CA02 initializes a rival registry from a second seed — which the
ledger ACCEPTS (naming-correspondence.md, "What t50 settled": a
permissionless ledger cannot prohibit a rival; canonical identity is
a derivation the consumer authenticates, not a refusal the chain
performs) — and asserts the rival's acceptance, the name difference
and the canonical registry's unaffected state, each read back from
the chain. CA03 is the executing control: an authenticator that
checks only policy and address accepts the rival, proving CA02's
rejection is attributable to the derived name alone. CA04 derives
the applied address from the pinned unapplied hash plus the declared
parameters and compares it with the address the chain reports.
CA05 forges an output at the canonical address carrying no registry
token: creating an output does not execute the receiving script, and
the run must show no script executed — not merely that nothing bad
happened.

The issue #70 rows (CG07, CG09, CG10, CG11, CG12, CG14, CG15,
CG19) run as their own CG session in canonical order, each
against its own freshly booted cage so a row's odd state (a
parked request) cannot poison its neighbours.
CG07, CG09, CG10 and CG15 are refusal rows: the refusing
transaction is hand-built, phase-1 valid, and the node's phase-2
refusal is attributed to the script that produced it (the request
script for CG07's retract, the state script
otherwise). CG11, CG12 and CG19 are the expected consumer
gaps (the 2026-09-03 cardano-keri audit; upstream
cardano-mpfs-onchain #100 and #101): the run submits what the
consumer's theorems require the partition to refuse and records the
chain's acceptance with the transaction that proves it — a gap is
observed, never relabelled as a pass or a refusal, and a refusal
where the audit expected acceptance would be reported equally. CG14
and CG15 carry the blueprint's staking validator for the
withdrawal leg: the credential is registered and a fold carrying
the matching withdraw-zero is accepted. CG13, CG17 and CG20 are
retired superseded history (NOTE-046, CG16 template): the
owner-pinning transfer, the custody sweep and the removed-signer
regression tested an owner role the registry does not have —
their observations live in rows.json, and no code path here
asserts that authority.

Row shapes (key @cg-row-key@, values @cg-v1@/@cg-v2@/@cg-v3@):

* CG02: Update v1->v2 folds; inclusion proof for v2 implies the
  chain root; a forged-value proof must not (control).
* CG03: Delete folds; the key proves absent from the chain root; a
  deleted-value claim must not verify (control).
* CG04: re-Insert v3 folds; inclusion proof for v3 implies the
  chain root; an exclusion proof must not verify (control).
* CG05: Insert on the occupied key must be refused, attributed to
  the state script in phase 2. The executing control is a fresh
  cage that accepts a valid insert: a cage that refuses everything
  would pass the refusal vacuously.

@CONFORMANCE_CONTROL=wrong-reason@ arms the refusal matcher against
an impossible marker (the run must fail naming what came back);
@CONFORMANCE_CONTROL=false-claim@ binds forged values to the
chain-read verifications, and in a CA session binds the fabricated
wrong-seed derivation to CA01's name match (both must fail).
@CONFORMANCE_CONTROL=naive-authenticator@ makes CA03 require the
policy+address-only authenticator to reject the rival, which it
cannot (the run must fail naming the accepted rival);
@CONFORMANCE_CONTROL=unapplied-address@ makes CA04 require the
unapplied layer's address to pass for the deployed script, which it
cannot (the run must fail). All prove the harness fails when it
should.
-}
module Conformance.Run (runForkProbe, runRows) where

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
import Conformance.Run.Manifest

import Conformance.Story.Live qualified as Live
import Conformance.Edge.Register qualified as RegistrationStory
import Conformance.Edge.Retire qualified as RetirementStory
import Conformance.Edge.Sequence qualified as SequenceStory
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel)
import Control.Exception (
    ErrorCall (..),
    SomeException,
    displayException,
    throwIO,
    try,
 )
import Control.Monad (unless, when)
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson (
    Value (..),
    encode,
    object,
    (.=),
 )
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (intercalate, isInfixOf, nub, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((&), (.~), (^.))
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.FilePath ((</>))

import Cardano.Ledger.Plutus.Data (Data (..))
import Cardano.Ledger.Address (
    AccountAddress (..),
    AccountId (..),
    Addr (..),
 )
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))

import Cardano.Ledger.Api.PParams (
    ppMaxTxExUnitsL,
    ppMaxTxSizeL,
 )
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
import Cardano.Ledger.Api.Scripts.Data (
    Datum (..),
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
    Network (..),
    StrictMaybe (..),
 )
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Credential (Credential (..), StakeReference (..))
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import MPF.Hashes (MPFHash)
import MPF.Proof.Insertion (MPFProof (..))

import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint (
    NamingCodes (..),
    applyBytesParam,
    applyDataParam,
    applyPreviousPolicies,
    applyRequestParams,
 )
import Singular.Registry.TxBuilder.Reject (rejectRequestsImpl)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (
    AssetName (..),
    Coin (..),
    ConwayEra,
    ExUnits (..),
    PolicyID (..),
    Root (..),
    TokenId (..),
    TxOut,
 )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Trie (TrieManager (..))
import Singular.Registry.Trie qualified as CageTrie
import Singular.Registry.Trie.PureManager (mkPureTrieManager)
import Singular.Registry.TxBuilder.Boot (bootTokenImpl)
import Singular.Registry.TxBuilder.Edges qualified as RegistryEdges
import Singular.Registry.TxBuilder.Internal (
    walkEdge,
    leafAbsent,
    addrFromKeyHashBytes,
    addrWitnessKeyHash,
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    computeScriptHash,
    computeScriptIntegrity,
    currentPosixMs,
    extractCageDatum,
    extractOwnerBytes,
    findRequestUtxos,
    findStateUtxo,
    mkCageScript,
    mkInlineDatum,
    mkRequestScript,
    onChainTokenId,
    requestAddrFromCfg,
    scriptHashBytes,
    scriptFromBytes,
    spendingIndex,
    toLedgerData,
    toPlcData,
    trySlots,
    txInToRef,
 )
import Singular.Registry.TxBuilder.Retract (retractRequestImpl)
import Singular.Registry.TxBuilder.Request (
    requestEdgeImpl,
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
    edgeInsertActive,
    edgeUpdateActive,
    OnChainRequest (..),
    OnChainRoot (..),
    OnChainTokenState (..),
    OnChainTxOutRef (..),
    RequestAction (Update),
    UpdateRedeemer (..),
 )
import Singular.Registry.Node (
    adaptProvider,
    awaitConnection,
    checkFunding,
    defaultFundingFloor,
    devnetGenesis,
    followedProvider,
    funderAddr,
    sessionMagic,
    withNodeSocket,
 )
import Singular.Registry.Types qualified as CageTypes
import Cardano.Node.Client.E2E.Setup (addKeyWitness)
import Cardano.Node.Client.N2C.Connection (
    newLSQChannel,
    newLTxSChannel,
    runNodeClient,
 )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
import Cardano.Node.Client.Submitter (
    SubmitResult (..),
    Submitter (..),
 )
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins.Internal (BuiltinByteString (..))

import Conformance.Authenticate (
    AuthDecision (..),
    AuthReject (..),
    authenticate,
    authenticateWeak,
 )
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
import Conformance.CS01 (runCS01)
import Conformance.CS06 (runCS06)
import Conformance.ForkKeys (findPresentForkKeys)
import Conformance.Receipt (
    ConstructorEvidence (..),
    ConstructorStanding (..),
    DerivationEvidence (..),
    DerivationOutcome (..),
    Outcome (..),
    PartialInfo (..),
    Receipt (..),
    RefusalInfo (..),
    Verdict (..),
    derivationMatches,
    derivationVenue,
    loadReceipts,
    maxReceiptBytes,
    writeReceiptFile,
 )
import Conformance.Refusal (
    RefusalRole (..),
    attributeRefusalReceipt,
    matchRefusal,
    refusalScriptHashes,
    trimRefusal,
    wrongReasonMarker,
 )


-- ---------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------

runRows :: [String] -> FilePath -> IO ()
runRows rawRows receiptsDir = do
    rows <- validateRows rawRows
    control <- readControl
    emit "control" (show control)
    let caRequested = any (`elem` caRows) rows
        cgRequested = any (`elem` (cgRows <> issue70Rows <> issue173Rows <> issue177Rows <> sequenceRows)) rows
    -- Armed controls must never pass vacuously: each mode belongs to
    -- one session, and a session it cannot fire in is refused here.
    when (caRequested && control == WrongReason) $
        failWith
            ( "wrong-reason arms a refusal matcher, but the CA rows \
              \assert no ledger refusal (the rival is accepted by \
              \design); use naive-authenticator, false-claim or \
              \unapplied-address"
            )
    when
        ( cgRequested
            && control `elem` [NaiveAuthenticator, UnappliedAddress]
        )
        $ failWith
            ( "naive-authenticator and unapplied-address are CA \
              \controls; the CG rows they cannot arm would pass \
              \vacuously"
            )
    blueprintPath <- requireEnv "REGISTRY_BLUEPRINT"
    -- Observe tree identity before any side effect: creating the
    -- receipts directory first would always report dirty.
    base <- requireBase
    emit "base" base
    dirty <- requireTreeClean
    emit "tree" (if dirty then "dirty (receipts record it)" else "clean")
    createDirectoryIfMissing True receiptsDir
    let localRows = [r | r <- rows, r `elem` ["CS01", "CS06"]]
        devnetRows = [r | r <- rows, r `notElem` ["CS01", "CS06"]]
        cgDevnet = [r | r <- devnetRows, r `elem` (cgRows <> issue70Rows <> issue173Rows <> issue177Rows <> sequenceRows)]
        caDevnet = [r | r <- devnetRows, r `elem` caRows]
        csDevnet = [r | r <- devnetRows, r `elem` csRows]
        unpartitioned = [r | r <- devnetRows, r `notElem` (caRows <> cgRows <> csRows <> issue70Rows <> issue173Rows <> issue177Rows <> sequenceRows)]
    unless (null unpartitioned) $
        failWith
            ("rows in no partition: " <> unwords unpartitioned)
    mapM_ (runLocalRow blueprintPath receiptsDir base dirty) localRows
    unless (null devnetRows) $ do
        (stateBytes, requestBytes, namingCodes) <- loadCodes blueprintPath
        devnetGenesis >>= mapM_ checkGenesis
        nodeVer <- readNodeVersion
        emit "node" nodeVer
        require
            "forged control value collides with a row value"
            (forgedValue `notElem` [cgV1, cgV2, cgV3, cgV4, controlVal])
        unless (null caDevnet) $
            bracketTmpDir $ do
                withNodeSocket $ \sock ->
                    runSession
                        caDevnet
                        control
                        (stateBytes, requestBytes, namingCodes)
                        blueprintPath
                        nodeVer
                        base
                        dirty
                        receiptsDir
                        sock
        unless (null cgDevnet) $
            bracketTmpDir $ do
                withNodeSocket $ \sock ->
                    runSession
                        cgDevnet
                        control
                        (stateBytes, requestBytes, namingCodes)
                        blueprintPath
                        nodeVer
                        base
                        dirty
                        receiptsDir
                        sock
        unless (null csDevnet) $
            bracketTmpDir $ do
                withNodeSocket $ \sock ->
                    runCSSession
                        csDevnet
                        control
                        stateBytes
                        requestBytes
                        namingCodes
                        nodeVer
                        base
                        dirty
                        receiptsDir
                        sock
    when (null devnetRows) $
        emit "complete" (show (length localRows) <> "/" <> show (length rows) <> " rows ok")

runLocalRow :: FilePath -> FilePath -> String -> Bool -> String -> IO ()
runLocalRow blueprintPath receiptsDir base dirty row = case row of
    "CS01" -> runCS01 blueprintPath receiptsDir base dirty
    "CS06" -> runCS06 blueprintPath receiptsDir base dirty
    _ -> failWith ("run cannot execute local row: " <> row)

validateRows :: [String] -> IO [String]
validateRows [] =
    failWith
        "run needs at least one row: run CA01..CA05, CG02..CG05, CS \
         \families, or the issue #70 rows CG07 CG09 CG10 CG11 CG12 \
             \CG14 CG15 CG19"
validateRows raw = do
    let bad = [r | r <- raw, r `notElem` canonicalRows]
    unless (null bad) $
        failWith ("run cannot execute rows: " <> unwords bad)
    let requested = [r | r <- canonicalRows, r `elem` raw]
        hasCa = any (`elem` caRows) requested
        hasCg = any (`elem` (cgRows <> issue70Rows <> issue173Rows <> issue177Rows <> sequenceRows)) requested
    when (hasCa && hasCg) $
        failWith
            ( "CA and CG rows run as separate sessions, one devnet \
              \each: run CA01..CA05, then the CG rows"
            )
    pure requested

-- ---------------------------------------------------------
-- Session
-- ---------------------------------------------------------

runSession ::
    [String] ->
    Control ->
    (SBS.ShortByteString, SBS.ShortByteString, NamingCodes) ->
    FilePath ->
    String ->
    String ->
    Bool ->
    FilePath ->
    FilePath ->
    IO ()
runSession
    rows
    control
    codes@(stateBytes, requestBytes, namingCodes)
    blueprintPath
    nodeVer
    base
    dirty
    receiptsDir
    sock = do
        lsqCh <- newLSQChannel 16
        ltxsCh <- newLTxSChannel 16
        nodeThread <-
            async $
                runNodeClient
                    sessionMagic
                    sock
                    lsqCh
                    ltxsCh
        let nodeProv = adaptProvider (mkN2CProvider lsqCh)
        awaitConnection sessionMagic sock nodeThread nodeProv
        let submit = mkN2CSubmitter ltxsCh
        prov <- followedProvider nodeProv submit
        checkFunding prov funderAddr defaultFundingFloor
        tm <- mkPureTrieManager
        mirror <- newMirror
        _ <- Cage.queryProtocolParams prov
        let caMode = any (`elem` caRows) rows
            legacyCg = any (`elem` cgRows) rows
        keys <- newIORef (False, "")
        deleteKeys <- newIORef (False, "")
        refsRef <- newIORef Nothing
        validUnits <- newIORef (0, 0)
        worlds <- newIORef Map.empty
        stakeRef <- newIORef Nothing
        key2Ref <- newIORef Nothing
        heldRef <- newIORef []
        failedRef <- newIORef []
        liveRecordsRef <- newIORef []
        liveMeasurementsRef <- newIORef []
        (env, marker, bootLine) <-
            if caMode
                then do
                    -- CA session: publish the canonical seed by a
                    -- designation split, then CA01 boots from it.
                    -- No cage is booted here: the boot IS row CA01.
                    --
                    -- The wallet is swept BEFORE the designation. After it,
                    -- the canonical seed is an ordinary ada-only output and
                    -- a sweep would spend the very one the config pins.
                    consolidateWallet prov submit
                    (seedTxIn, _) <- designateSplit prov submit "canonical"
                    let seedRef = txInToRef seedTxIn
                        cfg = cageCfg stateBytes requestBytes namingCodes seedRef
                    caTid <- newIORef Nothing
                    caSnap <- newIORef Nothing
                    caBootTx <- newIORef Nothing
                    caBootM <- newIORef Nothing
                    caRivalTid <- newIORef Nothing
                    caRivalM <- newIORef Nothing
                    let world =
                            CaWorld
                                { caCfg = cfg
                                , caSeedRef = seedRef
                                , caRawState = stateBytes
                                , caTidRef = caTid
                                , caSnapRef = caSnap
                                , caBootTxRef = caBootTx
                                , caBootMeasureRef = caBootM
                                , caRivalTidRef = caRivalTid
                                , caRivalMeasure = caRivalM
                                }
                    pure
                        ( Env
                            { envCfg = cfg
                            , envProv = prov
                            , envSubmit = submit
                            , envTm = tm
                            , -- never read in a CA session: the row
                              -- validator keeps CG rows out of it
                              envTid = TokenId (AssetName (SBS.toShort ""))
                            , envMirror = mirror
                            , envControl = control
                            , envBase = base
                            , envDirty = dirty
                            , envNode = nodeVer
                            , envBlueprint = blueprintId cfg requestBytes
                            , envReceiptsDir = receiptsDir
                            , envCodes = codes
                            , envBlueprintPath = blueprintPath
                            , envKeys = keys
                            , envDeleteKey = deleteKeys
                            , envRefs = refsRef
                            , envValidUnits = validUnits
                            , envCa = Just world
                            , envWorlds = worlds
                            , envStake = stakeRef
                            , envKey2 = key2Ref
                            , envHeld = heldRef
                            , envFailed = failedRef
                            , envLiveRecords = liveRecordsRef
                            , envLiveMeasurements = liveMeasurementsRef
                            }
                        , hex (scriptHashBytes (cfgScriptHash cfg))
                        , ( "CA session: canonical seed published at outRef "
                                <> show seedRef
                                <> " — the consumer derives the canonical \
                                   \name as SHA-256 of this outRef"
                          )
                        )
                else
                    -- The CG02-CG05 session cage boots only when one
                    -- of those rows is requested; the issue #70 rows
                    -- boot their own cages per row group instead.
                    if not legacyCg
                        then do
                            -- No CG02-CG05 row is requested, so those
                            -- row bodies never run; the config below
                            -- is an unbooted placeholder (the seed
                            -- query only names a real UTxO) kept for
                            -- the record's shape.
                            (seedTxIn, _) <- largestWalletUtxo prov
                            let placeholderCfg =
                                    cageCfg stateBytes requestBytes namingCodes (txInToRef seedTxIn)
                            pure
                                ( Env
                                    { envCfg = placeholderCfg
                                    , envProv = prov
                                    , envSubmit = submit
                                    , envTm = tm
                                    , envTid = TokenId (AssetName (SBS.toShort ""))
                                    , envMirror = mirror
                                    , envControl = control
                                    , envBase = base
                                    , envDirty = dirty
                                    , envNode = nodeVer
                                    , envBlueprint = blueprintId placeholderCfg requestBytes
                                    , envBlueprintPath = blueprintPath
                                    , envReceiptsDir = receiptsDir
                                    , envCodes = codes
                                    , envKeys = keys
                                    , envDeleteKey = deleteKeys
                                    , envRefs = refsRef
                                    , envValidUnits = validUnits
                                    , envCa = Nothing
                                    , envWorlds = worlds
                                    , envStake = stakeRef
                                    , envKey2 = key2Ref
                                    , envHeld = heldRef
                                    , envFailed = failedRef
                                    , envLiveRecords = liveRecordsRef
                                    , envLiveMeasurements = liveMeasurementsRef
                                    }
                                , hex (scriptHashBytes (cfgScriptHash placeholderCfg))
                                , "no session cage: the issue #70 rows boot \
                                   \their own"
                                )
                        else do
                            (seedTxIn, _) <- largestWalletUtxo prov
                            let cfg = cageCfg stateBytes requestBytes namingCodes (txInToRef seedTxIn)
                                marker' = case control of
                                    WrongReason -> wrongReasonMarker
                                    _ -> hex (scriptHashBytes (cfgScriptHash cfg))
                            unsignedBoot <- bootTokenImpl cfg prov genesisAddr
                            signedBoot <- submitWithGenesis submit unsignedBoot
                            tid <- extractTokenId cfg signedBoot
                            createTrie tm tid
                            pure
                                ( Env
                                    { envCfg = cfg
                                    , envProv = prov
                                    , envSubmit = submit
                                    , envTm = tm
                                    , envTid = tid
                                    , envMirror = mirror
                                    , envControl = control
                                    , envBase = base
                                    , envDirty = dirty
                                    , envNode = nodeVer
                                    , envBlueprint = blueprintId cfg requestBytes
                                    , envBlueprintPath = blueprintPath
                                    , envReceiptsDir = receiptsDir
                                    , envCodes = codes
                                    , envKeys = keys
                                    , envDeleteKey = deleteKeys
                                    , envRefs = refsRef
                                    , envValidUnits = validUnits
                                    , envCa = Nothing
                                    , envWorlds = worlds
                                    , envStake = stakeRef
                                    , envKey2 = key2Ref
                                    , envHeld = heldRef
                                    , envFailed = failedRef
                                    , envLiveRecords = liveRecordsRef
                                    , envLiveMeasurements = liveMeasurementsRef
                                    }
                                , marker'
                                , "cage booted bootTx=" <> txIdHex signedBoot
                                )
        emit "boot" bootLine
        mapM_ (runRow env marker) rows
        cancel nodeThread
        if caMode
            then writeCaCL01 env rows
            else
                if all (`elem` issue70Rows) rows
                    then writeCL01Issue70 env rows
                    else writeCL01Receipt env rows
        emit
            "complete"
            (show (length rows) <> "/" <> show (length rows) <> " rows ok")
        -- A held or failing row must never read as a pass: the
        -- session ends non-zero naming every such row.
        held <- readIORef (envHeld env)
        failed <- readIORef (envFailed env)
        case (held, failed) of
            ([], []) -> pure ()
            _ ->
                throwIO
                    ( ErrorCall
                        ( "ROWS THE RUN CANNOT REPORT AS PASSING"
                            <> "\n- Held (Q-002, story 2: Singular's Lean and \
                               \the consumer's theorem disagree and the \
                                   \chain sided with Singular's Lean; \
                                       \receipts carry verdict held-q002): "
                                <> ( if null held
                                        then "none"
                                        else unwords (reverse held)
                                   )
                            <> "\n- Failing against this candidate \
                               \(verdict diverges-from-lean — the chain \
                                   \refused what the Lean requires \
                                       \accepted): "
                                <> ( if null failed
                                        then "none"
                                        else unwords (reverse failed)
                                   )
                            <> "\nThese rows are the milestone owner's to \
                               \carry to the user."
                        )
                    )

-- ---------------------------------------------------------
-- Rows
-- ---------------------------------------------------------

runRow :: Env -> String -> String -> IO ()
runRow env marker row = do
    -- A CA row boots from the seed the session designated, so its wallet
    -- is left exactly as the designation left it. Every other row wants
    -- one ada-only output to fund from.
    unless (take 2 row == "CA") (consolidateFunding env)
    -- #177 A-003: every boot in this session references the state
    -- validator instead of carrying it inline. Idempotent, so it is
    -- established before the first row and found by every later one.
    ensureStateRef env
    runRowIn env marker row

runRowIn :: Env -> String -> String -> IO ()
runRowIn env marker row = case row of
    "CA01" -> withCa env row runCA01
    "CA02" -> withCa env row runCA02
    "CA03" -> withCa env row runCA03
    "CA04" -> withCa env row runCA04
    "CA05" -> withCa env row runCA05
    "CG02" -> runCG02 env
    "CG03" -> runCG03 env
    "CG04" -> runCG04 env
    "CG05" -> runCG05 env marker
    "CG07" -> runCG07 env
    "CG09" -> runCG09 env
    "CG10" -> runCG10 env
    "CG11" -> runCG11 env
    "CG12" -> runCG12 env
    "CG14" -> runCG14 env
    "CG15" -> runCG15 env
    "CG19" -> runCG19 env
    "CG21" -> runCG21 env
    "CG22" -> runCG22 env
    "sequence" -> runSequence env
    _ -> failWith ("run cannot execute row: " <> row)

withCa :: Env -> String -> (Env -> CaWorld -> IO ()) -> IO ()
withCa env row f = case envCa env of
    Just w -> f env w
    Nothing -> failWith ("row " <> row <> " needs a CA session")

-- ---------------------------------------------------------
-- CA rows (issue #69): canonical identity authentication
-- ---------------------------------------------------------

{- | The designation split: the largest wallet UTxO becomes two
outputs at the genesis wallet — output 0 is the new seed, output 1
the funding remainder. One seed candidate exists per split, so no
boot can ever consume the wrong UTxO as its funder, and the seed's
outRef is published by the split transaction itself.
-}
designateSplit ::
    Cage.Provider IO -> Submitter IO -> String -> IO (TxIn, TxIn)
designateSplit prov submit label = do
    (gIn, gOut) <- largestWalletUtxo prov
    let Coin total = gOut ^. coinTxOutL
        seedCoin = 2_000_000
        fee = 1_000_000
        rest = total - seedCoin - fee
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton gIn
                & outputsTxBodyL
                    .~ StrictSeq.fromList
                        [ mkBasicTxOut genesisAddr (MaryValue (Coin seedCoin) mempty)
                        , mkBasicTxOut genesisAddr (MaryValue (Coin rest) mempty)
                        ]
                & feeTxBodyL .~ Coin fee
        tx = mkBasicTx body
    require
        ("designation: wallet too small for the " <> label <> " split")
        (rest > seedCoin)
    result <- submitTx submit (addKeyWitness genesisSignKey tx)
    case result of
        Submitted _ -> pure ()
        Rejected reason ->
            failWith
                ( "designation split refused: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )
    awaitTx tx
    after <- Cage.queryUTxOs prov genesisAddr
    let txid = txIdHex tx
        mine =
            sortOn (txInIndex . fst)
                [p | p@(i, _) <- after, txInTxIdHex i == txid]
    case mine of
        [seed, funder] -> pure (fst seed, fst funder)
        _ ->
            failWith
                ( "designation: expected two outputs from the "
                    <> label
                    <> " split, found "
                    <> show (length mine)
                )

{- | CA01: boot the canonical registry from the published seed, then
recompute the token name in Haskell as SHA-256 of the seed's outRef
and match it against the state UTxO read from the chain: exactly
that name at quantity one under the canonical policy. The executing
control: the same derivation over a fabricated outRef must NOT
match. With @false-claim@ armed the fabricated derivation is bound
to the match instead, and the run must fail.
-}
runCA01 :: Env -> CaWorld -> IO ()
runCA01 env w = do
    let cfg = caCfg w
        prov = envProv env
    unsignedBoot <- bootTokenImpl cfg prov genesisAddr
    (mem, cpu) <- measureUnits env unsignedBoot
    let signedBoot = addKeyWitness genesisSignKey unsignedBoot
    result <- submitTxResilient (envSubmit env) signedBoot
    case result of
        Submitted _ -> pure ()
        Rejected reason ->
            failWith
                ( "CA01: the node refused the canonical boot: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )
    awaitTx signedBoot
    let size = txSizeBytes signedBoot
    emitMeasure env "CA01-boot" mem cpu size
    tid <- extractTokenId cfg signedBoot
    writeIORef (caTidRef w) (Just tid)
    writeIORef
        (caBootTxRef w)
        (Just unsignedBoot)
    writeIORef
        (caBootMeasureRef w)
        (Just (txIdHex signedBoot, mem, cpu, size))
    -- read the state UTxO back from the chain at the cage address
    -- (CA04 derives that address independently and cross-checks it)
    (stateIn, stateOut) <- canonicalStateUtxo env w
    let policyBytes =
            scriptHashBytes (policyID (cagePolicyIdFromCfg cfg))
        derivedName = deriveAssetName (caSeedRef w)
        fabricatedRef =
            (caSeedRef w){txOutRefIdx = txOutRefIdx (caSeedRef w) + 1}
        wrongName = deriveAssetName fabricatedRef
        underPolicy =
            Map.lookup policyBytes (outAssets stateOut)
        expectedName = case envControl env of
            FalseClaim -> wrongName
            _ -> derivedName
    require
        "CA01: the state UTxO carries no assets under the canonical policy"
        (maybe False (not . Map.null) underPolicy)
    let chainNames = maybe [] (map fst . Map.toList) underPolicy
    require
        ( "CA01: the canonical policy carries names "
            <> show (map hex chainNames)
            <> ", wanted exactly 0x"
            <> hex expectedName
            <> " at quantity one"
        )
        (fmap Map.toList underPolicy == Just [(expectedName, 1)])
    require
        ( "CA01 control failed: the fabricated outRef's derivation 0x"
            <> hex wrongName
            <> " matches the chain name — the derivation is not \
               \seed-bound"
        )
        (wrongName `notElem` chainNames)
    writeIORef
        (caSnapRef w)
        ( Just
            CaSnap
                { csIn = stateIn
                , csValue = stateOut ^. valueTxOutL
                , csDatum = stateOut ^. datumTxOutL
                }
        )
    writeRowReceipt
        env
        "CA01"
        Accepted
        AgreesWithModel        [txIdHex signedBoot]
        Nothing
        Nothing
        (Just mem)
        (Just cpu)
        (Just size)
        "node-submit"
        Nothing
    emit
        "row"
        ( "CA01: canonical registry token name 0x"
            <> hex derivedName
            <> " = SHA-256 of the published seed's outRef, matched \
               \on chain at quantity one; the fabricated outRef \
               \derives 0x"
            <> hex wrongName
            <> " and does not match (control)"
        )

{- | CA02: initialize a rival registry from a second seed through the
same bootstrap path. The ledger ACCEPTS it — the settled finding
(naming-correspondence.md, "What t50 settled"): a permissionless
ledger cannot prohibit a rival, so canonical identity is a
derivation the consumer authenticates, not a refusal the chain
performs. The row asserts three things, each read back from the
chain: the rival is accepted and live at the applied address, the
two token names differ (each the SHA-256 of its own seed's outRef),
and the canonical registry is unaffected — same UTxO, same value,
same datum bytes as CA01's snapshot. The authentication then rejects
the rival on the derived name while accepting the canonical
registry.
-}
runCA02 :: Env -> CaWorld -> IO ()
runCA02 env w = do
    tidC <- readIORef (caTidRef w)
    require "CA02 needs CA01's canonical registry; run CA01 first" (isJust tidC)
    -- the second designation split: output 0 is the rival seed
    (rivalIn, _) <- designateSplit (envProv env) (envSubmit env) "rival"
    let rivalRef = txInToRef rivalIn
        cfgR = (caCfg w){cageSeed = rivalRef}
        prov = envProv env
    unsignedRival <- bootTokenImpl cfgR prov genesisAddr
    (mem, cpu) <- measureUnits env unsignedRival
    let signedRival = addKeyWitness genesisSignKey unsignedRival
    result <- submitTxResilient (envSubmit env) signedRival
    case result of
        Rejected reason ->
            failWith
                ( "CA02 FINDING: the ledger REFUSED the internally \
                  \consistent rival ("
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                    <> ") — contradicts the settled design \
                       \(naming-correspondence.md, What t50 settled); \
                       \reported, not relabelled"
                )
        Submitted _ -> pure ()
    awaitTx signedRival
    let size = txSizeBytes signedRival
    emitMeasure env "CA02-rival-boot" mem cpu size
    tidR <- extractTokenId cfgR signedRival
    writeIORef (caRivalTidRef w) (Just tidR)
    -- read both registries back from the chain
    (_, rivalOut) <- rivalStateUtxo env w
    (canonIn, canonOut) <- canonicalStateUtxo env w
    let cfg = caCfg w
        policyBytes =
            scriptHashBytes (policyID (cagePolicyIdFromCfg cfg))
        canonicalName = deriveAssetName (caSeedRef w)
        rivalName = deriveAssetName rivalRef
        policyAsset out =
            Map.lookup policyBytes (outAssets out)
    -- 1. the rival was accepted: its UTxO is live, read above
    -- 2. the two token names differ, both read from the chain and
    --    each the SHA-256 of its own seed's outRef
    require
        "CA02: the canonical state's policy assets are not exactly the derived name at quantity one"
        (policyAsset canonOut == Just (Map.singleton canonicalName 1))
    require
        "CA02: the rival state's policy assets are not exactly its own seed's derivation at quantity one"
        (policyAsset rivalOut == Just (Map.singleton rivalName 1))
    require
        ( "CA02: the rival name equals the canonical name — \
          \derivation broken ("
            <> hex rivalName
            <> ")"
        )
        (rivalName /= canonicalName)
    -- 3. the canonical registry is unaffected: same UTxO, value and
    --    datum bytes as CA01's snapshot
    snap <- readIORef (caSnapRef w)
    case snap of
        Nothing -> failWith "CA02: no canonical snapshot; run CA01 first"
        Just s -> do
            require
                "CA02: the canonical registry UTxO moved"
                (csIn s == canonIn)
            require
                "CA02: the canonical registry value changed"
                (csValue s == canonOut ^. valueTxOutL)
            require
                "CA02: the canonical registry datum changed"
                (csDatum s == canonOut ^. datumTxOutL)
    -- the consumer's authentication, on chain-read assets: the
    -- derived canonical name accepts the canonical registry and
    -- rejects the rival
    let authRival =
            authenticate policyBytes canonicalName (outAssets rivalOut)
        authCanon =
            authenticate policyBytes canonicalName (outAssets canonOut)
    require
        ( "CA02: authentication accepted the rival — the derived \
          \name does not bind ("
            <> show authRival
            <> ")"
        )
        (authRival == AuthReject NameMismatch)
    require
        "CA02: authentication rejected the canonical registry"
        (authCanon == AuthAccept)
    -- the receipt records the LEDGER's verdict on the row's tx:
    -- accepted. The authentication's rejection is the assertion
    -- above, never a relabelling of the acceptance.
    writeIORef
        (caRivalMeasure w)
        (Just (txIdHex signedRival, mem, cpu, size))
    writeRowReceipt
        env
        "CA02"
        Accepted
        AgreesWithModel        [txIdHex signedRival]
        Nothing
        Nothing
        (Just mem)
        (Just cpu)
        (Just size)
        "node-submit"
        Nothing
    emit
        "row"
        ( "CA02: rival ACCEPTED by the ledger, as the settled design \
          \requires — tx="
            <> txIdHex signedRival
            <> " live at the applied address under token 0x"
            <> hex rivalName
            <> " vs canonical 0x"
            <> hex canonicalName
            <> " (each SHA-256 of its own seed's outRef); the \
               \canonical registry is unaffected: same UTxO, value \
               \and datum bytes as the CA01 snapshot; authentication \
               \rejects the rival on the derived name"
        )

{- | CA03: the executing negative control that makes CA02 worth
anything. An authenticator checking only policy and address — not
the derived name — ACCEPTS the rival read back from the chain: the
rival is indistinguishable from the canonical registry on every leg
except the name. The same chain-read value bound to the full
authenticator is rejected, so CA02's rejection is attributable to
the derived name alone. Armed (@naive-authenticator@) the row
instead requires the weak authenticator to reject the rival, which
it cannot, and the run fails naming the accepted rival.
-}
runCA03 :: Env -> CaWorld -> IO ()
runCA03 env w = do
    (rivalIn, rivalOut) <- rivalStateUtxo env w
    let cfg = caCfg w
        policyBytes =
            scriptHashBytes (policyID (cagePolicyIdFromCfg cfg))
        canonicalName = deriveAssetName (caSeedRef w)
        weak = authenticateWeak policyBytes (outAssets rivalOut)
        strong = authenticate policyBytes canonicalName (outAssets rivalOut)
    if envControl env == NaiveAuthenticator
        then
            failWith
                ( "CA03 ARMED (naive-authenticator): the policy+address \
                  \authenticator ACCEPTED the rival (UTxO "
                    <> show rivalIn
                    <> "), as designed — the run required the control \
                       \to reject, so the run fails here: without the \
                       \derived-name check the rival passes for the \
                       \canonical registry"
                )
        else pure ()
    require
        ( "CA03: the weak authenticator REJECTED the rival — the \
          \control does not discriminate: policy+address already \
          \excludes the rival, so CA02's rejection is not \
          \attributable to the name check"
        )
        (weak == AuthAccept)
    require
        ( "CA03: the strong authenticator accepted the rival — CA02's \
          \discrimination is gone ("
            <> show strong
            <> ")"
        )
        (strong == AuthReject NameMismatch)
    m <- readIORef (caRivalMeasure w)
    case m of
        Nothing ->
            failWith "CA03: no rival measurements; run CA02 first"
        Just (txid, mem, cpu, size) ->
            writeRowReceipt
                env
                "CA03"
                Accepted
                AgreesWithModel                [txid]
                Nothing
                Nothing
                (Just mem)
                (Just cpu)
                (Just size)
                "node-submit"
                Nothing
    emit
        "row"
        ( "CA03: control fired — the policy+address authenticator \
          \accepts the rival (weak="
            <> show weak
            <> ") while the derived-name check rejects it (strong="
            <> show strong
            <> "): the name is the only discriminator"
        )

{- | CA04: identity derivation per validator by declared arity.
The published manifest (@onchain/script-identity.json@) pins the
state hash and declares parameter count 0; the run requires arity
0, derives the deployment address through the PRODUCTION path
(@cageAddrFromCfg@, the function boot uses) and requires the
actual observed chain address to equal it. Request stays arity 2:
its deployed address must differ from the unapplied request bytes
(live distinctness). One checker decides both the ordinary
derivation and the exact-extra-application (List[]) corruption
against the same observed chain address; the mismatch is observed
and recorded, and the armed flag demands the corrupted derivation
pass (it must fail). The receipt carries typed addresses, arity,
match/distinct/refused outcomes and the explicit off-chain
identity venue — never phase-2 ledger evidence.
-}
runCA04 :: Env -> CaWorld -> IO ()
runCA04 env w = do
    manifest <- readScriptManifest
    let pins = pinsUnder "state.state" manifest
    (pinHash, pinParam) <- case pins of
        [] -> failWith "CA04: the manifest pins no state.state entry"
        (h, p) : rest
            | any ((/= h) . fst) rest ->
                failWith
                    ("CA04: the manifest's pins disagree: " <> show pins)
            | any ((/= p) . snd) rest ->
                failWith
                    ( "CA04: the manifest's parameter counts disagree: "
                        <> show pins
                    )
            | otherwise -> pure (h, p)
    let stateRaw = caRawState w
        unappliedHex = hex (scriptHashBytes (computeScriptHash stateRaw))
    require
        ( "CA04: the pinned unapplied hash 0x"
            <> T.unpack pinHash
            <> " is not this run's blueprint code 0x"
            <> unappliedHex
        )
        (pinHash == T.pack unappliedHex)
    require
        ( "CA04: the manifest declares "
            <> show pinParam
            <> " parameters for state.state, wanted 0 \
               \(zero-parameter state)"
        )
        (pinParam == Just 0)
    -- State arity 0 (NOTE-060, E18 dispositions): the state()
    -- validator takes no parameters — deploy the pinned bytes
    -- directly. The derivation below goes through the PRODUCTION
    -- path (cageAddrFromCfg, the function boot uses), never a
    -- test-only recomputation. Request stays arity 2 (live
    -- distinctness below).
    (stateInCA, stateOut) <- canonicalStateUtxo env w
    let chainAddr = stateOut ^. addrTxOutL
        chainOutref = T.pack (show stateInCA)
        cfg = caCfg w
        -- One checker, both sides (NOTE-067): the same acceptance
        -- decision on the ordinary config and the exact-extra-
        -- application config, with the observed chainAddr held
        -- constant. Separate inequality-only assertions are ruled
        -- out: they pass even if the normal comparison accepts all.
        checkDerivation dcfg =
            let actual = cageAddrFromCfg dcfg (network dcfg)
             in derivationMatches actual chainAddr
        (normalAddr, normalMatches) = checkDerivation cfg
    emit
        "identity"
        ( "CA04: state arity 0 — production derivation "
            <> show normalAddr
            <> " vs chain "
            <> show chainAddr
            <> " (layer equality expected here, carries no weight alone)"
        )
    require "CA04 normal derivation mismatch" normalMatches
    -- Request arity 2 (E18: distinctness retained): the deployed
    -- request address must differ from the unapplied request bytes.
    -- A blanket equal-layers restatement would erase this live
    -- discriminator.
    mTidCA04 <- readIORef (caTidRef w)
    tidCA04 <- case mTidCA04 of
        Just t -> pure t
        Nothing -> failWith "CA04: no token id; run CA01 first"
    let (_, requestBytesCA04, _) = envCodes env
        unappliedReqAddr =
            Addr
                Testnet
                (ScriptHashObj (computeScriptHash requestBytesCA04))
                StakeRefNull
        deployedReqAddr = requestAddrFromCfg cfg tidCA04 (network cfg)
    require
        ( "CA04: request applied layer equals unapplied layer — "
            <> "distinctness lost"
        )
        (deployedReqAddr /= unappliedReqAddr)
    emit
        "identity"
        ( "CA04: request arity 2 distinctness holds (deployed "
            <> show deployedReqAddr
            <> " /= unapplied "
            <> show unappliedReqAddr
            <> ")"
        )
    -- Executed negative, both sides same checker (NOTE-064, E18
    -- venue): the corrupted config differs from cfg in exactly one
    -- thing (the extra List[] application); the observed chain
    -- address is held constant. The mismatch is OBSERVED by the
    -- require below and recorded as DerivRefused — never hardcoded.
    -- Off-chain identity-derivation refusal, not phase-2 ledger
    -- evidence (receipt venue states it).
    let corruptedBytes = applyPreviousPolicies [] stateRaw
        corruptedCfg =
            cfg
                { cageScriptBytes = corruptedBytes
                , cfgScriptHash = computeScriptHash corruptedBytes
                }
        (badAddr, badMatches) = checkDerivation corruptedCfg
        corruptedHex = hex (scriptHashBytes (computeScriptHash corruptedBytes))
    emit
        "identity"
        ( "CA04 derivation [corrupted-List[]]: derived "
            <> show badAddr
            <> " vs chain "
            <> show chainAddr
        )
    require "CA04 corrupted derivation was accepted" (not badMatches)
    emit
        "control"
        ( "CA04: corrupted List[] derivation 0x"
            <> corruptedHex
            <> " refused (mismatch observed via the same checker) — extra application breaks identity"
        )
    if envControl env == UnappliedAddress
        then
            require
                ( "CA04 ARMED (unapplied-address): corrupted derivation "
                    <> show badAddr
                    <> " was required to pass for the deployed script; the chain reports "
                    <> show chainAddr
                    <> " — the check fails for that result, proving it can fail"
                )
                badMatches
        else
            emit
                "control"
                "CA04: armed equality demand available under CONFORMANCE_CONTROL=unapplied-address"
    let derivationEvidence =
            [ DerivationEvidence
                { deValidator = "state.state"
                , deArity = 0
                , deComputed = T.pack (show normalAddr)
                , deReference = T.pack (show chainAddr)
                , deReferenceSource = "chain-observed " <> chainOutref
                , deOutcome = DerivMatch
                , deVenue = derivationVenue
                }
            , DerivationEvidence
                { deValidator = "request.request"
                , deArity = 2
                , deComputed = T.pack (show deployedReqAddr)
                , deReference = T.pack (show unappliedReqAddr)
                , deReferenceSource = "pinned-unapplied"
                , deOutcome = DerivDistinct
                , deVenue = derivationVenue
                }
            , DerivationEvidence
                { deValidator = "state.state"
                , deArity = 0
                , deComputed = T.pack (show badAddr)
                , deReference = T.pack (show chainAddr)
                , deReferenceSource = "chain-observed " <> chainOutref
                , deOutcome = DerivRefused
                , deVenue = derivationVenue
                }
            ]
    m <- readIORef (caBootMeasureRef w)
    case m of
        Nothing -> failWith "CA04: no boot measurements; run CA01 first"
        Just (txid, mem, cpu, size) ->
            writeRowReceipt
                env
                "CA04"
                Accepted
                AgreesWithModel                [txid]
                Nothing
                Nothing
                (Just mem)
                (Just cpu)
                (Just size)
                derivationVenue
                (Just derivationEvidence)
    emit
        "row"
        ( "CA04: pinned state 0x"
            <> unappliedHex
            <> " (0 declared parameters, arity 0) — production derivation "
            <> show normalAddr
            <> " equals the chain-reported address; request arity 2 distinct; corrupted derivation refused via the same checker (receipt carries all three, off-chain venue)"
        )

{- | CA05: a forged output at the canonical address carrying no
registry token is not a registry — and creating it executes
nothing. The protocol specification's rule: creating an output at
Singular's address MUST NOT be treated as execution of its spending
validator. The row shows NO script executed — the accepted
transaction carries no script witness, no redeemer and no mint, and
the node's evaluation reports no purpose — not merely that nothing
bad happened: the same detector fires on the CA01 boot tx, which
carried the state script. The authentication rejects the forgery on
the missing policy token.
-}
runCA05 :: Env -> CaWorld -> IO ()
runCA05 env w = do
    let cfg = caCfg w
        prov = envProv env
        scriptAddr = cageAddrFromCfg cfg (network cfg)
        policyBytes =
            scriptHashBytes (policyID (cagePolicyIdFromCfg cfg))
    -- the forgery mimics the registry as closely as an output can:
    -- the canonical address and the canonical datum itself, minus
    -- the only thing that makes it a registry — the token
    (_, stateOut) <- canonicalStateUtxo env w
    datum <- case extractCageDatum stateOut of
        Just (StateDatum s) -> pure s
        _ -> failWith "CA05: the canonical state has no StateDatum to copy"
    (funderIn, funderOut) <- largestWalletUtxo prov
    let Coin avail = funderOut ^. coinTxOutL
        forgedCoin = 2_000_000
        fee = 500_000
        change = avail - forgedCoin - fee
        forgedOut =
            mkBasicTxOut scriptAddr (MaryValue (Coin forgedCoin) mempty)
                & datumTxOutL .~ mkInlineDatum (toPlcData (StateDatum datum))
        changeOut = mkBasicTxOut genesisAddr (MaryValue (Coin change) mempty)
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton funderIn
                & outputsTxBodyL .~ StrictSeq.fromList [forgedOut, changeOut]
                & feeTxBodyL .~ Coin fee
        unsigned = mkBasicTx body
    require "CA05: the funder is too small for the forgery" (change > forgedCoin)
    require
        "CA05: the forged tx unexpectedly carries script witnesses"
        (null (txScriptWitnesses unsigned))
    evalMap <- Cage.evaluateTx prov unsigned
    require
        ( "CA05: the node evaluated "
            <> show (Map.size evalMap)
            <> " script purposes on a plain payment"
        )
        (Map.null evalMap)
    let signed = addKeyWitness genesisSignKey unsigned
    result <- submitTxResilient (envSubmit env) signed
    case result of
        Rejected reason ->
            failWith
                ( "CA05: the ledger refused the forged output ("
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                    <> ") — creating an output at an address needs \
                       \nobody's permission"
                )
        Submitted _ -> pure ()
    awaitTx signed
    let size = txSizeBytes signed
    emitMeasure env "CA05-forged" 0 0 size
    -- read the forgery back from the chain
    utxos <- Cage.queryUTxOs prov scriptAddr
    forgedLive <- case [o | (i, o) <- utxos, txInTxIdHex i == txIdHex signed] of
        [o] -> pure o
        other ->
            failWith
                ( "CA05: expected the forged output live at the canonical \
                  \address, found "
                    <> show (length other)
                )
    let verdict =
            authenticate
                policyBytes
                (deriveAssetName (caSeedRef w))
                (outAssets forgedLive)
    require
        ( "CA05: authentication accepted the forged output ("
            <> show verdict
            <> ")"
        )
        (verdict == AuthReject PolicyAbsent)
    -- the detector proven able to fire: the same no-script detector
    -- fires on the CA01 boot tx, which carried the state script
    bootTx <- readIORef (caBootTxRef w)
    case bootTx of
        Nothing -> failWith "CA05: no boot tx recorded; run CA01 first"
        Just bt ->
            require
                ( "CA05 control failed: the no-script detector did not \
                  \fire on the boot tx, which carried the state script"
                )
                (not (null (txScriptWitnesses bt)))
    require
        "CA05: the detector reported script execution on the forged payment"
        (null (txScriptWitnesses signed))
    writeRowReceipt
        env
        "CA05"
        Accepted
        AgreesWithModel        [txIdHex signed]
        Nothing
        Nothing
        (Just 0)
        (Just 0)
        (Just size)
        "node-submit"
        Nothing
    emit
        "row"
        ( "CA05: forged output accepted at the canonical address with \
          \NO script executed (no witness, no redeemer, no mint, \
          \empty node evaluation; the same detector fires on the \
          \boot tx) — creating an output is not execution of its \
          \receiving validator; authentication rejects it: no token \
          \under the canonical policy"
        )

-- ---------------------------------------------------------
-- CA helpers
-- ---------------------------------------------------------

-- | The canonical registry's state UTxO, read back from the chain.
canonicalStateUtxo :: Env -> CaWorld -> IO (TxIn, TxOut ConwayEra)
canonicalStateUtxo env w = do
    tid <- readIORef (caTidRef w)
    case tid of
        Nothing ->
            failWith "the canonical registry is not booted; run CA01 first"
        Just t -> stateUtxoByToken env w t

-- | The rival registry's state UTxO, read back from the chain.
rivalStateUtxo :: Env -> CaWorld -> IO (TxIn, TxOut ConwayEra)
rivalStateUtxo env w = do
    tid <- readIORef (caRivalTidRef w)
    case tid of
        Nothing -> failWith "the rival registry is not booted; run CA02 first"
        Just t -> stateUtxoByToken env w t

stateUtxoByToken :: Env -> CaWorld -> TokenId -> IO (TxIn, TxOut ConwayEra)
stateUtxoByToken env w tid = do
    let cfg = caCfg w
    utxos <-
        Cage.queryUTxOs
            (envProv env)
            (cageAddrFromCfg cfg (network cfg))
    case findStateUtxo (cagePolicyIdFromCfg cfg) tid utxos of
        Just u -> pure u
        Nothing ->
            failWith
                ( "no state UTxO carrying token "
                    <> hex (SBS.fromShort (assetNameBytes (unTokenId tid)))
                    <> " is live at the cage address"
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
    pot <- collateralPot env
    (stateIn, _) <- cageStateUtxo env cage
    pp <- Cage.queryProtocolParams prov
    nowMs0 <- currentPosixMs
    upper <- trySlots prov [nowMs0 + 2_000, nowMs0 + 1_500, nowMs0 + 1_000]
    let stateRef = txInToRef stateIn
        script = mkRequestScript cfg tid
        inputs = Set.singleton reqIn
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
        refundCoin = reqVal - fee
        -- A retracted booking is not folded, so the approval that
        -- certified its edge comes back with the deposit.
        refundOut =
            mkBasicTxOut
                (addrFromKeyHashBytes (network cfg) (extractOwnerBytes reqOut))
                (MaryValue (Coin refundCoin) (MultiAsset (rawAssets reqOut)))
        Coin minAda = getMinCoinTxOut @ConwayEra pp refundOut
    require
        "CG07 hand retract: refund under min-ADA"
        (refundCoin >= minAda)
    let handTx =
            draft
                & bodyTxL . feeTxBodyL .~ Coin fee
                & bodyTxL . outputsTxBodyL .~ StrictSeq.fromList [refundOut]
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
a duplicate-key request, a redirected delivery beside its untampered control,
and a registration carrying one required signer the model does not require.
Each request runs through the same builder and driver comparison. The receipt
records all six steps and their chain outcomes. A two-request batch is outside
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
    -- emitted only after all six outcomes and comparisons have completed.
    records <- readIORef (envLiveRecords env)
    require "CG21 did not compare its six requests" (length records == 6)
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
    require "CG22 did not compare its seven requests" (length records == 7)
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

-- ---------------------------------------------------------
-- CS devnet session (serialization boundary)
-- ---------------------------------------------------------

cs02Key :: ByteString
cs02Key = "cs02-key"

runCSSession ::
    [String] ->
    Control ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    NamingCodes ->
    String ->
    String ->
    Bool ->
    FilePath ->
    FilePath ->
    IO ()
runCSSession rows control stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir sock = do
    lsqCh <- newLSQChannel 16
    ltxsCh <- newLTxSChannel 16
    nodeThread <-
        async $
            runNodeClient
                sessionMagic
                sock
                lsqCh
                ltxsCh
    let nodeProv = adaptProvider (mkN2CProvider lsqCh)
    awaitConnection sessionMagic sock nodeThread nodeProv
    let submit = mkN2CSubmitter ltxsCh
    prov <- followedProvider nodeProv submit
    let stateMarker = hex (scriptHashBytes (computeScriptHash stateBytes))
        blueprintIdStr =
            "state:"
                <> stateMarker
                <> " request:"
                <> hex
                    (scriptHashBytes (computeScriptHash requestBytes))
    _ <- Cage.queryProtocolParams prov
    checkFunding prov funderAddr defaultFundingFloor
    mapM_ (runCSRow prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr) rows
    cancel nodeThread
    emit
        "complete"
        (show (length rows) <> "/" <> show (length rows) <> " rows ok")
    -- Partial rows must never read as green: the session ends
    -- partial naming every such row (E18 §3/§4, NOTE-052). CI
    -- enumerates the known partial set; anything else is a failure.
    reportCSPartials receiptsDir rows

-- | Session-end partial accounting for the CS rows: receipts with
-- verdict partial among the rows just run end the session with the
-- specifically accounted partial status (exit 1, distinct report).
-- A loader rejection (including a success verdict carrying partial
-- constructors) fails the session as invalid evidence.
reportCSPartials :: FilePath -> [String] -> IO ()
reportCSPartials receiptsDir rows = do
    loaded <- loadReceipts receiptsDir
    receipts <- case loaded of
        Left err -> failWith ("partial accounting: " <> err)
        Right rs -> pure rs
    let partials =
            [ T.unpack (receiptRow r)
            | r <- receipts
            , receiptVerdict r == Partial
            , T.unpack (receiptRow r) `elem` rows
            ]
    case partials of
        [] -> pure ()
        _ ->
            throwIO
                ( ErrorCall
                    ( "ROWS PARTIAL: named constructors stay unexercised; "
                        <> "receipts carry the exact residuals"
                        <> "\n- Partial: "
                        <> unwords partials
                        <> "\nThese rows are the milestone owner's known partial debt (E18 completes at rebase)."
                    )
                )

runCSRow ::
    Cage.Provider IO ->
    Submitter IO ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    NamingCodes ->
    String ->
    String ->
    Bool ->
    FilePath ->
    Control ->
    String ->
    String ->
    IO ()
runCSRow prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr row = case row of
    "CS02" -> runCS02 prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr
    "CS03" -> runCS03 prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr
    "CS04" -> runCS04 prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr
    "CS05" -> runCS05 prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr
    "CS07" -> runCS07 prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr
    "CS08" -> runCS08 prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr
    _ -> failWith ("CS row not yet implemented: " <> row)

-- | CS02: datum bytes constructed in Haskell and submitted are read
-- back identical (byte-compare submitted vs chain-observed).
runCS02 ::
    Cage.Provider IO ->
    Submitter IO ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    NamingCodes ->
    String ->
    String ->
    Bool ->
    FilePath ->
    Control ->
    String ->
    IO ()
runCS02 prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr = do
    (seedTxIn, _) <- largestWalletUtxo prov
    let cfg = cageCfg stateBytes requestBytes namingCodes (txInToRef seedTxIn)
    unsignedBoot <- bootTokenImpl cfg prov genesisAddr
    let submittedStateDatum = findStateDatum unsignedBoot
    (mem, cpu) <- measureUnitsProv prov unsignedBoot
    signedBoot <- submitWithGenesis submit unsignedBoot
    tid <- extractTokenId cfg signedBoot
    unsignedReq <-
        requestEdgeImpl
            cfg
            prov
            (defaultTip cfg)
            tid
            cs02Key
            edgeInsertActive
            genesisAddr
    let submittedReqDatum = findRequestDatum cs02Key unsignedReq
    signedReq <- submitWithGenesis submit unsignedReq
    observedStateDatum <- readStateDatum prov cfg tid
    observedReqDatum <- readRequestDatum prov cfg tid cs02Key
    case control of
        FalseDatum -> do
            emit "control" "false-datum armed: demanding state bytes match request bytes"
            require
                ("CS02: submitted state bytes differ from chain-observed (control)")
                (submittedStateDatum == submittedReqDatum)
        _ -> do
            require
                ("CS02: state datum bytes differ: submitted " <> show submittedStateDatum <> " vs chain " <> show observedStateDatum)
                (submittedStateDatum == observedStateDatum)
            require
                ("CS02: request datum bytes differ: submitted " <> show submittedReqDatum <> " vs chain " <> show observedReqDatum)
                (submittedReqDatum == observedReqDatum)
    let sizeBoot = txSizeBytes signedBoot
        sizeReq = txSizeBytes signedReq
        size = max sizeBoot sizeReq
    emitMeasureProv prov "CS02" mem cpu size
    writeCSReceipt receiptsDir "CS02" Accepted AgreesWithModel [txIdHex signedBoot, txIdHex signedReq] Nothing Nothing (Just mem) (Just cpu) (Just size) "node-submit" base dirty nodeVer blueprintIdStr Nothing
    emit "row" "CS02: ACCEPTED datum bytes identical (state+request)"

-- | Find the state inline datum in an unsigned transaction's outputs.
findStateDatum :: ConwayTx -> Datum ConwayEra
findStateDatum tx =
    case [d | out <- toList (tx ^. bodyTxL . outputsTxBodyL), Just d <- [datumOfTxOut out], isStateDatum out] of
        [d] -> d
        _ -> error "CS02: unsigned tx has no single state datum"

-- | Find the request inline datum for a key in an unsigned tx.
findRequestDatum :: ByteString -> ConwayTx -> Datum ConwayEra
findRequestDatum key tx =
    case [d | out <- toList (tx ^. bodyTxL . outputsTxBodyL), Just d <- [datumOfTxOut out], isRequestDatum key out] of
        [d] -> d
        _ -> error "CS02: unsigned tx has no single request datum"

isStateDatum :: TxOut ConwayEra -> Bool
isStateDatum out = case extractCageDatum out of
    Just (StateDatum _) -> True
    _ -> False

isRequestDatum :: ByteString -> TxOut ConwayEra -> Bool
isRequestDatum key out = case extractCageDatum out of
    Just (RequestDatum rq) -> requestKey rq == key
    _ -> False

datumOfTxOut :: TxOut ConwayEra -> Maybe (Datum ConwayEra)
datumOfTxOut out = case out ^. datumTxOutL of
    d@(Datum _) -> Just d
    _ -> Nothing

readStateDatum :: Cage.Provider IO -> CageConfig -> TokenId -> IO (Datum ConwayEra)
readStateDatum prov cfg tid = do
    utxos <- Cage.queryUTxOs prov (cageAddrFromCfg cfg (network cfg))
    case findStateUtxo (cagePolicyIdFromCfg cfg) tid utxos of
        Nothing -> failWith "CS02: no state UTxO on chain"
        Just (_, out) -> case datumOfTxOut out of
            Just d -> pure d
            Nothing -> failWith "CS02: state UTxO has no inline datum"

readRequestDatum :: Cage.Provider IO -> CageConfig -> TokenId -> ByteString -> IO (Datum ConwayEra)
readRequestDatum prov cfg tid key = do
    utxos <- Cage.queryUTxOs prov (requestAddrFromCfg cfg tid (network cfg))
    let reqs = findRequestUtxos tid utxos
        matching = [out | (_, out) <- reqs, isRequestDatum key out]
    case matching of
        [out] -> case datumOfTxOut out of
            Just d -> pure d
            Nothing -> failWith "CS02: request UTxO has no inline datum"
        _ -> failWith ("CS02: expected one request UTxO for key, found " <> show (length matching))

-- | Measure execution units via the node, while inputs are unspent.
measureUnitsProv :: Cage.Provider IO -> ConwayTx -> IO (Integer, Integer)
measureUnitsProv prov tx = do
    evalMap <- Cage.evaluateTx prov tx
    let evalStr = Map.map (either (Left . show) Right) evalMap
    units <- case sequence evalStr of
        Left e -> failWith ("measure: node evaluation failed: " <> e)
        Right m -> pure (Map.elems m)
    let mem = sum [m | ExUnits m _ <- units]
        cpu = sum [s | ExUnits _ s <- units]
    pure (fromIntegral mem, fromIntegral cpu)

-- | Emit one fold's units and size against the devnet maxima.
emitMeasureProv :: Cage.Provider IO -> String -> Integer -> Integer -> Integer -> IO ()
emitMeasureProv prov label mem cpu size = do
    pp <- Cage.queryProtocolParams prov
    let ExUnits maxMem maxSteps = pp ^. ppMaxTxExUnitsL
        maxSize = fromIntegral (pp ^. ppMaxTxSizeL) :: Integer
        pct :: Integer -> Integer -> Double
        pct used maxV = fromIntegral used / fromIntegral maxV * 100 :: Double
    emit
        "measure"
        (label
            <> " mem="
            <> show mem
            <> "/"
            <> show maxMem
            <> " cpu="
            <> show cpu
            <> "/"
            <> show maxSteps
            <> " size="
            <> show size
            <> "/"
            <> show maxSize
            <> " (" <> show (pct size maxSize) <> "%)")

writeCSReceipt ::
    FilePath ->
    String ->
    Outcome ->
    Verdict ->
    [String] ->
    Maybe RefusalInfo ->
    Maybe String ->
    Maybe Integer ->
    Maybe Integer ->
    Maybe Integer ->
    T.Text ->
    String ->
    Bool ->
    String ->
    String ->
    Maybe PartialInfo ->
    IO ()
writeCSReceipt dir row outcome verdict txs refusal rejected mem cpu size venue base dirty nodeVer blueprintIdStr partial =
    writeReceiptFile dir $
        Receipt
            { receiptRow = T.pack row
            , receiptOutcome = outcome
            , receiptVerdict = verdict
            , receiptTransactions = map T.pack txs
            , receiptRefusal = refusal
            , receiptRejected = fmap T.pack rejected
            , receiptMem = mem
            , receiptCpu = cpu
            , receiptTxSize = size
            , receiptBase = T.pack base
            , receiptDirty = dirty
            , receiptPartial = partial

            , receiptDerivation = Nothing
            , receiptSteps = Nothing
            , receiptNode = T.pack nodeVer
            , receiptBlueprint = T.pack blueprintIdStr
            , receiptVenue = venue
            }

{- | CS08 (#157 X1): the eight fields of `OnChainTokenState` survive a
chain round trip, with the ACTIVE policy varied Base versus Alt
(NOTE-046: no stake script exists to vary; #157 C7 renamed the field
this row always varied). The four pinned policies are the ones D-BOOT
derives — the application policy from the naming application script and
the three token policies from `witness(kind, registry)` applied — so
this row is also what says the derivation reaches the chain intact.
-}
runCS08 ::
    Cage.Provider IO ->
    Submitter IO ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    NamingCodes ->
    String ->
    String ->
    Bool ->
    FilePath ->
    Control ->
    String ->
    IO ()
runCS08 prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr = do
    -- Base cage: all four pins derived for its own registry identity.
    (seedBase, _) <- largestWalletUtxo prov
    let cfgBase = cageCfg stateBytes requestBytes namingCodes (txInToRef seedBase)
    unsignedBootBase <- bootTokenImpl cfgBase prov genesisAddr
    (mem1, cpu1) <- measureUnitsProv prov unsignedBootBase
    signedBootBase <- submitWithGenesis submit unsignedBootBase
    tidBase <- extractTokenId cfgBase signedBootBase
    observedBase <- readChainState cfgBase prov tidBase
    expectedBase <- expectedStateFromTx unsignedBootBase
    -- Alt cage: one variable moves, the active policy, so the pair
    -- discriminates on exactly that field.
    (seedAlt, _) <- largestWalletUtxo prov
    let cfgAlt0 = cageCfg stateBytes requestBytes namingCodes (txInToRef seedAlt)
        cfgAlt = cfgAlt0{cfgActivePolicy = SBS.pack (replicate 28 7)}
    unsignedBootAlt <- bootTokenImpl cfgAlt prov genesisAddr
    (mem2, cpu2) <- measureUnitsProv prov unsignedBootAlt
    signedBootAlt <- submitWithGenesis submit unsignedBootAlt
    tidAlt <- extractTokenId cfgAlt signedBootAlt
    observedAlt <- readChainState cfgAlt prov tidAlt
    expectedAlt <- expectedStateFromTx unsignedBootAlt
    case control of
        FalseDatum -> do
            emit "control" "false-datum armed: demanding Base==Alt"
            require
                "CS08: Base and Alt states unexpectedly match (control)"
                (observedBase == observedAlt)
        LegacySixField -> do
            emit
                "control"
                "CS08 ARMED (legacy-six-field): demanding the retired \
                \six-field state encoding of the chain's own datum"
            require
                ( "CS08: the chain state encodes "
                    <> show (stateDatumArity observedBase)
                    <> " fields, not the six the retired contract had"
                )
                (stateDatumArity observedBase == 6)
        _ -> do
            require
                ("CS08: Base state fields differ: expected " <> show expectedBase <> " vs chain " <> show observedBase)
                (expectedBase == observedBase)
            require
                ("CS08: Alt state fields differ: expected " <> show expectedAlt <> " vs chain " <> show observedAlt)
                (expectedAlt == observedAlt)
            -- The eight fields, each explicitly, against the boot tx.
            require "CS08: Base root mismatch" (stateRoot observedBase == stateRoot expectedBase)
            require "CS08: Alt root mismatch" (stateRoot observedAlt == stateRoot expectedAlt)
            require "CS08: Base tip mismatch" (stateMaxFee observedBase == stateMaxFee expectedBase)
            require "CS08: Alt tip mismatch" (stateMaxFee observedAlt == stateMaxFee expectedAlt)
            require "CS08: Base processTime mismatch" (stateProcessTime observedBase == stateProcessTime expectedBase)
            require "CS08: Alt processTime mismatch" (stateProcessTime observedAlt == stateProcessTime expectedAlt)
            require "CS08: Base retractTime mismatch" (stateRetractTime observedBase == stateRetractTime expectedBase)
            require "CS08: Alt retractTime mismatch" (stateRetractTime observedAlt == stateRetractTime expectedAlt)
            require "CS08: Base applicationPolicy mismatch" (stateAppPolicy observedBase == stateAppPolicy expectedBase)
            require "CS08: Alt applicationPolicy mismatch" (stateAppPolicy observedAlt == stateAppPolicy expectedAlt)
            require "CS08: Base activePolicy mismatch" (stateActivePolicy observedBase == stateActivePolicy expectedBase)
            require "CS08: Alt activePolicy mismatch" (stateActivePolicy observedAlt == stateActivePolicy expectedAlt)
            require "CS08: Base absentPolicy mismatch" (stateAbsentPolicy observedBase == stateAbsentPolicy expectedBase)
            require "CS08: Alt absentPolicy mismatch" (stateAbsentPolicy observedAlt == stateAbsentPolicy expectedAlt)
            require "CS08: Base terminalPolicy mismatch" (stateTerminalPolicy observedBase == stateTerminalPolicy expectedBase)
            require "CS08: Alt terminalPolicy mismatch" (stateTerminalPolicy observedAlt == stateTerminalPolicy expectedAlt)
            -- The varied field discriminates; the held fields are stable.
            require
                "CS08: Base and Alt activePolicy unexpectedly match"
                (stateActivePolicy observedBase /= stateActivePolicy observedAlt)
            require
                "CS08: applicationPolicy moved between cages"
                (stateAppPolicy observedBase == stateAppPolicy observedAlt)
            -- D-BOOT: the pins are DERIVED. A placeholder would be all
            -- zeroes, and the three token policies are three distinct
            -- applications of one script, so they cannot coincide.
            require
                "CS08: a pinned policy is a placeholder (28 zero bytes)"
                ( all
                    (/= BuiltinByteString (BS.replicate 28 0))
                    [ stateAppPolicy observedBase
                    , stateActivePolicy observedBase
                    , stateAbsentPolicy observedBase
                    , stateTerminalPolicy observedBase
                    ]
                )
            require
                "CS08: the three derived token policies are not distinct"
                ( let ps =
                        [ stateActivePolicy observedBase
                        , stateAbsentPolicy observedBase
                        , stateTerminalPolicy observedBase
                        ]
                   in length (nub ps) == 3
                )
    let mem = max mem1 mem2
        cpu = max cpu1 cpu2
        size = max (txSizeBytes signedBootBase) (txSizeBytes signedBootAlt)
    emitMeasureProv prov "CS08" mem cpu size
    writeCSReceipt receiptsDir "CS08" Accepted AgreesWithModel [txIdHex signedBootBase, txIdHex signedBootAlt] Nothing Nothing (Just mem) (Just cpu) (Just size) "node-submit" base dirty nodeVer blueprintIdStr Nothing
    emit "row" "CS08: ACCEPTED eight fields survive (Base+AltActivePolicy)"

{- | How many fields the state datum actually encodes. The retired
contract had six; #157 C7 made it eight, and the armed control demands
the old arity so the row is shown able to notice a regression.
-}
stateDatumArity :: OnChainTokenState -> Int
stateDatumArity st = case toPlcData st of
    PLC.Constr _ fields -> length fields
    _ -> -1

expectedStateFromTx :: ConwayTx -> IO OnChainTokenState
expectedStateFromTx tx =
    case [s | out <- toList (tx ^. bodyTxL . outputsTxBodyL), Just (StateDatum s) <- [extractCageDatum out]] of
        [s] -> pure s
        _ -> failWith "CS08: unsigned boot has no single StateDatum"

{- | CS07: sequential absence folds exercise Leaf, lone Fork and Branch.
The C fold uses the exact historical C-over-{A,B} regression; D and E
widen the trie until a Branch is witnessed by another accepted fold.
-}
runCS07 ::
    Cage.Provider IO ->
    Submitter IO ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    NamingCodes ->
    String ->
    String ->
    Bool ->
    FilePath ->
    Control ->
    String ->
    IO ()
runCS07 prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr = do
    tm <- mkPureTrieManager
    (seed, _) <- largestWalletUtxo prov
    let cfg = cageCfg stateBytes requestBytes namingCodes (txInToRef seed)
    unsignedBoot <- bootTokenImpl cfg prov genesisAddr
    signedBoot <- submitWithGenesis submit unsignedBoot
    tid <- extractTokenId cfg signedBoot
    createTrie tm tid
    refs <-
        RegistryEdges.publishCageRefs
            cfg
            namingCodes
            prov
            (submitWithGenesis submit)
            genesisAddr
            tid
    folds <-
        mapM
            (insertWitness cfg tm tid refs)
            [ ("cs07-fork-A", [])
            , ("cs07-fork-B1294", [2])
            , ("cs07-fork-C11", [1])
            , ("cs07-fork-D127", [2, 1])
            , ("cs07-fork-E400", [2, 0])
            ]
    let observed = concat [proofStepConstrs tx | (tx, _, _) <- folds]
        witnessed = case control of
            MissingWitness -> filter (/= 1) observed
            _ -> observed
        mem = maximum [m | (_, m, _) <- folds]
        cpu = maximum [c | (_, _, c) <- folds]
        size = maximum [txSizeBytes tx | (tx, _, _) <- folds]
    require "CS07: missing accepted ProofStep witness" (all (`elem` witnessed) [0, 1, 2])
    emitMeasureProv prov "CS07" mem cpu size
    writeCSReceipt
        receiptsDir
        "CS07"
        Accepted
        AgreesWithModel
        (txIdHex signedBoot : [txIdHex tx | (tx, _, _) <- folds])
        Nothing
        Nothing
        (Just mem)
        (Just cpu)
        (Just size)
        "node-submit"
        base
        dirty
        nodeVer
        blueprintIdStr
        Nothing
    emit "row" "CS07: ACCEPTED Branch/Fork/Leaf and Neighbor; C-over-{A,B} absence folded"
  where
    insertWitness cfg tm tid refs (key, expectedSteps) = do
        _ <-
            RegistryEdges.bookEdge
                cfg
                namingCodes
                prov
                (submitWithGenesis submit)
                genesisAddr
                tid
                key
                edgeInsertAbsent
        ctx <- RegistryEdges.registryContextFor cfg namingCodes prov refs
        unsignedFold <-
            updateTokenWithDuties cfg prov tm tid genesisAddr ctx
        require
            ("CS07: unexpected proof for " <> show key <> ": " <> show (proofStepConstrs unsignedFold))
            (proofStepConstrs unsignedFold == expectedSteps)
        require "CS07: malformed Fork Neighbor" (forkNeighborsWellFormed unsignedFold)
        (mem, cpu) <- measureUnitsProv prov unsignedFold
        signedFold <- submitWithGenesis submit unsignedFold
        root <- withTrie tm tid $ \trie -> do
            _ <- walkEdge trie key edgeInsertAbsent
            CageTrie.getRoot trie
        observed <- readChainState cfg prov tid
        require
            "CS07: chain root differs from committed trie"
            (unOnChainRoot (stateRoot observed) == unRoot root)
        emit "CS07-fold" (show key <> " steps=" <> show expectedSteps <> " txid=" <> txIdHex signedFold)
        pure (signedFold, mem, cpu)

cs03KeyA, cs03KeyB :: ByteString
cs03KeyA = "cs03-modify-key"
cs03KeyB = "cs03-retract-key"

fastRetractCfgLocal :: CageConfig -> CageConfig
fastRetractCfgLocal cfg =
    cfg
        { defaultProcessTime = 1_000
        , defaultRetractTime = 30_000
        }

fastRejectCfgLocal :: CageConfig -> CageConfig
fastRejectCfgLocal cfg =
    cfg
        { defaultProcessTime = 1_000
        , defaultRetractTime = 1_000
        }

runCS03 ::
    Cage.Provider IO ->
    Submitter IO ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    NamingCodes ->
    String ->
    String ->
    Bool ->
    FilePath ->
    Control ->
    String ->
    IO ()
runCS03 prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr = do
    tm <- mkPureTrieManager
    (seedA, _) <- largestWalletUtxo prov
    let cfgA = cageCfg stateBytes requestBytes namingCodes (txInToRef seedA)
    unsignedBootA <- bootTokenImpl cfgA prov genesisAddr
    (memBootA, cpuBootA) <- measureUnitsProv prov unsignedBootA
    signedBootA <- submitWithGenesis submit unsignedBootA
    tidA <- extractTokenId cfgA signedBootA
    createTrie tm tidA
    refsA <-
        RegistryEdges.publishCageRefs
            cfgA
            namingCodes
            prov
            (submitWithGenesis submit)
            genesisAddr
            tidA
    _ <-
        RegistryEdges.bookEdge
            cfgA
            namingCodes
            prov
            (submitWithGenesis submit)
            genesisAddr
            tidA
            cs03KeyA
            edgeInsertActive
    ctxA <- RegistryEdges.registryContextFor cfgA namingCodes prov refsA
    unsignedFoldA <-
        updateTokenWithDuties cfgA prov tm tidA genesisAddr ctxA
    require
        "CS03: Modify witness missing Constr 2"
        (2 `elem` spendingConstrs unsignedFoldA)
    require
        "CS03: Contribute witness missing Constr 1"
        (1 `elem` spendingConstrs unsignedFoldA)
    (memFold, cpuFold) <- measureUnitsProv prov unsignedFoldA
    signedFoldA <- submitWithGenesis submit unsignedFoldA
    _ <- withTrie tm tidA $ \t ->
        () <$ walkEdge t cs03KeyA edgeInsertActive
    (seedB, _) <- largestWalletUtxo prov
    let cfgB = fastRetractCfgLocal (cageCfg stateBytes requestBytes namingCodes (txInToRef seedB))
    unsignedBootB <- bootTokenImpl cfgB prov genesisAddr
    (memBootB, cpuBootB) <- measureUnitsProv prov unsignedBootB
    signedBootB <- submitWithGenesis submit unsignedBootB
    tidB <- extractTokenId cfgB signedBootB
    createTrie tm tidB
    unsignedReqB <-
        requestEdgeImpl
            cfgB
            prov
            (defaultTip cfgB)
            tidB
            cs03KeyB
            edgeInsertActive
            genesisAddr
    _ <- submitWithGenesis submit unsignedReqB
    reqTxInB <- findRequestTxIn prov cfgB tidB cs03KeyB
    threadDelay 3_000_000
    unsignedRetract <- retractRequestImpl cfgB prov tidB reqTxInB genesisAddr
    require
        "CS03: Retract witness missing Constr 3"
        (3 `elem` spendingConstrs unsignedRetract)
    (memRetract, cpuRetract) <- measureUnitsProv prov unsignedRetract
    signedRetract <- submitWithGenesis submit unsignedRetract
    let got =
            [ 2 `elem` spendingConstrs signedFoldA
            , 1 `elem` spendingConstrs signedFoldA
            , 3 `elem` spendingConstrs signedRetract
            ]
        labels = ["Modify", "Contribute", "Retract"] :: [String]
        missing = [l | (False, l) <- zip got labels]
    case control of
        MissingWitness -> do
            -- Deliberately FALSE demand on an accepted tx (NOTE-058):
            -- the Retract tx carries Retract 3, so demanding it
            -- absent must fail with exactly this message. A control
            -- that passes on the valid path proves nothing; the
            -- failure below is the evidence it can fail.
            emit "control" "missing-witness armed: demanding Retract absent from its own tx (deliberately false)"
            require
                "CS03: Retract unexpectedly absent from its own tx (control)"
                (3 `notElem` spendingConstrs signedRetract)
        _ ->
            require
                ("CS03: missing accept witnesses: " <> show missing)
                (null missing)
    let mem = maximum [memBootA, memFold, memBootB, memRetract]
        cpu = maximum [cpuBootA, cpuFold, cpuBootB, cpuRetract]
        size =
            maximum
                [ txSizeBytes signedBootA
                , txSizeBytes signedFoldA
                , txSizeBytes signedBootB
                , txSizeBytes signedRetract
                ]
    emitMeasureProv prov "CS03" mem cpu size
    writeCSReceipt receiptsDir "CS03" Accepted Partial [txIdHex signedFoldA, txIdHex signedRetract] Nothing Nothing (Just mem) (Just cpu) (Just size) "node-submit" base dirty nodeVer blueprintIdStr
        ( Just
            ( PartialInfo
                [ ConstructorEvidence "Modify" 2 StandingAccepted (T.pack (txIdHex signedFoldA))
                , ConstructorEvidence "Contribute" 1 StandingAccepted (T.pack (txIdHex signedFoldA))
                , ConstructorEvidence "Retract" 3 StandingAccepted (T.pack (txIdHex signedRetract))
                , ConstructorEvidence "End" 0 StandingResidual "state.ak End refuses every party (ownerless NOTE-028/A-003; builder removed f3a68b1); no accepting path; E18 completes at rebase"
                , ConstructorEvidence "Sweep" 4 StandingResidual "request.ak Sweep refuses every party (ownerless NOTE-028/A-003; builder removed f3a68b1); no accepting path; E18 completes at rebase"
                ]
            )
        )
    emit "row" "CS03: PARTIAL Contribute/Modify/Retract executed; End/Sweep named residuals (E18)"

findRequestTxIn :: Cage.Provider IO -> CageConfig -> TokenId -> ByteString -> IO TxIn
findRequestTxIn prov cfg tid key = do
    utxos <- Cage.queryUTxOs prov (requestAddrFromCfg cfg tid (network cfg))
    let matching = [i | (i, out) <- findRequestUtxos tid utxos, isRequestDatum key out]
    case matching of
        [found] -> pure found
        _ -> failWith ("findRequestTxIn: expected one request for key, found " <> show (length matching))

-- | CS04: wrong constructor index refused, attributed to the script.
runCS04 ::
    Cage.Provider IO ->
    Submitter IO ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    NamingCodes ->
    String ->
    String ->
    Bool ->
    FilePath ->
    Control ->
    String ->
    IO ()
runCS04 prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr = do
    tm <- mkPureTrieManager
    (seed, _) <- largestWalletUtxo prov
    let cfg = cageCfg stateBytes requestBytes namingCodes (txInToRef seed)
    unsignedBoot <- bootTokenImpl cfg prov genesisAddr
    signedBoot <- submitWithGenesis submit unsignedBoot
    tid <- extractTokenId cfg signedBoot
    createTrie tm tid
    refs <-
        RegistryEdges.publishCageRefs
            cfg
            namingCodes
            prov
            (submitWithGenesis submit)
            genesisAddr
            tid
    _ <-
        RegistryEdges.bookEdge
            cfg
            namingCodes
            prov
            (submitWithGenesis submit)
            genesisAddr
            tid
            "cs04-key"
            edgeInsertActive
    ctx <- RegistryEdges.registryContextFor cfg namingCodes prov refs
    unsignedFold <-
        updateTokenWithDuties cfg prov tm tid genesisAddr ctx
    badTx <- tamperModifyToBadIndex prov unsignedFold
    let signedBad = addKeyWitness genesisSignKey badTx
    result <- submitTx submit signedBad
    let deployedState = computeScriptHash stateBytes
        stateMarker = hex (scriptHashBytes deployedState)
        requestMarker =
            hex
                ( scriptHashBytes
                    ( computeScriptHash
                        ( applyRequestParams
                            (scriptHashBytes deployedState)
                            (onChainTokenId tid)
                            requestBytes
                        )
                    )
                )
        activeWitnessMarker =
            hex
                ( scriptHashBytes
                    (hashScript (RegistryEdges.witnessScriptOf cfg namingCodes 1))
                )
        marker = case control of
            WrongReason -> wrongReasonMarker
            _ -> stateMarker
    case result of
        Rejected reason ->
            attributeCS04Refusal receiptsDir base dirty nodeVer blueprintIdStr marker stateMarker requestMarker activeWitnessMarker (T.unpack (TE.decodeUtf8Lenient reason)) (txIdHex signedBad)
        Submitted txid ->
            failWith
                ("CS04 FINDING: wrong-index fold accepted (txid " <> txInHex txid <> ") — reported, not relabelled")
    -- Control: fresh cage accepts a valid fold (refusal discriminates).
    (seedC, _) <- largestWalletUtxo prov
    let cfgC = cageCfg stateBytes requestBytes namingCodes (txInToRef seedC)
    unsignedBootC <- bootTokenImpl cfgC prov genesisAddr
    signedBootC <- submitWithGenesis submit unsignedBootC
    tidC <- extractTokenId cfgC signedBootC
    createTrie tm tidC
    refsC <-
        RegistryEdges.publishCageRefs
            cfgC
            namingCodes
            prov
            (submitWithGenesis submit)
            genesisAddr
            tidC
    _ <-
        RegistryEdges.bookEdge
            cfgC
            namingCodes
            prov
            (submitWithGenesis submit)
            genesisAddr
            tidC
            "cs04-control-key"
            edgeInsertActive
    ctxC <- RegistryEdges.registryContextFor cfgC namingCodes prov refsC
    unsignedFoldC <-
        updateTokenWithDuties cfgC prov tm tidC genesisAddr ctxC
    _ <- submitWithGenesis submit unsignedFoldC
    emit "control" "CS04 control: fresh cage accepted a valid fold"

-- | Retarget a valid Modify fold to Constr 5 keeping its fields:
-- same CBOR size (tags 2 and 5 both one byte), so fee and collateral
-- stay sufficient and any refusal attributes to the script, never to
-- phase 1. Constr 5 names no UpdateRedeemer constructor and the
-- validator must refuse it in phase 2.
tamperModifyToBadIndex :: Cage.Provider IO -> ConwayTx -> IO ConwayTx
tamperModifyToBadIndex prov tx = do
    pp <- Cage.queryProtocolParams prov
    let body = tx ^. bodyTxL
        Redeemers m = tx ^. witsTxL . rdmrsTxWitsL
        scripts = tx ^. witsTxL . scriptTxWitsL
        badMap = Map.map tamperOne m
        tamperOne (Data (PLC.Constr 2 fields), units) = (Data (PLC.Constr 5 fields), units)
        tamperOne other = other
        badRedeemers = Redeemers badMap
        integrity = computeScriptIntegrity pp badRedeemers
        newBody = body & scriptIntegrityHashTxBodyL .~ integrity
    pure (mkBasicTx newBody & witsTxL . scriptTxWitsL .~ scripts & witsTxL . rdmrsTxWitsL .~ badRedeemers)

{- | Attribute a CS04 refusal. The tampered fold breaks fold consistency
shared by the state, request and active-witness scripts, so more than one
can refuse in one submission and the ledger's failure-list order is not
stable. The invariant the row asserts is that the state script — whose
redeemer was tampered — refused; the recorded script set is derived from
the observed hashes in ledger order, never tuned to a run.
-}
attributeCS04Refusal :: FilePath -> String -> Bool -> String -> String -> String -> String -> String -> String -> String -> String -> IO ()
attributeCS04Refusal receiptsDir base dirty nodeVer blueprintIdStr marker stateMarker requestMarker activeWitnessMarker text rejectedTxid =
    case matchRefusal marker text of
        Right () -> do
            let hashes = refusalScriptHashes text
            require
                ("CS04: state script did not refuse; scripts named: " <> show hashes)
                (stateMarker `elem` hashes)
            roles <- mapM toRole hashes
            let trimmed = trimRefusal text
            unless (stateMarker `isInfixOf` trimmed) $
                failWith ("trimmer dropped the attribution; full reason: " <> take 20000 text)
            writeCSReceipt receiptsDir "CS04" Refused AgreesWithModel [] (Just (RefusalInfo {refusalScript = T.intercalate "+" (map T.pack roles), refusalReason = T.pack trimmed, refusalPhase = "phase-2", refusalHashes = map T.pack hashes, refusalBranch = Nothing, refusalLimit = Just "no named validator branch in this compiled trace; attribution is script hash plus phase-2 only"})) (Just rejectedTxid) Nothing Nothing Nothing "node-submit" base dirty nodeVer blueprintIdStr Nothing
            emit "row" ("CS04: REFUSED wrong index by " <> intercalate "+" roles <> " (state marker 0x" <> shortMarker stateMarker <> "; ledger order, unstable)")
        Left mismatch ->
            failWith ("CS04: refusal did not attribute (" <> show mismatch <> "): " <> text)
  where
    toRole h
        | h == stateMarker = pure "state"
        | h == requestMarker = pure "request"
        | h == activeWitnessMarker = pure "witness-active"
        | otherwise = failWith ("CS04: refusal names unknown script " <> h)

-- | CS05: RequestAction + MintRedeemer coverage, Migrating as gap.
runCS05 ::
    Cage.Provider IO ->
    Submitter IO ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    NamingCodes ->
    String ->
    String ->
    Bool ->
    FilePath ->
    Control ->
    String ->
    IO ()
runCS05 prov submit stateBytes requestBytes namingCodes nodeVer base dirty receiptsDir control blueprintIdStr = do
    tm <- mkPureTrieManager
    (seedC, _) <- largestWalletUtxo prov
    let cfgC = cageCfg stateBytes requestBytes namingCodes (txInToRef seedC)
    unsignedBootC <- bootTokenImpl cfgC prov genesisAddr
    (memBoot, cpuBoot) <- measureUnitsProv prov unsignedBootC
    signedBootC <- submitWithGenesis submit unsignedBootC
    tidC <- extractTokenId cfgC signedBootC
    createTrie tm tidC
    require "CS05: Minting witness missing Constr 0" (0 `elem` mintConstrs signedBootC)
    refsC <-
        RegistryEdges.publishCageRefs
            cfgC
            namingCodes
            prov
            (submitWithGenesis submit)
            genesisAddr
            tidC
    _ <-
        RegistryEdges.bookEdge
            cfgC
            namingCodes
            prov
            (submitWithGenesis submit)
            genesisAddr
            tidC
            "cs05-update-key"
            edgeInsertActive
    ctxC <- RegistryEdges.registryContextFor cfgC namingCodes prov refsC
    unsignedFoldC <-
        updateTokenWithDuties cfgC prov tm tidC genesisAddr ctxC
    require "CS05: Update witness missing Constr 0" (0 `elem` requestActionConstrs unsignedFoldC)
    (memFold, cpuFold) <- measureUnitsProv prov unsignedFoldC
    signedFoldC <- submitWithGenesis submit unsignedFoldC
    _ <- withTrie tm tidC $ \t ->
        () <$ walkEdge t "cs05-update-key" edgeInsertActive
    (seedD, _) <- largestWalletUtxo prov
    let cfgD = fastRejectCfgLocal (cageCfg stateBytes requestBytes namingCodes (txInToRef seedD))
    unsignedBootD <- bootTokenImpl cfgD prov genesisAddr
    signedBootD <- submitWithGenesis submit unsignedBootD
    tidD <- extractTokenId cfgD signedBootD
    createTrie tm tidD
    unsignedReqD <-
        requestEdgeImpl
            cfgD
            prov
            (defaultTip cfgD)
            tidD
            "cs05-reject-key"
            edgeInsertActive
            genesisAddr
    _ <- submitWithGenesis submit unsignedReqD
    threadDelay 3_000_000
    unsignedReject <- rejectRequestsImpl cfgD prov tidD genesisAddr
    require "CS05: Rejected witness missing Constr 1" (1 `elem` requestActionConstrs unsignedReject)
    (memReject, cpuReject) <- measureUnitsProv prov unsignedReject
    signedReject <- submitWithGenesis submit unsignedReject
    let actionsFold = requestActionConstrs signedFoldC
        actionsReject = requestActionConstrs signedReject
        mintsBoot = mintConstrs signedBootC
        hasUpdate = 0 `elem` actionsFold
        hasRejected = 1 `elem` actionsReject
        hasMinting = 0 `elem` mintsBoot
        missing =
            [l | (False, l) <- zip [hasUpdate, hasRejected, hasMinting] (["Update", "Rejected", "Minting"] :: [String])]
    case control of
        MissingWitness -> do
            emit "control" "missing-witness armed: demanding Rejected absent"
            require "CS05: Rejected unexpectedly present (control)" (1 `notElem` actionsReject)
        _ ->
            require ("CS05: missing witnesses: " <> show missing) (null missing)
    writeGapMigrating receiptsDir base blueprintIdStr
    let mem = maximum [memBoot, memFold, memReject]
        cpu = maximum [cpuBoot, cpuFold, cpuReject]
        size =
            maximum
                [ txSizeBytes signedBootC
                , txSizeBytes signedFoldC
                , txSizeBytes signedReject
                ]
    emitMeasureProv prov "CS05" mem cpu size
    writeCSReceipt receiptsDir "CS05" Accepted Partial [txIdHex signedBootC, txIdHex signedFoldC, txIdHex signedReject] Nothing Nothing (Just mem) (Just cpu) (Just size) "node-submit" base dirty nodeVer blueprintIdStr
        ( Just
            ( PartialInfo
                [ ConstructorEvidence "Update" 0 StandingAccepted (T.pack (txIdHex signedFoldC))
                , ConstructorEvidence "Rejected" 1 StandingAccepted (T.pack (txIdHex signedReject))
                , ConstructorEvidence "Minting" 0 StandingAccepted (T.pack (txIdHex signedBootC))
                , ConstructorEvidence "Burning" 2 StandingResidual "no accepting path (End removed f3a68b1, ownerless NOTE-028/A-003); E18 completes at rebase"
                , ConstructorEvidence "Migrating" 1 StandingGap "unconditional refusal under ownerless ruling (no attributed witness, no discriminator); wire Constr 1 retained; historical gap gap-CS05-Migrating.txt retained as history"
                ]
            )
        )
    emit "row" "CS05: PARTIAL Update/Rejected/Minting executed; Burning named residual (E18); Migrating gap"

writeGapMigrating :: FilePath -> String -> String -> IO ()
writeGapMigrating receiptsDir base blueprintIdStr = do
    let gap =
            "row: CS05\nconstructor: Migrating (MintRedeemer 1)\nstatus: gap\nreason: unconditional refusal under the ownerless ruling (no attributed witness, no discriminator); wire Constr 1 retained. Historical: previousPolicies=[] on the imported partition (state.ak validateMigration FR1) described the pre-ownerless gap; the allowlist and function are gone with the owner role.\nbase: "
                <> base
                <> "\nblueprint: "
                <> blueprintIdStr
                <> "\n"
    BSL.writeFile (receiptsDir </> "gap-CS05-Migrating.txt") (BSL.fromStrict (TE.encodeUtf8 (T.pack gap)))
    emit "gap" "CS05 Migrating unconditional refusal (ownerless); wire retained, history noted"

{- | t81 present-key `Fork` control (P-B): insert K1, P, Q (predicted
`[]`, `Leaf`-class, `Leaf`-class, all accepted), then an update fold
for present K1 whose proof carries `Fork` on the inclusion path — no
`excluding()` involved. Predicted REFUSED (bare `CekError`): the
divergence is about single-branch-sibling `Fork` per se. An ACCEPTED
fold falsifies that and opens a green path for the row (re-marking
stays an owner ruling). No receipts: this is an investigation probe,
not a row; shapes and verdicts are the evidence.
-}
runForkProbe :: IO ()
runForkProbe = do
    blueprintPath <- requireEnv "REGISTRY_BLUEPRINT"
    (stateBytes, requestBytes, namingCodes) <- loadCodes blueprintPath
    devnetGenesis >>= mapM_ checkGenesis
    nodeVer <- readNodeVersion
    emit "node" nodeVer
    base <- requireBase
    emit "base" base
    bracketTmpDir $ do
        withNodeSocket $ \sock ->
            runForkProbeSession stateBytes requestBytes namingCodes sock

runForkProbeSession :: SBS.ShortByteString -> SBS.ShortByteString -> NamingCodes -> FilePath -> IO ()
runForkProbeSession stateBytes requestBytes namingCodes sock = do
    lsqCh <- newLSQChannel 16
    ltxsCh <- newLTxSChannel 16
    nodeThread <-
        async $
            runNodeClient
                sessionMagic
                sock
                lsqCh
                ltxsCh
    let nodeProv = adaptProvider (mkN2CProvider lsqCh)
    awaitConnection sessionMagic sock nodeThread nodeProv
    let submit = mkN2CSubmitter ltxsCh
    prov <- followedProvider nodeProv submit
    checkFunding prov funderAddr defaultFundingFloor
    tm <- mkPureTrieManager
    (seed, _) <- largestWalletUtxo prov
    let cfg = cageCfg stateBytes requestBytes namingCodes (txInToRef seed)
    unsignedBoot <- bootTokenImpl cfg prov genesisAddr
    signedBoot <- submitWithGenesis submit unsignedBoot
    tid <- extractTokenId cfg signedBoot
    createTrie tm tid
    refs <-
        RegistryEdges.publishCageRefs
            cfg
            namingCodes
            prov
            (submitWithGenesis submit)
            genesisAddr
            tid
    (keyK, keyP, keyQ, _, _, _) <- findPresentForkKeys
    emit "probe-keys" (show (keyK, keyP, keyQ))
    (_, unsigned1) <- insertProbe tm cfg prov submit tid refs keyK
    require
        "probe setup unexpectedly carries Fork"
        (1 `notElem` proofStepConstrs unsigned1)
    (_, unsignedP) <- insertProbe tm cfg prov submit tid refs keyP
    require
        ("probe setup P proof unexpected: " <> show (proofStepConstrs unsignedP))
        (2 `elem` proofStepConstrs unsignedP)
    (_, unsignedQ) <- insertProbe tm cfg prov submit tid refs keyQ
    require
        ("probe setup Q unexpectedly carries Fork: " <> show (proofStepConstrs unsignedQ))
        (1 `notElem` proofStepConstrs unsignedQ)
    emit "probe" "update fold for present K1 (inclusion path, no excluding)"
    _ <-
        RegistryEdges.bookEdge
            cfg
            namingCodes
            prov
            (submitWithGenesis submit)
            genesisAddr
            tid
            keyK
            edgeUpdateActive
    ctx <- RegistryEdges.registryContextFor cfg namingCodes prov refs
    probeResult <-
        try @SomeException
            (updateTokenWithDuties cfg prov tm tid genesisAddr ctx)
    case probeResult of
        Left err -> do
            emit "verdict" "REFUSED as predicted"
            emit "refusal" (take 600 (displayException err))
            emit "complete" "probe done: inclusion-path Fork refused"
        Right unsignedProbe -> do
            emit "verdict" "ACCEPTED against prediction: Fork works on inclusion"
            emit "probe-steps" (show (proofStepConstrs unsignedProbe))
            require
                "accepted probe lacks well-formed Fork neighbor"
                (1 `elem` proofStepConstrs unsignedProbe && forkNeighborsWellFormed unsignedProbe)
            signedProbe <- submitWithGenesis submit unsignedProbe
            emit "probe-txid" (txIdHex signedProbe)
            emit "complete" "probe done: inclusion-path Fork ACCEPTED (falsification)"
    cancel nodeThread
  where
    insertProbe tmInner cfgInner provInner submitInner tidInner refs key = do
        _ <-
            RegistryEdges.bookEdge
                cfgInner
                namingCodes
                provInner
                (submitWithGenesis submitInner)
                genesisAddr
                tidInner
                key
                edgeInsertAbsent
        ctx <- RegistryEdges.registryContextFor cfgInner namingCodes provInner refs
        unsignedFold <-
            updateTokenWithDuties
                cfgInner
                provInner
                tmInner
                tidInner
                genesisAddr
                ctx
        signedFold <- submitWithGenesis submitInner unsignedFold
        _ <- withTrie tmInner tidInner $ \t ->
            () <$ walkEdge t key edgeInsertAbsent
        emit ("probe-insert-" <> T.unpack (TE.decodeUtf8Lenient key)) (show (proofStepConstrs unsignedFold))
        pure (signedFold, unsignedFold)

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
