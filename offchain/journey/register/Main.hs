{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Main
Description : The genuine insert flow on a real devnet (issue #77)
License     : Apache-2.0

Executes @Singular.foldOne@'s @.insert@ case and @Singular.fold_iff@'s
fold leg against a real devnet node as one connected transaction: the
registry cage is booted, an MPFS insert request keyed by the name
spelling is submitted, an insert approval is minted under the
application policy binding the exact proposal core, the insert request
(claim) is queued at the naming application validator, and a single
fold spends the state through @Modify@ with trie proofs, consumes the
request with @Contribute@ and the claim with @Fold@ — minting the
representative @+1@ under the APPLIED representative policy, burning the
approval, freezing the datum — so the registry entry for the name
reaches @.active@. Roots come from the state datums the chain reports
before and after; the receipt names every observation.

Ledger realisation (offchain\/naming-correspondence.md, t77 entries):

  * the registry key is the NAME spelling (@alice@, @bob@ — the claim
    carries @key: 42@ alongside @spelling: "alice"@ in the corpus; the
    key is the identity of the name, resolved via the frozen
    @spellingKey@ table). Keying by controller would collide two names
    under one controller and let one name occupy two keys;

  * the registry value is the representative asset name: presence of
    @(spelling -> repName)@ in the authenticated root is the @Active@
    entry, decided by the state validator against inclusion and absence
    proofs — never by a cooperating client;

  * the representative is minted under
    @representative.representative.mint@ applied with the application
    policy hash (1 parameter), named @Rep \|\| control key hash \|\| 0x00@
    (32 bytes, never a canonical address); the registry half of
    @Singular.representative@'s scope is the parameterised policy
    itself. No longer does any row carry an application-policy stand-in:
    the former t62/t66 stand-in shape is removed, and the fault control
    @fault-seeded-active@ shows a seeded decoy name refused;

  * the application policy's mint purpose gains the insert-approval arm
    binding the exact proposal core — @step .createInsert@ needs the
    request's token to be @insertAsset r.proposal@. The arm is appended
    (index 1); existing encodings keep their indices;

  * the @Active@-creating fold carries no registry-owner signer: every
    slice transaction is funded and witnessed by ordinary parties, and
    the fold itself carries an empty required-signer set. Permissionless
    since #79; the run asserts this from the submitted transaction, not
    from its own sentences.

@occupied-key@ is a submitted duplicate: the second insert for the
active name is built with the guard bypassed (proofs against a fresh
trie), submitted, and refused by the STATE validator — alongside the
free-key control that succeeds in the same run.

Every refusal is asserted on its reason: phase-2 @PlutusFailure@ naming
the script that binds the violated check. A fee, missing-input or
malformed-CBOR refusal fails the run.

Modes (env @REGISTER_CONTROL@): @valid@ makes a mint refusal actually
valid, so it succeeds and the guard must fail the run; @wrong-reason@
matches a refusal against a marker that cannot occur, so the matcher
must fail the run. Fault modes @fault-rep-policy@, @fault-owner-signed@
and @fault-seeded-active@ keep the accepted log wording but corrupt one
genuine observation each (NOTE-001); each must fail naming the wrong
observation. All exit 1 by design, after executing rows.

Hermetic run (D-011), from @offchain/@:

> naming="$(nix build --quiet --no-link --print-out-paths ../naming-onchain#plutus-blueprint)"
> mpfs="$(nix build --quiet --no-link --print-out-paths ../onchain#plutus-blueprint)"
> TMPDIR=/tmp/s77-devnet NAMING_BLUEPRINT="$naming" MPFS_BLUEPRINT="$mpfs" nix run --quiet .#register-rows
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
import Data.Aeson (FromJSON (..), Value, eitherDecode', object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Bits (complement)
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Coerce (coerce)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, sortBy, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..), comparing)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word32)
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.Process (readProcess)
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
    addrTxWitsL,
    rdmrsTxWitsL,
    scriptTxWitsL,
    witVKeyHash,
 )
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Binary.Version (Version)
import Cardano.Ledger.BaseTypes (Network (..), StrictMaybe (..), TxIx (..))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (Script, extractHash, hashScript)
import Cardano.Ledger.Credential (Credential (..), StakeReference (..))
import Cardano.Ledger.Hashes (ScriptHash, unKeyHash)
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
    addrKeyHashBytes,
    addrWitnessKeyHash,
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    computeScriptHash,
    computeScriptIntegrity,
    currentPosixMs,
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
import Cardano.MPFS.Cage.TxBuilder.Retract (retractRequestImpl)
import Cardano.MPFS.Cage.Types (
    CageDatum (..),
    OnChainRequest (..),
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
    , serialiseWireData
    )

-- ---------------------------------------------------------
-- Run modes
-- ---------------------------------------------------------

data Mode
    = MainRun
    | ControlValid
    | ControlWrongReason
    | FaultRepPolicy
    | FaultOwnerSigned
    | FaultSeededActive
    deriving (Eq, Show)

readMode :: IO Mode
readMode =
    lookupEnv "REGISTER_CONTROL" >>= \case
        Just "valid" -> pure ControlValid
        Just "wrong-reason" -> pure ControlWrongReason
        Just "fault-rep-policy" -> pure FaultRepPolicy
        Just "fault-owner-signed" -> pure FaultOwnerSigned
        Just "fault-seeded-active" -> pure FaultSeededActive
        Just other
            | not (null other) ->
                failWith ("unknown REGISTER_CONTROL value " <> other)
        _ -> pure MainRun

wrongReasonMarker :: String
wrongReasonMarker =
    "wrong-reason-control marker that no node reason can ever contain"

-- ---------------------------------------------------------
-- Fixture seeds (each exactly 32 bytes for mkSignKey)
-- ---------------------------------------------------------

partySeed, folderSeed, secondSeed, advSeed, nextSeed, next2Seed, tamperSeed :: ByteString
partySeed = "s77-ordinary-party00000000000000"
folderSeed = "s77-folder-ordinary0000000000000"
secondSeed = "s77-second-controller00000000000"
advSeed = "s77-adversarial-controller000000"
nextSeed = "s77-next-controller0000000000000"
next2Seed = "s77-next2-controller000000000000"
tamperSeed = "s77-tamper-key000000000000000000"

-- ---------------------------------------------------------
-- Name spellings: the registry keys (NOTE-004)
-- ---------------------------------------------------------

aliceSpelling, bobSpelling :: ByteString
aliceSpelling = "alice"
bobSpelling = "bob"

-- ---------------------------------------------------------
-- Ledger-shape constants
-- ---------------------------------------------------------

flatFee :: Integer
flatFee = 10_000_000

maxUnits :: ExUnits
maxUnits = ExUnits 3_000_000 200_000_000

claimCoin :: Integer
claimCoin = 25_000_000

-- | Manual pool: every accepted slice tx burns one fund UTxO and every
-- refused slice tx burns one collateral UTxO (phase-2 slashing), so the
-- pool must cover funds plus collateral for the whole run.
faucetSplits :: Integer
faucetSplits = 48

faucetPerSplit :: Integer
faucetPerSplit = 500_000_000

folderSplits :: Integer
folderSplits = 4

folderPerSplit :: Integer
folderPerSplit = 500_000_000

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
                "issue #77: the connected insert flow on a real ledger — \
                \cage boot, spelling-keyed request, insert approval, queued \
                \claim, one fold binding state Modify, request Contribute \
                \and naming Fold into Active with the real representative"
        ControlValid ->
            emit
                "control"
                "valid-transaction control: a refused mint made actually \
                \valid, so it must succeed and the refusal guard must fail \
                \the run"
        ControlWrongReason ->
            emit
                "control"
                "wrong-reason control: a refusal matched against a marker \
                \that cannot occur, so the matcher must fail the run"
        FaultRepPolicy ->
            emit
                "fault"
                "fault-rep-policy control: the accepted fold wording is \
                \preserved but the representative is minted under a \
                \tampered policy — the run must fail naming the wrong \
                \observation"
        FaultOwnerSigned ->
            emit
                "fault"
                "fault-owner-signed control: the accepted fold wording is \
                \preserved but the fold carries the registry-owner signer \
                \— the run must fail naming the wrong observation"
        FaultSeededActive ->
            emit
                "fault"
                "fault-seeded-active control: the Active wording is \
                \preserved but the entry is seeded directly, disconnected \
                \from any fold — the run must fail naming the wrong \
                \observation"
    namingPath <- requireEnv "NAMING_BLUEPRINT"
    mpfsPath <- requireEnv "MPFS_BLUEPRINT"
    outcome <-
        try (runMode mode namingPath mpfsPath) :: IO (Either SomeException ())
    case outcome of
        Right () -> pure ()
        Left e -> do
            hPutStrLn stderr ("register-rows: FAILED: " <> displayException e)
            exitWith (ExitFailure 1)

-- ---------------------------------------------------------
-- The run
-- ---------------------------------------------------------

runMode :: Mode -> FilePath -> FilePath -> IO ()
runMode mode namingPath mpfsPath = do
    enbp <- loadBlueprint namingPath
    nbp <- either failWith pure enbp
    appBytes <- case extractCompiledCode "application.application" nbp of
        Just bytes -> pure bytes
        Nothing ->
            failWith
                "application.application compiled code not found in the \
                \naming blueprint"
    repBytes <- case extractCompiledCode "representative.representative" nbp of
        Just bytes -> pure bytes
        Nothing ->
            failWith
                "representative.representative compiled code not found in \
                \the naming blueprint"
    embp <- loadBlueprint mpfsPath
    mbp <- either failWith pure embp
    stateBytes <- case extractCompiledCode "state.state" mbp of
        Just bytes -> pure bytes
        Nothing ->
            failWith
                "state.state compiled code not found in the MPFS blueprint"
    requestBytes <- case extractCompiledCode "request.request" mbp of
        Just bytes -> pure bytes
        Nothing ->
            failWith
                "request.request compiled code not found in the MPFS blueprint"
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
        let appScript = scriptFromBytes "naming-application" appBytes
            appHash = computeScriptHash appBytes
            appHex = hex (scriptHashBytes appHash)
            appAddr = Addr Testnet (ScriptHashObj appHash) StakeRefNull
            appPolicy = PolicyID appHash
            repUnappliedHex =
                hex (scriptHashBytes (computeScriptHash repBytes))
            repAppliedBytes =
                applyBytesParam (scriptHashBytes appHash) repBytes
            repAppliedHash = computeScriptHash repAppliedBytes
            repAppliedHex = hex (scriptHashBytes repAppliedHash)
            repAppliedPolicy = PolicyID repAppliedHash
            repAppliedScript =
                scriptFromBytes "representative" repAppliedBytes
            stateUnappliedHex =
                hex (scriptHashBytes (computeScriptHash stateBytes))
            appliedStateBytes = stateBytes
            appliedStateHash = computeScriptHash appliedStateBytes
            appliedStateHex = hex (scriptHashBytes appliedStateHash)
        checkPinnedNamingApplication appHex
        checkPinnedRepresentative repUnappliedHex
        checkPinnedMpfsState stateUnappliedHex
        emit
            "identity"
            ( "naming application 0x"
                <> appHex
                <> " (0 parameters: pinned is applied); representative \
                   \unapplied 0x"
                <> repUnappliedHex
                <> " applied 0x"
                <> repAppliedHex
                <> " (parameter: application-policy hash); registry state \
                   \unapplied 0x"
                <> stateUnappliedHex
                <> " applied 0x"
                <> appliedStateHex
                <> " (previousPolicies=[])"
            )
        let ownerHash = addrKeyHashBytes genesisAddr
            partyHash =
                addrKeyHashBytes
                    (enterpriseAddr (keyHashFromSignKey (mkSignKey partySeed)))
            partyAddr =
                enterpriseAddr (keyHashFromSignKey (mkSignKey partySeed))
            folderHash =
                addrKeyHashBytes
                    (enterpriseAddr (keyHashFromSignKey (mkSignKey folderSeed)))
            folderAddr =
                enterpriseAddr (keyHashFromSignKey (mkSignKey folderSeed))
            secondHash =
                addrKeyHashBytes
                    (enterpriseAddr (keyHashFromSignKey (mkSignKey secondSeed)))
            secondAddr =
                enterpriseAddr (keyHashFromSignKey (mkSignKey secondSeed))
            advHash =
                addrKeyHashBytes
                    (enterpriseAddr (keyHashFromSignKey (mkSignKey advSeed)))
            advAddr =
                enterpriseAddr (keyHashFromSignKey (mkSignKey advSeed))
            mustCodec bytes = case decodeAddress bytes of
                Just a -> a
                Nothing ->
                    error
                        "fixture: a devnet address does not decode as the \
                        \contract's canonical address"
        emit
            "actors"
            ( "registry owner 0x"
                <> hex ownerHash
                <> " (devnet genesis key: seeds the cage once, funds the \
                   \faucet once, then never signs); ordinary party 0x"
                <> hex partyHash
                <> " (controls alice and funds manual transactions); cage folder 0x"
                <> hex folderHash
                <> " (funds every cage transaction); second ordinary controller \
                   \0x"
                <> hex secondHash
                <> " (controls bob); adversarial controller 0x"
                <> hex advHash
                <> " (second alice claimant)"
            )
        tm <- mkPureTrieManager
        tmFresh <- mkPureTrieManager
        evDir <- evidenceDirFromEnv
        createDirectoryIfMissing True evDir
        evNext <- newIORef (0 :: Int)
        (candidate, worktreeDirty) <- candidateFromRepo
        writeEvidenceMeta evDir candidate worktreeDirty namingPath mpfsPath appHex repAppliedHex appliedStateHex
        (cfg, tok) <-
            bootCage prov submit tm appliedStateBytes requestBytes evDir evNext
        -- The adversarial manager gets its own empty trie, never synced
        -- with the cage: proofs built against it fail on-chain, which is
        -- exactly the occupied-key refusal.
        createTrie tmFresh tok
        pool <- faucetParty prov submit evDir evNext
        poolRef <- newIORef pool
        let refScripts =
                [ mkCageScript cfg
                , mkRequestScript cfg tok
                , appScript
                , repAppliedScript
                ]
        scriptRefs <- publishScripts prov submit pp poolRef refScripts partyAddr evDir evNext
        let env =
                Env
                    { envProv = prov
                    , envSubmit = submit
                    , envPp = pp
                    , envPool = poolRef
                    , envCfg = cfg
                    , envTok = tok
                    , envTrie = tm
                    , envTrieFresh = tmFresh
                    , envRefUtxos = scriptRefs
                    , envStateHash = appliedStateHash
                    , envStateHex = appliedStateHex
                    , envAppScript = appScript
                    , envAppHash = appHash
                    , envAppHex = appHex
                    , envAppPolicy = appPolicy
                    , envAppAddr = appAddr
                    , envRepUnapplied = repBytes
                    , envRepScript = repAppliedScript
                    , envRepHash = repAppliedHash
                    , envRepHex = repAppliedHex
                    , envRepPolicy = repAppliedPolicy
                    , envOwnerHash = ownerHash
                    , envPartyHash = partyHash
                    , envPartyAddr = partyAddr
                    , envFolderHash = folderHash
                    , envFolderAddr = folderAddr
                    , envPartyCodec = mustCodec (serialiseAddr partyAddr)
                    , envSecondHash = secondHash
                    , envSecondAddr = secondAddr
                    , envSecondCodec = mustCodec (serialiseAddr secondAddr)
                    , envAdvHash = advHash
                    , envAdvAddr = advAddr
                    , envAdvCodec = mustCodec (serialiseAddr advAddr)
                    , envEvDir = evDir
                    , envEvNext = evNext
                    , envCandidate = candidate
                    , envNamingBlueprint = namingPath
                    , envMpfsBlueprint = mpfsPath
                    }
        receiptRef <- newIORef []
        let record = recordRow receiptRef
        case mode of
            MainRun -> runRows env record
            ControlValid -> runControlValid env
            ControlWrongReason -> runControlWrongReason env
            FaultRepPolicy -> runFaultRepPolicy env
            FaultOwnerSigned -> runFaultOwnerSigned env
            FaultSeededActive -> runFaultSeededActive env
        rows <- readIORef receiptRef
        BSL.writeFile
            (envEvDir env </> "report.json")
            ( Aeson.encode $
                object
                    [ "candidate" .= envCandidate env
                    , "namingBlueprint" .= envNamingBlueprint env
                    , "mpfsBlueprint" .= envMpfsBlueprint env
                    , "rows" .= reverse rows
                    ]
            )
        emit "report" ("human-readable report (S3 reads raw evidence, not this): " <> (envEvDir env </> "report.json"))
        cancel nodeThread

