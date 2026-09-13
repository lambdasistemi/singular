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
import Control.Monad (unless, when)
import Crypto.Hash (Blake2b_256, Digest, hash)
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.Char (isHexDigit)
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Aeson (FromJSON (..), eitherDecode', encode, object, withObject, (.:), (.=))
import Data.List (isInfixOf, sortBy, sortOn)
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..), comparing)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Sequence.Strict qualified as StrictSeq
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.IO (BufferMode (..), hPutStrLn, hSetBuffering, stderr, stdout)

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address (Addr (..), serialiseAddr)
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Binary.Version (Version)
import Cardano.Ledger.Api.Scripts.Data (Data (..), Datum (..), binaryDataToData)
import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body (
    collateralInputsTxBodyL,
    feeTxBodyL,
    inputsTxBodyL,
    mintTxBodyL,
    mkBasicTxBody,
    outputsTxBodyL,
    referenceInputsTxBodyL,
    reqSignerHashesTxBodyL,
    scriptIntegrityHashTxBodyL,
 )
import Cardano.Ledger.Api.Tx.In (TxIn (..))
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
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
import Cardano.Ledger.BaseTypes (Network (..), StrictMaybe (..), TxIx (..))
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
import Cardano.MPFS.Cage.Trie (TrieManager (..))
import Cardano.MPFS.Cage.Trie qualified as Trie
import Cardano.MPFS.Cage.Trie.PureManager (mkPureTrieManager)
import Cardano.MPFS.Cage.TxBuilder.Boot (bootTokenImpl)
import Cardano.MPFS.Cage.TxBuilder.ConnectedFold (
    ConnectedFoldArgs (..),
    ConnectedMint (..),
    ConnectedSpend (..),
    RawRedeemer (..),
    connectedFoldTx,
    generousUnits,
    syncFoldedRequests,
 )
import Cardano.MPFS.Cage.TxBuilder.Internal (
    ConsumerBinding (..),
    addrKeyHashBytes,
    addrWitnessKeyHash,
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    computeScriptHash,
    computeScriptIntegrity,
    currentPosixMs,
    deriveConsumerBinding,
    extractCageDatum,
    findStateUtxo,
    mkCageScript,
    mkInlineDatum,
    mkRequestDatum,
    mkRequestScript,
    requestAddrFromCfg,
    scriptFromBytes,
    scriptHashBytes,
    spendingIndex,
    txInToRef,
 )
import Cardano.MPFS.Cage.TxBuilder.Request (requestInsertImpl, requestLockedAda)
import Cardano.MPFS.Cage.TxBuilder.Register (registerConsumerImpl)
import Cardano.MPFS.Cage.Types (
    CageDatum (..),
    OnChainOperation (..),
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

oldSeed, quorum1Seed, quorum2Seed, destSeed, wrongDestSeed, completerSeed :: ByteString
oldSeed = "s66-old-controller00000000000000"
quorum1Seed = "s66-quorum-member-one00000000000"
quorum2Seed = "s66-quorum-member-two00000000000"
destSeed = "s66-destination00000000000000000"
wrongDestSeed = "s66-wrong-custody0000000000000000"
completerSeed = "s77-completer-fresh-party0000000"

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
    consumerBytes <- case extractCompiledCode "consumer.consumer" mbp of
        Just bytes -> pure bytes
        Nothing ->
            failWith
                "consumer.consumer compiled code not found in the MPFS \
                \blueprint (every Modify withdraws the pinned consumer)"
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
        checkPinnedConsumer (hex (scriptHashBytes (computeScriptHash consumerBytes)))
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
        checkPinnedRepresentative repUnappliedHex
        emit
            "identity"
            ( "representative applied policy 0x"
                <> repAppliedHex
                <> " (the applied mint identity this run mints representatives under)"
            )
        tm <- mkPureTrieManager
        evDir <- evidenceDirFromEnv
        createDirectoryIfMissing True evDir
        evNext <- newIORef (0 :: Int)
        (cfg, tok) <- bootRetirementCage prov submit tm stateBytes requestBytes (SBS.toShort (scriptHashBytes repAppliedHash)) consumerBytes evDir evNext
        -- Registry-bound names (NOTE-007): derived post-boot once the cage
        -- token exists; every display, redeemer and minted value below uses
        -- these bindings (never the control-only shape).
        let repBytes = boundRepName cfg tok oldHash
            repTokens =
                Map.singleton
                    repAppliedPolicy
                    (Map.singleton (AssetName (SBS.toShort repBytes)) 1)
        createTrie tm tok
        -- Consumer stake registration (NOTE-020 item 2), BEFORE split:
        -- the pinned consumer's credential must be registered before the
        -- first Modify withdraws it, and registration must consume a
        -- pristine-genesis UTxO — never a pool fragment (poolRef entries
        -- go stale once spent; spending one breaks publish with
        -- already-included inputs). Funded by genesis, witnessed by it.
        unsignedReg <- registerConsumerImpl cfg prov genesisAddr
        let signedReg = addKeyWitness genesisSignKey unsignedReg
        regTag <- retainTxAt evDir evNext "consumer-registration" signedReg
        regResult <- submitTx submit signedReg
        case regResult of
            Submitted _ -> do
                retainOutcome evDir regTag "accepted" Nothing
                pure ()
            Rejected reason ->
                failWith ("consumer-registration: rejected: " <> show reason)
        _ <- waitConfirmation (txIdHex signedReg <> " (consumer-registration)")
        emit "consumer" "consumer stake credential registered; hook withdrawals are live"
        emit "split" "splitting the genesis wallet into funding UTxOs"
        pool <- splitGenesis prov submit 80
        poolRef <- newIORef pool
        scriptRefs <- publishRetirementRefs prov submit pp poolRef cfg tok script repAppliedScript (scriptFromBytes "naming-custody" custodyBytes)
        let env =                Env
                    { envProv = prov
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
                    , envCustodyScript = scriptFromBytes "naming-custody" custodyBytes
                    , envDatum = mkDatum
                    , envDatumDup = mkDatumDup
                    , envEvDir = evDir
                    , envEvNext = evNext
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
        -- Recovery-then-retire records (NOTE-024): same shape as
        -- accept1/accept2 (control oldAddr, commitment opens to
        -- destSeed, 2-member quorum) so each can rotate to the
        -- destination key and then retire with the CREATION hash.
        (txR1, recR1) <- setupRecoveryRecord env mkDatum "rr1" "rt-rr1"
        _ <- waitConfirmation (txR1 <> " (setup: rr1)")
        (txR2, recR2) <- setupRecoveryRecord env mkDatum "rr2" "rt-rr2"
        _ <- waitConfirmation (txR2 <> " (setup: rr2)")
        -- Permanent-retirement record (NOTE-027): a genuinely claimed
        -- name on the same shape, retired then completed into Over in
        -- the rows below (never a seeded Over).
        (txOver, recOver) <- setupRecoveryRecord env mkDatum "over" "rt-over"
        _ <- waitConfirmation (txOver <> " (setup: over)")
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
        -- Public creation material (NOTE-023 remaining path): the
        -- immutable key every Retire must carry. A third party retrieves
        -- (record, creation tx, creation hash, representative) from this
        -- log alone, recomputes the registry-bound name, and checks each
        -- retirement's key_hash equals the published creation hash.
        emit
            "creation-material"
            ( "accept1="
                <> showIn recAccept1
                <> " created-by="
                <> txA1
                <> " creation-control-hash=0x"
                <> hex oldHash
                <> " representative=0x"
                <> hex repBytes
            )
        emit
            "creation-material"
            ( "accept2="
                <> showIn recAccept2
                <> " created-by="
                <> txA2
                <> " creation-control-hash=0x"
                <> hex oldHash
                <> " representative=0x"
                <> hex repBytes
            )
        emit
            "creation-material"
            ( "rr1="
                <> showIn recR1
                <> " created-by="
                <> txR1
                <> " creation-control-hash=0x"
                <> hex oldHash
                <> " representative=0x"
                <> hex repBytes
                <> " (recovery-then-retire controller route)"
            )
        emit
            "creation-material"
            ( "rr2="
                <> showIn recR2
                <> " created-by="
                <> txR2
                <> " creation-control-hash=0x"
                <> hex oldHash
                <> " representative=0x"
                <> hex repBytes
                <> " (recovery-then-retire quorum route)"
            )
        emit
            "creation-material"
            ( "over="
                <> showIn recOver
                <> " created-by="
                <> txOver
                <> " creation-control-hash=0x"
                <> hex oldHash
                <> " representative=0x"
                <> hex repBytes
                <> " (permanent-retirement journey record)"
            )
        case mode of
            MainRun -> runRows env recAccept1 recAccept2 recRefusals recDuplicates recR1 recR2 recOver
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
    , envCustodyScript :: Script ConwayEra
    , envDatum :: NamingDatum
    , envDatumDup :: NamingDatum
    , envEvDir :: FilePath
    , envEvNext :: IORef Int
    }

-- ---------------------------------------------------------
-- The seven in-scope rows
-- ---------------------------------------------------------

runRows :: Env -> TxIn -> TxIn -> TxIn -> TxIn -> TxIn -> TxIn -> TxIn -> IO ()
runRows env recAccept1 recAccept2 recRefusals recDuplicates recR1 recR2 recOver = do
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
    signedLT01 <- rowLT01 env snapA1
    -- LT09 replays LT01's exact transaction against the consumed record.
    rowLT09 env recAccept1 signedLT01
    -- LT02 accepts, consuming accept2 into custody.
    snapA2 <- mustSnap env recAccept2
    _ <- rowLT02 env snapA2
    -- Recovery-then-retire (NOTE-024): rotate to the destination key,
    -- then retire with the CREATION hash (immutable across rotation).
    snapR1 <- mustSnap env recR1
    snapR1r <- rowRecoverRecord env snapR1 "RR1"
    signedRR1 <- rowRetireRecoveredController env snapR1r
    snapR2 <- mustSnap env recR2
    snapR2r <- rowRecoverRecord env snapR2 "RR2"
    _ <- rowRetireRecoveredQuorum env snapR2r
    -- Mismatched pair (NOTE-029 N2): LT01 custody with the RR1
    -- request must refuse (wrong pairing, each piece genuine).
    rowN2Mismatch env signedLT01 signedRR1
    -- Permanent retirement (NOTE-027/028): the genuinely claimed over
    -- record retires (queueing its pending Over-update request),
    -- refuses replay and withdrawal, completes permissionlessly into
    -- Over, and refuses reuse — all from the same reached state.
    snapOver <- mustSnap env recOver
    signedOverRetire <- rowOVRetire env snapOver
    rowOVReplay env recOver signedOverRetire
    rowLO01 env signedOverRetire snapOver
    custodyOver <- overCustodyOut env signedOverRetire "OV-retire"
    reqOver <- overRequestOut env signedOverRetire "OV-retire"
    let completerAddr = enterpriseAddr (keyHashFromSignKey (mkSignKey completerSeed))
    (completerFund, _completerColl) <- fundCompleter env completerAddr
    rowOVWithdrawRefused env custodyOver completerAddr
    rowOVBurnOnlyRefused env custodyOver
    signedComplete <- rowOVComplete env custodyOver reqOver completerFund
    rowLO02 env signedComplete snapOver
    rowLX01 env
    -- Final no-trace sweep.
    finalNoTrace env recRefusals
    emit
        "complete"
        ( "the retirement rows executed on a real devnet; every refusal \
          \attributed to its reason, custody and the record's end proved \
          \from the chain, retirement completed permissionlessly into Over \
          \with the burn observed, the state after the refusals unchanged"
        )

rowLT01 :: Env -> Snap -> IO ConwayTx
rowLT01 env snap = do
    tx <- retireTx env snap (envCustodyAddr env) [envOldHash env] "rt-accept1"
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
            <> " key-hash=0x"
            <> hex (envOldHash env)
            <> " (equals the published accept1 creation hash; the \
               \controller alone retires the name; the representative \
               \is at custody and the record is gone)"
        )
    pure signed

