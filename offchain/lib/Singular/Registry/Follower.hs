{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Singular.Registry.Follower
Description : Recover the proof mirror from confirmed registry transactions
License     : Apache-2.0

Follows the registry token from its recorded bootstrap. Request outputs
are retained until spent; Modify actions replay in ledger input order.
A checkpoint contains the complete replay state at one block boundary.
A rolled-back checkpoint restarts from origin. A mirror is published
only after its root agrees with a current node query.
-}
module Singular.Registry.Follower (
    FollowResult (..),
    followDeployment,
    FollowSource (..),
    nodeSource,
    followDeploymentWith,
    rebuildIfNeeded,
    attachRebuilding,
) where

import Control.Concurrent.Async (race)
import Control.Exception (SomeAsyncException, SomeException, catch, displayException, fromException, throwIO)
import Control.Monad (foldM, unless, void, when)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (elemIndex)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Proxy (Proxy (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64)
import Lens.Micro ((^.))
import System.Directory (doesFileExist)

import Cardano.Chain.Slotting (EpochSlots (..))
import Cardano.Crypto.Hash (hashFromBytes)
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Alonzo.Tx (IsValid (..), isValidTxL)
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body (inputsTxBodyL, outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (TxOut, valueTxOutL)
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Binary (decodeFull', serialize')
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (eraProtVerLow)
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..), PolicyID (..))
import Cardano.Ledger.Plutus.Data (Data (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Node.Client.N2C.ChainSync (runChainSyncN2C)
import Cardano.Node.Client.N2C.Connection (newLSQChannel, newLTxSChannel, runNodeClient)
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.Provider qualified as Node
import Cardano.Node.Client.Types (Block, BlockPoint)
import Cardano.Read.Ledger.Block.Block (fromConsensusBlock)
import Cardano.Read.Ledger.Block.Block qualified as ReadBlock
import Cardano.Read.Ledger.Block.Txs (getEraTransactions)
import Cardano.Read.Ledger.Eras.EraValue (applyEraFun)
import Cardano.Read.Ledger.Eras.KnownEras (Era (..), IsEra, theEra)
import Cardano.Read.Ledger.Tx.Tx qualified as Read
import Cardano.Tx.Ledger (ConwayTx)
import ChainFollower (Follower (..), Intersector (..), ProgressOrRewind (..))
import MPF.Backend.Pure (MPFInMemoryDB, emptyMPFInMemoryDB)
import Ouroboros.Consensus.Block.Abstract (fromRawHash, toRawHash)
import Ouroboros.Network.Block qualified as Network
import Ouroboros.Network.Magic (NetworkMagic (..))
import Ouroboros.Network.Point qualified as Point
import Ouroboros.Network.Protocol.ChainSync.Client (ChainSyncClient (..), ClientStIdle (..), ClientStIntersect (..), ClientStNext (..))
import PlutusTx (fromBuiltinData)
import PlutusTx.Builtins.Internal (BuiltinByteString (..), BuiltinData (..))

import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Deployment (
    Attached (..),
    CageParts,
    Deployment (..),
    ReplayCheckpoint (..),
    attach,
    loadMirror,
    loadReplayCheckpoint,
    mirrorPathFor,
    parseOutRef,
    readDeployment,
    renderOutRef,
    saveFollowedMirror,
 )
import Singular.Registry.Ledger (AssetName (..), ConwayEra, Root (..), TokenId (..))
import Singular.Registry.Provider qualified as Registry
import Singular.Registry.Trie qualified as Trie
import Singular.Registry.Trie.Pure (getRootFromDb, mkPureTrieFromRef)
import Singular.Registry.TxBuilder.Internal (extractCageDatum, txInToRef)
import Singular.Registry.Types (
    CageDatum (..),
    OnChainOperation (..),
    OnChainRequest (..),
    OnChainRoot (..),
    OnChainTokenId (..),
    OnChainTokenState (..),
    RequestAction (..),
    UpdateRedeemer (..),
 )

-- | Evidence returned after a verified mirror has been atomically saved.
data FollowResult = FollowResult
    { followedSlot :: Word64
    -- ^ Last replayed block slot
    , followedState :: Text
    -- ^ Confirmed registry state output
    , followedRoot :: Text
    -- ^ Rebuilt root, in hex
    , followedBlocks :: Int
    -- ^ Blocks consumed in this invocation
    , followedFolds :: Int
    -- ^ Registry folds consumed in this invocation
    , followedResumed :: Bool
    -- ^ Whether the saved checkpoint was used without rollback
    }
    deriving (Eq, Show)

data Replay = Replay
    { replayDb :: IORef MPFInMemoryDB
    , replayState :: Maybe (TxIn, TxOut ConwayEra)
    , replayRequests :: Map.Map TxIn (TxOut ConwayEra)
    , replayPoint :: BlockPoint
    , replayBlocks :: Int
    , replayFolds :: Int
    , replayResumed :: Bool
    }

failFollow :: String -> IO a
failFollow = ioError . userError . ("registry-follow: " <>)

hex :: ByteString -> Text
hex = T.pack . BC.unpack . B16.encode

unhex :: Text -> IO ByteString
unhex = either (const (failFollow "checkpoint-decode: invalid hex")) pure . B16.decode . BC.pack . T.unpack

-- | Rebuild from a manifest and node socket; no signing key is used.
followDeployment :: FilePath -> FilePath -> IO FollowResult
followDeployment = followDeploymentWith nodeSource

{- | Transport boundary. Injected sources drive the same replay/reset and
publication path as the real node; they do not supply computed roots.
-}
data FollowSource = FollowSource
    { followChain :: Intersector BlockPoint Network.SlotNo Block -> [BlockPoint] -> IO ()
    , currentOutputs :: TxIn -> IO (Maybe (Map.Map TxIn (TxOut ConwayEra)))
    -- ^ Nothing means a disconnected query client, not an empty UTxO result.
    }

nodeSource :: Deployment -> FilePath -> FollowSource
nodeSource dep socket = FollowSource run query
  where
    magic = NetworkMagic (depNetworkMagic dep)
    run intersector points = do
        let epochSlots = EpochSlots (if depNetworkMagic dep == 42 then 42 else 21600)
        outcome <- runChainSyncN2C epochSlots magic socket (finiteClient intersector points)
        either throwIO pure outcome
    query stateRef = do
        lsq <- newLSQChannel 16
        submit <- newLTxSChannel 16
        queried <-
            race (runNodeClient magic socket lsq submit) $
                Node.queryUTxOByTxIn (mkN2CProvider lsq) (Set.singleton stateRef)
        case queried of
            Left (Left err) -> throwIO err
            Left (Right ()) -> pure Nothing
            Right rows -> pure (Just rows)

-- Preserve already classified follower errors and asynchronous cancellation.
-- Only boundary failures acquire the checkpoint/network diagnostic prefix.
namedBoundary :: String -> IO a -> IO a
namedBoundary name action =
    action `catch` \(err :: SomeException) ->
        case fromException err :: Maybe SomeAsyncException of
            Just _ -> throwIO err
            Nothing
                | "registry-follow:" `T.isInfixOf` T.pack (displayException err) -> throwIO err
                | otherwise -> failFollow (name <> ": " <> displayException err)

followDeploymentWith :: (Deployment -> FilePath -> FollowSource) -> FilePath -> FilePath -> IO FollowResult
followDeploymentWith = followDeploymentFrom False

followDeploymentFrom :: Bool -> (Deployment -> FilePath -> FollowSource) -> FilePath -> FilePath -> IO FollowResult
followDeploymentFrom fromBootstrap sourceFor manifest socket = do
    dep <- readDeployment manifest
    tok <- deploymentToken dep
    saved <- if fromBootstrap then pure Nothing else namedBoundary "checkpoint-decode" (loadReplayCheckpoint manifest)
    initial <- case saved of
        Just cp | cpDeployment cp == dep -> namedBoundary "checkpoint-decode" (restoreReplay manifest tok cp)
        _ -> freshReplay
    ref <- newIORef initial
    let restart = do
            fresh <- freshReplay
            writeIORef ref fresh
            pure (intersector, [Network.genesisPoint])
        intersector =
            Intersector
                { intersectFound = \_ -> pure follower
                , intersectNotFound = restart
                }
        follower =
            Follower
                { rollForward = \block _ -> do
                    old <- readIORef ref
                    new <- replayBlock dep tok old block
                    writeIORef ref new
                    pure follower
                , rollBackward = \point -> do
                    current <- readIORef ref
                    if point == replayPoint current
                        then pure (Progress follower)
                        else do
                            _ <- restart
                            pure (Reset intersector)
                }
        source = sourceFor dep socket
    namedBoundary "socket-query" (followChain source intersector [replayPoint initial])
    final <- readIORef ref
    (stateRef, stateOut) <- maybe (failFollow "bootstrap-not-found: registry state was not found from the recorded bootstrap") pure (replayState final)
    db <- readIORef (replayDb final)
    checkRoot db stateOut
    -- Query the exact still-live output: a concurrent fold or rollback
    -- cannot turn the replayed snapshot into an apparently current mirror.
    queried <- namedBoundary "socket-query" (currentOutputs source stateRef)
    utxos <- maybe (failFollow "node-disconnected-before-root-verification") pure queried
    case Map.lookup stateRef utxos of
        Just out | out == stateOut -> checkRoot db out
        _ -> failFollow "chain-moved: replayed registry state is no longer current; rerun follow"
    let (slot, hash) = pointParts (replayPoint final)
        checkpoint =
            ReplayCheckpoint
                { cpDeployment = dep
                , cpSlot = slot
                , cpBlockHash = hash
                , cpStateRef = renderOutRef stateRef
                , cpStateOutput = encodeOutput stateOut
                , cpRequests = [(renderOutRef i, encodeOutput o) | (i, o) <- Map.toList (replayRequests final)]
                }
    saveFollowedMirror manifest checkpoint (Map.singleton tok db)
    Root root <- getRootFromDb db
    pure
        FollowResult
            { followedSlot = slot
            , followedState = renderOutRef stateRef
            , followedRoot = hex root
            , followedBlocks = replayBlocks final
            , followedFolds = replayFolds final
            , followedResumed = replayResumed final
            }

{- | Attach and repair a missing or stale mirror before returning the
refreshed confirmed state output to a writer.
-}
attachRebuilding :: Registry.Provider IO -> Deployment -> CageParts -> FilePath -> FilePath -> IO Attached
attachRebuilding provider deployment parts manifest socket = do
    attached <- attach provider deployment parts
    rebuildIfNeeded manifest socket attached
    attach provider deployment parts

{- | Follow only when no mirror exists or its root differs from the
already resolved state output. The caller reattaches after a rebuild.
-}
rebuildIfNeeded :: FilePath -> FilePath -> Attached -> IO ()
rebuildIfNeeded manifest socket attached = do
    exists <- doesFileExist (mirrorPathFor manifest)
    mirrors <- loadMirror manifest
    let db = Map.findWithDefault emptyMPFInMemoryDB (attToken attached) mirrors
    Root local <- getRootFromDb db
    chain <- outputRoot (snd (attStateUtxo attached))
    when (not exists || local /= chain) (void (followDeploymentFrom True nodeSource manifest socket))

deploymentToken :: Deployment -> IO TokenId
deploymentToken dep = do
    seed <- either failFollow pure (parseOutRef (depSeedOutRef dep))
    let name = deriveAssetName (txInToRef seed)
    unless (hex name == depCageToken dep) (failFollow "manifest-token-mismatch")
    when (null (depBootstrapTxs dep)) (failFollow "manifest has no bootstrap transaction")
    pure (TokenId (AssetName (SBS.toShort name)))

freshReplay :: IO Replay
freshReplay = do
    db <- newIORef emptyMPFInMemoryDB
    pure (Replay db Nothing Map.empty Network.genesisPoint 0 0 False)

restoreReplay :: FilePath -> TokenId -> ReplayCheckpoint -> IO Replay
restoreReplay manifest tok cp = do
    mirrors <- loadMirror manifest
    db <- maybe (failFollow "checkpoint has no registry trie") pure (Map.lookup tok mirrors)
    stateIn <- either failFollow pure (parseOutRef (cpStateRef cp))
    stateOut <- decodeOutput (cpStateOutput cp)
    policy <- deploymentPolicy (cpDeployment cp)
    unless (hasToken policy tok stateOut) (failFollow "checkpoint-state-token-mismatch")
    checkRoot db stateOut
    requests <- mapM (\(i, o) -> (,) <$> either failFollow pure (parseOutRef i) <*> decodeOutput o) (cpRequests cp)
    raw <- unhex (cpBlockHash cp)
    unless (length (BC.unpack raw) == 32) (failFollow "checkpoint block hash must be 32 bytes")
    let point = Network.Point (Point.At (Point.Block (Network.SlotNo (cpSlot cp)) (fromRawHash (Proxy @Block) raw)))
    dbRef <- newIORef db
    pure (Replay dbRef (Just (stateIn, stateOut)) (Map.fromList requests) point 0 0 True)

pointParts :: BlockPoint -> (Word64, Text)
pointParts (Network.Point Point.Origin) = (0, "")
pointParts (Network.Point (Point.At (Point.Block (Network.SlotNo slot) hash))) =
    (slot, hex (toRawHash (Proxy @Block) hash))

encodeOutput :: TxOut ConwayEra -> Text
encodeOutput = hex . serialize' (eraProtVerLow @ConwayEra)

decodeOutput :: Text -> IO (TxOut ConwayEra)
decodeOutput value = do
    raw <- unhex value
    either (failFollow . ("checkpoint-decode: output: " <>) . show) pure (decodeFull' (eraProtVerLow @ConwayEra) raw)

outputRoot :: TxOut ConwayEra -> IO ByteString
outputRoot out = case extractCageDatum out of
    Just (StateDatum st) -> pure (unOnChainRoot (stateRoot st))
    _ -> failFollow "state output has no registry state datum"

checkRoot :: MPFInMemoryDB -> TxOut ConwayEra -> IO ()
checkRoot db out = do
    Root actual <- getRootFromDb db
    expected <- outputRoot out
    unless (actual == expected) $
        failFollow ("root-mismatch: rebuilt=" <> T.unpack (hex actual) <> " chain=" <> T.unpack (hex expected))

replayBlock :: Deployment -> TokenId -> Replay -> Block -> IO Replay
replayBlock dep tok replay block = do
    next <- foldM (replayTx dep tok) replay (applyEraFun transactions (fromConsensusBlock block))
    pure next{replayPoint = Network.blockPoint block, replayBlocks = replayBlocks replay + 1}
  where
    transactions :: forall era. (IsEra era) => ReadBlock.Block era -> [ConwayTx]
    transactions eraBlock = case theEra @era of
        Conway -> map Read.unTx (getEraTransactions eraBlock)
        _ -> []

replayTx :: Deployment -> TokenId -> Replay -> ConwayTx -> IO Replay
replayTx dep tok replay tx
    | tx ^. isValidTxL /= IsValid True = pure replay
    | otherwise = do
        policy <- deploymentPolicy dep
        let inputs = Set.toAscList (tx ^. bodyTxL . inputsTxBodyL)
            outputs = zipWith (\ix o -> (TxIn (txIdTx tx) (TxIx ix), o)) [0 ..] (toList (tx ^. bodyTxL . outputsTxBodyL))
            stateOutputs = filter (hasToken policy tok . snd) outputs
            pending = replayRequests replay
            consumed = mapMaybe (`Map.lookup` pending) inputs
        next <- case replayState replay of
            Nothing -> case stateOutputs of
                [] -> pure replay
                [state] -> do
                    let bootId = T.takeWhile (/= '#') (renderOutRef (fst state))
                    seed <- either failFollow pure (parseOutRef (depSeedOutRef dep))
                    unless (bootId `elem` depBootstrapTxs dep && seed `elem` inputs) (failFollow "bootstrap-identity-mismatch")
                    readIORef (replayDb replay) >>= \db -> checkRoot db (snd state)
                    pure replay{replayState = Just state}
                _ -> failFollow "multiple registry state outputs"
            Just (stateIn, oldOut)
                | stateIn `elem` inputs -> do
                    actions <- foldActions tx stateIn inputs
                    unless (length actions == length consumed) (failFollow "request-action-count-mismatch: missing request history")
                    readIORef (replayDb replay) >>= \db -> checkRoot db oldOut
                    mapM_ (applyRequest (replayDb replay)) (zip consumed actions)
                    state <- case stateOutputs of
                        [state] -> pure state
                        _ -> failFollow "registry-state-ended-or-missing"
                    readIORef (replayDb replay) >>= \db -> checkRoot db (snd state)
                    pure replay{replayState = Just state, replayFolds = replayFolds replay + 1}
                | null stateOutputs -> pure replay
                | otherwise -> failFollow "registry-state-chain-broken"
        let retained = foldr Map.delete pending inputs
            created = filter (isRequest tok . snd) outputs
        pure next{replayRequests = Map.union (Map.fromList created) retained}

deploymentPolicy :: Deployment -> IO PolicyID
deploymentPolicy dep = do
    bytes <- unhex (depStatePolicy dep)
    h <- maybe (failFollow "manifest state policy is not a script hash") pure (hashFromBytes bytes)
    pure (PolicyID (ScriptHash h))

hasToken :: PolicyID -> TokenId -> TxOut ConwayEra -> Bool
hasToken policy (TokenId name) out =
    let MaryValue _ (MultiAsset assets) = out ^. valueTxOutL
     in (Map.lookup policy assets >>= Map.lookup name) == Just 1

isRequest :: TokenId -> TxOut ConwayEra -> Bool
isRequest (TokenId (AssetName name)) out = case extractCageDatum out of
    Just (RequestDatum req) -> requestToken req == OnChainTokenId (BuiltinByteString (SBS.fromShort name))
    _ -> False

foldActions :: ConwayTx -> TxIn -> [TxIn] -> IO [RequestAction]
foldActions tx stateIn inputs = do
    ix <- maybe (failFollow "state input index missing") pure (elemIndex stateIn inputs)
    let Redeemers redeemers = tx ^. witsTxL . rdmrsTxWitsL
    case Map.lookup (ConwaySpending (AsIx (fromIntegral ix))) redeemers of
        Just (Data datum, _) -> case fromBuiltinData (BuiltinData datum) of
            Just (Modify actions) -> pure actions
            _ -> failFollow "unsupported-state-spend: expected Modify"
        Nothing -> failFollow "state spending redeemer missing"

applyRequest :: IORef MPFInMemoryDB -> (TxOut ConwayEra, RequestAction) -> IO ()
applyRequest _ (_, Rejected) = pure ()
applyRequest ref (out, Update _) = case extractCageDatum out of
    Just (RequestDatum request) -> do
        let trie = mkPureTrieFromRef ref
            key = requestKey request
        case requestValue request of
            OpInsert value -> void (Trie.insert trie key value)
            OpDelete _ -> void (Trie.delete trie key)
            OpUpdate _ value -> do
                void (Trie.delete trie key)
                void (Trie.insert trie key value)
    _ -> failFollow "consumed request datum missing"

-- The generic follower supplies replay and rollback behavior. This finite
-- client sends Done at the reported tip, including an intersection at tip.
finiteClient :: Intersector BlockPoint Network.SlotNo Block -> [BlockPoint] -> ChainSyncClient Block BlockPoint (Network.Tip Block) IO ()
finiteClient intersector points =
    ChainSyncClient $
        pure $
            SendMsgFindIntersect
                points
                ClientStIntersect
                    { recvMsgIntersectFound = \point tip -> ChainSyncClient $ do
                        follower <- intersectFound intersector point
                        pure (if point == Network.getTipPoint tip then SendMsgDone () else next follower)
                    , recvMsgIntersectNotFound = \_ -> ChainSyncClient $ do
                        (another, starts) <- intersectNotFound intersector
                        runChainSyncClient (finiteClient another starts)
                    }
  where
    next follower =
        SendMsgRequestNext
            (pure ())
            ClientStNext
                { recvMsgRollForward = \block tip -> ChainSyncClient $ do
                    let slot = case tip of
                            Network.TipGenesis -> 0
                            Network.Tip s _ _ -> s
                    following <- rollForward follower block slot
                    pure (if Network.blockPoint block == Network.getTipPoint tip then SendMsgDone () else next following)
                , recvMsgRollBackward = \point _ -> ChainSyncClient $ do
                    result <- rollBackward follower point
                    case result of
                        Progress following -> pure (next following)
                        Rewind starts another -> runChainSyncClient (finiteClient another starts)
                        Reset another -> runChainSyncClient (finiteClient another [Network.genesisPoint])
                }
