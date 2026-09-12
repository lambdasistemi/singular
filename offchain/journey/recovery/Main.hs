{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Main
Description : The LR recovery rows on a real devnet (issue #62)
License     : Apache-2.0

Executes the eleven contract rows @LR01..LR11@ against a real devnet
node, one narration line per step, and verifies what the chain then
holds. The rows were proved at model level by epic 15
(@recoverController@) and at Aiken level by this slice's
@application.tests@; this is the first time they meet a ledger, so
what is under test is the /composition/: can a real transaction
present the context the Aiken tests constructed, and do the naming
scripts and the merged codec agree the way the correspondence record
claims?

Ledger realisation (offchain\/naming-correspondence.md, t62 entries):

  * the record is a UTxO at the naming application validator carrying
    the four-field naming datum inline (merged 'Naming.Datum' codec)
    and exactly one representative token under the APPLIED
    representative policy (@Rep || control key hash || 0x00@, minted +1
    by the genuine insert fold that created the record, issue #77). The
    former application-policy stand-in shape is removed: no row mints
    or carries a representative under the application policy any more;
    the validator binds the redeemer claim to the chain-carried token,
    preserving the single-representative shape;

  * the registry binding is the application validator's own hash
    (@own_hash@ read from the spent input's address): the @Recover@
    redeemer claims it, the validator refuses when the claim
    disagrees (@LR10@), making the refusal real rather than
    contrived;

  * @LR01@ spends the record with a @Recover@ redeemer revealing the
    committed next-control address, demands exactly its payment key
    among the required signers (no old-controller signature), installs
    it as controller with a fresh commitment, and preserves the
    representative, registry binding, payment destination and quorum;

  * @LR04@ and @LR05@ run after a real @LR01@, against the successor
    the chain actually holds; ordinary maintenance under the
    recovered controller then succeeds, proving recovery produced a
    usable name;

  * the three records (main, refusals, forged) are folded from three
    distinct keys, each with its own insert approval and representative
    — a second fold for an active key is @occupied-key@-refused, so
    sharing one key across records would not be a genuine state;

Every refusal is asserted on its reason: the node must report a
phase-2 PlutusFailure naming the application validator's script
hash. A fee, missing-input or malformed-CBOR refusal fails the run.

Controls (env @RECOVERY_CONTROL@): @valid@ makes LR03's transaction
actually valid (the missing signer added), so it succeeds and the
refusal guard must fail the run; @wrong-reason@ matches every refusal
against a marker that cannot occur, so the reason matcher must fail
the run naming what came back. Both exit 1 by design, after
executing rows.

Hermetic run (D-011), from @offchain/@:

> blueprint="$(nix build --quiet --no-link --print-out-paths ../naming-onchain#plutus-blueprint)"
> TMPDIR=/tmp/s62-devnet NAMING_BLUEPRINT="$blueprint" nix run --quiet .#recovery-rows
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
import Control.Monad (unless, when)
import Crypto.Hash (Blake2b_256, Digest, hash)
import Data.Bits (complement)
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Aeson (FromJSON (..), eitherDecode', withObject, (.:))
import Data.List (intercalate, isInfixOf, sortBy, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
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
    TokenId (..),
 )
import Cardano.MPFS.Cage.Provider qualified as Cage
import Cardano.MPFS.Cage.Trie (TrieManager (..))
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
import Cardano.MPFS.Cage.TxBuilder.Request (requestInsertImpl)
import Cardano.MPFS.Cage.Types (
    CageDatum (..),
    OnChainRoot (..),
    OnChainTokenState (..),
 )
import Cardano.MPFS.Cage.TxBuilder.Internal (
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
    , serialiseWireData
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
readMode =
    lookupEnv "RECOVERY_CONTROL" >>= \case
        Just "valid" -> pure ControlValid
        Just "wrong-reason" -> pure ControlWrongReason
        Just other
            | not (null other) ->
                failWith ("unknown RECOVERY_CONTROL value " <> other)
        _ -> pure MainRun

wrongReasonMarker :: String
wrongReasonMarker =
    "wrong-reason-control marker that no node reason can ever contain"

-- ---------------------------------------------------------
-- Fixture seeds (each exactly 32 bytes for mkSignKey)
-- ---------------------------------------------------------

oldSeed, revealedSeed, wrongSeed, freshSeed, fresh2Seed, refusalsSeed, forgedSeed, destSeed :: ByteString
oldSeed = "s62-old-controller00000000000000"
revealedSeed = "s62-revealed-next000000000000000"
wrongSeed = "s62-wrong-reveal0000000000000000"
freshSeed = "s62-fresh-next000000000000000000"
fresh2Seed = "s62-fresh20000000000000000000000"
refusalsSeed = "s62-refusals-control000000000000"
forgedSeed = "s62-forged-control00000000000000"
destSeed = "s62-destination00000000000000000"

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
                "issue #62: the LR recovery rows on a real ledger"
        ControlValid ->
            emit
                "control"
                "valid-transaction control: LR03 made actually valid, so it \
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
            hPutStrLn stderr ("recovery-rows: FAILED: " <> displayException e)
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
            repUnappliedHex =
                hex (scriptHashBytes (computeScriptHash repUnappliedBytes))
            repAppliedBytes =
                applyBytesParam (scriptHashBytes appHash) repUnappliedBytes
            repAppliedHash = computeScriptHash repAppliedBytes
            repAppliedHex = hex (scriptHashBytes repAppliedHash)
            repAppliedPolicy = PolicyID repAppliedHash
            repAppliedScript =
                scriptFromBytes "representative" repAppliedBytes
        checkPinnedApplication appHex
        checkPinnedRepresentative repUnappliedHex
        emit
            "identity"
            ( "application validator hash 0x"
                <> appHex
                <> " (0 parameters: the pinned manifest identity is the \
                   \applied identity this run carries on chain); \
                   \representative applied 0x"
                <> repAppliedHex
                <> " = unapplied 0x"
                <> repUnappliedHex
                <> " with parameter application-policy hash"
            )
        let oldHash = addrKeyHashBytes (enterpriseAddr (keyHashFromSignKey (mkSignKey oldSeed)))
            oldAddr = enterpriseAddr (keyHashFromSignKey (mkSignKey oldSeed))
            revealedHash = addrKeyHashBytes (enterpriseAddr (keyHashFromSignKey (mkSignKey revealedSeed)))
            revealedAddr = enterpriseAddr (keyHashFromSignKey (mkSignKey revealedSeed))
            wrongHash = addrKeyHashBytes (enterpriseAddr (keyHashFromSignKey (mkSignKey wrongSeed)))
            wrongAddr = enterpriseAddr (keyHashFromSignKey (mkSignKey wrongSeed))
            freshAddr =
                enterpriseAddr (keyHashFromSignKey (mkSignKey freshSeed))
            fresh2Addr =
                enterpriseAddr (keyHashFromSignKey (mkSignKey fresh2Seed))
            refusalsHash = addrKeyHashBytes (enterpriseAddr (keyHashFromSignKey (mkSignKey refusalsSeed)))
            refusalsAddr = enterpriseAddr (keyHashFromSignKey (mkSignKey refusalsSeed))
            forgedHash = addrKeyHashBytes (enterpriseAddr (keyHashFromSignKey (mkSignKey forgedSeed)))
            forgedAddr = enterpriseAddr (keyHashFromSignKey (mkSignKey forgedSeed))
            destAddr =
                enterpriseAddr (keyHashFromSignKey (mkSignKey destSeed))
            mustCodec bytes = case decodeAddress bytes of
                Just a -> a
                Nothing ->
                    error
                        "fixture: a devnet address does not decode as the contract's canonical address"
            oldCodec = mustCodec (serialiseAddr oldAddr)
            revealedCodec = mustCodec (serialiseAddr revealedAddr)
            wrongCodec = mustCodec (serialiseAddr wrongAddr)
            refusalsCodec = mustCodec (serialiseAddr refusalsAddr)
            forgedCodec = mustCodec (serialiseAddr forgedAddr)
            destCodec = mustCodec (serialiseAddr destAddr)
            storedC = nextControlCommitmentOf (serialiseAddr revealedAddr)
            forgedC = forgedCommitmentOf (serialiseAddr revealedAddr)
            freshC = nextControlCommitmentOf (serialiseAddr freshAddr)
            fresh2C = nextControlCommitmentOf (serialiseAddr fresh2Addr)
            mkDatum codec controllerHash stored =
                NamingDatum
                    { controlAddress = codec
                    , paymentDestination = NoDestination
                    , nextControlCommitment = stored
                    , retirementQuorum =
                        RetirementQuorum
                            { quorumMembers = [controllerHash]
                            , quorumThreshold = 1
                            }
                    }
            datumCorrect = mkDatum oldCodec oldHash storedC
            datumRefusals = mkDatum refusalsCodec refusalsHash storedC
            datumForged = mkDatum forgedCodec forgedHash forgedC
        tm <- mkPureTrieManager
        (cfg, tok) <- bootRecoveryCage prov submit tm stateBytes requestBytes
        createTrie tm tok
        emit "split" "splitting the genesis wallet into funding UTxOs"
        pool <- splitGenesis prov submit 80
        poolRef <- newIORef pool
        scriptRefs <- publishRecoveryRefs prov submit pp poolRef cfg tok script repAppliedScript
        let env =
                Env
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
                    , envRevealedHash = revealedHash
                    , envRevealedAddr = revealedAddr
                    , envRevealedCodec = revealedCodec
                    , envWrongHash = wrongHash
                    , envWrongAddr = wrongAddr
                    , envWrongCodec = wrongCodec
                    , envFreshC = freshC
                    , envFresh2C = fresh2C
                    , envRepPolicy = repAppliedPolicy
                    , envRepScript = repAppliedScript
                    , envRepHash = repAppliedHash
                    , envRepHex = repAppliedHex
                    , envCfg = cfg
                    , envTok = tok
                    , envTrie = tm
                    , envRefUtxos = scriptRefs
                    , envDestCodec = destCodec
                    , envDatumCorrect = datumCorrect
                    , envDatumForged = datumForged
                    }
        emit "setup" "folding the three recovery records (main, refusals, forged)"
        (txMain, recMain) <-
            setupGenuineRecord env oldSeed oldHash datumCorrect "main" "rc-main"
        _ <- waitConfirmation (txMain <> " (setup: main)")
        (txRef, recRefusals) <-
            setupGenuineRecord env refusalsSeed refusalsHash datumRefusals "refusals" "rc-refusals"
        _ <- waitConfirmation (txRef <> " (setup: refusals)")
        (txForged, recForged) <-
            setupGenuineRecord env forgedSeed forgedHash datumForged "forged" "rc-forged"
        _ <- waitConfirmation (txForged <> " (setup: forged)")
        emit
            "setup"
            ( "records live at the application validator 0x"
                <> appHex
                <> ": main="
                <> showIn recMain
                <> " (representative 0x"
                <> hex (representativeName oldHash freshIncarnation)
                <> ") refusals="
                <> showIn recRefusals
                <> " (representative 0x"
                <> hex (representativeName refusalsHash freshIncarnation)
                <> ") forged="
                <> showIn recForged
                <> " (representative 0x"
                <> hex (representativeName forgedHash freshIncarnation)
                <> ") — each folded from its own insert with its \
                   \representative minted +1 under the applied policy 0x"
                <> repAppliedHex
                <> "; the former application-policy stand-in shape is \
                   \removed; main/refusals store the domain-separated \
                   \commitment of the reveal, forged stores the \
                   \non-domain-separated digest"
            )
        case mode of
            MainRun -> runRows env recMain recRefusals recForged
            ControlValid -> runControlValid env recRefusals
            ControlWrongReason -> runControlWrongReason env recMain recRefusals
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
    , envRevealedHash :: ByteString
    , envRevealedAddr :: Addr
    , envRevealedCodec :: Address
    , envWrongHash :: ByteString
    , envWrongAddr :: Addr
    , envWrongCodec :: Address
    , envFreshC :: ByteString
    , envFresh2C :: ByteString
    , envRepPolicy :: PolicyID
    , envRepScript :: Script ConwayEra
    , envRepHash :: ScriptHash
    , envRepHex :: String
    , envCfg :: CageConfig
    , envTok :: TokenId
    , envTrie :: TrieManager IO
    , envRefUtxos :: [(TxIn, TxOut ConwayEra)]
    , envDestCodec :: Address
    , envDatumCorrect :: NamingDatum
    , envDatumForged :: NamingDatum
    }

-- ---------------------------------------------------------
-- The eleven rows
-- ---------------------------------------------------------

runRows :: Env -> TxIn -> TxIn -> TxIn -> IO ()
runRows env recMain recRefusals recForged = do
    snapRefusals <- mustSnap env recRefusals
    snapForged <- mustSnap env recForged
    -- The ten refusals against the live refusals/forged records.
    rowLR02 env snapRefusals
    rowLR03 MainRun env snapRefusals
    rowLR07 env snapRefusals
    rowLR08 env snapRefusals
    rowLR09 env snapRefusals
    rowLR10 env snapRefusals
    rowLR11 env snapRefusals
    rowLR11Destination env snapRefusals
    rowLR11Control env snapRefusals
    rowLR06 env snapForged
    -- LR01 accepts, consuming main into the recovered successor.
    snapMain <- mustSnap env recMain
    rec1 <- rowLR01 env snapMain
    -- LR04 and LR05 against the genuine successor.
    rowLR04 env rec1
    rowLR05 env rec1
    -- Maintenance under the recovered controller succeeds.
    rec2 <- rowMaintainRecovered env rec1
    -- Final no-trace sweep.
    finalNoTrace env recRefusals recForged rec2
    emit
        "complete"
        ( "the LR recovery rows executed on a real devnet; every refusal \
          \attributed to its reason, preservation and transfer proved from \
          \the chain, the state after the refusals unchanged"
        )

rowLR01 :: Env -> Snap -> IO Snap
rowLR01 env snap = do
    current <- chainDatumOf env snap "LR01"
    let successor =
            current
                { controlAddress = envRevealedCodec env
                , nextControlCommitment = envFreshC env
                }
    tx <- recoverTx env snap (serialiseAddr (envRevealedAddr env)) [snapRep snap] (scriptHashBytes (envScriptHash env)) successor [envRevealedHash env]
    let signed = addKeyWitness (mkSignKey revealedSeed) (addKeyWitness genesisSignKey tx)
    assertWitness env signed
    unless
        (Set.singleton (addrWitnessKeyHash (envRevealedHash env)) == (signed ^. bodyTxL . reqSignerHashesTxBodyL))
        $ failWith "LR01: required signers must be exactly the revealed payment key"
    when (Set.member (addrWitnessKeyHash (envOldHash env)) (signed ^. bodyTxL . reqSignerHashesTxBodyL)) $
        failWith "LR01: the old controller must not be among the required signers"
    submitAccepted env "LR01" signed
    _ <- waitConfirmation (txIdHex signed <> " (LR01)")
    contIn <-
        mustFindUTxO (envProv env) (envAppAddr env) (txIdHex signed) "LR01 continuation"
    contSnap <- mustSnap env contIn
    decoded <- chainDatumOf env contSnap "LR01"
    let diffs =
            concat
                [ [ "representative changed"
                  | snapTokens contSnap /= snapTokens snap
                  ]
                , [ "paymentDestination changed"
                  | paymentDestination decoded /= paymentDestination current
                  ]
                , [ "retirementQuorum changed"
                  | retirementQuorum decoded /= retirementQuorum current
                  ]
                ]
    unless (null diffs) $
        failWith ("LR01-preservation: preserved fields were not preserved: " <> intercalate "; " diffs)
    unless (controlAddress decoded == envRevealedCodec env) $
        failWith "LR01-transfer: the successor control is not the reveal"
    unless (nextControlCommitment decoded == envFreshC env) $
        failWith "LR01-transfer: the successor commitment is not fresh"
    unless (nextControlCommitment decoded /= nextControlCommitment current) $
        failWith "LR01-transfer: the successor re-installed the consumed commitment"
    assertChainBytes contSnap successor "LR01"
    emit
        "row"
        ( "LR01-recovery-accepts: accepted tx="
            <> txIdHex signed
            <> " continuation="
            <> showIn contIn
            <> " (reveal installed as controller with a fresh commitment, \
               \no old-controller signature)"
        )
    emit
        "preservation"
        ( "LR01-preservation: read back from the chain with the merged codec \
          \and compared field by field: representative tokens "
            <> show (snapTokens contSnap)
            <> " preserved; registry binding 0x"
            <> envAppHex env
            <> " preserved; paymentDestination unchanged; retirementQuorum \
               \unchanged; control 0x"
            <> hex (addressBytes (controlAddress decoded))
            <> " is the reveal; commitment 0x"
            <> hex (nextControlCommitment decoded)
            <> " is fresh and differs; on-chain bytes equal the codec encoding"
        )
    pure contSnap

rowLR02 :: Env -> Snap -> IO ()
rowLR02 env snap = do
    current <- chainDatumOf env snap "LR02"
    let successor =
            current
                { controlAddress = envRevealedCodec env
                , nextControlCommitment = envFreshC env
                }
        wrongBytes = serialiseAddr (envWrongAddr env)
    tx <- recoverTx env snap wrongBytes [snapRep snap] (scriptHashBytes (envScriptHash env)) successor [envWrongHash env]
    let signed = addKeyWitness (mkSignKey wrongSeed) (addKeyWitness genesisSignKey tx)
    expectRefused
        MainRun
        env
        "LR02-wrong-reveal-refused"
        "recovery-commitment"
        ( "a different canonical address, signed by its own key — its \
          \domain-separated commitment does not match the stored one"
        )
        signed
    noTrace env snap "LR02"

rowLR03 :: Mode -> Env -> Snap -> IO ()
rowLR03 mode env snap = do
    current <- chainDatumOf env snap "LR03"
    let successor =
            current
                { controlAddress = envRevealedCodec env
                , nextControlCommitment = envFreshC env
                }
    tx <- recoverTx env snap (serialiseAddr (envRevealedAddr env)) [snapRep snap] (scriptHashBytes (envScriptHash env)) successor []
    let signed = addKeyWitness genesisSignKey tx
    expectRefused
        mode
        env
        "LR03-missing-recovery-signer-refused"
        "recovery-required-signer"
        "the correct reveal with no required signer"
        signed
    noTrace env snap "LR03"

rowLR06 :: Env -> Snap -> IO ()
rowLR06 env snap = do
    current <- chainDatumOf env snap "LR06"
    let successor =
            current
                { controlAddress = envRevealedCodec env
                , nextControlCommitment = envFreshC env
                }
    tx <- recoverTx env snap (serialiseAddr (envRevealedAddr env)) [snapRep snap] (scriptHashBytes (envScriptHash env)) successor [envRevealedHash env]
    let signed = addKeyWitness (mkSignKey revealedSeed) (addKeyWitness genesisSignKey tx)
    expectRefused
        MainRun
        env
        "LR06-forged-public-digest-refused"
        "recovery-commitment"
        ( "the stored commitment was computed without the domain separation, \
          \so the validator's domain-separated recomputation mismatches; \
          \this row passes iff the domain separation is dropped"
        )
        signed
    noTrace env snap "LR06"

rowLR07 :: Env -> Snap -> IO ()
rowLR07 env snap = do
    current <- chainDatumOf env snap "LR07"
    let successor =
            current
                { controlAddress = envRevealedCodec env
                , nextControlCommitment = envFreshC env
                }
    tx <- recoverTx env snap (serialiseAddr (envRevealedAddr env)) [snapRep snap] (scriptHashBytes (envScriptHash env)) successor [envOldHash env]
    let signed = addKeyWitness (mkSignKey oldSeed) (addKeyWitness genesisSignKey tx)
    expectRefused
        MainRun
        env
        "LR07-wrong-payment-key-signer-refused"
        "recovery-required-signer"
        "the correct reveal, but the signature is the old controller's"
        signed
    noTrace env snap "LR07"

rowLR08 :: Env -> Snap -> IO ()
rowLR08 env snap = do
    current <- chainDatumOf env snap "LR08"
    let stale =
            current
                { controlAddress = envRevealedCodec env
                , nextControlCommitment = nextControlCommitment current
                }
    tx <- recoverTx env snap (serialiseAddr (envRevealedAddr env)) [snapRep snap] (scriptHashBytes (envScriptHash env)) stale [envRevealedHash env]
    let signed = addKeyWitness (mkSignKey revealedSeed) (addKeyWitness genesisSignKey tx)
    expectRefused
        MainRun
        env
        "LR08-missing-fresh-commitment-refused"
        "recovery-fresh-commitment"
        "the successor re-installs the consumed commitment"
        signed
    noTrace env snap "LR08"

rowLR09 :: Env -> Snap -> IO ()
rowLR09 env snap = do
    current <- chainDatumOf env snap "LR09"
    let successor =
            current
                { controlAddress = envRevealedCodec env
                , nextControlCommitment = envFreshC env
                }
        tamperedRep = BS.map complement (snapRep snap)
    tx <- recoverTx env snap (serialiseAddr (envRevealedAddr env)) [tamperedRep] (scriptHashBytes (envScriptHash env)) successor [envRevealedHash env]
    let signed = addKeyWitness (mkSignKey revealedSeed) (addKeyWitness genesisSignKey tx)
    expectRefused
        MainRun
        env
        "LR09-representative-tamper-refused"
        "recovery-representative"
        "the claim names a representative the consumed record does not carry"
        signed
    noTrace env snap "LR09"

rowLR10 :: Env -> Snap -> IO ()
rowLR10 env snap = do
    current <- chainDatumOf env snap "LR10"
    let successor =
            current
                { controlAddress = envRevealedCodec env
                , nextControlCommitment = envFreshC env
                }
        tamperedReg = BS.map complement (scriptHashBytes (envScriptHash env))
    tx <- recoverTx env snap (serialiseAddr (envRevealedAddr env)) [snapRep snap] tamperedReg successor [envRevealedHash env]
    let signed = addKeyWitness (mkSignKey revealedSeed) (addKeyWitness genesisSignKey tx)
    expectRefused
        MainRun
        env
        "LR10-registry-tamper-refused"
        "recovery-registry"
        "the claim names a registry binding the consumed record does not carry"
        signed
    noTrace env snap "LR10"

rowLR11 :: Env -> Snap -> IO ()
rowLR11 env snap = do
    current <- chainDatumOf env snap "LR11"
    let tamperedQuorum =
            (retirementQuorum current)
                { quorumMembers = quorumMembers (retirementQuorum current) <> [envRevealedHash env]
                }
        tampered =
            (current {controlAddress = envRevealedCodec env})
                { retirementQuorum = tamperedQuorum
                , nextControlCommitment = envFreshC env
                }
    tx <- recoverTx env snap (serialiseAddr (envRevealedAddr env)) [snapRep snap] (scriptHashBytes (envScriptHash env)) tampered [envRevealedHash env]
    let signed = addKeyWitness (mkSignKey revealedSeed) (addKeyWitness genesisSignKey tx)
    expectRefused
        MainRun
        env
        "LR11-quorum-tamper-refused"
        "recovery-field-preservation"
        "the successor alters the retirement quorum"
        signed
    noTrace env snap "LR11"

rowLR11Destination :: Env -> Snap -> IO ()
rowLR11Destination env snap = do
    current <- chainDatumOf env snap "LR11-destination"
    let tampered =
            (current {controlAddress = envRevealedCodec env})
                { paymentDestination = SomeDestination (envDestCodec env)
                , nextControlCommitment = envFreshC env
                }
    tx <- recoverTx env snap (serialiseAddr (envRevealedAddr env)) [snapRep snap] (scriptHashBytes (envScriptHash env)) tampered [envRevealedHash env]
    let signed = addKeyWitness (mkSignKey revealedSeed) (addKeyWitness genesisSignKey tx)
    expectRefused
        MainRun
        env
        "LR11-destination-tamper-refused"
        "recovery-field-preservation"
        "the successor changes the payment destination"
        signed
    noTrace env snap "LR11-destination"

rowLR11Control :: Env -> Snap -> IO ()
rowLR11Control env snap = do
    current <- chainDatumOf env snap "LR11-control"
    let tampered =
            (current {controlAddress = envWrongCodec env})
                { nextControlCommitment = envFreshC env
                }
    tx <- recoverTx env snap (serialiseAddr (envRevealedAddr env)) [snapRep snap] (scriptHashBytes (envScriptHash env)) tampered [envRevealedHash env]
    let signed = addKeyWitness (mkSignKey revealedSeed) (addKeyWitness genesisSignKey tx)
    expectRefused
        MainRun
        env
        "LR11-control-substitution-refused"
        "recovery-field-preservation"
        "the successor installs a controller other than the reveal"
        signed
    noTrace env snap "LR11-control"

rowLR04 :: Env -> Snap -> IO ()
rowLR04 env snap1 = do
    current <- chainDatumOf env snap1 "LR04"
    let candidate =
            current
                { controlAddress = envRevealedCodec env
                , nextControlCommitment = envFresh2C env
                }
    tx <- recoverTx env snap1 (serialiseAddr (envRevealedAddr env)) [snapRep snap1] (scriptHashBytes (envScriptHash env)) candidate [envRevealedHash env]
    let signed = addKeyWitness (mkSignKey revealedSeed) (addKeyWitness genesisSignKey tx)
    emit
        "row"
        ( "LR04-recovery-replay-refused: replaying the consumed reveal 0x"
            <> hex (serialiseAddr (envRevealedAddr env))
            <> " against the genuine successor "
            <> showIn (snapIn snap1)
            <> " (stored fresh 0x"
            <> hex (nextControlCommitment current)
            <> ")"
        )
    result <- submitTx (envSubmit env) signed
    case result of
        Submitted _ ->
            failWith
                "LR04: the replay was ACCEPTED — the consumed commitment authorized recovery twice"
        Rejected reason -> do
            let reasonText = T.unpack (TE.decodeUtf8Lenient reason)
                phase2 = "PlutusFailure" `isInfixOf` reasonText
                namesApp = envAppHex env `isInfixOf` reasonText
            unless (phase2 && namesApp) $
                failWith
                    ( "LR04-recovery-replay-refused: reason mismatch — expected phase-2 \
                      \naming the application validator but got <"
                        <> reasonText
                        <> ">"
                    )
            emit
                "row"
                ( "LR04-recovery-replay-refused: REFUSED, reason matched (model reason \
                  \recovery-commitment; phase-2 naming 0x"
                    <> envAppHex env
                    <> "): "
                    <> reasonText
                )
    noTrace env snap1 "LR04"

rowLR05 :: Env -> Snap -> IO ()
rowLR05 env snap1 = do
    current <- chainDatumOf env snap1 "LR05"
    let maintained = current {paymentDestination = SomeDestination (envDestCodec env)}
    tx <- maintainTx env snap1 maintained [envOldHash env]
    let signed = addKeyWitness (mkSignKey oldSeed) (addKeyWitness genesisSignKey tx)
    expectRefused
        MainRun
        env
        "LR05-old-controller-refused"
        "controller-signature"
        ( "after a real LR01 the old controller's ordinary maintenance is \
          \refused: the record's control is the reveal, not the old key"
        )
        signed
    noTrace env snap1 "LR05"

rowMaintainRecovered :: Env -> Snap -> IO Snap
rowMaintainRecovered env snap1 = do
    current <- chainDatumOf env snap1 "maintain-recovered"
    let maintained = current {paymentDestination = SomeDestination (envDestCodec env)}
    tx <- maintainTx env snap1 maintained [envRevealedHash env]
    let signed = addKeyWitness (mkSignKey revealedSeed) (addKeyWitness genesisSignKey tx)
    submitAccepted env "maintain-recovered" signed
    _ <- waitConfirmation (txIdHex signed <> " (maintain-recovered)")
    contIn <-
        mustFindUTxO (envProv env) (envAppAddr env) (txIdHex signed) "maintain-recovered continuation"
    contSnap <- mustSnap env contIn
    decoded <- chainDatumOf env contSnap "maintain-recovered"
    unless (paymentDestination decoded == SomeDestination (envDestCodec env)) $
        failWith "maintain-recovered: the payment destination was not maintained"
    unless (controlAddress decoded == controlAddress current) $
        failWith "maintain-recovered: the control changed under maintenance"
    emit
        "row"
        ( "LR05-maintenance-under-recovered-controller: accepted tx="
            <> txIdHex signed
            <> " continuation="
            <> showIn contIn
            <> " (the recovered key maintains normally; recovery produced a \
               \usable name)"
        )
    pure contSnap

finalNoTrace :: Env -> TxIn -> TxIn -> Snap -> IO ()
finalNoTrace env refusalsIn forgedIn rec2 = do
    snapR <- mustSnap env refusalsIn
    snapF <- mustSnap env forgedIn
    emit
        "no-trace"
        ( "state unchanged after every refusal — no trace: refusals="
            <> showIn refusalsIn
            <> " ("
            <> show (snapCoin snapR)
            <> " lovelace, tokens "
            <> show (snapTokens snapR)
            <> ", datum bytes unchanged), forged="
            <> showIn forgedIn
            <> " ("
            <> show (snapCoin snapF)
            <> " lovelace, tokens "
            <> show (snapTokens snapF)
            <> "), recovered successor="
            <> showIn (snapIn rec2)
            <> " live; the refused transactions left the authenticated state \
               \exactly as it was"
        )

-- ---------------------------------------------------------
-- Controls
-- ---------------------------------------------------------

runControlValid :: Env -> TxIn -> IO ()
runControlValid env recRefusals = do
    snap <- mustSnap env recRefusals
    current <- chainDatumOf env snap "CONTROL-valid"
    let successor =
            current
                { controlAddress = envRevealedCodec env
                , nextControlCommitment = envFreshC env
                }
    -- First a genuine refusal (emits a row, proving the runner ran).
    rowLR02 env snap
    -- Then LR03 made actually valid: the missing signer added.
    tx <- recoverTx env snap (serialiseAddr (envRevealedAddr env)) [snapRep snap] (scriptHashBytes (envScriptHash env)) successor [envRevealedHash env]
    let signed = addKeyWitness (mkSignKey revealedSeed) (addKeyWitness genesisSignKey tx)
    result <- submitTx (envSubmit env) signed
    case result of
        Submitted _ -> do
            emit
                "row"
                "LR03-missing-recovery-signer-refused: CONTROL valid-transaction \
                \succeeded as constructed — failing the run as required"
            failWith
                ( "CONTROL valid-transaction: LR03's transaction, made actually \
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
runControlWrongReason env recMain recRefusals = do
    -- LR01 first (accepts, emits a row, proving the runner ran).
    snapMain <- mustSnap env recMain
    _rec1 <- rowLR01 env snapMain
    -- Then a refusal matched against an impossible marker.
    snap <- mustSnap env recRefusals
    current <- chainDatumOf env snap "CONTROL-wrong-reason"
    let wrongSuccessor =
            current
                { controlAddress = envRevealedCodec env
                , nextControlCommitment = envFreshC env
                }
    txBad <- recoverTx env snap (serialiseAddr (envWrongAddr env)) [snapRep snap] (scriptHashBytes (envScriptHash env)) wrongSuccessor [envWrongHash env]
    let signedBad = addKeyWitness (mkSignKey wrongSeed) (addKeyWitness genesisSignKey txBad)
    expectRefused
        ControlWrongReason
        env
        "LR02-wrong-reveal-refused"
        "recovery-commitment"
        "wrong-reason control: this matcher must fail"
        signedBad
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
            scriptOut (envPp env) (envAppAddr env) (snapCoin snap) (snapRepTokens env snap) successor
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
            scriptOut (envPp env) (envAppAddr env) (snapCoin snap) (snapRepTokens env snap) successor
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

changeOut ::
    Integer ->
    Integer ->
    [TxOut ConwayEra] ->
    TxOut ConwayEra
changeOut inCoin fee outs =
    let spent = sum [c | o <- outs, let Coin c = o ^. coinTxOutL]
        change = inCoin - fee - spent
     in if change <= 1_000_000
            then error "recovery-rows: change underflow while balancing"
            else mkBasicTxOut genesisAddr (MaryValue (Coin change) mempty)

-- ---------------------------------------------------------
-- Setup transactions
-- ---------------------------------------------------------

-- | The snap's representative name: the single token the record carries
-- under the applied representative policy.
snapRep :: Snap -> ByteString
snapRep snap = case snapTokens snap of
    [(name, _)] -> name
    _ -> error "snapshot: the record does not carry exactly one representative"

-- | The snap's representative token map, for continuation outputs.
snapRepTokens :: Env -> Snap -> Map.Map PolicyID (Map.Map AssetName Integer)
snapRepTokens env snap =
    Map.singleton
        (envRepPolicy env)
        (Map.singleton (AssetName (SBS.toShort (snapRep snap))) 1)

bootRecoveryCage ::
    Cage.Provider IO ->
    Submitter IO ->
    TrieManager IO ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    IO (CageConfig, TokenId)
bootRecoveryCage prov submit tm stateBytes requestBytes = do
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
    emit "boot" "booted the recovery registry cage"
    pure (cfg, tok)

-- | Publish the four scripts as reference outputs so connected folds
-- resolve every purpose through reference inputs.
publishRecoveryRefs ::
    Cage.Provider IO ->
    Submitter IO ->
    PParams ConwayEra ->
    IORef [(TxIn, TxOut ConwayEra)] ->
    CageConfig ->
    TokenId ->
    Script ConwayEra ->
    Script ConwayEra ->
    IO [(TxIn, TxOut ConwayEra)]
publishRecoveryRefs prov submit pp poolRef cfg tok appScript repScript = do
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
submitRecoveryRequest :: Env -> ByteString -> ByteString -> IO (TxIn, TxOut ConwayEra)
submitRecoveryRequest env spelling value = do
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

queryRecoveryState :: Env -> IO (TxIn, TxOut ConwayEra)
queryRecoveryState env = do
    let cfg = envCfg env
        tok = envTok env
        stateAddr = cageAddrFromCfg cfg Testnet
    utxos <- Cage.queryUTxOs (envProv env) stateAddr
    case findStateUtxo (cagePolicyIdFromCfg cfg) tok utxos of
        Just x -> pure x
        Nothing -> failWith "state UTxO not found"

queryRecoveryFee :: Env -> IO (TxIn, TxOut ConwayEra)
queryRecoveryFee env = do
    (fund, _collateral) <- takeFundCollateral env
    pure fund

mustOutAt :: Env -> Addr -> TxIn -> IO (TxOut ConwayEra)
mustOutAt env addr txin = do
    utxos <- Cage.queryUTxOs (envProv env) addr
    case filter ((== txin) . fst) utxos of
        [(_, o)] -> pure o
        _ -> failWith ("output " <> showIn txin <> " is not live")

chainRecoveryRoot :: Env -> IO String
chainRecoveryRoot env = do
    (_, stateOut) <- queryRecoveryState env
    case extractCageDatum stateOut of
        Just (StateDatum st) ->
            let OnChainRoot bs = stateRoot st
             in pure (hex bs)
        _ -> failWith "the state UTxO carries no state datum"

-- | Fold one genuine record through the CONNECTED transaction: MPFS
-- request keyed by the given spelling plus the naming claim, one state
-- Modify, approval burn and representative mint. Returns the fold txid
-- and the record input.
setupGenuineRecord ::
    Env ->
    ByteString ->
    ByteString ->
    NamingDatum ->
    String ->
    ByteString ->
    IO (String, TxIn)
setupGenuineRecord env controllerSeed controllerHash datum label spelling = do
    let controlBytes = addressBytes (controlAddress datum)
        commitment = nextControlCommitment datum
        approval = insertApprovalName controlBytes commitment
        repName = representativeName controllerHash freshIncarnation
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
                            controllerHash
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
                    .~ Set.singleton (addrWitnessKeyHash controllerHash)
                & scriptIntegrityHashTxBodyL .~ integrityA
        txA =
            mkBasicTx bodyA
                & witsTxL . scriptTxWitsL
                    .~ Map.singleton (envScriptHash env) (envScript env)
                & witsTxL . rdmrsTxWitsL .~ redeemersA
    let signedA =
            addKeyWitness
                (mkSignKey controllerSeed)
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
    (reqIn, reqOut) <- submitRecoveryRequest env spelling repName
    -- The connected fold: state Modify, request Contribute, claim Fold.
    (stateIn, stateOut) <- queryRecoveryState env
    feeUtxo <- queryRecoveryFee env
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
                                    controllerHash
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
    rootAfter <- chainRecoveryRoot env
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
            case tokens of
                [_] -> pure (Snap txin c tokens datum)
                _ ->
                    failWith
                        ( "snapshot: "
                            <> showIn txin
                            <> " does not carry exactly one naming token \
                               \under the application or representative policy"
                        )
        _ ->
            failWith
                ( "snapshot: "
                    <> showIn txin
                    <> " is not live at the application validator"
                )

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
                    <> " is live at the application validator"
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

assertChainBytes :: Snap -> NamingDatum -> String -> IO ()
assertChainBytes snap expected label =
    case snapDatum snap >>= wireOf >>= serialiseWireData of
        Just chainBytes
            | Just codecBytes <- serialiseNamingDatum expected ->
                unless (chainBytes == codecBytes) $
                    failWith
                        ( label
                            <> ": the on-chain bytes are not the codec encoding: \
                               \chain=0x"
                                <> hex chainBytes
                                <> " codec=0x"
                                <> hex codecBytes
                        )
        _ ->
            failWith
                ( label
                    <> ": the chain datum cannot be serialised as the contract's \
                       \wire bytes"
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

redeemerRecover :: ByteString -> [ByteString] -> ByteString -> PLC.Data
redeemerRecover revealed reps registry =
    PLC.Constr 4 [PLC.B revealed, PLC.List (map PLC.B reps), PLC.B registry]

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

assertWitness :: Env -> ConwayTx -> IO ()
assertWitness env signed = do
    let witnessHashes =
            Set.fromList
                [ hex (scriptHashBytes sh)
                | sh <- Map.keys (signed ^. witsTxL . scriptTxWitsL)
                ]
    unless (witnessHashes == Set.singleton (envAppHex env)) $
        failWith $
            "identity: expected the tx witness to carry exactly the derived \
            \applied hash 0x"
                <> envAppHex env
                <> " but it held "
                <> show (Set.toList witnessHashes)

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

-- ---------------------------------------------------------
-- Narration and plumbing
-- ---------------------------------------------------------

emit :: String -> String -> IO ()
emit step detail = putStrLn ("[recovery] " <> step <> ": " <> detail)

failWith :: String -> IO a
failWith msg = throwIO (ErrorCall ("recovery-rows: " <> msg))

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

forgedCommitmentOf :: ByteString -> ByteString
forgedCommitmentOf bs =
    convert (hash bs :: Digest Blake2b_256)