rowLT02 :: Env -> Snap -> IO ConwayTx
rowLT02 env snap = do
    tx <- retireTx env snap (envCustodyAddr env) [envQuorum1Hash env, envQuorum2Hash env] "rt-accept2"
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
            <> " key-hash=0x"
            <> hex (envOldHash env)
            <> " (equals the published accept2 creation hash — the key is \
               \immutable across routes; the fixed registration quorum \
               \alone retires the name, with no controller signature; the \
               \representative is at custody and the record is gone)"
        )
    pure signed

-- | Control-record retirement (NOTE-033): valid quorum retire as
-- control-mode setup (accepts, not a guard) — own labels, same
-- checks as the quorum route.
rowRetireCtl :: Env -> Snap -> IO ConwayTx
rowRetireCtl env snap = do
    tx <- retireTx env snap (envCustodyAddr env) [envQuorum1Hash env, envQuorum2Hash env] "rt-ctl"
    let signed =
            addKeyWitness
                (mkSignKey quorum1Seed)
                (addKeyWitness (mkSignKey quorum2Seed) (addKeyWitness genesisSignKey tx))
    submitAccepted env "CTL-retire" signed
    _ <- waitConfirmation (txIdHex signed <> " (CTL-retire)")
    assertCustody env "CTL-retire" signed
    assertGone env snap "CTL-retire"
    emit
        "row"
        ( "CTL-control-retirement-accepts: accepted tx="
            <> txIdHex signed
            <> " (control record for the eval-branch controls; quorum route)"
        )
    pure signed

-- | The recovery destination: destSeed's enterprise address and its
-- hash (both module-level seeds, no hidden constants per row).
recoveryDest :: (Addr, ByteString)
recoveryDest =
    let addr = enterpriseAddr (keyHashFromSignKey (mkSignKey destSeed))
     in (addr, addrKeyHashBytes addr)

-- | Recover a record to the destination key: real on-chain rotation
-- (control oldAddr -> destAddr). Binds the EXACT observed successor
-- (NOTE-025): the fresh snap of the accepted recovery transaction's
-- outputs[0] — never the old snapshot, never expected data. Rotation,
-- payment/quorum preservation, representative carriage and coin
-- preservation are all asserted on the observed successor; the old
-- input's consumption is asserted on chain. Returns the successor snap.
rowRecoverRecord :: Env -> Snap -> String -> IO Snap
rowRecoverRecord env snap label = do
    current <- chainDatumOf env snap (label <> "-pre")
    let (destAddr, destHash) = recoveryDest
        freshCommitment = BS.replicate 32 0x01
    when (freshCommitment == nextControlCommitment current) $
        failWith (label <> ": fresh commitment collides (impossible case)")
    let successor =
            current
                { controlAddress = envDestCodec env
                , nextControlCommitment = freshCommitment
                }
    tx <-
        recoverTx
            env
            snap
            (serialiseAddr destAddr)
            [envRepBytes env]
            (scriptHashBytes (envScriptHash env))
            successor
            [destHash]
    let signed = addKeyWitness (mkSignKey destSeed) (addKeyWitness genesisSignKey tx)
    unless
        (Set.singleton (addrWitnessKeyHash destHash) == (signed ^. bodyTxL . reqSignerHashesTxBodyL))
        $ failWith (label <> ": required signers must be exactly the revealed key")
    when
        ( any
            (`Set.member` (signed ^. bodyTxL . reqSignerHashesTxBodyL))
            [addrWitnessKeyHash (envOldHash env), addrWitnessKeyHash (envQuorum1Hash env), addrWitnessKeyHash (envQuorum2Hash env)]
        )
        $ failWith (label <> ": neither the old controller nor quorum may sign the recovery")
    submitAccepted env (label <> "-recover") signed
    _ <- waitConfirmation (txIdHex signed <> " (" <> label <> " recover)")
    -- The exact observed successor: fresh chain snap of outputs[0].
    snapSucc <- mustSnap env (TxIn (txIdTx signed) (TxIx 0))
    rotated <- chainDatumOf env snapSucc (label <> "-rotated")
    unless (controlAddress rotated == envDestCodec env) $
        failWith (label <> ": rotated control is not the destination")
    unless (retirementQuorum rotated == retirementQuorum current) $
        failWith (label <> ": recovery altered the quorum")
    unless (paymentDestination rotated == paymentDestination current) $
        failWith (label <> ": recovery altered the payment destination")
    unless (snapTokens snapSucc == snapTokens snap) $
        failWith (label <> ": recovery altered the carried tokens")
    unless (snapCoin snapSucc == snapCoin snap) $
        failWith (label <> ": recovery altered the lovelace")
    -- The old exact input was consumed on chain.
    assertGone env snap (label <> "-recovery-consumed")
    emit
        "row"
        ( label
            <> "-recovered: rotated to control 0x"
            <> hex (serialiseAddr destAddr)
            <> " in tx="
            <> txIdHex signed
            <> " (successor bound from chain, old input consumed)"
        )
    pure snapSucc

-- | Retire a RECOVERED record via the controller route: the NEW
-- controller (destSeed) signs, but the redeemer carries the CREATION
-- hash (envOldHash) — the immutable key, no longer the current
-- control. Reuses the custody/gone assertions.
rowRetireRecoveredController :: Env -> Snap -> IO ConwayTx
rowRetireRecoveredController env snap = do
    let (_destAddr, destHash) = recoveryDest
    tx <- retireTx env snap (envCustodyAddr env) [destHash] "rt-rr1"
    let signed = addKeyWitness (mkSignKey destSeed) (addKeyWitness genesisSignKey tx)
    unless
        (Set.singleton (addrWitnessKeyHash destHash) == (signed ^. bodyTxL . reqSignerHashesTxBodyL))
        $ failWith "RR1: required signers must be exactly the recovered controller key"
    when
        ( any
            (`Set.member` (signed ^. bodyTxL . reqSignerHashesTxBodyL))
            [addrWitnessKeyHash (envQuorum1Hash env), addrWitnessKeyHash (envQuorum2Hash env)]
        )
        $ failWith "RR1: no quorum member may be among the required signers"
    submitAccepted env "RR1" signed
    _ <- waitConfirmation (txIdHex signed <> " (RR1)")
    assertCustody env "RR1" signed
    assertGone env snap "RR1"
    emit
        "row"
        ( "RR1-recovery-then-controller-retire-accepts: accepted tx="
            <> txIdHex signed
            <> " key-hash=0x"
            <> hex (envOldHash env)
            <> " (the CREATION hash, not the current rotated control; the \
               \recovered controller alone retires; representative at custody)"
        )
    pure signed

