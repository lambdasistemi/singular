{-# LANGUAGE TypeApplications #-}

{- |
Module      : Conformance.Run
Description : CG02-CG05 devnet session: rows, controls, measurements
License     : Apache-2.0

One @run@ boots a cage on an isolated devnet and executes the
requested generic rows in canonical order, each with its executing
negative control and its measurements. Every result is read back
from the chain; the mirror ("Conformance.Mirror") builds the proofs
and the chain-read root is the only comparison target.

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
chain-read verifications (the run must fail). Both prove the harness
fails when it should.
-}
module Conformance.Run (runRows) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, poll)
import Control.Exception (
    SomeException,
    displayException,
    throwIO,
    try,
 )
import Control.Monad (unless, when)
import Data.Aeson (eitherDecode)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..))
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Lens.Micro ((&), (.~), (^.))
import System.Directory (
    createDirectoryIfMissing,
    doesFileExist,
    getTemporaryDirectory,
    removePathForcibly,
 )
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Posix.Env (setEnv)
import System.Posix.Process (getProcessID)
import System.Process (readProcess, readProcessWithExitCode)

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.PParams (
    ppMaxTxExUnitsL,
    ppMaxTxSizeL,
 )
import Cardano.Ledger.Api.Tx (bodyTxL, estimateMinFeeTx, mkBasicTx, mkBasicTxBody, witsTxL)
import Cardano.Ledger.Api.Tx.Body (
    ValidityInterval (..),
    collateralInputsTxBodyL,
    feeTxBodyL,
    inputsTxBodyL,
    mintTxBodyL,
    outputsTxBodyL,
    reqSignerHashesTxBodyL,
    scriptIntegrityHashTxBodyL,
    vldtTxBodyL,
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
import Cardano.Ledger.BaseTypes (Network (..), StrictMaybe (..))
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (eraProtVerHigh, extractHash, hashScript)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxId (..))
import Cardano.Tx.Ledger (ConwayTx)
import MPF.Hashes (MPFHash)
import MPF.Proof.Insertion (MPFProof (..))
import Ouroboros.Network.Magic (NetworkMagic (..))

import Cardano.MPFS.Cage.Blueprint (
    applyPreviousPolicies,
    extractCompiledCode,
    loadBlueprint,
 )
import Cardano.MPFS.Cage.Config (CageConfig (..))
import Cardano.MPFS.Cage.Ledger (
    Coin (..),
    ConwayEra,
    ExUnits (..),
    Root (..),
    SlotNo (..),
    TokenId (..),
    TxIn,
    TxOut,
 )
import Cardano.MPFS.Cage.Provider qualified as Cage
import Cardano.MPFS.Cage.Trie (TrieManager (..))
import Cardano.MPFS.Cage.Trie qualified as CageTrie
import Cardano.MPFS.Cage.Trie.PureManager (mkPureTrieManager)
import Cardano.MPFS.Cage.TxBuilder.Boot (bootTokenImpl)
import Cardano.MPFS.Cage.TxBuilder.Internal (
    addrFromKeyHashBytes,
    addrWitnessKeyHash,
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    computeScriptHash,
    computeScriptIntegrity,
    extractCageDatum,
    extractOwnerBytes,
    findRequestUtxos,
    findStateUtxo,
    mkCageScript,
    mkInlineDatum,
    mkRequestScript,
    requestAddrFromCfg,
    scriptHashBytes,
    spendingIndex,
    toLedgerData,
    toPlcData,
    trySlots,
    txInToRef,
 )
import Cardano.MPFS.Cage.TxBuilder.Request (
    requestDeleteImpl,
    requestInsertImpl,
    requestUpdateImpl,
 )
import Cardano.MPFS.Cage.TxBuilder.Update (updateTokenImpl)
import Cardano.MPFS.Cage.Types (
    CageDatum (..),
    OnChainOperation (..),
    OnChainRequest (..),
    OnChainRoot (..),
    OnChainTokenState (..),
    OnChainTxOutRef,
    ProofStep,
    RequestAction (Update),
    UpdateRedeemer (..),
 )
import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup (
    addKeyWitness,
    genesisAddr,
    genesisDir,
    genesisSignKey,
 )
import Cardano.Node.Client.N2C.Connection (
    newLSQChannel,
    newLTxSChannel,
    runNodeClient,
 )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
import Cardano.Node.Client.Provider qualified as N2C
import Cardano.Node.Client.Submitter (
    SubmitResult (..),
    Submitter (..),
 )
import PlutusTx.Builtins.Internal (BuiltinByteString (..))

import Conformance.Mirror (
    Mirror,
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
    Receipt (..),
    RefusalInfo (..),
    writeReceiptFile,
 )
import Conformance.Refusal (matchRefusal, trimRefusal, wrongReasonMarker)

