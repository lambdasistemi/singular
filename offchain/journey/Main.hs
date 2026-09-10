{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Main
Description : The bounded MPFS cage journey, verified against a real devnet
License     : Apache-2.0

One command that runs the bounded journey against a real devnet
node and verifies it, one line per step:

  boot a cage, submit a request, prove the key absent, apply
  the request, prove the key present with the expected value,
  reject a false claim, read the resulting state back, then
  submit three transactions the on-chain validators must
  refuse — a forged state-token identity, a tampered
  certified output, a missing required witness — and prove
  the authenticated state took no trace from them.

The three negative cases are MPFS cage negative cases. They
exercise the imported validators' identity, certified-output
and ownership guards; no Singular naming behaviour exists in
this runner.

Verification follows D-013: the library builds proofs
('mkMPFExclusionProof', 'mkMPFInclusionProof'); off-chain each
proof is folded to the root it implies and that root is compared
against the root read back from the chain's state datum — never
against a root this runner derived from the same trie.

This is the vehicle for Singular's naming claim, not the claim:
nothing this runner prints describes a name as claimed, registered
or maintained. It exercises the MPFS cage protocol only.

It uses the same code path as the E2E suite — 'bootTokenImpl',
'requestInsertImpl', 'updateTokenImpl' and a real node-to-client
connection to a real 'cardano-node' spawned as a subprocess. No
mocks, no stubbed node.

At start it prints the upstream source revision and the pinned
validator hashes read from @onchain/script-identity.json@. Those
pins are the /unapplied/ blueprint identities — the stable,
reviewable scripts issue #34 enforces — not the hashes a
transaction carries: the on-chain scripts are parameterized (the
state validator takes 1 parameter, the request validator 2), so
applying the parameters changes the hash. The run therefore also
reports the /applied/ hashes it actually used, with their
parameters named, and asserts the derivation between the two
layers (marker @derived-applied-identity@): each applied hash
must equal the hash of the unapplied blueprint code with this
instance's parameters applied, or the run fails naming both
hashes and the parameters.
-}
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async, cancel, poll)
import Control.Exception
    ( ErrorCall (..)
    , SomeException
    , catch
    , displayException
    , throwIO
    )
