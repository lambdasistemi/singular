{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Main
Description : The LT retirement rows on a real devnet (issue #66)
License     : Apache-2.0

Executes the seven in-scope contract rows @LT01..LT03, LT05, LT06, LT08,
LT09@ against a real devnet node, one narration line per step, and verifies
what the chain then holds. The rows were proved at model level by epic 15
(@beginRetirement@) and at Aiken level by this slice's @application.tests@;
this is the first time they meet a ledger, so what is under test is the
/composition/: can a real transaction present the context the Aiken tests
constructed, and do the naming scripts and the merged codec agree the way
the correspondence record claims?

Ledger realisation (offchain\/naming-correspondence.md, t66 entries):

  * the record is a UTxO at the naming application validator carrying
    the four-field naming datum inline (merged 'Naming.Datum' codec)
    and exactly one representative token under the applied representative
    policy (the 34-byte representative name for the retiring controller at
    incarnation zero, minted by the connected fold that burns the claim's
    insert approval — the genuine t77 shape (the former stand-in removed);

  * authorization is the controller's payment key among the required
    signers, or at least `threshold` distinct stored quorum members
    among them (@LT01@ carries no quorum signature, @LT02@ carries no
    controller signature, @LT03@ is one distinct signature short);

  * custody is the new completion-only script in @naming-onchain/@
    whose only spending path burns what it holds: the @Retire@ spend
    places the representative there, and creating that output executes
    no receiving script — @LT08@'s refusal comes from the @Retire@
    spend checking the destination;

  * @LT05@ and @LT06@ are not retirements: they are @Maintain@ actions
    carrying quorum signatures and no controller signature, refused on
    `controller-signature` by the existing path — the rows that prove
    quorum power is bounded to ending the name;

  * @LT09@ retires a record a real earlier @LT01@ already consumed, so
    the ledger itself refuses the spent output (the LC06 precedent).

Every refusal is asserted on its reason: the node must report a
phase-2 PlutusFailure naming the application validator's script
hash — except @LT09@, where the ledger itself refuses the consumed
output in phase 1. A fee, missing-input or malformed-CBOR refusal
fails the run.

Controls (env @RETIREMENT_CONTROL@, falling back to @RECOVERY_CONTROL@):
@valid@ makes LT03's transaction actually valid (the missing quorum
member added), so it succeeds and the refusal guard must fail the run;
@wrong-reason@ matches every refusal against a marker that cannot occur,
so the reason matcher must fail the run naming what came back. Both exit
1 by design, after executing rows.

Hermetic run (D-011), from @offchain/@:

> blueprint="$(nix build --quiet --no-link --print-out-paths ../naming-onchain#plutus-blueprint)"
> TMPDIR=/tmp/s66-devnet NAMING_BLUEPRINT="$blueprint" nix run --quiet .#retirement-rows
-}
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async, cancel, poll)
import Control.Exception
    ( ErrorCall (..)
    , SomeException
    , displayException
    , throwIO
    , try
    )
import Control.Applicative ((<|>))
import Control.Monad (forM, unless, when)
import Crypto.Hash (Blake2b_256, Digest, hash)
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Aeson (FromJSON (..), eitherDecode', withObject, (.:))
import Data.List (isInfixOf, sortBy, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust, fromMaybe, isJust)
import Data.Ord (Down (..), comparing)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Sequence.Strict qualified as StrictSeq
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.IO (BufferMode (..), hPutStrLn, hSetBuffering, stderr, stdout)

-- (NOTE-038.1) the five rival decisions live in exactly one shared module;
-- the driver and the offline check both call them, neither owns a copy.
import RivalDriverLogic

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address (Addr (..), serialiseAddr)
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.Scripts.Data (Data (..), Datum (..), binaryDataToData)
import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body (
    collateralInputsTxBodyL,
    feeTxBodyL,
    inputsTxBodyL,
    mintTxBodyL,
    mkBasicTxBody,
    outputsTxBodyL,
    reqSignerHashesTxBodyL,
    scriptIntegrityHashTxBodyL,
 )
import Cardano.Ledger.Api.Tx.In (TxIn (..))
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    addrTxOutL,
    coinTxOutL,
    datumTxOutL,
    getMinCoinTxOut,
    mkBasicTxOut,
    referenceScriptTxOutL,
    valueTxOutL,
 )
import Cardano.Ledger.Api.Tx.Wits (
    Redeemers (..),
    rdmrsTxWitsL,
    scriptTxWitsL,
 )
import Cardano.Ledger.BaseTypes (Inject (..), Network (..), StrictMaybe (SJust), TxIx (..))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (Script, extractHash)
import Cardano.Ledger.Credential (Credential (..), StakeReference (..))
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..), PolicyID (..))
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.TxIn (TxId (..))

import Cardano.MPFS.Cage.Blueprint (
    applyBytesParam,
    extractCompiledCode,
    loadBlueprint,
 )
import Cardano.MPFS.Cage.Config (CageConfig (..))
import Cardano.MPFS.Cage.Ledger (
    AssetName (..),
    Coin (..),
    ConwayEra,
    PParams,
    Root (..),
    TokenId (..),
 )
import Cardano.MPFS.Cage.Provider qualified as Cage
import Cardano.MPFS.Cage.Trie (Trie (..), TrieManager (..))
import Cardano.MPFS.Cage.Trie.PureManager (mkPureTrieManager)
import Cardano.MPFS.Cage.TxBuilder.Boot (bootTokenImpl)
import Cardano.MPFS.Cage.TxBuilder.ConnectedFold (
    ConnectedFoldArgs (..),
    ConnectedMint (..),
    ConnectedSpend (..),
    RawRedeemer (..),
    connectedFoldTx,
    syncFoldedRequests,
 )
import Cardano.MPFS.Cage.TxBuilder.Internal (
    evaluateAndBalance,
    addrKeyHashBytes,
    addrWitnessKeyHash,
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    computeScriptHash,
    computeScriptIntegrity,
    extractCageDatum,
    findStateUtxo,
    mkCageScript,
    mkInlineDatum,
    mkRequestScript,
    requestAddrFromCfg,
    scriptFromBytes,
    scriptHashBytes,
    spendingIndex,
    txInToRef,
 )
import Cardano.MPFS.Cage.TxBuilder.Request (requestInsertImpl)
import Cardano.MPFS.Cage.Types (
    CageDatum (..),
    OnChainRoot (..),
    OnChainTokenState (..),
 )
import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup (
    addKeyWitness,
    devnetMagic,
    enterpriseAddr,
    genesisAddr,
    genesisDir,
    genesisSignKey,
    keyHashFromSignKey,
    mkSignKey,
 )
import Cardano.Node.Client.Ledger (ConwayTx)
import Cardano.Node.Client.N2C.Connection (
    newLSQChannel,
    newLTxSChannel,
    runNodeClient,
 )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
import Cardano.Node.Client.Provider qualified as N2C
import Cardano.Node.Client.Submitter (SubmitResult (..), Submitter (..))
import Naming.Datum
import Naming.Register
import Naming.Wire
    ( Address (..)
    , WireData (..)
    , addressBytes
    , decodeAddress
    )

-- ---------------------------------------------------------
-- Run modes
-- ---------------------------------------------------------

data Mode
    = MainRun
    | ControlValid
    | ControlWrongReason
    deriving (Eq, Show)

readMode :: IO Mode
readMode = do
    retirement <- lookupEnv "RETIREMENT_CONTROL"
    recovery <- lookupEnv "RECOVERY_CONTROL"
    case retirement <|> recovery of
        Just "valid" -> pure ControlValid
        Just "wrong-reason" -> pure ControlWrongReason
        Just other
            | not (null other) ->
                failWith ("unknown RETIREMENT_CONTROL value " <> other)
        _ -> pure MainRun

wrongReasonMarker :: String
wrongReasonMarker =
    "wrong-reason-control marker that no node reason can ever contain"

-- ---------------------------------------------------------
-- Fixture seeds (each exactly 32 bytes for mkSignKey)
-- ---------------------------------------------------------

oldSeed, quorum1Seed, quorum2Seed, destSeed, wrongDestSeed :: ByteString
oldSeed = "s66-old-controller00000000000000"
quorum1Seed = "s66-quorum-member-one00000000000"
quorum2Seed = "s66-quorum-member-two00000000000"
destSeed = "s66-destination00000000000000000"
wrongDestSeed = "s66-wrong-custody0000000000000000"

-- ---------------------------------------------------------
-- Ledger-shape constants
-- ---------------------------------------------------------

flatFee :: Integer
flatFee = 10_000_000

maxUnits :: ExUnits
maxUnits = ExUnits 3_000_000 200_000_000

claimCoin :: Integer
claimCoin = 25_000_000

-- ---------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------

main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    mode <- readMode
    case mode of
        MainRun ->
            emit
                "row"
                "issue #66: the LT retirement rows on a real ledger"
        ControlValid ->
            emit
                "control"
                "valid-transaction control: LT03 made actually valid, so it \
                \must succeed and the refusal guard must fail the run"
        ControlWrongReason ->
            emit
                "control"
                "wrong-reason control: refusals matched against a marker \
                \that cannot occur, so the matcher must fail the run"
    blueprintPath <- requireEnv "NAMING_BLUEPRINT"
    mpfsPath <- requireEnv "MPFS_BLUEPRINT"
    outcome <-
        try (runMode mode blueprintPath mpfsPath) :: IO (Either SomeException ())
    case outcome of
        Right () -> pure ()
        Left e -> do
            hPutStrLn stderr ("retirement-rows: FAILED: " <> displayException e)
            exitWith (ExitFailure 1)

-- ---------------------------------------------------------
-- The run
-- ---------------------------------------------------------