-- | Retire a RECOVERED record via the quorum route: quorum signs, the
-- recovered controller must not, key_hash is still the creation hash.
rowRetireRecoveredQuorum :: Env -> Snap -> IO ConwayTx
rowRetireRecoveredQuorum env snap = do
    tx <- retireTx env snap (envCustodyAddr env) [envQuorum1Hash env, envQuorum2Hash env] "rt-rr2"
    let signed =
            addKeyWitness
                (mkSignKey quorum1Seed)
                (addKeyWitness (mkSignKey quorum2Seed) (addKeyWitness genesisSignKey tx))
    unless
        ( Set.fromList
                [addrWitnessKeyHash (envQuorum1Hash env), addrWitnessKeyHash (envQuorum2Hash env)]
                == (signed ^. bodyTxL . reqSignerHashesTxBodyL)
        )
        $ failWith "RR2: required signers must be exactly the two quorum members"
    when
        ( Set.member
            (addrWitnessKeyHash (envOldHash env))
            (signed ^. bodyTxL . reqSignerHashesTxBodyL)
        )
        $ failWith "RR2: the original controller must not be among the required signers"
    submitAccepted env "RR2" signed
    _ <- waitConfirmation (txIdHex signed <> " (RR2)")
    assertCustody env "RR2" signed
    assertGone env snap "RR2"
    emit
        "row"
        ( "RR2-recovery-then-quorum-retire-accepts: accepted tx="
            <> txIdHex signed
            <> " key-hash=0x"
            <> hex (envOldHash env)
            <> " (the CREATION hash surviving rotation; quorum alone \
               \retires with no controller signature; representative at custody)"
        )
    pure signed

rowLT03 :: Mode -> Env -> Snap -> IO ()
rowLT03 mode env snap = do
    tx <- retireTx env snap (envCustodyAddr env) [envQuorum1Hash env] "rt-refusals"
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
    tx <- retireTx env snap (envCustodyAddr env) [envQuorum1Hash env] "rt-duplicates"
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
    tx <- retireTx env snap (envWrongDestAddr env) [envOldHash env] "rt-refusals"
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
            tag <- retainTx env "LT09-replay" signedLT01
            retainOutcome (envEvDir env) tag "refused" (Just (T.unpack (TE.decodeUtf8Lenient reason)))
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

-- ---------------------------------------------------------
-- Permanent retirement (NOTE-027/028): connected Over journey
-- ---------------------------------------------------------

-- | A UTxO carries the run's representative once under the applied
-- representative policy (shared shape: custody assertions and Over
-- resolution below).
carriesOverRep :: Env -> (TxIn, TxOut ConwayEra) -> Bool
carriesOverRep env (_, o) = case o ^. valueTxOutL of
    MaryValue _ (MultiAsset ma) ->
        ( Map.lookup (envRepPolicy env) ma
            >>= Map.lookup (AssetName (SBS.toShort (envRepBytes env)))
        )
            == Just 1

-- | Resolve the single custody output of an accepted retirement
-- (exactly one output of the tx carries the representative at the
-- custody address — anything else fails the row, never assumed).
overCustodyOut :: Env -> ConwayTx -> String -> IO (TxIn, TxOut ConwayEra)
overCustodyOut env signed label = do
    threadDelay 5_000_000
    utxos <- Cage.queryUTxOs (envProv env) (envCustodyAddr env)
    case filter (carriesOverRep env) (utxosByTxId utxos (txIdHex signed)) of
        [out] -> pure out
        mine ->
            failWith
                ( label
                    <> ": expected exactly one rep-carrying custody output, found "
                    <> show (length mine)
                )

-- | Resolve the single pending-request output of an accepted
-- retirement (the Over-update the route-authorized retire queued).
overRequestOut :: Env -> ConwayTx -> String -> IO (TxIn, TxOut ConwayEra)
overRequestOut env signed label = do
    let reqAddr = requestAddrFromCfg (envCfg env) (envTok env) Testnet
    utxos <- Cage.queryUTxOs (envProv env) reqAddr
    case utxosByTxId utxos (txIdHex signed) of
        [out] -> pure out
        mine ->
            failWith
                ( label
                    <> ": expected exactly one request output, found "
                    <> show (length mine)
                )

-- | The runner mirror root, hex — must equal the chain root before
-- any mirror-bound read means anything (D-013 discipline).
mirrorRootHex :: Env -> IO String
mirrorRootHex env =
    withTrie (envTrie env) (envTok env) $ \trie -> do
        r <- Trie.getRoot trie
        pure (hex (unRoot r))

assertMirrorHealthy :: Env -> String -> IO ()
assertMirrorHealthy env label = do
    chain <- chainRetirementRoot env
    mirror <- mirrorRootHex env
    unless (chain == mirror) $
        failWith
            ( label
                <> ": runner mirror root 0x"
                <> mirror
                <> " differs from chain root 0x"
                <> chain
                <> " — mirror-bound reads prove nothing"
            )

mirrorValue :: Env -> ByteString -> IO (Maybe ByteString)
mirrorValue env key =
    withTrie (envTrie env) (envTok env) $ \trie -> Trie.lookup trie key

repPolicyHex :: Env -> String
repPolicyHex env = hex (scriptHashBytes rh) where PolicyID rh = envRepPolicy env

rowOVRetire :: Env -> Snap -> IO ConwayTx
rowOVRetire env snap = do
    tx <- retireTx env snap (envCustodyAddr env) [envOldHash env] "rt-over"
    let signed = addKeyWitness (mkSignKey oldSeed) (addKeyWitness genesisSignKey tx)
    unless
        (Set.singleton (addrWitnessKeyHash (envOldHash env)) == (signed ^. bodyTxL . reqSignerHashesTxBodyL))
        $ failWith "OV-retire: required signers must be exactly the controller payment key"
    submitAccepted env "OV-retire" signed
    _ <- waitConfirmation (txIdHex signed <> " (OV-retire)")
    assertCustody env "OV-retire" signed
    assertGone env snap "OV-retire"
    emit
        "row"
        ( "OV-retire-controller-retirement-accepts: accepted tx="
            <> txIdHex signed
            <> " key-hash=0x"
            <> hex (envOldHash env)
            <> " (the genuinely claimed over record retires by the \
               \controller alone; representative at custody, record gone; \
               \the same transaction queues this key's pending Over-update \
               \request)"
        )
    pure signed

rowOVReplay :: Env -> TxIn -> ConwayTx -> IO ()
rowOVReplay env _consumedIn signedOver = do
    result <- submitTx (envSubmit env) signedOver
    case result of
        Submitted _ ->
            failWith
                "OV-replay: the replay was ACCEPTED — a consumed record authorized retirement twice"
        Rejected reason -> do
            tag <- retainTx env "OV-replay" signedOver
            retainOutcome (envEvDir env) tag "refused" (Just (T.unpack (TE.decodeUtf8Lenient reason)))
            let reasonText = T.unpack (TE.decodeUtf8Lenient reason)
                allSpent = "All inputs are spent" `isInfixOf` reasonText
            unless allSpent $
                failWith
                    ( "OV-replay: reason mismatch — expected the ledger to refuse \
                      \the replay in phase 1 naming the consumed output "
                        <> txIdHex signedOver
                        <> " but the node said <"
                        <> reasonText
                        <> ">"
                    )
            emit
                "row"
                ( "OV-replay-retirement-replay-refused: REFUSED, reason matched \
                  \(model reason naming-record-unavailable): "
                    <> reasonText
                    <> " — the consumed record cannot authorize again; resolution \
                       \of the over key cannot yield an active record"
                )

rowLO01 :: Env -> ConwayTx -> Snap -> IO ()
rowLO01 env signed snap = do
    assertMirrorHealthy env "LO01"
    keyPresent <- mirrorValue env "rt-over"
    case keyPresent of
        Just _ -> pure ()
        Nothing ->
            failWith "LO01: over key absent from the chain-synced mirror — expected present (pending)"
    root <- mirrorRootHex env
    emit
        "row"
        ( "LO01-retirement-pending-visible: representative 0x"
            <> hex (envRepBytes env)
            <> " under policy 0x"
            <> repPolicyHex env
            <> " held at custody 0x"
            <> envCustodyHex env
            <> " in tx "
            <> txIdHex signed
            <> "; record "
            <> showIn (snapIn snap)
            <> " gone from the application validator; key rt-over present in \
               \the chain-synced mirror (root 0x"
            <> root
            <> ") — pending (presence only: the Pure backend echoes the key hash, never stored values), and resolution \
               \cannot yield an active record: no record UTxO exists at the \
               \application validator (queried above) and the consumed record \
               \cannot authorize again (OV-replay refused above)"
        )

rowOVWithdrawRefused :: Env -> (TxIn, TxOut ConwayEra) -> Addr -> IO ()
rowOVWithdrawRefused env custody completerAddr = do
    (fund, coll) <- takeFundCollateral env
    tx <- withdrawTx env custody fund coll completerAddr
    let signed = addKeyWitness genesisSignKey tx
    expectRefusedMarker
        MainRun
        env
        "OV-withdraw-refused"
        "retirement-withdrawal-refused"
        (envCustodyHex env)
        "the retirement custody script"
        "the custody script enforces the burn: the same spend without it refuses"
        signed

-- | Burn-only attempt (NOTE-029 N1): custody spend plus the exact
-- burn, but NO registry state input and NO request fold. Must refuse
-- at the executing layer (absent-transition refusal) — this is the
-- witness shape NOTE-028 closed and NOTE-029 keeps closed.
rowOVBurnOnlyRefused :: Env -> (TxIn, TxOut ConwayEra) -> IO ()
rowOVBurnOnlyRefused env custody = do
    (fund, coll) <- takeFundCollateral env
    tx <- burnOnlyTx env custody fund coll
    let signed = addKeyWitness genesisSignKey tx
    expectRefusedMarker
        MainRun
        env
        "N1-burn-only-refused"
        "completion-binds-transition"
        (envCustodyHex env)
        "the retirement custody script"
        "a burn with no registry transition refuses"
        signed