-- ---------------------------------------------------------
-- Row vocabulary and control modes
-- ---------------------------------------------------------

canonicalRows :: [String]
canonicalRows = ["CG02", "CG03", "CG04", "CG05"]

data Control
    = Normal
    | WrongReason
    | FalseClaim
    deriving stock (Eq, Show)

readControl :: IO Control
readControl = do
    mode <- lookupEnv "CONFORMANCE_CONTROL"
    case mode of
        Nothing -> pure Normal
        Just "wrong-reason" -> pure WrongReason
        Just "false-claim" -> pure FalseClaim
        Just other ->
            failWith
                ("unknown CONFORMANCE_CONTROL value " <> other)

-- ---------------------------------------------------------
-- Keys and values
-- ---------------------------------------------------------

cgKey, cgV1, cgV2, cgV3, cgV4 :: ByteString
cgKey = "cg-row-key"
cgV1 = "cg-value-one"
cgV2 = "cg-value-two"
cgV3 = "cg-value-three"
cgV4 = "cg-value-occupied-retry"

controlKey, controlVal, forgedValue :: ByteString
controlKey = "cg-control-key"
controlVal = "cg-control-value"
forgedValue = "forged-value"

-- ---------------------------------------------------------
-- Session environment
-- ---------------------------------------------------------

data Env = Env
    { envCfg :: CageConfig
    , envProv :: Cage.Provider IO
    , envSubmit :: Submitter IO
    , envTm :: TrieManager IO
    , envTid :: TokenId
    , envMirror :: Mirror
    , envControl :: Control
    , envBase :: String
    , envDirty :: Bool
    , envNode :: String
    , envBlueprint :: String
    , envReceiptsDir :: FilePath
    , envKeys :: IORef (Bool, ByteString)
    -- ^ (present, current value) for cgKey
    , envValidUnits :: IORef (Integer, Integer)
    {- ^ last valid fold's measured units: the hand-built fold
    declares twice these, so the budget covers the error path
    -}
    }

-- ---------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------

runRows :: [String] -> FilePath -> IO ()
runRows rawRows receiptsDir = do
    rows <- validateRows rawRows
    control <- readControl
    emit "control" (show control)
    blueprintPath <- requireEnv "MPFS_BLUEPRINT"
    (stateBytes, requestBytes) <- loadCodes blueprintPath
    nodeVer <- readNodeVersion
    emit "node" nodeVer
    base <- requireBase
    emit "base" base
    dirty <- requireTreeClean
    emit "tree" (if dirty then "dirty (receipts record it)" else "clean")
    require
        "forged control value collides with a row value"
        (forgedValue `notElem` [cgV1, cgV2, cgV3, cgV4, controlVal])
    createDirectoryIfMissing True receiptsDir
    bracketTmpDir $ do
        gDir <- genesisDir
        checkGenesis gDir
        withCardanoNode gDir $ \sock _startMs ->
            runSession
                rows
                control
                stateBytes
                requestBytes
                nodeVer
                base
                dirty
                receiptsDir
                sock

validateRows :: [String] -> IO [String]
validateRows [] =
    failWith "run needs at least one row: run CG02 CG03 CG04 CG05"
validateRows raw = do
    let bad = [r | r <- raw, r `notElem` canonicalRows]
    unless (null bad) $
        failWith ("run cannot execute rows: " <> unwords bad)
    pure [r | r <- canonicalRows, r `elem` raw]

requireEnv :: String -> IO FilePath
requireEnv name = do
    found <- lookupEnv name
    case found of
        Just path -> pure path
        Nothing ->
            failWith
                ("run needs " <> name <> " pointing at a plutus blueprint")

loadCodes ::
    FilePath ->
    IO (SBS.ShortByteString, SBS.ShortByteString)
loadCodes path = do
    ebp <- loadBlueprint path
    bp <- case ebp of
        Left err -> failWith ("blueprint does not parse: " <> err)
        Right bp -> pure bp
    case ( extractCompiledCode "state.state" bp
         , extractCompiledCode "request.request" bp
         ) of
        (Just stateBytes, Just requestBytes) ->
            pure (stateBytes, requestBytes)
        _ ->
            failWith
                "blueprint has no state.state/request.request code"

{- | The genesis dir must carry the devnet files before the node
spawns; otherwise @prepareTmpDir@ fails mid-copy. Points at
@E2E_GENESIS_DIR@ when the default does not apply.
-}
checkGenesis :: FilePath -> IO ()
checkGenesis dir = do
    ok <- doesFileExist (dir </> "alonzo-genesis.json")
    require
        ( "genesis dir has no alonzo-genesis.json: "
            <> dir
            <> " (set E2E_GENESIS_DIR)"
        )
        ok