runMode :: Mode -> FilePath -> FilePath -> IO ()
runMode mode blueprintPath mpfsPath = do
    ebp <- loadBlueprint blueprintPath
    bp <- either failWith pure ebp
    embp <- loadBlueprint mpfsPath
    mbp <- either failWith pure embp
    appBytes <- case extractCompiledCode "application.application" bp of
        Just bytes -> pure bytes
        Nothing ->
            failWith
                "application.application compiled code not found in the \
                \naming blueprint"
    -- The custody script is created, never spent, by this slice: its
    -- bytes are needed only to derive the address Retire must place
    -- the representative at.
    custodyBytes <- case extractCompiledCode "retirement_custody.retirement_custody" bp of
        Just bytes -> pure bytes
        Nothing ->
            failWith
                "retirement_custody.retirement_custody compiled code not \
                \found in the naming blueprint"
    repUnappliedBytes <- case extractCompiledCode "representative.representative" bp of
        Just bytes -> pure bytes
        Nothing ->
            failWith
                "representative.representative compiled code not found in \
                \the naming blueprint"
    stateBytes <- case extractCompiledCode "state.state" mbp of
        Just bytes -> pure bytes
        Nothing -> failWith "state.state compiled code not found in the MPFS blueprint"
    requestBytes <- case extractCompiledCode "request.request" mbp of
        Just bytes -> pure bytes
        Nothing -> failWith "request.request compiled code not found in the MPFS blueprint"
    gDir <- genesisDir
    withCardanoNode gDir $ \sock _startMs -> do
        lsqCh <- newLSQChannel 16
        ltxsCh <- newLTxSChannel 16
        nodeThread <- async $ runNodeClient devnetMagic sock lsqCh ltxsCh
        threadDelay 3_000_000
        verifyConnection nodeThread
        let prov = adaptProvider (mkN2CProvider lsqCh)
            submit = mkN2CSubmitter ltxsCh
        pp <- Cage.queryProtocolParams prov
        let script = scriptFromBytes "naming-application" appBytes
            appHash = computeScriptHash appBytes
            appHex = hex (scriptHashBytes appHash)
            appAddr = Addr Testnet (ScriptHashObj appHash) StakeRefNull
            appPolicy = PolicyID appHash
            custodyHash = computeScriptHash custodyBytes
            custodyHex = hex (scriptHashBytes custodyHash)
            custodyAddr = Addr Testnet (ScriptHashObj custodyHash) StakeRefNull
        checkPinnedApplication appHex
        checkPinnedCustody custodyHex
        emit
            "identity"
            ( "application validator hash 0x"
                <> appHex
                <> " (0 parameters: the pinned manifest identity is the \
                   \applied identity this run carries on chain); custody script \
                   \hash 0x"
                <> custodyHex
                <> " (0 parameters: the only address Retire may place the \
                   \representative at)"
            )
        let oldHash = addrKeyHashBytes (enterpriseAddr (keyHashFromSignKey (mkSignKey oldSeed)))
            oldAddr = enterpriseAddr (keyHashFromSignKey (mkSignKey oldSeed))
            quorum1Hash = addrKeyHashBytes (enterpriseAddr (keyHashFromSignKey (mkSignKey quorum1Seed)))
            quorum2Hash = addrKeyHashBytes (enterpriseAddr (keyHashFromSignKey (mkSignKey quorum2Seed)))
            repBytes = representativeName oldHash freshIncarnation
            destAddr =
                enterpriseAddr (keyHashFromSignKey (mkSignKey destSeed))
            wrongDestAddr =
                enterpriseAddr (keyHashFromSignKey (mkSignKey wrongDestSeed))
            mustCodec bytes = case decodeAddress bytes of
                Just a -> a
                Nothing ->
                    error
                        "fixture: a devnet address does not decode as the contract's canonical address"
            oldCodec = mustCodec (serialiseAddr oldAddr)
            destCodec = mustCodec (serialiseAddr destAddr)
            -- The stored commitment is 32 bytes of fixed fixture; Retire
            -- never inspects it, but the datum must stay well-formed.
            storedC = nextControlCommitmentOf (serialiseAddr destAddr)
            mkDatum =
                NamingDatum
                    { controlAddress = oldCodec
                    , paymentDestination = NoDestination
                    , nextControlCommitment = storedC
                    , retirementQuorum =
                        RetirementQuorum
                            { quorumMembers = [quorum1Hash, quorum2Hash]
                            , quorumThreshold = 2
                            }
                    }
            -- The duplicate-member record: the stored quorum names one
            -- member twice and a second once, at threshold two.
            -- Well-formed by the existing rules (distinct 2), but the
            -- duplicated member alone must not retire.
            mkDatumDup =
                mkDatum
                    { retirementQuorum =
                        RetirementQuorum
                            { quorumMembers = [quorum1Hash, quorum1Hash, quorum2Hash]
                            , quorumThreshold = 2
                            }
                    }
        let repUnappliedHex =
                hex (scriptHashBytes (computeScriptHash repUnappliedBytes))
            repAppliedBytes =
                applyBytesParam (scriptHashBytes appHash) repUnappliedBytes
            repAppliedHash = computeScriptHash repAppliedBytes
            repAppliedHex = hex (scriptHashBytes repAppliedHash)
            repAppliedPolicy = PolicyID repAppliedHash
            repAppliedScript =
                scriptFromBytes "representative" repAppliedBytes
            repTokens =
                Map.singleton
                    repAppliedPolicy
                    (Map.singleton (AssetName (SBS.toShort repBytes)) 1)
        checkPinnedRepresentative repUnappliedHex
        emit
            "identity"
            ( "representative applied policy 0x"
                <> repAppliedHex
                <> " (the applied mint identity this run mints representatives under)"
            )
        tm <- mkPureTrieManager
        (cfg, tok) <- bootRetirementCage prov submit tm stateBytes requestBytes (SBS.toShort (scriptHashBytes repAppliedHash))
        createTrie tm tok
        emit "split" "splitting the genesis wallet into funding UTxOs"
        pool <- splitGenesis prov submit 80
        poolRef <- newIORef pool
        scriptRefs <- publishRetirementRefs prov submit pp poolRef cfg tok script repAppliedScript
        rivalRef <- newIORef Nothing
        rivalCtxRef <- newIORef Nothing
        rivalSeedRef <- newIORef Nothing
        newRootRef <- newIORef Nothing
        let env =
                Env
                    { envProv = prov
                    , envRivalAnchor = rivalRef
                    , envRivalCtx = rivalCtxRef
                    , envRivalBSeed = rivalSeedRef
                    , envNewRootRef = newRootRef
                    , envStateBytes = stateBytes
                    , envRequestBytes = requestBytes
                    , envSubmit = submit
                    , envPp = pp
                    , envPool = poolRef
                    , envScript = script
                    , envScriptHash = appHash
                    , envAppHex = appHex
                    , envAppPolicy = appPolicy
                    , envAppAddr = appAddr
                    , envOldHash = oldHash
                    , envQuorum1Hash = quorum1Hash
                    , envQuorum2Hash = quorum2Hash
                    , envRepBytes = repBytes
                    , envRepTokens = repTokens
                    , envRepPolicy = repAppliedPolicy
                    , envRepScript = repAppliedScript
                    , envRepHash = repAppliedHash
                    , envRepHex = repAppliedHex
                    , envCfg = cfg
                    , envTok = tok
                    , envTrie = tm
                    , envRefUtxos = scriptRefs
                    , envDestCodec = destCodec
                    , envWrongDestAddr = wrongDestAddr
                    , envCustodyHash = custodyHash
                    , envCustodyHex = custodyHex
                    , envCustodyAddr = custodyAddr
                    , envDatum = mkDatum
                    , envDatumDup = mkDatumDup
                    }
        emit "setup" "creating the three retirement records (accept1, accept2, refusals)"
        (txA1, recAccept1) <- setupRecoveryRecord env mkDatum "accept1" "rt-accept1"
        _ <- waitConfirmation (txA1 <> " (setup: accept1)")
        (txA2, recAccept2) <- setupRecoveryRecord env mkDatum "accept2" "rt-accept2"
        _ <- waitConfirmation (txA2 <> " (setup: accept2)")
        (txRef, recRefusals) <- setupRecoveryRecord env mkDatum "refusals" "rt-refusals"
        _ <- waitConfirmation (txRef <> " (setup: refusals)")
        (txDup, recDuplicates) <- setupRecoveryRecord env mkDatumDup "duplicates" "rt-duplicates"
        _ <- waitConfirmation (txDup <> " (setup: duplicates)")
        emit
            "setup"
            ( "records live at the application validator 0x"
                <> appHex
                <> ": accept1="
                <> showIn recAccept1
                <> " accept2="
                <> showIn recAccept2
                <> " refusals="
                <> showIn recRefusals
                <> " duplicates="
                <> showIn recDuplicates
                <> "; each carries the single representative 0x"
                <> hex repBytes
                <> " under the applied representative policy 0x"
                <> repAppliedHex
                <> " with control 0x"
                <> hex (serialiseAddr oldAddr)
                <> " and quorum threshold 2 over two distinct members; \
                   \custody is the script 0x"
                <> custodyHex
            )
        case mode of
            MainRun -> runRows env recAccept1 recAccept2 recRefusals recDuplicates
            ControlValid -> runControlValid env recRefusals
            ControlWrongReason -> runControlWrongReason env recAccept1 recRefusals
        cancel nodeThread

data Env = Env
    { envProv :: Cage.Provider IO
    , envSubmit :: Submitter IO
    , envPp :: PParams ConwayEra
    , envPool :: IORef [(TxIn, TxOut ConwayEra)]
    , envScript :: Script ConwayEra
    , envScriptHash :: ScriptHash
    , envAppHex :: String
    , envAppPolicy :: PolicyID
    , envAppAddr :: Addr
    , envOldHash :: ByteString
    , envQuorum1Hash :: ByteString
    , envQuorum2Hash :: ByteString
    , envRepBytes :: ByteString
    , envRepTokens :: Map.Map PolicyID (Map.Map AssetName Integer)
    , envRepPolicy :: PolicyID
    , envRepScript :: Script ConwayEra
    , envRepHash :: ScriptHash
    , envRepHex :: String
    , envCfg :: CageConfig
    , envTok :: TokenId
    , envTrie :: TrieManager IO
    , envRefUtxos :: [(TxIn, TxOut ConwayEra)]
    , envDestCodec :: Address
    , envWrongDestAddr :: Addr
    , envCustodyHash :: ScriptHash
    , envCustodyHex :: String
    , envCustodyAddr :: Addr
    , envDatum :: NamingDatum
    , envDatumDup :: NamingDatum
    , envRivalAnchor :: IORef (Maybe (TxIn, TxOut ConwayEra))
    , envRivalCtx :: IORef (Maybe RivalCtx)
    , envRivalBSeed :: IORef (Maybe TxIn)
    , envNewRootRef :: IORef (Maybe Root)
    , envStateBytes :: SBS.ShortByteString
    , envRequestBytes :: SBS.ShortByteString
    }

-- ---------------------------------------------------------
-- The seven in-scope rows
-- ---------------------------------------------------------