data Env = Env
    { envProv :: Cage.Provider IO
    , envSubmit :: Submitter IO
    , envPp :: PParams ConwayEra
    , envPool :: IORef [(TxIn, TxOut ConwayEra)]
    , envCfg :: CageConfig
    , envTok :: TokenId
    , envTrie :: TrieManager IO
    , envTrieFresh :: TrieManager IO
    , envRefUtxos :: [(TxIn, TxOut ConwayEra)]
    , envStateHash :: ScriptHash
    , envStateHex :: String
    , envAppScript :: Script ConwayEra
    , envAppHash :: ScriptHash
    , envAppHex :: String
    , envAppPolicy :: PolicyID
    , envAppAddr :: Addr
    , envRepUnapplied :: SBS.ShortByteString
    , envRepScript :: Script ConwayEra
    , envRepHash :: ScriptHash
    , envRepHex :: String
    , envRepPolicy :: PolicyID
    , envOwnerHash :: ByteString
    , envPartyHash :: ByteString
    , envPartyAddr :: Addr
    , envFolderHash :: ByteString
    , envFolderAddr :: Addr
    , envPartyCodec :: Address
    , envSecondHash :: ByteString
    , envSecondAddr :: Addr
    , envSecondCodec :: Address
    , envAdvHash :: ByteString
    , envAdvAddr :: Addr
    , envAdvCodec :: Address
    , envEvDir :: FilePath
    , envEvNext :: IORef Int
    , envCandidate :: String
    , envNamingBlueprint :: FilePath
    , envMpfsBlueprint :: FilePath
    }

-- ---------------------------------------------------------
-- The main rows
-- ---------------------------------------------------------

runRows :: Env -> (Value -> IO ()) -> IO ()
runRows env record = do
    root0 <- chainRootHex env
    mgr0 <- managerRootHex env (envTrie env)
    unless (root0 == mgr0) $
        failWith "genesis: the chain root and the manager root disagree"
    emit
        "row"
        ( "genesis: registry root "
            <> root0
            <> " read from the chain state datum — no name Active"
        )
    -- Supported request, submitted early so it ages into the retract
    -- window for the closing retract row.
    supportReq <- submitSupportRequest env record "support-aging" "support-value"
    -- alice: the connected insert, accepted.
    alice <- setupKey env "alice" aliceSpelling (envPartyCodec env) (envPartyAddr env) (envPartyHash env) partySeed nextSeed
    foldTxAlice <- connectedAccept env record (envTrie env) alice True "fold-active"
    -- Adversarial alice: same name, another controller — built with the
    -- guard bypassed, submitted, refused by the state validator.
    advAlice <- setupKey env "alice-dup" aliceSpelling (envAdvCodec env) (envAdvAddr env) (envAdvHash env) advSeed next2Seed
    runAdversarial env record alice advAlice
    -- bob: the free-key control succeeds in the same run.
    bob <- setupKey env "bob" bobSpelling (envSecondCodec env) (envSecondAddr env) (envSecondHash env) secondSeed nextSeed
    _ <- connectedAccept env record (envTrie env) bob True "free-key-control"
    emit
        "row"
        "free-key-control: bob folded clean in the same run — the \
        \occupied-name refusal is about alice being taken, not about folding"
    -- Mint negatives: the insert-approval arm refuses.
    rowMintBadName env
    rowMintNoSigner env
    -- key3: fold negatives against a live insert claim (naming only).
    key3 <- setupKey env "key3" "carol" (mustCodecOf tamperSeed) (enterpriseAddr (keyHashFromSignKey (mkSignKey tamperSeed))) (addrKeyHashBytes (enterpriseAddr (keyHashFromSignKey (mkSignKey tamperSeed)))) tamperSeed nextSeed
    (_claim3Tx, claim3In, _claim3Out) <- setupNamingClaim env key3
    rowFoldTamperedRep env key3 claim3In
    rowFoldMissingRep env key3 claim3In
    rowFoldEmptyReps env key3 claim3In
    -- Withdraw-approval claim: an insert fold cannot consume it.
    claimWTx <- createWithdrawClaim env key3
    claimWIn <- mustFindUTxO (envProv env) (envAppAddr env) claimWTx "withdraw claim"
    rowFoldWithdrawApproval env key3 claimWIn
    -- Ownerless rows: submitted refusals on the same cage.
    runOwnerlessEnd env record False
    runOwnerlessEnd env record True
    runOwnerlessMigration env record
    runOwnerlessBurning env record
    runOwnerlessSweep env record False
    runOwnerlessSweep env record True
    -- Supported actions: plain fold and retract on the same cage.
    runSupportFold env record
    runSupportRetract env record supportReq
    -- Final sweep: chain root plus one Active record per folded name.
    finalSweep env alice bob foldTxAlice
    emit
        "complete"
        "the connected insert flow executed on a real devnet: alice and \
        \bob folded into Active with real representatives, the duplicate \
        \alice refused by the state validator with the free-key control, \
        \every new check refused on its reason"

mustCodecOf :: ByteString -> Address
mustCodecOf seed =
    case decodeAddress (serialiseAddr (enterpriseAddr (keyHashFromSignKey (mkSignKey seed)))) of
        Just a -> a
        Nothing -> error "fixture: devnet address does not decode"

-- | One controlled name: spelling (the registry key), datum, approval,
-- representative.
data KeySetup = KeySetup
    { keyLabel :: String
    , keySpelling :: ByteString
    , keyDatum :: NamingDatum
    , keyControlBytes :: ByteString
    , keyCommitment :: ByteString
    , keyControllerHash :: ByteString
    , keyControllerSeed :: ByteString
    }

setupKey :: Env -> String -> ByteString -> Address -> Addr -> ByteString -> ByteString -> ByteString -> IO KeySetup
setupKey _env label spelling codec addr controllerHash controllerSeed revealSeed = do
    let revealAddr = enterpriseAddr (keyHashFromSignKey (mkSignKey revealSeed))
        commitment = nextControlCommitmentOf (serialiseAddr revealAddr)
        datum =
            NamingDatum
                { controlAddress = codec
                , paymentDestination = NoDestination
                , nextControlCommitment = commitment
                , retirementQuorum =
                    RetirementQuorum
                        { quorumMembers = [controllerHash]
                        , quorumThreshold = 1
                        }
                }
        approval = insertApprovalName (serialiseAddr addr) commitment
        repName = representativeName controllerHash freshIncarnation
    emit
        "key"
        ( label
            <> ": spelling "
            <> show spelling
            <> " control 0x"
            <> hex (serialiseAddr addr)
            <> " commitment 0x"
            <> hex commitment
            <> " approval 0x"
            <> hex approval
            <> " representative 0x"
            <> hex repName
        )
    pure
        KeySetup
            { keyLabel = label
            , keySpelling = spelling
            , keyDatum = datum
            , keyControlBytes = serialiseAddr addr
            , keyCommitment = commitment
            , keyControllerHash = controllerHash
            , keyControllerSeed = controllerSeed
            }

keyRepName :: KeySetup -> ByteString
keyRepName ks = representativeName (keyControllerHash ks) freshIncarnation

-- ---------------------------------------------------------
-- Cage boot and requests
-- ---------------------------------------------------------

bootCage ::
    Cage.Provider IO ->
    Submitter IO ->
    TrieManager IO ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    FilePath ->
    IORef Int ->
    IO (CageConfig, TokenId)
bootCage prov submit tm stateBytes requestBytes evDir evNext = do
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
    result <- submitRetainAt evDir evNext submit "cage-boot" signedBoot
    case result of
        Submitted _ -> pure ()
        Rejected reason ->
            failWith ("boot: rejected: " <> show reason)
    threadDelay 5_000_000
    let MultiAsset ma = signedBoot ^. bodyTxL . mintTxBodyL
        assets = Map.toList (ma Map.! cagePolicyIdFromCfg cfg)
    tok <- case assets of
        [(an, _)] -> pure (TokenId an)
        _ -> failWith "boot: unexpected minted assets"
    createTrie tm tok
    emit "boot" "booted the registry cage (permissionless folds from here)"
    pure (cfg, tok)

-- | Submit one MPFS insert request: spelling -> representative name.
-- Returns the request input and output.
submitMPFSRequest :: Env -> ByteString -> ByteString -> IO (TxIn, TxOut ConwayEra)
submitMPFSRequest env spelling value = do
    let cfg = envCfg env
        tok = envTok env
    unsigned <-
        requestInsertImpl cfg (envProv env) (Coin 1_000_000) tok spelling value (envFolderAddr env)
    let signed = addKeyWitness (mkSignKey folderSeed) unsigned
    result <- submitRetain env ("mpfs-request-" <> show spelling) signed
    case result of
        Submitted _ -> pure ()
        Rejected reason ->
            failWith ("request: rejected: " <> show reason)
    let txid = txIdHex signed
    _ <- waitConfirmation (txid <> " (MPFS request " <> show spelling <> ")")
    let reqAddr = requestAddrFromCfg cfg tok Testnet
    reqIn <- mustFindUTxO (envProv env) reqAddr txid "MPFS request"
    reqOut <- mustOutAt (envProv env) reqAddr reqIn
    emit
        "requested"
        ( "spelling "
            <> show spelling
            <> " requested as "
            <> showIn reqIn
        )
    pure (reqIn, reqOut)

queryStateUtxo :: Env -> IO (TxIn, TxOut ConwayEra)
queryStateUtxo env = do
    let cfg = envCfg env
        tok = envTok env
        stateAddr = cageAddrFromCfg cfg Testnet
    utxos <- Cage.queryUTxOs (envProv env) stateAddr
    case findStateUtxo (cagePolicyIdFromCfg cfg) tok utxos of
        Just x -> pure x
        Nothing -> failWith "state UTxO not found"

queryFeeUtxo :: Env -> IO (TxIn, TxOut ConwayEra)
queryFeeUtxo env = do
    utxos <- Cage.queryUTxOs (envProv env) (envFolderAddr env)
    case sortOn (Down . (^. coinTxOutL) . snd) utxos of
        [] -> failWith "fee: the folder wallet has no UTxOs"
        (u : _) -> pure u

-- | The registry root hex read from the chain state datum.
chainRootHex :: Env -> IO String
chainRootHex env = do
    (_, stateOut) <- queryStateUtxo env
    case extractCageDatum stateOut of
        Just (StateDatum st) ->
            let OnChainRoot bs = stateRoot st
             in pure (hex bs)
        _ -> failWith "the state UTxO carries no state datum"

-- | The manager's root hex (proofs are computed against this).
managerRootHex :: Env -> TrieManager IO -> IO String
managerRootHex env tm = do
    r <- withTrie tm (envTok env) getRoot
    pure (hex (unRoot r))

-- ---------------------------------------------------------
-- Naming claims (approval mint + queued claim, controller-signed)
-- ---------------------------------------------------------

setupNamingClaim :: Env -> KeySetup -> IO (String, TxIn, TxOut ConwayEra)
setupNamingClaim env ks = do
    let approval = insertApprovalName (keyControlBytes ks) (keyCommitment ks)
        approvalMA =
            MultiAsset $
                Map.singleton
                    (envAppPolicy env)
                    (Map.singleton (AssetName (SBS.toShort approval)) 1)
    (fund, collateral) <- takeFundCollateral env
    let claimOut =
            scriptOut
                (envPp env)
                (envAppAddr env)
                claimCoin
                approvalMA
                (keyDatum ks)
        change = changeOut (coinOf fund) flatFee [claimOut] (envPartyAddr env)
        redeemers =
            Redeemers $
                Map.singleton
                    (ConwayMinting (AsIx 0))
                    ( Data
                        ( insertApprovalRedeemer
                            (keyControllerHash ks)
                            (keyControlBytes ks)
                            (keyCommitment ks)
                        )
                    , maxUnits
                    )
        integrity = computeScriptIntegrity (envPp env) redeemers
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.fromList [fst fund]
                & collateralInputsTxBodyL .~ Set.singleton (fst collateral)
                & outputsTxBodyL .~ StrictSeq.fromList [claimOut, change]
                & feeTxBodyL .~ Coin flatFee
                & mintTxBodyL .~ approvalMA
                & reqSignerHashesTxBodyL
                    .~ Set.singleton
                        (addrWitnessKeyHash (keyControllerHash ks))
                & scriptIntegrityHashTxBodyL .~ integrity
        tx =
            mkBasicTx body
                & witsTxL . scriptTxWitsL
                    .~ Map.singleton (envAppHash env) (envAppScript env)
                & witsTxL . rdmrsTxWitsL .~ redeemers
        signed =
            addKeyWitness
                (mkSignKey (keyControllerSeed ks))
                (addKeyWitness (mkSignKey partySeed) tx)
    assertOwnerAbsentTx env signed (keyLabel ks <> " insert-request creation")
    submitAccepted env (keyLabel ks <> "-insert-request") signed
    let txid = txIdHex signed
    _ <- waitConfirmation (txid <> " (" <> keyLabel ks <> " insert-request)")
    claimIn <- mustFindUTxO (envProv env) (envAppAddr env) txid (keyLabel ks <> " claim")
    claimLive <- mustOutAt (envProv env) (envAppAddr env) claimIn
    emit
        "row"
        ( "insert-request-queued: "
            <> keyLabel ks
            <> " claim "
            <> showIn claimIn
            <> " carries the insert approval 0x"
            <> hex approval
        )
    pure (txid, claimIn, claimLive)
  where
    coinOf (_, o) = let Coin c = o ^. coinTxOutL in c

-- ---------------------------------------------------------
-- The connected fold: accept path
-- ---------------------------------------------------------

-- | Fold one name through the connected transaction and assert every
-- NOTE-001 observation. Returns the fold txid. The trie manager must be
-- synced with the chain root (@checkSync@); the adversarial path passes
-- a fresh manager with no sync check.
connectedAccept ::
    Env ->
    (Value -> IO ()) ->
    TrieManager IO ->
    KeySetup ->
    Bool ->
    String ->
    IO String