readNodeVersion :: IO String
readNodeVersion = do
    out <- readProcess "cardano-node" ["--version"] ""
    case lines out of
        [] -> failWith "cardano-node --version printed nothing"
        first : _ -> pure first

requireBase :: IO String
requireBase = do
    out <- readProcess "git" ["rev-parse", "HEAD"] ""
    case lines out of
        [] -> failWith "git base unknown; receipts need it"
        first : _ -> pure first

{- | Whether the running tree has uncommitted changes. A dirty tree
still runs — its receipts record @dirty: true@ — but only a clean
tree names a commit that reproduces them.
-}
requireTreeClean :: IO Bool
requireTreeClean = do
    (code, out, _) <- readProcessWithExitCode "git" ["status", "--porcelain"] ""
    case code of
        ExitSuccess -> pure (not (null (lines out)))
        _ -> failWith "git status unknown; receipts need tree identity"

-- ---------------------------------------------------------
-- Devnet isolation (not optional)
-- ---------------------------------------------------------

{- | Isolate this run's node: a unique TMPDIR owned by this process,
created before the node starts. @prepareTmpDir@ removes
@$TMPDIR\/cardano-e2e@, so inheriting the default would delete
another lane's database. Verified below, not merely set.
-}
bracketTmpDir :: IO a -> IO a
bracketTmpDir action = do
    sysTmp <- getTemporaryDirectory
    pid <- getProcessID
    now <- getCurrentTime
    let stamp =
            show
                ( floor (utcTimeToPOSIXSeconds now * 1000) ::
                    Integer
                )
        dir =
            sysTmp </> ("conformance-" <> show pid <> "-" <> stamp)
    createDirectoryIfMissing True dir
    setEnv "TMPDIR" dir True
    check <- getTemporaryDirectory
    require
        ( "TMPDIR isolation failed: still "
            <> check
            <> " (wanted "
            <> dir
            <> ")"
        )
        (check == dir)
    require
        ("TMPDIR isolation failed: using the default " <> sysTmp)
        (dir /= sysTmp)
    emit "tmpdir" dir
    result <- try @SomeException action
    removePathForcibly dir
    case result of
        Right a -> pure a
        Left (e :: SomeException) -> throwIO e

-- ---------------------------------------------------------
-- Session
-- ---------------------------------------------------------

runSession ::
    [String] ->
    Control ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    String ->
    String ->
    Bool ->
    FilePath ->
    FilePath ->
    IO ()
runSession
    rows
    control
    stateBytes
    requestBytes
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
                    (NetworkMagic 42)
                    sock
                    lsqCh
                    ltxsCh
        threadDelay 3_000_000
        status <- poll nodeThread
        case status of
            Nothing -> pure ()
            Just _ ->
                failWith "node connection closed before queries ran"
        let prov = adaptProvider (mkN2CProvider lsqCh)
            submit = mkN2CSubmitter ltxsCh
        tm <- mkPureTrieManager
        mirror <- newMirror
        _ <- Cage.queryProtocolParams prov
        (seedTxIn, _) <- largestWalletUtxo prov
        let cfg = cageCfg stateBytes requestBytes (txInToRef seedTxIn)
            stateMarker = hex (scriptHashBytes (cfgScriptHash cfg))
            marker = case control of
                WrongReason -> wrongReasonMarker
                _ -> stateMarker
            blueprintId =
                "state:"
                    <> stateMarker
                    <> " request:"
                    <> hex
                        (scriptHashBytes (computeScriptHash requestBytes))
        unsignedBoot <- bootTokenImpl cfg prov genesisAddr
        signedBoot <- submitWithGenesis submit unsignedBoot
        tid <- extractTokenId cfg signedBoot
        createTrie tm tid
        keys <- newIORef (False, "")
        validUnits <- newIORef (0, 0)
        let env =
                Env
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
                    , envBlueprint = blueprintId
                    , envReceiptsDir = receiptsDir
                    , envKeys = keys
                    , envValidUnits = validUnits
                    }
        emit "boot" ("cage booted bootTx=" <> txIdHex signedBoot)
        mapM_ (runRow env marker) rows
        cancel nodeThread
        writeCL01Receipt env rows
        emit
            "complete"
            (show (length rows) <> "/" <> show (length rows) <> " rows ok")