runRows :: Env -> TxIn -> TxIn -> TxIn -> TxIn -> IO ()
runRows env recAccept1 recAccept2 recRefusals recDuplicates = do
    snapRefusals <- mustSnap env recRefusals
    snapDuplicates <- mustSnap env recDuplicates
    -- The four refusals against the live refusals record.
    rowLT03 MainRun env snapRefusals
    rowLT05 env snapRefusals
    rowLT06 env snapRefusals
    rowLT08 env snapRefusals
    -- The duplicate-stored-member refusal against its own record.
    rowLT03Dup env snapDuplicates
    -- LT01 accepts, consuming accept1 into custody.
    snapA1 <- mustSnap env recAccept1
    -- (NOTE-027.1) capture A's exact live state input BEFORE the rival
    -- boot installs B.
    (aStateIn, aStateOut) <- queryRetirementState env
    -- (NOTE-039.2) retain A's authentic state NFT identity (policy AND
    -- token name: A and B share the state policy, so the policy alone
    -- cannot exclude A) and prove it present at quantity one in the
    -- captured pre-boot state output.
    let aPolicyId = cagePolicyIdFromCfg (envCfg env)
        aTokenName = unTokenId (envTok env)
        aNftQty = case aStateOut ^. valueTxOutL of
            MaryValue _ (MultiAsset ma) ->
                case Map.lookup aPolicyId ma >>= Map.lookup aTokenName of
                    Just q -> q
                    Nothing -> 0
    unless (aNftQty == 1) $
        failWith "A-NFT: the authentic A state asset is not present at quantity one in the pre-boot state output"
    -- (NOTE-017/019) the single rival activation.
    let repAppliedPolicyBytes =
            SBS.toShort (scriptHashBytes (policyID (envRepPolicy env)))
    runRivalSetup env repAppliedPolicyBytes
    mVariant <- readRivalVariant
    -- (NOTE-038.1) the ordinary/rival dispatch is the shared planMode
    -- decision; a witness terminal returns without ordinary-row fallthrough.
    case planMode mVariant of
        -- No variant: the ordinary full-row behaviour is unchanged.
        FullRows -> do
            signedLT01 <- rowLT01 env snapA1
            rowLT09 env recAccept1 signedLT01
            snapA2 <- mustSnap env recAccept2
            _ <- rowLT02 env snapA2
            finalNoTrace env recRefusals
            emit
                "complete"
                ( "the LT retirement rows executed on a real devnet; every refusal "
                    <> "attributed to its reason, custody and the record's end proved "
                    <> "from the chain, the state after the refusals unchanged"
                )
        -- RIVAL WITNESS TERMINAL (NOTE-026/027): build and sign the target
        -- body OUTSIDE any expected-refusal catcher, submit directly, and
        -- branch on the typed Submitted/Rejected result with exact
        -- script-hash attribution and post-failure liveness queries.
        WitnessTerminal variant expectation -> do
            tx <- retireTx env snapA1 (envCustodyAddr env) [envOldHash env]
            let signed = addKeyWitness (mkSignKey oldSeed) (addKeyWitness genesisSignKey tx)
            unless
                (Set.singleton (addrWitnessKeyHash (envOldHash env)) == (signed ^. bodyTxL . reqSignerHashesTxBodyL))
                $ failWith "LT01-rival: required signers must be exactly the controller payment key"
            when
                ( any
                    (`Set.member` (signed ^. bodyTxL . reqSignerHashesTxBodyL))
                    [addrWitnessKeyHash (envQuorum1Hash env), addrWitnessKeyHash (envQuorum2Hash env)]
                )
                $ failWith "LT01-rival: no quorum member may be among the required signers"
            let targetTxid = txIdHex signed
                succTxId (TxIn tid _ix) = tid
                isLiveAt addr i = do
                    utxos' <- Cage.queryUTxOs (envProv env) addr
                    pure (any ((== i) . fst) utxos')
            emit "target" ("target body txid " <> targetTxid)
            -- (NOTE-027.1) mechanical anchor assertions from the SIGNED
            -- body: B's exact pre-fold state input present; A's exact
            -- pre-boot state input absent (absent from this transaction,
            -- not from the ledger).
            -- (NOTE-030.2) the exact installed target anchor is selected BY
            -- VARIANT: authentic variants use B's bundle state; the forged
            -- control uses its exact saved tokenless anchor (it intentionally
            -- has no RivalCtx) and must still reach typed submission.
            mRivalCtx2 <- readIORef (envRivalCtx env)
            mForgedAnchor <- readIORef (envRivalAnchor env)
            -- (NOTE-038.2) the shared anchor decision from the OBSERVED
            -- availability; its result maps back to the same observed input.
            -- A forged case needs no RivalCtx to reach typed submission.
            let anchorAvail =
                    AnchorAvailability
                        { bundleInstalled = isJust mRivalCtx2
                        , forgedSaved = isJust mForgedAnchor
                        }
            (bAnchorIn, _bAnchorOut) <- case selectAnchor variant anchorAvail of
                Right AnchorFromBundle -> case mRivalCtx2 of
                    Just ctx -> pure (rcState ctx)
                    Nothing -> failWith "rival bundle missing after setup"
                Right AnchorFromForgedSave -> case mForgedAnchor of
                    Just forged -> pure forged
                    Nothing -> failWith "forged anchor: installed anchor missing"
                Left err -> failWith err
            let bodyInputs = signed ^. bodyTxL . inputsTxBodyL
            unless (Set.member bAnchorIn bodyInputs) $
                failWith "anchor assertion: B's state input is absent from the target body"
            when (Set.member aStateIn bodyInputs) $
                failWith "anchor assertion: A's pre-boot state input is PRESENT in the target body (must be absent)"
            emit "anchors" "B's state input present; A's state input absent from the target transaction"
            -- (NOTE-030.3) liveness: the exact attempted record input and the
            -- exact attempted anchor input must both be currently live before
            -- submission.
            recordLiveBefore <- isLiveAt (envAppAddr env) (snapIn snapA1)
            anchorLiveBefore <- isLiveAt (cageAddrFromCfg (envCfg env) Testnet) bAnchorIn
            unless (recordLiveBefore && anchorLiveBefore) $
                failWith "liveness assertion: attempted record or anchor input is no longer live before submission"
            -- (NOTE-026.2) submit directly; branch only on the typed result
            result <- submitTx (envSubmit env) signed
            emit "submit" ("raw submit result: " <> show result)
            case result of
                Submitted _ ->
                    case expectation of
                        ExpectAccept -> do
                            emit "submit" ("SUBMITTED: " <> targetTxid)
                            _ <- waitConfirmation targetTxid
                            assertCustody env "LT01-witness" signed
                            assertGone env snapA1 "LT01-witness"
                            -- (NOTE-029.4) successor proof: select the output
                            -- created by the TARGET txid at B's state address
                            -- carrying B's exact policy+token at quantity one
                            -- (excluding every other asset), root equal to the
                            -- recorded fold result; prove the old exact B
                            -- anchor is consumed.
                            mRivalCtx3 <- readIORef (envRivalCtx env)
                            (bAnchorInNow, _) <- case mRivalCtx3 of
                                Just ctx -> pure (rcState ctx)
                                Nothing -> failWith "B-successor: bundle missing"
                            let stateAddr = cageAddrFromCfg (rcCfg (fromJust mRivalCtx3)) Testnet
                                policyB = cagePolicyIdFromCfg (rcCfg (fromJust mRivalCtx3))
                                tokB = rcTok (fromJust mRivalCtx3)
                            liveNow <- Cage.queryUTxOs (envProv env) stateAddr
                            let targetTxId = txIdTx signed
                                succs =
                                    [ (i, o)
                                    | (i, o) <- liveNow
                                    , succTxId i == targetTxId
                                    ]
                            mRoot <- readIORef (envNewRootRef env)
                            case (mRoot, succs) of
                                (Just (Root want), [(succIn, succOut)]) -> do
                                    -- (NOTE-038.4) derive every successor fact
                                    -- from the exact target-created output and
                                    -- ledger observations; comments and constants
                                    -- are not observations.
                                    let valueAssets = case succOut ^. valueTxOutL of
                                            MaryValue _ (MultiAsset ma) ->
                                                [ (pid, an, q)
                                                | (pid, perPolicy) <- Map.toAscList ma
                                                , (an, q) <- Map.toAscList perPolicy
                                                , q /= 0
                                                ]
                                        bTokenQty =
                                            case
                                                [ q
                                                | (pid, an, q) <- valueAssets
                                                , pid == policyB
                                                , an == unTokenId tokB
                                                ]
                                            of
                                                (q : _) -> q
                                                [] -> 0
                                        rootOk = case extractCageDatum succOut of
                                            Just (StateDatum st) -> unOnChainRoot (stateRoot st) == want
                                            _ -> False
                                        facts =
                                            SuccessorFacts
                                                { sfJoinedToTargetTxId = succTxId succIn == targetTxId
                                                , sfAtBStateAddress = succOut ^. addrTxOutL == stateAddr
                                                , sfExactBPolicy = any (\(pid, _, _) -> pid == policyB) valueAssets
                                                , sfExactBTokenName = bTokenQty > 0
                                                , sfTokenQtyOne = bTokenQty == 1
                                                , sfATokenExcluded = not (any (\(pid, an, _) -> pid == aPolicyId && an == aTokenName) valueAssets)
                                                , sfNoOtherAssets = length valueAssets == 1
                                                , sfOldExactBAnchorSpent =
                                                    not (Set.member bAnchorInNow (Set.fromList (map fst liveNow)))
                                                , sfRootEqualsFoldResult = rootOk
                                                }
                                    case checkCopiedSuccessor facts of
                                        Right () ->
                                            emit "witness" "B-successor proof OK: successor carries B's authentic seed-derived token at B's state address, root equal to the fold result"
                                        Left err -> failWith ("B-successor proof: " <> err)
                                    emit "complete" "COPIED-POLICY WITNESS complete: retire A using ONLY B's state accepted"
                                _ -> failWith "B-successor proof: the target tx's successor state output not found"
                        ExpectRefusal ->
                            failWith
                                ( "RIVAL WITNESS FAILURE: variant "
                                    <> show variant
                                    <> " was SUBMITTED AND ACCEPTED - unexpected acceptance"
                                )
                Rejected reason -> do
                    let anchorAddr = case mRivalCtx2 of
                            Just ctx -> cageAddrFromCfg (rcCfg ctx) Testnet
                            Nothing -> cageAddrFromCfg (envCfg env) Testnet
                        failureText = show reason
                    emit "submit" ("raw submit result: " <> show result)
                    -- (NOTE-039.1) exact named-subject attribution: parse the
                    -- failed-script field the node names and require it to be
                    -- the application itself; whole-message substring search
                    -- cannot tell which script failed. Budget exhaustion is
                    -- setup/capacity evidence, never a semantic refusal.
                    case classifyRefusal failureText of
                        CapacityFailure ->
                            failWith "rival refusal: budget/capacity exhaustion is setup evidence, never a semantic refusal"
                        NoNamedSubject ->
                            failWith "rival refusal: the rejection names no parseable failed-script subject"
                        SemanticRefusal subject
                            | subject /= envAppHex env ->
                                failWith
                                    ( "rival refusal: the failure names a different script subject "
                                        <> subject
                                        <> ", not the application "
                                        <> envAppHex env
                                    )
                            | otherwise -> do
                                -- (NOTE-038.3) query BOTH exact attempted inputs fresh
                                -- after the typed rejection and run the shared liveness
                                -- decision on the observed booleans; no preset record.
                                recordLiveAfter <- isLiveAt (envAppAddr env) (snapIn snapA1)
                                anchorLiveAfter <- isLiveAt anchorAddr bAnchorIn
                                let refusalLiveness =
                                        RefusalLiveness
                                            { attemptedRecordInputLive = recordLiveAfter
                                            , attemptedAnchorInputLive = anchorLiveAfter
                                            }
                                case checkRefusalLiveness refusalLiveness of
                                    Right () -> pure ()
                                    Left err -> failWith err
                                case variant of
                                    RivalOwnPolicy ->
                                        emit "witness" "OWN-POLICY BASELINE: phase-2 refusal attributed to the exact application script hash; attempted inputs remain unspent"
                                    RivalForgedAnchor ->
                                        emit "witness" "FORGED-ANCHOR CONTROL: phase-2 refusal recorded (separately labelled; not an authentic B transition)"
                                    RivalCopiedPolicy ->
                                        failWith "COPIED-POLICY: unexpected REJECTION - copied-policy requires submission"

rowLT01 :: Env -> Snap -> IO ConwayTx
rowLT01 env snap = do
    tx <- retireTx env snap (envCustodyAddr env) [envOldHash env]
    let signed = addKeyWitness (mkSignKey oldSeed) (addKeyWitness genesisSignKey tx)
    unless
        (Set.singleton (addrWitnessKeyHash (envOldHash env)) == (signed ^. bodyTxL . reqSignerHashesTxBodyL))
        $ failWith "LT01: required signers must be exactly the controller payment key"
    when
        ( any
            (`Set.member` (signed ^. bodyTxL . reqSignerHashesTxBodyL))
            [addrWitnessKeyHash (envQuorum1Hash env), addrWitnessKeyHash (envQuorum2Hash env)]
        )
        $ failWith "LT01: no quorum member may be among the required signers"
    submitAccepted env "LT01" signed
    _ <- waitConfirmation (txIdHex signed <> " (LT01)")
    assertCustody env "LT01" signed
    assertGone env snap "LT01"
    emit
        "row"
        ( "LT01-controller-retirement-accepts: accepted tx="
            <> txIdHex signed
            <> " (the controller alone retires the name; the representative \
               \is at custody and the record is gone)"
        )
    pure signed

rowLT02 :: Env -> Snap -> IO ConwayTx
rowLT02 env snap = do
    tx <- retireTx env snap (envCustodyAddr env) [envQuorum1Hash env, envQuorum2Hash env]
    let signed =
            addKeyWitness
                (mkSignKey quorum1Seed)
                (addKeyWitness (mkSignKey quorum2Seed) (addKeyWitness genesisSignKey tx))
    unless
        ( Set.fromList
                [addrWitnessKeyHash (envQuorum1Hash env), addrWitnessKeyHash (envQuorum2Hash env)]
                == (signed ^. bodyTxL . reqSignerHashesTxBodyL)
        )
        $ failWith "LT02: required signers must be exactly the two quorum members"
    when
        ( Set.member
            (addrWitnessKeyHash (envOldHash env))
            (signed ^. bodyTxL . reqSignerHashesTxBodyL)
        )
        $ failWith "LT02: the controller must not be among the required signers"
    submitAccepted env "LT02" signed
    _ <- waitConfirmation (txIdHex signed <> " (LT02)")
    assertCustody env "LT02" signed
    assertGone env snap "LT02"
    emit
        "row"
        ( "LT02-quorum-retirement-accepts: accepted tx="
            <> txIdHex signed
            <> " (the fixed registration quorum alone retires the name, with \
               \no controller signature; the representative is at custody and \
               \the record is gone)"
        )
    pure signed

rowLT03 :: Mode -> Env -> Snap -> IO ()
rowLT03 mode env snap = do
    tx <- retireTx env snap (envCustodyAddr env) [envQuorum1Hash env]
    let signed = addKeyWitness (mkSignKey quorum1Seed) (addKeyWitness genesisSignKey tx)
    expectRefused
        mode
        env
        "LT03-insufficient-quorum-refused"
        "retirement-authorization"
        ( "one distinct quorum signature short of the threshold of two, no \
          \controller signature — otherwise exactly the accepted shape"
        )
        signed
    noTrace env snap "LT03"

rowLT03Dup :: Env -> Snap -> IO ()
rowLT03Dup env snap = do
    tx <- retireTx env snap (envCustodyAddr env) [envQuorum1Hash env]
    let signed = addKeyWitness (mkSignKey quorum1Seed) (addKeyWitness genesisSignKey tx)
    expectRefused
        MainRun
        env
        "LT03-duplicate-member-refused"
        "retirement-authorization"
        ( "the stored quorum names one member twice and a second once at \
          \threshold two — well-formed by the existing rules — but the \
          \duplicated member alone signs: counting signatures instead of \
          \distinct members would accept, so this row binds the distinctness"
        )
        signed
    noTrace env snap "LT03-duplicate"

rowLT05 :: Env -> Snap -> IO ()
rowLT05 env snap = do
    current <- chainDatumOf env snap "LT05"
    let tampered = current {controlAddress = envDestCodec env}
    tx <- maintainTx env snap tampered [envQuorum1Hash env, envQuorum2Hash env]
    let signed =
            addKeyWitness
                (mkSignKey quorum1Seed)
                (addKeyWitness (mkSignKey quorum2Seed) (addKeyWitness genesisSignKey tx))
    unless
        ( Set.fromList
                [addrWitnessKeyHash (envQuorum1Hash env), addrWitnessKeyHash (envQuorum2Hash env)]
                == (signed ^. bodyTxL . reqSignerHashesTxBodyL)
        )
        $ failWith "LT05: the attempt must carry exactly the quorum signatures"
    expectRefused
        MainRun
        env
        "LT05-quorum-control-takeover-refused"
        "controller-signature"
        ( "a quorum-signed attempt to change the control fields carries no \
          \controller signature: the quorum may end the name, never take it over"
        )
        signed
    noTrace env snap "LT05"

rowLT06 :: Env -> Snap -> IO ()
rowLT06 env snap = do
    current <- chainDatumOf env snap "LT06"
    let tampered = current {paymentDestination = SomeDestination (envDestCodec env)}
    tx <- maintainTx env snap tampered [envQuorum1Hash env, envQuorum2Hash env]
    let signed =
            addKeyWitness
                (mkSignKey quorum1Seed)
                (addKeyWitness (mkSignKey quorum2Seed) (addKeyWitness genesisSignKey tx))
    expectRefused
        MainRun
        env
        "LT06-quorum-payment-redirection-refused"
        "controller-signature"
        ( "a quorum-signed attempt to change the payment destination carries \
          \no controller signature: the quorum may end the name, never \
          \redirect its payments"
        )
        signed
    noTrace env snap "LT06"

rowLT08 :: Env -> Snap -> IO ()
rowLT08 env snap = do
    tx <- retireTx env snap (envWrongDestAddr env) [envOldHash env]
    let signed = addKeyWitness (mkSignKey oldSeed) (addKeyWitness genesisSignKey tx)
    expectRefused
        MainRun
        env
        "LT08-wrong-retirement-custody-refused"
        "retirement-request"
        ( "authorized by the controller but the representative goes anywhere \
          \but the custody script — otherwise exactly the accepted shape"
        )
        signed
    noTrace env snap "LT08"

rowLT09 :: Env -> TxIn -> ConwayTx -> IO ()
rowLT09 env consumedIn signedLT01 = do
    appUtxos <- Cage.queryUTxOs (envProv env) (envAppAddr env)
    unless (not (any ((== consumedIn) . fst) appUtxos)) $
        failWith "LT09: the retired record is unexpectedly still live"
    emit
        "row"
        ( "LT09-retirement-replay-refused: retiring "
            <> showIn consumedIn
            <> " again with LT01's exact tx="
            <> txIdHex signedLT01
            <> " (the record is gone)"
        )
    result <- submitTx (envSubmit env) signedLT01
    case result of
        Submitted _ ->
            failWith
                "LT09: the replay was ACCEPTED — a consumed record authorized \
                \retirement twice"
        Rejected reason -> do
            let reasonText = T.unpack (TE.decodeUtf8Lenient reason)
                allSpent = "All inputs are spent" `isInfixOf` reasonText
            unless allSpent $
                failWith
                    ( "LT09: reason mismatch — expected the ledger to refuse \
                      \the replay in phase 1 naming the consumed output "
                        <> txIdHex signedLT01
                        <> " (the ledger shape of naming-record-unavailable) \
                           \but the node said <"
                        <> reasonText
                        <> ">"
                    )
            emit
                "row"
                ( "LT09-retirement-replay-refused: REFUSED, reason matched \
                  \(model reason naming-record-unavailable): "
                    <> reasonText
                    <> " — the ledger itself refuses in phase 1, naming the \
                       \consumed output: a consumed UTxO cannot be re-spent, \
                       \so the replay never reaches the validator; recorded as \
                       \exactly that, not dressed up as a validator refusal"
                )

-- | Custody proved from the chain: an output of the accepted retirement
-- carries the representative at the custody script address.
assertCustody :: Env -> String -> ConwayTx -> IO ()
assertCustody env label signed = do
    threadDelay 5_000_000
    utxos <- Cage.queryUTxOs (envProv env) (envCustodyAddr env)
    let mine = utxosByTxId utxos (txIdHex signed)
    when (null mine) $
        failWith
            ( label
                <> ": no output of the retirement is live at the custody \
                   \address 0x"
                <> envCustodyHex env
            )
    let hasRep :: (TxIn, TxOut ConwayEra) -> Bool
        hasRep (_, o) = case o ^. valueTxOutL of
            MaryValue _ (MultiAsset ma) ->
                ( Map.lookup (envRepPolicy env) ma
                    >>= Map.lookup (AssetName (SBS.toShort (envRepBytes env)))
                )
                    == Just 1
    unless (any hasRep mine) $
        failWith
            ( label
                <> ": the custody outputs do not carry the representative 0x"
                <> hex (envRepBytes env)
            )
    emit
        "custody"
        ( label
            <> ": representative 0x"
            <> hex (envRepBytes env)
            <> " observed at the custody script 0x"
            <> envCustodyHex env
            <> " in tx "
            <> txIdHex signed
        )

-- | The retired record is observed gone from the application validator.
assertGone :: Env -> Snap -> String -> IO ()
assertGone env snap label = do
    utxos <- Cage.queryUTxOs (envProv env) (envAppAddr env)
    when (any ((== snapIn snap) . fst) utxos) $
        failWith
            ( label
                <> ": the retired record "
                <> showIn (snapIn snap)
                <> " is still live at the application validator"
            )
    emit
        "custody"
        ( label
            <> ": record "
            <> showIn (snapIn snap)
            <> " observed gone from the application validator"
        )

finalNoTrace :: Env -> TxIn -> IO ()
finalNoTrace env refusalsIn = do
    snapR <- mustSnap env refusalsIn
    emit
        "no-trace"
        ( "state unchanged after every refusal — no trace: refusals="
            <> showIn refusalsIn
            <> " ("
            <> show (snapCoin snapR)
            <> " lovelace, tokens "
            <> show (snapTokens snapR)
            <> ", datum bytes unchanged); both accept records consumed into \
               \custody; the refused transactions left the authenticated state \
               \exactly as it was"
        )

-- ---------------------------------------------------------
-- Controls
-- ---------------------------------------------------------

runControlValid :: Env -> TxIn -> IO ()
runControlValid env recRefusals = do
    snap <- mustSnap env recRefusals
    -- First a genuine refusal (emits a row, proving the runner ran).
    rowLT08 env snap
    -- Then LT03 made actually valid: the missing quorum member added.
    tx <- retireTx env snap (envCustodyAddr env) [envQuorum1Hash env, envQuorum2Hash env]
    let signed =
            addKeyWitness
                (mkSignKey quorum1Seed)
                (addKeyWitness (mkSignKey quorum2Seed) (addKeyWitness genesisSignKey tx))
    result <- submitTx (envSubmit env) signed
    case result of
        Submitted _ -> do
            emit
                "row"
                "LT03-insufficient-quorum-refused: CONTROL valid-transaction \
                \succeeded as constructed — failing the run as required"
            failWith
                ( "CONTROL valid-transaction: LT03's transaction, made actually \
                  \valid, SUCCEEDED — the guard did not refuse, so this run \
                  \fails as the control requires"
                )
        Rejected reason ->
            failWith
                ( "CONTROL valid-transaction: the control transaction was \
                  \unexpectedly refused: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )

runControlWrongReason :: Env -> TxIn -> TxIn -> IO ()
runControlWrongReason env recAccept1 recRefusals = do
    -- LT01 first (accepts, emits a row, proving the runner ran).
    snapA1 <- mustSnap env recAccept1
    _ <- rowLT01 env snapA1
    -- Then a refusal matched against an impossible marker.
    snap <- mustSnap env recRefusals
    rowLT03 ControlWrongReason env snap
    failWith "CONTROL wrong-reason: the impossible marker unexpectedly matched"

-- ---------------------------------------------------------
-- Refusal attribution
-- ---------------------------------------------------------

expectRefused ::
    Mode ->
    Env ->
    String ->
    String ->
    String ->
    ConwayTx ->
    IO ()
expectRefused mode env rowName modelReason guard signed = do
    let wrongReasonMode = mode == ControlWrongReason
        expectedMarker
            | wrongReasonMode = wrongReasonMarker
            | otherwise = envAppHex env
    result <- submitTx (envSubmit env) signed
    case result of
        Submitted _ ->
            failWith
                ( rowName
                    <> ": transaction was ACCEPTED — the guard did not hold: "
                    <> guard
                )
        Rejected reason -> do
            let reasonText = T.unpack (TE.decodeUtf8Lenient reason)
                phase2 = "PlutusFailure" `isInfixOf` reasonText
            unless (phase2 || wrongReasonMode) $
                failWith
                    ( rowName
                        <> ": expected-rejection-reason <phase-2 PlutusFailure \
                           \naming the application validator> but the node \
                           \rejected with <"
                        <> reasonText
                        <> "> — a phase-1 refusal proves nothing about the guard"
                    )
            unless (expectedMarker `isInfixOf` reasonText) $
                failWith
                    ( rowName
                        <> ": reason mismatch — expected the refusal to name <"
                        <> expectedMarker
                        <> "> but the node said <"
                        <> reasonText
                        <> ">"
                    )
            emit
                "row"
                ( rowName
                    <> ": REFUSED, reason matched (model reason "
                    <> modelReason
                    <> "; phase-2 PlutusFailure naming the application validator \
                       \0x"
                    <> envAppHex env
                    <> "): "
                    <> reasonText
                    <> " — "
                    <> guard
                )

-- ---------------------------------------------------------
-- Transaction builders
-- ---------------------------------------------------------

retireTx ::
    Env ->
    Snap ->
    Addr ->
    [ByteString] ->
    IO ConwayTx
retireTx env snap destination signers = do
    -- State-anchored retire (issue #77, E-001 repair): the record spend
    -- rides a connected transaction spending the registry state via a
    -- no-op `Modify` (empty requests, root unchanged), so the application
    -- validator reads the expected representative policy from validated
    -- state. No mint rides a retire (the representative moves to custody;
    -- completion burns it later). Local evaluation is skipped so the ledger
    -- executes every purpose for real with stated budgets. `retireTx`
    -- returns the unsigned transaction; callers add key witnesses exactly
    -- as before.
    snapLive <- mustOutAt env (envAppAddr env) (snapIn snap)
    (stateIn, stateOut) <- queryRetirementState env
    feeUtxo <- queryRetirementFee env
    let custodyOut' =
            custodyOut (envPp env) destination (snapCoin snap) (envRepTokens env)
    -- RIVAL WITNESS (issue #80 t80e / NOTE-023/027): when the rival bundle
    -- is installed, the ENTIRE fold transition is constructed from B — B's
    -- config, B's authentic seed-derived token, B's settled state UTxO and
    -- B's trie — never A's. The successor of this fold is therefore a real
    -- B-state transition, and the application validator's expected_rep_policy
    -- reads B's datum policy.
    mRivalCtx <- readIORef (envRivalCtx env)
    let rivalCfg = maybe (envCfg env) rcCfg mRivalCtx
        rivalTrie = maybe (envTrie env) rcTrie mRivalCtx
        rivalTok = maybe (envTok env) rcTok mRivalCtx
        rivalState = maybe (stateIn, stateOut) rcState mRivalCtx
    (unsigned, newRoot) <-
        connectedFoldTx
            ConnectedFoldArgs
                { cfaCfg = rivalCfg
                , cfaProvider = envProv env
                , cfaTrie = rivalTrie
                , cfaToken = rivalTok
                , cfaFeeAddr = genesisAddr
                , cfaStateUtxo = rivalState
                , cfaReqUtxos = []
                , cfaFeeUtxo = feeUtxo
                , cfaPp = envPp env
                , cfaSpends =
                    [ ConnectedSpend
                        { csUtxo = (snapIn snap, snapLive)
                        , csRedeemer =
                            RawRedeemer (redeemerRetire (envRepBytes env))
                        , csScript = envScript env
                        }
                    ]
                , cfaMints = []
                , cfaOutputs = [custodyOut']
                , cfaSigners = map addrWitnessKeyHash signers
                , cfaRefUtxos = envRefUtxos env
                , cfaAttachScripts = []
                , cfaSkipEval = True
                , cfaAdjustRoot = id
                }
    writeIORef (envNewRootRef env) (Just newRoot)
    pure unsigned

maintainTx ::
    Env ->
    Snap ->
    NamingDatum ->
    [ByteString] ->
    IO ConwayTx
maintainTx env snap successor signers = do
    (fund, collateral) <- takeFundCollateral env
    let inputs = Set.fromList [snapIn snap, fst fund]
        spendIdx = spendingIndex (snapIn snap) inputs
        redeemers =
            Redeemers
                ( Map.singleton
                    (ConwaySpending (AsIx spendIdx))
                    (Data redeemerMaintain, maxUnits)
                )
        integrity = computeScriptIntegrity (envPp env) redeemers
        contOut =
            scriptOut (envPp env) (envAppAddr env) (snapCoin snap) (envRepTokens env) successor
        change = changeOut (snapCoin snap + coinOf fund) flatFee [contOut]
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ inputs
                & collateralInputsTxBodyL .~ Set.singleton (fst collateral)
                & outputsTxBodyL .~ StrictSeq.fromList [contOut, change]
                & feeTxBodyL .~ Coin flatFee
                & reqSignerHashesTxBodyL
                    .~ Set.fromList (map addrWitnessKeyHash signers)
                & scriptIntegrityHashTxBodyL .~ integrity
    pure $
        ( mkBasicTx body
            & witsTxL . scriptTxWitsL
                .~ Map.singleton (envScriptHash env) (envScript env)
            & witsTxL . rdmrsTxWitsL .~ redeemers
        )
  where
    coinOf (_, o) = let Coin c = o ^. coinTxOutL in c

scriptOut ::
    PParams ConwayEra ->
    Addr ->
    Integer ->
    Map.Map PolicyID (Map.Map AssetName Integer) ->
    NamingDatum ->
    TxOut ConwayEra
scriptOut pp addr coin tokens datum =
    let probe :: TxOut ConwayEra
        probe = mkBasicTxOut addr (MaryValue (Coin 0) (MultiAsset tokens))
        minCoin = let Coin c = getMinCoinTxOut pp probe in c
        finalCoin = max coin (minCoin + 1_000_000)
     in mkBasicTxOut
            addr
            (MaryValue (Coin finalCoin) (MultiAsset tokens))
            & datumTxOutL .~ mkInlineDatum (namingDataToData datum)

-- | A custody output: the representative at the custody script address
-- with no datum. Creating it executes no receiving script.
custodyOut ::
    PParams ConwayEra ->
    Addr ->
    Integer ->
    Map.Map PolicyID (Map.Map AssetName Integer) ->
    TxOut ConwayEra
custodyOut pp addr coin tokens =
    let probe :: TxOut ConwayEra
        probe = mkBasicTxOut addr (MaryValue (Coin 0) (MultiAsset tokens))
        minCoin = let Coin c = getMinCoinTxOut pp probe in c
        finalCoin = max coin (minCoin + 1_000_000)
     in mkBasicTxOut
            addr
            (MaryValue (Coin finalCoin) (MultiAsset tokens))
            & datumTxOutL .~ NoDatum

changeOut ::
    Integer ->
    Integer ->
    [TxOut ConwayEra] ->
    TxOut ConwayEra
changeOut inCoin fee outs =
    let spent = sum [c | o <- outs, let Coin c = o ^. coinTxOutL]
        change = inCoin - fee - spent
     in if change <= 1_000_000
            then error "retirement-rows: change underflow while balancing"
            else mkBasicTxOut genesisAddr (MaryValue (Coin change) mempty)

-- ---------------------------------------------------------
-- Setup transactions
-- ---------------------------------------------------------

bootRetirementCage ::
    Cage.Provider IO ->
    Submitter IO ->
    TrieManager IO ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    IO (CageConfig, TokenId)
bootRetirementCage prov submit tm stateBytes requestBytes repPolicy = do
    utxos <- Cage.queryUTxOs prov genesisAddr
    seedRef <- case sortOn (Down . (^. coinTxOutL) . snd) utxos of
        [] -> failWith "boot: genesis wallet has no UTxOs"
        (txIn, _) : _ -> pure (txInToRef txIn)
    let cfg =
            CageConfig
                { cageScriptBytes = stateBytes
                , requestScriptBytes = requestBytes
                , cfgScriptHash = computeScriptHash stateBytes
                , cageSeed = seedRef
                , defaultProcessTime = 120_000
                , defaultRetractTime = 30_000
                , defaultTip = Coin 1_000_000
                , cfgRepPolicy = repPolicy
                , network = Testnet
                }
    unsignedBoot <- bootTokenImpl cfg prov genesisAddr
    let signedBoot = addKeyWitness genesisSignKey unsignedBoot
    result <- submitTx submit signedBoot
    case result of
        Submitted _ -> pure ()
        Rejected reason -> failWith ("boot: rejected: " <> show reason)
    threadDelay 5_000_000
    let MultiAsset ma = signedBoot ^. bodyTxL . mintTxBodyL
        assets = Map.toList (ma Map.! cagePolicyIdFromCfg cfg)
    tok <- case assets of
        [(an, _)] -> pure (TokenId an)
        _ -> failWith "boot: unexpected minted assets"
    createTrie tm tok
    emit "boot" "booted the retirement registry cage"
    pure (cfg, tok)

-- | Publish the four scripts as reference outputs so connected folds
-- resolve every purpose through reference inputs.
publishRetirementRefs ::
    Cage.Provider IO ->
    Submitter IO ->
    PParams ConwayEra ->
    IORef [(TxIn, TxOut ConwayEra)] ->
    CageConfig ->
    TokenId ->
    Script ConwayEra ->
    Script ConwayEra ->
    IO [(TxIn, TxOut ConwayEra)]
publishRetirementRefs prov submit pp poolRef cfg tok appScript repScript = do
    let scripts =
            [ mkCageScript cfg
            , mkRequestScript cfg tok
            , appScript
            , repScript
            ]
    concat <$> mapM (publishBatch prov submit pp poolRef genesisAddr) (batches scripts)
  where
    batches [] = []
    batches xs = take 2 xs : batches (drop 2 xs)

publishBatch ::
    Cage.Provider IO ->
    Submitter IO ->
    PParams ConwayEra ->
    IORef [(TxIn, TxOut ConwayEra)] ->
    Addr ->
    [Script ConwayEra] ->
    IO [(TxIn, TxOut ConwayEra)]
publishBatch prov submit pp poolRef addr scripts = do
    pool <- readIORef poolRef
    (fund, rest) <- case pool of
        (f : fs) -> pure (f, fs)
        [] -> failWith "the funding pool is exhausted"
    writeIORef poolRef rest
    let mkRefOut script =
            let probe =
                    mkBasicTxOut addr (MaryValue (Coin 0) mempty)
                        & referenceScriptTxOutL .~ SJust script
                Coin minCoin = getMinCoinTxOut pp probe
             in mkBasicTxOut
                    addr
                    (MaryValue (Coin (minCoin + 1_000_000)) mempty)
                    & referenceScriptTxOutL .~ SJust script
        outs = map mkRefOut scripts
        spent = sum [c | o <- outs, let Coin c = o ^. coinTxOutL]
        Coin inCoin = (snd fund) ^. coinTxOutL
        changeCoin = inCoin - 1_000_000 - spent
    unless (changeCoin > 1_000_000) $
        failWith "publish: funding UTxO too small for script outputs"
    let changeOutTx =
            mkBasicTxOut genesisAddr (MaryValue (Coin changeCoin) mempty)
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton (fst fund)
                & outputsTxBodyL .~ StrictSeq.fromList (outs <> [changeOutTx])
                & feeTxBodyL .~ Coin 1_000_000
        tx = mkBasicTx body
        signed = addKeyWitness genesisSignKey tx
    result <- submitTx submit signed
    case result of
        Submitted _ -> pure ()
        Rejected reason -> failWith ("publish: refused: " <> show reason)
    let txid = txIdHex tx
    threadDelay 5_000_000
    after <- Cage.queryUTxOs prov addr
    let mine =
            sortBy
                (comparing (txInIndex . fst))
                (utxosByTxId after txid)
    unless (length mine >= length scripts) $
        failWith "publish: script outputs not found"
    pure (take (length scripts) mine)

-- | Submit one MPFS insert request (spelling -> representative name),
-- genesis-funded like the rest of this runner.
submitRetirementRequest :: Env -> ByteString -> ByteString -> IO (TxIn, TxOut ConwayEra)
submitRetirementRequest env spelling value = do
    let cfg = envCfg env
        tok = envTok env
    unsigned <-
        requestInsertImpl cfg (envProv env) (Coin 1_000_000) tok spelling value genesisAddr
    let signed = addKeyWitness genesisSignKey unsigned
    result <- submitTx (envSubmit env) signed
    case result of
        Submitted _ -> pure ()
        Rejected reason -> failWith ("request: rejected: " <> show reason)
    let txid = txIdHex signed
    _ <- waitConfirmation (txid <> " (MPFS request " <> show spelling <> ")")
    let reqAddr = requestAddrFromCfg cfg tok Testnet
    reqIn <- mustFindUTxO (envProv env) reqAddr txid "MPFS request"
    reqOut <- mustOutAt env reqAddr reqIn
    pure (reqIn, reqOut)

-- ---------------------------------------------------------
-- Rival-cage witness (issue #80 t80e; NOTE-017/019/022/023)
-- ---------------------------------------------------------

-- | The typed B bundle: the rival's actual boot artifacts -- config,
-- authentic seed-derived token, settled state UTxO, and its own trie --
-- from which the target retirement's ConnectedFoldArgs are built. A's
-- config/token/trie are never mixed in.
data RivalCtx = RivalCtx
    { rcCfg :: CageConfig
    , rcTok :: TokenId
    , rcState :: (TxIn, TxOut ConwayEra)
    , rcTrie :: TrieManager IO
    }

-- (NOTE-038.1) the rival variants and their parser are the shared
-- RivalDriverLogic ones; no private enum or parser remains.
readRivalVariant :: IO (Maybe RivalVariant)
readRivalVariant = do
    m <- lookupEnv "RIVAL_VARIANT"
    case m of
        Nothing -> pure Nothing
        Just s -> case parseRivalVariant s of
            Just v -> pure (Just v)
            Nothing -> failWith ("RIVAL_VARIANT: unknown variant " <> s)

-- | Boot B (own seed through the real validateMint -> a distinct
-- authentic cage token under the SAME state policy and address; datum
-- representative_policy per the variant) and install B's settled state
-- as the retirement anchor. The forged-anchor variant instead installs a
-- tokenless output at the MPFS state address (creating an output never
-- executes the script), labelled separately.
runRivalSetup :: Env -> SBS.ShortByteString -> IO ()
runRivalSetup env repAppliedPolicyBytes = do
    let rivalRef = envRivalAnchor env
    readRivalVariant >>= \case
        Nothing -> emit "rival" "no RIVAL_VARIANT set: ordinary retirement run"
        Just variant -> do
            emit "rival" ("variant: " <> show variant)
            genesisBefore <- Cage.queryUTxOs (envProv env) genesisAddr
            case variant of
                RivalOwnPolicy -> bootAndAnchor rivalRef bPolicyOwn
                RivalCopiedPolicy -> bootAndAnchor rivalRef repAppliedPolicyBytes
                RivalForgedAnchor -> forgedAnchor rivalRef
            genesisAfter <- Cage.queryUTxOs (envProv env) genesisAddr
            -- (NOTE-038.5) retain the exact B seed identity consumed by the
            -- real boot, for the funding selection's seed exclusion.
            let consumed = [i | (i, _) <- genesisBefore, i `notElem` map fst genesisAfter]
            case consumed of
                [] -> pure ()
                [seedIn] -> writeIORef (envRivalBSeed env) (Just seedIn)
                _ -> failWith "rival boot: unexpected multiple genesis seeds consumed"
  where
    prov = envProv env
    bPolicyOwn = SBS.pack (replicate 28 0x42)
    bootAndAnchor rivalRef bPolicy = do
        -- B's seed: the largest genesis UTxO still unspent (A's seed is
        -- consumed by A's boot), so validateMint mints B a distinct
        -- authentic token name under the same state policy and address.
        (cfgB, tokB) <-
            bootRetirementCage prov (envSubmit env) (envTrie env)
                (envStateBytes env)
                (envRequestBytes env)
                bPolicy
        let stateAddr = cageAddrFromCfg cfgB Testnet
        utxos <- Cage.queryUTxOs prov stateAddr
        bState <- case findStateUtxo (cagePolicyIdFromCfg cfgB) tokB utxos of
            Just x -> pure x
            Nothing -> failWith "rival B: state UTxO not found"
        -- the material relation (NOTE-028): the manager's tokB root equals
        -- the root in B's settled state datum
        managerRootB <- withTrie (envTrie env) tokB $ \t -> getRoot t
        datumRootOk <- case extractCageDatum (snd bState) of
            Just (StateDatum st) -> case stateRoot st of
                OnChainRoot got -> pure (got == unRoot managerRootB)
            _ -> pure False
        unless datumRootOk $ failWith "rival B: the manager's tokB root does not equal the settled state datum root"
        writeIORef (envRivalCtx env) (Just (RivalCtx cfgB tokB bState (envTrie env)))
        writeIORef rivalRef (Just bState)
        emit
            "rival"
            ( "B booted and anchored: token "
                <> show tokB
                <> ", datum representative_policy 0x"
                <> hex (SBS.fromShort bPolicy)
                <> " (A's applied policy is 0x"
                <> hex (SBS.fromShort repAppliedPolicyBytes)
                <> ")"
            )
    forgedAnchor rivalRef = do
        -- A tokenless output at the MPFS state address: creating an output
        -- never executes the script (the CA05 observation), so this input
        -- is constructible by anyone and carries NO cage token.
        (anchorIn, anchorOut) <- mintlessOutputAtState
        writeIORef rivalRef (Just (anchorIn, anchorOut))
        emit "rival" "forged anchor installed: tokenless output at the state address"
    mintlessOutputAtState :: IO (TxIn, TxOut ConwayEra)
    mintlessOutputAtState = do
        pp <- Cage.queryProtocolParams prov
        let stateAddr = cageAddrFromCfg (envCfg env) Testnet
        utxos <- Cage.queryUTxOs prov genesisAddr
        feeUtxo <- case sortOn (Down . (^. coinTxOutL) . snd) utxos of
            [] -> failWith "forged anchor: no UTxOs"
            (u : _) -> pure u
        let out :: TxOut ConwayEra
            out = mkBasicTxOut stateAddr (inject (Coin 2_000_000))
            body = mkBasicTx (mkBasicTxBody & outputsTxBodyL .~ StrictSeq.singleton out)
        balanced <- evaluateAndBalance prov pp [feeUtxo] genesisAddr body
        let signed = addKeyWitness genesisSignKey balanced
        _ <- submitWithRetirementGenesis (envSubmit env) signed
        let created = TxIn (txIdTx signed) (TxIx 0)
        -- read the created output back from the chain (the settled form)
        live <- Cage.queryUTxOs prov stateAddr
        case [ pair | pair@(i, _) <- live, i == created ] of
            (pair : _) -> pure pair
            [] -> failWith "forged anchor: created output not found"

submitWithRetirementGenesis :: Submitter IO -> ConwayTx -> IO ConwayTx
submitWithRetirementGenesis submit unsignedTx = do
    let signedTx = addKeyWitness genesisSignKey unsignedTx
    result <- submitTx submit signedTx
    case result of
        Submitted _ -> threadDelay 2_000_000 >> pure signedTx
        Rejected reason -> failWith ("tx rejected: " <> show reason)

queryRetirementState :: Env -> IO (TxIn, TxOut ConwayEra)
queryRetirementState env = do
    -- RIVAL WITNESS: when the rival anchor is installed (single activation
    -- inside retireTx), every anchor query resolves B.
    mAnchor <- readIORef (envRivalAnchor env)
    case mAnchor of
        Just bState -> pure bState
        Nothing -> do
            let cfg = envCfg env
                tok = envTok env
                stateAddr = cageAddrFromCfg cfg (network (envCfg env))
            utxos <- Cage.queryUTxOs (envProv env) stateAddr
            case findStateUtxo (cagePolicyIdFromCfg cfg) tok utxos of
                Just x -> pure x
                Nothing -> failWith "state UTxO not found"

queryRetirementFee :: Env -> IO (TxIn, TxOut ConwayEra)
queryRetirementFee env = do
    (fund, _collateral) <- takeFundCollateral env
    pure fund

mustOutAt :: Env -> Addr -> TxIn -> IO (TxOut ConwayEra)
mustOutAt env addr txin = do
    utxos <- Cage.queryUTxOs (envProv env) addr
    case filter ((== txin) . fst) utxos of
        [(_, o)] -> pure o
        _ -> failWith ("output " <> showIn txin <> " is not live")

mustFindUTxO ::
    Cage.Provider IO ->
    Addr ->
    String ->
    String ->
    IO TxIn
mustFindUTxO prov addr txid label = do
    utxos <- Cage.queryUTxOs prov addr
    let mine = sortBy (comparing (txInIndex . fst)) (utxosByTxId utxos txid)
    case mine of
        ((i, _) : _) -> pure i
        [] ->
            failWith
                ( label
                    <> ": no output of tx "
                    <> txid
                    <> " is live at the given address"
                )

chainRetirementRoot :: Env -> IO String
chainRetirementRoot env = do
    (_, stateOut) <- queryRetirementState env
    case extractCageDatum stateOut of
        Just (StateDatum st) ->
            let OnChainRoot bs = stateRoot st
             in pure (hex bs)
        _ -> failWith "the state UTxO carries no state datum"

-- | Fold one genuine record through the CONNECTED transaction: MPFS
-- request keyed by the given spelling plus the naming claim, one state
-- Modify, approval burn and representative mint. Returns the fold txid
setupRecoveryRecord ::
    Env ->
    NamingDatum ->
    String ->
    ByteString ->
    IO (String, TxIn)
setupRecoveryRecord env datum label spelling = do
    let controlBytes = addressBytes (controlAddress datum)
        commitment = nextControlCommitment datum
        approval = insertApprovalName controlBytes commitment
        repName = representativeName (envOldHash env) freshIncarnation
        approvalTokens =
            Map.singleton
                (envAppPolicy env)
                (Map.singleton (AssetName (SBS.toShort approval)) 1)
    -- The insert request (claim) at the application validator.
    (fundA, collateralA) <- takeFundCollateral env
    let claimOut =
            scriptOut
                (envPp env)
                (envAppAddr env)
                claimCoin
                approvalTokens
                datum
        changeA = changeOut (coinOf fundA) flatFee [claimOut]
        redeemersA =
            Redeemers $
                Map.singleton
                    (ConwayMinting (AsIx 0))
                    ( Data
                        ( insertApprovalRedeemer
                            (envOldHash env)
                            controlBytes
                            commitment
                        )
                    , maxUnits
                    )
        integrityA = computeScriptIntegrity (envPp env) redeemersA
        bodyA =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.fromList [fst fundA]
                & collateralInputsTxBodyL .~ Set.singleton (fst collateralA)
                & outputsTxBodyL .~ StrictSeq.fromList [claimOut, changeA]
                & feeTxBodyL .~ Coin flatFee
                & mintTxBodyL .~ MultiAsset approvalTokens
                & reqSignerHashesTxBodyL
                    .~ Set.singleton (addrWitnessKeyHash (envOldHash env))
                & scriptIntegrityHashTxBodyL .~ integrityA
        txA =
            mkBasicTx bodyA
                & witsTxL . scriptTxWitsL
                    .~ Map.singleton (envScriptHash env) (envScript env)
                & witsTxL . rdmrsTxWitsL .~ redeemersA
    let signedA =
            addKeyWitness
                (mkSignKey oldSeed)
                (addKeyWitness genesisSignKey txA)
    submitAccepted env ("setup-" <> label <> "-insert") signedA
    _ <- waitConfirmation (txIdHex signedA <> " (setup: " <> label <> " claim)")
    claimIn <-
        mustFindUTxO
            (envProv env)
            (envAppAddr env)
            (txIdHex signedA)
            ("setup: " <> label <> " claim")
    snapClaim <- mustSnap env claimIn
    claimLive <- mustOutAt env (envAppAddr env) claimIn
    -- The MPFS request keyed by the spelling.
    (reqIn, reqOut) <- submitRetirementRequest env spelling repName
    -- The connected fold: state Modify, request Contribute, claim Fold.
    (stateIn, stateOut) <- queryRetirementState env
    feeUtxo <- queryRetirementFee env
    let recordTokens =
            Map.singleton
                (envRepPolicy env)
                (Map.singleton (AssetName (SBS.toShort repName)) 1)
        recordOut =
            scriptOut
                (envPp env)
                (envAppAddr env)
                (snapCoin snapClaim)
                recordTokens
                datum
    (unsignedF, _newRoot) <-
        connectedFoldTx
            ConnectedFoldArgs
                { cfaCfg = envCfg env
                , cfaProvider = envProv env
                , cfaTrie = envTrie env
                , cfaToken = envTok env
                , cfaFeeAddr = genesisAddr
                , cfaStateUtxo = (stateIn, stateOut)
                , cfaReqUtxos = [(reqIn, reqOut)]
                , cfaFeeUtxo = feeUtxo
                , cfaPp = envPp env
                , cfaSpends =
                    [ ConnectedSpend
                        { csUtxo = (claimIn, claimLive)
                        , csRedeemer = RawRedeemer (foldRedeemer [repName])
                        , csScript = envScript env
                        }
                    ]
                , cfaMints =
                    [ ConnectedMint
                        { cmPolicy = envAppPolicy env
                        , cmAssets =
                            Map.singleton
                                (AssetName (SBS.toShort approval))
                                (-1)
                        , cmRedeemer =
                            RawRedeemer
                                ( insertApprovalRedeemer
                                    (envOldHash env)
                                    controlBytes
                                    commitment
                                )
                        , cmScript = envScript env
                        }
                    , ConnectedMint
                        { cmPolicy = envRepPolicy env
                        , cmAssets =
                            Map.singleton
                                (AssetName (SBS.toShort repName))
                                1
                        , cmRedeemer = RawRedeemer mintRepresentativeRedeemer
                        , cmScript = envRepScript env
                        }
                    ]
                , cfaOutputs = [recordOut]
                , cfaSigners = []
                , cfaRefUtxos = envRefUtxos env
                , cfaSkipEval = False
                , cfaAttachScripts = []
                , cfaAdjustRoot = id
                }
    let signedF = addKeyWitness genesisSignKey unsignedF
    submitAccepted env ("setup-" <> label <> "-fold") signedF
    _ <- waitConfirmation (txIdHex signedF <> " (setup: " <> label <> " fold)")
    syncFoldedRequests (envTrie env) (envTok env) [(reqIn, reqOut)]
    rootAfter <- chainRetirementRoot env
    emit
        "setup-fold"
        ( label
            <> " folded connected into Active as "
            <> txIdHex signedF
            <> " (spelling "
            <> show spelling
            <> ", root "
            <> rootAfter
            <> ")"
        )
    recordIn <-
        mustFindUTxO
            (envProv env)
            (envAppAddr env)
            (txIdHex signedF)
            ("setup: " <> label <> " record")
    pure (txIdHex signedF, recordIn)
  where
    coinOf (_, o) = let Coin c = o ^. coinTxOutL in c

splitGenesis :: Cage.Provider IO -> Submitter IO -> Integer -> IO [(TxIn, TxOut ConwayEra)]
splitGenesis prov submit nSplits = do
    utxos <- Cage.queryUTxOs prov genesisAddr
    (bigIn, bigOut) <- case sortBy (comparing outSortKey) utxos of
        (b : _) -> pure b
        [] -> failWith "split: the genesis wallet has no UTxOs"
    let Coin total = bigOut ^. coinTxOutL
        perSplit = 2_000_000_000
        fee = 1_000_000
        change = total - nSplits * perSplit - fee
    unless (change > 1_000_000) $
        failWith "split: the genesis wallet cannot fund the splits"
    let splitOuts =
            [ mkBasicTxOut genesisAddr (MaryValue (Coin perSplit) mempty)
            | _ <- [1 .. nSplits]
            ]
        changeOut' = mkBasicTxOut genesisAddr (MaryValue (Coin change) mempty)
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton bigIn
                & outputsTxBodyL .~ StrictSeq.fromList (splitOuts <> [changeOut'])
                & feeTxBodyL .~ Coin fee
        splitTx = mkBasicTx body
    result <- submitTx submit (addKeyWitness genesisSignKey splitTx)
    case result of
        Submitted _ -> pure ()
        Rejected reason ->
            failWith
                ( "split: refused: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )
    threadDelay 5_000_000
    after <- Cage.queryUTxOs prov genesisAddr
    let txid = txIdHex splitTx
        mine =
            [ (i, o)
            | (i, o) <- after
            , txInTxIdHex i == txid
            , txInIndex i < nSplits
            ]
    unless (toInteger (length mine) == nSplits) $
        failWith
            ( "split: expected "
                <> show nSplits
                <> " funding UTxOs, found "
                <> show (length mine)
            )
    pure (sortBy (comparing (txInIndex . fst)) mine)
  where
    outSortKey (i, _) = (txInTxIdHex i, txInIndex i)

txInTxIdHex :: TxIn -> String
txInTxIdHex (TxIn (TxId h) _) = hex (hashToBytes (extractHash h))

txInIndex :: TxIn -> Integer
txInIndex (TxIn _ (TxIx i)) = toInteger i

takeFundCollateral ::
    Env ->
    IO ((TxIn, TxOut ConwayEra), (TxIn, TxOut ConwayEra))
takeFundCollateral env = do
    pool <- readIORef (envPool env)
    mBSeed <- readIORef (envRivalBSeed env)
    -- (NOTE-038.5) observe CURRENT liveness for every cached pool identity
    -- and the exact consumed B seed captured from the real boot; the shared
    -- decision prunes; retained identities map back to the same UTxOs. No
    -- caller-supplied liveness or seed Bool.
    observed <- forM pool $ \pair@(i, _) -> do
        live <- queryInputLive env i
        pure
            ( FundingEntry
                { feInputId = txInTxIdHex i <> "#" <> show (txInIndex i)
                , feLive = live
                , feIsConsumedBSeed = Just i == mBSeed
                }
            , pair
            )
    let (kept, pruned) = selectLiveFunding (map fst observed)
        keptIds = Set.fromList (map feInputId kept)
        retainedPairs = [pair | (fe, pair) <- observed, Set.member (feInputId fe) keptIds]
    writeIORef (envPool env) retainedPairs
    unless (null pruned) $
        emit "funding" ("pruned " <> show (length pruned) <> " stale/consumed funding UTxOs")
    case retainedPairs of
        (f : c : rest) -> do
            writeIORef (envPool env) rest
            pure (f, c)
        _ -> failWith "the funding pool is exhausted: no live non-seed funding UTxOs remain"

-- | Is this exact input currently live at the genesis funding wallet?
queryInputLive :: Env -> TxIn -> IO Bool
queryInputLive env i = do
    utxos <- Cage.queryUTxOs (envProv env) genesisAddr
    pure (any ((== i) . fst) utxos)

-- ---------------------------------------------------------
-- Chain reading
-- ---------------------------------------------------------

data Snap = Snap
    { snapIn :: TxIn
    , snapCoin :: Integer
    , snapTokens :: [(ByteString, Integer)]
    , snapDatum :: Maybe PLC.Data
    }

mustSnap :: Env -> TxIn -> IO Snap
mustSnap env txin = do
    utxos <- Cage.queryUTxOs (envProv env) (envAppAddr env)
    case filter ((== txin) . fst) utxos of
        [(_, o)] -> do
            let Coin c = o ^. coinTxOutL
                ofPolicy pid = case o ^. valueTxOutL of
                    MaryValue _ (MultiAsset ma) ->
                        maybe
                            []
                            ( Map.toAscList
                                . Map.mapKeys (SBS.fromShort . assetNameBytes)
                            )
                            (Map.lookup pid ma)
                tokens = ofPolicy (envAppPolicy env) <> ofPolicy (envRepPolicy env)
                datum = datumDataOf o
            pure (Snap txin c tokens datum)
        _ ->
            failWith
                ( "snapshot: "
                    <> showIn txin
                    <> " is not live at the application validator"
                )

utxosByTxId ::
    [(TxIn, TxOut ConwayEra)] ->
    String ->
    [(TxIn, TxOut ConwayEra)]
utxosByTxId utxos txid = filter ((== txid) . txInTxIdHex . fst) utxos

datumDataOf :: TxOut ConwayEra -> Maybe PLC.Data
datumDataOf out = case out ^. datumTxOutL of
    Datum bd -> let Data d = binaryDataToData bd in Just d
    _ -> Nothing

wireOf :: PLC.Data -> Maybe WireData
wireOf (PLC.Constr i fs)
    | i >= 0 && i <= 6 = Constr (fromIntegral i) <$> traverse wireOf fs
wireOf (PLC.B b) = Just (WBytes b)
wireOf (PLC.I n) = Just (WInt n)
wireOf (PLC.List xs) = WList <$> traverse wireOf xs
wireOf _ = Nothing

chainDatumOf :: Env -> Snap -> String -> IO NamingDatum
chainDatumOf _env snap label =
    case snapDatum snap >>= wireOf >>= decodeNamingDatum of
        Just d -> pure d
        Nothing ->
            failWith
                ( label
                    <> ": the chain datum does not decode as a naming datum"
                )

noTrace :: Env -> Snap -> String -> IO ()
noTrace env before label = do
    now <- mustSnap env (snapIn before)
    unless
        ( snapCoin now == snapCoin before
            && snapTokens now == snapTokens before
            && snapDatum now == snapDatum before
        )
        $ failWith
            ( label
                <> ": the refused transaction moved the state at "
                <> showIn (snapIn before)
            )
    emit
        "no-trace"
        ( label
            <> ": state unchanged — no trace: "
            <> showIn (snapIn before)
            <> " still holds "
            <> show (snapCoin now)
            <> " lovelace, tokens "
            <> show (snapTokens now)
            <> ", datum bytes unchanged"
        )

-- ---------------------------------------------------------
-- Redeemer and datum encodings
-- ---------------------------------------------------------

namingDataToData :: NamingDatum -> PLC.Data
namingDataToData nd =
    PLC.Constr
        0
        [ PLC.Constr
            0
            [ PLC.B (addressBytes (controlAddress nd))
            , destinationData (paymentDestination nd)
            , PLC.B (nextControlCommitment nd)
            , quorumData (retirementQuorum nd)
            ]
        ]
  where
    destinationData NoDestination = PLC.Constr 0 []
    destinationData (SomeDestination a) = PLC.Constr 1 [PLC.B (addressBytes a)]
    quorumData q =
        PLC.Constr
            0
            [ PLC.I (quorumThreshold q)
            , PLC.List (map PLC.B (quorumMembers q))
            ]

redeemerMaintain :: PLC.Data
redeemerMaintain = PLC.Constr 0 []

-- Retire is constr index 3 (Maintain 0, Cancel 1, Fold 2, Retire 3,
-- Recover 4): the naming application validator's redeemer for ending a
-- name into custody. The list names the representative; the validator
-- binds it to the chain-carried token.
redeemerRetire :: ByteString -> PLC.Data
redeemerRetire rep =
    PLC.Constr 3 [PLC.List [PLC.B rep]]

-- | Spend redeemer @Fold { representatives }@.
foldRedeemer :: [ByteString] -> PLC.Data
foldRedeemer reps = PLC.Constr 2 [PLC.List (map PLC.B reps)]

-- | Mint redeemer @InsertApproval { controller, control, commitment }@.
insertApprovalRedeemer :: ByteString -> ByteString -> ByteString -> PLC.Data
insertApprovalRedeemer controller control commitment =
    PLC.Constr 1 [PLC.B controller, PLC.B control, PLC.B commitment]

-- | Mint redeemer @MintRepresentative@.
mintRepresentativeRedeemer :: PLC.Data
mintRepresentativeRedeemer = PLC.Constr 0 []

-- ---------------------------------------------------------
-- Submission helpers
-- ---------------------------------------------------------

submitAccepted :: Env -> String -> ConwayTx -> IO ()
submitAccepted env label signed =
    submitTx (envSubmit env) signed >>= \case
        Submitted _ ->
            emit "submit" (label <> ": accepted tx=" <> txIdHex signed)
        Rejected reason ->
            failWith
                ( label
                    <> ": the node refused an accepting row: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )

waitConfirmation :: String -> IO ()
waitConfirmation what = do
    threadDelay 5_000_000
    emit "confirm" ("confirmed on chain: " <> what)

-- ---------------------------------------------------------
-- Pinned identity
-- ---------------------------------------------------------

newtype NamingManifest = NamingManifest
    { manifestValidators :: [ManifestPin]
    }

data ManifestPin = ManifestPin
    { mpTitle :: T.Text
    , mpHash :: T.Text
    }

instance FromJSON NamingManifest where
    parseJSON = withObject "NamingManifest" $ \o ->
        NamingManifest <$> o .: "validators"

instance FromJSON ManifestPin where
    parseJSON = withObject "ManifestPin" $ \o ->
        ManifestPin <$> o .: "title" <*> o .: "hash"

checkPinnedApplication :: String -> IO ()
checkPinnedApplication appHex = do
    path <-
        fromMaybe "../naming-onchain/script-identity.json"
            <$> lookupEnv "NAMING_SCRIPT_IDENTITY"
    bytes <- BS.readFile path
    manifest <- either failWith pure (eitherDecode' (BSL.fromStrict bytes))
    let pins =
            [ mpHash p
            | p <- manifestValidators manifest
            , "application.application" `T.isPrefixOf` mpTitle p
            ]
    unless (length pins >= 3) $
        failWith
            "identity: fewer than three application.application pins in the \
            \manifest"
    unless (all (== T.pack appHex) pins) $
        failWith
            ( "identity: the manifest pins "
                <> show pins
                <> " but this run's blueprint hashes to 0x"
                <> appHex
            )

checkPinnedRepresentative :: String -> IO ()
checkPinnedRepresentative unappliedHex = do
    path <-
        fromMaybe "../naming-onchain/script-identity.json"
            <$> lookupEnv "NAMING_SCRIPT_IDENTITY"
    bytes <- BS.readFile path
    manifest <- either failWith pure (eitherDecode' (BSL.fromStrict bytes))
    let pins =
            [ mpHash p
            | p <- manifestValidators manifest
            , "representative.representative.mint" `T.isPrefixOf` mpTitle p
            ]
    unless (length pins >= 1) $
        failWith
            "identity: no representative.representative.mint pin in the \
            \manifest"
    unless (all (== T.pack unappliedHex) pins) $
        failWith
            ( "identity: the manifest pins unapplied representative hash(es) "
                <> show pins
                <> " but this run's blueprint code hashes to 0x"
                <> unappliedHex
            )

checkPinnedCustody :: String -> IO ()
checkPinnedCustody custodyHex = do
    path <-
        fromMaybe "../naming-onchain/script-identity.json"
            <$> lookupEnv "NAMING_SCRIPT_IDENTITY"
    bytes <- BS.readFile path
    manifest <- either failWith pure (eitherDecode' (BSL.fromStrict bytes))
    let pins =
            [ mpHash p
            | p <- manifestValidators manifest
            , "retirement_custody.retirement_custody" `T.isPrefixOf` mpTitle p
            ]
    unless (length pins >= 2) $
        failWith
            "identity: fewer than two retirement_custody pins in the \
            \manifest"
    unless (all (== T.pack custodyHex) pins) $
        failWith
            ( "identity: the manifest pins "
                <> show pins
                <> " but this run's blueprint hashes to 0x"
                <> custodyHex
            )

-- ---------------------------------------------------------
-- Narration and plumbing
-- ---------------------------------------------------------

emit :: String -> String -> IO ()
emit step detail = putStrLn ("[retirement] " <> step <> ": " <> detail)

failWith :: String -> IO a
failWith msg = throwIO (ErrorCall ("retirement-rows: " <> msg))

requireEnv :: String -> IO String
requireEnv name =
    lookupEnv name
        >>= maybe (failWith ("missing environment variable " <> name)) pure

hex :: ByteString -> String
hex = T.unpack . TE.decodeUtf8 . Base16.encode

txIdHex :: ConwayTx -> String
txIdHex tx = let TxId h = txIdTx tx in hex (hashToBytes (extractHash h))

showIn :: TxIn -> String
showIn (TxIn (TxId h) (TxIx i)) =
    hex (hashToBytes (extractHash h)) <> "#" <> show i

adaptProvider :: N2C.Provider IO -> Cage.Provider IO
adaptProvider p =
    Cage.Provider
        { Cage.queryUTxOs = N2C.queryUTxOs p
        , Cage.queryProtocolParams = N2C.queryProtocolParams p
        , Cage.evaluateTx = N2C.evaluateTx p
        , Cage.posixMsToSlot = N2C.posixMsToSlot p
        , Cage.posixMsCeilSlot = N2C.posixMsCeilSlot p
        }

verifyConnection :: (Show e) => Async (Either e ()) -> IO ()
verifyConnection nodeThread =
    poll nodeThread >>= \case
        Just (Left err) -> failWith ("node connection failed: " <> show err)
        Just (Right (Left err)) ->
            failWith ("node connection error: " <> show err)
        Just (Right (Right ())) ->
            failWith "node connection closed unexpectedly"
        Nothing -> pure ()

nextControlCommitmentOf :: ByteString -> ByteString
nextControlCommitmentOf bs =
    convert
        ( hash
            ( "singular/naming/next-control/v1"
                <> BS.singleton 0x00
                <> bs
            )
            :: Digest Blake2b_256
        )