-- | Mismatched pair (NOTE-029 N2): LT01's live custody with RR1's
-- pending request — each piece genuine (live custody, valid Update
-- proof, exact burn of the custody-held rep), but the pairing is
-- wrong (different creator transactions). Must refuse at local
-- evaluation naming the custody script (co-creation), spending
-- nothing and losing no collateral.
-- | Outcome of a control probe (NOTE-033 item 1): control modes
-- catch their own expected firings and continue to the pre-existing
-- terminal fail, so MainRun evidence legs never churn for controls.
-- `ProbeFired` (with the firing quoted) continues; `ProbeBroken`
-- fails the run loudly.
data ProbeOutcome = ProbeFired String | ProbeBroken String

-- | Continue on a correctly fired control, fail on anything else.
requireFired :: String -> ProbeOutcome -> IO ()
requireFired label = \case
    ProbeFired detail -> emit "control" (label <> " control fired correctly: " <> detail)
    ProbeBroken detail -> failWith ("CONTROL broken: " <> label <> ": " <> detail)

-- | Build a mismatched-pair fold (N2 shape): the given custody with
-- the given foreign request. Shared by the MainRun row and both
-- control modes; callers pin the outcome (refusal, wrong marker, or
-- acceptance). Throws local-evaluation failures as exceptions.
buildMismatchFold ::
    Env ->
    (TxIn, TxOut ConwayEra) ->
    (TxIn, TxOut ConwayEra) ->
    (TxIn, TxOut ConwayEra) ->
    Addr ->
    IO (ConwayTx, Root)
buildMismatchFold env custody reqUtxo feeUtxo feeAddr = do
    (stateIn, stateOut) <- queryRetirementState env
    connectedFoldTx
        ConnectedFoldArgs
            { cfaCfg = envCfg env
            , cfaProvider = envProv env
            , cfaTrie = envTrie env
            , cfaToken = envTok env
            , cfaFeeAddr = feeAddr
            , cfaStateUtxo = (stateIn, stateOut)
            , cfaReqUtxos = [reqUtxo]
            , cfaFeeUtxo = feeUtxo
            , cfaPp = envPp env
            , cfaSpends =
                [ ConnectedSpend
                    { csUtxo = custody
                    , csRedeemer = RawRedeemer custodySpendRedeemer
                    , csScript = envCustodyScript env
                    }
                ]
            , cfaMints =
                [ ConnectedMint
                    { cmPolicy = envRepPolicy env
                    , cmAssets = Map.singleton (AssetName (SBS.toShort (envRepBytes env))) (-1)
                    , cmRedeemer = RawRedeemer burnRepresentativeRedeemer
                    , cmScript = envRepScript env
                    }
                ]
            , cfaOutputs = []
            , cfaSigners = []
            , cfaRefUtxos = envRefUtxos env
            , cfaSkipEval = False
            , cfaAttachScripts = []
            , cfaAdjustRoot = id
            }

-- | Queue, claim and build a refold for a spelling (LX01 shape):
-- returns the build outcome (`Left` = local-evaluation refusal).
-- Shared by the MainRun row and both control modes. The claim
-- approval binds control, not spelling, so any spelling's request
-- refolds through the same claim shape.
refoldAttempt :: Env -> ByteString -> IO (Either SomeException ConwayTx)
refoldAttempt env spelling = do
    (reqIn, reqOut) <- submitRetirementRequest env spelling (envRepBytes env)
    emit
        "row"
        ( "refold-queued: insert request for "
            <> show spelling
            <> " accepted "
            <> showIn reqIn
            <> " (queueing is not the refusal; the fold is)"
        )
    (claimIn, claimLive) <- lx01Claim env
    try (lx01Fold env (reqIn, reqOut) (claimIn, claimLive)) :: IO (Either SomeException ConwayTx)

rowN2Mismatch :: Env -> ConwayTx -> ConwayTx -> IO ()
rowN2Mismatch env signedLT01 signedRR1 = do
    custodyLT01 <- overCustodyOut env signedLT01 "N2-lt01-custody"
    reqRR1 <- overRequestOut env signedRR1 "N2-rr1-request"
    feeUtxo <- queryRetirementFee env
    foldResult <-
        try (buildMismatchFold env custodyLT01 reqRR1 feeUtxo genesisAddr) :: IO (Either SomeException (ConwayTx, Root))
    case foldResult of
        Left err -> do
            -- Strict attribution (NOTE-030): named custody-script
            -- field, semantic (never budget), at the custody spend.
            pinEvalRefusal "N2" (show err) (envCustodyHex env) "ConwaySpending"
            emit
                "row"
                ( "N2-mismatched-pair-refused: REFUSED at build — the fold pairs \
                  \LT01 custody with the RR1 request (different creators): the \
                  \custody script refuses the pairing: "
                    <> show err
                )
        Right _ ->
            failWith "N2: mismatched-pair fold BUILT — expected local-evaluation refusal (co-creation)"

-- | N2 wrong-reason control (NOTE-033): the mismatched pair must
-- refuse, and the strict pin must reject the impossible marker.
rowN2ControlWrongReason :: Env -> ConwayTx -> (TxIn, TxOut ConwayEra) -> IO ProbeOutcome
rowN2ControlWrongReason env signedCustody decoyReq = do
    custody <- overCustodyOut env signedCustody "N2-CWR-custody"
    feeUtxo <- queryRetirementFee env
    foldResult <- try (buildMismatchFold env custody decoyReq feeUtxo genesisAddr) :: IO (Either SomeException (ConwayTx, Root))
    case foldResult of
        Left err -> do
            pinOutcome <-
                try (pinEvalRefusal "N2-CWR" (show err) wrongReasonMarker "ConwaySpending") :: IO (Either SomeException ())
            case pinOutcome of
                Left pinErr -> pure (ProbeFired (show pinErr))
                Right _ -> pure (ProbeBroken "impossible marker MATCHED an eval refusal (matcher broken)")
        Right _ -> pure (ProbeBroken "mismatched-pair fold BUILT (occupied pairing bypassed?)")

-- | N2 valid-mode refusal (NOTE-033): the mismatched pair refuses
-- under strict pins (recorded, continued to the terminal fail).
rowN2ValidRefusal :: Env -> ConwayTx -> (TxIn, TxOut ConwayEra) -> IO ProbeOutcome
rowN2ValidRefusal env signedCustody decoyReq = do
    custody <- overCustodyOut env signedCustody "N2-CV-custody"
    feeUtxo <- queryRetirementFee env
    foldResult <- try (buildMismatchFold env custody decoyReq feeUtxo genesisAddr) :: IO (Either SomeException (ConwayTx, Root))
    case foldResult of
        Left err -> do
            pinEvalRefusal "N2-CV" (show err) (envCustodyHex env) "ConwaySpending"
            pure (ProbeFired "mismatched pair refused under strict pins")
        Right _ -> pure (ProbeBroken "mismatched-pair fold BUILT (expected refusal)")

-- | N2 valid-mode acceptance (NOTE-033): the CORRECT pair builds and
-- submits accepted (genuine completion shape); the mirror syncs the
-- completed Update (later builds need the current root); caught,
-- recorded and continued (the run's terminal fail stays
-- LT03-made-valid).
rowN2ValidAccept :: Env -> ConwayTx -> (TxIn, TxOut ConwayEra) -> IO ProbeOutcome
rowN2ValidAccept env signedCustody ownReq = do
    custody <- overCustodyOut env signedCustody "N2-CV-custody"
    feeUtxo <- queryRetirementFee env
    (unsigned, _) <- buildMismatchFold env custody ownReq feeUtxo genesisAddr
    let signed = addKeyWitness genesisSignKey unsigned
    tag <- retainTx env "N2-CV-accept" signed
    result <- submitTx (envSubmit env) signed
    case result of
        Submitted _ -> do
            retainOutcome (envEvDir env) tag "accepted" Nothing
            _ <- waitConfirmation (txIdHex signed <> " (N2-CV accept)")
            syncFoldedRequests (envTrie env) (envTok env) [ownReq]
            pure (ProbeFired "correct pair accepted as constructed")
        Rejected reason ->
            pure (ProbeBroken ("correct pair unexpectedly refused: " <> T.unpack (TE.decodeUtf8Lenient reason)))

-- | LX01 wrong-reason control (NOTE-033): the occupied-key refold
-- must refuse, and the strict pin must reject the impossible marker.
rowLX01ControlWrongReason :: Env -> ByteString -> IO ProbeOutcome
rowLX01ControlWrongReason env spelling = do
    result <- refoldAttempt env spelling
    case result of
        Left err -> do
            pinOutcome <-
                try (pinEvalRefusal "LX01-CWR" (show err) wrongReasonMarker "ConwaySpending") :: IO (Either SomeException ())
            case pinOutcome of
                Left pinErr -> pure (ProbeFired (show pinErr))
                Right _ -> pure (ProbeBroken "impossible marker MATCHED an eval refusal (matcher broken)")
        Right _ -> pure (ProbeBroken "occupied-key refold BUILT (absence proof produced for occupied key?)")