{- | CL01 for these rows: worst-case units and size across the
slice's accepting folds, with the fold transactions named. The
per-row values live in the row receipts; this receipt records that
every accepting row above reported against the devnet maxima. Full
CL01 closes when every accepting row in the inventory reports.
-}
writeCL01Receipt :: Env -> [String] -> IO ()
writeCL01Receipt env rows = do
    receipts <- mapM readRowReceipt ["CG02", "CG03", "CG04"]
    case (rows, sequence receipts) of
        (requested, Just rs)
            | all (`elem` requested) ["CG02", "CG03", "CG04"] ->
                writeRowReceipt
                    env
                    "CL01"
                    Accepted
                    (map T.unpack (concatMap receiptTransactions rs))
                    Nothing
                    Nothing
                    (Just (maximum (map getMem rs)))
                    (Just (maximum (map getCpu rs)))
                    (Just (maximum (map getSize rs)))
                    "node-submit"
        _ ->
            emit
                "measure"
                "CL01 not receipted: run did not cover CG02 CG03 CG04"
  where
    readRowReceipt row = do
        let path =
                envReceiptsDir env
                    </> ("receipt-" <> row <> ".json")
        exists <- doesFileExist path
        if not exists
            then pure Nothing
            else do
                content <- BSL.readFile path
                case eitherDecode content of
                    Right r -> pure (Just (r :: Receipt))
                    Left _ -> pure Nothing
    getMem r = case receiptMem r of Just m -> m; Nothing -> 0
    getCpu r = case receiptCpu r of Just c -> c; Nothing -> 0
    getSize r = case receiptTxSize r of Just s -> s; Nothing -> 0

{- | The largest wallet UTxO: ample funds for boot, which spends
only the seed and one more input. First-in-query-order would be
dust after a session of folds.
-}
largestWalletUtxo :: Cage.Provider IO -> IO (TxIn, TxOut ConwayEra)
largestWalletUtxo prov = do
    utxos <- Cage.queryUTxOs prov genesisAddr
    case sortOn (Down . (^. coinTxOutL) . snd) utxos of
        [] -> failWith "genesis wallet has no UTxOs; cannot pick a seed"
        u : _ -> pure u

adaptProvider :: N2C.Provider IO -> Cage.Provider IO
adaptProvider p =
    Cage.Provider
        { Cage.queryUTxOs = N2C.queryUTxOs p
        , Cage.queryProtocolParams = N2C.queryProtocolParams p
        , Cage.evaluateTx = N2C.evaluateTx p
        , Cage.posixMsToSlot = N2C.posixMsToSlot p
        , Cage.posixMsCeilSlot = N2C.posixMsCeilSlot p
        }

-- ---------------------------------------------------------
-- Rows
-- ---------------------------------------------------------

runRow :: Env -> String -> String -> IO ()
runRow env marker row = case row of
    "CG02" -> runCG02 env
    "CG03" -> runCG03 env
    "CG04" -> runCG04 env
    "CG05" -> runCG05 env marker
    _ -> failWith ("run cannot execute row: " <> row)

-- | CG02: Update v1->v2 folds; v2 reads back from the chain.
runCG02 :: Env -> IO ()
runCG02 env = do
    ensurePresentV1 env
    (foldTx, mem, cpu, size) <-
        requestAndFold env "CG02" (OpUpdate cgV1 cgV2)
    commitTm env (OpUpdate cgV1 cgV2)
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
        [txIdHex foldTx]
        Nothing
        Nothing
        (Just mem)
        (Just cpu)
        (Just size)
        "node-submit"
    writeIORef (envKeys env) (True, cgV2)
    emit "row" "CG02: ACCEPTED update v1->v2, v2 reads back from chain"

-- | CG03: Delete folds; the key proves absent from the chain.
runCG03 :: Env -> IO ()
runCG03 env = do
    (present, cur) <- readIORef (envKeys env)
    require "CG03 needs the key present; run CG02 first" present
    (preProof, preRoot) <- capturePreProof env
    (foldTx, mem, cpu, size) <-
        requestAndFold env "CG03" (OpDelete cur)
    commitTm env (OpDelete cur)
    verifyAbsentKey
        (envCfg env)
        (envProv env)
        (envMirror env)
        (envTid env)
        cgKey
        cur
        preProof
        preRoot
        (envControl env == FalseClaim)
    writeRowReceipt
        env
        "CG03"
        Accepted
        [txIdHex foldTx]
        Nothing
        Nothing
        (Just mem)
        (Just cpu)
        (Just size)
        "node-submit"
    writeIORef (envKeys env) (False, "")
    emit "row" "CG03: ACCEPTED delete, key absent on chain"