import Control.Monad (unless, when)
import Data.Aeson (FromJSON (..), eitherDecode', withObject, (.:))
import Data.Bits (complement)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short (fromShort)
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.IORef (IORef, newIORef, readIORef)
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((&), (%~), (.~), (^.))
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Scripts.Data (Data (..))
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body (
    mintTxBodyL,
    outputsTxBodyL,
    reqSignerHashesTxBodyL,
    scriptIntegrityHashTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (datumTxOutL)
import Cardano.Ledger.Api.Tx.Wits (
    Redeemers (..),
    rdmrsTxWitsL,
    scriptTxWitsL,
 )
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Mary.Value (MultiAsset (..))
import PlutusTx.IsData.Class (FromData (..))

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
    PParams,
    Root (..),
    TokenId (..),
 )
import Cardano.MPFS.Cage.Provider qualified as Cage
import Cardano.MPFS.Cage.Trie qualified as CageTrie
import Cardano.MPFS.Cage.Trie (TrieManager (..))
import Cardano.MPFS.Cage.Trie.Pure (mkPureTrieFromRef)
import Cardano.MPFS.Cage.Trie.PureManager (mkPureTrieManager)
import Cardano.MPFS.Cage.TxBuilder.Boot (bootTokenImpl)
import Cardano.MPFS.Cage.TxBuilder.Internal (
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    computeScriptHash,
    computeScriptIntegrity,
    extractCageDatum,
    findStateUtxo,
    mkInlineDatum,
    onChainTokenId,
    requestAddrFromCfg,
    scriptHashBytes,
    toLedgerData,
    toPlcData,
    txInToRef,
 )
import Cardano.MPFS.Cage.TxBuilder.Request (requestInsertImpl)
import Cardano.MPFS.Cage.TxBuilder.Update (updateTokenImpl)
import Cardano.MPFS.Cage.Types (
    CageDatum (..),
    OnChainRoot (..),
    OnChainTokenState (..),
    OnChainTxOutRef,
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
import MPF.Backend.Pure (
    MPFInMemoryDB,
    emptyMPFInMemoryDB,
    runMPFPure,
    runMPFPureTransaction,
 )
import MPF.Backend.Standalone (
    MPFStandalone (..),
    MPFStandaloneCodecs (..),
 )
import MPF.Hashes (
    MPFHash,
    isoMPFHash,
    mkMPFHash,
    mpfHashing,
    parseMPFHash,
    renderMPFHash,
 )
import MPF.Interface (
    FromHexKV (..),
    HexKey,
    byteStringToHexKey,
    hexKeyPrism,
 )
import MPF.Proof.Exclusion (
    MPFExclusionProof,
    foldMPFExclusionProof,
    mkMPFExclusionProof,
    verifyMPFExclusionProof,
 )
import MPF.Proof.Insertion (
    MPFProof (..),
    foldMPFProof,
    mkMPFInclusionProof,
 )
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
import Cardano.Node.Client.Provider qualified as N2C
import Cardano.Node.Client.Submitter (SubmitResult (..), Submitter (..))
import Cardano.Tx.Ledger (ConwayTx)
import Ouroboros.Network.Magic (NetworkMagic (..))
import PlutusTx.Builtins.Internal (BuiltinByteString (..), BuiltinData (..))

-- ---------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------

main :: IO ()
main = journey `catch` \(e :: SomeException) -> do
    hPutStrLn stderr ("journey: FAILED: " <> displayException e)
    exitWith (ExitFailure 1)

journey :: IO ()
journey = do
    blueprintPath <- requireEnv "MPFS_BLUEPRINT"
    identityPath <- identityPathFromEnv
    si <- readScriptIdentity identityPath
    printIdentity si
    ebp <- loadBlueprint blueprintPath
    bp <- either failWith pure ebp
    case
        ( extractCompiledCode "state.state" bp
        , extractCompiledCode "request.request" bp
        , extractCompiledCode "staking.staking" bp
        ) of
        (Just stateBytes, Just requestBytes, Just stakingBytes) ->
            runJourney si stateBytes requestBytes stakingBytes
        _ ->
            failWith
                "state.state, request.request or staking.staking \
                \compiled code not found in blueprint"

-- ---------------------------------------------------------
-- Identity: which contracts this run exercises
-- ---------------------------------------------------------

-- | Default location of the pinned-identity manifest, relative
-- to @offchain/@ (where the flake app and the CI job run it).
defaultIdentityPath :: FilePath
defaultIdentityPath = "../onchain/script-identity.json"

identityPathFromEnv :: IO FilePath
identityPathFromEnv =
    lookupEnv "MPFS_SCRIPT_IDENTITY"
        >>= maybe (pure defaultIdentityPath) pure

{- | The pinned identities in @onchain\/script-identity.json@:
the upstream source revision, each validator's parameter
count, and the compiled validator hashes the repository
pins. Those pins are the /unapplied/ blueprint scripts —
the stable, reviewable identity — not the hashes the
transactions of a particular instance carry.
-}
data ScriptIdentity = ScriptIdentity
    { siRevision :: Text
    , siValidators :: [ValidatorPin]
    }

data ValidatorPin = ValidatorPin
    { vpTitle :: Text
    -- ^ Validator title, e.g. @state.state.spend@
    , vpHash :: Text
    -- ^ Unapplied compiled script hash pinned in the manifest
    , vpParameters :: Int
    -- ^ How many parameters the on-chain instance applies
    }

instance FromJSON ValidatorPin where
    parseJSON = withObject "ValidatorPin" $ \o ->
        ValidatorPin
            <$> o .: "title"
            <*> o .: "hash"
            <*> o .: "parameters"

instance FromJSON ScriptIdentity where
    parseJSON = withObject "ScriptIdentity" $ \o ->
        ScriptIdentity
            <$> (o .: "upstream" >>= (.: "source_revision"))
            <*> o .: "validators"

readScriptIdentity :: FilePath -> IO ScriptIdentity
readScriptIdentity path = do
    bytes <- BS.readFile path
    either failWith pure (eitherDecode' (BSL.fromStrict bytes))

printIdentity :: ScriptIdentity -> IO ()
printIdentity si = do
    emit
        "identity"
        ("upstream source revision " <> T.unpack (siRevision si))
    mapM_ one (siValidators si)
  where
    one v =
        emit
            "identity"
            ( "pinned unapplied validator "
                <> T.unpack (vpTitle v)
                <> " hash 0x"
                <> T.unpack (vpHash v)
                <> " (parameters="
                <> show (vpParameters v)
                <> ")"
            )

{- | Assert the derivation between the two identity layers
(marker @derived-applied-identity@).

The manifest pins the /unapplied/ blueprint scripts. The
scripts that run on chain are parameterized: the state
validator takes 1 parameter (@previousPolicies@, @[]@ for
this genesis cage), the request validator takes 2
(@statePolicyId@, @cageToken@), and the staking validator
takes none, so its two layers coincide. This step

  * requires each pinned unapplied hash to be the hash of
    the blueprint's raw code, so the pinned layer is what
    this run's blueprint actually contains;

  * applies this instance's parameters to the unapplied
    code, hashes the result, and requires it to equal the
    hash of the script the run actually carried to the
    node: the boot transaction's witness holds exactly the
    derived state script, the update transaction's witness
    exactly the derived state and request scripts.

Any mismatch fails the run naming both hashes and the
parameters used — the relationship between the layers is a
check, not an assumption.
-}
stepDerivedIdentity ::
    ScriptIdentity ->
    CageConfig ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    TokenId ->
    ConwayTx ->
    ConwayTx ->
    IO ()
stepDerivedIdentity si cfg rawState rawRequest rawStaking tid bootTx updateTx = do
    let hashHex = hex . scriptHashBytes
        -- The unapplied layer: the blueprint's raw code hashes.
        unappliedState = hashHex (computeScriptHash rawState)
        unappliedRequest = hashHex (computeScriptHash rawRequest)
        unappliedStaking = hashHex (computeScriptHash rawStaking)
    -- The pinned layer is the unapplied code this run's
    -- blueprint actually contains.
    checkPinnedUnapplied si "state.state" unappliedState
    checkPinnedUnapplied si "request.request" unappliedRequest
    checkPinnedUnapplied si "staking.staking" unappliedStaking
    -- Derivation: apply this instance's parameters to the
    -- unapplied code and hash the result.
    let stateHash = computeScriptHash (applyPreviousPolicies [] rawState)
        stateHex = hashHex stateHash
        stateParams = "previousPolicies=[]"
        tokenName = let TokenId (AssetName an) = tid in fromShort an
        requestHash =
            computeScriptHash $
                applyRequestParams
                    (scriptHashBytes stateHash)
                    (onChainTokenId tid)
                    rawRequest
        requestHex = hashHex requestHash
        requestParams =
            "statePolicyId=0x"
                <> stateHex
                <> " cageToken=0x"
                <> hex tokenName
    -- The run's config follows from the same derivation.
    unless (cfgScriptHash cfg == stateHash) $
        failWith $
            "derived-applied-identity failed for state: \
            \derived applied hash 0x"
                <> stateHex
                <> " (parameters "
                <> stateParams
                <> ") but the run's state policy hash is 0x"
                <> hashHex (cfgScriptHash cfg)
    -- The scripts the run actually carried to the node.
    let bootWitness = witnessScriptHashes bootTx
        updateWitness = witnessScriptHashes updateTx
    unless (bootWitness == Set.singleton stateHex) $
        failWith $
            "derived-applied-identity failed for state: \
            \expected the boot transaction to carry exactly \
            \the derived applied hash 0x"
                <> stateHex
                <> " (parameters "
                <> stateParams
                <> ") but its script witness held "
                <> show (Set.toList bootWitness)
    unless (updateWitness == Set.fromList [stateHex, requestHex]) $
        failWith $
            "derived-applied-identity failed for request: \
            \expected the update transaction to carry exactly \
            \the derived applied hashes 0x"
                <> stateHex
                <> " and 0x"
                <> requestHex
                <> " (request parameters "
                <> requestParams
                <> ") but its script witness held "
                <> show (Set.toList updateWitness)
    emit
        "derived-applied-identity"
        ( "state applied hash 0x"
            <> stateHex
            <> " = unapplied 0x"
            <> unappliedState
            <> " with parameters "
            <> stateParams
            <> " (1 parameter) — the boot tx carried \
               \exactly this script"
        )
    emit
        "derived-applied-identity"
        ( "request applied hash 0x"
            <> requestHex
            <> " = unapplied 0x"
            <> unappliedRequest
            <> " with parameters "
            <> requestParams
            <> " (2 parameters) — the update tx carried \
               \exactly this script"
        )
    emit
        "derived-applied-identity"
        ( "staking applied hash 0x"
            <> unappliedStaking
            <> " takes no parameters (0) — applied and \
               \unapplied coincide, matching the pin"
        )

-- | Require every manifest entry under the validator
-- prefix to pin exactly @unappliedHex@ — the hash of this
-- run's blueprint raw code.
checkPinnedUnapplied :: ScriptIdentity -> Text -> String -> IO ()
checkPinnedUnapplied si prefix unappliedHex =
    case pins of
        [] ->
            failWith
                ( "derived-applied-identity: no pinned unapplied \
                  \entry for "
                    <> T.unpack prefix
                )
        (h : rest) ->
            unless (all (== h) rest && h == T.pack unappliedHex) $
                failWith $
                    "derived-applied-identity: the manifest pins \
                    \unapplied hash "
                        <> T.unpack h
                        <> " for "
                        <> T.unpack prefix
                        <> " but this run's blueprint code \
                           \hashes to 0x"
                        <> unappliedHex
  where
    pins =
        [ vpHash v
        | v <- siValidators si
        , prefix `T.isPrefixOf` vpTitle v
        ]

-- | The hashes of the PlutusV3 scripts a submitted
-- transaction carried in its witness set — the bytes the
-- node received and executed.
witnessScriptHashes :: ConwayTx -> Set.Set String
witnessScriptHashes tx =
    Set.fromList
        [ hex (scriptHashBytes sh)
        | sh <- Map.keys (tx ^. witsTxL . scriptTxWitsL)
        ]

-- ---------------------------------------------------------
-- The journey, on a real devnet
-- ---------------------------------------------------------

runJourney ::
    ScriptIdentity ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    IO ()
runJourney si stateBytes requestBytes stakingBytes = do
    gDir <- genesisDir
    withCardanoNode gDir $ \sock _startMs -> do
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
        verifyConnection nodeThread
        let prov = adaptProvider (mkN2CProvider lsqCh)
            submit = mkN2CSubmitter ltxsCh
        tm <- mkPureTrieManager
        -- The proof mirror: an in-memory trie kept in step with
        -- the operations the journey applies on chain. It builds
        -- the proofs; the roots those proofs are checked against
        -- are always read back from the chain's state datum
        -- (D-013), never from this trie.
        mirrorRef <- newIORef emptyMPFInMemoryDB
        -- Verify the connection carries queries before building on it.
        _ <- Cage.queryProtocolParams prov
        -- Pick the boot seed from the genesis wallet. The state
        -- script is unparameterized; boot carries the seed in the
        -- mint redeemer.
        utxos <- Cage.queryUTxOs prov genesisAddr
        seedRef <- case utxos of
            [] ->
                failWith
                    "genesis wallet has no UTxOs; cannot pick a boot seed"
            (txIn, _) : _ -> pure (txInToRef txIn)
        let cfg = cageCfg stateBytes requestBytes seedRef
        (tokenId, bootRoot, bootTx) <- stepBoot cfg prov submit tm
        reqCount <- stepRequest cfg prov submit tokenId
        stepVerifyAbsent cfg prov mirrorRef tokenId
        appliedTx <- stepApply cfg prov submit tm tokenId reqCount
        stepDerivedIdentity
            si
            cfg
            stateBytes
            requestBytes
            stakingBytes
            tokenId
            bootTx
            appliedTx
        stepVerifyPresent cfg prov mirrorRef tokenId
        appliedState <- stepReadBack cfg prov tokenId bootRoot
        stepReject cfg prov submit tm tokenId appliedState
        cancel nodeThread
        emit "complete" "11/11 journey steps ok"

-- | Boot a cage: mint the state token, register its trie,
-- observe the state UTxO and read the boot state datum.
stepBoot ::
    CageConfig ->
    Cage.Provider IO ->
    Submitter IO ->
    TrieManager IO ->
    IO (TokenId, OnChainRoot, ConwayTx)
stepBoot cfg prov submit tm = do
    unsigned <- bootTokenImpl cfg prov genesisAddr
    signed <- submitWithGenesis submit unsigned
    (tid, tidBytes) <- extractTokenId cfg signed
    createTrie tm tid
    stateUtxos <- Cage.queryUTxOs prov (cageAddrFromCfg cfg Testnet)
    require "boot: state UTxO present at the cage address" $
        not (null stateUtxos)
    bootRoot <- case
        findStateUtxo (cagePolicyIdFromCfg cfg) tid stateUtxos of
        Nothing ->
            failWith
                "boot: no state UTxO carrying the policy token"
        Just (_, out) -> case extractCageDatum out of
            Just (StateDatum s) -> pure (stateRoot s)
            _ ->
                failWith
                    "boot: state UTxO datum is not a StateDatum"
    emit
        "boot"
        ( "booted cage token_id=0x"
            <> hex tidBytes
            <> " tx="
            <> show (txIdTx signed)
            <> " root=0x"
            <> hex (unOnChainRoot bootRoot)
        )
    pure (tid, bootRoot, signed)

-- | Submit an insert request into the cage's request address
-- and observe it land.
stepRequest ::
    CageConfig ->
    Cage.Provider IO ->
    Submitter IO ->
    TokenId ->
    IO Int
stepRequest cfg prov submit tid = do
    let reqAddr = requestAddrFromCfg cfg tid Testnet
    before <- Cage.queryUTxOs prov reqAddr
    require "request: request address empty before the request" $
        null before
    unsigned <-
        requestInsertImpl
            cfg
            prov
            (Coin 1_000_000)
            tid
            journeyKey
            journeyValue
            genesisAddr
    signed <- submitWithGenesis submit unsigned
    after <- Cage.queryUTxOs prov reqAddr
    require
        "request: request UTxO observed at the request address"
        (length after == 1)
    emit
        "request"
        ( "submitted insert request key="
            <> textOf journeyKey
            <> " value="
            <> textOf journeyValue
            <> " tx="
            <> show (txIdTx signed)
            <> " request_utxos="
            <> show (length after)
        )
    pure (length after)

-- | Apply the request as the oracle: the update consumes the
-- request UTxO and moves the trie root on chain.
stepApply ::
    CageConfig ->
    Cage.Provider IO ->
    Submitter IO ->
    TrieManager IO ->
    TokenId ->
    Int ->
    IO ConwayTx
stepApply cfg prov submit tm tid reqCount = do
    unsigned <- updateTokenImpl cfg prov tm tid genesisAddr
    signed <- submitWithGenesis submit unsigned
    after <- Cage.queryUTxOs prov (requestAddrFromCfg cfg tid Testnet)
    require "apply: the request UTxO was consumed" $
        length after < reqCount
    emit
        "apply"
        ( "oracle applied the request tx="
            <> show (txIdTx signed)
            <> " request_utxos "
            <> show reqCount
            <> "->"
            <> show (length after)
        )
    pure signed

-- | Read the resulting state back from the chain: decode the
-- state UTxO's inline datum and observe that the trie root
-- moved from the boot root. Returns the authenticated state
-- as read, for the negative section's unchanged control.
stepReadBack ::
    CageConfig ->
    Cage.Provider IO ->
    TokenId ->
    OnChainRoot ->
    IO OnChainTokenState
stepReadBack cfg prov tid bootRoot = do
    stateUtxos <- Cage.queryUTxOs prov (cageAddrFromCfg cfg Testnet)
    st <- case
        findStateUtxo (cagePolicyIdFromCfg cfg) tid stateUtxos of
        Nothing ->
            failWith "read-back: no state UTxO carrying the policy token"
        Just (_, out) -> case extractCageDatum out of
            Just (StateDatum s) -> pure s
            _ ->
                failWith
                    "read-back: state UTxO datum is not a StateDatum"
    require
        "read-back: trie root moved from the boot root"
        (stateRoot st /= bootRoot)
    emit
        "read-back"
        ( "state read back root 0x"
            <> hex (unOnChainRoot bootRoot)
            <> " -> 0x"
            <> hex (unOnChainRoot (stateRoot st))
            <> " max_fee="
            <> show (stateMaxFee st)
            <> " process_window_ms="
            <> show (stateProcessTime st)
            <> " retract_window_ms="
            <> show (stateRetractTime st)
            <> " stake_script="
            <> maybe "none" (\(BuiltinByteString bs) -> hex bs) (stateStakeScript st)
        )
    pure st

-- ---------------------------------------------------------
-- Negative cases: the validators must refuse (issue #41)
-- ---------------------------------------------------------

{- | The rejection reason each negative case requires: the
node must report a phase-2 Plutus evaluation failure — the
on-chain validator refused to execute the transaction — and
not any phase-1 ledger rule. A malformed CBOR, an unbalanced
fee or a missing input would all "fail" while telling us
nothing about the guards; a phase-1-shaped rejection fails
the run naming what came back instead.

Marker: expected-rejection-reason
-}
expectedRejectionReason :: String
expectedRejectionReason =
    "phase-2 Plutus script evaluation failure \
    \on the submitted transaction"

-- | The node-level marker of that reason: a failed Plutus
-- evaluation is reported by the ledger as a 'PlutusFailure'.
phase2ScriptFailureMarker :: String -> Bool
phase2ScriptFailureMarker = isInfixOf "PlutusFailure"

{- | The MPFS cage negative section. With one unapplied
insert request pending, build the valid update transaction
the oracle would submit, derive three transactions from it
that are each invalid in exactly one intended way, and
require the on-chain validators to refuse all three. Then
prove the authenticated state is unchanged: a rejected
evaluation never applies, so the rejected transactions must
have left no trace.
-}
stepReject ::
    CageConfig ->
    Cage.Provider IO ->
    Submitter IO ->
    TrieManager IO ->
    TokenId ->
    OnChainTokenState ->
    IO ()
stepReject cfg prov submit tm tid stateBeforeRejects = do
    -- A second, unapplied insert request: the payload the
    -- mutated updates below pretend to process. It stays at
    -- the request address throughout.
    let reqAddr = requestAddrFromCfg cfg tid Testnet
    before <- Cage.queryUTxOs prov reqAddr
    require "reject: request address empty before the second request" $
        null before
    unsignedReq <-
        requestInsertImpl
            cfg
            prov
            (Coin 1_000_000)
            tid
            negativeKey
            negativeValue
            genesisAddr
    _ <- submitWithGenesis submit unsignedReq
    reqUtxos <- Cage.queryUTxOs prov reqAddr
    require "reject: exactly one request UTxO after the second request" $
        length reqUtxos == 1
    forgedRef <- case reqUtxos of
        ((reqIn, _) : _) -> pure (txInToRef reqIn)
        [] -> failWith "reject: no request UTxO found"
    emit
        "reject-request"
        ( "pending insert request key="
            <> textOf negativeKey
            <> " value="
            <> textOf negativeValue
            <> " request_utxos="
            <> show (length reqUtxos)
        )
    -- The apply step ran inside a speculative session, whose
    -- mutations were discarded: the manager's trie still holds
    -- the empty boot state, while the chain holds the applied
    -- hello insert. Replay that insert — committed this time —
    -- so the second update's proofs are computed against the
    -- root the chain actually has, and require the manager to
    -- be in step before building on it.
    _ <- withTrie tm tid $ \trie -> do
        _ <- CageTrie.insert trie journeyKey journeyValue
        managerRoot <- CageTrie.getRoot trie
        require
            "reject: trie manager is in step with the chain"
            (unRoot managerRoot == unOnChainRoot (stateRoot stateBeforeRejects))
        pure ()
    -- The valid oracle update for that request. It is never
    -- submitted unmutated: each case derives one single-defect
    -- transaction from it. Every mutation keeps the tx
    -- well-formed for ledger phase 1 (the case descriptions
    -- say how), so only the on-chain validator stands between
    -- each transaction and the ledger.
    baseTx <- updateTokenImpl cfg prov tm tid genesisAddr
    newRoot <- baseTxStateRoot baseTx
    pp <- Cage.queryProtocolParams prov
    -- The validators the three cases require to refuse, by
    -- their script hashes as the node names them in a phase-2
    -- failure.
    let stateScriptHash =
            scriptHashHexOfAddr (cageAddrFromCfg cfg Testnet)
        requestScriptHash =
            scriptHashHexOfAddr (requestAddrFromCfg cfg tid Testnet)
    -- Case 1: forged state-token identity. The request's
    -- Contribute redeemer names a real input — the request
    -- UTxO itself — as the cage's state UTxO. It carries no
    -- state token, and request.request.spend must refuse it.
    expectRejected
        "reject-forged-identity"
        "request.request.spend validateContribute: the claimed state UTxO carries no state token"
        requestScriptHash
        submit
        (forgeContributeStateRef pp forgedRef baseTx)
    -- Case 2: tampered certified output. The new state output
    -- keeps the exact StateDatum shape but its root is the
    -- byte complement of the root the proofs certify.
    let tamperedRoot = tamperRoot newRoot
    expectRejected
        "reject-tampered-output"
        "state.state.spend validModify: output datum root must equal the proof-recomputed root"
        stateScriptHash
        submit
        (tamperStateOutputRoot newRoot tamperedRoot baseTx)
    -- Case 3: missing required witness. The owner signature
    -- is dropped from the body's required signers, so the
    -- ledger no longer demands the vkey witness and phase 1
    -- passes — but state.state.spend still requires it.
    expectRejected
        "reject-missing-witness"
        "state.state.spend validateOwnership: the owner's required signature is absent"
        stateScriptHash
        submit
        (dropRequiredSigners baseTx)
    -- Positive control: the rejected transactions left no
    -- trace. The authenticated state is re-read from the
    -- chain and compared against the post-apply state.
    stateAfter <- readChainState cfg prov tid
    require
        "reject-control: authenticated state datum unchanged"
        (stateAfter == stateBeforeRejects)
    reqAfter <- Cage.queryUTxOs prov reqAddr
    require
        "reject-control: the pending request is still unapplied"
        (length reqAfter == 1)
    emit
        "reject-control"
        ( "authenticated state unchanged after 3 rejected transactions"
            <> " root=0x"
            <> hex (unOnChainRoot (stateRoot stateAfter))
            <> " request_utxos="
            <> show (length reqAfter)
            <> " — no trace"
        )

{- | Submit a mutated transaction that the on-chain
validators must refuse. Fails the journey if the node
accepts it — naming the guard that did not hold — or if it
rejects it for any reason other than 'expectedRejectionReason'.
-}
expectRejected ::
    String ->
    String ->
    String ->
    Submitter IO ->
    ConwayTx ->
    IO ()
expectRejected caseName guard expectedScript submit tx = do
    result <- submitTx submit (addKeyWitness genesisSignKey tx)
    case result of
        Submitted _ ->
            failWith $
                caseName
                    <> ": transaction was ACCEPTED — the guard did not hold: "
                    <> guard
        Rejected reason -> do
            let reasonText = T.unpack (TE.decodeUtf8Lenient reason)
            unless (phase2ScriptFailureMarker reasonText) $
                failWith $
                    caseName
                        <> ": expected-rejection-reason <"
                        <> expectedRejectionReason
                        <> "> but the node rejected with <"
                        <> reasonText
                        <> ">"
            -- The node names the script that failed: require the
            -- expected validator to be the one that refused.
            unless (expectedScript `isInfixOf` reasonText) $
                failWith $
                    caseName
                        <> ": the node rejected in phase 2 but its failure does not name the expected validator (script hash 0x"
                        <> expectedScript
                        <> "); the node said <"
                        <> reasonText
                        <> ">"
            emit caseName ("node refused it, reason matched: " <> reasonText)

-- | The payload of the request the negative section
-- pretends to process. It is never applied.
negativeKey :: ByteString
negativeKey = "negative"

negativeValue :: ByteString
negativeValue = "probe"

-- | The root the valid update writes into its state output.
baseTxStateRoot :: ConwayTx -> IO OnChainRoot
baseTxStateRoot tx = case mapMaybe stateRootOf outputs of
    [r] -> pure r
    rs ->
        failWith $
            "reject: expected exactly one state output in the base update, found "
                <> show (length rs)
  where
    outputs = toList (tx ^. bodyTxL . outputsTxBodyL)
    stateRootOf out = case extractCageDatum out of
        Just (StateDatum s) -> Just (stateRoot s)
        _ -> Nothing

-- | A same-shaped but wrong root: the byte complement.
tamperRoot :: OnChainRoot -> OnChainRoot
tamperRoot (OnChainRoot bs) = OnChainRoot (BS.map complement bs)

{- | Rewrite the request spend's Contribute redeemer so it
names a forged state reference, and re-stamp the script
integrity hash so ledger phase 1 stays valid. Everything
else — inputs, outputs, fees — is untouched.
-}
forgeContributeStateRef ::
    PParams ConwayEra ->
    OnChainTxOutRef ->
    ConwayTx ->
    ConwayTx
forgeContributeStateRef pp forgedRef tx =
    tx
        & witsTxL . rdmrsTxWitsL .~ newRedeemers
        & bodyTxL . scriptIntegrityHashTxBodyL .~ integrity
  where
    Redeemers rdmrMap = tx ^. witsTxL . rdmrsTxWitsL
    newRedeemers = Redeemers (Map.map swapContribute rdmrMap)
    swapContribute pair = case decodeUpdateRedeemer (fst pair) of
        Just (Contribute _) -> (toLedgerData (Contribute forgedRef), snd pair)
        _ -> pair
    integrity = computeScriptIntegrity pp newRedeemers

-- | Decode a redeemer payload as an 'UpdateRedeemer'.
decodeUpdateRedeemer :: Data ConwayEra -> Maybe UpdateRedeemer
decodeUpdateRedeemer (Data d) = fromBuiltinData (BuiltinData d)

-- | Lowercase hex of the script hash of a script payment
-- address, in the form the node names a failing script by.
scriptHashHexOfAddr :: Addr -> String
scriptHashHexOfAddr (Addr _ (ScriptHashObj sh) _) =
    hex (scriptHashBytes sh)
scriptHashHexOfAddr _ = emptyScriptHashHex

-- | The empty fallback for a non-script address, which the
-- reason check can never match.
emptyScriptHashHex :: String
emptyScriptHashHex = ""

{- | Replace the root inside the new state output's inline
datum: correct 'StateDatum' shape, wrong content. The value,
size and address are untouched, so fee and min-UTxO rules
still hold.
-}
tamperStateOutputRoot :: OnChainRoot -> OnChainRoot -> ConwayTx -> ConwayTx
tamperStateOutputRoot expected tampered tx =
    tx & bodyTxL . outputsTxBodyL %~ fmap fixOutput
  where
    fixOutput out = case extractCageDatum out of
        Just (StateDatum s)
            | stateRoot s == expected ->
                out
                    & datumTxOutL
                    .~ mkInlineDatum
                        (toPlcData (StateDatum s{stateRoot = tampered}))
        _ -> out

{- | Drop every required signer from the body: the ledger no
longer demands the owner's vkey witness, but the state
validator still does.
-}
dropRequiredSigners :: ConwayTx -> ConwayTx
dropRequiredSigners tx =
    tx & bodyTxL . reqSignerHashesTxBodyL .~ Set.empty

-- ---------------------------------------------------------
-- Authenticated-state verification (D-013)
-- ---------------------------------------------------------

-- | The bounded operation the journey applies: an insert of
-- 'journeyKey' with 'journeyValue'. 'forgedValue' is a value
-- the state does not hold — the negative case's claim.
journeyKey :: ByteString
journeyKey = "hello"

journeyValue :: ByteString
journeyValue = "world"

forgedValue :: ByteString
forgedValue = "forged"

{- | MPF codecs and key hashing with the exact conventions
the cage trie uses, so proof paths match what the on-chain
validator expects.
-}
mpfCodecs :: MPFStandaloneCodecs HexKey MPFHash MPFHash
mpfCodecs =
    MPFStandaloneCodecs
        { mpfKeyCodec = hexKeyPrism
        , mpfValueCodec = isoMPFHash
        , mpfNodeCodec = isoMPFHash
        }

fromHexKVIdentity :: FromHexKV HexKey MPFHash MPFHash
fromHexKVIdentity =
    FromHexKV
        { fromHexK = id
        , fromHexV = id
        , hexTreePrefix = const []
        }

-- | Keys enter the trie hashed, as the cage library hashes them.
mpfKeyPath :: ByteString -> HexKey
mpfKeyPath = byteStringToHexKey . renderMPFHash . mkMPFHash

-- | Build the exclusion proof for a raw key against a
-- snapshot of the mirror database.
exclusionProofFrom ::
    MPFInMemoryDB -> ByteString -> Maybe (MPFExclusionProof MPFHash)
exclusionProofFrom db k =
    fst $
        runMPFPure db $
            runMPFPureTransaction mpfCodecs $
                mkMPFExclusionProof
                    []
                    fromHexKVIdentity
                    mpfHashing
                    MPFStandaloneMPFCol
                    (mpfKeyPath k)

-- | Build the inclusion proof for a raw key against a
-- snapshot of the mirror database.
inclusionProofFrom ::
    MPFInMemoryDB -> ByteString -> Maybe (MPFProof MPFHash)
inclusionProofFrom db k =
    fst $
        runMPFPure db $
            runMPFPureTransaction mpfCodecs $
                mkMPFInclusionProof
                    []
                    fromHexKVIdentity
                    mpfHashing
                    MPFStandaloneMPFCol
                    (mpfKeyPath k)

{- | The chain-read root as the exclusion verifier's trusted
root: the all-zero root denotes the empty trie.
-}
trustedRootFromChain :: OnChainRoot -> IO (Maybe MPFHash)
trustedRootFromChain (OnChainRoot bs)
    | bs == BS.replicate 32 0 = pure Nothing
    | otherwise = case parseMPFHash bs of
        Just h -> pure (Just h)
        Nothing ->
            failWith
                ("verify: malformed chain root 0x" <> hex bs)

-- | Read the current state datum for a token straight from
-- the chain: the state UTxO at the cage address. This is the
-- only comparison target for every verification below.
readChainState ::
    CageConfig ->
    Cage.Provider IO ->
    TokenId ->
    IO OnChainTokenState
readChainState cfg prov tid = do
    stateUtxos <- Cage.queryUTxOs prov (cageAddrFromCfg cfg Testnet)
    case findStateUtxo (cagePolicyIdFromCfg cfg) tid stateUtxos of
        Nothing ->
            failWith "verify: no state UTxO carrying the policy token"
        Just (_, out) -> case extractCageDatum out of
            Just (StateDatum s) -> pure s
            _ ->
                failWith
                    "verify: state UTxO datum is not a StateDatum"

{- | Verify the key is provably absent from the authenticated
state, before the insert: fold the exclusion proof and compare
the root it implies against the root read back from the chain.
-}
stepVerifyAbsent ::
    CageConfig ->
    Cage.Provider IO ->
    IORef MPFInMemoryDB ->
    TokenId ->
    IO ()
stepVerifyAbsent cfg prov mirrorRef tid = do
    chainRoot <- stateRoot <$> readChainState cfg prov tid
    trusted <- trustedRootFromChain chainRoot
    db <- readIORef mirrorRef
    proof <- case exclusionProofFrom db journeyKey of
        Just p -> pure p
        Nothing ->
            failWith $
                "proved-absent failed: key "
                    <> textOf journeyKey
                    <> " has no exclusion proof — the state holds it"
                    <> "; chain root 0x"
                    <> hex (unOnChainRoot chainRoot)
    let implied = foldMPFExclusionProof mpfHashing proof
    unless (verifyMPFExclusionProof mpfHashing trusted proof) $
        failWith $
            "proved-absent failed: key "
                <> textOf journeyKey
                <> " exclusion proof implies root "
                <> maybe "<empty trie>" (hex . renderMPFHash) implied
                <> " but the chain read root 0x"
                <> hex (unOnChainRoot chainRoot)
    emit
        "verify-absent"
        ( "proved absent key="
            <> textOf journeyKey
            <> " against chain root 0x"
            <> hex (unOnChainRoot chainRoot)
        )

{- | Verify the key is provably present with the expected
value, after the apply: replay the applied insert into the
mirror, bind the claimed value into the inclusion proof, fold
it, and compare against the chain-read root. Then run the
negative case: a proof asserting a value the state does not
hold must not reproduce that root, and the runner must reject
it.
-}
stepVerifyPresent ::
    CageConfig ->
    Cage.Provider IO ->
    IORef MPFInMemoryDB ->
    TokenId ->
    IO ()
stepVerifyPresent cfg prov mirrorRef tid = do
    let mirror = mkPureTrieFromRef mirrorRef
    _ <- CageTrie.insert mirror journeyKey journeyValue
    chainRoot <- stateRoot <$> readChainState cfg prov tid
    db <- readIORef mirrorRef
    base <- case inclusionProofFrom db journeyKey of
        Just p -> pure p
        Nothing ->
            failWith $
                "proved-present failed: key "
                    <> textOf journeyKey
                    <> " has no inclusion proof; chain root 0x"
                    <> hex (unOnChainRoot chainRoot)
    let claimed = base{mpfProofValueHash = mkMPFHash journeyValue}
        implied = foldMPFProof mpfHashing claimed
    unless (renderMPFHash implied == unOnChainRoot chainRoot) $
        failWith $
            "proved-present failed: key "
                <> textOf journeyKey
                <> " value "
                <> textOf journeyValue
                <> ": proof implies root 0x"
                <> hex (renderMPFHash implied)
                <> " but the chain read root 0x"
                <> hex (unOnChainRoot chainRoot)
    emit
        "verify-present"
        ( "proved present key="
            <> textOf journeyKey
            <> " value="
            <> textOf journeyValue
            <> " root=0x"
            <> hex (unOnChainRoot chainRoot)
        )
    let falseClaim = base{mpfProofValueHash = mkMPFHash forgedValue}
        falseRoot = foldMPFProof mpfHashing falseClaim
    when (renderMPFHash falseRoot == unOnChainRoot chainRoot) $
        failWith $
            "false-claim accepted: key "
                <> textOf journeyKey
                <> " claimed value "
                <> textOf forgedValue
                <> " reproduced the chain read root 0x"
                <> hex (unOnChainRoot chainRoot)
                <> " — the negative case is not negative"
    emit
        "verify-false-claim"
        ( "rejected false claim key="
            <> textOf journeyKey
            <> " claimed value="
            <> textOf forgedValue
            <> ": proof implies root 0x"
            <> hex (renderMPFHash falseRoot)
            <> " which differs from the chain read root 0x"
            <> hex (unOnChainRoot chainRoot)
        )

-- ---------------------------------------------------------
-- Shared plumbing (same code path as the E2E suite)
-- ---------------------------------------------------------

-- | Build a 'CageConfig' from state and request script bytes
-- plus the boot seed 'OnChainTxOutRef', exactly as the E2E
-- suite does. The raw state bytes are applied to the empty
-- (genesis) @previousPolicies@ allowlist before hashing,
-- matching the parameterized on-chain state script.
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

{- | Extract the 'TokenId' from a boot transaction's mint
field, with the raw asset-name bytes for narration.
-}
extractTokenId :: CageConfig -> ConwayTx -> IO (TokenId, ByteString)
extractTokenId cfg tx =
    let MultiAsset ma =
            tx ^. bodyTxL . mintTxBodyL
        assets =
            Map.toList
                (ma Map.! cagePolicyIdFromCfg cfg)
     in case assets of
            [(AssetName an, _)] ->
                pure (TokenId (AssetName an), fromShort an)
            _ ->
                failWith $
                    "boot: unexpected mint assets: "
                        <> show (length assets)

{- | Sign with the devnet genesis key, submit and wait for
confirmation. Fails the journey on a rejected transaction.
-}
submitWithGenesis :: Submitter IO -> ConwayTx -> IO ConwayTx
submitWithGenesis submit unsigned = do
    let signed = addKeyWitness genesisSignKey unsigned
    result <- submitTx submit signed
    case result of
        Submitted _ -> pure ()
        Rejected reason -> failWith ("tx rejected: " <> show reason)
    threadDelay 5_000_000
    pure signed

{- | Adapt a @cardano-node-clients@ 'N2C.Provider' to a
@Cage@ 'Cage.Provider'. The record fields are identical.
-}
adaptProvider :: N2C.Provider IO -> Cage.Provider IO
adaptProvider p =
    Cage.Provider
        { Cage.queryUTxOs = N2C.queryUTxOs p
        , Cage.queryProtocolParams = N2C.queryProtocolParams p
        , Cage.evaluateTx = N2C.evaluateTx p
        , Cage.posixMsToSlot = N2C.posixMsToSlot p
        , Cage.posixMsCeilSlot = N2C.posixMsCeilSlot p
        }

-- | Fail the journey unless the node client thread is alive
-- and connected after startup.
verifyConnection :: (Show e) => Async (Either e ()) -> IO ()
verifyConnection nodeThread = do
    status <- poll nodeThread
    case status of
        Just (Left err) ->
            failWith ("node connection failed: " <> show err)
        Just (Right (Left err)) ->
            failWith ("node connection error: " <> show err)
        Just (Right (Right ())) ->
            failWith "node connection closed unexpectedly"
        Nothing -> pure ()

-- ---------------------------------------------------------
-- Narration helpers
-- ---------------------------------------------------------

-- | One narration line: what the runner did and what it
-- observed.
emit :: String -> String -> IO ()
emit stepName detail =
    putStrLn ("[journey] " <> stepName <> ": " <> detail)

-- | Fail the journey unless the observable holds.
require :: String -> Bool -> IO ()
require label cond =
    unless cond (failWith ("condition failed: " <> label))

-- | Abort the journey with a diagnosable message.
failWith :: String -> IO a
failWith msg = throwIO (ErrorCall ("journey: " <> msg))

requireEnv :: String -> IO String
requireEnv name =
    lookupEnv name
        >>= maybe
            (failWith ("missing environment variable " <> name))
            pure

-- | Lowercase hex for narration.
hex :: ByteString -> String
hex = T.unpack . TE.decodeUtf8 . Base16.encode

-- | Render a byte string as text for narration.
textOf :: ByteString -> String
textOf = T.unpack . TE.decodeUtf8
