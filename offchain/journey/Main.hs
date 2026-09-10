{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Main
Description : The bounded MPFS cage journey, narrated against a real devnet
License     : Apache-2.0

One command that runs the bounded journey against a real devnet
node and narrates it, one line per step:

  boot a cage, submit a request, apply it, read the resulting
  state back.

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
import Control.Monad (unless)
import Data.Aeson (FromJSON (..), eitherDecode', withObject, (.:))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short (fromShort)
import Data.ByteString.Short qualified as SBS
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
import Cardano.MPFS.Cage.Trie (TrieManager (..))
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
        stepApply cfg prov submit tm tokenId reqCount
        stepReadBack cfg prov tokenId bootRoot
        cancel nodeThread
        emit "complete" "4/4 journey steps ok"

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
            "hello"
            "world"
            genesisAddr
    signed <- submitWithGenesis submit unsigned
    after <- Cage.queryUTxOs prov reqAddr
    require
        "request: request UTxO observed at the request address"
        (length after == 1)
    emit
        "request"
        ( "submitted insert request key=hello value=world tx="
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