-- | CG04: re-Insert v3 folds; v3 reads back from the chain.
runCG04 :: Env -> IO ()
runCG04 env = do
    (present, _) <- readIORef (envKeys env)
    when present $ do
        emit "setup" "key present; deleting as setup for re-Insert"
        setupDelete env
    (foldTx, mem, cpu, size) <-
        requestAndFold env "CG04" (OpInsert cgV3)
    commitTm env (OpInsert cgV3)
    verifyPresentValue
        (envCfg env)
        (envProv env)
        (envMirror env)
        (envTid env)
        cgKey
        (claimValue env cgV3)
        forgedValue
    writeRowReceipt
        env
        "CG04"
        Accepted
        [txIdHex foldTx]
        Nothing
        Nothing
        (Just mem)
        (Just cpu)
        (Just size)
        "node-submit"
    writeIORef (envKeys env) (True, cgV3)
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
    unsignedReq <-
        requestInsertImpl
            cfg
            prov
            (defaultTip cfg)
            tid
            cgKey
            cgV4
            genesisAddr
    _ <- submitWithGenesis (envSubmit env) unsignedReq
    emit "row" "CG05: occupied insert requested; folding must refuse"
    -- The eval-time observation: genuine evidence about the same
    -- rules, kept as a line, never as the verdict.
    evalNote <-
        try @SomeException
            (updateTokenImpl cfg prov (envTm env) tid genesisAddr)
    case evalNote of
        Left err
            | "build failed" `isInfixOf` displayException err ->
                emit
                    "eval-observation"
                    (trimRefusal (displayException err))
            | otherwise -> throwIO err
        Right _ ->
            emit
                "eval-observation"
                "unexpected: the poisoned fold evaluated; submitting anyway"
    handTx <- buildRefusedFold env
    let signed = addKeyWitness genesisSignKey handTx
    result <- submitTx (envSubmit env) signed
    case result of
        Rejected reason ->
            attributeSubmitRefusal
                env
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

attributeSubmitRefusal :: Env -> String -> String -> String -> IO ()
attributeSubmitRefusal env marker text rejectedTxid =
    case matchRefusal marker text of
        Right () -> do
            let trimmed = trimRefusal text
            unless (marker `isInfixOf` trimmed) $
                failWith
                    ( "trimmer dropped the attribution; full reason: "
                        <> take 20000 text
                    )
            writeRowReceipt
                env
                "CG05"
                Refused
                []
                ( Just
                    ( RefusalInfo
                        { refusalScript = "state"
                        , refusalReason = T.pack trimmed
                        }
                    )
                )
                (Just rejectedTxid)
                Nothing
                Nothing
                Nothing
                "node-submit"
            emit
                "row"
                ( "CG05: REFUSED at submit, attributed to state "
                    <> "(phase-2, marker 0x"
                    <> shortMarker marker
                    <> ")"
                )
        Left mismatch ->
            failWith
                ( "CG05: refusal did not attribute ("
                    <> show mismatch
                    <> "): "
                    <> text
                )

-- | The live-cage control: a fresh cage accepts a valid insert.
controlFreshCage :: Env -> IO ()
controlFreshCage env = do
    let cfg0 = envCfg env
        prov = envProv env
    (seedTxIn, _) <- largestWalletUtxo prov
    let cfg = cfg0{cageSeed = txInToRef seedTxIn}
    unsignedBoot <- bootTokenImpl cfg prov genesisAddr
    signedBoot <- submitWithGenesis (envSubmit env) unsignedBoot
    tid <- extractTokenId cfg signedBoot
    createTrie (envTm env) tid
    unsignedReq <-
        requestInsertImpl
            cfg
            prov
            (defaultTip cfg)
            tid
            controlKey
            controlVal
            genesisAddr
    _ <- submitWithGenesis (envSubmit env) unsignedReq
    foldTx <-
        updateTokenImpl cfg prov (envTm env) tid genesisAddr
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
                requestAndFold env "CG02-setup" (OpInsert cgV1)
            commitTm env (OpInsert cgV1)
            verifyPresentValue
                (envCfg env)
                (envProv env)
                (envMirror env)
                (envTid env)
                cgKey
                (claimValue env cgV1)
                forgedValue
            writeIORef (envKeys env) (True, cgV1)

ensurePresentV3 :: Env -> IO ()
ensurePresentV3 env = do
    (present, val) <- readIORef (envKeys env)
    case (present, val) of
        (True, v) | v == cgV3 -> pure ()
        (True, _) ->
            failWith "CG05 setup: key holds an unexpected value"
        _ -> do
            emit "setup" "key absent; inserting v3 as setup"
            (_, _, _, _) <-
                requestAndFold env "CG05-setup" (OpInsert cgV3)
            commitTm env (OpInsert cgV3)
            verifyPresentValue
                (envCfg env)
                (envProv env)
                (envMirror env)
                (envTid env)
                cgKey
                (claimValue env cgV3)
                forgedValue
            writeIORef (envKeys env) (True, cgV3)

