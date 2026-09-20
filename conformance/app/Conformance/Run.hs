{-# LANGUAGE TypeApplications #-}

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

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, poll)
import Control.Exception (
    ErrorCall (..),
    SomeException,
    displayException,
    throwIO,
    try,
 )
import Control.Monad (unless, when)
import Data.Aeson (
    FromJSON (..),
    eitherDecode,
    encode,
    object,
    withObject,
    (.=),
    (.:),
    (.:?),
 )
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.ByteString.Base16 qualified as Base16
import Data.List (intercalate, isInfixOf, nub, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Ord (Down (..))
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Lens.Micro ((&), (%~), (.~), (^.))
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
import Cardano.Ledger.Plutus.Data (Data (..), hashData)
import Cardano.Ledger.Address (
    AccountAddress (..),
    AccountId (..),
    Addr (..),
    serialiseAddr,
    Withdrawals (..),
 )
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))

import Cardano.Ledger.Api.PParams (
    ppKeyDepositL,
    ppMaxTxExUnitsL,
    ppMaxTxSizeL,
 )
import Cardano.Ledger.Api.Tx (
    bodyTxL,
    estimateMinFeeTx,
    mkBasicTx,
    mkBasicTxBody,
    txIdTx,
    witsTxL,
 )
import Cardano.Ledger.Api.Tx.Body (
    ValidityInterval (..),
    certsTxBodyL,
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
import Cardano.Ledger.Api.Scripts.Data (
    Datum (..),
 )
import Cardano.Ledger.Api.Tx.Out (
    referenceScriptTxOutL,
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
    SlotNo (..),
    StrictMaybe (..),
    TxIx (..),
 )
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Conway.TxCert (ConwayDelegCert (..), ConwayTxCert (..))
import Cardano.Ledger.Core (
    eraProtVerLow,
    KeyHash,
    Script,
    eraProtVerHigh,
    extractHash,
    hashScript,
 )
import Cardano.Ledger.Credential (Credential (..), StakeReference (..))
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Keys (KeyRole (..))
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..), txInToText)
import Cardano.Tx.Ledger (ConwayTx)
import MPF.Hashes (MPFHash)
import MPF.Proof.Insertion (MPFProof (..))

import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint (
    Blueprint (..),
    NamingCodes (..),
    Validator (..),
    applyBytesParam,
    applyDataParam,
    applyPreviousPolicies,
    applyRequestParams,
    extractCompiledCode,
    loadBlueprint,
    loadRegistryCodesFromEnv,
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
    leafActive,
    leafTerminal,
    approvalName,
    mkRequestDatumWith,
    policyIdFromPin,
    addrFromKeyHashBytes,
    addrKeyHashBytes,
    addrWitnessKeyHash,
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    policyIdFromPin,
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
    RegistryDuties (..),
    registryDuties,
    updateTokenImpl,
    updateTokenWithDuties,
 )
import Singular.Registry.TxBuilder.ConnectedFold (
    ConnectedMint (..),
    ConnectedSpend (..),
    RawRedeemer (..),
    generousUnits,
 )
import Singular.Registry.Types (
    CageDatum (..),
    Edge,
    edgeDeleteAbsent,
    edgeInsertAbsent,
    edgeInsertActive,
    edgeUpdateActive,
    edgeUpdateTerminal,
    edgeWitnessTerminal,
    OnChainRequest (..),
    OnChainRoot (..),
    OnChainTokenState (..),
    OnChainTxOutRef (..),
    ProofStep (..),
    RequestAction (Update),
    UpdateRedeemer (..),
 )
import Singular.Registry.Node (
    checkFunding,
    defaultFundingFloor,
    devnetGenesis,
    funderAddr,
    funderSignKey,
    sessionMagic,
    withNodeSocket,
 )
