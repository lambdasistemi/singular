{-# LANGUAGE TypeApplications #-}

{- |
Module      : Conformance.Run
Description : CG02-CG05 and CA01-CA05 devnet sessions: rows, controls, measurements
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
import Data.Aeson (
    FromJSON (..),
    eitherDecode,
    withObject,
    (.:),
    (.:?),
 )
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (intercalate, isInfixOf, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
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
import Cardano.Ledger.Address (Addr (..))
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
import Cardano.Ledger.Api.Scripts.Data (
    Data (..),
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
import Cardano.Ledger.BaseTypes (Network (..), StrictMaybe (..), TxIx (..))
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (eraProtVerHigh, extractHash, hashScript)
import Cardano.Ledger.Credential (Credential (..), StakeReference (..))
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import MPF.Hashes (MPFHash)
import MPF.Proof.Insertion (MPFProof (..))
import Ouroboros.Network.Magic (NetworkMagic (..))

import Cardano.MPFS.Cage.AssetName (deriveAssetName)
import Cardano.MPFS.Cage.Blueprint (
    applyPreviousPolicies,
    applyRequestParams,
    extractCompiledCode,
    loadBlueprint,
 )
import Cardano.MPFS.Cage.Config (CageConfig (..))
import Cardano.MPFS.Cage.Ledger (
    AssetName (..),
    Coin (..),
    ConwayEra,
    ExUnits (..),
    PolicyID (..),
    Root (..),
    SlotNo (..),
    TokenId (..),
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
    onChainTokenId,
    requestAddrFromCfg,
    scriptHashBytes,
    spendingIndex,
    toLedgerData,
    toPlcData,
    trySlots,
    txInToRef,
 )
import Cardano.MPFS.Cage.TxBuilder.End (endTokenImpl)
import Cardano.MPFS.Cage.TxBuilder.Reject (rejectRequestsImpl)
import Cardano.MPFS.Cage.TxBuilder.Request (
    requestDeleteImpl,
    requestInsertImpl,
    requestUpdateImpl,
 )
import Cardano.MPFS.Cage.TxBuilder.Retract (retractRequestImpl)
import Cardano.MPFS.Cage.TxBuilder.Sweep (sweepUtxoImpl)
import Cardano.MPFS.Cage.TxBuilder.Update (updateTokenImpl)
import Cardano.Tx.Balance (
    BalanceResult (..),
    balanceTx,
 )
import Cardano.MPFS.Cage.Types (
    CageDatum (..),
    OnChainOperation (..),
    OnChainRequest (..),
    OnChainRoot (..),
    OnChainTokenState (..),
    OnChainTxOutRef (..),
    ProofStep (..),
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
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins.Internal (BuiltinByteString (..))

import Conformance.Authenticate (
    AuthDecision (..),
    AuthReject (..),
    authenticate,
    authenticateWeak,
 )
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
import Conformance.CS01 (runCS01)
import Conformance.CS06 (runCS06)
import Conformance.Receipt (
    Outcome (..),
    Receipt (..),
    RefusalInfo (..),
    writeReceiptFile,
 )
import Conformance.Refusal (matchRefusal, refusalScriptHashes, trimRefusal, wrongReasonMarker)

-- ---------------------------------------------------------
-- Row vocabulary and control modes
-- ---------------------------------------------------------

canonicalRows :: [String]
canonicalRows =
    [ "CA01"
    , "CA02"
    , "CA03"
    , "CA04"
    , "CA05"
    , "CG02"
    , "CG03"
    , "CG04"
    , "CG05"
    , "CS01"
    , "CS02"
    , "CS03"
    , "CS04"
    , "CS05"
    , "CS06"
    , "CS08"
    ]

-- | Row families by explicit membership. Every partition below filters by
-- these lists, never by exclusion: a catch-all partition silently absorbs
-- the next family of rows (CA01-CA05 were once routed into the CS
-- session by a notElem-CG catch-all). A row in no family fails loudly.
caRows, cgRows, csRows :: [String]
caRows = ["CA01", "CA02", "CA03", "CA04", "CA05"]
cgRows = ["CG02", "CG03", "CG04", "CG05"]
csRows = ["CS01", "CS02", "CS03", "CS04", "CS05", "CS06", "CS08"]

data Control
    = Normal
    | WrongReason
    | FalseClaim
    | WrongIndex
    | WrongParams
    | FalseDatum
    | MissingWitness
    | -- | CA03 armed: the policy+address-only authenticator must
      -- reject the rival, which it cannot. Proves CA02's rejection
      -- is attributable to the derived name and nothing else.
      NaiveAuthenticator
    | -- | CA04 armed: the unapplied layer's address must pass for
      -- the deployed script, which it cannot. Proves the identity
      -- layers are genuinely distinct and the check can fail.
      UnappliedAddress
    deriving stock (Eq, Show)

readControl :: IO Control
readControl = do
    mode <- lookupEnv "CONFORMANCE_CONTROL"
    case mode of
        Nothing -> pure Normal
        Just "wrong-reason" -> pure WrongReason
        Just "false-claim" -> pure FalseClaim
        Just "wrong-index" -> pure WrongIndex
        Just "wrong-params" -> pure WrongParams
        Just "false-datum" -> pure FalseDatum
        Just "missing-witness" -> pure MissingWitness
        Just "naive-authenticator" -> pure NaiveAuthenticator
        Just "unapplied-address" -> pure UnappliedAddress
        Just other ->
            failWith
                ( "unknown CONFORMANCE_CONTROL value " <> other
                )

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
    , envCa :: Maybe CaWorld
    {- ^ the CA session's world: the published canonical seed, the
    boots' results, the canonical snapshot. Nothing in a CG session
    (the row validator keeps the two sessions apart).
    -}
    }

{- | The CA session's world (issue #69). The canonical seed's outRef
is the publication a consumer derives the canonical name from; the
IORefs carry what the rows produce in order (CA01's token id and
snapshot, CA02's rival token id and measurements for CA03's
receipt).
-}
data CaWorld = CaWorld
    { caCfg :: CageConfig
    -- ^ the canonical cage config (seed = the published canonical seed)
    , caSeedRef :: OnChainTxOutRef
    , caRawState :: SBS.ShortByteString
    -- ^ this run's unapplied state code; CA04 hashes it against the
    -- pinned manifest entry before applying the declared parameters
    , caTidRef :: IORef (Maybe TokenId)
    , caSnapRef :: IORef (Maybe CaSnap)
    , caBootTxRef :: IORef (Maybe ConwayTx)
    -- ^ CA01's unsigned boot tx: CA05's no-script detector must fire
    -- on it, proving the detector can detect a script witness
    , caBootMeasureRef ::
        IORef (Maybe (String, Integer, Integer, Integer))
    -- ^ CA01's boot txid and measurements; CA04's receipt evidence
    , caRivalTidRef :: IORef (Maybe TokenId)
    , caRivalMeasure ::
        IORef (Maybe (String, Integer, Integer, Integer))
    -- ^ rival txid, mem, cpu, size — CA02's accepted tx, reused as
    -- CA03's receipt evidence
    }

-- | The canonical registry's chain identity at CA01 time: the exact
-- UTxO, its value and its datum. CA02 proves the rival left it
-- untouched by comparing against this snapshot read back later.
data CaSnap = CaSnap
    { csIn :: TxIn
    , csValue :: MaryValue
    , csDatum :: Datum ConwayEra
    }

-- ---------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------

runRows :: [String] -> FilePath -> IO ()
runRows rawRows receiptsDir = do
    rows <- validateRows rawRows
    control <- readControl
    emit "control" (show control)
    let caRequested = any (`elem` caRows) rows
        cgRequested = any (`elem` cgRows) rows
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
    blueprintPath <- requireEnv "MPFS_BLUEPRINT"
    -- Observe tree identity before any side effect: creating the
    -- receipts directory first would always report dirty.
    base <- requireBase
    emit "base" base
    dirty <- requireTreeClean
    emit "tree" (if dirty then "dirty (receipts record it)" else "clean")
    createDirectoryIfMissing True receiptsDir
    let localRows = [r | r <- rows, r `elem` ["CS01", "CS06"]]
        devnetRows = [r | r <- rows, r `notElem` ["CS01", "CS06"]]
        cgDevnet = [r | r <- devnetRows, r `elem` cgRows]
        caDevnet = [r | r <- devnetRows, r `elem` caRows]
        csDevnet = [r | r <- devnetRows, r `elem` csRows]
        unpartitioned = [r | r <- devnetRows, r `notElem` (caRows <> cgRows <> csRows)]
    unless (null unpartitioned) $
        failWith
            ("rows in no partition: " <> unwords unpartitioned)
    mapM_ (runLocalRow blueprintPath receiptsDir base dirty) localRows
    unless (null devnetRows) $ do
        (stateBytes, requestBytes) <- loadCodes blueprintPath
        nodeVer <- readNodeVersion
        emit "node" nodeVer
        require
            "forged control value collides with a row value"
            (forgedValue `notElem` [cgV1, cgV2, cgV3, cgV4, controlVal])
        unless (null caDevnet) $
            bracketTmpDir $ do
                gDir <- genesisDir
                checkGenesis gDir
                withCardanoNode gDir $ \sock _startMs ->
                    runSession
                        caDevnet
                        control
                        stateBytes
                        requestBytes
                        nodeVer
                        base
                        dirty
                        receiptsDir
                        sock
        unless (null cgDevnet) $
            bracketTmpDir $ do
                gDir <- genesisDir
                checkGenesis gDir
                withCardanoNode gDir $ \sock _startMs ->
                    runSession
                        cgDevnet
                        control
                        stateBytes
                        requestBytes
                        nodeVer
                        base
                        dirty
                        receiptsDir
                        sock
        unless (null csDevnet) $
            bracketTmpDir $ do
                gDir <- genesisDir
                checkGenesis gDir
                withCardanoNode gDir $ \sock _startMs ->
                    runCSSession
                        csDevnet
                        control
                        stateBytes
                        requestBytes
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
        "run needs at least one row: run CA01 CA02 CA03 CA04 CA05 \
         \or CG02 CG03 CG04 CG05"
validateRows raw = do
    let bad = [r | r <- raw, r `notElem` canonicalRows]
    unless (null bad) $
        failWith ("run cannot execute rows: " <> unwords bad)
    let requested = [r | r <- canonicalRows, r `elem` raw]
        hasCa = any (`elem` caRows) requested
        hasCg = any (`elem` cgRows) requested
    when (hasCa && hasCg) $
        failWith
            ( "CA and CG rows run as separate sessions, one devnet \
              \each: run CA01..CA05, then CG02..CG05"
            )
    pure requested

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
        let caMode = any (`elem` caRows) rows
        keys <- newIORef (False, "")
        validUnits <- newIORef (0, 0)
        (env, marker, bootLine) <-
            if caMode
                then do
                    -- CA session: publish the canonical seed by a
                    -- designation split, then CA01 boots from it.
                    -- No cage is booted here: the boot IS row CA01.
                    (seedTxIn, _) <- designateSplit prov submit "canonical"
                    let seedRef = txInToRef seedTxIn
                        cfg = cageCfg stateBytes requestBytes seedRef
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
                            , envKeys = keys
                            , envValidUnits = validUnits
                            , envCa = Just world
                            }
                        , hex (scriptHashBytes (cfgScriptHash cfg))
                        , ( "CA session: canonical seed published at outRef "
                                <> show seedRef
                                <> " — the consumer derives the canonical \
                                   \name as SHA-256 of this outRef"
                          )
                        )
                else do
                    (seedTxIn, _) <- largestWalletUtxo prov
                    let cfg = cageCfg stateBytes requestBytes (txInToRef seedTxIn)
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
                            , envReceiptsDir = receiptsDir
                            , envKeys = keys
                            , envValidUnits = validUnits
                            , envCa = Nothing
                            }
                        , marker'
                        , "cage booted bootTx=" <> txIdHex signedBoot
                        )
        emit "boot" bootLine
        mapM_ (runRow env marker) rows
        cancel nodeThread
        if caMode
            then writeCaCL01 env rows
            else writeCL01Receipt env rows
        emit
            "complete"
            (show (length rows) <> "/" <> show (length rows) <> " rows ok")