setupDelete :: Env -> IO ()
setupDelete env = do
    (present, cur) <- readIORef (envKeys env)
    require "setup delete needs the key present" present
    (preProof, preRoot) <- capturePreProof env
    (_, _, _, _) <-
        requestAndFold env "CG04-setup" (OpDelete cur)
    commitTm env (OpDelete cur)
    verifyAbsentKey
        (envCfg env)
        (envProv env)
        (envMirror env)
        (envTid env)
        cgKey
        cur
        preProof
        preRoot
        (envControl env == FalseClaim)
    writeIORef (envKeys env) (False, "")

{- | Capture the pre-delete inclusion proof and chain root for the
absence control: the proof bound to the deleted value must not
imply the post-delete root.
-}
capturePreProof :: Env -> IO (MPFProof MPFHash, OnChainRoot)
capturePreProof env = do
    preRoot <-
        stateRoot
            <$> readChainState
                (envCfg env)
                (envProv env)
                (envTid env)
    db <- readIORef (envMirror env)
    case inclusionProofFrom db cgKey of
        Just p -> pure (p, preRoot)
        Nothing ->
            failWith
                "setup: key has no inclusion proof before delete"

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
    let Coin estFee = estimateMinFeeTx pp draft 1 0 0
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
    processOne trie (_, txOut) = do
        let op = case extractCageDatum txOut of
                Just (RequestDatum rq) -> requestValue rq
                _ -> error "hand-build: pending UTxO has no request datum"
        case op of
            OpInsert v -> do
                _ <- CageTrie.insert trie cgKey v
                mSteps <- CageTrie.getProofSteps trie cgKey
                pure (fromMaybe [] mSteps)
            OpDelete _ -> do
                mSteps <- CageTrie.getProofSteps trie cgKey
                _ <- CageTrie.delete trie cgKey
                pure (fromMaybe [] mSteps)
            OpUpdate _ v -> do
                mSteps <- CageTrie.getProofSteps trie cgKey
                _ <- CageTrie.delete trie cgKey
                _ <- CageTrie.insert trie cgKey v
                pure (fromMaybe [] mSteps)

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
    mapM_ (requireAdaOnly . snd) reqUtxos
    oldState <- extractState stateOut
    upperSlot <- foldUpperSlot prov oldState (map snd reqUtxos)
    assembleBody pp funder oldState upperSlot fee
  where
    assembleBody pp funder oldState upperSlot feeAmt = do
        let tipAmount = stateMaxFee oldState
            nReqs = toInteger (length reqUtxos)
            perReqFee = feeAmt `div` nReqs
            remainder = feeAmt - perReqFee * nReqs
        refunds <-
            mapM
                (makeRefund pp tipAmount perReqFee remainder)
                (zip [0 ..] reqUtxos)
        newStateOut <- makeStateOut oldState newRoot
        changeOut <- makeChange pp funder feeAmt refunds
        redeemers <- makeRedeemers stateIn funder reqUtxos proofLists units
        scripts <- makeScripts
        ownerKh <- case stateOwner oldState of
            BuiltinByteString bs -> pure (addrWitnessKeyHash bs)
        let inputs =
                Set.fromList (stateIn : fst funder : map fst reqUtxos)
            integrity = computeScriptIntegrity pp redeemers
            body =
                mkBasicTxBody
                    & inputsTxBodyL .~ inputs
                    & outputsTxBodyL
                        .~ StrictSeq.fromList
                            ([newStateOut] <> refunds <> [changeOut])
                    & feeTxBodyL .~ Coin feeAmt
                    & collateralInputsTxBodyL
                        .~ Set.singleton (fst funder)
                    & reqSignerHashesTxBodyL .~ Set.singleton ownerKh
                    & scriptIntegrityHashTxBodyL .~ integrity
                    & vldtTxBodyL
                        .~ ValidityInterval SNothing (SJust upperSlot)
        pure $
            mkBasicTx body
                & witsTxL . scriptTxWitsL .~ scripts
                & witsTxL . rdmrsTxWitsL .~ redeemers
    makeRefund pp tipAmount perReqFee remainder (i, (_, reqOut)) = do
        let Coin reqVal = reqOut ^. coinTxOutL
            extra = if i == (0 :: Int) then remainder else 0
            refundCoin = reqVal - tipAmount - perReqFee - extra
            refundAddr =
                addrFromKeyHashBytes
                    (network (envCfg env))
                    (extractOwnerBytes reqOut)
            out = mkBasicTxOut refundAddr (injectRefund refundCoin)
            Coin minAda = getMinCoinTxOut @ConwayEra pp out
        require
            ( "hand-build: refund under min-ADA: "
                <> show refundCoin
                <> " < "
                <> show minAda
            )
            (refundCoin >= minAda)
        pure out
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
    makeChange pp funder' feeAmt refunds = do
        let reqCoins = [outCoin o | (_, o) <- reqUtxos]
            funderCoin = outCoin (snd funder')
            refundCoins = [outCoin o | o <- refunds]
            change = sum reqCoins + funderCoin - sum refundCoins - feeAmt
            out =
                mkBasicTxOut
                    genesisAddr
                    (MaryValue (Coin change) mempty)
            Coin minAda = getMinCoinTxOut @ConwayEra pp out
        require
            ("hand-build: change under min-ADA: " <> show change)
            (change >= minAda)
        pure out
    makeRedeemers stateIn' funder' reqUtxos' proofLists' units' = do
        let inputs =
                Set.fromList (stateIn' : fst funder' : map fst reqUtxos')
            statePurpose =
                ConwaySpending (AsIx (spendingIndex stateIn' inputs))
            stateRef = txInToRef stateIn'
            actions =
                zipWith (\_ proofs -> Update proofs) reqUtxos' proofLists'
            modRedeemer = Modify actions
            pairs =
                ( statePurpose
                , (toLedgerData modRedeemer, units')
                )
                    : [ ( ConwaySpending (AsIx (spendingIndex reqIn inputs))
                        , (toLedgerData (Contribute stateRef), units')
                        )
                      | (reqIn, _) <- reqUtxos'
                      ]
        pure (Redeemers (Map.fromList pairs))
    makeScripts = do
        let stateScript = mkCageScript (envCfg env)
            reqScript = mkRequestScript (envCfg env) (envTid env)
        pure
            ( Map.fromList
                [ (hashScript stateScript, stateScript)
                , (hashScript reqScript, reqScript)
                ]
            )
    injectRefund c = MaryValue (Coin c) mempty
    adaOnly out = case out ^. valueTxOutL of
        MaryValue _ (MultiAsset ma) -> Map.null ma
    requireAdaOnly out =
        require "hand-build: request carries tokens" (adaOnly out)

extractState :: TxOut ConwayEra -> IO OnChainTokenState
extractState out = case extractCageDatum out of
    Just (StateDatum s) -> pure s
    _ -> failWith "hand-build: state output has no StateDatum"

-- | Lovelace in an output, era-pinned for the polymorphic lenses.
outCoin :: TxOut ConwayEra -> Integer
outCoin o = let Coin c = o ^. coinTxOutL in c

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
    Env -> String -> OnChainOperation -> IO (ConwayTx, Integer, Integer, Integer)
requestAndFold env label op = do
    let cfg = envCfg env
        prov = envProv env
        tid = envTid env
        tip = defaultTip cfg
    unsignedReq <- case op of
        OpInsert v ->
            requestInsertImpl cfg prov tip tid cgKey v genesisAddr
        OpDelete v ->
            requestDeleteImpl cfg prov tip tid cgKey v genesisAddr
        OpUpdate o n ->
            requestUpdateImpl cfg prov tip tid cgKey o n genesisAddr
    _ <- submitWithGenesis (envSubmit env) unsignedReq
    unsignedFold <-
        updateTokenImpl cfg prov (envTm env) tid genesisAddr
    (stateIn, handFold) <- buildValidFold env
    calibrateFold stateIn handFold unsignedFold
    emit "calibration" (label <> ": hand model matches the library fold")
    (mem, cpu) <- measureUnits env unsignedFold
    writeIORef (envValidUnits env) (mem, cpu)
    signed <- submitWithGenesis (envSubmit env) unsignedFold
    let size = txSizeBytes signed
    emitMeasure env label mem cpu size
    pure (signed, mem, cpu, size)

{- | Commit a landed op to the builder trie. Speculative folds never
commit ('withSpeculativeTrie' discards), so the caller keeps the
trie in step or the next fold proves against a stale root.
-}
commitTm :: Env -> OnChainOperation -> IO ()
commitTm env op =
    withTrie (envTm env) (envTid env) $ \t -> case op of
        OpInsert v -> do
            _ <- CageTrie.insert t cgKey v
            pure ()
        OpDelete _ -> do
            _ <- CageTrie.delete t cgKey
            pure ()
        OpUpdate _ n -> do
            _ <- CageTrie.delete t cgKey
            _ <- CageTrie.insert t cgKey n
            pure ()

-- | The claimed value under test; false-claim mode binds the forgery.
claimValue :: Env -> ByteString -> ByteString
claimValue env val = case envControl env of
    FalseClaim -> forgedValue
    _ -> val

submitWithGenesis :: Submitter IO -> ConwayTx -> IO ConwayTx
submitWithGenesis submit unsignedTx = do
    let signedTx = addKeyWitness genesisSignKey unsignedTx
    result <- submitTx submit signedTx
    case result of
        Submitted _ -> awaitTx >> pure signedTx
        Rejected reason ->
            failWith
                ( "transaction rejected: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )

awaitTx :: IO ()
awaitTx = threadDelay 5_000_000

-- ---------------------------------------------------------
-- Measurements (CL01 for these rows)
-- ---------------------------------------------------------

{- | Measure a fold's execution units: summed over the node's
per-script evaluation of the unsigned transaction, while its
inputs are still unspent. Units come from the running node, never
hardcoded.
-}
measureUnits :: Env -> ConwayTx -> IO (Integer, Integer)
measureUnits env tx = do
    evalMap <- Cage.evaluateTx (envProv env) tx
    let evalStr = Map.map (either (Left . show) Right) evalMap
    units <- case sequence evalStr of
        Left e ->
            failWith ("measure: node evaluation failed: " <> e)
        Right m -> pure (Map.elems m)
    let mem = sum [m | ExUnits m _ <- units]
        cpu = sum [s | ExUnits _ s <- units]
    pure (fromIntegral mem, fromIntegral cpu)

-- | Serialized size of the signed transaction that lands on chain.
txSizeBytes :: ConwayTx -> Integer
txSizeBytes tx =
    fromIntegral (BSL.length (serialize (eraProtVerHigh @ConwayEra) tx))

{- | Print one fold's units and size against the devnet's Conway
maxima, with headroom. Maxima are queried, never hardcoded.
-}
emitMeasure :: Env -> String -> Integer -> Integer -> Integer -> IO ()
emitMeasure env label mem cpu size = do
    pp <- Cage.queryProtocolParams (envProv env)
    let ExUnits maxMem maxSteps = pp ^. ppMaxTxExUnitsL
        maxSize = fromIntegral (pp ^. ppMaxTxSizeL) :: Integer
        pct :: Integer -> Integer -> Double
        pct used maxV =
            (fromIntegral used / fromIntegral maxV * 100) ::
                Double
    emit
        "measure"
        ( label
            <> " fold mem="
            <> show mem
            <> "/"
            <> show maxMem
            <> " ("
            <> show (pct mem (fromIntegral maxMem))
            <> "%, headroom "
            <> show (fromIntegral maxMem - mem)
            <> ") cpu="
            <> show cpu
            <> "/"
            <> show maxSteps
            <> " ("
            <> show (pct cpu (fromIntegral maxSteps))
            <> "%, headroom "
            <> show (fromIntegral maxSteps - cpu)
            <> ") size="
            <> show size
            <> "/"
            <> show maxSize
            <> " ("
            <> show (pct size maxSize)
            <> "%, headroom "
            <> show (maxSize - size)
            <> ")"
        )

-- ---------------------------------------------------------
-- Receipts
-- ---------------------------------------------------------

writeRowReceipt ::
    Env ->
    String ->
    Outcome ->
    [String] ->
    Maybe RefusalInfo ->
    Maybe String ->
    Maybe Integer ->
    Maybe Integer ->
    Maybe Integer ->
    T.Text ->
    IO ()
writeRowReceipt env row outcome txs refusal rejected mem cpu size venue =
    writeReceiptFile (envReceiptsDir env) $
        Receipt
            { receiptRow = T.pack row
            , receiptOutcome = outcome
            , receiptTransactions = map T.pack txs
            , receiptRefusal = refusal
            , receiptRejected = fmap T.pack rejected
            , receiptMem = mem
            , receiptCpu = cpu
            , receiptTxSize = size
            , receiptBase = T.pack (envBase env)
            , receiptDirty = envDirty env
            , receiptNode = T.pack (envNode env)
            , receiptBlueprint = T.pack (envBlueprint env)
            , receiptVenue = venue
            }

-- ---------------------------------------------------------
-- Config and identities
-- ---------------------------------------------------------

cageCfg ::
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    OnChainTxOutRef ->
    CageConfig
cageCfg stateBytes requestBytes seed =
    let appliedStateBytes = applyPreviousPolicies [] stateBytes
     in CageConfig
            { cageScriptBytes = appliedStateBytes
            , requestScriptBytes = requestBytes
            , cfgScriptHash =
                computeScriptHash appliedStateBytes
            , cageSeed = seed
            , defaultProcessTime = 30_000
            , defaultRetractTime = 30_000
            , defaultTip = Coin 1_000_000
            , network = Testnet
            , cfgStakeScript = Nothing
            }

shortMarker :: String -> String
shortMarker marker = take 12 marker

extractTokenId :: CageConfig -> ConwayTx -> IO TokenId
extractTokenId cfg tx =
    let MultiAsset ma = tx ^. bodyTxL . mintTxBodyL
        assets =
            Map.toList (ma Map.! cagePolicyIdFromCfg cfg)
     in case assets of
            [(an, _)] -> pure (TokenId an)
            _ ->
                failWith
                    "extractTokenId: unexpected mint assets"

txInHex :: TxId -> String
txInHex (TxId h) =
    hex (hashToBytes (extractHash h))