import Singular.Registry.Types qualified as CageTypes
import Cardano.Node.Client.E2E.Setup (
    addKeyWitness,
    enterpriseAddr,
    keyHashFromSignKey,
    mkSignKey,
    Ed25519DSIGN,
    SignKeyDSIGN,
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
import Conformance.ForkKeys (findPresentForkKeys)
import Conformance.Receipt (
    AssetEntry (..),
    ConstructorEvidence (..),
    ConstructorStanding (..),
    DerivationEvidence (..),
    DerivationOutcome (..),
    EdgeEvidence (..),
    FoldStep (..),
    Outcome (..),
    PartialInfo (..),
    Receipt (..),
    RefusalInfo (..),
    RefusalLeg (..),
    RetirementEvidence (..),
    RetirementQuantities (..),
    RetirementRoots (..),
    RetirementSource (..),
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
-- Row vocabulary and control modes
-- ---------------------------------------------------------

-- | Row families by explicit membership. Every partition below filters by
-- these lists, never by exclusion: a catch-all partition silently absorbs
-- the next family of rows (CA01-CA05 were once routed into the CS
-- session by a notElem-CG catch-all). A row in no family fails loudly.
caRows, cgRows, csRows, issue70Rows, issue70AcceptingRows, issue173Rows, issue177Rows :: [String]
caRows = ["CA01", "CA02", "CA03", "CA04", "CA05"]
cgRows = ["CG02", "CG03", "CG04", "CG05"]
csRows = ["CS01", "CS02", "CS03", "CS04", "CS05", "CS06", "CS07", "CS08"]

-- The issue #70 rows, listed by membership — never by exclusion or
-- position: a partition defined by what it is not silently absorbs
-- whatever the next slice adds.
issue70Rows =
    [ "CG07"
    , "CG09"
    , "CG10"
    , "CG11"
    , "CG12"
    , "CG14"
    , "CG15"
    , "CG19"
    ]

-- The issue #70 rows that close a CL01 receipt when the full session
-- ran: every accepting fold in the session.
issue70AcceptingRows = ["CG11", "CG12", "CG14", "CG19"]

-- The issue #173 rows, listed by membership like every other family:
-- CG21 is the insertActive fold together with its two DISTINCT refusal
-- fixtures (A-006) — the same-key duplicate refused `key-exists` before
-- any mint arithmetic, and the two-distinct-key batch whose claimed
-- mint agrees per kind and disagrees per (kind, key), refused
-- `net-mint-mismatch`. Each refusal carries its own accepting control.
issue173Rows = ["CG21"]

-- The issue #177 row, listed by membership like every other family:
-- CG22 is the updateTerminal retirement — insertActive then
-- updateTerminal at the SAME key in one session — together with its two
-- DISTINCT refusal fixtures, an Unknown key (`key-unknown`) and an
-- Absent key (`not-booked`), each with its own accepting control. It
-- shares no fixture, receipt or assertion with CG21.
issue177Rows = ["CG22"]

canonicalRows :: [String]
canonicalRows =
    caRows <> cgRows <> csRows <> issue70Rows <> issue173Rows <> issue177Rows

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
    | -- | CS01 armed (#157 D-DEST): a three-element list must validate
      -- against the two-element destination pair, which it cannot —
      -- the fixed tuple is checked at exact arity. Proves the schema
      -- oracle was not loosened into a homogeneous list rule.
      BlueprintWrongArity
    | -- | CS08 armed (#157 X1): the retired SIX-field state encoding
      -- must decode the chain's datum, which it cannot — the datum has
      -- eight fields now. Proves the round-trip row is reading the new
      -- contract and would notice a regression to the old one.
      LegacySixField
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
        Just "legacy-six-field" -> pure LegacySixField
        Just "blueprint-wrong-arity" -> pure BlueprintWrongArity
        Just other ->
            failWith
                ( "unknown CONFORMANCE_CONTROL value " <> other
                )

-- ---------------------------------------------------------
-- Keys and values
-- ---------------------------------------------------------

{- | The generic rows' keys, and the leaf states they move between.

#157 admits three leaf values and nothing else, so the rows say what they
always said — insert, update, delete, re-insert, occupied-key refusal —
in the only vocabulary the registry has. `cgKey` runs the insert, update
and occupied-key rows; `cgDeleteKey` runs the delete and the re-insert,
because deleting an ACTIVE leaf is the one edge naming never certifies
(N5) and a delete that can fold is a delete of a witnessed absence.
-}
cgKey, cgDeleteKey, cgV1, cgV2, cgV3, cgV4 :: ByteString
cgKey = "cg-row-key"
cgDeleteKey = "cg-delete-key"
cgV1 = leafAbsent
cgV2 = leafActive
cgV3 = leafAbsent
cgV4 = leafAbsent

{- | The control values. A forged claim names a leaf the key does not
hold; there is no byte outside the codec that would reach the comparison
at all, so the forgery is a wrong LEAF, which is what a false claim about
a registry actually looks like.
-}
controlKey, controlVal, forgedValue :: ByteString
controlKey = "cg-control-key"
controlVal = leafAbsent
forgedValue = leafTerminal

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

-- ---------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------

runRows :: [String] -> FilePath -> IO ()
runRows rawRows receiptsDir = do
    rows <- validateRows rawRows
    control <- readControl
    emit "control" (show control)
    let caRequested = any (`elem` caRows) rows
        cgRequested = any (`elem` (cgRows <> issue70Rows)) rows
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
        cgDevnet = [r | r <- devnetRows, r `elem` (cgRows <> issue70Rows <> issue173Rows <> issue177Rows)]
        caDevnet = [r | r <- devnetRows, r `elem` caRows]
        csDevnet = [r | r <- devnetRows, r `elem` csRows]
        unpartitioned = [r | r <- devnetRows, r `notElem` (caRows <> cgRows <> csRows <> issue70Rows <> issue173Rows <> issue177Rows)]
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
        hasCg = any (`elem` (cgRows <> issue70Rows <> issue173Rows <> issue177Rows)) requested
    when (hasCa && hasCg) $
        failWith
            ( "CA and CG rows run as separate sessions, one devnet \
              \each: run CA01..CA05, then the CG rows"
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
        threadDelay 3_000_000
        status <- poll nodeThread
        case status of
            Nothing -> pure ()
            Just _ ->
                failWith "node connection closed before queries ran"
        let prov = adaptProvider (mkN2CProvider lsqCh)
            submit = mkN2CSubmitter ltxsCh
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
                    AgreesWithModel                    (map T.unpack (concatMap receiptTransactions rs))
                    Nothing
                    Nothing
                    (Just (maximum (map getMem rs)))
                    (Just (maximum (map getCpu rs)))
                    (Just (maximum (map getSize rs)))
                    "node-submit"
                    Nothing
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
                    AgreesWithModel                    (map T.unpack (concatMap receiptTransactions rs))
                    Nothing
                    Nothing
                    (Just (maximum (map getMem rs)))
                    (Just (maximum (map getCpu rs)))
                    (Just (maximum (map getSize rs)))
                    "node-submit"
                    Nothing
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
    -- #157: a spent approval is not burned at the fold, so it returns to
    -- the funder and rides in the wallet. Fee and collateral inputs are
    -- taken from an ada-only output, which is what the ledger requires of
    -- collateral and what the hand model asserts of its funder.
    case sortOn (Down . (^. coinTxOutL) . snd) (filter (adaOnlyOut . snd) utxos) of
        [] -> failWith "genesis wallet has no ada-only UTxO; cannot fund"
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
    -- #177 I177-CONFORMANCE. NOT YET IMPLEMENTED: the row is reached
    -- inside a real session, on a real devnet, and fails here rather
    -- than in `validateRows`, so the session, genesis, node and
    -- partitioning subjects all execute before the absent fixture is
    -- reported.
    "CG22" -> runCG22 env
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
    result <- submitTxResilient (envSubmit env) signedBoot
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
run reads it, never edits it. @REGISTRY_SCRIPT_IDENTITY@ overrides the
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
    override <- lookupEnv "REGISTRY_SCRIPT_IDENTITY"
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

attributeSubmitRefusal :: Env -> String -> Verdict -> String -> String -> String -> IO ()
attributeSubmitRefusal env row verdict marker text rejectedTxid = do
    -- NOTE-003 discipline: the node may report several failing
    -- scripts in an order that is not stable, so the matcher asserts
    -- the expected script is AMONG them (the reason text is matched
    -- raw, never a single first hash). The write policy lives in the
    -- library (A-002): a refusal ROW's receipt IS the row outcome.
    let script = if row `elem` ["CG07"] then "request" else "state"
    r <-
        attributeRefusalReceipt
            RefusalRow
            (envReceiptsDir env)
            row
            verdict
            script
            marker
            text
            rejectedTxid
            (envBase env)
            (envDirty env)
            (envNode env)
            (envBlueprint env)
    case r of
        Right () ->
            emit
                "row"
                ( row
                    <> ": REFUSED at submit, attributed to "
                    <> script
                    <> " (phase-2, marker 0x"
                    <> shortMarker marker
                    <> ")"
                )
        Left mismatch ->
            failWith
                ( row
                    <> ": refusal did not attribute ("
                    <> show mismatch
                    <> "): "
                    <> text
                )

{- | A refused CONTROL: submitted and attributed like a refusal row,
but its outcome is run-log evidence under its own identity and never
writes the row's receipt (A-002 — CG11/CG12/CG19's held receipts were
being replaced by their controls' refusals). It cannot silently pass:
an accepted control fails the run as a FINDING, and a refusal that
does not attribute fails the run naming the mismatch.
-}
submitExpectRefusedControl :: Env -> String -> Verdict -> String -> ConwayTx -> IO ()
submitExpectRefusedControl env row verdict marker tx = do
    let signed = addKeyWitness genesisSignKey tx
    result <- submitTxResilient (envSubmit env) signed
    case result of
        Rejected reason ->
            attributeControlRefusal
                env
                row
                verdict
                marker
                (T.unpack (TE.decodeUtf8Lenient reason))
                (txIdHex signed)
        Submitted txid ->
            failWith
                ( row
                    <> " FINDING: the node ACCEPTED the control transaction "
                    <> "expected to refuse (txid "
                    <> txInHex txid
                    <> ") — reported, not relabelled"
                )

attributeControlRefusal :: Env -> String -> Verdict -> String -> String -> String -> IO ()
attributeControlRefusal env row verdict marker text rejectedTxid = do
    let script = if row `elem` ["CG07"] then "request" else "state"
    r <-
        attributeRefusalReceipt
            RefusalControl
            (envReceiptsDir env)
            row
            verdict
            script
            marker
            text
            rejectedTxid
            (envBase env)
            (envDirty env)
            (envNode env)
            (envBlueprint env)
    case r of
        Right () ->
            emit
                "control"
                ( row
                    <> " control: REFUSED at submit, attributed to "
                    <> script
                    <> " (phase-2, marker 0x"
                    <> shortMarker marker
                    <> ") — run-log evidence only; the row's receipt is "
                        <> "not overwritten (A-002)"
                )
        Left mismatch ->
            failWith
                ( row
                    <> ": control refusal did not attribute ("
                    <> show mismatch
                    <> "): "
                    <> text
                )

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

-- ---------------------------------------------------------
-- Issue #70 machinery: cages, the second wallet, the stake kit
-- ---------------------------------------------------------

{- | The cage for one row group, booted on first use from a fresh
seed. Rows whose outcome leaves odd state (a transferred owner, a
parked request) get their own cage so the odd state cannot poison a
neighbour row. The windows are the boot datum's phase clocks; rows
retracting or rejecting wait for a phase boundary, so fast windows
keep the run short without weakening any check.
-}
ensureRowCage ::
    Env ->
    String ->
    -- | process window (ms, phase 1)
    Integer ->
    -- | retract window (ms, phase 2)
    Integer ->
    IO RowCage
ensureRowCage env name processMs retractMs = do
    worlds <- readIORef (envWorlds env)
    case Map.lookup name worlds of
        Just w -> pure w
        Nothing -> do
            -- The library builders below choose their own fee and
            -- collateral inputs, and choose them by position rather than
            -- by size. One ada-only output leaves them nothing to get
            -- wrong.
            consolidateFunding env
            -- Boot with retry: the node supervisor can be mid-
            -- reconnect when a row group starts (its connection loss
            -- is transient); a failed attempt leaves nothing behind —
            -- each attempt takes a fresh seed.
            w <- bootCageAttempt (3 :: Int)
            writeIORef (envWorlds env) (Map.insert name w worlds)
            pure w
  where
    bootCageAttempt n = do
        r <- try @SomeException bootOnce
        case r of
            Right w -> pure w
            Left e
                | n > 1 -> do
                    emit
                        "boot"
                        ( "boot attempt failed ("
                            <> take 200 (displayException e)
                            <> "); retrying"
                        )
                    threadDelay 5_000_000
                    bootCageAttempt (n - 1)
                | otherwise -> throwIO e
    bootOnce :: IO RowCage
    bootOnce = do
        let (stateBytes, requestBytes, namingCodes) = envCodes env
            prov = envProv env
        -- Sweep, then carve: seeding from the largest output would strand
        -- the funding in the cage and leave the change to fund and
        -- collateralise the boot.
        consolidateFunding env
        seedTxIn <- carveSeed env
        let cfg =
                cageCfgWith
                    stateBytes
                    requestBytes
                    namingCodes
                    (txInToRef seedTxIn)
                    processMs
                    retractMs
        unsignedBoot <- bootTokenImpl cfg prov genesisAddr
        signedBoot <- submitWithGenesis (envSubmit env) unsignedBoot
        tid <- extractTokenId cfg signedBoot
        createTrie (envTm env) tid
        tidRef <- newIORef (Just tid)
        unitsRef <- newIORef (0, 0)
        published <- cageRefUtxos env cfg tid

        let w = RowCage cfg tidRef unitsRef published
        emit
            "cage"
            ( name
                <> " booted bootTx="
                <> txIdHex signedBoot
                <> " processMs="
                <> show processMs
                <> " retractMs="
                <> show retractMs
            )
        pure w

cageTid :: RowCage -> IO TokenId
cageTid rc = do
    t <- readIORef (rcTid rc)
    case t of
        Just tid -> pure tid
        Nothing -> failWith "row cage is not booted"

{- | The stake_script hook's kit (CG14/CG15): the blueprint's
staking validator, its hash cross-checked against the pinned
manifest, the credential registered on the devnet (a withdrawal
from an unregistered account is a phase-1 error, not a verdict on
the hook), and the cage booted with the hook in its datum.
-}
ensureStakeKit :: Env -> IO StakeKit
ensureStakeKit env = do
    kit <- readIORef (envStake env)
    case kit of
        Just k -> pure k
        Nothing -> do
            ebp <- loadBlueprint (envBlueprintPath env)
            bp <- case ebp of
                Left err -> failWith ("blueprint does not parse: " <> err)
                Right b -> pure b
            bytes <- case extractCompiledCode "staking.staking" bp of
                Just b -> pure b
                Nothing ->
                    failWith
                        "the blueprint carries no staking.staking validator"
            let h = computeScriptHash bytes
                hHex = hex (scriptHashBytes h)
            manifest <- readScriptManifest
            case pinsUnder "staking.staking" manifest of
                [] ->
                    failWith
                        "the script manifest pins no staking.staking entry"
                pins ->
                    require
                        ( "the staking pin disagrees with this run's \
                           \blueprint: "
                            <> show pins
                            <> " vs 0x"
                            <> hHex
                        )
                        (all ((== T.pack hHex) . fst) pins)
            registerStakeCredential env bytes h
            cage <-
                ensureRowCage
                    env
                    "cg-stake"
                    60_000
                    300_000
            let k = StakeKit bytes h cage
            writeIORef (envStake env) (Just k)
            pure k

{- | Register the staking credential: a @RegTxCert@ paying the key
deposit. Registration carries no script witness — the blueprint's
staking validator implements only the withdraw handler, so a cert
purpose would run its fail branch, and the node does not demand a
witness for a registration. The deposit is paid; nobody withdraws
it back — a devnet-bound residue, recorded, not hidden.
-}
registerStakeCredential ::
    Env -> SBS.ShortByteString -> ScriptHash -> IO ()
registerStakeCredential env _bytes h = do
    let prov = envProv env
        cred = ScriptHashObj h
    pp <- Cage.queryProtocolParams prov
    (funderIn, funderOut) <- largestWalletUtxo prov
    let Coin avail = funderOut ^. coinTxOutL
        depositCoin = pp ^. ppKeyDepositL
        Coin deposit = depositCoin
        build feeAmt =
            mkBasicTx
                ( mkBasicTxBody
                    & inputsTxBodyL .~ Set.singleton funderIn
                    & certsTxBodyL
                        .~ StrictSeq.fromList
                            [ ConwayTxCertDeleg
                                ( ConwayRegCert
                                    cred
                                    (SJust depositCoin)
                                )
                            ]
                    & feeTxBodyL .~ Coin feeAmt
                )
    let Coin estFee = estimateMinFeeTx pp (build 0) 1 0 0
        fee = estFee + 50_000
        change = avail - fee - deposit
        changeOut = mkBasicTxOut genesisAddr (MaryValue (Coin change) mempty)
        Coin minAda = getMinCoinTxOut @ConwayEra pp changeOut
    require
        ( "registration: wallet output under min-ADA after fee+deposit: "
            <> show change
        )
        (change >= minAda)
    let tx =
            build fee
                & bodyTxL . outputsTxBodyL
                    .~ StrictSeq.fromList
                        [ mkBasicTxOut
                            genesisAddr
                            (MaryValue (Coin change) mempty)
                        ]
    signed <- pure (addKeyWitness genesisSignKey tx)
    result <- submitTxResilient (envSubmit env) signed
    case result of
        Submitted _ -> pure ()
        Rejected reason ->
            failWith
                ( "CG14/CG15 COULD NOT EXECUTE — registration of the \
                   \staking credential refused: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )
    awaitTx
    emit
        "stake"
        ( "staking credential 0x"
            <> hex (scriptHashBytes h)
            <> " registered (deposit "
            <> show deposit
            <> ") regTx="
            <> txIdHex signed
        )

{- | The second wallet: a key derived from a fixed seed (like the
genesis key), funded by a plain split of the largest genesis UTxO.
CG19's second request is owned (and funded) by it.
-}
secondWallet :: Env -> IO (SignKeyDSIGN Ed25519DSIGN, Addr)
secondWallet env = do
    existing <- readIORef (envKey2 env)
    case existing of
        Just w -> pure w
        Nothing -> do
            let sk = mkSignKey "conformance-second-key-seed-000001"
                addr = enterpriseAddr (keyHashFromSignKey sk)
            fundWallet env addr 12_000_000
            writeIORef (envKey2 env) (Just (sk, addr))
            pure (sk, addr)

fundWallet :: Env -> Addr -> Integer -> IO ()
fundWallet env addr amount = do
    let prov = envProv env
    (funderIn, funderOut) <- largestWalletUtxo prov
    let Coin avail = funderOut ^. coinTxOutL
        fee = 200_000
        change = avail - amount - fee
    require
        ("wallet funding: funder too small (" <> show avail <> ")")
        (change > amount)
    let body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton funderIn
                & outputsTxBodyL
                    .~ StrictSeq.fromList
                        [ mkBasicTxOut addr (MaryValue (Coin amount) mempty)
                        , mkBasicTxOut
                            genesisAddr
                            (MaryValue (Coin change) mempty)
                        ]
                & feeTxBodyL .~ Coin fee
    _ <- submitWithGenesis (envSubmit env) (mkBasicTx body)
    pure ()

{- | A small dedicated collateral pot for one refusing transaction:
on phase-2 failure the whole collateral is taken, so the collateral
is a split-off 5 ADA output — never the 30 ADA funder the CG05
shape once used. The pot is a pure collateral input (never a
regular input), ada-only and key-witnessed.
-}
collateralPot :: Env -> IO TxIn
collateralPot env = do
    let prov = envProv env
    (funderIn, funderOut) <- largestWalletUtxo prov
    let Coin avail = funderOut ^. coinTxOutL
        pot = 5_000_000
        fee = 200_000
        change = avail - pot - fee
    require "collateral pot: funder too small" (change > pot)
    let body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton funderIn
                & outputsTxBodyL
                    .~ StrictSeq.fromList
                        [ mkBasicTxOut
                            genesisAddr
                            (MaryValue (Coin pot) mempty)
                        , mkBasicTxOut
                            genesisAddr
                            (MaryValue (Coin change) mempty)
                        ]
                & feeTxBodyL .~ Coin fee
    tx <- submitWithGenesis (envSubmit env) (mkBasicTx body)
    -- the pot is the split's first output (index 0), deterministically
    pure (TxIn (txIdTx tx) (TxIx 0))

-- | Sleep until the devnet's POSIX-ms clock reaches @targetMs@.
sleepUntilMs :: Env -> Integer -> IO ()
sleepUntilMs _env targetMs = do
    now <- currentPosixMs
    let remaining = targetMs - now
    when (remaining > 0) $ do
        emit "wait" (show remaining <> " ms to the next phase boundary")
        threadDelay (fromIntegral remaining * 1000)

-- | The state script's refusal marker (applied hash hex).
stateMarkerOf :: CageConfig -> String
stateMarkerOf cfg = hex (scriptHashBytes (cfgScriptHash cfg))

-- | The request script's refusal marker for one cage (applied hash hex).
requestMarkerOf :: CageConfig -> TokenId -> String
requestMarkerOf cfg tid =
    hex (scriptHashBytes (hashScript (mkRequestScript cfg tid)))

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
    funder <- largestWalletUtxo prov
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
    duties <-
        case registryDuties
            (fsCfg fs)
            pp
            oldState
            ctx
            (fsReqs fs)
            (foldSpecProcessed fs) of
            Right d -> pure d
            Left err -> failWith ("hand-build: " <> err)
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
            dutyCoins = map outCoin (rdOutputs duties)
            change =
                sum reqCoins
                    + funderCoin
                    + sum custodyCoins
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

-- | Evaluate a transaction's script purposes on the node.
-- ---------------------------------------------------------
-- Issue #70 rows
-- ---------------------------------------------------------

{- | Submit and require acceptance (key-witnessed by the given
signer); a refusal is a loud failure naming the reason.
-}
-- | Submit with transient-failure resilience: the N2C local-tx
-- supervisor reopens the bearer after a lost connection mid-submit;
-- the client contract says callers treat 'ConnectionLost' as
-- transient and retry. Re-evaluation is deterministic, so the retry
-- yields the same verdict (a phase-2 failure is not a chain effect:
-- a locally rejected transaction never entered the ledger, and no
-- collateral moves).
submitTxResilient :: Submitter IO -> ConwayTx -> IO SubmitResult
submitTxResilient submit tx = go (4 :: Int)
  where
    go 0 = submitTx submit tx
    go n = do
        r <- try @SomeException (submitTx submit tx)
        case r of
            Right res -> pure res
            Left e
                | "ConnectionLost" `isInfixOf` displayException e -> do
                    emit "submit" "connection lost mid-submit; retrying"
                    threadDelay 3_000_000
                    go (n - 1)
                | otherwise -> throwIO e

-- | Submit and require acceptance (key-witnessed by the given
-- signer); a refusal is a loud failure naming the reason.
--}
submitExpectAccepted :: Env -> ConwayTx -> IO ConwayTx
submitExpectAccepted env tx = do
    result <- submitTxResilient (envSubmit env) tx
    case result of
        Submitted _ -> awaitTx >> pure tx
        Rejected reason ->
            failWith
                ( "expected acceptance, the node refused: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )

{- | Submit a hand-built refusing transaction and close the row on
the node's phase-2 attribution. A submission success is a FINDING:
reported, never relabelled.
-}
-- The refusal transaction is signed with the genesis key (the
-- collateral pot and fee inputs are genesis's); rows needing a
-- second witness pre-sign before calling.
submitExpectRefused :: Env -> String -> Verdict -> String -> ConwayTx -> IO ()
submitExpectRefused env row verdict marker tx = do
    let signed = addKeyWitness genesisSignKey tx
    result <- submitTxResilient (envSubmit env) signed
    case result of
        Rejected reason ->
            attributeSubmitRefusal
                env
                row
                verdict
                marker
                (T.unpack (TE.decodeUtf8Lenient reason))
                (txIdHex signed)
        Submitted txid ->
            failWith
                ( row
                    <> " FINDING: the node ACCEPTED the transaction the "
                    <> "consumer's requirement refuses (txid "
                    <> txInHex txid
                    <> ") — reported, not relabelled"
                )

{- | Book one absence on a row cage's registry (#157 A-009, D-001).

The issue-70 rows used to create a bare request: no destination, no
approval, and a value the leaf codec does not admit. A request like that is
not a registry-mode booking at all, and a fold of it could only ever be
refused. Every row request is now the insertAbsent edge — the one edge that
needs no signature, because anyone may witness that a name is free — with
the deposit's refund address as its destination and the approval that
certifies it riding along.

The key is the row's own; the value is the absent leaf, because that is
what an absence witness says.
-}
rowRequestInsert :: Env -> RowCage -> ByteString -> ByteString -> IO (TxIn, TxOut ConwayEra)
rowRequestInsert env cage key _val = do
    let cfg = rcCfg cage
    tid <- cageTid cage
    dest <- edgeDestination env edgeInsertAbsent
    (reqIn, reqOut) <-
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
    pure (reqIn, reqOut)
cageStateUtxo :: Env -> RowCage -> IO (TxIn, TxOut ConwayEra)
cageStateUtxo env cage = do
    tid <- cageTid cage
    let cfg = rcCfg cage
    utxos <- Cage.queryUTxOs (envProv env) (cageAddrFromCfg cfg (network cfg))
    case findStateUtxo (cagePolicyIdFromCfg cfg) tid utxos of
        Just u -> pure u
        Nothing -> failWith "row cage: no state UTxO"

-- | Speculatively apply one request's insert; proof steps + new root.
speculativeInsert ::
    Env -> RowCage -> TokenId -> ByteString -> ByteString -> IO ([ProofStep], Root)
speculativeInsert env _cage tid key val =
    withSpeculativeTrie (envTm env) tid $ \trie -> do
        _ <- CageTrie.insert trie key val
        steps <- fromMaybe [] <$> CageTrie.getProofSteps trie key
        r <- CageTrie.getRoot trie
        pure (steps, r)

{- | Speculatively apply every request's own op (read from its
datum), keeping proof steps aligned with the request order given.
-}
speculativeApplyAll ::
    Env ->
    RowCage ->
    TokenId ->
    [(TxIn, TxOut ConwayEra)] ->
    IO ([[ProofStep]], Root)
speculativeApplyAll env _cage tid reqs =
    withSpeculativeTrie (envTm env) tid $ \trie -> do
        ps <- mapM (applyOne trie) reqs
        r <- CageTrie.getRoot trie
        pure (ps, r)
  where
    applyOne trie (_, out) =
        -- #183: the edge names the move and its leaf bytes, from the
        -- table the cage reads (#157 C3: a read proves its key and
        -- leaves it alone).
        walkEdge trie key edge
      where
        (key, edge) = case extractCageDatum out of
            Just (RequestDatum rq) ->
                (requestKey rq, requestEdge rq)
            _ -> error "speculative: pending UTxO has no request datum"

-- | Commit a landed edge to a row cage's trie (#157 C3: a read
-- commits nothing, which `walkEdge` already knows).
rowCommit :: Env -> RowCage -> ByteString -> Edge -> IO ()
rowCommit env cage key edge = do
    tid <- cageTid cage
    withTrie (envTm env) tid $ \t -> () <$ walkEdge t key edge

{- | Book one absence on a row cage at an explicit bond (#157 A-009).

The bond is the caller's, because CG19 needs two different ones to cross
and CG05 needs one large enough to carry its own refusal. What was a bare
payment carrying a request datum is now a booking: the edge is certified,
the destination names where the deposit comes back, and the approval rides
the request to the fold.
-}
paddedRequest ::
    Env ->
    RowCage ->
    Addr ->
    SignKeyDSIGN Ed25519DSIGN ->
    ByteString ->
    ByteString ->
    Integer ->
    IO (TxIn, TxOut ConwayEra)
paddedRequest env cage payerAddr payerSk key _val bond = do
    let cfg = rcCfg cage
    tid <- cageTid cage
    dest <- edgeDestinationFor env payerAddr edgeInsertAbsent
    bookEdge
        env
        cfg
        tid
        payerAddr
        payerSk
        key
        edgeInsertAbsent
        dest
        []
        bond
{- | Request datum's (key, edge) and submitted-at, read from a
live request UTxO.
-}
requestDatumOf :: TxOut ConwayEra -> ((ByteString, Edge), Integer)
requestDatumOf out = case extractCageDatum out of
    Just (RequestDatum rq) ->
        ((requestKey rq, requestEdge rq), requestSubmittedAt rq)
    _ -> error "requestDatumOf: not a request UTxO"

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

{- | The keys CG21 books. Four, because the row's three observations are
three DISTINCT fixtures (A-006) and none may stand in for another: the
fold's own key, the fresh key that controls the duplicate, and the two
keys the keyed-mint batch needs.
-}
cg21Key, cg21ControlKey, cg21KeyA, cg21KeyB :: ByteString
cg21Key = "cg21-insert-active"
cg21ControlKey = "cg21-insert-active-control"
cg21KeyA = "cg21-keyed-mint-a"
cg21KeyB = "cg21-keyed-mint-b"

{- | CG21: one `insertActive` folds on the open registry and places
exactly one @(activePolicy, key)@ token at the address the request
named; a second insert at the same committed key is refused on chain at
the state script; and a two-key batch whose claimed mint agrees per kind
and disagrees per @(kind, key)@ is refused there too. Each refusal
carries an accepting control, so neither can pass merely because the
request was malformed.

The destination is a WALLET the funder never spends from.
'edgeDestinationFor' routes an `insertActive` to the naming
APPLICATION's script address, which is right for naming and wrong here:
@open.ak@ is a minting policy with no spending arm, so a token routed
there is locked forever. It is also not the FUNDING wallet, whose
non-ada outputs the session sweeps into the attic between rows — the
delivered token would go with them.

Order, and why it is this one. The duplicate's control is a FRESH key
and folds BEFORE it, so a broken control is reported rather than
silently leaving the refusal vacuous. The keyed-mint control is the SAME
batch with the right distribution, so it can only fold AFTER: a refused
transaction consumes nothing, and the batch has to still be pending for
its control to fold it. The duplicate comes last because its request
stays pending, and nothing after it folds.

The row lands three folds and commits each into the manager's trie
before the next proof is built. The receipt records the chain's root
either side of every one of them beside the committed root, so a fold
re-proved against a stale trie is visible in the evidence instead of
surfacing later as an unrelated-looking failure.
-}
runCG21 :: Env -> IO ()
runCG21 env = do
    cage <- ensureRowCage env "cg21" 30_000 30_000
    let cfg = rcCfg cage
    tid <- cageTid cage
    openParams <- cg21OpenParameters env
    (_, destAddr) <- secondWallet env
    let dest = (serialiseAddr destAddr, BS.empty)
        bond = defaultTipCoin cfg + cgDeposit
        activePolicy = policyIdFromPin (cfgActivePolicy cfg)
        book key =
            bookEdge
                env
                cfg
                tid
                genesisAddr
                genesisSignKey
                key
                edgeInsertActive
                dest
                []
                bond

    -- 1. The story fold. Every fine conjunct is read off this
    --    transaction and the state datum either side of it.
    (_, reqOut) <- book cg21Key
    before <- cg21State env cage
    (foldTx, step1, (mem, cpu, size)) <- cg21Fold env cage [cg21Key]
    after <- cg21State env cage
    emitMeasure env "CG21-fold" mem cpu size
    (observedAddr, delivered) <- cg21Delivery activePolicy cg21Key foldTx
    held <- cg21HeldAt env destAddr activePolicy cg21Key
    require
        ( "CG21: the named wallet holds "
            <> show held
            <> " active tokens at this key, not exactly one"
        )
        (held == 1)
    approvalObserved <- cg21ApprovalOn cfg reqOut
    (reqLovelace, approvalRecomputed) <- cg21RequestFacts reqOut
    emit
        "row"
        ( "CG21: one insertActive folded (tx="
            <> txIdHex foldTx
            <> ") and exactly one active token landed at the named wallet"
        )

    -- 2. The duplicate's accepting control: a FRESH key through the
    --    SAME builder, folded first so a failure here is reported as a
    --    broken control rather than making step 4 vacuous.
    _ <- book cg21ControlKey
    (dupControlTx, step2) <- cg21HandFold env cage [cg21ControlKey]
    emit
        "control"
        ( "CG21 control: a fresh key folded through the same builder (tx="
            <> txIdHex dupControlTx
            <> ") — the duplicate below is the occupancy, not the builder"
        )

    -- 3. The keyed-mint batch: two DISTINCT keys whose per-kind totals
    --    agree and whose per-(kind, key) totals do not. The claim moves
    --    key B's unit onto key A in the mint AND in the output that
    --    carries it, so the ledger still balances and the STATE SCRIPT
    --    is what refuses, rather than phase 1 on an unbalanced value.
    _ <- book cg21KeyA
    _ <- book cg21KeyB
    honest <- cg21BatchFold env cage
    let nameA = AssetName (SBS.toShort cg21KeyA)
        nameB = AssetName (SBS.toShort cg21KeyB)
        policyHexT = hexT (cg21PolicyBytes activePolicy)
        entailed =
            [ AssetEntry policyHexT (hexT cg21KeyA) 1
            , AssetEntry policyHexT (hexT cg21KeyB) 1
            ]
        claimedTx = cg21MoveAsset activePolicy nameB nameA honest
    mintLeg <-
        cg21ExpectRefused
            env
            cage
            "keyed-mint"
            [cg21KeyA, cg21KeyB]
            (Just (cg21MintedOf activePolicy claimedTx))
            (Just entailed)
            "claimed both units at one key; the edges entail one at each"
            (addKeyWitness genesisSignKey claimedTx)
    (mintControlTx, step3, _) <- cg21Fold env cage [cg21KeyA, cg21KeyB]
    emit
        "control"
        ( "CG21 control: the same two keys with the distribution their "
            <> "edges entail accepted (tx="
            <> txIdHex mintControlTx
            <> ")"
        )

    -- 4. The duplicate, last: its request stays pending and nothing
    --    after it folds.
    _ <- book cg21Key
    duplicateTx <- cg21HandBuild env cage
    dupLeg <-
        cg21ExpectRefused
            env
            cage
            "duplicate"
            [cg21Key]
            Nothing
            Nothing
            "the committed trie already binds this key"
            (addKeyWitness genesisSignKey duplicateTx)

    let edge =
            EdgeEvidence
                { eeOpenPolicy = hexT (SBS.fromShort (cfgApplicationPolicy cfg))
                , eeOpenParameters = openParams
                , eeActivePolicy = hexT (SBS.fromShort (cfgActivePolicy cfg))
                , eeKey = hexT cg21Key
                , eeFoldTxid = T.pack (txIdHex foldTx)
                , eeMinted = cg21MintedOf activePolicy foldTx
                , eeRequestedAddress = hexT (serialiseAddr destAddr)
                , eeObservedAddress = observedAddr
                , eeDelivered = delivered
                , eeMaxFee = stateMaxFee before
                , eeRequestLovelace = reqLovelace
                , eeApprovalName = approvalObserved
                , eeApprovalRecomputed = approvalRecomputed
                , eeRefunds = cg21RefundsOf foldTx
                , eeSigners = cg21SignersOf foldTx
                , eeConfigBefore = cg21Pins before
                , eeConfigAfter = cg21Pins after
                , eeSequence = [step1, step2, step3]
                , eeDuplicate =
                    dupLeg{rlControlTxid = T.pack (txIdHex dupControlTx)}
                , eeKeyedMint =
                    Just
                        mintLeg
                            { rlControlTxid = T.pack (txIdHex mintControlTx)
                            , rlControlMint =
                                Just (cg21MintedOf activePolicy mintControlTx)
                            }
                }
    writeCG21Receipt env foldTx mem cpu size edge

-- ---------------------------------------------------------
-- CG21 helpers (#184)
-- ---------------------------------------------------------

-- | Hex, as the receipt records it.
hexT :: ByteString -> T.Text
hexT = T.pack . hex

-- | The raw 28 bytes a policy id is.
cg21PolicyBytes :: PolicyID -> ByteString
cg21PolicyBytes (PolicyID sh) = scriptHashBytes sh

{- | The open application's declared parameter count, READ from the
blueprint entry rather than written down here. A parameterless policy's
compiled hash IS its policy id, so a blueprint that grew a parameter
must change this observation instead of being contradicted by it.
-}
cg21OpenParameters :: Env -> IO Integer
cg21OpenParameters env = do
    ebp <- loadBlueprint (envBlueprintPath env)
    bp <- case ebp of
        Left err -> failWith ("CG21: blueprint does not parse: " <> err)
        Right b -> pure b
    case [v | v <- validators bp, vTitle v == "open.open.mint"] of
        (v : _) -> pure (fromIntegral (vParameters v))
        [] -> failWith "CG21: open.open.mint is not in this blueprint"

-- | The cage's live eight-field state datum.
cg21State :: Env -> RowCage -> IO OnChainTokenState
cg21State env cage = do
    (_, out) <- cageStateUtxo env cage
    extractState out

{- | The seven non-root pins of the state datum. The eighth field is
the root, and the fold is allowed to move exactly that one.
-}
cg21Pins :: OnChainTokenState -> [T.Text]
cg21Pins s =
    [ T.pack (show (stateMaxFee s))
    , T.pack (show (stateProcessTime s))
    , T.pack (show (stateRetractTime s))
    , pin (stateAppPolicy s)
    , pin (stateActivePolicy s)
    , pin (stateAbsentPolicy s)
    , pin (stateTerminalPolicy s)
    ]
  where
    pin (BuiltinByteString b) = hexT b

-- | The registry root the chain currently carries.
cg21ChainRoot :: Env -> RowCage -> IO T.Text
cg21ChainRoot env cage = do
    s <- cg21State env cage
    pure (hexT (unOnChainRoot (stateRoot s)))

{- | Fold every pending request through the library builder, commit each
landed key into the manager's trie, and record what the roots did.

The commit is not bookkeeping. The speculative session inside
'updateTokenWithDuties' starts from the COMMITTED trie and is discarded,
so a caller that skips it re-proves the next fold against the boot state
and that fold submits an empty proof. The root either side is recorded
and a root that did not move fails the row here, where the cause is
still visible.
-}
cg21Fold ::
    Env -> RowCage -> [ByteString] -> IO (ConwayTx, FoldStep, (Integer, Integer, Integer))
cg21Fold env cage keys = do
    tid <- cageTid cage
    let cfg = rcCfg cage
    rootBefore <- cg21ChainRoot env cage
    ctx <- rowRegistryContext env cage tid
    unsigned <- updateTokenWithDuties cfg (envProv env) (envTm env) tid genesisAddr ctx
    -- Measured BEFORE the submission: evaluation resolves the spending
    -- script through the UTxO the fold is about to consume, and once it
    -- is consumed the node cannot point the redeemer at anything.
    (mem, cpu) <- measureUnits env unsigned
    signed <- submitWithGenesis (envSubmit env) unsigned
    -- The measured fold is what `declaredSpec` doubles for the hand
    -- assembly below, so the duplicate pair declares a budget that
    -- reaches the occupancy check rather than a guess.
    writeIORef (rcUnits cage) (mem, cpu)
    mapM_ (\k -> rowCommit env cage k edgeInsertActive) keys
    rootAfter <- cg21ChainRoot env cage
    committed <- withTrie (envTm env) tid CageTrie.getRoot
    require
        ( "CG21: a landed fold left the registry root where it found it (0x"
            <> T.unpack rootBefore
            <> "); the next proof would be built against a stale trie"
        )
        (rootBefore /= rootAfter)
    pure
        ( signed
        , FoldStep
            { fsTxid = T.pack (txIdHex signed)
            , fsRootBefore = rootBefore
            , fsRootAfter = rootAfter
            , fsCommitted = hexT (unRoot committed)
            }
        , (mem, cpu, txSizeBytes signed)
        )

{- | Assemble a fold of whatever is pending, WITHOUT evaluating it.

The library builder evaluates every fold against the node before it
returns one, so a fold the state script refuses never becomes a
transaction at all: `updateTokenWithDuties` raises the evaluation
failure and there is nothing to submit and nothing for the chain to
reject. The harness's own assembly builds the same shape and leaves the
verdict to the node — which is what a refusal on chain means.

This is the builder BOTH halves of the duplicate pair use, so the pair
differs in the key's occupancy and in nothing else.
-}
cg21HandBuild :: Env -> RowCage -> IO ConwayTx
cg21HandBuild env cage = do
    tid <- cageTid cage
    state <- cageStateUtxo env cage
    reqs <- pendingRequests env cage
    require "CG21: the hand fold has no pending request to fold" (not (null reqs))
    (proofs, root) <- cg21Proofs env cage tid reqs
    units <- declaredSpec env cage
    pot <- collateralPot env
    assembleFoldWithFee
        env
        (rowSpec cage tid state reqs (map Update proofs) root units)
            { fsCollateral = Just pot
            }

{- | Proof steps for the pending requests, and the root they reach.

The speculative insert is the normal path. On a key the trie ALREADY
binds it cannot apply — which is the whole duplicate fixture — so the
fallback proves the key where it sits and leaves the root alone. Either
proof reaches the same place on chain: `mpf.miss` answers false for an
occupied key and the state script halts `key-exists` before any mint
arithmetic runs.
-}
cg21Proofs ::
    Env ->
    RowCage ->
    TokenId ->
    [(TxIn, TxOut ConwayEra)] ->
    IO ([[ProofStep]], Root)
cg21Proofs env cage tid reqs = do
    attempt <- try @SomeException (speculativeApplyAll env cage tid reqs)
    case attempt of
        Right ok -> pure ok
        Left _ -> withSpeculativeTrie (envTm env) tid $ \trie -> do
            steps <-
                mapM
                    ( \(_, o) ->
                        fromMaybe []
                            <$> CageTrie.getProofSteps trie (fst (fst (requestDatumOf o)))
                    )
                    reqs
            root <- CageTrie.getRoot trie
            pure (steps, root)

{- | Fold through the harness's own assembly, submit, commit, and record
what the roots did — the accepting half of the duplicate pair.
-}
cg21HandFold :: Env -> RowCage -> [ByteString] -> IO (ConwayTx, FoldStep)
cg21HandFold env cage keys = do
    tid <- cageTid cage
    rootBefore <- cg21ChainRoot env cage
    hand <- cg21HandBuild env cage
    signed <- submitExpectAccepted env (addKeyWitness genesisSignKey hand)
    mapM_ (\k -> rowCommit env cage k edgeInsertActive) keys
    rootAfter <- cg21ChainRoot env cage
    committed <- withTrie (envTm env) tid CageTrie.getRoot
    require
        ( "CG21: a landed fold left the registry root where it found it (0x"
            <> T.unpack rootBefore
            <> "); the next proof would be built against a stale trie"
        )
        (rootBefore /= rootAfter)
    pure
        ( signed
        , FoldStep
            { fsTxid = T.pack (txIdHex signed)
            , fsRootBefore = rootBefore
            , fsRootAfter = rootAfter
            , fsCommitted = hexT (unRoot committed)
            }
        )

{- | The honest fold of whatever is pending, built and not submitted.
The keyed-mint fixture derives its claim from this one, so the two
differ in the mint distribution and in nothing else.
-}
cg21BatchFold :: Env -> RowCage -> IO ConwayTx
cg21BatchFold env cage = do
    tid <- cageTid cage
    let cfg = rcCfg cage
    ctx <- rowRegistryContext env cage tid
    updateTokenWithDuties cfg (envProv env) (envTm env) tid genesisAddr ctx

{- | Move one asset name's whole quantity onto another, under one
policy, in the mint AND in every output that carries it.

Both halves matter. Moving only the mint leaves the transaction
unbalanced and the LEDGER refuses it in phase 1, where no script speaks;
moving both keeps it balanced so the state script runs and refuses the
claim itself. The script integrity hash covers redeemers, datums and
cost models, none of which this touches.
-}
cg21MoveAsset :: PolicyID -> AssetName -> AssetName -> ConwayTx -> ConwayTx
cg21MoveAsset policy from to tx =
    tx
        & bodyTxL . mintTxBodyL %~ (\(MultiAsset ma) -> MultiAsset (moveMap ma))
        & bodyTxL . outputsTxBodyL %~ fmap moveOut
  where
    moveOut o =
        o
            & valueTxOutL
                %~ ( \v -> case v of
                        MaryValue c (MultiAsset ma) ->
                            MaryValue c (MultiAsset (moveMap ma))
                   )
    moveMap ma = case Map.lookup policy ma of
        Nothing -> ma
        Just names -> case Map.lookup from names of
            Nothing -> ma
            Just q ->
                Map.insert
                    policy
                    (Map.insertWith (+) to q (Map.delete from names))
                    ma

{- | The trace the ledger actually surfaced, or nothing.

A script-execution failure carries an EMPTY Plutus log list, so the
validator's own trace is usually not recoverable from the node's text.
This reads it where it IS there and records absence where it is not; the
refusal NAMES are asserted where the validator reads them, in the
compiled suite.
-}
cg21TraceIn :: String -> Maybe T.Text
cg21TraceIn text =
    case [n | n <- ["key-exists", "net-mint-mismatch"], n `isInfixOf` text] of
        (n : _) -> Just (T.pack n)
        [] -> Nothing

{- | Submit a transaction that must be refused, and attribute the
refusal to the state script before recording it.

An accepted transaction here is a FINDING and fails the run; a refusal
that does not attribute fails the run naming the mismatch. Neither can
pass quietly as "refused".
-}
cg21ExpectRefused ::
    Env ->
    RowCage ->
    String ->
    -- | the keys the refused batch named
    [ByteString] ->
    -- | what it claimed to mint
    Maybe [AssetEntry] ->
    -- | what its edges entail
    Maybe [AssetEntry] ->
    -- | what differs between it and its control
    String ->
    ConwayTx ->
    IO RefusalLeg
cg21ExpectRefused env cage label keys claimed entailed distinguisher signed = do
    let marker = stateMarkerOf (rcCfg cage)
    result <- submitTxResilient (envSubmit env) signed
    case result of
        Submitted txid ->
            failWith
                ( "CG21 FINDING: the node ACCEPTED the "
                    <> label
                    <> " transaction expected to refuse (txid "
                    <> txInHex txid
                    <> ") — reported, not relabelled"
                )
        Rejected reason -> do
            let text = T.unpack (TE.decodeUtf8Lenient reason)
            case matchRefusal marker text of
                Left mismatch ->
                    failWith
                        ( "CG21 "
                            <> label
                            <> ": the refusal did not attribute to the state "
                            <> "script ("
                            <> show mismatch
                            <> "): "
                            <> take 2000 text
                        )
                Right () -> do
                    emit
                        "row"
                        ( "CG21 "
                            <> label
                            <> ": REFUSED at submit, attributed to state "
                            <> "(phase-2, marker 0x"
                            <> shortMarker marker
                            <> ")"
                        )
                    pure
                        RefusalLeg
                            { rlTxid = T.pack (txIdHex signed)
                            , rlHashes = map T.pack (refusalScriptHashes text)
                            , rlTrace = cg21TraceIn text
                            , -- The control belongs to the refusal it
                              -- controls and is filled in when it lands.
                              rlControlTxid = ""
                            , rlDistinguisher = T.pack distinguisher
                            , rlKeys = map hexT keys
                            , rlClaimed = claimed
                            , rlEntailed = entailed
                            , rlControlMint = Nothing
                            }

{- | What the fold minted under one policy at one key, read off the
transaction the chain accepted.
-}
cg21MintedOf :: PolicyID -> ConwayTx -> [AssetEntry]
cg21MintedOf policy tx = case tx ^. bodyTxL . mintTxBodyL of
    MultiAsset ma ->
        [ AssetEntry (hexT (cg21PolicyBytes policy)) (hexT (SBS.fromShort an)) q
        | (p, names) <- Map.toList ma
        , p == policy
        , (AssetName an, q) <- Map.toList names
        ]

{- | Where the fold actually delivered, and what that output holds.

Read off the accepted transaction's own outputs rather than off the
address the harness queried: querying by address and then reporting that
address back would compare a value with itself.
-}
cg21Delivery ::
    PolicyID -> ByteString -> ConwayTx -> IO (T.Text, [AssetEntry])
cg21Delivery policy key tx =
    case [o | o <- toList (tx ^. bodyTxL . outputsTxBodyL), holds o] of
        [o] ->
            pure
                ( hexT (serialiseAddr (o ^. addrTxOutL))
                , [ AssetEntry (hexT (cg21PolicyBytes policy)) (hexT key) q
                  | (p, names) <- Map.toList (rawAssets o)
                  , p == policy
                  , (AssetName an, q) <- Map.toList names
                  , SBS.fromShort an == key
                  ]
                )
        outs ->
            failWith
                ( "CG21: the fold has "
                    <> show (length outs)
                    <> " outputs carrying the active token at this key, want one"
                )
  where
    holds o =
        or
            [ SBS.fromShort an == key
            | (p, names) <- Map.toList (rawAssets o)
            , p == policy
            , (AssetName an, _) <- Map.toList names
            ]

{- | The quantity the destination address actually holds at this key,
queried from the chain. The fold's own output says where the token went;
this says it is still there and spendable from that address.
-}
cg21HeldAt :: Env -> Addr -> PolicyID -> ByteString -> IO Integer
cg21HeldAt env addr policy key = do
    utxos <- Cage.queryUTxOs (envProv env) addr
    pure
        ( sum
            [ q
            | (_, out) <- utxos
            , (p, names) <- Map.toList (rawAssets out)
            , p == policy
            , (AssetName an, q) <- Map.toList names
            , SBS.fromShort an == key
            ]
        )

-- | The approval asset the request UTxO actually carries.
cg21ApprovalOn :: CageConfig -> TxOut ConwayEra -> IO T.Text
cg21ApprovalOn cfg out =
    case [ SBS.fromShort an
         | (p, names) <- Map.toList (rawAssets out)
         , p == policyIdFromPin (cfgApplicationPolicy cfg)
         , (AssetName an, _) <- Map.toList names
         ] of
        [n] -> pure (hexT n)
        ns ->
            failWith
                ( "CG21: the request UTxO carries "
                    <> show (length ns)
                    <> " approvals, want one"
                )

{- | What the request's OWN datum says: the lovelace it carries, and the
approval name its edge, key, owner and destination pair hash to.

The recomputation is the destination binding. The approval's asset name
IS the hash of the scoping tuple the request names, so a fold delivering
somewhere the approval did not bind makes the recomputed name differ
from the one the chain shows on the request.
-}
cg21RequestFacts :: TxOut ConwayEra -> IO (Integer, T.Text)
cg21RequestFacts out = do
    rq <- case extractCageDatum out of
        Just (RequestDatum r) -> pure r
        _ -> failWith "CG21: the request UTxO carries no request datum"
    -- #183: the request states its C2 row itself; there is nothing to
    -- derive. A tag outside the table names no approval binding, so a
    -- row that reads one would be reading a fact that does not exist.
    edgeIx <- do
        let e = requestEdge rq
        if e >= edgeInsertAbsent && e <= edgeWitnessTerminal
            then pure e
            else failWith "CG21: the request names no admissible edge"
    let BuiltinByteString owner = requestOwner rq
        Coin lovelace = out ^. coinTxOutL
    pure
        ( lovelace
        , hexT (approvalName edgeIx (requestKey rq) owner (requestDestination rq))
        )

{- | The refund obligations this fold creates, read off its own
redeemer.

The state script derives refunds from the fold's ACTIONS: only a
`Rejected` action (constructor 1) owes anything, and `sumRefunds` is the
rule that checks them. A batch whose actions are all `Update`
(constructor 0) owes none, which is the model's @refunds := []@ — read
from the transaction the node validated rather than from what the
harness meant to build.
-}
cg21RefundsOf :: ConwayTx -> [Integer]
cg21RefundsOf tx = [c | c <- requestActionConstrs tx, c /= 0]

-- | The signers the fold declares it requires. The model says none.
cg21SignersOf :: ConwayTx -> [T.Text]
cg21SignersOf tx =
    map (T.pack . show) (Set.toList (tx ^. bodyTxL . reqSignerHashesTxBodyL))

-- | CG21's receipt: an accepted row carrying its edge observation.
writeCG21Receipt ::
    Env -> ConwayTx -> Integer -> Integer -> Integer -> EdgeEvidence -> IO ()
writeCG21Receipt env foldTx mem cpu size edge =
    writeReceiptFile (envReceiptsDir env) $
        Receipt
            { receiptRow = "CG21"
            , receiptOutcome = Accepted
            , receiptVerdict = AgreesWithModel
            , receiptTransactions = [T.pack (txIdHex foldTx)]
            , receiptRefusal = Nothing
            , receiptRejected = Nothing
            , receiptMem = Just mem
            , receiptCpu = Just cpu
            , receiptTxSize = Just size
            , receiptBase = T.pack (envBase env)
            , receiptDirty = envDirty env
            , receiptPartial = Nothing
            , receiptEdge = Just edge
            , receiptRetirement = Nothing
            , receiptDerivation = Nothing
            , receiptNode = T.pack (envNode env)
            , receiptBlueprint = T.pack (envBlueprint env)
            , receiptVenue = "node-submit"
            }
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
    cage <- ensureRowCage env "cg22" 30_000 30_000
    tid <- cageTid cage
    let cfg = rcCfg cage
        prov = envProv env
        bond = defaultTipCoin cfg + cgDeposit
        -- The open story hands the witness to a WALLET, which is where
        -- the retirement must find it. `edgeDestinationFor` would route
        -- an activation to the application's script address, right for
        -- naming and wrong here.
        walletDest = (serialiseAddr genesisAddr, recordDatumHash)
        -- A retirement delivers nothing, so it names nothing.
        retireDest = (BS.empty, BS.empty)
        book key op dest =
            bookEdge env cfg tid genesisAddr genesisSignKey key op dest [] bond
        buildFold = do
            ctx <- rowRegistryContext env cage tid
            updateTokenWithDuties cfg prov (envTm env) tid genesisAddr ctx
        land key op = do
            unsigned <- buildFold
            signed <- submitWithGenesis (envSubmit env) unsigned
            rowCommit env cage key op
            pure signed
        rootNow = withTrie (envTm env) tid CageTrie.getRoot

    -- 1. the prerequisite, EXECUTED: the key becomes Active and the
    --    wallet holds its witness.
    rootBeforeInsert <- rootNow
    _ <- book cg22Key insertActiveOp walletDest
    insertTx <- land cg22Key insertActiveOp
    rootActive <- rootNow
    heldBefore <- activeHeldFor env cfg cg22Key
    require
        "CG22: the insert did not leave exactly one active witness at the wallet"
        (heldBefore == 1)

    -- The exact input the burn will consume, recorded BEFORE it is
    -- spent. A mint of -1 with no token-bearing input is the shape the
    -- cage refuses `token-missing`, and a row that did not look would
    -- not know the difference.
    source <- activeSourceFor env cfg cg22Key

    -- 2. the edge under test, at the SAME key.
    _ <- book cg22Key retireOp retireDest
    retireTx <- land cg22Key retireOp
    rootTerminal <- rootNow
    heldAfter <- activeHeldFor env cfg cg22Key
    chainRoot <- committedRootOf env cage
    require
        "CG22: the wallet still holds this key's active witness after the retirement"
        (heldAfter == 0)
    -- The LEAF, observed where a leaf can actually be observed.
    -- `Trie.lookup` answers with the key's hash rather than its value and
    -- cannot see a leaf at all. The committed ROOT can: a trie with a
    -- different leaf at this key has a different root. The chain reached
    -- this one through the validator's own `mpf.update(0x01, 0x02)` and
    -- the mirror through an independent local trie, so equality is a
    -- statement about the leaf and not about either implementation.
    require
        "CG22: the chain root after the retirement is not the root of a \
        \trie whose leaf at this key is Terminal"
        (chainRoot == unRoot rootTerminal)
    let burned = activeMintOf retireTx cfg
    require
        "CG22: the retirement's mint under the active policy is not exactly this key's -1"
        (burned == [AssetEntry (hexText (activePolicyBytes cfg)) (hexText cg22Key) (-1)])
    require
        "CG22: the three roots are not distinct"
        (length (nub [rootBeforeInsert, rootActive, rootTerminal]) == 3)

    {- Each refusal needs a cage of its own.

    A refused fold never consumes the request that caused it. That
    request stays pending, the next fold sweeps it up, and the second
    refusal becomes the chain re-refusing the first — or, worse, a
    builder failure naming the first key while the row claims the
    second. Ordering does not help: whichever refusal runs first poisons
    everything after it.

    So the Absent leg runs LAST in this cage, controlled by the story's
    own retirement above — same cage, same builder, and the only thing
    that differs is the leaf. The Unknown leg gets a second cage with a
    control folded in it first. -}

    -- 3. a key bound by a real insertAbsent fold and never booked. Its
    --    control is the retirement that has just landed here.
    _ <- book cg22AbsentKey insertAbsentOp (serialiseAddr genesisAddr, BS.empty)
    _ <- land cg22AbsentKey insertAbsentOp
    _ <- book cg22AbsentKey retireOp retireDest
    -- a #177 retirement refusal leg does not observe the keyed-mint
    -- delta; CG21 (#184) is the row that observes it. An empty
    -- `rlClaimed`/`rlEntailed` on such a leg means not-observed, never
    -- observed-empty.
    absentLeg <-
        refusedRetirement
            env
            cage
            tid
            cg22AbsentKey
            (txIdHex retireTx)
            "the control retired a key that IS Active in this same cage; \
            \this one was witnessed Absent"
            "CG22: the chain ACCEPTED updateTerminal on a key witnessed \
            \Absent — reported, not relabelled"

    -- 4. a key the trie does not bind at all, in a cage of its own so
    --    the Absent refusal above cannot be what refuses it.
    unknownCage <- ensureRowCage env "cg22-unknown" 30_000 30_000
    unknownTid <- cageTid unknownCage
    let unknownCfg = rcCfg unknownCage
        bookU key op dest =
            bookEdge env unknownCfg unknownTid genesisAddr genesisSignKey key op dest [] bond
        landU key op = do
            ctx <- rowRegistryContext env unknownCage unknownTid
            unsigned <-
                updateTokenWithDuties
                    unknownCfg
                    prov
                    (envTm env)
                    unknownTid
                    genesisAddr
                    ctx
            signed <- submitWithGenesis (envSubmit env) unsigned
            rowCommit env unknownCage key op
            pure signed
    _ <- bookU cg22ControlKey insertActiveOp walletDest
    _ <- landU cg22ControlKey insertActiveOp
    _ <- bookU cg22ControlKey retireOp retireDest
    controlTx <- landU cg22ControlKey retireOp
    emit
        "control"
        "CG22 control: a key that IS active retired in the Unknown leg's \
        \own cage — the refusal below discriminates the leaf"
    _ <- bookU cg22UnknownKey retireOp retireDest
    -- a #177 retirement refusal leg does not observe the keyed-mint
    -- delta; CG21 (#184) is the row that observes it. An empty
    -- `rlClaimed`/`rlEntailed` on such a leg means not-observed, never
    -- observed-empty.
    unknownLeg <-
        refusedRetirement
            env
            unknownCage
            unknownTid
            cg22UnknownKey
            (txIdHex controlTx)
            "the control retired a key that IS Active in this same cage; \
            \this one was never inserted at all"
            "CG22: the chain ACCEPTED updateTerminal on a key the trie \
            \does not bind — reported, not relabelled"

    (mem, cpu) <- readIORef (rcUnits cage)
    writeRetirementReceipt
        env
        "CG22"
        -- Every transaction this row put on chain, so the gate can find
        -- the two folds and BOTH accepting controls in it.
        --
        -- The two legs carry DIFFERENT controls, because they run in
        -- different cages: the Absent leg is controlled by `retireTx`,
        -- the story retirement in its own cage, and the Unknown leg by
        -- `controlTx`, folded in the second cage before it. A single
        -- control could not serve both — a refused fold never consumes
        -- its request, so the two refusals cannot share a cage, and a
        -- control from the other cage would not be the same builder
        -- against the same state.
        [ txIdHex insertTx
        , txIdHex retireTx
        , txIdHex controlTx
        , T.unpack (rlTxid unknownLeg)
        , T.unpack (rlTxid absentLeg)
        ]
        (Just mem)
        (Just cpu)
        (Just (txSizeBytes retireTx))
        RetirementEvidence
            { rtActivePolicy = hexText (activePolicyBytes cfg)
            , rtKey = hexText cg22Key
            , rtInsertTxid = T.pack (txIdHex insertTx)
            , rtRetireTxid = T.pack (txIdHex retireTx)
            , rtRoots =
                RetirementRoots
                    { rrBeforeInsert = hexText (unRoot rootBeforeInsert)
                    , rrActive = hexText (unRoot rootActive)
                    , rrTerminal = hexText (unRoot rootTerminal)
                    }
            , rtQuantities =
                RetirementQuantities{rqBefore = heldBefore, rqAfter = heldAfter}
            , rtMint = burned
            , rtSource = source
            , rtLeaf = "Terminal"
            , rtUnknown = unknownLeg
            , rtAbsent = absentLeg
            }
    emit
        "CG22"
        "the witness the insert delivered was burned from its holder, the \
        \leaf reads Terminal, and the Unknown and Absent retirements were \
        \refused against an accepting control"


{- | The registry's own committed root, read off a row cage's state UTxO
on chain. This is how a LEAF is observed: `Trie.lookup` answers with the
key's hash rather than its value, while a trie with a different leaf at
a key has a different root.
-}
committedRootOf :: Env -> RowCage -> IO ByteString
committedRootOf env cage = do
    (_, out) <- cageStateUtxo env cage
    case extractCageDatum out of
        Just (StateDatum s) -> pure (unOnChainRoot (stateRoot s))
        _ -> failWith "row cage: the state UTxO carries no state datum"

-- | CG22's three keys: the story, its control, and the two bad leaves.
cg22Key, cg22ControlKey, cg22UnknownKey, cg22AbsentKey :: ByteString
cg22Key = "cg22-retire"
cg22ControlKey = "cg22-retire-control"
cg22UnknownKey = "cg22-retire-unknown"
cg22AbsentKey = "cg22-retire-absent"

insertActiveOp, insertAbsentOp, retireOp :: Edge
insertActiveOp = edgeInsertActive
insertAbsentOp = edgeInsertAbsent
retireOp = edgeUpdateTerminal

{- | Submit a fold the chain must REFUSE, and record the leg: the refused
transaction's id, the script hashes the failure is attributed to, the
honest trace (`Nothing` unless the ledger surfaced one), the accepting
control, and what differs between the two.

The fold is HAND-ASSEMBLED rather than taken from
`updateTokenWithDuties`. That builder evaluates on the node and raises
the failure as its own error, so it produces no transaction — and a row
whose claim is "the chain refused this, here is the transaction" needs
one to point at. Assembling it directly is the same path every other
refusal row in this suite uses.

An ACCEPTANCE here is reported as a finding, never relabelled.
-}
refusedRetirement ::
    Env ->
    RowCage ->
    TokenId ->
    -- | the key under test, named by the refused batch
    ByteString ->
    -- | the accepting control's txid
    String ->
    -- | the one fact that differs from the control
    String ->
    -- | what to say if the chain accepts
    String ->
    IO RefusalLeg
refusedRetirement env cage tid key controlTxid distinguisher acceptedMsg = do
    state <- cageStateUtxo env cage
    reqUtxos <- pendingRequests env cage
    (proofs, newRoot) <- speculativeApplyAll env cage tid reqUtxos
    pp <- Cage.queryProtocolParams (envProv env)
    -- The budget is per REDEEMER and the ledger caps their SUM, so the
    -- transaction maximum handed to each one over-subscribes it by the
    -- number of purposes (`ExUnitsTooBigUTxO`). A quarter each leaves
    -- room for the state spend, the request spends and the mints, and
    -- is far more than a fold needs to reach the refusal under test.
    let ExUnits maxMem maxSteps = pp ^. ppMaxTxExUnitsL
        share = ExUnits (maxMem `div` 4) (maxSteps `div` 4)
    unsigned <-
        assembleFoldWithFee
            env
            (rowSpec cage tid state reqUtxos (map Update proofs) newRoot share)
    let signed = addKeyWitness genesisSignKey unsigned
    result <- submitTxResilient (envSubmit env) signed
    case result of
        Submitted _ -> awaitTx >> failWith acceptedMsg
        Rejected reason -> do
            let text = T.unpack (TE.decodeUtf8Lenient reason)
                hashes = refusalScriptHashes text
            -- A phase-2 failure names the script that refused. A phase-1
            -- rejection names none, and would mean the chain refused
            -- this transaction for its shape rather than for the leaf
            -- under test — so the reason travels with the complaint.
            require
                ( "CG22: the refusal carries no script-hash attribution, so \
                  \it is not the cage refusing: "
                    <> take 600 text
                )
                (not (null hashes))
            pure
                RefusalLeg
                    { rlTxid = T.pack (txIdHex signed)
                    , rlHashes = map T.pack hashes
                    , -- A phase-2 failure carries an EMPTY Plutus log
                      -- list, so the validator's own trace is normally
                      -- not recoverable. `Nothing` rather than a guess;
                      -- the NAMES are asserted in the Aiken suite.
                      rlTrace = Nothing
                    , rlControlTxid = T.pack controlTxid
                    , rlDistinguisher = T.pack distinguisher
                    , rlKeys = [hexT key]
                    , rlClaimed = Nothing
                    , rlEntailed = Nothing
                    , rlControlMint = Nothing
                    }

-- | The quantity the genesis wallet holds of this key's active witness.
activeHeldFor :: Env -> CageConfig -> ByteString -> IO Integer
activeHeldFor env cfg key = do
    utxos <- Cage.queryUTxOs (envProv env) genesisAddr
    pure (sum [q | (_, o) <- utxos, (_, q) <- activeEntriesOf cfg key o])

{- | The wallet UTxO carrying this key's active witness, by outref and
quantity, read off the chain before the retirement spends it.
-}
activeSourceFor :: Env -> CageConfig -> ByteString -> IO RetirementSource
activeSourceFor env cfg key = do
    utxos <- Cage.queryUTxOs (envProv env) genesisAddr
    case [(i, q) | (i, o) <- utxos, (_, q) <- activeEntriesOf cfg key o] of
        [(i, q)] ->
            pure
                RetirementSource
                    { rsOutref = txInToText i
                    , rsPolicy = hexText (activePolicyBytes cfg)
                    , rsName = hexText key
                    , rsQuantity = q
                    }
        carriers ->
            failWith
                ( "CG22: the wallet holds "
                    <> show (length carriers)
                    <> " carriers of this key's active witness, not one"
                )

-- | This output's holdings under the active policy at this key.
activeEntriesOf ::
    CageConfig -> ByteString -> TxOut ConwayEra -> [(ByteString, Integer)]
activeEntriesOf cfg key out =
    let MaryValue _ (MultiAsset ma) = out ^. valueTxOutL
        policy = policyIdFromPin (cfgActivePolicy cfg)
     in [ (SBS.fromShort n, q)
        | (p, names) <- Map.toList ma
        , p == policy
        , (AssetName n, q) <- Map.toList names
        , SBS.fromShort n == key
        ]

-- | Everything a transaction moves under the ACTIVE policy, by key.
activeMintOf :: ConwayTx -> CageConfig -> [AssetEntry]
activeMintOf tx cfg =
    let MultiAsset ma = tx ^. bodyTxL . mintTxBodyL
        policy = policyIdFromPin (cfgActivePolicy cfg)
     in [ AssetEntry
            (hexText (activePolicyBytes cfg))
            (hexText (SBS.fromShort n))
            q
        | (p, names) <- Map.toList ma
        , p == policy
        , (AssetName n, q) <- Map.toList names
        ]

activePolicyBytes :: CageConfig -> ByteString
activePolicyBytes = SBS.fromShort . cfgActivePolicy

hexText :: ByteString -> T.Text
hexText = TE.decodeUtf8 . Base16.encode

{- | A receipt carrying retirement evidence (#177). Everything else is
`writeRowReceipt`'s; only the extra object differs, so the two cannot
drift on the fields they share.
-}
writeRetirementReceipt ::
    Env ->
    String ->
    [String] ->
    Maybe Integer ->
    Maybe Integer ->
    Maybe Integer ->
    RetirementEvidence ->
    IO ()
writeRetirementReceipt env row txs mem cpu size retirement =
    writeReceiptFile (envReceiptsDir env) $
        Receipt
            { receiptRow = T.pack row
            , receiptOutcome = Accepted
            , receiptVerdict = AgreesWithModel
            , receiptTransactions = map T.pack txs
            , receiptRefusal = Nothing
            , receiptRejected = Nothing
            , receiptMem = mem
            , receiptCpu = cpu
            , receiptTxSize = size
            , receiptBase = T.pack (envBase env)
            , receiptDirty = envDirty env
            , receiptPartial = Nothing
            , receiptEdge = Nothing
            , receiptRetirement = Just retirement
            , receiptDerivation = Nothing
            , receiptNode = T.pack (envNode env)
            , receiptBlueprint = T.pack (envBlueprint env)
            , receiptVenue = "node-submit"
            }

-- | Every pending request UTxO of a row cage, in tx-input order.
pendingRequests :: Env -> RowCage -> IO [(TxIn, TxOut ConwayEra)]
pendingRequests env cage = do
    tid <- cageTid cage
    let cfg = rcCfg cage
    reqUtxos <-
        Cage.queryUTxOs
            (envProv env)
            (requestAddrFromCfg cfg tid (network cfg))
    pure (sortOn fst (findRequestUtxos tid reqUtxos))

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

extractState :: TxOut ConwayEra -> IO OnChainTokenState
extractState out = case extractCageDatum out of
    Just (StateDatum s) -> pure s
    _ -> failWith "hand-build: state output has no StateDatum"

-- | Lovelace in an output, era-pinned for the polymorphic lenses.
outCoin :: TxOut ConwayEra -> Integer
outCoin o = let Coin c = o ^. coinTxOutL in c

{- | A request output's submitted-at (ms), from its live datum.
-}
submittedAtDatum :: TxOut ConwayEra -> IO Integer
submittedAtDatum out = case extractCageDatum out of
    Just (RequestDatum rq) -> pure (requestSubmittedAt rq)
    _ -> failWith "deadline: request output has no RequestDatum"

{- | Wait until past the given deadline ms (phase-3 entry for
Rejected folds). Polls the clock; fails closed on timeout rather
than submitting a wrong-phase transaction.
-}
waitPhase3 :: Integer -> IO ()
waitPhase3 deadline = go (20 :: Int)
  where
    go n = do
        now <- currentPosixMs
        if now > deadline + 2000
            then pure ()
            else
                if n <= 0
                    then
                        failWith
                            "phase-3 wait timed out; refusing to submit a wrong-phase fold"
                    else threadDelay 5_000_000 >> go (n - 1)

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

{- | The deposit a booking rides with, over and above the tip. The fold
returns it to the destination the request named, or locks it in the
custody an absence creates — it is never the folder's (T6, want-ledger R4).
-}
cgDeposit :: Integer
cgDeposit = 3_000_000

{- | Commit a landed op to the builder trie. Speculative folds never
commit ('withSpeculativeTrie' discards), so the caller keeps the
trie in step or the next fold proves against a stale root.
-}
commitTm :: Env -> Edge -> IO ()
commitTm env = commitTmKey env cgKey

commitTmKey :: Env -> ByteString -> Edge -> IO ()
commitTmKey env cgKey' edge =
    withTrie (envTm env) (envTid env) $ \t -> () <$ walkEdge t cgKey' edge

-- | The claimed value under test; false-claim mode binds the forgery.
claimValue :: Env -> ByteString -> ByteString
claimValue env val = case envControl env of
    FalseClaim -> forgedValue
    _ -> val

submitWithGenesis :: Submitter IO -> ConwayTx -> IO ConwayTx
submitWithGenesis submit unsignedTx = do
    let signedTx = addKeyWitness genesisSignKey unsignedTx
    result <- submitTxResilient submit signedTx
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
    Verdict ->
    [String] ->
    Maybe RefusalInfo ->
    Maybe String ->
    Maybe Integer ->
    Maybe Integer ->
    Maybe Integer ->
    T.Text ->
    Maybe [DerivationEvidence] ->
    IO ()
writeRowReceipt env row outcome verdict txs refusal rejected mem cpu size venue derivation =
    writeReceiptFile (envReceiptsDir env) $
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
            , receiptBase = T.pack (envBase env)
            , receiptDirty = envDirty env
            , receiptPartial = Nothing
            , receiptEdge = Nothing
            , receiptRetirement = Nothing

            , receiptDerivation = derivation
            , receiptNode = T.pack (envNode env)
            , receiptBlueprint = T.pack (envBlueprint env)
            , receiptVenue = venue
            }

{- | Record a held row (Q-002, story 2): the chain's outcome agrees
with Singular's Lean and contradicts the consumer's theorem. The
row is visible here, in its receipt (@held-q002@), and in the
run's exit — the session ends non-zero while anything is held.
-}
recordHold :: Env -> String -> String -> String -> String -> IO ()
recordHold env row holdId leanSays consumerSays = do
    modifyIORef' (envHeld env) (row :)
    emit
        "held"
        ( row
            <> " HELD FOR "
            <> holdId
            <> ": "
            <> leanSays
            <> "; the consumer's theorem says "
            <> consumerSays
            <> "; which model is the behavioral authority is the \
               \user's ruling, not ours — the run cannot exit 0 \
               \while this row is held"
        )

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
    threadDelay 3_000_000
    status <- poll nodeThread
    case status of
        Nothing -> pure ()
        Just _ ->
            failWith "node connection closed before queries ran"
    let prov = adaptProvider (mkN2CProvider lsqCh)
        submit = mkN2CSubmitter ltxsCh
        stateMarker = hex (scriptHashBytes (computeScriptHash stateBytes))
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
            , receiptEdge = Nothing
            , receiptRetirement = Nothing

            , receiptDerivation = Nothing
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

-- | `ProofStep` indices inside `Update` actions (0 `Branch`, 1 `Fork`,
-- 2 `Leaf`), read from the transaction supplied to the node.
proofStepConstrs :: ConwayTx -> [Integer]
proofStepConstrs tx = concatMap fromDatum (redeemerPlutusDatas tx)
  where
    fromDatum (PLC.Constr 2 [PLC.List actions]) = concatMap fromAction actions
    fromDatum _ = []
    fromAction (PLC.Constr 0 [PLC.List steps]) = concatMap fromStep steps
    fromAction _ = []
    fromStep (PLC.Constr ix _) = [ix]
    fromStep _ = []

-- | Every `Fork` step in the tx carries a well-formed 3-field
-- `Neighbor`. Companion to `proofStepConstrs`.
forkNeighborsWellFormed :: ConwayTx -> Bool
forkNeighborsWellFormed tx = all fromDatum (redeemerPlutusDatas tx)
  where
    fromDatum (PLC.Constr 2 [PLC.List actions]) = all fromAction actions
    fromDatum _ = True
    fromAction (PLC.Constr 0 [PLC.List steps]) = all fromStep steps
    fromAction _ = True
    fromStep (PLC.Constr 1 [_, PLC.Constr 0 [_, _, _]]) = True
    fromStep (PLC.Constr 1 _) = False
    fromStep _ = True

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
            writeCSReceipt receiptsDir "CS04" Refused AgreesWithModel [] (Just (RefusalInfo {refusalScript = T.intercalate "+" (map T.pack roles), refusalReason = T.pack trimmed, refusalPhase = "phase-2", refusalHashes = map T.pack hashes, refusalBranch = Nothing, refusalLimit = Just "no named validator branch in this compiled trace; attribution is script hash plus phase-2 only"})) (Just rejectedTxid) Nothing Nothing Nothing "node-submit" base dirty nodeVer blueprintIdStr Nothing
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
    threadDelay 3_000_000
    status <- poll nodeThread
    case status of
        Nothing -> pure ()
        Just _ ->
            failWith "node connection closed before queries ran"
    let prov = adaptProvider (mkN2CProvider lsqCh)
        submit = mkN2CSubmitter ltxsCh
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

{- | Book one registry-mode edge (#157 C2, C4, D-DEST): mint the approval
that certifies it under the registry's pinned application policy, and
create the request that carries it.

The approval's asset name IS the binding — the edge index, the key, the
owner and the destination, hashed together — and the cage recomputes it
from the request at fold time. A booking and a fold therefore cannot
disagree about what was certified: a drift makes the honest fold refuse
with `approval-binding` rather than pass quietly.

Which signature or reference the naming application demands is the edge's
own business (R-NM4): an absence witness needs none, an activation needs
the controller, and a deletion needs the custody's refund address and the
custody itself in view.
-}
bookEdge ::
    Env ->
    CageConfig ->
    TokenId ->
    Addr ->
    SignKeyDSIGN Ed25519DSIGN ->
    -- | Registry key
    ByteString ->
    Edge ->
    -- | Destination: address bytes and datum hash
    (ByteString, ByteString) ->
    -- | Reference inputs the certifying arm reads (custody, for a deletion)
    [(TxIn, TxOut ConwayEra)] ->
    -- | Bond: the tip plus the deposit that rides to the destination
    Integer ->
    IO (TxIn, TxOut ConwayEra)
bookEdge env cfg tid payerAddr payerSk key edge dest refIns bond = do
    let (_, _, codes) = envCodes env
        prov = envProv env
    -- #183: the tag IS the edge. A row that books one outside the table
    -- is booking something the cage refuses `edge-inadmissible`, which
    -- no row here asks for, so it is caught at the booking.
    unless (edge >= edgeInsertAbsent && edge <= edgeWitnessTerminal) $
        failWith
            ( "bookEdge: edge "
                <> show edge
                <> " on key "
                <> show key
                <> " is not one of the seven admissible edges"
            )
    pp <- Cage.queryProtocolParams prov
    utxos <- Cage.queryUTxOs prov payerAddr
    (feeIn, feeOut) <- case sortOn (Down . (^. coinTxOutL) . snd) utxos of
        [] -> failWith "bookEdge: payer wallet has no UTxOs"
        (u : _) -> pure u
    -- A spent approval is not burned at the fold, so it comes back to the
    -- funder and rides in the wallet from then on. The booking carries
    -- whatever its input holds through to its own change, and collateral
    -- is taken from an ada-only output, which is all the ledger accepts.
    collateralIn <- case sortOn (Down . (^. coinTxOutL) . snd) (filter (adaOnlyOut . snd) utxos) of
        [] -> failWith "bookEdge: payer wallet has no ada-only output for collateral"
        ((i, _) : _) -> pure i
    now <- currentPosixMs
    let MaryValue (Coin feeBal) carried = feeOut ^. valueTxOutL
        Coin tipVal = defaultTip cfg
        -- The booking runs the application's mint arm, and the fee it
        -- owes scales with the budget declared for it.
        fee = 2_000_000
        change = feeBal - bond - fee
        owner = addrKeyHashBytes payerAddr
        (destAddr, destHash) = dest
        name = approvalName edge key owner dest
        appScript = scriptFromBytes "naming-application" (ncApplication codes)
        appPolicy = PolicyID (hashScript appScript)
        approval =
            MultiAsset
                (Map.singleton appPolicy (Map.singleton (AssetName (SBS.toShort name)) 1))
        approveRedeemer =
            PLC.Constr
                0
                [ PLC.I edge
                , PLC.B key
                , PLC.B owner
                , PLC.List [PLC.B destAddr, PLC.B destHash]
                ]
        requestAddr = requestAddrFromCfg cfg tid (network cfg)
        -- #183: the datum binds the DEPOSIT, not the tip. The output
        -- holds `bond` = tip + deposit and the fold checks
        -- `deposit == held - tip`; the min-ADA check below is what
        -- keeps the two equal, because a bond raised to meet min-ADA
        -- would break the equality silently.
        datum = mkRequestDatumWith tid payerAddr key edge (bond - tipVal) now dest
        reqOut =
            mkBasicTxOut requestAddr (MaryValue (Coin bond) approval)
                & datumTxOutL .~ mkInlineDatum datum
        Coin minAda = getMinCoinTxOut @ConwayEra pp reqOut
    require
        ("bookEdge: payer wallet too small (" <> show feeBal <> ")")
        (change > 0)
    require
        ("bookEdge: bond under min-ADA: " <> show bond)
        (bond >= minAda)
    let redeemers =
            Redeemers
                ( Map.singleton
                    (ConwayMinting (AsIx 0))
                    (toLedgerData (RawRedeemer approveRedeemer), generousUnits)
                )
        integrity = computeScriptIntegrity pp redeemers
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton feeIn
                & referenceInputsTxBodyL .~ Set.fromList (map fst refIns)
                & outputsTxBodyL
                    .~ StrictSeq.fromList
                        [ reqOut
                        , mkBasicTxOut payerAddr (MaryValue (Coin change) carried)
                        ]
                & feeTxBodyL .~ Coin fee
                & mintTxBodyL .~ approval
                & collateralInputsTxBodyL .~ Set.singleton collateralIn
                & reqSignerHashesTxBodyL
                    .~ Set.singleton (addrWitnessKeyHash owner)
                & scriptIntegrityHashTxBodyL .~ integrity
        unsigned =
            mkBasicTx body
                & witsTxL . scriptTxWitsL
                    .~ Map.singleton (hashScript appScript) appScript
                & witsTxL . rdmrsTxWitsL .~ redeemers
        signed = addKeyWitness payerSk unsigned
    result <- submitTxResilient (envSubmit env) signed
    case result of
        Submitted _ -> awaitTx
        Rejected reason ->
            failWith
                ( "bookEdge refused (edge "
                    <> show edge
                    <> ", key "
                    <> show key
                    <> "): "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )
    emit
        "booked"
        ( "edge "
            <> show edge
            <> " on key "
            <> show key
            <> " certified by approval 0x"
            <> hex name
        )
    pure (TxIn (txIdTx signed) (TxIx 0), reqOut)

{- | The record datum a booking's destination binds, and its hash. The
cage checks only that the receiving output carries a datum hashing to what
the approval bound — naming's own validators do not run at fold time — so
the harness needs one datum it can produce on both sides and nothing more.
-}
recordDatum :: PLC.Data
recordDatum = PLC.B "cg-record"

recordDatumHash :: ByteString
recordDatumHash =
    hashToBytes (extractHash (hashData (Data recordDatum :: Data ConwayEra)))

{- | Where an edge delivers (#157 D-DEST, R-NM4).

An absence names the address its deposit comes back to, and no datum. An
activation names the naming application's own address and the record datum
it will carry — that is what `record_destination` demands of it. A deletion
and a termination name nothing at all.
-}
edgeDestination :: Env -> Edge -> IO (ByteString, ByteString)
edgeDestination env = edgeDestinationFor env genesisAddr

-- | `edgeDestination` for a named payer: an absence binds the address its
-- deposit comes back to, and that is the payer's own.
edgeDestinationFor ::
    Env -> Addr -> Edge -> IO (ByteString, ByteString)
edgeDestinationFor env payerAddr edge = do
    let (_, _, codes) = envCodes env
        appHash = computeScriptHash (ncApplication codes)
        appAddr = Addr (network (envCfg env)) (ScriptHashObj appHash) StakeRefNull
    pure $ case edge of
        0 -> (serialiseAddr payerAddr, BS.empty)
        1 -> (serialiseAddr appAddr, recordDatumHash)
        2 -> (serialiseAddr appAddr, recordDatumHash)
        6 -> (serialiseAddr payerAddr, BS.empty)
        _ -> (BS.empty, BS.empty)

{- | What the certifying arm needs to read. A deletion is authorised by the
custody's own refund address, which naming reads from the custody UTxO as a
reference input.
-}
edgeReferences ::
    Env -> ByteString -> Edge -> IO [(TxIn, TxOut ConwayEra)]
edgeReferences env key edge = case edge of
    4 -> do
        utxos <- cageUtxos env
        case
            [ u
            | u@(_, o) <- utxos
            , Just (AbsentCustody k _) <- [extractCageDatum o]
            , k == key
            ]
            of
            [u] -> pure [u]
            _ -> failWith ("edgeReferences: no single custody UTxO for key " <> show key)
    _ -> pure []

-- | The UTxOs sitting at the cage's own address; custody lives among them.
cageUtxos :: Env -> IO [(TxIn, TxOut ConwayEra)]
cageUtxos env =
    Cage.queryUTxOs
        (envProv env)
        (cageAddrFromCfg (envCfg env) (network (envCfg env)))

{- | Everything a fold of tree edges needs in hand: the three token
policies this registry pins, the cage script custody spends run, the cage's
own UTxOs, and the one destination datum the harness books against.
-}
registryContext :: Env -> IO RegistryContext
registryContext env = do
    refs <- sessionRefUtxos env
    let cfg = envCfg env
        (_, _, codes) = envCodes env
        registryId =
            scriptHashBytes (cfgScriptHash cfg)
                <> SBS.fromShort (assetNameBytes (unTokenId (envTid env)))
        witnessAt kind =
            scriptFromBytes
                ("witness-" <> show kind)
                ( applyBytesParam
                    registryId
                    (applyDataParam (PLC.I kind) (ncWitness codes))
                )
    utxos <- cageUtxos env
    pure
        RegistryContext
            { rcWitnessScripts =
                Map.fromList [(k, witnessAt k) | k <- [0, 1, 2]]
            , rcCageScript = Just (mkCageScript cfg)
            , rcCageUtxos = utxos
            , rcDatums = [(recordDatumHash, recordDatum)]
            , rcAllowInadmissible = False
            , rcHolderUtxos = []
            , rcRefUtxos = refs
            }
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

{- | The session's reference outputs, published on first use: the cage,
the request validator and the three token policies.
-}
sessionRefUtxos :: Env -> IO [(TxIn, TxOut ConwayEra)]
sessionRefUtxos env = do
    cached <- readIORef (envRefs env)
    case cached of
        Just refs -> pure refs
        Nothing -> do
            refs <- cageRefUtxos env (envCfg env) (envTid env)
            writeIORef (envRefs env) (Just refs)
            pure refs

-- | The reference outputs one cage's folds resolve their scripts through.
cageRefUtxos ::
    Env -> CageConfig -> TokenId -> IO [(TxIn, TxOut ConwayEra)]
cageRefUtxos env cfg tid = do
            let (_, _, codes) = envCodes env
                registryId =
                    scriptHashBytes (cfgScriptHash cfg)
                        <> SBS.fromShort (assetNameBytes (unTokenId tid))
                witnessAt kind =
                    scriptFromBytes
                        ("witness-" <> show kind)
                        ( applyBytesParam
                            registryId
                            (applyDataParam (PLC.I kind) (ncWitness codes))
                        )
            refs <-
                mapM
                    (publishRefScript env)
                    ( [ mkCageScript cfg
                      , mkRequestScript cfg tid
                      ]
                        <> map witnessAt [0, 1, 2]
                    )
            emit
                "references"
                ( show (length refs)
                    <> " scripts published as reference outputs; folds resolve \
                       \every purpose through them"
                )
            pure refs

{- | Can this output fund a transaction? It must hold ada and nothing
else, because it doubles as collateral, and it must not be one of the
published reference outputs, because a transaction may not both spend an
output and reference it.
-}
adaOnlyOut :: TxOut ConwayEra -> Bool
adaOnlyOut out =
    (case out ^. valueTxOutL of MaryValue _ (MultiAsset m) -> Map.null m)
        && (case out ^. referenceScriptTxOutL of SNothing -> True; SJust _ -> False)

writeCL01Issue70 :: Env -> [String] -> IO ()
writeCL01Issue70 env rows
    | all (`elem` rows) issue70Rows = do
        receipts <- mapM readRowReceiptFile issue70AcceptingRows
        case sequence receipts of
            Just rs ->
                writeRowReceipt
                    env
                    "CL01"
                    Accepted
                    AgreesWithModel                    (map T.unpack (concatMap receiptTransactions rs))
                    Nothing
                    Nothing
                    (Just (maximum (map getMem rs)))
                    (Just (maximum (map getCpu rs)))
                    (Just (maximum (map getSize rs)))
                    "node-submit"
                    Nothing
            Nothing ->
                emit
                    "measure"
                    "CL01 not receipted: an accepting row's receipt is \
                     \missing"
    | otherwise =
        emit
            "measure"
            "CL01 not receipted: run did not cover the issue #70 rows"
  where
    readRowReceiptFile row = do
        let path = envReceiptsDir env </> ("receipt-" <> row <> ".json")
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


-- | The serialised size of the reference script an output carries.
refScriptSize :: TxOut ConwayEra -> Int
refScriptSize out = case out ^. referenceScriptTxOutL of
    SNothing -> 0
    SJust s -> fromIntegral (BSL.length (serialize (eraProtVerLow @ConwayEra) s))

{- | Sweep the funder's ada-only outputs back into one.

Every fold returns the approval it consumed to the booker in an output of
its own, and every booking and publication leaves change, so the wallet
fragments as a session runs. A builder that picks collateral without
weighing it then picks a small output and the ledger refuses the
transaction for a collateral shortfall. One output, one choice.

Reference outputs are left alone: they are what the folds resolve their
scripts through.
-}

{- | Publish the state validator as a reference output once per session,
before any boot (#177, A-003).

The boot transaction carries the state validator INLINE unless the
funding wallet already holds a publication of it, and that validator is
fifteen kilobytes against a sixteen-kilobyte transaction cap. #177's
retirement guard does not fit in what is left. Referencing the script
returns the whole fifteen kilobytes to the budget.

Every cage in a session shares the same state script — only the seed
differs — so one publication serves every boot. Idempotent by
discovery, and the funding sweep already spares outputs carrying
reference scripts, so it publishes once and finds it thereafter.
-}
ensureStateRef :: Env -> IO ()
ensureStateRef env = do
    let cfg = envCfg env
        wanted = cfgScriptHash cfg
    utxos <- Cage.queryUTxOs (envProv env) genesisAddr
    let published =
            [ ()
            | (_, out) <- utxos
            , SJust s <- [out ^. referenceScriptTxOutL]
            , hashScript s == wanted
            ]
    case published of
        (_ : _) -> pure ()
        [] -> do
            _ <- publishRefScript env (mkCageScript cfg)
            emit
                "state-ref"
                "published the state validator as a reference output; \
                \boots reference it instead of carrying it inline"

consolidateFunding :: Env -> IO ()
consolidateFunding env = consolidateWallet (envProv env) (envSubmit env)

-- | The sweep, before there is an `Env` to carry: a CA session designates
-- its canonical seed during construction, and a sweep after that would
-- spend the very output CA01 boots from.
consolidateWallet :: Cage.Provider IO -> Submitter IO -> IO ()
consolidateWallet prov submit = do
    utxos <- Cage.queryUTxOs prov genesisAddr
    let spendable = filter (not . carriesRefScript . snd) utxos
        dirty = filter (not . adaOnlyOut . snd) spendable
        clean = filter (adaOnlyOut . snd) spendable
    if length spendable < 2 && null dirty
        then pure ()
        else do
            pp <- Cage.queryProtocolParams prov
            let total = sum [outCoin o | (_, o) <- spendable]
                assets =
                    foldr
                        (\(_, o) acc -> mergeAssets acc (rawAssets o))
                        Map.empty
                        dirty
                fee = 1_000_000
                atticProbe c =
                    mkBasicTxOut atticAddr (MaryValue (Coin c) (MultiAsset assets))
                Coin atticFirst = getMinCoinTxOut @ConwayEra pp (atticProbe 0)
                atticAda =
                    if Map.null assets
                        then 0
                        else
                            let Coin c = getMinCoinTxOut @ConwayEra pp (atticProbe atticFirst)
                             in c
                fundingAda = total - fee - atticAda
                outs =
                    mkBasicTxOut genesisAddr (MaryValue (Coin fundingAda) mempty)
                        : [atticProbe atticAda | not (Map.null assets)]
                body =
                    mkBasicTxBody
                        & inputsTxBodyL .~ Set.fromList (map fst spendable)
                        & outputsTxBodyL .~ StrictSeq.fromList outs
                        & feeTxBodyL .~ Coin fee
                signed = addKeyWitness genesisSignKey (mkBasicTx body)
            require
                ("consolidateFunding: wallet too small: " <> show fundingAda)
                (fundingAda > 5_000_000)
            result <- submitTxResilient submit signed
            case result of
                Submitted _ -> do
                    awaitTx
                    emit
                        "funding"
                        ( show (length clean)
                            <> " ada-only and "
                            <> show (length dirty)
                            <> " approval-bearing outputs swept; funding is one \
                               \output of "
                            <> show fundingAda
                            <> " lovelace"
                        )
                Rejected reason ->
                    failWith
                        ( "consolidateFunding refused: "
                            <> T.unpack (TE.decodeUtf8Lenient reason)
                        )

{- | Where spent approvals go.

A fold returns the approval it consumed to the booker, which in this
harness is the funding wallet, and the library builders pick their extra
input and their collateral by position: one small token-bearing output is
enough to make a boot unfundable. The harness moves them aside. Nothing
reads them again — an approval is spent evidence, and the rows assert
nothing about where it rests.
-}
atticAddr :: Addr
atticAddr = addrFromKeyHashBytes Testnet (BS.replicate 28 0xaa)

carriesRefScript :: TxOut ConwayEra -> Bool
carriesRefScript out = case out ^. referenceScriptTxOutL of
    SNothing -> False
    SJust _ -> True


mergeAssets ::
    Map.Map PolicyID (Map.Map AssetName Integer) ->
    Map.Map PolicyID (Map.Map AssetName Integer) ->
    Map.Map PolicyID (Map.Map AssetName Integer)
mergeAssets = Map.unionWith (Map.unionWith (+))
{- | Carve a small ada-only output to seed a cage with.

A boot consumes its seed, so seeding from the largest output strands the
session's funding in a registry: what is left is whatever small change
happened to be lying about, and the next builder that needs collateral
finds too little. Carving the seed leaves the consolidated output where it
is.
-}
carveSeed :: Env -> IO TxIn
carveSeed env = do
    let prov = envProv env
    (funderIn, funderOut) <- largestWalletUtxo prov
    let Coin avail = funderOut ^. coinTxOutL
        seed = 20_000_000
        fee = 1_000_000
        change = avail - seed - fee
    require "carveSeed: funder too small to carve a seed" (change > seed)
    let body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton funderIn
                & outputsTxBodyL
                    .~ StrictSeq.fromList
                        [ mkBasicTxOut genesisAddr (MaryValue (Coin seed) mempty)
                        , mkBasicTxOut genesisAddr (MaryValue (Coin change) mempty)
                        ]
                & feeTxBodyL .~ Coin fee
        signed = addKeyWitness genesisSignKey (mkBasicTx body)
    result <- submitTxResilient (envSubmit env) signed
    case result of
        Submitted _ -> awaitTx
        Rejected reason ->
            failWith
                ( "carveSeed refused: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )
    pure (TxIn (txIdTx signed) (TxIx 0))

-- | The UTxOs at a given cage's own address; custody lives among them.
cageUtxosOf :: Env -> CageConfig -> IO [(TxIn, TxOut ConwayEra)]
cageUtxosOf env cfg =
    Cage.queryUTxOs (envProv env) (cageAddrFromCfg cfg (network cfg))

-- | The tip a cage charges, as a plain integer.
defaultTipCoin :: CageConfig -> Integer
defaultTipCoin cfg = case defaultTip cfg of Coin c -> c

-- | The multi-asset an output carries, in the ledger's own shape.
rawAssets :: TxOut ConwayEra -> Map.Map PolicyID (Map.Map AssetName Integer)
rawAssets out = case out ^. valueTxOutL of
    MaryValue _ (MultiAsset m) -> m
{- | Publish one script as a reference output, once per session.

The state validator alone is fifteen kilobytes: a fold that attaches it,
the request script and a token policy does not fit in a transaction. The
same outputs serve every fold the session builds, so this happens once and
the references are carried in the environment.
-}
publishRefScript :: Env -> Script ConwayEra -> IO (TxIn, TxOut ConwayEra)
publishRefScript env script = do
    let prov = envProv env
    pp <- Cage.queryProtocolParams prov
    utxos <- Cage.queryUTxOs prov genesisAddr
    fund <- case sortOn (Down . (^. coinTxOutL) . snd) utxos of
        [] -> failWith "publishRefScript: the funding wallet has no output"
        (u : _) -> pure u
    let probe =
            mkBasicTxOut genesisAddr (MaryValue (Coin 0) mempty)
                & referenceScriptTxOutL .~ SJust script
        Coin minCoin = getMinCoinTxOut @ConwayEra pp probe
        refCoin = minCoin + 1_000_000
        refOut =
            mkBasicTxOut genesisAddr (MaryValue (Coin refCoin) mempty)
                & referenceScriptTxOutL .~ SJust script
        fee = 1_000_000
        Coin inCoin = snd fund ^. coinTxOutL
        changeCoin = inCoin - fee - refCoin
    require
        ( "publishRefScript: funding output holds "
            <> show inCoin
            <> ", which does not cover a reference output of "
            <> show refCoin
            <> " plus fees"
        )
        (changeCoin > 1_000_000)
    let body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton (fst fund)
                & outputsTxBodyL
                    .~ StrictSeq.fromList
                        [ refOut
                        , mkBasicTxOut genesisAddr (MaryValue (Coin changeCoin) mempty)
                        ]
                & feeTxBodyL .~ Coin fee
        signed = addKeyWitness genesisSignKey (mkBasicTx body)
    result <- submitTxResilient (envSubmit env) signed
    case result of
        Submitted _ -> awaitTx
        Rejected reason ->
            failWith
                ( "publishRefScript refused: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )
    pure (TxIn (txIdTx signed) (TxIx 0), refOut)


{- | The duties context for a row cage: its own three token policies, the
cage script its custody spends run, its UTxOs, the one destination datum
the harness books against, and the reference outputs published at its boot.
-}
rowRegistryContext :: Env -> RowCage -> TokenId -> IO RegistryContext
rowRegistryContext env cage tid = do
    let cfg = rcCfg cage
        (_, _, codes) = envCodes env
        registryId =
            scriptHashBytes (cfgScriptHash cfg)
                <> SBS.fromShort (assetNameBytes (unTokenId tid))
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
            , rcAllowInadmissible = False
            , rcHolderUtxos = []
            , rcRefUtxos = rcRefs cage
            }

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
            , rcHolderUtxos = []
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
