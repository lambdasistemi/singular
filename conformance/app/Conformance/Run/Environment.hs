{- |
Module      : Conformance.Run.Environment
Description : Split out of Conformance.Run (#263); see that module's header
License     : Apache-2.0
-}
module Conformance.Run.Environment (Env (..), RowCage (..), StakeKit (..), CaWorld (..), CaSnap (..), requireEnv, loadCodes, loadNamingCodes, checkNamingPins, genesisAddr, genesisSignKey, checkGenesis, readNodeVersion, requireBase, requireTreeClean, bracketTmpDir, blueprintId, cageCfg, cageCfgWith, shortMarker, extractTokenId, txInHex) where

import Conformance.Run.Control

import Control.Exception (
    SomeException,
    throwIO,
    try,
 )
import Data.Aeson (Value (..))
import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS
import Data.IORef (IORef)
import Data.Map.Strict qualified as Map
import Data.Time (getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Lens.Micro ((^.))
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

import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (mintTxBodyL)
import Cardano.Ledger.Api.Scripts.Data (
    Datum (..),
 )
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Core (extractHash)
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint (
    NamingCodes (..),
    applyBytesParam,
    applyDataParam,
    extractCompiledCode,
    loadBlueprint,
    loadRegistryCodesFromEnv,
 )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (
    Coin (..),
    ConwayEra,
    TokenId (..),
    TxOut,
 )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Trie (TrieManager (..))
import Singular.Registry.TxBuilder.Internal (
    cagePolicyIdFromCfg,
    computeScriptHash,
    scriptHashBytes,
 )
import Singular.Registry.Types (OnChainTxOutRef (..))
import Singular.Registry.Node (
    funderAddr,
    funderSignKey,
 )
import Cardano.Node.Client.E2E.Setup (
    Ed25519DSIGN,
    SignKeyDSIGN,
 )
import Cardano.Node.Client.Submitter (Submitter (..))
import PlutusCore.Data qualified as PLC

import Conformance.Mirror (
    Mirror,
    emit,
    failWith,
    hex,
    require,
 )

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
    , envBlueprintPath :: FilePath
    , envReceiptsDir :: FilePath
    , envCodes :: (SBS.ShortByteString, SBS.ShortByteString, NamingCodes)
    -- ^ (unapplied state bytes, unapplied request bytes, unapplied
    -- consumer bytes) from the session's blueprint: the row cages
    -- boot from these.
    , envKeys :: IORef (Bool, ByteString)
    , envDeleteKey :: IORef (Bool, ByteString)
    , envRefs :: IORef (Maybe [(TxIn, TxOut ConwayEra)])
    -- ^ CG03/CG04 own their own key (D-001): the delete row acts on a
    -- witnessed absence, which the shared key is not once CG02 has
    -- activated it.
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
    , envWorlds :: IORef (Map.Map String RowCage)
    {- ^ the issue #70 rows' cages, booted on first use per row group
    so one row's odd state cannot poison another's
    -}
    , envStake :: IORef (Maybe StakeKit)
    {- ^ the stake_script hook's world (CG14/CG15): the blueprint's
    staking validator, its registered credential, the cage booted
    with the hook set
    -}
    , envKey2 :: IORef (Maybe (SignKeyDSIGN Ed25519DSIGN, Addr))
    {- ^ a second funded wallet (CG19's second request owner),
    split off the genesis wallet on first use
    -}
    , envHeld :: IORef [String]
    {- ^ rows recorded as @held-q002@ this session: Singular's Lean
    and the consumer's theorem disagree and the chain sided with
    Singular's Lean. The session ends non-zero while this is
    non-empty — a hold must never read as a pass.
    -}
    , envFailed :: IORef [String]
    {- ^ rows recorded as @diverges-from-lean@ this session: the
    chain refused what Singular's Lean requires accepted. The
    session ends non-zero while this is non-empty.
    -}
    , envLiveRecords :: IORef [Value]
    , envLiveMeasurements :: IORef [(Integer, Integer, Integer)]
    }


{- | One row group's cage: the config it was booted from, its token,
and the last valid fold's measured units (hand-built refusals
declare twice those).
-}
data RowCage = RowCage
    { rcCfg :: CageConfig
    , rcTid :: IORef (Maybe TokenId)
    , rcUnits :: IORef (Integer, Integer)
    , rcRefs :: [(TxIn, TxOut ConwayEra)]
    -- ^ This cage's reference outputs, published once at boot. Folds
    -- resolve every purpose through them, and publishing is five awaited
    -- submissions — far too many to spend inside a request's phase-1
    -- window, so it happens before any request of this cage exists.
    }


{- | The staking validator's kit (CG14/CG15): the blueprint's
staking validator bytes and hash (cross-checked against the pinned
manifest), and the cage it is registered for. The credential is
registered on the devnet (a withdrawal from an unregistered account
is a phase-1 error, not a verdict on the leg); the bytes and hash
build the withdrawal credential the folds carry. NOTE-046: no
datum hook remains — the former @cfgStakeScript@ pin died with the
owner role, so the kit's cage boots like every other cage.
-}
data StakeKit = StakeKit
    { skBytes :: SBS.ShortByteString
    , skHash :: ScriptHash
    , skCage :: RowCage
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
    IO (SBS.ShortByteString, SBS.ShortByteString, NamingCodes)
loadCodes path = do
    ebp <- loadBlueprint path
    bp <- case ebp of
        Left err -> failWith ("blueprint does not parse: " <> err)
        Right bp -> pure bp
    codes <- loadNamingCodes
    case ( extractCompiledCode "state.state" bp
         , extractCompiledCode "request.request" bp
         ) of
        (Just stateBytes, Just requestBytes) ->
            pure (stateBytes, requestBytes, codes)
        _ ->
            failWith
                "blueprint has no state.state/request.request code"


{- | The naming partition's compiled code (#157 D-BOOT). The four pins
the eight-field boot datum carries are DERIVED from it for the registry
identity each boot creates — never typed, never a placeholder — so the
harness needs the code itself, not a recorded hash: the application
validator declares no parameters, but `witness(kind, registry)` declares
two, and an applied hash cannot be recovered from an unapplied one.
-}
loadNamingCodes :: IO NamingCodes
loadNamingCodes = do
    codes <- loadRegistryCodesFromEnv
    checkNamingPins (ncApplication codes) (ncWitness codes)
    pure codes


{- | Cross-check this run's naming code against the naming partition's
committed manifest, at load rather than at first boot: a derivation from
the wrong code would produce four plausible-looking ids and fail much
later, somewhere else.
-}
checkNamingPins :: SBS.ShortByteString -> SBS.ShortByteString -> IO ()
checkNamingPins appCode witnessCode = do
    let appHex = hex (scriptHashBytes (computeScriptHash appCode))
        witnessHex = hex (scriptHashBytes (computeScriptHash witnessCode))
    emit "naming" ("application 0x" <> appHex <> " witness 0x" <> witnessHex)


{- | The wallet every actor of this run is funded from. On the factory
devnet it is the genesis UTxO key, as it always was; in external-node
mode it is the joiner's own signing key
(`Singular.Registry.Node`). The name is kept so the funding sites
below read unchanged.
-}
genesisAddr :: Addr
genesisAddr = funderAddr


-- | The signing key matching 'genesisAddr'.
genesisSignKey :: SignKeyDSIGN Ed25519DSIGN
genesisSignKey = funderSignKey


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


blueprintId :: CageConfig -> SBS.ShortByteString -> String
blueprintId cfg requestBytes =
    "state:"
        <> hex (scriptHashBytes (cfgScriptHash cfg))
        <> " request:"
        <> hex (scriptHashBytes (computeScriptHash requestBytes))


-- ---------------------------------------------------------
-- Config and identities
-- ---------------------------------------------------------

cageCfg ::
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    NamingCodes ->
    OnChainTxOutRef ->
    CageConfig
cageCfg stateBytes requestBytes namingCodes seed =
    cageCfgWith stateBytes requestBytes namingCodes seed 30_000 30_000


-- | 'cageCfg' with the row-owned phase windows.
cageCfgWith ::
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    NamingCodes ->
    OnChainTxOutRef ->
    -- | process window (ms)
    Integer ->
    -- | retract window (ms)
    Integer ->
    CageConfig
cageCfgWith stateBytes requestBytes namingCodes seed processMs retractMs =
    -- Zero-parameter state (NOTE-060): the current state() validator
    -- takes no parameters — deploy its bytes directly. Applying a
    -- previous-policies list supplies List[] where the runtime
    -- expects a constructor (unConstrData failure at boot).
    let cfgScriptHashValue = computeScriptHash stateBytes
        -- #157 D-BOOT: the four pins for THIS registry identity —
        -- the state policy plus the token name the seed determines —
        -- derived from the naming partition's own compiled code.
        registryId =
            scriptHashBytes cfgScriptHashValue <> deriveAssetName seed
        witnessPolicy kind =
            SBS.toShort
                ( scriptHashBytes
                    ( computeScriptHash
                        ( applyBytesParam
                            registryId
                            (applyDataParam (PLC.I kind) (ncWitness namingCodes))
                        )
                    )
                )
     in CageConfig
            { cageScriptBytes = stateBytes
            , requestScriptBytes = requestBytes
            , cfgScriptHash = cfgScriptHashValue
            , cageSeed = seed
            , defaultProcessTime = processMs
            , defaultRetractTime = retractMs
            , defaultTip = Coin 1_000_000
            -- Ownerless registry (NOTE-028/A-003, NOTE-046): the
            -- representative policy is 28 zero bytes on registry-only
            -- cages (no naming validator reads it here; enforced
            -- at representative mint, not fold). The consumer pin
            -- and script are the candidate's REAL consumer
            -- (NOTE-049): state.validModify always requires the
            -- exact pinned withdrawal, and the builders refuse an
            -- empty script — zeros would fail closed at first fold.
            , cfgApplicationPolicy =
                SBS.toShort
                    (scriptHashBytes (computeScriptHash (ncApplication namingCodes)))
            , cfgAbsentPolicy = witnessPolicy 0
            , cfgActivePolicy = witnessPolicy 1
            , cfgTerminalPolicy = witnessPolicy 2
            , cfgConsumerScript = SBS.empty
            , network = Testnet
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
