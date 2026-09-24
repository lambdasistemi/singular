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

import Conformance.FoldFixture qualified as FoldFixture

import Conformance.Run.Control
import Conformance.Run.CgRows
import Conformance.Run.CsRows
import Conformance.Run.CaRows
import Conformance.Run.Receipts
import Conformance.Run.Cage
import Conformance.Run.Wallet
import Conformance.Run.Submit
import Conformance.Run.Environment
import Conformance.Run.ForkProbe

import Control.Concurrent.Async (async, cancel)
import Control.Exception (
    ErrorCall (..),
    throwIO,
 )
import Control.Monad (unless, when)
import Data.ByteString.Short qualified as SBS
import Data.IORef (newIORef, readIORef)
import Data.Map.Strict qualified as Map
import System.Directory (createDirectoryIfMissing)

import Singular.Registry.Blueprint (NamingCodes (..))
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (
    AssetName (..),
    TokenId (..),
 )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Trie (TrieManager (..))
import Singular.Registry.Trie.PureManager (mkPureTrieManager)
import Singular.Registry.TxBuilder.Boot (bootTokenImpl)
import Singular.Registry.TxBuilder.Internal (
    scriptHashBytes,
    txInToRef,
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
import Cardano.Node.Client.N2C.Connection (
    newLSQChannel,
    newLTxSChannel,
    runNodeClient,
 )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)

import Conformance.Mirror (
    emit,
    failWith,
    hex,
    newMirror,
    require,
    txIdHex,
 )
import Conformance.CS01 (runCS01)
import Conformance.CS06 (runCS06)
import Conformance.Refusal (wrongReasonMarker)

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
        foldFixture <- FoldFixture.newFixture
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
                            , envFoldFixture = foldFixture
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
                                    , envFoldFixture = foldFixture
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
                                    , envFoldFixture = foldFixture
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