connectedAccept env record tm ks checkSync rowKind = do
    (_claimTx, claimIn, _claimOut) <- setupNamingClaim env ks
    snapClaim <- mustSnap env claimIn
    _ <- assertQueuedRequest env ks snapClaim
    (reqIn, reqOut) <- submitMPFSRequest env (keySpelling ks) (keyRepName ks)
    (stateIn, _stateOut) <- queryStateUtxo env
    feeUtxo <- queryFeeUtxo env
    rootBefore <- chainRootHex env
    when checkSync $ do
        mgr <- managerRootHex env tm
        unless (mgr == rootBefore) $
            failWith
                ( keyLabel ks
                    <> ": proofs would not be computed against the \
                       \chain-read root (manager "
                    <> mgr
                    <> " vs chain "
                    <> rootBefore
                    <> ")"
                )
    let repName = keyRepName ks
        approval = insertApprovalName (keyControlBytes ks) (keyCommitment ks)
        recordTokens =
            MultiAsset $
                Map.singleton
                    (envRepPolicy env)
                    (Map.singleton (AssetName (SBS.toShort repName)) 1)
        recordOut =
            scriptOut
                (envPp env)
                (envAppAddr env)
                (snapCoin snapClaim)
                recordTokens
                (keyDatum ks)
    (unsigned, newRoot) <-
        connectedFoldTx
            ConnectedFoldArgs
                { cfaCfg = envCfg env
                , cfaProvider = envProv env
                , cfaTrie = tm
                , cfaToken = envTok env
                , cfaFeeAddr = envFolderAddr env
                , cfaStateUtxo = (stateIn, _stateOut)
                , cfaReqUtxos = [(reqIn, reqOut)]
                , cfaFeeUtxo = feeUtxo
                , cfaPp = envPp env
                , cfaSpends =
                    [ ConnectedSpend
                        { csUtxo = (claimIn, _claimOut)
                        , csRedeemer =
                            RawRedeemer (foldRedeemer [repName])
                        , csScript = envAppScript env
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
                                    (keyControllerHash ks)
                                    (keyControlBytes ks)
                                    (keyCommitment ks)
                                )
                        , cmScript = envAppScript env
                        }
                    , ConnectedMint
                        { cmPolicy = envRepPolicy env
                        , cmAssets =
                            Map.singleton
                                (AssetName (SBS.toShort repName))
                                1
                        , cmRedeemer =
                            RawRedeemer mintRepresentativeRedeemer
                        , cmScript = envRepScript env
                        }
                    ]
                , cfaOutputs = [recordOut]
                , cfaSigners = []
                , cfaSkipEval = False
                , cfaAttachScripts = []
                , cfaRefUtxos = envRefUtxos env
                , cfaAdjustRoot = id
                }
    let signed = addKeyWitness (mkSignKey folderSeed) unsigned
    -- NOTE-001.2, pre-submit: the fold carries no registry-owner signer.
    assertFoldPermissionless env signed (keyLabel ks)
    retainListings env (keyLabel ks <> "-fold-pre")
    submitAccepted env (keyLabel ks <> "-fold") signed
    let txid = txIdHex signed
    _ <- waitConfirmation (txid <> " (" <> keyLabel ks <> " fold)")
    -- NOTE-001.3: the mint field carries the APPLIED representative
    -- identity with the expected name at +1.
    assertRepMintedByFold env signed repName txid (keyLabel ks)
    -- NOTE-001.2, post-submit: witnesses name no owner either.
    assertOwnerAbsentWitnesses env signed txid (keyLabel ks)
    -- NOTE-001.1: the fold is connected — state moved, request and claim
    -- consumed, Active record produced.
    rootAfter <- chainRootHex env
    retainListings env (keyLabel ks <> "-fold-post")
    unless (rootAfter == hex (unRoot newRoot)) $
        failWith
            ( keyLabel ks
                <> ": the chain root "
                <> rootAfter
                <> " is not the computed new root "
                <> hex (unRoot newRoot)
            )
    reqLive <- isLiveAt (envProv env) (requestAddrFromCfg (envCfg env) (envTok env) Testnet) reqIn
    when reqLive $
        failWith (keyLabel ks <> ": the MPFS request survived the fold")
    claimLive <- isLiveAt (envProv env) (envAppAddr env) claimIn
    when claimLive $
        failWith (keyLabel ks <> ": the naming claim survived the fold")
    recordIn <-
        mustFindUTxO (envProv env) (envAppAddr env) txid (keyLabel ks <> " record")
    snapRecord <- mustSnap env recordIn
    decoded <- chainDatumOf snapRecord (keyLabel ks <> "-active")
    unless (decoded == keyDatum ks) $
        failWith (keyLabel ks <> ": the Active datum is not the frozen proposal")
    assertChainBytes snapRecord (keyDatum ks) (keyLabel ks <> "-active")
    unless (lookupToken snapRecord (envRepPolicy env) repName == Just 1) $
        failWith
            ( keyLabel ks
                <> ": the Active record does not carry 0x"
                <> hex repName
                <> " under the applied representative policy 0x"
                <> envRepHex env
            )
    syncFoldedRequests tm (envTok env) [(reqIn, reqOut)]
    emit
        "row"
        ( keyLabel ks
            <> "-fold-accepted: accepted tx="
            <> txid
            <> " record="
            <> showIn recordIn
        )
    emit
        "fold-root-active"
        ( "the fold "
            <> txid
            <> " moved the registry root from "
            <> rootBefore
            <> " to "
            <> rootAfter
            <> " (state spent with Modify, request Contribute, claim Fold): \
               \the entry for "
            <> show (keySpelling ks)
            <> " is Active with representative 0x"
            <> hex repName
            <> " minted +1 under the applied policy 0x"
            <> envRepHex env
        )
    contDatum <- stateDatumObject env
    contIn <- mustFindUTxO (envProv env) (cageAddrFromCfg (envCfg env) Testnet) txid (keyLabel ks <> " continuation")
    let distinctFromField
            | rowKind == "free-key-control" = ["distinctFrom" .= ("occupied-key" :: String)]
            | otherwise = []
    record $
        object $
            [ "row" .= (rowKind :: String)
            , "submittedTxId" .= txid
            , "outcome" .= ("accepted" :: String)
            , "stateInput" .= showIn stateIn
            , "requestInput" .= [showIn reqIn]
            , "stateContinuationDatum" .= contDatum
            , "rootBefore" .= rootBefore
            , "rootAfter" .= rootAfter
            , "rootBeforeObservedFrom" .= showIn stateIn
            , "rootAfterObservedFrom" .= showIn contIn
            , "applicationPolicy" .= envAppHex env
            , "representativeAppliedPolicy" .= envRepHex env
            , "representativeAssetName" .= hex repName
            , "mint" .= mintFacts signed
            , "requiredSigners" .= signerHexes signed
            , "vkeyWitnesses" .= witnessHexes signed
            ]
            <> distinctFromField
    pure txid

-- | The queued request holds the datum and the exact approval; the
-- registry entry is still absent (no root change yet).
assertQueuedRequest :: Env -> KeySetup -> Snap -> IO ()
assertQueuedRequest env ks snap = do
    decoded <- chainDatumOf snap (keyLabel ks <> "-queued")
    unless (decoded == keyDatum ks) $
        failWith (keyLabel ks <> ": the queued claim datum is not the proposal datum")
    assertChainBytes snap (keyDatum ks) (keyLabel ks <> "-queued")
    let approval = insertApprovalName (keyControlBytes ks) (keyCommitment ks)
    unless (lookupToken snap (envAppPolicy env) approval == Just 1) $
        failWith
            ( keyLabel ks
                <> ": the queued claim does not carry the bound insert approval"
            )

-- ---------------------------------------------------------
-- The adversarial duplicate: submitted, refused by the state
-- ---------------------------------------------------------