-- | LX01 valid-mode refusal (NOTE-033): the occupied-key refold
-- refuses under strict pins (recorded, continued to terminal).
rowLX01ValidRefusal :: Env -> ByteString -> IO ProbeOutcome
rowLX01ValidRefusal env spelling = do
    result <- refoldAttempt env spelling
    case result of
        Left err -> do
            let stateHex = hex (scriptHashBytes (cfgScriptHash (envCfg env)))
            pinEvalRefusal "LX01-CV" (show err) stateHex "ConwaySpending"
            pure (ProbeFired "occupied refold refused under strict pins")
        Right _ -> pure (ProbeBroken "occupied-key refold BUILT (expected refusal)")

-- | LX01 valid-mode acceptance (NOTE-033): the fresh-key refold
-- builds and submits accepted; caught, recorded and continued (the
-- run's terminal fail stays LT03-made-valid).
rowLX01ValidAccept :: Env -> ByteString -> IO ProbeOutcome
rowLX01ValidAccept env spelling = do
    result <- refoldAttempt env spelling
    case result of
        Left err -> pure (ProbeBroken ("fresh refold unexpectedly refused: " <> show err))
        Right built -> do
            let signed = addKeyWitness genesisSignKey built
            tag <- retainTx env "LX01-CV-accept" signed
            outcome <- submitTx (envSubmit env) signed
            case outcome of
                Submitted _ -> do
                    retainOutcome (envEvDir env) tag "accepted" Nothing
                    _ <- waitConfirmation (txIdHex signed <> " (LX01-CV accept)")
                    pure (ProbeFired "fresh-key fold accepted as constructed")
                Rejected reason ->
                    pure (ProbeBroken ("fresh fold unexpectedly refused: " <> T.unpack (TE.decodeUtf8Lenient reason)))

rowOVComplete :: Env -> (TxIn, TxOut ConwayEra) -> (TxIn, TxOut ConwayEra) -> (TxIn, TxOut ConwayEra) -> IO ConwayTx
rowOVComplete env custody reqUtxo feeUtxo = do
    let completerKey = mkSignKey completerSeed
        completerAddr = enterpriseAddr (keyHashFromSignKey completerKey)
        completerHash = addrKeyHashBytes completerAddr
    when (completerHash `elem` [envOldHash env, envQuorum1Hash env, envQuorum2Hash env]) $
        failWith "OV-complete: completer key is not fresh — it collides with a route party"
    (stateIn, stateOut) <- queryRetirementState env
    rootBefore <- chainRetirementRoot env
    (unsigned, _newRoot) <-
        connectedFoldTx
            ConnectedFoldArgs
                { cfaCfg = envCfg env
                , cfaProvider = envProv env
                , cfaTrie = envTrie env
                , cfaToken = envTok env
                , cfaFeeAddr = completerAddr
                , cfaStateUtxo = (stateIn, stateOut)
                , cfaReqUtxos = [reqUtxo]
                , cfaFeeUtxo = feeUtxo
                , cfaPp = envPp env
                , cfaSpends =
                    [ ConnectedSpend
                        { csUtxo = custody
                        , csRedeemer = RawRedeemer custodySpendRedeemer
                        , csScript = envCustodyScript env
                        }
                    ]
                , cfaMints =
                    [ ConnectedMint
                        { cmPolicy = envRepPolicy env
                        , cmAssets = Map.singleton (AssetName (SBS.toShort (envRepBytes env))) (-1)
                        , cmRedeemer = RawRedeemer burnRepresentativeRedeemer
                        , cmScript = envRepScript env
                        }
                    ]
                , cfaOutputs = []
                , cfaSigners = []
                , cfaRefUtxos = envRefUtxos env
                , cfaAttachScripts = []
                , cfaSkipEval = False
                , cfaAdjustRoot = id
                }
    -- Permissionless: no required signer of any kind (the completer
    -- witnesses only as the fee-paying input owner, never as an
    -- authorizer — custody, state and burn need no signature).
    unless (Set.null (unsigned ^. bodyTxL . reqSignerHashesTxBodyL)) $
        failWith "OV-complete: required signers must be empty — completion is permissionless"
    let signed = addKeyWitness completerKey unsigned
    assertBurnField env "OV-complete" signed
    submitAccepted env "OV-complete" signed
    _ <- waitConfirmation (txIdHex signed <> " (OV-complete)")
    syncFoldedRequests (envTrie env) (envTok env) [reqUtxo]
    rootAfter <- chainRetirementRoot env
    when (rootAfter == rootBefore) $
        failWith "OV-complete: registry root unchanged — no authentic transition happened"
    assertCustodyConsumed env custody "OV-complete"
    assertNoRepOutputs env "OV-complete" signed
    emit
        "row"
        ( "OV-complete-permissionless-completion-accepts: accepted tx="
            <> txIdHex signed
            <> " burning 0x"
            <> hex (envRepBytes env)
            <> " under policy 0x"
            <> repPolicyHex env
            <> " (mint field -1, custody consumed, registry root 0x"
            <> rootBefore
            <> " -> 0x"
            <> rootAfter
            <> "); required signers empty, fee paid and witnessed by fresh key 0x"
            <> hex completerHash
            <> " (in none of the route sets); the pending Over-update request \
               \folded with the burn in one registry transition"
        )
    pure signed

-- | The completion's mint field burns exactly the run representative
-- once under the applied representative policy (read off the built
-- bytes, pre-submit).
assertBurnField :: Env -> String -> ConwayTx -> IO ()
assertBurnField env label signed = do
    let expected =
            MultiAsset
                ( Map.singleton
                    (envRepPolicy env)
                    (Map.singleton (AssetName (SBS.toShort (envRepBytes env))) (-1))
                )
    unless ((signed ^. bodyTxL . mintTxBodyL) == expected) $
        failWith (label <> ": mint field is not exactly the representative burn")

-- | A custody outref is consumed (not live at the custody address).
assertCustodyConsumed :: Env -> (TxIn, TxOut ConwayEra) -> String -> IO ()
assertCustodyConsumed env (custodyIn, _) label = do
    utxos <- Cage.queryUTxOs (envProv env) (envCustodyAddr env)
    when (any ((== custodyIn) . fst) utxos) $
        failWith (label <> ": custody output " <> showIn custodyIn <> " still live — burn not observed")
    emit "custody" (label <> ": custody output " <> showIn custodyIn <> " observed consumed")

-- | The completion leaves no representative-carrying outputs: the
-- burn is total (the shared representative name means other live
-- records and custodys legitimately hold the same bytes, so global
-- absence is unassertable and never claimed — what is proved is that
-- THIS completion creates no live resolution: no output carries the
-- burned asset forward). Read off the built bytes, pre-submit.
assertNoRepOutputs :: Env -> String -> ConwayTx -> IO ()
assertNoRepOutputs env label signed = do
    let outs = toList (signed ^. bodyTxL . outputsTxBodyL)
        hasRep o = case o ^. valueTxOutL of
            MaryValue _ (MultiAsset ma) ->
                Map.member
                    (AssetName (SBS.toShort (envRepBytes env)))
                    (Map.findWithDefault Map.empty (envRepPolicy env) ma)
    when (any hasRep outs) $
        failWith (label <> ": completion outputs carry the burned representative forward")
    emit "custody" (label <> ": completion outputs carry no representative (burn total)")

rowLO02 :: Env -> ConwayTx -> Snap -> IO ()
rowLO02 env signed snap = do
    assertMirrorHealthy env "LO02"
    keyPresent <- mirrorValue env "rt-over"
    case keyPresent of
        Just _ -> pure ()
        Nothing ->
            failWith "LO02: over key absent from the chain-synced mirror — expected occupied (Over)"
    root <- mirrorRootHex env
    emit
        "row"
        ( "LO02-retirement-over-visible: completion tx "
            <> txIdHex signed
            <> " burned 0x"
            <> hex (envRepBytes env)
            <> " (mint field -1); record "
            <> showIn (snapIn snap)
            <> " gone; key rt-over still occupied in the chain-synced mirror \
               \(root 0x"
            <> root
            <> ", value proved by the reader from the retained request datum (mirror lookup is presence-only)) — retired/Over, and no live resolution exists for this retirement: the record is gone (application queried), its custody is consumed (custody queried), this completion creates no representative-carrying outputs (built bytes checked), and the consumed record cannot authorize again (OV-replay refused above; other live records hold the same shared bytes and are unaffected)"
        )

-- | Re-registration claim for the over key (LX01 setup): a fresh
-- insert approval (re-minted — the original burned in the over
-- record's fold) carrying the same datum. Submitted, not assumed:
-- if the ledger refuses the claim itself, that refusal (not a fold
-- refusal) is what the row reports.
lx01Claim :: Env -> IO (TxIn, TxOut ConwayEra)
lx01Claim env = do
    let datum = envDatum env
        controlBytes = addressBytes (controlAddress datum)
        commitment = nextControlCommitment datum
        approval = insertApprovalName controlBytes commitment
        approvalTokens =
            Map.singleton
                (envAppPolicy env)
                (Map.singleton (AssetName (SBS.toShort approval)) 1)
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
    submitAccepted env "LX01-reuse-insert" signedA
    _ <- waitConfirmation (txIdHex signedA <> " (LX01: reuse claim)")
    claimIn <-
        mustFindUTxO
            (envProv env)
            (envAppAddr env)
            (txIdHex signedA)
            "LX01: reuse claim"
    claimLive <- mustOutAt env (envAppAddr env) claimIn
    pure (claimIn, claimLive)
  where
    coinOf (_, o) = let Coin c = o ^. coinTxOutL in c

-- | The re-registration fold for the over key (LX01 core): a connected
-- fold of the queued insert, built from chain state with local
-- evaluation ON. Expected to fail — either at build (EvalFailure
-- naming the state script, e2e-occupied precedent) or at submit —
-- because the key is occupied. Returns the built tx for the submit
-- path; build failure propagates to the row's attribution.
lx01Fold :: Env -> (TxIn, TxOut ConwayEra) -> (TxIn, TxOut ConwayEra) -> IO ConwayTx
lx01Fold env (reqIn, reqOut) (claimIn, claimLive) = do
    let datum = envDatum env
        repName = boundRepName (envCfg env) (envTok env) (envOldHash env)
        approval = insertApprovalName (addressBytes (controlAddress datum)) (nextControlCommitment datum)
    snapClaim <- mustSnap env claimIn
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
                                    (addressBytes (controlAddress datum))
                                    (nextControlCommitment datum)
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
    pure unsignedF

rowLX01 :: Env -> IO ()
rowLX01 env = do
    let stateHex = hex (scriptHashBytes (cfgScriptHash (envCfg env)))
    assertMirrorHealthy env "LX01"
    occupied <- mirrorValue env "rt-over"
    case occupied of
        Just _ -> pure ()
        Nothing ->
            failWith "LX01: over key absent from the chain-synced mirror — expected occupied (Over)"
    -- Queue lands: queueing is not the refusal.
    (reqIn, reqOut) <- submitRetirementRequest env "rt-over" (envRepBytes env)
    emit
        "row"
        ( "LX01-re-registration-queued: insert request for rt-over accepted "
            <> showIn reqIn
            <> " (queueing is not the refusal; the fold is)"
        )
    (claimIn, claimLive) <- lx01Claim env
    foldResult <- try (lx01Fold env (reqIn, reqOut) (claimIn, claimLive)) :: IO (Either SomeException ConwayTx)
    case foldResult of
        Left err -> do
            -- Strict attribution (NOTE-030): named state-script field,
            -- semantic (never budget), at the state spend.
            pinEvalRefusal "LX01" (show err) stateHex "ConwaySpending"
            emit
                "row"
                ( "LX01-re-registration-after-over-refused: REFUSED at build (model \
                  \reason occupied-key): the fold's local evaluation fails naming the \
                  \MPFS state script 0x"
                    <> stateHex
                    <> " at a ConwaySpending purpose — the absence proof the insert \
                       \requires is unproducible against the chain root holding rt-over: "
                    <> show err
                )
        Right built -> do
            let signed = addKeyWitness genesisSignKey built
            expectRefusedMarker
                MainRun
                env
                "LX01-re-registration-after-over-refused"
                "occupied-key"
                stateHex
                "the MPFS state script"
                "absence proof unproducible: the key is occupied"
                signed
    -- Control: the same registration succeeds for an unretired key in
    -- the same run — without it the refusal is equally consistent with
    -- a harness that cannot register anything at all.
    (txCtl, recCtl) <- setupRecoveryRecord env (envDatum env) "over-control" "rt-over-control"
    _ <- waitConfirmation (txCtl <> " (setup: over-control)")
    emit
        "row"
        ( "LX01-control-fresh-key-registers: rt-over-control folded connected as "
            <> showIn recCtl
            <> " in tx "
            <> txCtl
            <> " (the harness registers; only the over key refuses)"
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
    -- Control record for the eval-branch controls (NOTE-033): its
    -- own custody, so N2 pairs genuinely without touching MainRun
    -- records. Retired validly as setup (accepts, not a guard).
    (txCtl, recCtl) <- setupRecoveryRecord env (envDatum env) "ctl" "rt-ctl"
    _ <- waitConfirmation (txCtl <> " (setup: ctl)")
    snapCtl <- mustSnap env recCtl
    signedCtl <- rowRetireCtl env snapCtl
    decoyReq <- submitRetirementRequest env "rt-n2-decoy" (envRepBytes env)
    requireFired "N2-CV-refusal" =<< rowN2ValidRefusal env signedCtl decoyReq
    ownReq <- overRequestOut env signedCtl "N2-CV-own"
    requireFired "N2-CV-accept" =<< rowN2ValidAccept env signedCtl ownReq
    requireFired "LX01-CV-refusal" =<< rowLX01ValidRefusal env "rt-ctl"
    requireFired "LX01-CV-accept" =<< rowLX01ValidAccept env "rt-ctl-fresh"
    -- Then LT03 made actually valid: the missing quorum member added.
    tx <- retireTx env snap (envCustodyAddr env) [envQuorum1Hash env, envQuorum2Hash env] "rt-refusals"
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
    signedA1 <- rowLT01 env snapA1
    -- Eval-branch controls (NOTE-033): mismatched pair and occupied
    -- refold through the impossible marker (fired + recorded here;
    -- spellings are this runner's own setup conventions).
    decoyReq <- submitRetirementRequest env "rt-n2-decoy" (envRepBytes env)
    requireFired "N2-CWR" =<< rowN2ControlWrongReason env signedA1 decoyReq
    requireFired "LX01-CWR" =<< rowLX01ControlWrongReason env "rt-accept1"
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
expectRefused mode env rowName modelReason guard signed =
    expectRefusedMarker mode env rowName modelReason (envAppHex env) "the application validator" guard signed

-- | Refusal against an explicit script marker (general core behind
-- expectRefused): phase-2 PlutusFailure naming @markerHex@ (a script
-- hash in hex, derived from run bytes — never hardcoded), retained
-- with its reason. @scriptName@ names the script for narration only.
expectRefusedMarker ::
    Mode ->
    Env ->
    String ->
    String ->
    String ->
    String ->
    String ->
    ConwayTx ->
    IO ()
expectRefusedMarker mode env rowName modelReason markerHex scriptName guard signed = do
    let wrongReasonMode = mode == ControlWrongReason
        expectedMarker
            | wrongReasonMode = wrongReasonMarker
            | otherwise = markerHex
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
                           \naming "
                        <> scriptName
                        <> "> but the node rejected with <"
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
                    <> "; phase-2 PlutusFailure naming "
                    <> scriptName
                    <> " 0x"
                    <> markerHex
                    <> "): "
                    <> reasonText
                    <> " — "
                    <> guard
                )
            tag <- retainTx env rowName signed
            retainOutcome
                (envEvDir env)
                tag
                "refused"
                (Just reasonText)

-- ---------------------------------------------------------
-- Transaction builders
-- ---------------------------------------------------------

-- | Over marker (NOTE-028/031): `Naming.Register.overMarkerFor` —
-- the value a retirement's pending Update request writes for its
-- key, mirroring `naming.over_marker_for` (single source in the
-- library): the completion scripts check the folded request moves
-- the burned asset to exactly this marker.
retireTx ::
    Env ->
    Snap ->
    Addr ->
    [ByteString] ->
    ByteString ->
    IO ConwayTx
retireTx env snap destination signers spelling = do
    -- Reference-anchored retire (NOTE-014 item A1): the record spend rides
    -- a transaction that REFERENCES (never spends) the registry state, so
    -- the application validator reads the expected policy and token from
    -- validated-but-unspent configuration — no empty `Modify`, no filler
    -- request, no state output, no mint (the representative moves to
    -- custody; completion burns it later). All scripts resolve through
    -- reference inputs; callers add key witnesses exactly as before.
    -- Pending Over-update request (NOTE-028): the same route-authorized
    -- transaction queues the Update this key must fold to reach Over
    -- (old value = the representative name the insert stored, new value
    -- = the over marker). Creating the output executes no script; its
    -- authority is this transaction's route signatures, and completion
    -- must fold exactly this key's request with the custody burn.
    _live <- mustOutAt env (envAppAddr env) (snapIn snap)
    (stateIn, _stateOut) <- queryRetirementState env
    (fund, collateral) <- takeFundCollateral env
    now <- currentPosixMs
    let reqAddr = requestAddrFromCfg (envCfg env) (envTok env) Testnet
        reqDatum =
            mkRequestDatum
                (envTok env)
                genesisAddr
                spelling
                (OpUpdate (envRepBytes env) (overMarkerFor (envRepBytes env)))
                1_000_000
                now
        reqDraftOut =
            mkBasicTxOut reqAddr (MaryValue (Coin 0) mempty)
                & datumTxOutL .~ mkInlineDatum reqDatum
        reqRefundDraft = mkBasicTxOut genesisAddr (MaryValue (Coin 0) mempty)
        Coin reqCoin =
            requestLockedAda (envPp env) reqDraftOut reqRefundDraft 1_000_000
        requestOut =
            mkBasicTxOut reqAddr (MaryValue (Coin reqCoin) mempty)
                & datumTxOutL .~ mkInlineDatum reqDatum
        inputs = Set.fromList [snapIn snap, fst fund]
        spendIdx = spendingIndex (snapIn snap) inputs
        redeemers =
            Redeemers
                ( Map.singleton
                    (ConwaySpending (AsIx spendIdx))
                    -- Generous (NOTE-023 class): the retire carries the
                    -- record spend over a grown transaction (custody +
                    -- pending-request outputs with inline datums); honest
                    -- execution must not be budget-capped. Measured
                    -- minima live in ConnectedFold.generousUnits.
                    (Data (redeemerRetire (envRepBytes env) (envOldHash env)), generousUnits)
                )
        integrity = computeScriptIntegrity (envPp env) redeemers
        custodyOut' =
            custodyOut (envPp env) destination (snapCoin snap) (envRepTokens env)
        change = changeOut (snapCoin snap + coinOf fund) flatFee [custodyOut', requestOut]
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ inputs
                & referenceInputsTxBodyL .~ Set.fromList ([stateIn] ++ map fst (envRefUtxos env))
                & collateralInputsTxBodyL .~ Set.singleton (fst collateral)
                & outputsTxBodyL .~ StrictSeq.fromList [custodyOut', requestOut, change]
                & feeTxBodyL .~ Coin flatFee
                & reqSignerHashesTxBodyL
                    .~ Set.fromList (map addrWitnessKeyHash signers)
                & scriptIntegrityHashTxBodyL .~ integrity
    pure $
        ( mkBasicTx body
            & witsTxL . rdmrsTxWitsL .~ redeemers
        )
  where
    coinOf (_, o) = let Coin c = o ^. coinTxOutL in c

-- | Mint redeemer @BurnRepresentative@ (second constructor of the
-- representative redeemer): burns the custody-held representative.
burnRepresentativeRedeemer :: PLC.Data
burnRepresentativeRedeemer = PLC.Constr 1 []

-- | Custody spend redeemer: the custody validator ignores its redeemer
-- (burn enforcement is over inputs + mint), so this carries nothing.
custodySpendRedeemer :: PLC.Data
custodySpendRedeemer = PLC.Constr 0 []

-- | Fund the fresh completing party from the genesis pool (infrastructure:
-- two ADA-only outputs, fund + collateral). The completion itself is
-- signed by the completer alone; genesis never touches it.
fundCompleter ::
    Env ->
    Addr ->
    IO ((TxIn, TxOut ConwayEra), (TxIn, TxOut ConwayEra))
fundCompleter env completerAddr = do
    (fund, _collateral) <- takeFundCollateral env
    let Coin inCoin = (snd fund) ^. coinTxOutL
        outCoin = 20_000_000
        changeCoin = inCoin - flatFee - 2 * outCoin
    unless (changeCoin > 1_000_000) $
        failWith "completer funding: pool UTxO too small"
    let outs =
            [ mkBasicTxOut completerAddr (MaryValue (Coin outCoin) mempty)
            , mkBasicTxOut completerAddr (MaryValue (Coin outCoin) mempty)
            , mkBasicTxOut genesisAddr (MaryValue (Coin changeCoin) mempty)
            ]
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton (fst fund)
                & outputsTxBodyL .~ StrictSeq.fromList outs
                & feeTxBodyL .~ Coin flatFee
        signed = addKeyWitness genesisSignKey (mkBasicTx body)
    submitAccepted env "over-completer-funding" signed
    _ <- waitConfirmation (txIdHex signed <> " (over: completer funding)")
    -- The two completer outputs are indices 0 (fund) and 1
    -- (collateral); resolve both against the funding txid.
    utxos <- Cage.queryUTxOs (envProv env) completerAddr
    let mine = sortBy (comparing (txInIndex . fst)) (utxosByTxId utxos (txIdHex signed))
    case mine of
        [(fundIn, fundOut), (collIn, collOut)] -> pure ((fundIn, fundOut), (collIn, collOut))
        _ -> failWith "completer funding: expected exactly two completer outputs"

-- | Burn-only completion attempt (NOTE-029 N1): custody spend plus
-- the exact burn, but NO registry state input and NO request fold.
-- Scripts attached directly (no reference games): the refusal must
-- come from the executing scripts (absent-transition refusal), never
-- from missing witnesses. Pool funded, genesis witnessed — a refusal
-- probe, never a completion shape.
burnOnlyTx ::
    Env ->
    (TxIn, TxOut ConwayEra) ->
    (TxIn, TxOut ConwayEra) ->
    (TxIn, TxOut ConwayEra) ->
    IO ConwayTx
burnOnlyTx env (custodyIn, custOut) (fundIn, fundOut) (collIn, _) = do
    let inputs = Set.fromList [custodyIn, fundIn]
        spendIdx = spendingIndex custodyIn inputs
        redeemers =
            Redeemers $
                Map.fromList
                    [ (ConwaySpending (AsIx spendIdx), (Data custodySpendRedeemer, generousUnits))
                    , (ConwayMinting (AsIx 0), (Data burnRepresentativeRedeemer, generousUnits))
                    ]
        integrity = computeScriptIntegrity (envPp env) redeemers
        burnTokens =
            Map.singleton
                (envRepPolicy env)
                (Map.singleton (AssetName (SBS.toShort (envRepBytes env))) (-1))
        Coin fundCoin = fundOut ^. coinTxOutL
        Coin custodyCoin = custOut ^. coinTxOutL
        change = changeOut (fundCoin + custodyCoin) flatFee []
        PolicyID repHash = envRepPolicy env
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ inputs
                & collateralInputsTxBodyL .~ Set.singleton collIn
                & outputsTxBodyL .~ StrictSeq.fromList [change]
                & feeTxBodyL .~ Coin flatFee
                & mintTxBodyL .~ MultiAsset burnTokens
                & reqSignerHashesTxBodyL .~ Set.empty
                & scriptIntegrityHashTxBodyL .~ integrity
    pure $
        mkBasicTx body
            & witsTxL . scriptTxWitsL
                .~ Map.fromList
                    [(envCustodyHash env, envCustodyScript env), (repHash, envRepScript env)]
            & witsTxL . rdmrsTxWitsL .~ redeemers

-- | Strict local-evaluation refusal attribution (NOTE-030): the
-- message must be a semantic `EvalFailure` (never budget exhaustion
-- or a build/setup failure) naming the expected script hash in a
-- script-hash field, at the expected Plutus purpose. Anything else
-- fails the row quoting the full message — a hash occurring
-- somewhere or a budget/setup failure is never the claimed refusal.
pinEvalRefusal :: String -> String -> String -> String -> IO ()
pinEvalRefusal label msg expectedHash purpose = do
    unless ("EvalFailure" `isInfixOf` msg) $
        failWith (label <> ": not a local-evaluation refusal — " <> msg)
    when ("overspending the budget" `isInfixOf` msg) $
        failWith (label <> ": budget exhaustion is not the claimed refusal — " <> msg)
    unless (purpose `isInfixOf` msg) $
        failWith (label <> ": refusal not at " <> purpose <> " — " <> msg)
    case extractScriptHashes msg of
        [] ->
            failWith (label <> ": no script-hash field in refusal — " <> msg)
        hs ->
            unless (expectedHash `elem` hs) $
                failWith
                    ( label
                        <> ": refusal names no script-hash field equal to 0x"
                        <> expectedHash
                        <> " (found "
                        <> show hs
                        <> ") — "
                        <> msg
                    )

-- | Script hashes from named script-hash fields only
-- (`pwcScriptHash = ScriptHash ".."` as rendered by ledger
-- evaluation failures, `The script hash is:ScriptHash ".."` as
-- rendered by the matcher — quotes escaped or raw): bare hex
-- occurring anywhere else (datum dumps, credentials) is never
-- attribution.
extractScriptHashes :: String -> [String]
extractScriptHashes msg = concatMap (`fieldHashes` msg) markers
  where
    markers =
        [ "pwcScriptHash = ScriptHash \\\"", "The script hash is:ScriptHash \\\"",
          "pwcScriptHash = ScriptHash \"", "The script hash is:ScriptHash \""
        ]
    fieldHashes marker s = case T.breakOn (T.pack marker) (T.pack s) of
        (_, rest) | T.null rest -> []
        (_, rest) ->
            let hexPart = T.unpack (T.take 56 (T.drop (T.length (T.pack marker)) rest))
             in [hexPart | length hexPart == 56 && all isHexDigit hexPart]
                <> fieldHashes marker (T.unpack (T.drop (T.length (T.pack marker)) rest))
-- | Withdrawal attempt (LT07 shape, NOTE-027 item 5): the same spend
-- as completion but with the burn removed — the representative is
-- redirected to the completing party instead. No mint rides it, so
-- the refusal must come from the custody script alone (phase-2 naming
-- the custody hash). Manual builder (no state spend, no fold): pool
-- funded, genesis witnessed — it is a refusal probe, not the
-- permissionless path.
withdrawTx ::
    Env ->
    (TxIn, TxOut ConwayEra) ->
    (TxIn, TxOut ConwayEra) ->
    (TxIn, TxOut ConwayEra) ->
    Addr ->
    IO ConwayTx
withdrawTx env (custodyIn, custOut) (fundIn, fundOut) (collIn, _) destAddr = do
    let inputs = Set.fromList [custodyIn, fundIn]
        spendIdx = spendingIndex custodyIn inputs
        redeemers =
            Redeemers $
                Map.singleton
                    (ConwaySpending (AsIx spendIdx))
                    -- Generous like the retire above: same grown shape.
                    (Data custodySpendRedeemer, generousUnits)
        integrity = computeScriptIntegrity (envPp env) redeemers
        Coin custodyCoin = custOut ^. coinTxOutL
        Coin fundCoin = fundOut ^. coinTxOutL
        repOut =
            mkBasicTxOut
                destAddr
                ( MaryValue (Coin custodyCoin) (MultiAsset (Map.singleton (envRepPolicy env) (Map.singleton (AssetName (SBS.toShort (envRepBytes env))) 1)))
                )
        change = changeOut (fundCoin + custodyCoin) flatFee [repOut]
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ inputs
                & collateralInputsTxBodyL .~ Set.singleton collIn
                & outputsTxBodyL .~ StrictSeq.fromList [repOut, change]
                & feeTxBodyL .~ Coin flatFee
                -- No required signer: the custody script ignores
                -- signatories, and this attempt claims no authorization.
                -- The pool inputs are witnessed by genesis below.
                & reqSignerHashesTxBodyL .~ Set.empty
                & scriptIntegrityHashTxBodyL .~ integrity
    pure $
        mkBasicTx body
            & witsTxL . scriptTxWitsL
                .~ Map.singleton (envCustodyHash env) (envCustodyScript env)
            & witsTxL . rdmrsTxWitsL .~ redeemers

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

-- | Spend redeemer @Recover { revealed_control, representatives,
-- registry }@ (NOTE-024 recovery-then-retire): application Constr 4
-- carrying the revealed address bytes, the carried representatives
-- and the registry binding (the app's own hash).
redeemerRecover :: ByteString -> [ByteString] -> ByteString -> PLC.Data
redeemerRecover revealed reps registry =
    PLC.Constr 4 [PLC.B revealed, PLC.List (map PLC.B reps), PLC.B registry]

-- | Recover a record to a revealed control (real on-chain rotation).
-- Mirrors maintainTx exactly, with the Recover redeemer: the revealed
-- key signs, the successor carries the revealed control with payment
-- and quorum preserved, value (representative included) preserved.
recoverTx ::
    Env ->
    Snap ->
    ByteString ->
    [ByteString] ->
    ByteString ->
    NamingDatum ->
    [ByteString] ->
    IO ConwayTx
recoverTx env snap revealed reps registry successor signers = do
    (fund, collateral) <- takeFundCollateral env
    let inputs = Set.fromList [snapIn snap, fst fund]
        spendIdx = spendingIndex (snapIn snap) inputs
        redeemers =
            Redeemers
                ( Map.singleton
                    (ConwaySpending (AsIx spendIdx))
                    (Data (redeemerRecover revealed reps registry), maxUnits)
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

-- | Registry-bound representative name (NOTE-007): recomputed identically
-- on chain from the supplied state's token. Single source per file so
-- displays, redeemers and minted values cannot drift apart.
boundRepName :: CageConfig -> TokenId -> ByteString -> ByteString
boundRepName cfg tok controlHash =
    let TokenId (AssetName tokSbs) = tok
     in representativeName
            controlHash
            (scriptHashBytes (cfgScriptHash cfg))
            (SBS.fromShort tokSbs)
            freshIncarnation

bootRetirementCage ::
    Cage.Provider IO ->
    Submitter IO ->
    TrieManager IO ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    FilePath ->
    IORef Int ->
    IO (CageConfig, TokenId)
bootRetirementCage prov submit tm stateBytes requestBytes repPolicy consumerBytes evDir evNext = do
    utxos <- Cage.queryUTxOs prov genesisAddr
    seedRef <- case sortOn (Down . (^. coinTxOutL) . snd) utxos of
        [] -> failWith "boot: genesis wallet has no UTxOs"
        (txIn, _) : _ -> pure (txInToRef txIn)
    let ConsumerBinding
            { cbPin = consumerPin
            , cbScriptBytes = consumerScriptBytes
            , cbHash = consumerHash
            } = deriveConsumerBinding consumerBytes
        cfg =
            CageConfig
                { cageScriptBytes = stateBytes
                , requestScriptBytes = requestBytes
                , cfgScriptHash = computeScriptHash stateBytes
                , cageSeed = seedRef
                , defaultProcessTime = 120_000
                , defaultRetractTime = 30_000
                , defaultTip = Coin 1_000_000
                , cfgRepPolicy = repPolicy
                , cfgConsumerPin = consumerPin
                , cfgConsumerScript = consumerScriptBytes
                , network = Testnet
                }
    emit
        "consumer"
        ( "pinned exhibit consumer 0x"
            <> hex (scriptHashBytes consumerHash)
            <> " (unparameterized: authenticates batches from transaction \
               \evidence alone; stake credential registered below before \
               \the first Modify)"
        )
    unsignedBoot <- bootTokenImpl cfg prov genesisAddr
    let signedBoot = addKeyWitness genesisSignKey unsignedBoot
    bootTag <- retainTxAt evDir evNext "cage-boot" signedBoot
    result <- submitTx submit signedBoot
    case result of
        Submitted _ -> do
            retainOutcome evDir bootTag "accepted" Nothing
            pure ()
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
    Script ConwayEra ->
    IO [(TxIn, TxOut ConwayEra)]
publishRetirementRefs prov submit pp poolRef cfg tok appScript repScript custodyScript = do
    let scripts =
            [ mkCageScript cfg
            , mkRequestScript cfg tok
            , appScript
            , repScript
            , custodyScript
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
    tag <- retainTx env ("mpfs-request-" <> show spelling) signed
    result <- submitTx (envSubmit env) signed
    case result of
        Submitted _ -> do
            retainOutcome (envEvDir env) tag "accepted" Nothing
            pure ()
        Rejected reason -> failWith ("request: rejected: " <> show reason)
    let txid = txIdHex signed
    _ <- waitConfirmation (txid <> " (MPFS request " <> show spelling <> ")")
    let reqAddr = requestAddrFromCfg cfg tok Testnet
    reqIn <- mustFindUTxO (envProv env) reqAddr txid "MPFS request"
    reqOut <- mustOutAt env reqAddr reqIn
    pure (reqIn, reqOut)

queryRetirementState :: Env -> IO (TxIn, TxOut ConwayEra)
queryRetirementState env = do
    let cfg = envCfg env
        tok = envTok env
        stateAddr = cageAddrFromCfg cfg Testnet
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
        repName = boundRepName (envCfg env) (envTok env) (envOldHash env)
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
    case pool of
        (f : c : rest) -> do
            writeIORef (envPool env) rest
            pure (f, c)
        _ -> failWith "the funding pool is exhausted"

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
-- | Spend redeemer @Retire { representatives, key_hash }@ (NOTE-011: the
-- authorized two-field shape — the creation control key hash the
-- representative name commits to; this runner only retires records created
-- by the original controller, so the creation hash is `envOldHash` at every
-- call site. A one-field @Constr 3@ decodes to @headList []@ on chain.)
redeemerRetire :: ByteString -> ByteString -> PLC.Data
redeemerRetire rep keyHash =
    PLC.Constr 3 [PLC.List [PLC.B rep], PLC.B keyHash]

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
submitAccepted env label signed = do
    tag <- retainTx env label signed
    submitTx (envSubmit env) signed >>= \case
        Submitted _ -> do
            retainOutcome (envEvDir env) tag "accepted" Nothing
            emit "submit" (label <> ": accepted tx=" <> txIdHex signed)
        Rejected reason -> do
            retainOutcome
                (envEvDir env)
                tag
                "refused"
                (Just (T.unpack (TE.decodeUtf8Lenient reason)))
            failWith
                ( label
                    <> ": the node refused an accepting row: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )

-- | CBOR version for evidence serialization (matches the register
-- journey: the txid self-check validates the choice empirically).
evidenceVersion :: Version
evidenceVersion = maxBound

serializeTxHex :: ConwayTx -> String
serializeTxHex tx = hex (serialize' evidenceVersion tx)

-- | Evidence location: gate-owned wins, smoke override second,
-- isolated TMPDIR last (same contract as the register journey).
evidenceDirFromEnv :: IO FilePath
evidenceDirFromEnv = do
    gateOwned <- lookupEnv "S3_EVIDENCE"
    smokeOverride <- lookupEnv "S77_EVIDENCE_DIR"
    case (gateOwned, smokeOverride) of
        (Just dir, _) -> pure dir
        (Nothing, Just dir) -> pure dir
        (Nothing, Nothing) -> do
            tmpdir <- fromMaybe "/tmp" <$> lookupEnv "TMPDIR"
            pure (tmpdir ++ "/retirement-evidence")

retainTxAt :: FilePath -> IORef Int -> String -> ConwayTx -> IO String
retainTxAt evDir evNext label signed = do
    n <- readIORef evNext
    writeIORef evNext (n + 1)
    let num = replicate (3 - length (show n)) '0' <> show n
        tag = num <> "-" <> label
    BSL.writeFile
        (evDir </> ("tx-" <> tag <> ".cborhex"))
        (BSL.fromStrict (TE.encodeUtf8 (T.pack (serializeTxHex signed))))
    pure tag

retainTx :: Env -> String -> ConwayTx -> IO String
retainTx env = retainTxAt (envEvDir env) (envEvNext env)

retainOutcome :: FilePath -> String -> String -> Maybe String -> IO ()
retainOutcome evDir tag outcome mReason =
    BSL.writeFile
        (evDir </> ("tx-" <> tag <> ".outcome.json"))
        ( encode $
            object $
                [ "outcome" .= outcome
                , "tag" .= tag
                ]
                    <> case mReason of
                        Just reason -> ["reason" .= reason]
                        Nothing -> []
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

checkPinnedConsumer :: String -> IO ()
checkPinnedConsumer unappliedHex = do
    path <-
        fromMaybe "../onchain/script-identity.json"
            <$> lookupEnv "MPFS_SCRIPT_IDENTITY"
    bytes <- BS.readFile path
    manifest <- either failWith pure (eitherDecode' (BSL.fromStrict bytes))
    let pins =
            [ mpHash p
            | p <- manifestValidators manifest
            , "consumer.consumer" `T.isPrefixOf` mpTitle p
            ]
    unless (length pins >= 1) $
        failWith
            "identity: no consumer.consumer pin in the MPFS manifest"
    unless (all (== T.pack unappliedHex) pins) $
        failWith
            ( "identity: the manifest pins unapplied consumer hash(es) "
                <> show pins
                <> " but this run's blueprint code hashes to 0x"
                <> unappliedHex
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
