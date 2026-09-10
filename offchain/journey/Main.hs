{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Main
Description : The bounded MPFS cage journey, verified against a real devnet
License     : Apache-2.0

One command that runs the bounded journey against a real devnet
node and verifies it, one line per step:

  boot a cage, submit a request, prove the key absent, apply
  the request, prove the key present with the expected value,
  reject a false claim, read the resulting state back.

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
validator hashes read from @onchain/script-identity.json@, so the
run states which contracts it exercised.
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
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short (fromShort)
import Data.ByteString.Short qualified as SBS
import Data.IORef (IORef, newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((^.))
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body (mintTxBodyL)
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Mary.Value (MultiAsset (..))

import Cardano.MPFS.Cage.Blueprint (
    applyPreviousPolicies,
    extractCompiledCode,
    loadBlueprint,
 )
import Cardano.MPFS.Cage.Config (CageConfig (..))
import Cardano.MPFS.Cage.Ledger (
    AssetName (..),
    Coin (..),
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
    extractCageDatum,
    findStateUtxo,
    requestAddrFromCfg,
    txInToRef,
 )
import Cardano.MPFS.Cage.TxBuilder.Request (requestInsertImpl)
import Cardano.MPFS.Cage.TxBuilder.Update (updateTokenImpl)
import Cardano.MPFS.Cage.Types (
    CageDatum (..),
    OnChainRoot (..),
    OnChainTokenState (..),
    OnChainTxOutRef,
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
import PlutusTx.Builtins.Internal (BuiltinByteString (..))

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
    printIdentity =<< readScriptIdentity identityPath
    ebp <- loadBlueprint blueprintPath
    bp <- either failWith pure ebp
    case
        ( extractCompiledCode "state.state" bp
        , extractCompiledCode "request.request" bp
        ) of
        (Just stateBytes, Just requestBytes) ->
            runJourney stateBytes requestBytes
        _ ->
            failWith
                "state.state or request.request compiled code \
                \not found in blueprint"

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
the upstream source revision and the compiled validator
hashes the repository pins.
-}
data ScriptIdentity = ScriptIdentity
    { siRevision :: Text
    , siValidators :: [ValidatorPin]
    }

data ValidatorPin = ValidatorPin
    { vpTitle :: Text
    -- ^ Validator title, e.g. @state.state.spend@
    , vpHash :: Text
    -- ^ Compiled script hash pinned in the manifest
    }

instance FromJSON ValidatorPin where
    parseJSON = withObject "ValidatorPin" $ \o ->
        ValidatorPin <$> o .: "title" <*> o .: "hash"

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
            ( "pinned validator "
                <> T.unpack (vpTitle v)
                <> " hash "
                <> T.unpack (vpHash v)
            )

-- ---------------------------------------------------------
-- The journey, on a real devnet
-- ---------------------------------------------------------

runJourney :: SBS.ShortByteString -> SBS.ShortByteString -> IO ()
runJourney stateBytes requestBytes = do
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
        (tokenId, bootRoot) <- stepBoot cfg prov submit tm
        reqCount <- stepRequest cfg prov submit tokenId
        stepVerifyAbsent cfg prov mirrorRef tokenId
        stepApply cfg prov submit tm tokenId reqCount
        stepVerifyPresent cfg prov mirrorRef tokenId
        stepReadBack cfg prov tokenId bootRoot
        cancel nodeThread
        emit "complete" "6/6 journey steps ok"

-- | Boot a cage: mint the state token, register its trie,
-- observe the state UTxO and read the boot state datum.
stepBoot ::
    CageConfig ->
    Cage.Provider IO ->
    Submitter IO ->
    TrieManager IO ->
    IO (TokenId, OnChainRoot)
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
    pure (tid, bootRoot)

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
    IO ()
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

-- | Read the resulting state back from the chain: decode the
-- state UTxO's inline datum and observe that the trie root
-- moved from the boot root.
stepReadBack ::
    CageConfig ->
    Cage.Provider IO ->
    TokenId ->
    OnChainRoot ->
    IO ()
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