-- | The second insert for the taken name, built with the guard
-- bypassed (proofs against a fresh trie that has never seen alice) and
-- SUBMITTED. The state validator must refuse with the occupied name;
-- the free name folds in the same run elsewhere.
runAdversarial :: Env -> (Value -> IO ()) -> KeySetup -> KeySetup -> IO ()
runAdversarial env record ksAccepted ks = do
    (_claimTx, claimIn, claimOut) <- setupNamingClaim env ks
    snapClaim <- mustSnap env claimIn
    _ <- assertQueuedRequest env ks snapClaim
    (reqIn, reqOut) <- submitMPFSRequest env (keySpelling ks) (keyRepName ks)
    (stateIn, stateOut) <- queryStateUtxo env
    feeUtxo <- queryFeeUtxo env
    rootBefore <- chainRootHex env
    let tmFresh = envTrieFresh env
        repName = keyRepName ks
        approval = insertApprovalName (keyControlBytes ks) (keyCommitment ks)
        recordTokens =
            MultiAsset $
                Map.singleton
                    (envRepPolicy env)
                    (Map.singleton (AssetName (SBS.toShort repName)) 1)
        recordOut =
            scriptOut
                (envPp env)
                (envAppAddr env)
                (snapCoin snapClaim)
                recordTokens
                (keyDatum ks)
    (unsigned, _newRoot) <-
        connectedFoldTx
            ConnectedFoldArgs
                { cfaCfg = envCfg env
                , cfaProvider = envProv env
                , cfaTrie = tmFresh
                , cfaToken = envTok env
                , cfaFeeAddr = envFolderAddr env
                , cfaStateUtxo = (stateIn, stateOut)
                , cfaReqUtxos = [(reqIn, reqOut)]
                , cfaFeeUtxo = feeUtxo
                , cfaPp = envPp env
                , cfaSpends =
                    [ ConnectedSpend
                        { csUtxo = (claimIn, claimOut)
                        , csRedeemer = RawRedeemer (foldRedeemer [repName])
                        , csScript = envAppScript env
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
                                    (keyControllerHash ks)
                                    (keyControlBytes ks)
                                    (keyCommitment ks)
                                )
                        , cmScript = envAppScript env
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
                , cfaSkipEval = True
                , cfaAttachScripts = []
                , cfaRefUtxos = envRefUtxos env
                , cfaAdjustRoot = id
                }
    let signed = addKeyWitness (mkSignKey folderSeed) unsigned
        txid = txIdHex signed
    emit
        "row"
        ( "occupied-key-submitted: duplicate insert for "
            <> show (keySpelling ks)
            <> " submitted as "
            <> txid
            <> " (proofs against a fresh trie; no client guard)"
        )
    retainListings env "adv-fold-pre"
    result <- submitRetain env "adversarial-fold" signed
    case result of
        Submitted _ ->
            failWith
                ( "occupied-key: the duplicate insert for "
                    <> show (keySpelling ks)
                    <> " was ACCEPTED as "
                    <> txid
                    <> " — the taken name folded twice"
                )
        Rejected reason -> do
            let reasonText = T.unpack (TE.decodeUtf8Lenient reason)
            unless ("PlutusFailure" `isInfixOf` reasonText) $
                failWith
                    ( "occupied-key: the duplicate was refused WITHOUT \
                       \phase-2 validator evidence: <"
                        <> reasonText
                        <> ">"
                    )
            unless (envStateHex env `isInfixOf` reasonText) $
                failWith
                    ( "occupied-key: the refusal does not name the state \
                       \validator 0x"
                        <> envStateHex env
                        <> ": <"
                        <> reasonText
                        <> ">"
                    )
            rootAfter <- chainRootHex env
            retainListings env "adv-fold-post"
            unless (rootAfter == rootBefore) $
                failWith "occupied-key: the refused fold moved the chain root"
            dups <- recordsForSpelling env ksAccepted
            unless (length dups == 1) $
                failWith
                    ( "occupied-key: expected exactly one Active record for "
                        <> show (keySpelling ks)
                        <> " but found "
                        <> show (length dups)
                    )
            reqLive <-
                isLiveAt
                    (envProv env)
                    (requestAddrFromCfg (envCfg env) (envTok env) Testnet)
                    reqIn
            unless reqLive $
                failWith "occupied-key: the refused request did not stay pending"
            claimLive <- isLiveAt (envProv env) (envAppAddr env) claimIn
            unless claimLive $
                failWith "occupied-key: the refused claim did not stay queued"
            emit
                "row"
                ( "occupied-key-refused: duplicate insert for "
                    <> show (keySpelling ks)
                    <> " REFUSED by the state validator 0x"
                    <> envStateHex env
                    <> " (Singular.foldOne .insert occupied-key); submitted \
                       \as "
                    <> txid
                    <> "; root unchanged at "
                    <> rootAfter
                    <> "; exactly one Active record; request and claim stay \
                       \pending"
                )
            record $
                object
                    [ "row" .= ("occupied-key" :: String)
                    , "operation" .= ("insert" :: String)
                    , "submittedTxId" .= txid
                    , "outcome" .= ("refused" :: String)
                    , "refusedByScript" .= envStateHex env
                    , "stateInput" .= showIn stateIn
                    , "requestInput" .= [showIn reqIn]
                    , "rootBefore" .= rootBefore
                    , "rootAfter" .= rootAfter
                    , "requiredSigners" .= signerHexes signed
                    , "vkeyWitnesses" .= witnessHexes signed
                    , "mint" .= mintFacts signed
                    ]

-- | Live Active records for the spelling: the value carries this
-- spelling's representative under the applied policy.
recordsForSpelling :: Env -> KeySetup -> IO [TxIn]
recordsForSpelling env ks = do
    utxos <- Cage.queryUTxOs (envProv env) (envAppAddr env)
    pure
        [ i
        | utxo@(i, _) <- utxos
        , let snap = extractSnap utxo
        , lookupToken snap (envRepPolicy env) (keyRepName ks) == Just 1
        ]

-- | Final sweep: chain root plus one Active record per folded name.
finalSweep :: Env -> KeySetup -> KeySetup -> String -> IO ()
finalSweep env alice bob _foldTxAlice = do
    activesA <- recordsForSpelling env alice
    activesB <- recordsForSpelling env bob
    unless (length activesA == 1 && length activesB == 1) $
        failWith
            ( "final: expected exactly one Active record per folded name, \
               \found "
                <> show (length activesA)
                <> " and "
                <> show (length activesB)
            )
    root <- chainRootHex env
    retainListings env "final"
    case (activesA, activesB) of
        ([a1], [a2]) ->
            emit
                "final"
                ( "registry root "
                    <> root
                    <> " holds Active records "
                    <> showIn a1
                    <> " (alice) and "
                    <> showIn a2
                    <> " (bob), each carrying its representative under 0x"
                    <> envRepHex env
                    <> "; no name holds two"
                )
        _ -> failWith "final: Active record shape changed mid-sweep"
    emit
        "row"
        "final-active-records-present: both folded names Active, no duplicates"

-- ---------------------------------------------------------
-- Ownerless rows: submitted refusals on the same cage (S3)
-- ---------------------------------------------------------

-- | Spend redeemer `End` (constructor 0, no fields).
endRedeemer :: PLC.Data
endRedeemer = PLC.Constr 0 []

-- | Mint redeemer `Burning(tokenId)` for the cage token.
burningRedeemer :: Env -> PLC.Data
burningRedeemer env =
    let TokenId (AssetName sbs) = envTok env
     in PLC.Constr 2 [PLC.Constr 0 [PLC.B (SBS.fromShort sbs)]]

-- | Require a phase-2 refusal naming the operation's script, assert the
-- root did not move, and record the S3 row. Structural checks corroborate;
-- the node's attribution decides (NOTE-011).
requireRefusal ::
    Env ->
    (Value -> IO ()) ->
    String ->
    String ->
    TxIn ->
    String ->
    ConwayTx ->
    ByteString ->
    IO ()
requireRefusal env record rowName operation stateIn rootBefore signed reason = do
    let reasonText = T.unpack (TE.decodeUtf8Lenient reason)
    unless ("PlutusFailure" `isInfixOf` reasonText) $
        failWith (rowName <> ": refused WITHOUT phase-2 validator evidence")
    scriptHex <- refusalScriptHex env operation
    unless (scriptHex `isInfixOf` reasonText) $
        failWith (rowName <> ": refusal does not name " <> scriptHex)
    rootAfter <- chainRootHex env
    unless (rootAfter == rootBefore) $
        failWith (rowName <> ": refused operation moved the chain root")
    retainListings env (rowName <> "-post")
    emit "row" (rowName <> ": refused by " <> scriptHex <> " as " <> txIdHex signed)
    record $
        object
            [ "row" .= (rowName :: String)
            , "operation" .= (operation :: String)
            , "submittedTxId" .= txIdHex signed
            , "outcome" .= ("refused" :: String)
            , "refusedByScript" .= scriptHex
            , "stateInput" .= showIn stateIn
            , "rootBefore" .= rootBefore
            , "rootAfter" .= rootAfter
            , "requiredSigners" .= signerHexes signed
            , "vkeyWitnesses" .= witnessHexes signed
            , "mint" .= mintFacts signed
            ]

-- | The script hash refusing each operation: state policy for
-- end/migration/burning, request policy for sweep.
refusalScriptHex :: Env -> String -> IO String
refusalScriptHex env operation =
    pure
        ( hex
            ( scriptHashBytes
                ( if operation == "sweep"
                    then hashScript (mkRequestScript (envCfg env) (envTok env))
                    else envStateHash env
                )
            )
        )


-- | Ownerless End, both signer variants: spend the state with `End`
-- plus the `-1` burn, no continuation. Neither the folder nor the
-- creator can terminate. Manual transaction (no local evaluation) so
-- the LEDGER attributes the refusal.
runOwnerlessEnd :: Env -> (Value -> IO ()) -> Bool -> IO ()
runOwnerlessEnd env record creatorSigned = do
    let who
            | creatorSigned = "creator-signed"
            | otherwise = "ordinary"
    (stateIn, stateOut) <- queryStateUtxo env
    rootBefore <- chainRootHex env
    let Coin stateCoin = stateOut ^. coinTxOutL
        policyId = cagePolicyIdFromCfg (envCfg env)
        assetName = (\(TokenId an) -> an) (envTok env)
        burnMA =
            MultiAsset $
                Map.singleton policyId (Map.singleton assetName (-1))
    (fund, collateral) <- takeFundCollateral env
    let change =
            changeOut (stateCoin + coinOf fund) flatFee [] (feeChangeAddr creatorSigned)
        redeemers =
            Redeemers $
                Map.fromList
                    [ ( ConwaySpending (AsIx (spendingIndex stateIn (Set.fromList [stateIn, fst fund])))
                      , (Data endRedeemer, maxUnits)
                      )
                    , ( ConwayMinting (AsIx 0)
                      , (Data (burningRedeemer env), maxUnits)
                      )
                    ]
        integrity = computeScriptIntegrity (envPp env) redeemers
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.fromList [stateIn, fst fund]
                & collateralInputsTxBodyL .~ Set.singleton (fst collateral)
                & outputsTxBodyL .~ StrictSeq.fromList [change]
                & feeTxBodyL .~ Coin flatFee
                & mintTxBodyL .~ burnMA
                & reqSignerHashesTxBodyL .~ signerSet
                & scriptIntegrityHashTxBodyL .~ integrity
        tx =
            mkBasicTx body
                & witsTxL . scriptTxWitsL
                    .~ Map.singleton (envStateHash env) (mkCageScript (envCfg env))
                & witsTxL . rdmrsTxWitsL .~ redeemers
        signed = signTx tx
    emit "row" ("ownerless-end-submitted: " <> who <> " End submitted")
    retainListings env ("ownerless-end-" <> who <> "-pre")
    result <- submitRetain env ("ownerless-end-" <> who) signed
    case result of
        Submitted _ ->
            failWith ("ownerless-end: " <> who <> " End ACCEPTED as " <> txIdHex signed)
        Rejected reason ->
            requireRefusal env record "ownerless-end" "end" stateIn rootBefore signed reason
  where
    coinOf (_, o) = let Coin c = o ^. coinTxOutL in c
    feeChangeAddr _ = envPartyAddr env
    signerSet
        | creatorSigned = Set.singleton (addrWitnessKeyHash (envOwnerHash env))
        | otherwise = Set.empty
    signTx
        | creatorSigned = addKeyWitness genesisSignKey . addKeyWitness (mkSignKey partySeed)
        | otherwise = addKeyWitness (mkSignKey partySeed)

-- | Ownerless migration: mint under the state policy presenting the
-- `Migrating` redeemer. Submitted and must be refused.
runOwnerlessMigration :: Env -> (Value -> IO ()) -> IO ()
runOwnerlessMigration env record = do
    (stateIn, _) <- queryStateUtxo env
    rootBefore <- chainRootHex env
    let policyId = cagePolicyIdFromCfg (envCfg env)
        PolicyID policyBytes = policyId
        TokenId assetName = envTok env
        AssetName nameBytes = assetName
        redeemer =
            PLC.Constr
                1
                [ PLC.Constr
                    0
                    [ PLC.B (scriptHashBytes policyBytes)
                    , PLC.Constr 0 [PLC.B (SBS.fromShort nameBytes)]
                    ]
                ]
        mintMA =
            MultiAsset $ Map.singleton policyId (Map.singleton assetName 1)
    (fund, collateral) <- takeFundCollateral env
    let tokenOut = keyOut (envPp env) (envPartyAddr env) claimCoin mintMA
        change = changeOut (coinOf fund) flatFee [tokenOut] (envPartyAddr env)
        redeemers =
            Redeemers $
                Map.singleton
                    (ConwayMinting (AsIx 0))
                    (Data redeemer, maxUnits)
        integrity = computeScriptIntegrity (envPp env) redeemers
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.fromList [fst fund]
                & collateralInputsTxBodyL .~ Set.singleton (fst collateral)
                & outputsTxBodyL .~ StrictSeq.fromList [tokenOut, change]
                & feeTxBodyL .~ Coin flatFee
                & mintTxBodyL .~ mintMA
                & reqSignerHashesTxBodyL .~ Set.empty
                & scriptIntegrityHashTxBodyL .~ integrity
        tx =
            mkBasicTx body
                & witsTxL . scriptTxWitsL
                    .~ Map.singleton (envStateHash env) (mkCageScript (envCfg env))
                & witsTxL . rdmrsTxWitsL .~ redeemers
        signed = addKeyWitness (mkSignKey partySeed) tx
    emit "row" "ownerless-migration-submitted: Migrating mint submitted"
    retainListings env "ownerless-migration-pre"
    result <- submitRetain env "ownerless-migration" signed
    case result of
        Submitted _ ->
            failWith ("ownerless-migration: ACCEPTED as " <> txIdHex signed)
        Rejected reason ->
            requireRefusal env record "ownerless-migration" "migration" stateIn rootBefore signed reason
  where
    coinOf (_, o) = let Coin c = o ^. coinTxOutL in c

-- | Ownerless burning: mint presenting the `Burning` redeemer (arm
-- isolation; the realistic termination shape is closed jointly with the
-- `End` rows). Submitted and must be refused.
runOwnerlessBurning :: Env -> (Value -> IO ()) -> IO ()
runOwnerlessBurning env record = do
    (stateIn, _) <- queryStateUtxo env
    rootBefore <- chainRootHex env
    let policyId = cagePolicyIdFromCfg (envCfg env)
        assetName = (\(TokenId an) -> an) (envTok env)
        mintMA =
            MultiAsset $ Map.singleton policyId (Map.singleton assetName 1)
    (fund, collateral) <- takeFundCollateral env
    let tokenOut = keyOut (envPp env) (envPartyAddr env) claimCoin mintMA
        change = changeOut (coinOf fund) flatFee [tokenOut] (envPartyAddr env)
        redeemers =
            Redeemers $
                Map.singleton
                    (ConwayMinting (AsIx 0))
                    (Data (burningRedeemer env), maxUnits)
        integrity = computeScriptIntegrity (envPp env) redeemers
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.fromList [fst fund]
                & collateralInputsTxBodyL .~ Set.singleton (fst collateral)
                & outputsTxBodyL .~ StrictSeq.fromList [tokenOut, change]
                & feeTxBodyL .~ Coin flatFee
                & mintTxBodyL .~ mintMA
                & reqSignerHashesTxBodyL .~ Set.empty
                & scriptIntegrityHashTxBodyL .~ integrity
        tx =
            mkBasicTx body
                & witsTxL . scriptTxWitsL
                    .~ Map.singleton (envStateHash env) (mkCageScript (envCfg env))
                & witsTxL . rdmrsTxWitsL .~ redeemers
        signed = addKeyWitness (mkSignKey partySeed) tx
    emit "row" "ownerless-burning-submitted: Burning mint submitted"
    retainListings env "ownerless-burning-pre"
    result <- submitRetain env "ownerless-burning" signed
    case result of
        Submitted _ ->
            failWith ("ownerless-burning: ACCEPTED as " <> txIdHex signed)
        Rejected reason ->
            requireRefusal env record "ownerless-burning" "burning" stateIn rootBefore signed reason
  where
    coinOf (_, o) = let Coin c = o ^. coinTxOutL in c

-- | Ownerless Sweep, both signer variants: spend garbage at the request
-- address with a `Sweep` redeemer, the state as reference input.
-- Submitted and must be refused (request validator). Manual transaction
-- (no local evaluation) so the LEDGER attributes the refusal.
runOwnerlessSweep :: Env -> (Value -> IO ()) -> Bool -> IO ()
runOwnerlessSweep env record creatorSigned = do
    let who
            | creatorSigned = "creator-signed"
            | otherwise = "ordinary"
        reqAddr = requestAddrFromCfg (envCfg env) (envTok env) Testnet
    (garbageIn, garbageCoin) <- parkGarbageAt env reqAddr
    (stateIn, _) <- queryStateUtxo env
    rootBefore <- chainRootHex env
    let reqScript = mkRequestScript (envCfg env) (envTok env)
        TxIn (TxId stateTxId) (TxIx stateIx) = stateIn
        sweepRedeemer =
            PLC.Constr
                4
                [ PLC.Constr
                    0
                    [ PLC.B (hashToBytes (extractHash stateTxId))
                    , PLC.I (toInteger stateIx)
                    ]
                ]
    (fund, collateral) <- takeFundCollateral env
    let change = changeOut (coinOf fund + garbageCoin) flatFee [] (envPartyAddr env)
        spendIdx =
            spendingIndex garbageIn (Set.fromList [garbageIn, fst fund])
        redeemers =
            Redeemers $
                Map.singleton
                    (ConwaySpending (AsIx spendIdx))
                    (Data sweepRedeemer, maxUnits)
        integrity = computeScriptIntegrity (envPp env) redeemers
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.fromList [garbageIn, fst fund]
                & referenceInputsTxBodyL .~ Set.singleton stateIn
                & collateralInputsTxBodyL .~ Set.singleton (fst collateral)
                & outputsTxBodyL .~ StrictSeq.fromList [change]
                & feeTxBodyL .~ Coin flatFee
                & reqSignerHashesTxBodyL .~ signerSet
                & scriptIntegrityHashTxBodyL .~ integrity
        tx =
            mkBasicTx body
                & witsTxL . scriptTxWitsL
                    .~ Map.singleton (hashScript reqScript) reqScript
                & witsTxL . rdmrsTxWitsL .~ redeemers
        signed = signTx tx
    emit "row" ("ownerless-sweep-submitted: " <> who <> " Sweep submitted")
    retainListings env ("ownerless-sweep-" <> who <> "-pre")
    result <- submitRetain env ("ownerless-sweep-" <> who) signed
    case result of
        Submitted _ ->
            failWith ("ownerless-sweep: " <> who <> " ACCEPTED as " <> txIdHex signed)
        Rejected reason ->
            requireRefusal env record "ownerless-sweep" "sweep" stateIn rootBefore signed reason
  where
    coinOf (_, o) = let Coin c = o ^. coinTxOutL in c
    signerSet
        | creatorSigned = Set.singleton (addrWitnessKeyHash (envOwnerHash env))
        | otherwise = Set.empty
    signTx
        | creatorSigned = addKeyWitness genesisSignKey . addKeyWitness (mkSignKey partySeed)
        | otherwise = addKeyWitness (mkSignKey partySeed)

-- | Park a datum-less garbage output at an address from the manual pool.
parkGarbageAt :: Env -> Addr -> IO (TxIn, Integer)
parkGarbageAt env addr = do
    (fund, _collateral) <- takeFundCollateral env
    let garbageOut = mkBasicTxOut addr (MaryValue (Coin 2_000_000) mempty)
        change = changeOut (coinOf fund) flatFee [garbageOut] (envPartyAddr env)
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton (fst fund)
                & outputsTxBodyL .~ StrictSeq.fromList [garbageOut, change]
                & feeTxBodyL .~ Coin flatFee
        tx = mkBasicTx body
        signed = addKeyWitness (mkSignKey partySeed) tx
    result <- submitRetain env "park-garbage" signed
    case result of
        Submitted _ -> pure ()
        Rejected reason -> failWith ("park-garbage: refused: " <> show reason)
    let txid = txIdHex signed
    threadDelay 5_000_000
    garbageIn <- mustFindUTxO (envProv env) addr txid "garbage output"
    pure (garbageIn, 2_000_000)
  where
    coinOf (_, o) = let Coin c = o ^. coinTxOutL in c

-- | A plain MPFS request for the supported-action rows (no naming
-- parts): submitted early so it ages into the retract window.
submitSupportRequest :: Env -> (Value -> IO ()) -> ByteString -> ByteString -> IO (TxIn, TxOut ConwayEra)
submitSupportRequest env record spelling value = do
    (reqIn, reqOut) <- submitMPFSRequest env spelling value
    retainListings env ("support-request-" <> show spelling <> "-post")
    record $
        object
            [ "row" .= ("supported-action-control" :: String)
            , "distinctFrom" .= ("ownerless-end" :: String)
            , "submittedTxId" .= txInTxIdHex reqIn
            , "outcome" .= ("accepted" :: String)
            , "requestInput" .= showIn reqIn
            ]
    pure (reqIn, reqOut)

-- | A plain permissionless fold (no naming parts) through the connected
-- builder: the registry still works.
runSupportFold :: Env -> (Value -> IO ()) -> IO ()
runSupportFold env record = do
    (reqIn, reqOut) <- submitMPFSRequest env "support" "support-value"
    (stateIn, stateOut) <- queryStateUtxo env
    feeUtxo <- queryFeeUtxo env
    rootBefore <- chainRootHex env
    (unsigned, newRoot) <-
        connectedFoldTx
            ConnectedFoldArgs
                { cfaCfg = envCfg env
                , cfaProvider = envProv env
                , cfaTrie = envTrie env
                , cfaToken = envTok env
                , cfaFeeAddr = envFolderAddr env
                , cfaStateUtxo = (stateIn, stateOut)
                , cfaReqUtxos = [(reqIn, reqOut)]
                , cfaFeeUtxo = feeUtxo
                , cfaPp = envPp env
                , cfaSpends = []
                , cfaMints = []
                , cfaOutputs = []
                , cfaSigners = []
                , cfaRefUtxos = envRefUtxos env
                , cfaSkipEval = False
                , cfaAttachScripts = []
                , cfaAdjustRoot = id
                }
    let signed = addKeyWitness (mkSignKey folderSeed) unsigned
    assertFoldPermissionless env signed "support"
    retainListings env "support-fold-pre"
    submitAccepted env "support-fold" signed
    let txid = txIdHex signed
    _ <- waitConfirmation (txid <> " (support fold)")
    rootAfter <- chainRootHex env
    retainListings env "support-fold-post"
    unless (rootAfter == hex (unRoot newRoot)) $
        failWith "support fold: chain root is not the computed new root"
    syncFoldedRequests (envTrie env) (envTok env) [(reqIn, reqOut)]
    emit "row" ("support-fold-accepted: " <> txid)
    record $
        object
            [ "row" .= ("supported-action-control" :: String)
            , "distinctFrom" .= ("ownerless-end" :: String)
            , "submittedTxId" .= txid
            , "outcome" .= ("accepted" :: String)
            , "stateInput" .= showIn stateIn
            , "requestInput" .= [showIn reqIn]
            , "rootBefore" .= rootBefore
            , "rootAfter" .= rootAfter
            , "requiredSigners" .= signerHexes signed
            , "vkeyWitnesses" .= witnessHexes signed
            , "mint" .= mintFacts signed
            ]

-- | Retract the aged support request in its phase-2 window.
runSupportRetract :: Env -> (Value -> IO ()) -> (TxIn, TxOut ConwayEra) -> IO ()
runSupportRetract env record (reqIn, reqOut) = do
    submittedAt <- case extractCageDatum reqOut of
        Just (RequestDatum r) -> pure (requestSubmittedAt r)
        _ -> failWith "support retract: request datum does not decode"
    waitForPhase2 submittedAt
    built <- try (retryHorizon 3 (retractRequestImpl (envCfg env) (envProv env) (envTok env) reqIn (envFolderAddr env))) :: IO (Either SomeException ConwayTx)
    unsigned <- case built of
        Right tx -> pure tx
        Left err -> failWith ("support retract build failed: " <> displayException err)
    let signed = addKeyWitness (mkSignKey folderSeed) unsigned
    retainListings env "support-retract-pre"
    result <- submitRetain env "support-retract" signed
    case result of
        Submitted _ -> do
            retainListings env "support-retract-post"
            emit "row" ("support-retract-accepted: " <> txIdHex signed)
            record $
                object
                    [ "row" .= ("supported-action-control" :: String)
                    , "distinctFrom" .= ("ownerless-end" :: String)
                    , "submittedTxId" .= txIdHex signed
                    , "outcome" .= ("accepted" :: String)
                    , "requestInput" .= showIn reqIn
                    , "requiredSigners" .= signerHexes signed
                    , "vkeyWitnesses" .= witnessHexes signed
                    ]
        Rejected reason ->
            failWith ("support retract refused: " <> show reason)

-- | Retry PastHorizon failures only; every other failure propagates.
-- The slot forecast horizon covers a bounded window; a bound computed
-- just past the edge resolves as the tip advances.
retryHorizon :: Int -> IO a -> IO a
retryHorizon n act = do
    outcome <- try act
    case outcome of
        Right x -> pure x
        Left e ->
            if n > (0 :: Int) && "PastHorizon" `isInfixOf` displayException (e :: SomeException)
                then emit "retry" "slot forecast horizon not yet covering a bound; retrying" >> threadDelay 2_000_000 >> retryHorizon (n - 1) act
                else throwIO e

-- | Sleep until the request's phase-2 window opens.
waitForPhase2 :: Integer -> IO ()
waitForPhase2 submittedAt = do
    now <- currentPosixMs
    let target = submittedAt + 120_000 + 5_000
    when (now < target) $ do
        emit "wait" "sleeping into the retract window"
        threadDelay (fromIntegral (target - now) * 1000)

-- | Hex facts from a submitted transaction for report rows.
signerHexes :: ConwayTx -> [String]
signerHexes signed =
    [ hex (hashToBytes (unKeyHash kh))
    | kh <- Set.toList (signed ^. bodyTxL . reqSignerHashesTxBodyL)
    ]

witnessHexes :: ConwayTx -> [String]
witnessHexes signed =
    [ hex (hashToBytes (unKeyHash (witVKeyHash w)))
    | w <- Set.toList (signed ^. witsTxL . addrTxWitsL)
    ]

mintFacts :: ConwayTx -> [Value]
mintFacts signed =
    let MultiAsset ma = signed ^. bodyTxL . mintTxBodyL
     in [ object ["policy" .= hex (scriptHashBytes h), "quantity" .= q]
        | (PolicyID h, names) <- Map.toList ma
        , (_, q) <- Map.toList names
        ]

-- | The chain-read state datum as a checkable object (no owner field exists).
stateDatumObject :: Env -> IO Value
stateDatumObject env = do
    (_, stateOut) <- queryStateUtxo env
    case extractCageDatum stateOut of
        Just (StateDatum st) ->
            let OnChainRoot bs = stateRoot st
             in pure $
                    object
                        [ "root" .= hex bs
                        , "tip" .= stateMaxFee st
                        , "processTime" .= stateProcessTime st
                        , "retractTime" .= stateRetractTime st
                        ]
        _ -> failWith "the state UTxO carries no state datum"

-- ---------------------------------------------------------
-- NOTE-001 assertion path
-- ---------------------------------------------------------

-- | The submitted fold's own authorization carries no registry-owner
-- signer: required signers are empty and every slice input is funded by
-- the ordinary party pool.
assertFoldPermissionless :: Env -> ConwayTx -> String -> IO ()
assertFoldPermissionless _env signed label = do
    let signers = signed ^. bodyTxL . reqSignerHashesTxBodyL
    unless (Set.null signers) $
        failWith
            ( label
                <> ": the Active-creating fold carries required signers "
                <> show signers
                <> " — the permissionless fold carries none"
            )
    emit
        "fold-permissionless"
        ( "the Active-creating fold for "
            <> label
            <> " carries no registry owner signer: required signers empty, \
               \fee drawn from the ordinary folder wallet; submitted \
               \permissionless by a party with no privileged relationship \
               \to the registry"
        )

-- | The fold's mint field carries the APPLIED representative policy —
-- derived from the exact application-policy parameter — with the
-- expected asset name at exactly +1. The unapplied manifest pin is
-- recorded separately and is never accepted here.
assertRepMintedByFold :: Env -> ConwayTx -> ByteString -> String -> String -> IO ()
assertRepMintedByFold env signed repName txid label = do
    let MultiAsset mintMap = signed ^. bodyTxL . mintTxBodyL
        repQty =
            Map.lookup (envRepPolicy env) mintMap
                >>= Map.lookup (AssetName (SBS.toShort repName))
    case repQty of
        Just 1 ->
            emit
                "representative-minted-by-fold"
                ( "fold "
                    <> txid
                    <> " mints 0x"
                    <> hex repName
                    <> " at +1 under the applied representative policy 0x"
                    <> envRepHex env
                    <> " (parameter: application-policy hash 0x"
                    <> envAppHex env
                    <> ")"
                )
        other ->
            failWith
                ( label
                    <> ": the fold "
                    <> txid
                    <> " does not mint the representative under the applied \
                       \policy 0x"
                    <> envRepHex env
                    <> " — observed "
                    <> show other
                    <> " for 0x"
                    <> hex repName
                )

-- | The vkey witnesses of the submitted transaction name no owner: the
-- only witness is the ordinary party's fee key.
assertOwnerAbsentWitnesses :: Env -> ConwayTx -> String -> String -> IO ()
assertOwnerAbsentWitnesses env signed txid label = do
    let wits = Set.map witVKeyHash (signed ^. witsTxL . addrTxWitsL)
        owner = coerce (addrWitnessKeyHash (envOwnerHash env))
    when (owner `Set.member` wits) $
        failWith
            ( label
                <> ": the fold "
                <> txid
                <> " is witnessed by the registry owner 0x"
                <> hex (envOwnerHash env)
                <> " — the permissionless fold must not be"
            )
    emit
        "owner-absent"
        ( "fold "
            <> txid
            <> " witnesses name no registry owner; folding and funding \
               \actor is the ordinary folder 0x"
            <> hex (envFolderHash env)
            <> ", distinct from the owner 0x"
            <> hex (envOwnerHash env)
        )

-- | Slice transactions other than the fold: the owner is absent from
-- required signers.
assertOwnerAbsentTx :: Env -> ConwayTx -> String -> IO ()
assertOwnerAbsentTx env signed label = do
    let signers = signed ^. bodyTxL . reqSignerHashesTxBodyL
        owner = addrWitnessKeyHash (envOwnerHash env)
    when (owner `Set.member` signers) $
        failWith
            ( label
                <> ": the registry owner signs a slice transaction — \
                   \ordinary parties only"
            )

-- ---------------------------------------------------------
-- Negative rows: every new naming check refuses on its reason
-- (naming-validator scope; refused folds never reach the registry)
-- ---------------------------------------------------------

rowMintBadName :: Env -> IO ()
rowMintBadName env = do
    let badName = BS.map complement (insertApprovalName (serialiseAddr (envPartyAddr env)) (nextControlCommitmentOf (serialiseAddr (envPartyAddr env))))
        badMA =
            MultiAsset $
                Map.singleton
                    (envAppPolicy env)
                    (Map.singleton (AssetName (SBS.toShort badName)) 1)
    (fund, collateral) <- takeFundCollateral env
    let badOut = keyOut (envPp env) (envPartyAddr env) claimCoin badMA
        change = changeOut (coinOf fund) flatFee [badOut] (envPartyAddr env)
        redeemers =
            Redeemers $
                Map.singleton
                    (ConwayMinting (AsIx 0))
                    ( Data
                        ( insertApprovalRedeemer
                            (envPartyHash env)
                            (serialiseAddr (envPartyAddr env))
                            (nextControlCommitmentOf (serialiseAddr (envPartyAddr env)))
                        )
                    , maxUnits
                    )
        integrity = computeScriptIntegrity (envPp env) redeemers
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.fromList [fst fund]
                & collateralInputsTxBodyL .~ Set.singleton (fst collateral)
                & outputsTxBodyL .~ StrictSeq.fromList [badOut, change]
                & feeTxBodyL .~ Coin flatFee
                & mintTxBodyL .~ badMA
                & reqSignerHashesTxBodyL
                    .~ Set.singleton (addrWitnessKeyHash (envPartyHash env))
                & scriptIntegrityHashTxBodyL .~ integrity
        tx =
            mkBasicTx body
                & witsTxL . scriptTxWitsL
                    .~ Map.singleton (envAppHash env) (envAppScript env)
                & witsTxL . rdmrsTxWitsL .~ redeemers
        signed = addKeyWitness (mkSignKey partySeed) tx
    expectRefused
        MainRun
        env
        "insert-approval-name-mismatch-refused"
        "insert-binding"
        "an insert approval whose name is not the bound proposal hash"
        signed
  where
    coinOf (_, o) = let Coin c = o ^. coinTxOutL in c

rowMintNoSigner :: Env -> IO ()
rowMintNoSigner env = do
    let control = serialiseAddr (envPartyAddr env)
        commitment = nextControlCommitmentOf control
        approval = insertApprovalName control commitment
        approvalMA =
            MultiAsset $
                Map.singleton
                    (envAppPolicy env)
                    (Map.singleton (AssetName (SBS.toShort approval)) 1)
    (fund, collateral) <- takeFundCollateral env
    let goodOut = keyOut (envPp env) (envPartyAddr env) claimCoin approvalMA
        change = changeOut (coinOf fund) flatFee [goodOut] (envPartyAddr env)
        redeemers =
            Redeemers $
                Map.singleton
                    (ConwayMinting (AsIx 0))
                    ( Data
                        (insertApprovalRedeemer (envPartyHash env) control commitment)
                    , maxUnits
                    )
        integrity = computeScriptIntegrity (envPp env) redeemers
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.fromList [fst fund]
                & collateralInputsTxBodyL .~ Set.singleton (fst collateral)
                & outputsTxBodyL .~ StrictSeq.fromList [goodOut, change]
                & feeTxBodyL .~ Coin flatFee
                & mintTxBodyL .~ approvalMA
                & reqSignerHashesTxBodyL .~ Set.empty
                & scriptIntegrityHashTxBodyL .~ integrity
        tx =
            mkBasicTx body
                & witsTxL . scriptTxWitsL
                    .~ Map.singleton (envAppHash env) (envAppScript env)
                & witsTxL . rdmrsTxWitsL .~ redeemers
        signed = addKeyWitness (mkSignKey partySeed) tx
    expectRefused
        MainRun
        env
        "insert-approval-without-controller-refused"
        "application-approval"
        "the bound approval with no controller signer"
        signed
  where
    coinOf (_, o) = let Coin c = o ^. coinTxOutL in c

rowFoldTamperedRep :: Env -> KeySetup -> TxIn -> IO ()
rowFoldTamperedRep env ks claimIn = do
    snapClaim <- mustSnap env claimIn
    let tampered = BS.map complement (keyRepName ks)
        approval = insertApprovalName (keyControlBytes ks) (keyCommitment ks)
        tamperedMintMA =
            MultiAsset $
                Map.singleton
                    (envRepPolicy env)
                    (Map.singleton (AssetName (SBS.toShort tampered)) 1)
        burnMA =
            MultiAsset $
                Map.singleton
                    (envAppPolicy env)
                    (Map.singleton (AssetName (SBS.toShort approval)) (-1))
        mintMA = burnMA <> tamperedMintMA
    (fund, collateral) <- takeFundCollateral env
    let recordOut =
            scriptOut
                (envPp env)
                (envAppAddr env)
                (snapCoin snapClaim)
                tamperedMintMA
                (keyDatum ks)
        change =
            changeOut
                (snapCoin snapClaim + coinOf fund)
                flatFee
                [recordOut]
                (envPartyAddr env)
        spendIdx = spendingIndex claimIn (Set.fromList [claimIn, fst fund])
        redeemers =
            Redeemers $
                Map.fromList
                    [
                        ( ConwaySpending (AsIx spendIdx)
                        , (Data (foldRedeemer [tampered]), maxUnits)
                        )
                    ,
                        ( ConwayMinting (AsIx (mintIndexOf mintMA (envAppPolicy env)))
                        , ( Data
                                ( insertApprovalRedeemer
                                    (keyControllerHash ks)
                                    (keyControlBytes ks)
                                    (keyCommitment ks)
                                )
                          , maxUnits
                          )
                        )
                    ,
                        ( ConwayMinting (AsIx (mintIndexOf mintMA (envRepPolicy env)))
                        , (Data mintRepresentativeRedeemer, maxUnits)
                        )
                    ]
        integrity = computeScriptIntegrity (envPp env) redeemers
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.fromList [claimIn, fst fund]
                & collateralInputsTxBodyL .~ Set.singleton (fst collateral)
                & outputsTxBodyL .~ StrictSeq.fromList [recordOut, change]
                & feeTxBodyL .~ Coin flatFee
                & mintTxBodyL .~ mintMA
                & reqSignerHashesTxBodyL .~ Set.empty
                & scriptIntegrityHashTxBodyL .~ integrity
        tx =
            mkBasicTx body
                & witsTxL . scriptTxWitsL
                    .~ Map.fromList
                        [ (envAppHash env, envAppScript env)
                        , (envRepHash env, envRepScript env)
                        ]
                & witsTxL . rdmrsTxWitsL .~ redeemers
        signed = addKeyWitness (mkSignKey partySeed) tx
    expectRefused
        MainRun
        env
        "fold-misnamed-representative-refused"
        "representative-identity"
        "the fold names a representative the record control does not determine"
        signed
    noTrace env snapClaim "fold-misnamed-representative"
  where
    coinOf (_, o) = let Coin c = o ^. coinTxOutL in c

rowFoldMissingRep :: Env -> KeySetup -> TxIn -> IO ()
rowFoldMissingRep env ks claimIn = do
    snapClaim <- mustSnap env claimIn
    let repName = keyRepName ks
        approval = insertApprovalName (keyControlBytes ks) (keyCommitment ks)
        repMintMA =
            MultiAsset $
                Map.singleton
                    (envRepPolicy env)
                    (Map.singleton (AssetName (SBS.toShort repName)) 1)
        burnMA =
            MultiAsset $
                Map.singleton
                    (envAppPolicy env)
                    (Map.singleton (AssetName (SBS.toShort approval)) (-1))
        mintMA = burnMA <> repMintMA
    (fund, collateral) <- takeFundCollateral env
    let recordOut =
            scriptOut
                (envPp env)
                (envAppAddr env)
                (snapCoin snapClaim)
                mempty
                (keyDatum ks)
        strayOut = keyOut (envPp env) (envPartyAddr env) claimCoin repMintMA
        change =
            changeOut
                (snapCoin snapClaim + coinOf fund)
                flatFee
                [recordOut, strayOut]
                (envPartyAddr env)
        spendIdx = spendingIndex claimIn (Set.fromList [claimIn, fst fund])
        redeemers =
            Redeemers $
                Map.fromList
                    [
                        ( ConwaySpending (AsIx spendIdx)
                        , (Data (foldRedeemer [repName]), maxUnits)
                        )
                    ,
                        ( ConwayMinting (AsIx (mintIndexOf mintMA (envAppPolicy env)))
                        , ( Data
                                ( insertApprovalRedeemer
                                    (keyControllerHash ks)
                                    (keyControlBytes ks)
                                    (keyCommitment ks)
                                )
                          , maxUnits
                          )
                        )
                    ,
                        ( ConwayMinting (AsIx (mintIndexOf mintMA (envRepPolicy env)))
                        , (Data mintRepresentativeRedeemer, maxUnits)
                        )
                    ]
        integrity = computeScriptIntegrity (envPp env) redeemers
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.fromList [claimIn, fst fund]
                & collateralInputsTxBodyL .~ Set.singleton (fst collateral)
                & outputsTxBodyL .~ StrictSeq.fromList [recordOut, strayOut, change]
                & feeTxBodyL .~ Coin flatFee
                & mintTxBodyL .~ mintMA
                & reqSignerHashesTxBodyL .~ Set.empty
                & scriptIntegrityHashTxBodyL .~ integrity
        tx =
            mkBasicTx body
                & witsTxL . scriptTxWitsL
                    .~ Map.fromList
                        [ (envAppHash env, envAppScript env)
                        , (envRepHash env, envRepScript env)
                        ]
                & witsTxL . rdmrsTxWitsL .~ redeemers
        signed = addKeyWitness (mkSignKey partySeed) tx
    expectRefused
        MainRun
        env
        "fold-missing-record-representative-refused"
        "certified-output"
        "the minted representative never reaches the record"
        signed
    noTrace env snapClaim "fold-missing-record-representative"
  where
    coinOf (_, o) = let Coin c = o ^. coinTxOutL in c

rowFoldEmptyReps :: Env -> KeySetup -> TxIn -> IO ()
rowFoldEmptyReps env ks claimIn = do
    snapClaim <- mustSnap env claimIn
    let approval = insertApprovalName (keyControlBytes ks) (keyCommitment ks)
        burnMA =
            MultiAsset $
                Map.singleton
                    (envAppPolicy env)
                    (Map.singleton (AssetName (SBS.toShort approval)) (-1))
    (fund, collateral) <- takeFundCollateral env
    let recordOut =
            scriptOut
                (envPp env)
                (envAppAddr env)
                (snapCoin snapClaim)
                mempty
                (keyDatum ks)
        change =
            changeOut
                (snapCoin snapClaim + coinOf fund)
                flatFee
                [recordOut]
                (envPartyAddr env)
        spendIdx = spendingIndex claimIn (Set.fromList [claimIn, fst fund])
        redeemers =
            Redeemers $
                Map.fromList
                    [
                        ( ConwaySpending (AsIx spendIdx)
                        , (Data (foldRedeemer []), maxUnits)
                        )
                    ,
                        ( ConwayMinting (AsIx 0)
                        , ( Data
                                ( insertApprovalRedeemer
                                    (keyControllerHash ks)
                                    (keyControlBytes ks)
                                    (keyCommitment ks)
                                )
                          , maxUnits
                          )
                        )
                    ]
        integrity = computeScriptIntegrity (envPp env) redeemers
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.fromList [claimIn, fst fund]
                & collateralInputsTxBodyL .~ Set.singleton (fst collateral)
                & outputsTxBodyL .~ StrictSeq.fromList [recordOut, change]
                & feeTxBodyL .~ Coin flatFee
                & mintTxBodyL .~ burnMA
                & reqSignerHashesTxBodyL .~ Set.empty
                & scriptIntegrityHashTxBodyL .~ integrity
        tx =
            mkBasicTx body
                & witsTxL . scriptTxWitsL
                    .~ Map.singleton (envAppHash env) (envAppScript env)
                & witsTxL . rdmrsTxWitsL .~ redeemers
        signed = addKeyWitness (mkSignKey partySeed) tx
    expectRefused
        MainRun
        env
        "fold-empty-with-insert-approval-refused"
        "withdraw-tag"
        "an insert approval consumed by the empty-representatives fold"
        signed
    noTrace env snapClaim "fold-empty-with-insert-approval"
  where
    coinOf (_, o) = let Coin c = o ^. coinTxOutL in c

-- | A withdraw-approval claim for the tamper key: canonical-named
-- approval minted controller-signed, queued at the validator.
createWithdrawClaim :: Env -> KeySetup -> IO String
createWithdrawClaim env ks = do
    let destination = serialiseAddr (envSecondAddr env)
        approvalMA =
            MultiAsset $
                Map.singleton
                    (envAppPolicy env)
                    (Map.singleton (AssetName (SBS.toShort destination)) 1)
    (fund, collateral) <- takeFundCollateral env
    let claimOut =
            scriptOut
                (envPp env)
                (envAppAddr env)
                claimCoin
                approvalMA
                (keyDatum ks)
        change = changeOut (coinOf fund) flatFee [claimOut] (envPartyAddr env)
        redeemers =
            Redeemers $
                Map.singleton
                    (ConwayMinting (AsIx 0))
                    ( Data
                        ( withdrawApprovalRedeemer
                            (keyControllerHash ks)
                            destination
                        )
                    , maxUnits
                    )
        integrity = computeScriptIntegrity (envPp env) redeemers
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.fromList [fst fund]
                & collateralInputsTxBodyL .~ Set.singleton (fst collateral)
                & outputsTxBodyL .~ StrictSeq.fromList [claimOut, change]
                & feeTxBodyL .~ Coin flatFee
                & mintTxBodyL .~ approvalMA
                & reqSignerHashesTxBodyL
                    .~ Set.singleton
                        (addrWitnessKeyHash (keyControllerHash ks))
                & scriptIntegrityHashTxBodyL .~ integrity
        tx =
            mkBasicTx body
                & witsTxL . scriptTxWitsL
                    .~ Map.singleton (envAppHash env) (envAppScript env)
                & witsTxL . rdmrsTxWitsL .~ redeemers
        signed =
            addKeyWitness
                (mkSignKey (keyControllerSeed ks))
                (addKeyWitness (mkSignKey partySeed) tx)
    submitAccepted env (keyLabel ks <> "-withdraw-claim") signed
    let txid = txIdHex signed
    _ <- waitConfirmation (txid <> " (" <> keyLabel ks <> " withdraw claim)")
    pure txid
  where
    coinOf (_, o) = let Coin c = o ^. coinTxOutL in c

rowFoldWithdrawApproval :: Env -> KeySetup -> TxIn -> IO ()
rowFoldWithdrawApproval env ks claimIn = do
    snapClaim <- mustSnap env claimIn
    let destination = serialiseAddr (envSecondAddr env)
        repName = keyRepName ks
        repMintMA =
            MultiAsset $
                Map.singleton
                    (envRepPolicy env)
                    (Map.singleton (AssetName (SBS.toShort repName)) 1)
        burnMA =
            MultiAsset $
                Map.singleton
                    (envAppPolicy env)
                    (Map.singleton (AssetName (SBS.toShort destination)) (-1))
        mintMA = burnMA <> repMintMA
    (fund, collateral) <- takeFundCollateral env
    let recordOut =
            scriptOut
                (envPp env)
                (envAppAddr env)
                (snapCoin snapClaim)
                repMintMA
                (keyDatum ks)
        change =
            changeOut
                (snapCoin snapClaim + coinOf fund)
                flatFee
                [recordOut]
                (envPartyAddr env)
        spendIdx = spendingIndex claimIn (Set.fromList [claimIn, fst fund])
        redeemers =
            Redeemers $
                Map.fromList
                    [
                        ( ConwaySpending (AsIx spendIdx)
                        , (Data (foldRedeemer [repName]), maxUnits)
                        )
                    ,
                        ( ConwayMinting (AsIx (mintIndexOf mintMA (envAppPolicy env)))
                        , ( Data
                                ( withdrawApprovalRedeemer
                                    (keyControllerHash ks)
                                    destination
                                )
                          , maxUnits
                          )
                        )
                    ,
                        ( ConwayMinting (AsIx (mintIndexOf mintMA (envRepPolicy env)))
                        , (Data mintRepresentativeRedeemer, maxUnits)
                        )
                    ]
        integrity = computeScriptIntegrity (envPp env) redeemers
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.fromList [claimIn, fst fund]
                & collateralInputsTxBodyL .~ Set.singleton (fst collateral)
                & outputsTxBodyL .~ StrictSeq.fromList [recordOut, change]
                & feeTxBodyL .~ Coin flatFee
                & mintTxBodyL .~ mintMA
                & reqSignerHashesTxBodyL .~ Set.empty
                & scriptIntegrityHashTxBodyL .~ integrity
        tx =
            mkBasicTx body
                & witsTxL . scriptTxWitsL
                    .~ Map.fromList
                        [ (envAppHash env, envAppScript env)
                        , (envRepHash env, envRepScript env)
                        ]
                & witsTxL . rdmrsTxWitsL .~ redeemers
        signed = addKeyWitness (mkSignKey partySeed) tx
    expectRefused
        MainRun
        env
        "fold-withdraw-approval-as-insert-refused"
        "insert-binding"
        "a withdraw approval consumed by an insert fold"
        signed
    noTrace env snapClaim "fold-withdraw-approval-as-insert"
  where
    coinOf (_, o) = let Coin c = o ^. coinTxOutL in c

-- ---------------------------------------------------------
-- Controls
-- ---------------------------------------------------------

runControlValid :: Env -> IO ()
runControlValid env = do
    -- A genuine refusal first, proving the runner ran.
    rowMintBadName env
    -- Then the same mint made actually valid: it succeeds, so the
    -- refusal guard must fail the run.
    let control = serialiseAddr (envPartyAddr env)
        commitment = nextControlCommitmentOf control
        approval = insertApprovalName control commitment
        approvalMA =
            MultiAsset $
                Map.singleton
                    (envAppPolicy env)
                    (Map.singleton (AssetName (SBS.toShort approval)) 1)
    (fund, collateral) <- takeFundCollateral env
    let goodOut = keyOut (envPp env) (envPartyAddr env) claimCoin approvalMA
        change = changeOut (coinOf fund) flatFee [goodOut] (envPartyAddr env)
        redeemers =
            Redeemers $
                Map.singleton
                    (ConwayMinting (AsIx 0))
                    ( Data
                        (insertApprovalRedeemer (envPartyHash env) control commitment)
                    , maxUnits
                    )
        integrity = computeScriptIntegrity (envPp env) redeemers
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.fromList [fst fund]
                & collateralInputsTxBodyL .~ Set.singleton (fst collateral)
                & outputsTxBodyL .~ StrictSeq.fromList [goodOut, change]
                & feeTxBodyL .~ Coin flatFee
                & mintTxBodyL .~ approvalMA
                & reqSignerHashesTxBodyL
                    .~ Set.singleton (addrWitnessKeyHash (envPartyHash env))
                & scriptIntegrityHashTxBodyL .~ integrity
        tx =
            mkBasicTx body
                & witsTxL . scriptTxWitsL
                    .~ Map.singleton (envAppHash env) (envAppScript env)
                & witsTxL . rdmrsTxWitsL .~ redeemers
        signed = addKeyWitness (mkSignKey partySeed) tx
    result <- submitRetain env "control-valid-mint" signed
    case result of
        Submitted _ -> do
            emit
                "row"
                "insert-approval-name-mismatch-refused: CONTROL \
                \valid-transaction succeeded as constructed — failing the \
                \run as required"
            failWith
                "CONTROL valid-transaction: the corrected mint SUCCEEDED — \
                \the guard did not refuse, so this run fails as the control \
                \requires"
        Rejected reason ->
            failWith
                ( "CONTROL valid-transaction: the corrected mint was \
                  \unexpectedly refused: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )
  where
    coinOf (_, o) = let Coin c = o ^. coinTxOutL in c

runControlWrongReason :: Env -> IO ()
runControlWrongReason env = do
    -- An accept first, proving the runner ran.
    alice <- setupKey env "alice" aliceSpelling (envPartyCodec env) (envPartyAddr env) (envPartyHash env) partySeed nextSeed
    (_txid, _claimIn, _claimOut) <- setupNamingClaim env alice
    emit
        "row"
        "wrong-reason-setup: insert request queued (the runner ran)"
    -- Then a refusal matched against an impossible marker.
    let control = serialiseAddr (envPartyAddr env)
        commitment = nextControlCommitmentOf control
        badName = BS.map complement (insertApprovalName control commitment)
        badMA =
            MultiAsset $
                Map.singleton
                    (envAppPolicy env)
                    (Map.singleton (AssetName (SBS.toShort badName)) 1)
    (fund, collateral) <- takeFundCollateral env
    let badOut = keyOut (envPp env) (envPartyAddr env) claimCoin badMA
        change = changeOut (coinOf fund) flatFee [badOut] (envPartyAddr env)
        redeemers =
            Redeemers $
                Map.singleton
                    (ConwayMinting (AsIx 0))
                    ( Data (insertApprovalRedeemer (envPartyHash env) control commitment)
                    , maxUnits
                    )
        integrity = computeScriptIntegrity (envPp env) redeemers
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.fromList [fst fund]
                & collateralInputsTxBodyL .~ Set.singleton (fst collateral)
                & outputsTxBodyL .~ StrictSeq.fromList [badOut, change]
                & feeTxBodyL .~ Coin flatFee
                & mintTxBodyL .~ badMA
                & reqSignerHashesTxBodyL
                    .~ Set.singleton (addrWitnessKeyHash (envPartyHash env))
                & scriptIntegrityHashTxBodyL .~ integrity
        tx =
            mkBasicTx body
                & witsTxL . scriptTxWitsL
                    .~ Map.singleton (envAppHash env) (envAppScript env)
                & witsTxL . rdmrsTxWitsL .~ redeemers
        signed = addKeyWitness (mkSignKey partySeed) tx
    expectRefused
        ControlWrongReason
        env
        "insert-approval-name-mismatch-refused"
        "insert-binding"
        "wrong-reason control: this matcher must fail"
        signed
    failWith "CONTROL wrong-reason: the impossible marker unexpectedly matched"
  where
    coinOf (_, o) = let Coin c = o ^. coinTxOutL in c

-- ---------------------------------------------------------
-- Fault controls (NOTE-001): same wording, one wrong observation
-- ---------------------------------------------------------

-- | The fold mints under a tampered representative policy. The ledger
-- itself refuses — the tampered script cannot find the application
-- spend under its tampered credential — naming the tampered hash; the
-- red log carries the expected applied identity alongside.
runFaultRepPolicy :: Env -> IO ()
runFaultRepPolicy env = do
    alice <- setupKey env "alice" aliceSpelling (envPartyCodec env) (envPartyAddr env) (envPartyHash env) partySeed nextSeed
    (_claimTx, claimIn, claimOut) <- setupNamingClaim env alice
    snapClaim <- mustSnap env claimIn
    (reqIn, reqOut) <- submitMPFSRequest env (keySpelling alice) (keyRepName alice)
    (stateIn, stateOut) <- queryStateUtxo env
    feeUtxo <- queryFeeUtxo env
    let tamperedParam = BS.map complement (scriptHashBytes (envAppHash env))
        tamperedBytes = applyBytesParam tamperedParam (envRepUnapplied env)
        tamperedScript = scriptFromBytes "tampered-representative" tamperedBytes
        tamperedPolicy = PolicyID (computeScriptHash tamperedBytes)
        tamperedHex = hex (scriptHashBytes (computeScriptHash tamperedBytes))
        repName = keyRepName alice
        approval = insertApprovalName (keyControlBytes alice) (keyCommitment alice)
        recordTokens =
            MultiAsset $
                Map.singleton
                    tamperedPolicy
                    (Map.singleton (AssetName (SBS.toShort repName)) 1)
        recordOut =
            scriptOut
                (envPp env)
                (envAppAddr env)
                (snapCoin snapClaim)
                recordTokens
                (keyDatum alice)
    emit
        "fault"
        ( "submitting the alice fold under the tampered representative \
           \policy; expected applied 0x"
            <> envRepHex env
        )
    (unsigned, _newRoot) <-
        connectedFoldTx
            ConnectedFoldArgs
                { cfaCfg = envCfg env
                , cfaProvider = envProv env
                , cfaTrie = envTrie env
                , cfaToken = envTok env
                , cfaFeeAddr = envFolderAddr env
                , cfaStateUtxo = (stateIn, stateOut)
                , cfaReqUtxos = [(reqIn, reqOut)]
                , cfaFeeUtxo = feeUtxo
                , cfaPp = envPp env
                , cfaSpends =
                    [ ConnectedSpend
                        { csUtxo = (claimIn, claimOut)
                        , csRedeemer = RawRedeemer (foldRedeemer [repName])
                        , csScript = envAppScript env
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
                                    (keyControllerHash alice)
                                    (keyControlBytes alice)
                                    (keyCommitment alice)
                                )
                        , cmScript = envAppScript env
                        }
                    , ConnectedMint
                        { cmPolicy = tamperedPolicy
                        , cmAssets =
                            Map.singleton
                                (AssetName (SBS.toShort repName))
                                1
                        , cmRedeemer = RawRedeemer mintRepresentativeRedeemer
                        , cmScript = tamperedScript
                        }
                    ]
                , cfaOutputs = [recordOut]
                , cfaSigners = []
                , cfaSkipEval = True
                , cfaAttachScripts = [tamperedScript]
                , cfaRefUtxos = envRefUtxos env
                , cfaAdjustRoot = id
                }
    let signed = addKeyWitness (mkSignKey folderSeed) unsigned
        txid = txIdHex signed
    result <- submitRetain env "fault-rep-policy-fold" signed
    case result of
        Submitted _ ->
            failWith
                ( "FAULT fault-rep-policy: the fold under the tampered \
                   \policy was ACCEPTED as "
                    <> txid
                    <> " — expected applied 0x"
                    <> envRepHex env
                )
        Rejected reason -> do
            let reasonText = T.unpack (TE.decodeUtf8Lenient reason)
            unless (tamperedHex `isInfixOf` reasonText) $
                failWith
                    ( "FAULT fault-rep-policy: the refusal does not name \
                       \the tampered policy "
                        <> tamperedHex
                        <> ": <"
                        <> reasonText
                        <> ">"
                    )
            emit
                "row"
                ( "fault-rep-policy-observed: the tampered-policy fold \
                   \refused as it must; expected applied representative \
                   \policy 0x"
                    <> envRepHex env
                    <> "; node reason names the tampered identity"
                )
            failWith
                ( "FAULT fault-rep-policy: wrong representative policy \
                   \observed — expected applied 0x"
                    <> envRepHex env
                    <> " but the fold minted under the tampered identity 0x"
                    <> tamperedHex
                )

-- | The fold carries the registry-owner signer and witness. The
-- no-owner assertion must fail naming the owner.
runFaultOwnerSigned :: Env -> IO ()
runFaultOwnerSigned env = do
    alice <- setupKey env "alice" aliceSpelling (envPartyCodec env) (envPartyAddr env) (envPartyHash env) partySeed nextSeed
    (_claimTx, claimIn, claimOut) <- setupNamingClaim env alice
    snapClaim <- mustSnap env claimIn
    (reqIn, reqOut) <- submitMPFSRequest env (keySpelling alice) (keyRepName alice)
    (stateIn, stateOut) <- queryStateUtxo env
    feeUtxo <- queryFeeUtxo env
    let repName = keyRepName alice
        approval = insertApprovalName (keyControlBytes alice) (keyCommitment alice)
        recordTokens =
            MultiAsset $
                Map.singleton
                    (envRepPolicy env)
                    (Map.singleton (AssetName (SBS.toShort repName)) 1)
        recordOut =
            scriptOut
                (envPp env)
                (envAppAddr env)
                (snapCoin snapClaim)
                recordTokens
                (keyDatum alice)
    (unsigned, _newRoot) <-
        connectedFoldTx
            ConnectedFoldArgs
                { cfaCfg = envCfg env
                , cfaProvider = envProv env
                , cfaTrie = envTrie env
                , cfaToken = envTok env
                , cfaFeeAddr = envFolderAddr env
                , cfaStateUtxo = (stateIn, stateOut)
                , cfaReqUtxos = [(reqIn, reqOut)]
                , cfaFeeUtxo = feeUtxo
                , cfaPp = envPp env
                , cfaSpends =
                    [ ConnectedSpend
                        { csUtxo = (claimIn, claimOut)
                        , csRedeemer = RawRedeemer (foldRedeemer [repName])
                        , csScript = envAppScript env
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
                                    (keyControllerHash alice)
                                    (keyControlBytes alice)
                                    (keyCommitment alice)
                                )
                        , cmScript = envAppScript env
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
                , cfaSigners = [addrWitnessKeyHash (envOwnerHash env)]
                , cfaSkipEval = False
                , cfaAttachScripts = []
                , cfaRefUtxos = envRefUtxos env
                , cfaAdjustRoot = id
                }
    let signed =
            addKeyWitness genesisSignKey (addKeyWitness (mkSignKey folderSeed) unsigned)
    -- Same assertion as the genuine path: it must fail naming the owner.
    assertFoldPermissionless env signed "alice"
    failWith
        "FAULT fault-owner-signed: the owner-signed fold passed the \
        \no-owner assertion — it must not have"

-- | The Active entry is seeded directly — a former-shaped stand-in
-- minted under the application policy and placed at the validator with
-- no state spend, no request and no Fold. The connection assertion must
-- fail naming the disconnection.
runFaultSeededActive :: Env -> IO ()
runFaultSeededActive env = do
    alice <- setupKey env "alice" aliceSpelling (envPartyCodec env) (envPartyAddr env) (envPartyHash env) partySeed nextSeed
    let decoy = serialiseAddr (envPartyAddr env)
        decoyMA =
            MultiAsset $
                Map.singleton
                    (envAppPolicy env)
                    (Map.singleton (AssetName (SBS.toShort decoy)) 1)
    (fund, collateral) <- takeFundCollateral env
    let seededOut =
            scriptOut
                (envPp env)
                (envAppAddr env)
                claimCoin
                decoyMA
                (keyDatum alice)
        change = changeOut (coinOf fund) flatFee [seededOut] (envPartyAddr env)
        redeemers =
            Redeemers $
                Map.singleton
                    (ConwayMinting (AsIx 0))
                    ( Data
                        ( withdrawApprovalRedeemer
                            (envPartyHash env)
                            decoy
                        )
                    , maxUnits
                    )
        integrity = computeScriptIntegrity (envPp env) redeemers
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.fromList [fst fund]
                & collateralInputsTxBodyL .~ Set.singleton (fst collateral)
                & outputsTxBodyL .~ StrictSeq.fromList [seededOut, change]
                & feeTxBodyL .~ Coin flatFee
                & mintTxBodyL .~ decoyMA
                & reqSignerHashesTxBodyL
                    .~ Set.singleton (addrWitnessKeyHash (envPartyHash env))
                & scriptIntegrityHashTxBodyL .~ integrity
        tx =
            mkBasicTx body
                & witsTxL . scriptTxWitsL
                    .~ Map.singleton (envAppHash env) (envAppScript env)
                & witsTxL . rdmrsTxWitsL .~ redeemers
        signed = addKeyWitness (mkSignKey partySeed) tx
    submitAccepted env "fault-seeded-placement" signed
    let txid = txIdHex signed
    _ <- waitConfirmation (txid <> " (fault seeded placement)")
    emit
        "row"
        ( "fault-seeded-observed: placement "
            <> txid
            <> " carries no state spend, no request and no Fold"
        )
    rootAfter <- chainRootHex env
    rootBefore <- chainRootHex env
    let MultiAsset mintMap = signed ^. bodyTxL . mintTxBodyL
        repQty =
            Map.lookup (envRepPolicy env) mintMap
                >>= Map.lookup (AssetName (SBS.toShort (keyRepName alice)))
        Redeemers rdmrs = signed ^. witsTxL . rdmrsTxWitsL
        purposes = Map.keys rdmrs
    case (repQty, rootBefore == rootAfter) of
        (Just 1, False) ->
            failWith
                "FAULT fault-seeded-active: the seeded placement looks \
                \connected — it must not"
        _ ->
            failWith
                ( "FAULT fault-seeded-active: seeded Active result is \
                   \disconnected from any fold — placement "
                    <> txid
                    <> " has no state Modify or request Contribute purpose \
                       \(purposes: "
                    <> show (length purposes)
                    <> "), representative under the applied policy 0x"
                    <> envRepHex env
                    <> " observed "
                    <> show repQty
                    <> " (the entry carries a former-shaped stand-in under \
                       \the application policy instead), registry root \
                       \unmoved at "
                    <> rootAfter
                )
  where
    coinOf (_, o) = let Coin c = o ^. coinTxOutL in c

-- ---------------------------------------------------------
-- Faucet and funding pool (ordinary-party funds only)
-- ---------------------------------------------------------

-- | Fund the two ordinary wallets once, on disjoint addresses so the
-- manually-tracked pool (party) and the largest-first cage funding
-- (folder) can never select the same input: equal-value splits make
-- largest-first meaningless within one address.
faucetParty :: Cage.Provider IO -> Submitter IO -> FilePath -> IORef Int -> IO [(TxIn, TxOut ConwayEra)]
faucetParty prov submit evDir evNext = do
    let partyAddr =
            enterpriseAddr (keyHashFromSignKey (mkSignKey partySeed))
        folderAddr =
            enterpriseAddr (keyHashFromSignKey (mkSignKey folderSeed))
    utxos <- Cage.queryUTxOs prov genesisAddr
    (bigIn, bigOut) <- case sortOn (Down . (^. coinTxOutL) . snd) utxos of
        [] -> failWith "faucet: the genesis wallet has no UTxOs"
        (b : _) -> pure b
    let Coin total = bigOut ^. coinTxOutL
        change =
            total
                - faucetSplits * faucetPerSplit
                - folderSplits * folderPerSplit
                - 1_000_000
    unless (change > 1_000_000) $
        failWith "faucet: the genesis wallet cannot fund the splits"
    let partyOuts =
            [ mkBasicTxOut partyAddr (MaryValue (Coin faucetPerSplit) mempty)
            | _ <- [1 .. faucetSplits]
            ]
        folderOuts =
            [ mkBasicTxOut folderAddr (MaryValue (Coin folderPerSplit) mempty)
            | _ <- [1 .. folderSplits]
            ]
        changeOutTx =
            mkBasicTxOut genesisAddr (MaryValue (Coin change) mempty)
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton bigIn
                & outputsTxBodyL
                    .~ StrictSeq.fromList (partyOuts <> folderOuts <> [changeOutTx])
                & feeTxBodyL .~ Coin 1_000_000
        faucetTx = mkBasicTx body
    result <- submitRetainAt evDir evNext submit "faucet" (addKeyWitness genesisSignKey faucetTx)
    case result of
        Submitted _ -> pure ()
        Rejected reason ->
            failWith
                ("faucet: refused: " <> T.unpack (TE.decodeUtf8Lenient reason))
    threadDelay 5_000_000
    after <- Cage.queryUTxOs prov partyAddr
    afterFolder <- Cage.queryUTxOs prov folderAddr
    let txid = txIdHex faucetTx
        mine =
            [ (i, o)
            | (i, o) <- after
            , txInTxIdHex i == txid
            , txInIndex i < faucetSplits
            ]
        mineFolder =
            [ (i, o)
            | (i, o) <- afterFolder
            , txInTxIdHex i == txid
            ]
    unless (toInteger (length mine) == faucetSplits) $
        failWith
            ( "faucet: expected "
                <> show faucetSplits
                <> " party UTxOs, found "
                <> show (length mine)
            )
    unless (toInteger (length mineFolder) == folderSplits) $
        failWith
            ( "faucet: expected "
                <> show folderSplits
                <> " folder UTxOs, found "
                <> show (length mineFolder)
            )
    emit
        "faucet"
        ( "registry owner funded the ordinary wallets once: "
            <> show faucetSplits
            <> " manual UTxOs at the party address and "
            <> show folderSplits
            <> " cage UTxOs at the folder address (disjoint funding)"
        )
    pure (sortBy (comparing (txInIndex . fst)) mine)

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

-- | Publish scripts once as reference outputs at a key address, so
-- connected folds resolve every purpose through reference inputs
-- instead of witnessing four scripts (which would breach max tx size).
-- Returns the four reference UTxOs in script order.
publishScripts ::
    Cage.Provider IO ->
    Submitter IO ->
    PParams ConwayEra ->
    IORef [(TxIn, TxOut ConwayEra)] ->
    [Script ConwayEra] ->
    Addr ->
    FilePath ->
    IORef Int ->
    IO [(TxIn, TxOut ConwayEra)]
publishScripts prov submit pp poolRef scripts addr evDir evNext = do
    -- Batches of two: all four scripts in one transaction would breach
    -- max tx size, which is why they are published at all.
    concat <$> mapM (\batch -> publishBatch prov submit pp poolRef addr batch evDir evNext) (batches scripts)
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
    FilePath ->
    IORef Int ->
    IO [(TxIn, TxOut ConwayEra)]
publishBatch prov submit pp poolRef addr scripts evDir evNext = do
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
            mkBasicTxOut addr (MaryValue (Coin changeCoin) mempty)
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton (fst fund)
                & outputsTxBodyL .~ StrictSeq.fromList (outs <> [changeOutTx])
                & feeTxBodyL .~ Coin 1_000_000
        tx = mkBasicTx body
    result <- submitRetainAt evDir evNext submit "publish-scripts" (addKeyWitness (mkSignKey partySeed) tx)
    case result of
        Submitted _ -> pure ()
        Rejected reason ->
            failWith ("publish: refused: " <> show reason)
    let txid = txIdHex tx
    threadDelay 5_000_000
    after <- Cage.queryUTxOs prov addr
    let mine =
            sortBy
                (comparing (txInIndex . fst))
                (utxosByTxId after txid)
    unless (length mine >= length scripts) $
        failWith "publish: script outputs not found"
    emit
        "scripts"
        ( "published "
            <> show (length scripts)
            <> " scripts as reference outputs in "
            <> txid
        )
    pure (take (length scripts) mine)

-- ---------------------------------------------------------
-- Transaction builders (naming half)
-- ---------------------------------------------------------

scriptOut ::
    PParams ConwayEra ->
    Addr ->
    Integer ->
    MultiAsset ->
    NamingDatum ->
    TxOut ConwayEra
scriptOut pp addr coin tokens datum =
    let probe :: TxOut ConwayEra
        probe = mkBasicTxOut addr (MaryValue (Coin 0) tokens)
        minCoin = let Coin c = getMinCoinTxOut pp probe in c
        finalCoin = max coin (minCoin + 1_000_000)
     in mkBasicTxOut
            addr
            (MaryValue (Coin finalCoin) tokens)
            & datumTxOutL .~ mkInlineDatum (namingDataToData datum)

keyOut ::
    PParams ConwayEra ->
    Addr ->
    Integer ->
    MultiAsset ->
    TxOut ConwayEra
keyOut pp addr coin tokens =
    let probe :: TxOut ConwayEra
        probe = mkBasicTxOut addr (MaryValue (Coin 0) tokens)
        minCoin = let Coin c = getMinCoinTxOut pp probe in c
        finalCoin = max coin (minCoin + 1_000_000)
     in mkBasicTxOut addr (MaryValue (Coin finalCoin) tokens)

changeOut :: Integer -> Integer -> [TxOut ConwayEra] -> Addr -> TxOut ConwayEra
changeOut inCoin fee outs addr =
    let spent = sum [c | o <- outs, let Coin c = o ^. coinTxOutL]
        change = inCoin - fee - spent
     in if change <= 1_000_000
            then error "register-rows: change underflow while balancing"
            else mkBasicTxOut addr (MaryValue (Coin change) mempty)

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
    destinationData (SomeDestination a) =
        PLC.Constr 1 [PLC.B (addressBytes a)]
    quorumData q =
        PLC.Constr
            0
            [ PLC.I (quorumThreshold q)
            , PLC.List (map PLC.B (quorumMembers q))
            ]

-- | Spend redeemer @Fold { representatives }@ — index 2.
foldRedeemer :: [ByteString] -> PLC.Data
foldRedeemer reps = PLC.Constr 2 [PLC.List (map PLC.B reps)]

-- | Mint redeemer @InsertApproval { controller, control, commitment }@.
insertApprovalRedeemer :: ByteString -> ByteString -> ByteString -> PLC.Data
insertApprovalRedeemer controller control commitment =
    PLC.Constr 1 [PLC.B controller, PLC.B control, PLC.B commitment]

-- | Mint redeemer @WithdrawApproval { controller, destination }@.
withdrawApprovalRedeemer :: ByteString -> ByteString -> PLC.Data
withdrawApprovalRedeemer controller destination =
    PLC.Constr 0 [PLC.B controller, PLC.B destination]

-- | Mint redeemer @MintRepresentative@.
mintRepresentativeRedeemer :: PLC.Data
mintRepresentativeRedeemer = PLC.Constr 0 []

mintIndexOf :: MultiAsset -> PolicyID -> Word32
mintIndexOf (MultiAsset ma) pid =
    fromIntegral (length [p | p <- Map.keys ma, p < pid])

-- ---------------------------------------------------------
-- Chain reading
-- ---------------------------------------------------------

data Snap = Snap
    { snapIn :: TxIn
    , snapCoin :: Integer
    , snapTokens :: Map.Map (PolicyID, AssetName) Integer
    , snapDatum :: Maybe PLC.Data
    }

extractSnap :: (TxIn, TxOut ConwayEra) -> Snap
extractSnap (i, o) =
    let Coin c = o ^. coinTxOutL
        triples = case o ^. valueTxOutL of
            MaryValue _ (MultiAsset ma) ->
                [ ((p, n), q)
                | (p, names) <- Map.toList ma
                , (n, q) <- Map.toList names
                ]
     in Snap i c (Map.fromList triples) (datumDataOf o)

mustSnap :: Env -> TxIn -> IO Snap
mustSnap env txin = do
    utxos <- Cage.queryUTxOs (envProv env) (envAppAddr env)
    case filter ((== txin) . fst) utxos of
        [utxo] -> pure (extractSnap utxo)
        _ ->
            failWith
                ( "snapshot: "
                    <> showIn txin
                    <> " is not live at the application validator"
                )

lookupToken :: Snap -> PolicyID -> ByteString -> Maybe Integer
lookupToken snap policy name =
    Map.lookup (policy, AssetName (SBS.toShort name)) (snapTokens snap)

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
                    <> " is live at the address"
                )

mustOutAt :: Cage.Provider IO -> Addr -> TxIn -> IO (TxOut ConwayEra)
mustOutAt prov addr txin = do
    utxos <- Cage.queryUTxOs prov addr
    case filter ((== txin) . fst) utxos of
        [(_, o)] -> pure o
        _ -> failWith ("output " <> showIn txin <> " is not live")

isLiveAt :: Cage.Provider IO -> Addr -> TxIn -> IO Bool
isLiveAt prov addr txin = do
    utxos <- Cage.queryUTxOs prov addr
    pure (any ((== txin) . fst) utxos)

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
    | otherwise = Nothing
wireOf (PLC.B b) = Just (WBytes b)
wireOf (PLC.I n) = Just (WInt n)
wireOf (PLC.List xs) = WList <$> traverse wireOf xs
wireOf _ = Nothing

chainDatumOf :: Snap -> String -> IO NamingDatum
chainDatumOf snap label =
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
            <> " still live with datum bytes unchanged"
        )