blueprintId :: CageConfig -> SBS.ShortByteString -> String
blueprintId cfg requestBytes =
    "state:"
        <> hex (scriptHashBytes (cfgScriptHash cfg))
        <> " request:"
        <> hex (scriptHashBytes (computeScriptHash requestBytes))

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

{- | CL01 for the CA rows: worst-case units and size across the
session's two accepting boots (CA01 canonical, CA02 rival). CA03 and
CA04 name one of those two transactions and reuse its measurements;
CA05 executes no script and reports zeros honestly. Written only
when the full CA set ran, and bound to the run's own receipts.
-}
writeCaCL01 :: Env -> [String] -> IO ()
writeCaCL01 env rows
    | all (`elem` rows) caRows = do
        receipts <- mapM readRowReceipt ["CA01", "CA02"]
        case sequence receipts of
            Just rs ->
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
            Nothing ->
                emit
                    "measure"
                    "CL01 not receipted: the CA01/CA02 receipts are missing"
    | otherwise =
        emit
            "measure"
            "CL01 not receipted: run did not cover CA01 CA02 CA03 CA04 CA05"
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
    "CA01" -> withCa env row runCA01
    "CA02" -> withCa env row runCA02
    "CA03" -> withCa env row runCA03
    "CA04" -> withCa env row runCA04
    "CA05" -> withCa env row runCA05
    "CG02" -> runCG02 env
    "CG03" -> runCG03 env
    "CG04" -> runCG04 env
    "CG05" -> runCG05 env marker
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
    awaitTx
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
    result <- submitTx (envSubmit env) signedBoot
    case result of
        Submitted _ -> pure ()
        Rejected reason ->
            failWith
                ( "CA01: the node refused the canonical boot: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )
    awaitTx
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
        [txIdHex signedBoot]
        Nothing
        Nothing
        (Just mem)
        (Just cpu)
        (Just size)
        "node-submit"
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
    result <- submitTx (envSubmit env) signedRival
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
    awaitTx
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
        [txIdHex signedRival]
        Nothing
        Nothing
        (Just mem)
        (Just cpu)
        (Just size)
        "node-submit"
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
                [txid]
                Nothing
                Nothing
                (Just mem)
                (Just cpu)
                (Just size)
                "node-submit"
    emit
        "row"
        ( "CA03: control fired — the policy+address authenticator \
          \accepts the rival (weak="
            <> show weak
            <> ") while the derived-name check rejects it (strong="
            <> show strong
            <> "): the name is the only discriminator"
        )

{- | CA04: the two identity layers stay distinct and derived. The
published manifest (@onchain/script-identity.json@) pins the
unapplied state hash and declares its parameter count; the run
hashes this run's blueprint code against the pin, applies the
declared parameters in Haskell (@previousPolicies = []@, the
fresh-partition application), derives the applied hash and address,
and requires the address the chain reports for the state UTxO to
equal the derivation — and the library's own derivation, which the
queries use, to agree with both. The executing control: the
unapplied layer's address must NOT pass for the deployed script.
Armed (@unapplied-address@) it must, and the run fails.
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
            <> " parameters for state.state, wanted 1 \
               \(previousPolicies)"
        )
        (pinParam == Just 1)
    let appliedBytes = applyPreviousPolicies [] stateRaw
        appliedHash = computeScriptHash appliedBytes
        appliedHex = hex (scriptHashBytes appliedHash)
        derivedAddr = Addr Testnet (ScriptHashObj appliedHash) StakeRefNull
        unappliedAddr =
            Addr Testnet (ScriptHashObj (computeScriptHash stateRaw)) StakeRefNull
    require
        ( "CA04: the applied hash equals the unapplied hash — \
          \parameter application is a no-op"
        )
        (appliedHex /= unappliedHex)
    (_, stateOut) <- canonicalStateUtxo env w
    let chainAddr = stateOut ^. addrTxOutL
        cfg = caCfg w
    require
        ( "CA04: the chain reports address "
            <> show chainAddr
            <> " but the derivation says "
            <> show derivedAddr
        )
        (chainAddr == derivedAddr)
    require
        "CA04: the derivation disagrees with the library's address"
        (derivedAddr == cageAddrFromCfg cfg (network cfg))
    if envControl env == UnappliedAddress
        then
            failWith
                ( "CA04 ARMED (unapplied-address): the unapplied layer's \
                  \address "
                    <> show unappliedAddr
                    <> " was required to pass for the deployed script; \
                       \the chain reports "
                        <> show chainAddr
                        <> " — the identity layers are distinct, and \
                           \the run fails here"
                )
        else
            require
                ( "CA04 control failed: the unapplied layer's address \
                  \passed for the deployed script"
                )
                (unappliedAddr /= chainAddr)
    m <- readIORef (caBootMeasureRef w)
    case m of
        Nothing -> failWith "CA04: no boot measurements; run CA01 first"
        Just (txid, mem, cpu, size) ->
            writeRowReceipt
                env
                "CA04"
                Accepted
                [txid]
                Nothing
                Nothing
                (Just mem)
                (Just cpu)
                (Just size)
                "node-submit"
    emit
        "row"
        ( "CA04: pinned unapplied 0x"
            <> unappliedHex
            <> " (1 declared parameter) applied in Haskell to 0x"
            <> appliedHex
            <> " — derived address "
            <> show derivedAddr
            <> " equals the chain-reported address; the unapplied \
               \layer's address "
            <> show unappliedAddr
            <> " does not pass for the deployed script (control)"
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
    result <- submitTx (envSubmit env) signed
    case result of
        Rejected reason ->
            failWith
                ( "CA05: the ledger refused the forged output ("
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                    <> ") — creating an output at an address needs \
                       \nobody's permission"
                )
        Submitted _ -> pure ()
    awaitTx
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
        [txIdHex signed]
        Nothing
        Nothing
        (Just 0)
        (Just 0)
        (Just size)
        "node-submit"
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

{- | One output's assets as the authenticator sees them:
policy-id bytes @->@ asset-name bytes @->@ quantity.
-}
outAssets :: TxOut ConwayEra -> Map.Map ByteString (Map.Map ByteString Integer)
outAssets o = case o ^. valueTxOutL of
    MaryValue _ (MultiAsset ma) ->
        Map.fromList
            [
                ( scriptHashBytes (policyID pid)
                , Map.fromList
                    [ (SBS.fromShort (assetNameBytes an), q)
                    | (an, q) <- Map.toList qs
                    ]
                )
            | (pid, qs) <- Map.toList ma
            ]

{- | The no-script-execution detector: the parts of a transaction
that can only exist because a script executed. CA05's forged payment
must be empty under it, and the boot tx — which carried the state
script — must not be, proving the detector can fire.
-}
txScriptWitnesses :: ConwayTx -> [String]
txScriptWitnesses tx =
    [ "script witness"
    | not (Map.null (tx ^. witsTxL . scriptTxWitsL))
    ]
        <> ["redeemers" | redeemersEmpty tx]
        <> ["mint" | mintEmpty tx]
  where
    redeemersEmpty t = case t ^. witsTxL . rdmrsTxWitsL of
        Redeemers m -> not (Map.null m)
    mintEmpty t = case t ^. bodyTxL . mintTxBodyL of
        MultiAsset ma -> not (Map.null ma)

txInTxIdHex :: TxIn -> String
txInTxIdHex (TxIn (TxId h) _) = hex (hashToBytes (extractHash h))

txInIndex :: TxIn -> Integer
txInIndex (TxIn _ (TxIx i)) = toInteger i

-- ---------------------------------------------------------
-- The published script manifest (onchain/script-identity.json)
-- ---------------------------------------------------------

data ValidatorPin = ValidatorPin
    { vpTitle :: T.Text
    , vpHash :: T.Text
    , vpParams :: Maybe Int
    }

instance FromJSON ValidatorPin where
    parseJSON = withObject "ValidatorPin" $ \o ->
        ValidatorPin
            <$> o .: "title"
            <*> o .: "hash"
            <*> o .:? "parameters"

newtype ScriptManifest = ScriptManifest {smValidators :: [ValidatorPin]}

instance FromJSON ScriptManifest where
    parseJSON = withObject "ScriptManifest" $ \o ->
        ScriptManifest <$> o .: "validators"

{- | The manifest is a tracked file of the pinned onchain tree; the
run reads it, never edits it. @MPFS_SCRIPT_IDENTITY@ overrides the
path (the li-refusals convention); the default resolves against the
repository root, wherever the run is invoked from.
-}
readScriptManifest :: IO ScriptManifest
readScriptManifest = do
    path <- manifestPath
    bytes <- BS.readFile path
    case eitherDecode (BSL.fromStrict bytes) of
        Right m -> pure m
        Left err ->
            failWith
                ("the script manifest at " <> path <> " does not parse: " <> err)

manifestPath :: IO FilePath
manifestPath = do
    override <- lookupEnv "MPFS_SCRIPT_IDENTITY"
    case override of
        Just p -> pure p
        Nothing -> do
            root <- readProcess "git" ["rev-parse", "--show-toplevel"] ""
            pure (filter (/= '\n') root </> "onchain" </> "script-identity.json")

pinsUnder :: T.Text -> ScriptManifest -> [(T.Text, Maybe Int)]
pinsUnder prefix m =
    [ (vpHash v, vpParams v)
    | v <- smValidators m
    , prefix `T.isPrefixOf` vpTitle v
    ]

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

-- ---------------------------------------------------------
-- CS devnet session (serialization boundary)
-- ---------------------------------------------------------

cs02Key, cs02Val :: ByteString
cs02Key = "cs02-key"
cs02Val = "cs02-value"

runCSSession ::
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
runCSSession rows control stateBytes requestBytes nodeVer base dirty receiptsDir sock = do
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
        stateMarker = hex (scriptHashBytes (computeScriptHash (applyPreviousPolicies [] stateBytes)))
        blueprintIdStr =
            "state:"
                <> stateMarker
                <> " request:"
                <> hex
                    (scriptHashBytes (computeScriptHash requestBytes))
    _ <- Cage.queryProtocolParams prov
    mapM_ (runCSRow prov submit stateBytes requestBytes nodeVer base dirty receiptsDir control blueprintIdStr) rows
    cancel nodeThread
    emit
        "complete"
        (show (length rows) <> "/" <> show (length rows) <> " rows ok")

runCSRow ::
    Cage.Provider IO ->
    Submitter IO ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    String ->
    String ->
    Bool ->
    FilePath ->
    Control ->
    String ->
    String ->
    IO ()
runCSRow prov submit stateBytes requestBytes nodeVer base dirty receiptsDir control blueprintIdStr row = case row of
    "CS02" -> runCS02 prov submit stateBytes requestBytes nodeVer base dirty receiptsDir control blueprintIdStr
    "CS03" -> runCS03 prov submit stateBytes requestBytes nodeVer base dirty receiptsDir control blueprintIdStr
    "CS04" -> runCS04 prov submit stateBytes requestBytes nodeVer base dirty receiptsDir control blueprintIdStr
    "CS05" -> runCS05 prov submit stateBytes requestBytes nodeVer base dirty receiptsDir control blueprintIdStr
    "CS08" -> runCS08 prov submit stateBytes requestBytes nodeVer base dirty receiptsDir control blueprintIdStr
    _ -> failWith ("CS row not yet implemented: " <> row)

-- | CS02: datum bytes constructed in Haskell and submitted are read
-- back identical (byte-compare submitted vs chain-observed).
runCS02 ::
    Cage.Provider IO ->
    Submitter IO ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    String ->
    String ->
    Bool ->
    FilePath ->
    Control ->
    String ->
    IO ()
runCS02 prov submit stateBytes requestBytes nodeVer base dirty receiptsDir control blueprintIdStr = do
    (seedTxIn, _) <- largestWalletUtxo prov
    let cfg = cageCfg stateBytes requestBytes (txInToRef seedTxIn)
    unsignedBoot <- bootTokenImpl cfg prov genesisAddr
    let submittedStateDatum = findStateDatum unsignedBoot
    (mem, cpu) <- measureUnitsProv prov unsignedBoot
    signedBoot <- submitWithGenesis submit unsignedBoot
    tid <- extractTokenId cfg signedBoot
    unsignedReq <-
        requestInsertImpl
            cfg
            prov
            (defaultTip cfg)
            tid
            cs02Key
            cs02Val
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
    writeCSReceipt receiptsDir "CS02" Accepted [txIdHex signedBoot, txIdHex signedReq] Nothing Nothing (Just mem) (Just cpu) (Just size) "node-submit" base dirty nodeVer blueprintIdStr
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
    IO ()
writeCSReceipt dir row outcome txs refusal rejected mem cpu size venue base dirty nodeVer blueprintIdStr =
    writeReceiptFile dir $
        Receipt
            { receiptRow = T.pack row
            , receiptOutcome = outcome
            , receiptTransactions = map T.pack txs
            , receiptRefusal = refusal
            , receiptRejected = fmap T.pack rejected
            , receiptMem = mem
            , receiptCpu = cpu
            , receiptTxSize = size
            , receiptBase = T.pack base
            , receiptDirty = dirty
            , receiptNode = T.pack nodeVer
            , receiptBlueprint = T.pack blueprintIdStr
            , receiptVenue = venue
            }

-- | CS08: OnChainTokenState six fields survive with stake None and Some.
runCS08 ::
    Cage.Provider IO ->
    Submitter IO ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    String ->
    String ->
    Bool ->
    FilePath ->
    Control ->
    String ->
    IO ()
runCS08 prov submit stateBytes requestBytes nodeVer base dirty receiptsDir control blueprintIdStr = do
    -- None cage.
    (seedNone, _) <- largestWalletUtxo prov
    let cfgNone = cageCfg stateBytes requestBytes (txInToRef seedNone)
    unsignedBootNone <- bootTokenImpl cfgNone prov genesisAddr
    (mem1, cpu1) <- measureUnitsProv prov unsignedBootNone
    signedBootNone <- submitWithGenesis submit unsignedBootNone
    tidNone <- extractTokenId cfgNone signedBootNone
    observedNone <- readChainState cfgNone prov tidNone
    expectedNone <- expectedStateFromTx unsignedBootNone
    -- Some cage (staking script hash in datum).
    stakingBytes <- loadStakingBytes
    let stakeHash = computeScriptHash stakingBytes
    (seedSome, _) <- largestWalletUtxo prov
    let cfgSome0 = cageCfg stateBytes requestBytes (txInToRef seedSome)
        cfgSome = cfgSome0 { cfgStakeScript = Just (stakingBytes, stakeHash) }
    unsignedBootSome <- bootTokenImpl cfgSome prov genesisAddr
    (mem2, cpu2) <- measureUnitsProv prov unsignedBootSome
    signedBootSome <- submitWithGenesis submit unsignedBootSome
    tidSome <- extractTokenId cfgSome signedBootSome
    observedSome <- readChainState cfgSome prov tidSome
    expectedSome <- expectedStateFromTx unsignedBootSome
    case control of
        FalseDatum -> do
            emit "control" "false-datum armed: demanding None==Some"
            require
                ("CS08: None and Some states unexpectedly match (control)")
                (observedNone == observedSome)
        _ -> do
            require
                ("CS08: None state fields differ: expected " <> show expectedNone <> " vs chain " <> show observedNone)
                (expectedNone == observedNone)
            require
                ("CS08: Some state fields differ: expected " <> show expectedSome <> " vs chain " <> show observedSome)
                (expectedSome == observedSome)
            require
                ("CS08: stake_script None expected, got " <> show (stateStakeScript observedNone))
                (stateStakeScript observedNone == Nothing)
            case stateStakeScript observedSome of
                Nothing -> failWith "CS08: stake_script Some expected, got None"
                Just _ -> emit "check-stake-Some" "present ok"
            -- Six fields each, explicitly.
            require "CS08: None root mismatch" (stateRoot observedNone == stateRoot expectedNone)
            require "CS08: Some root mismatch" (stateRoot observedSome == stateRoot expectedSome)
            require "CS08: None tip mismatch" (stateMaxFee observedNone == stateMaxFee expectedNone)
            require "CS08: Some tip mismatch" (stateMaxFee observedSome == stateMaxFee expectedSome)
    let mem = max mem1 mem2
        cpu = max cpu1 cpu2
        size = max (txSizeBytes signedBootNone) (txSizeBytes signedBootSome)
    emitMeasureProv prov "CS08" mem cpu size
    writeCSReceipt receiptsDir "CS08" Accepted [txIdHex signedBootNone, txIdHex signedBootSome] Nothing Nothing (Just mem) (Just cpu) (Just size) "node-submit" base dirty nodeVer blueprintIdStr
    emit "row" "CS08: ACCEPTED six fields survive (None+Some)"

expectedStateFromTx :: ConwayTx -> IO OnChainTokenState
expectedStateFromTx tx =
    case [s | out <- toList (tx ^. bodyTxL . outputsTxBodyL), Just (StateDatum s) <- [extractCageDatum out]] of
        [s] -> pure s
        _ -> failWith "CS08: unsigned boot has no single StateDatum"

loadStakingBytes :: IO SBS.ShortByteString
loadStakingBytes = do
    mPath <- lookupEnv "MPFS_BLUEPRINT"
    path <- case mPath of
        Just p -> pure p
        Nothing -> failWith "run needs MPFS_BLUEPRINT pointing at a plutus blueprint"
    ebp <- loadBlueprint path
    bp <- case ebp of
        Left err -> failWith ("blueprint does not parse: " <> err)
        Right b -> pure b
    case extractCompiledCode "staking.staking" bp of
        Just c -> pure c
        Nothing -> failWith "CS08 gap: blueprint has no staking.staking code"
-- ---------------------------------------------------------
-- CS03-CS07: redeemer inspection + remaining rows
-- ---------------------------------------------------------

redeemerPlutusDatas :: ConwayTx -> [PLC.Data]
redeemerPlutusDatas tx =
    let Redeemers m = tx ^. witsTxL . rdmrsTxWitsL
     in [plc | (Data plc, _) <- Map.elems m]

spendingConstrs :: ConwayTx -> [Integer]
spendingConstrs tx =
    let Redeemers m = tx ^. witsTxL . rdmrsTxWitsL
     in [ix | (ConwaySpending _, (Data (PLC.Constr ix _), _)) <- Map.toList m]

mintConstrs :: ConwayTx -> [Integer]
mintConstrs tx =
    let Redeemers m = tx ^. witsTxL . rdmrsTxWitsL
     in [ix | (ConwayMinting _, (Data (PLC.Constr ix _), _)) <- Map.toList m]

requestActionConstrs :: ConwayTx -> [Integer]
requestActionConstrs tx = concatMap fromDatum (redeemerPlutusDatas tx)
  where
    fromDatum (PLC.Constr 2 [PLC.List actions]) = concatMap fromAction actions
    fromDatum _ = []
    fromAction (PLC.Constr ix _) = [ix]
    fromAction _ = []

cs03KeyA, cs03ValA, cs03KeyB, cs03ValB :: ByteString
cs03KeyA = "cs03-modify-key"
cs03ValA = "cs03-modify-val"
cs03KeyB = "cs03-retract-key"
cs03ValB = "cs03-retract-val"

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

submitGarbage :: Cage.Provider IO -> Submitter IO -> CageConfig -> TokenId -> IO TxIn
submitGarbage prov submit cfg tid = do
    pp <- Cage.queryProtocolParams prov
    walletUtxos <- Cage.queryUTxOs prov genesisAddr
    feeUtxo <- case sortOn (Down . (^. coinTxOutL) . snd) walletUtxos of
        [] -> failWith "garbage: no wallet UTxOs"
        (u : _) -> pure u
    let reqAddr = requestAddrFromCfg cfg tid (network cfg)
        txOut = mkBasicTxOut reqAddr (MaryValue (Coin 3_000_000) mempty)
        tx = mkBasicTx $ mkBasicTxBody & outputsTxBodyL .~ StrictSeq.singleton txOut
    balanced <- case balanceTx pp [feeUtxo] [] genesisAddr tx of
        Left err -> failWith ("garbage: balance failed: " <> show err)
        Right br -> pure (balancedTx br)
    _ <- submitWithGenesis submit balanced
    utxos <- Cage.queryUTxOs prov reqAddr
    case [i | (i, out) <- utxos, isGarbageOut out] of
        [found] -> pure found
        xs -> failWith ("garbage: expected one garbage UTxO, found " <> show (length xs))
  where
    isGarbageOut out = case datumOfTxOut out of
        Nothing -> True
        Just _ -> False
-- | CS03: one executing witness per UpdateRedeemer constructor.
runCS03 ::
    Cage.Provider IO ->
    Submitter IO ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    String ->
    String ->
    Bool ->
    FilePath ->
    Control ->
    String ->
    IO ()
runCS03 prov submit stateBytes requestBytes nodeVer base dirty receiptsDir control blueprintIdStr = do
    tm <- mkPureTrieManager
    (seedA, _) <- largestWalletUtxo prov
    let cfgA = cageCfg stateBytes requestBytes (txInToRef seedA)
    unsignedBootA <- bootTokenImpl cfgA prov genesisAddr
    (memBootA, cpuBootA) <- measureUnitsProv prov unsignedBootA
    signedBootA <- submitWithGenesis submit unsignedBootA
    tidA <- extractTokenId cfgA signedBootA
    createTrie tm tidA
    unsignedReqA <-
        requestInsertImpl
            cfgA
            prov
            (defaultTip cfgA)
            tidA
            cs03KeyA
            cs03ValA
            genesisAddr
    _ <- submitWithGenesis submit unsignedReqA
    unsignedFoldA <- updateTokenImpl cfgA prov tm tidA genesisAddr
    require
        "CS03: Modify witness missing Constr 2"
        (2 `elem` spendingConstrs unsignedFoldA)
    require
        "CS03: Contribute witness missing Constr 1"
        (1 `elem` spendingConstrs unsignedFoldA)
    (memFold, cpuFold) <- measureUnitsProv prov unsignedFoldA
    signedFoldA <- submitWithGenesis submit unsignedFoldA
    _ <- withTrie tm tidA $ \t -> do
        _ <- CageTrie.insert t cs03KeyA cs03ValA
        pure ()
    garbIn <- submitGarbage prov submit cfgA tidA
    unsignedSweep <- sweepUtxoImpl cfgA prov tidA garbIn genesisAddr
    require
        "CS03: Sweep witness missing Constr 4"
        (4 `elem` spendingConstrs unsignedSweep)
    (memSweep, cpuSweep) <- measureUnitsProv prov unsignedSweep
    signedSweep <- submitWithGenesis submit unsignedSweep
    (seedB, _) <- largestWalletUtxo prov
    let cfgB = fastRetractCfgLocal (cageCfg stateBytes requestBytes (txInToRef seedB))
    unsignedBootB <- bootTokenImpl cfgB prov genesisAddr
    (memBootB, cpuBootB) <- measureUnitsProv prov unsignedBootB
    signedBootB <- submitWithGenesis submit unsignedBootB
    tidB <- extractTokenId cfgB signedBootB
    createTrie tm tidB
    unsignedReqB <-
        requestInsertImpl
            cfgB
            prov
            (defaultTip cfgB)
            tidB
            cs03KeyB
            cs03ValB
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
    unsignedEnd <- endTokenImpl cfgA prov tidA genesisAddr
    require
        "CS03: End witness missing Constr 0"
        (0 `elem` spendingConstrs unsignedEnd)
    (memEnd, cpuEnd) <- measureUnitsProv prov unsignedEnd
    signedEnd <- submitWithGenesis submit unsignedEnd
    let got =
            [ 2 `elem` spendingConstrs signedFoldA
            , 1 `elem` spendingConstrs signedFoldA
            , 3 `elem` spendingConstrs signedRetract
            , 4 `elem` spendingConstrs signedSweep
            , 0 `elem` spendingConstrs signedEnd
            ]
        labels = ["Modify", "Contribute", "Retract", "Sweep", "End"] :: [String]
        missing = [l | (False, l) <- zip got labels]
    case control of
        MissingWitness -> do
            emit "control" "missing-witness armed: demanding Sweep absent"
            require
                "CS03: Sweep unexpectedly present (control)"
                (4 `notElem` spendingConstrs signedSweep)
        _ ->
            require
                ("CS03: missing witnesses: " <> show missing)
                (null missing)
    let mem = maximum [memBootA, memFold, memSweep, memBootB, memRetract, memEnd]
        cpu = maximum [cpuBootA, cpuFold, cpuSweep, cpuBootB, cpuRetract, cpuEnd]
        size =
            maximum
                [ txSizeBytes signedBootA
                , txSizeBytes signedFoldA
                , txSizeBytes signedSweep
                , txSizeBytes signedBootB
                , txSizeBytes signedRetract
                , txSizeBytes signedEnd
                ]
    emitMeasureProv prov "CS03" mem cpu size
    writeCSReceipt receiptsDir "CS03" Accepted [txIdHex signedFoldA, txIdHex signedRetract, txIdHex signedSweep, txIdHex signedEnd] Nothing Nothing (Just mem) (Just cpu) (Just size) "node-submit" base dirty nodeVer blueprintIdStr
    emit "row" "CS03: ACCEPTED End/Contribute/Modify/Retract/Sweep executed"

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
    String ->
    String ->
    Bool ->
    FilePath ->
    Control ->
    String ->
    IO ()
runCS04 prov submit stateBytes requestBytes nodeVer base dirty receiptsDir control blueprintIdStr = do
    tm <- mkPureTrieManager
    (seed, _) <- largestWalletUtxo prov
    let cfg = cageCfg stateBytes requestBytes (txInToRef seed)
    unsignedBoot <- bootTokenImpl cfg prov genesisAddr
    signedBoot <- submitWithGenesis submit unsignedBoot
    tid <- extractTokenId cfg signedBoot
    createTrie tm tid
    unsignedReq <-
        requestInsertImpl
            cfg
            prov
            (defaultTip cfg)
            tid
            "cs04-key"
            "cs04-val"
            genesisAddr
    _ <- submitWithGenesis submit unsignedReq
    unsignedFold <- updateTokenImpl cfg prov tm tid genesisAddr
    badTx <- tamperModifyToBadIndex prov unsignedFold
    let signedBad = addKeyWitness genesisSignKey badTx
    result <- submitTx submit signedBad
    let appliedState = computeScriptHash (applyPreviousPolicies [] stateBytes)
        stateMarker = hex (scriptHashBytes appliedState)
        requestMarker =
            hex
                ( scriptHashBytes
                    ( computeScriptHash
                        ( applyRequestParams
                            (scriptHashBytes appliedState)
                            (onChainTokenId tid)
                            requestBytes
                        )
                    )
                )
        marker = case control of
            WrongReason -> wrongReasonMarker
            _ -> stateMarker
    case result of
        Rejected reason ->
            attributeCS04Refusal receiptsDir base dirty nodeVer blueprintIdStr marker stateMarker requestMarker (T.unpack (TE.decodeUtf8Lenient reason)) (txIdHex signedBad)
        Submitted txid ->
            failWith
                ("CS04 FINDING: wrong-index fold accepted (txid " <> txInHex txid <> ") — reported, not relabelled")
    -- Control: fresh cage accepts a valid fold (refusal discriminates).
    (seedC, _) <- largestWalletUtxo prov
    let cfgC = cageCfg stateBytes requestBytes (txInToRef seedC)
    unsignedBootC <- bootTokenImpl cfgC prov genesisAddr
    signedBootC <- submitWithGenesis submit unsignedBootC
    tidC <- extractTokenId cfgC signedBootC
    createTrie tm tidC
    unsignedReqC <-
        requestInsertImpl
            cfgC
            prov
            (defaultTip cfgC)
            tidC
            "cs04-control-key"
            "cs04-control-val"
            genesisAddr
    _ <- submitWithGenesis submit unsignedReqC
    unsignedFoldC <- updateTokenImpl cfgC prov tm tidC genesisAddr
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
shared by both cage scripts, so both can refuse in one submission and
the ledger's failure-list order is not stable. The invariant the row
asserts is that the state script — whose redeemer was tampered —
refused; the recorded script set is derived from the observed hashes
in ledger order, never tuned to a run.
-}
attributeCS04Refusal :: FilePath -> String -> Bool -> String -> String -> String -> String -> String -> String -> String -> IO ()
attributeCS04Refusal receiptsDir base dirty nodeVer blueprintIdStr marker stateMarker requestMarker text rejectedTxid =
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
            writeCSReceipt receiptsDir "CS04" Refused [] (Just (RefusalInfo {refusalScript = T.intercalate "+" (map T.pack roles), refusalReason = T.pack trimmed})) (Just rejectedTxid) Nothing Nothing Nothing "node-submit" base dirty nodeVer blueprintIdStr
            emit "row" ("CS04: REFUSED wrong index by " <> intercalate "+" roles <> " (state marker 0x" <> shortMarker stateMarker <> "; ledger order, unstable)")
        Left mismatch ->
            failWith ("CS04: refusal did not attribute (" <> show mismatch <> "): " <> text)
  where
    toRole h
        | h == stateMarker = pure "state"
        | h == requestMarker = pure "request"
        | otherwise = failWith ("CS04: refusal names unknown script " <> h)

-- | CS05: RequestAction + MintRedeemer coverage, Migrating as gap.
runCS05 ::
    Cage.Provider IO ->
    Submitter IO ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    String ->
    String ->
    Bool ->
    FilePath ->
    Control ->
    String ->
    IO ()
runCS05 prov submit stateBytes requestBytes nodeVer base dirty receiptsDir control blueprintIdStr = do
    tm <- mkPureTrieManager
    (seedC, _) <- largestWalletUtxo prov
    let cfgC = cageCfg stateBytes requestBytes (txInToRef seedC)
    unsignedBootC <- bootTokenImpl cfgC prov genesisAddr
    (memBoot, cpuBoot) <- measureUnitsProv prov unsignedBootC
    signedBootC <- submitWithGenesis submit unsignedBootC
    tidC <- extractTokenId cfgC signedBootC
    createTrie tm tidC
    require "CS05: Minting witness missing Constr 0" (0 `elem` mintConstrs signedBootC)
    unsignedReqC <-
        requestInsertImpl
            cfgC
            prov
            (defaultTip cfgC)
            tidC
            "cs05-update-key"
            "cs05-update-val"
            genesisAddr
    _ <- submitWithGenesis submit unsignedReqC
    unsignedFoldC <- updateTokenImpl cfgC prov tm tidC genesisAddr
    require "CS05: Update witness missing Constr 0" (0 `elem` requestActionConstrs unsignedFoldC)
    (memFold, cpuFold) <- measureUnitsProv prov unsignedFoldC
    signedFoldC <- submitWithGenesis submit unsignedFoldC
    _ <- withTrie tm tidC $ \t -> do
        _ <- CageTrie.insert t "cs05-update-key" "cs05-update-val"
        pure ()
    (seedD, _) <- largestWalletUtxo prov
    let cfgD = fastRejectCfgLocal (cageCfg stateBytes requestBytes (txInToRef seedD))
    unsignedBootD <- bootTokenImpl cfgD prov genesisAddr
    signedBootD <- submitWithGenesis submit unsignedBootD
    tidD <- extractTokenId cfgD signedBootD
    createTrie tm tidD
    unsignedReqD <-
        requestInsertImpl
            cfgD
            prov
            (defaultTip cfgD)
            tidD
            "cs05-reject-key"
            "cs05-reject-val"
            genesisAddr
    _ <- submitWithGenesis submit unsignedReqD
    threadDelay 3_000_000
    unsignedReject <- rejectRequestsImpl cfgD prov tidD genesisAddr
    require "CS05: Rejected witness missing Constr 1" (1 `elem` requestActionConstrs unsignedReject)
    (memReject, cpuReject) <- measureUnitsProv prov unsignedReject
    signedReject <- submitWithGenesis submit unsignedReject
    unsignedEnd <- endTokenImpl cfgC prov tidC genesisAddr
    require "CS05: Burning witness missing Constr 2" (2 `elem` mintConstrs unsignedEnd)
    (memEnd, cpuEnd) <- measureUnitsProv prov unsignedEnd
    signedEnd <- submitWithGenesis submit unsignedEnd
    let actionsFold = requestActionConstrs signedFoldC
        actionsReject = requestActionConstrs signedReject
        mintsBoot = mintConstrs signedBootC
        mintsEnd = mintConstrs signedEnd
        hasUpdate = 0 `elem` actionsFold
        hasRejected = 1 `elem` actionsReject
        hasMinting = 0 `elem` mintsBoot
        hasBurning = 2 `elem` mintsEnd
        missing =
            [l | (False, l) <- zip [hasUpdate, hasRejected, hasMinting, hasBurning] (["Update", "Rejected", "Minting", "Burning"] :: [String])]
    case control of
        MissingWitness -> do
            emit "control" "missing-witness armed: demanding Rejected absent"
            require "CS05: Rejected unexpectedly present (control)" (1 `notElem` actionsReject)
        _ ->
            require ("CS05: missing witnesses: " <> show missing) (null missing)
    writeGapMigrating receiptsDir base blueprintIdStr
    let mem = maximum [memBoot, memFold, memReject, memEnd]
        cpu = maximum [cpuBoot, cpuFold, cpuReject, cpuEnd]
        size =
            maximum
                [ txSizeBytes signedBootC
                , txSizeBytes signedFoldC
                , txSizeBytes signedReject
                , txSizeBytes signedEnd
                ]
    emitMeasureProv prov "CS05" mem cpu size
    writeCSReceipt receiptsDir "CS05" Accepted [txIdHex signedBootC, txIdHex signedFoldC, txIdHex signedReject, txIdHex signedEnd] Nothing Nothing (Just mem) (Just cpu) (Just size) "node-submit" base dirty nodeVer blueprintIdStr
    emit "row" "CS05: ACCEPTED Update/Rejected/Minting/Burning + Migrating gap"

writeGapMigrating :: FilePath -> String -> String -> IO ()
writeGapMigrating receiptsDir base blueprintIdStr = do
    let gap =
            "row: CS05\nconstructor: Migrating (MintRedeemer 1)\nstatus: gap\nreason: previousPolicies=[] on the imported partition, so has(previousPolicies, oldPolicy) fails at state.ak validateMigration FR1; migration needs an allowlisted predecessor plus its state UTxO spent atomically, none exists on a genesis cage.\nbase: "
                <> base
                <> "\nblueprint: "
                <> blueprintIdStr
                <> "\n"
    BSL.writeFile (receiptsDir </> "gap-CS05-Migrating.txt") (BSL.fromStrict (TE.encodeUtf8 (T.pack gap)))
    emit "gap" "CS05 Migrating unreachable on previousPolicies=[] (state.ak FR1)"