-- ---------------------------------------------------------
-- Submission helpers
-- ---------------------------------------------------------

submitAccepted :: Env -> String -> ConwayTx -> IO ()
submitAccepted env label signed =
    submitRetain env label signed >>= \case
        Submitted _ ->
            emit "submit" (label <> ": accepted tx=" <> txIdHex signed)
        Rejected reason ->
            failWith
                ( label
                    <> ": the node refused an accepting row: "
                    <> T.unpack (TE.decodeUtf8Lenient reason)
                )

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
    result <- submitRetain env rowName signed
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

waitConfirmation :: String -> IO ()
waitConfirmation what = do
    threadDelay 5_000_000
    emit "confirm" ("confirmed on chain: " <> what)

-- ---------------------------------------------------------
-- Pinned identity
-- ---------------------------------------------------------

data ManifestPin = ManifestPin
    { pinTitle :: T.Text
    , pinHash :: T.Text
    }

instance FromJSON ManifestPin where
    parseJSON = withObject "ManifestPin" $ \o ->
        ManifestPin <$> o .: "title" <*> o .: "hash"

data NamingIdentity = NamingIdentity
    { niValidators :: [ManifestPin]
    }

instance FromJSON NamingIdentity where
    parseJSON = withObject "NamingIdentity" $ \o ->
        NamingIdentity <$> o .: "validators"

pinsUnder :: NamingIdentity -> T.Text -> [T.Text]
pinsUnder ni prefix =
    [ pinHash p | p <- niValidators ni, prefix `T.isPrefixOf` pinTitle p ]

readIdentityManifest :: FilePath -> IO NamingIdentity
readIdentityManifest path = do
    bytes <- BS.readFile path
    either failWith pure (eitherDecode' (BSL.fromStrict bytes))

checkPinnedNamingApplication :: String -> IO ()
checkPinnedNamingApplication appHex = do
    path <-
        fromMaybe "../naming-onchain/script-identity.json"
            <$> lookupEnv "NAMING_SCRIPT_IDENTITY"
    manifest <- readIdentityManifest path
    let pins = pinsUnder manifest "application.application"
    unless (length pins >= 3) $
        failWith "identity: fewer than three application.application pins"
    unless (all (== T.pack appHex) pins) $
        failWith
            ( "identity: the naming manifest pins "
                <> show pins
                <> " but this run's blueprint hashes to 0x"
                <> appHex
            )

checkPinnedRepresentative :: String -> IO ()
checkPinnedRepresentative unappliedHex = do
    path <-
        fromMaybe "../naming-onchain/script-identity.json"
            <$> lookupEnv "NAMING_SCRIPT_IDENTITY"
    manifest <- readIdentityManifest path
    let pins = pinsUnder manifest "representative.representative.mint"
    unless (length pins >= 1) $
        failWith "identity: no representative.representative.mint pin"
    unless (all (== T.pack unappliedHex) pins) $
        failWith
            ( "identity: the naming manifest pins unapplied representative \
               \hash(es) "
                <> show pins
                <> " but this run's blueprint code hashes to 0x"
                <> unappliedHex
            )

checkPinnedMpfsState :: String -> IO ()
checkPinnedMpfsState unappliedHex = do
    path <-
        fromMaybe "../onchain/script-identity.json"
            <$> lookupEnv "MPFS_SCRIPT_IDENTITY"
    manifest <- readIdentityManifest path
    let pins = pinsUnder manifest "state.state"
    unless (length pins >= 1) $
        failWith "identity: no state.state pin in the MPFS manifest"
    unless (all (== T.pack unappliedHex) pins) $
        failWith
            ( "identity: the MPFS manifest pins unapplied state hash(es) "
                <> show pins
                <> " but this run's blueprint code hashes to 0x"
                <> unappliedHex
            )

-- ---------------------------------------------------------
-- Receipt
-- ---------------------------------------------------------

-- ---------------------------------------------------------
-- Raw evidence (S3 verifier contract)
-- ---------------------------------------------------------

-- | CBOR version for evidence serialization. Runner and verifier share
-- the identical pinned stack; the txid self-check (recomputed ==
-- submitted) validates the choice empirically on every run.
evidenceVersion :: Version
evidenceVersion = maxBound

serializeTxHex :: ConwayTx -> String
serializeTxHex tx = hex (serialize' evidenceVersion tx)

serializeTxOutHex :: TxOut ConwayEra -> String
serializeTxOutHex out = hex (serialize' evidenceVersion out)

-- | Gate-owned evidence location wins when set (`S3_EVIDENCE`, the only
-- acceptance path); the smoke override is second; TMPDIR last.
evidenceDirFromEnv :: IO FilePath
evidenceDirFromEnv = do
    gateOwned <- lookupEnv "S3_EVIDENCE"
    smokeOverride <- lookupEnv "S77_EVIDENCE_DIR"
    case (gateOwned, smokeOverride) of
        (Just dir, _) -> pure dir
        (Nothing, Just dir) -> pure dir
        (Nothing, Nothing) -> do
            tmpdir <- fromMaybe "/tmp" <$> lookupEnv "TMPDIR"
            pure (tmpdir ++ "/register-evidence")

writeEvidenceMeta ::
    FilePath -> String -> Bool -> FilePath -> FilePath -> String -> String -> String -> IO ()
writeEvidenceMeta evDir candidate dirty namingBp mpfsBp appH repH stateH =
    BSL.writeFile
        (evDir </> "meta.json")
        ( Aeson.encode $
            object
                [ "candidate" .= candidate
                , "worktreeDirty" .= dirty
                , "namingBlueprint" .= namingBp
                , "mpfsBlueprint" .= mpfsBp
                , "applicationPolicy" .= appH
                , "representativeAppliedPolicy" .= repH
                , "stateScriptHash" .= stateH
                ]
        )

-- | Candidate revision, derived not told: an explicit override wins for
-- smoke runs, else the invocation repository's HEAD. A revision that
-- cannot be established fails the run closed — never "unknown".
candidateFromRepo :: IO (String, Bool)
candidateFromRepo = do
    override <- lookupEnv "CANDIDATE_SHA"
    headOut <- try (readProcess "git" ["rev-parse", "HEAD"] "") :: IO (Either SomeException String)
    statusOut <- try (readProcess "git" ["status", "--porcelain"] "") :: IO (Either SomeException String)
    let dirty = case statusOut of
            Right status -> not (null (filter (/= '\n') status))
            Left _ -> True
    case (override, headOut) of
        (Just sha, _) -> pure (sha, dirty)
        (Nothing, Right sha) -> pure (filter (/= '\n') sha, dirty)
        (Nothing, Left err) -> failWith ("candidate: cannot establish repository revision: " <> displayException err)

-- | Retain the signed transaction bytes. Returns the tag.
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

-- | Retain the submission outcome.
retainOutcomeAt :: FilePath -> String -> SubmitResult -> ConwayTx -> IO ()
retainOutcomeAt evDir tag result signed =
    BSL.writeFile
        (evDir </> ("tx-" <> tag <> ".outcome.json"))
        ( Aeson.encode $ case result of
            Submitted _ ->
                object
                    [ "outcome" .= ("accepted" :: String)
                    , "txid" .= txIdHex signed
                    ]
            Rejected reason ->
                object
                    [ "outcome" .= ("refused" :: String)
                    , "reason" .= T.unpack (TE.decodeUtf8Lenient reason)
                    ]
        )

retainOutcome :: Env -> String -> SubmitResult -> ConwayTx -> IO ()
retainOutcome env = retainOutcomeAt (envEvDir env)

-- | Retain full address listings (every UTxO at the three script
-- addresses with canonical bytes) under a tag.
retainListings :: Env -> String -> IO ()
retainListings env tag = do
    let addrs =
            [ (envAppAddr env, "app")
            , (requestAddrFromCfg (envCfg env) (envTok env) Testnet, "request")
            , (cageAddrFromCfg (envCfg env) Testnet, "state")
            ]
    saved <- mapM (saveOneListing env tag) addrs
    BSL.writeFile
        (envEvDir env </> ("listings-" <> tag <> ".json"))
        (Aeson.encode (object saved))
  where
    saveOneListing e _t (addr, which) = do
        utxos <- Cage.queryUTxOs (envProv e) addr
        pure
            ( Key.fromString which,
              Aeson.toJSON
                [ object
                    [ "outref" .= showIn i
                    , "txout_cbor" .= serializeTxOutHex o
                    ]
                | (i, o) <- sortOn fst utxos
                ]
            )

-- | Submit, retaining body bytes and outcome. Returns the submission
-- result. Listings are retained explicitly at key transitions.
submitRetain :: Env -> String -> ConwayTx -> IO SubmitResult
submitRetain env label signed = do
    tag <- retainTx env label signed
    result <- submitTx (envSubmit env) signed
    retainOutcome env tag result signed
    pure result

submitRetainAt ::
    FilePath -> IORef Int -> Submitter IO -> String -> ConwayTx -> IO SubmitResult
submitRetainAt evDir evNext submit label signed = do
    tag <- retainTxAt evDir evNext label signed
    result <- submitTx submit signed
    retainOutcomeAt evDir tag result signed
    pure result

recordRow :: IORef [Value] -> Value -> IO ()
recordRow ref row = modifyIORef' ref (row :)

-- ---------------------------------------------------------
-- Shared plumbing
-- ---------------------------------------------------------

adaptProvider :: N2C.Provider IO -> Cage.Provider IO
adaptProvider p =
    Cage.Provider
        { Cage.queryUTxOs = N2C.queryUTxOs p
        , Cage.queryProtocolParams = N2C.queryProtocolParams p
        , Cage.evaluateTx = N2C.evaluateTx p
        , Cage.posixMsToSlot = N2C.posixMsToSlot p
        , Cage.posixMsCeilSlot = N2C.posixMsCeilSlot p
        }

verifyConnection :: Async (Either e ()) -> IO ()
verifyConnection nodeThread =
    poll nodeThread >>= \case
        Just (Left err) ->
            failWith ("node connection failed: " <> show err)
        Just (Right (Right ())) ->
            failWith "node connection closed unexpectedly"
        Just _ -> failWith "node connection error"
        Nothing -> pure ()

nextControlCommitmentOf :: ByteString -> ByteString
nextControlCommitmentOf addressBytes0 =
    convert
        ( hash
            ( "singular/naming/next-control/v1"
                <> BS.singleton 0x00
                <> addressBytes0
            )
            :: Digest Blake2b_256
        )

-- ---------------------------------------------------------
-- Narration helpers
-- ---------------------------------------------------------

emit :: String -> String -> IO ()
emit stepName detail = putStrLn ("[register] " <> stepName <> ": " <> detail)

failWith :: String -> IO a
failWith msg = throwIO (ErrorCall ("register-rows: " <> msg))

requireEnv :: String -> IO String
requireEnv name =
    lookupEnv name
        >>= maybe
            (failWith ("missing environment variable " <> name))
            pure

hex :: ByteString -> String
hex = T.unpack . TE.decodeUtf8 . Base16.encode

txIdHex :: ConwayTx -> String
txIdHex tx = let TxId h = txIdTx tx in hex (hashToBytes (extractHash h))

txInTxIdHex :: TxIn -> String
txInTxIdHex (TxIn (TxId h) _) = hex (hashToBytes (extractHash h))

txInIndex :: TxIn -> Integer
txInIndex (TxIn _ (TxIx i)) = toInteger i

showIn :: TxIn -> String
showIn (TxIn (TxId h) (TxIx i)) =
    hex (hashToBytes (extractHash h)) <> "#" <> show i
