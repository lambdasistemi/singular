{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

{- |
Module      : Singular.Registry.E2E.FollowerSpec
Description : A second machine rebuilds and folds through a real node
License     : Apache-2.0
-}
module Singular.Registry.E2E.FollowerSpec (spec) where

import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body (inputsTxBodyL)
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Plutus.Data (Data (..))
import Cardano.Ledger.TxIn (TxIn (..))
import ChainFollower (Follower (..), Intersector (..), ProgressOrRewind (..))
import Control.Concurrent (threadDelay)
import Control.Monad (forM_, void, when)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (elemIndex)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Lens.Micro ((^.))
import Ouroboros.Network.Block qualified as Network
import PlutusTx (fromBuiltinData)
import Singular.Registry.E2E.Constructors (constructorSet, constructorTag)
import System.Directory (removeFile)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (fileMode, getFileStatus)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy, shouldThrow)

import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Node.Client.E2E.Setup (genesisAddr)
import PlutusTx.Builtins.Internal (BuiltinByteString (..), BuiltinData (..))
import Singular.Registry.Blueprint (extractCompiledCode, loadBlueprint)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Deployment
import Singular.Registry.E2E.CageSpec (submitInsertRequest, submitWithGenesis, withBootedCageAtSocket)
import Singular.Registry.Follower
import Singular.Registry.Ledger (AssetName (..), Coin (..), Root (..), TokenId (..))
import Singular.Registry.Provider qualified as Registry
import Singular.Registry.Trie (TrieManager (..))
import Singular.Registry.Trie qualified as Trie
import Singular.Registry.Trie.PureManager (mkPureTrieManagerFrom)
import Singular.Registry.TxBuilder.Internal (cageAddrFromCfg, cagePolicyIdFromCfg, extractCageDatum, findStateUtxo, requestAddrFromCfg, scriptHashBytes)
import Singular.Registry.TxBuilder.Reject (rejectRequestsImpl)
import Singular.Registry.TxBuilder.Request (requestDeleteImpl, requestUpdateImpl)
import Singular.Registry.TxBuilder.Update (updateTokenImpl)
import Singular.Registry.Types

spec :: Spec
spec = describe "registry follower" $ do
    recoverySpec
    armsSpec

recoverySpec :: Spec
recoverySpec = it "rebuilds from bootstrap, resumes pending requests, refuses corruption and folds again" $ do
    path <- lookupEnv "REGISTRY_BLUEPRINT" >>= maybe (fail "REGISTRY_BLUEPRINT is required for follower E2E") pure
    bp <- loadBlueprint path >>= either fail pure
    let script title = maybe (fail ("missing script " <> title)) pure (extractCompiledCode (T.pack title) bp)
    stateBytes <- script "state.state"
    requestBytes <- script "request.request"
    consumerBytes <- script "consumer.consumer"
    withSystemTempDirectory "follower" $ \dir ->
        withBootedCageAtSocket (\cfg -> cfg{defaultProcessTime = 300000}) stateBytes requestBytes consumerBytes $ \socket cfg prov submit _ tok -> do
            let manifest = dir </> "preprod.json"
                state = do
                    outputs <- Registry.queryUTxOs prov (cageAddrFromCfg cfg Testnet)
                    maybe (fail "registry state missing") pure (findStateUtxo (cagePolicyIdFromCfg cfg) tok outputs)
            boot <- state
            let seed = cageSeed cfg
                tokenName = case tok of TokenId (AssetName name) -> SBS.fromShort name
                dep =
                    Deployment
                        { depRelease = "follower-e2e"
                        , depLeanRevision = "f558d0e8fc916eef494fffcef09cfe2ac5582b8e"
                        , depNetworkMagic = 42
                        , depSeedOutRef = hex (case txOutRefId seed of BuiltinByteString b -> b) <> "#" <> T.pack (show (txOutRefIdx seed))
                        , depCageToken = hex tokenName
                        , depStatePolicy = hex (scriptHashBytes (cfgScriptHash cfg))
                        , depRequestHash = ""
                        , depApplicationHash = ""
                        , depRepresentativePolicy = ""
                        , depConsumerHash = ""
                        , depProcessTime = defaultProcessTime cfg
                        , depRetractTime = defaultRetractTime cfg
                        , depTip = 1000000
                        , depReferenceScripts = []
                        , depBootstrapTxs = [T.takeWhile (/= '#') (renderOutRef (fst boot))]
                        }
            writeDeployment manifest dep
            (machineA, dumpA) <- mkPureTrieManagerFrom Map.empty
            createTrie machineA tok
            let queue key = void (submitInsertRequest cfg prov submit tok key ("value-" <> key))
                foldKeys manager keys = do
                    tx <- updateTokenImpl cfg prov manager tok genesisAddr
                    void (submitWithGenesis submit tx)
                    forM_ keys $ \key -> withTrie manager tok $ \trie ->
                        void (Trie.insert trie key ("value-" <> key))
                chainRoot = do
                    (_, out) <- state
                    case extractCageDatum out of
                        Just (StateDatum st) -> pure (hex (unOnChainRoot (stateRoot st)))
                        _ -> fail "state datum missing"
            mapM_ queue ["alpha", "beta"]
            foldKeys machineA ["alpha", "beta"]
            queue "gamma"
            foldKeys machineA ["gamma"]
            dumpA >>= saveMirror manifest
            originalRoot <- chainRoot
            -- The next request predates the saved point but is consumed
            -- after it. A checkpoint carrying only the trie cannot pass.
            queue "pending"
            removeFile (mirrorPathFor manifest)
            rebuilt <- followDeployment manifest socket
            followedRoot rebuilt `shouldBe` originalRoot
            followedFolds rebuilt `shouldBe` 2
            followedResumed rebuilt `shouldBe` False
            pendingCheckpoint <- loadReplayCheckpoint manifest >>= maybe (fail "pending checkpoint missing") pure
            pendingOutput <- case cpRequests pendingCheckpoint of
                [(_, out)] -> pure out
                _ -> fail "expected one confirmed pending request"
            foldKeys machineA ["pending"]
            resumed <- followDeployment manifest socket
            followedResumed resumed `shouldBe` True
            followedFolds resumed `shouldBe` 1
            expected <- chainRoot
            followedRoot resumed `shouldBe` expected
            atTip <- followDeployment manifest socket
            followedFolds atTip `shouldBe` 0
            followedResumed atTip `shouldBe` True
            status <- getFileStatus (mirrorPathFor manifest)
            fileMode status .&. 0o7777 `shouldBe` 0o600
            validCheckpoint <- loadReplayCheckpoint manifest >>= maybe (fail "checkpoint missing") pure
            validMirrors <- loadMirror manifest
            saveFollowedMirror manifest validCheckpoint{cpStateOutput = "00"} validMirrors
            refusesPreserving manifest "checkpoint-decode" (followDeployment manifest socket)
            saveFollowedMirror manifest validCheckpoint validMirrors
            BL.writeFile (mirrorPathFor manifest) "{broken-json"
            refusesPreserving manifest "checkpoint-decode" (followDeployment manifest socket)
            saveFollowedMirror manifest validCheckpoint validMirrors
            refusesPreserving manifest "socket-query" (followDeployment manifest (dir </> "missing.sock"))
            let queryControl query dep' sock = (nodeSource dep' sock){currentOutputs = query}
            refusesPreserving manifest "chain-moved" (followDeploymentWith (queryControl (const (pure (Just Map.empty)))) manifest socket)
            refusesPreserving manifest "node-disconnected-before-root-verification" (followDeploymentWith (queryControl (const (pure Nothing))) manifest socket)
            refusesPreserving manifest "socket-query" (followDeploymentWith (queryControl (const (ioError (userError "seeded query failure")))) manifest socket)
            forM_ [False, True] $ \rollback -> do
                -- A request from the discarded branch must not survive reset.
                -- Its CBOR is genuine; its reference belongs only to this
                -- manufactured former branch, never to the replayed chain.
                let orphan = (T.replicate 64 "f" <> "#0", pendingOutput)
                saveFollowedMirror manifest validCheckpoint{cpRequests = [orphan]} validMirrors
                let resetSource replay dep' sock =
                        let real = nodeSource dep' sock
                         in real
                                { followChain = \intersector points -> do
                                    points `shouldSatisfy` (/= [Network.genesisPoint])
                                    (next, starts) <-
                                        if rollback
                                            then case points of
                                                [point] -> do
                                                    follower <- intersectFound intersector point
                                                    result <- rollBackward follower Network.genesisPoint
                                                    case result of
                                                        Reset next -> pure (next, [Network.genesisPoint])
                                                        _ -> fail "earlier rollback did not request reset"
                                                _ -> fail "expected one saved point"
                                            else intersectNotFound intersector
                                    starts `shouldBe` [Network.genesisPoint]
                                    when replay (followChain real next starts)
                                }
                -- Observe discard before a later node rollback can reset a
                -- second time and mask a disabled intersect/rollback arm.
                refusesPreserving manifest "bootstrap-not-found" (followDeploymentWith (resetSource False) manifest socket)
                reset <- followDeploymentWith (resetSource True) manifest socket
                followedResumed reset `shouldBe` False
                followedFolds reset `shouldBe` 3
                followedRoot reset `shouldBe` expected
                restored <- loadReplayCheckpoint manifest >>= maybe (fail "reset checkpoint missing") pure
                cpRequests restored `shouldBe` cpRequests validCheckpoint
                putStrLn ("reset-discarded-trie-state-pending rollback=" <> show rollback)
            -- Replace the trie while retaining the real checkpoint. The
            -- refusal must preserve these bytes, never publish a false root.
            checkpoint <- loadReplayCheckpoint manifest >>= maybe (fail "missing replay checkpoint") pure
            (empty, dumpEmpty) <- mkPureTrieManagerFrom Map.empty
            createTrie empty tok
            dumpEmpty >>= saveFollowedMirror manifest checkpoint
            badBytes <- BS.readFile (mirrorPathFor manifest)
            followDeployment manifest socket `shouldThrow` (\e -> "root-mismatch" `T.isInfixOf` T.pack (show (e :: IOError)))
            unchanged <- BS.readFile (mirrorPathFor manifest)
            unchanged `shouldBe` badBytes
            let parts =
                    CageParts
                        { partsStateBytes = cageScriptBytes cfg
                        , partsRequestBytes = requestScriptBytes cfg
                        , partsRepPolicy = cfgRepPolicy cfg
                        , partsConsumerPin = cfgConsumerPin cfg
                        , partsConsumerScript = cfgConsumerScript cfg
                        }
            void (attachRebuilding prov dep parts manifest socket)
            rebuiltBytes <- BS.readFile (mirrorPathFor manifest)
            rebuiltBytes `shouldSatisfy` (/= badBytes)
            recoveredRoot <- followDeployment manifest socket
            followedRoot recoveredRoot `shouldBe` expected
            recovered <- loadMirror manifest
            (machineB, dumpB) <- mkPureTrieManagerFrom recovered
            queue "delta"
            foldKeys machineB ["delta"]
            Root local <- withTrie machineB tok Trie.getRoot
            finalRoot <- chainRoot
            hex local `shouldBe` finalRoot
            finalRoot `shouldSatisfy` (/= originalRoot)
            dumpB >>= saveMirror manifest
            loadReplayCheckpoint manifest >>= (`shouldBe` Nothing)
            replayed <- followDeployment manifest socket
            followedResumed replayed `shouldBe` False
            followedRoot replayed `shouldBe` finalRoot
  where
    hex :: ByteString -> T.Text
    hex = T.pack . BC.unpack . B16.encode

-- Coverage is counted only after a fold's state output is reported by the node
-- and the follower has independently reproduced its root. Tags come from
-- decoded consumed request datums and the submitted, confirmed redeemer.
armsSpec :: Spec
armsSpec = it "confirms and replays every request/action constructor" $ do
    path <- lookupEnv "REGISTRY_BLUEPRINT" >>= maybe (fail "REGISTRY_BLUEPRINT is required for follower E2E") pure
    bp <- loadBlueprint path >>= either fail pure
    let script title = maybe (fail ("missing script " <> title)) pure (extractCompiledCode (T.pack title) bp)
    stateBytes <- script "state.state"
    requestBytes <- script "request.request"
    consumerBytes <- script "consumer.consumer"
    withSystemTempDirectory "follower" $ \dir ->
        withBootedCageAtSocket (\cfg -> cfg{defaultProcessTime = 30000, defaultRetractTime = 1000}) stateBytes requestBytes consumerBytes $ \socket cfg prov submit _ tok -> do
            let manifest = dir </> "preprod.json"
                state = do
                    outputs <- Registry.queryUTxOs prov (cageAddrFromCfg cfg Testnet)
                    maybe (fail "registry state missing") pure (findStateUtxo (cagePolicyIdFromCfg cfg) tok outputs)
            boot <- state
            let seed = cageSeed cfg
                tokenName = case tok of TokenId (AssetName name) -> SBS.fromShort name
                dep =
                    Deployment
                        { depRelease = "follower-e2e"
                        , depLeanRevision = "f558d0e8fc916eef494fffcef09cfe2ac5582b8e"
                        , depNetworkMagic = 42
                        , depSeedOutRef = hex (case txOutRefId seed of BuiltinByteString b -> b) <> "#" <> T.pack (show (txOutRefIdx seed))
                        , depCageToken = hex tokenName
                        , depStatePolicy = hex (scriptHashBytes (cfgScriptHash cfg))
                        , depRequestHash = ""
                        , depApplicationHash = ""
                        , depRepresentativePolicy = ""
                        , depConsumerHash = ""
                        , depProcessTime = defaultProcessTime cfg
                        , depRetractTime = defaultRetractTime cfg
                        , depTip = 1000000
                        , depReferenceScripts = []
                        , depBootstrapTxs = [T.takeWhile (/= '#') (renderOutRef (fst boot))]
                        }
            writeDeployment manifest dep

            seenOps <- newIORef Set.empty
            seenActions <- newIORef Set.empty
            (manager, _) <- mkPureTrieManagerFrom Map.empty
            createTrie manager tok
            let confirm build = do
                    pending <- Registry.queryUTxOs prov (requestAddrFromCfg cfg tok Testnet)
                    (oldStateIn, _) <- state
                    tx <- build >>= submitWithGenesis submit
                    (stateIn, stateOut) <- state
                    stateIn `shouldSatisfy` (\(TxIn tid _) -> tid == txIdTx tx)
                    let inputs = Set.toAscList (tx ^. bodyTxL . inputsTxBodyL)
                        ops = [requestValue r | i <- inputs, Just out <- [lookup i pending], Just (RequestDatum r) <- [extractCageDatum out]]
                        Redeemers redeemers = tx ^. witsTxL . rdmrsTxWitsL
                    stateIndex <- maybe (fail "state input missing from confirmed fold") pure (elemIndex oldStateIn inputs)
                    actions <- case Map.lookup (ConwaySpending (AsIx (fromIntegral stateIndex))) redeemers of
                        Just (Data d, _) | Just (Modify as) <- fromBuiltinData (BuiltinData d) -> pure as
                        _ -> fail "confirmed state input has no Modify redeemer"
                    length actions `shouldBe` length ops
                    actions `shouldSatisfy` (not . null)
                    replayed <- followDeployment manifest socket
                    Just (StateDatum st) <- pure (extractCageDatum stateOut)
                    followedRoot replayed `shouldBe` hex (unOnChainRoot (stateRoot st))
                    followedFolds replayed `shouldBe` 1
                    modifyIORef' seenOps (Set.union (Set.fromList ([$(constructorTag ''OnChainOperation) op | (op, Update _) <- zip ops actions])))
                    modifyIORef' seenActions (Set.union (Set.fromList (map $(constructorTag ''RequestAction) actions)))
                    putStrLn ("confirmed-fold constructors=" <> show (map $(constructorTag ''RequestAction) actions, map $(constructorTag ''OnChainOperation) ops))
                foldNow = confirm (updateTokenImpl cfg prov manager tok genesisAddr)
            void (submitInsertRequest cfg prov submit tok "arm" "before")
            foldNow
            withTrie manager tok $ \trie -> void (Trie.insert trie "arm" "before")
            requestUpdateImpl cfg prov (Coin 1000000) tok "arm" "before" "after" genesisAddr >>= void . submitWithGenesis submit
            foldNow
            withTrie manager tok $ \trie -> do
                void (Trie.delete trie "arm")
                void (Trie.insert trie "arm" "after")
            requestDeleteImpl cfg prov (Coin 1000000) tok "arm" "after" genesisAddr >>= void . submitWithGenesis submit
            foldNow
            withTrie manager tok $ \trie -> void (Trie.delete trie "arm")
            void (submitInsertRequest cfg prov submit tok "rejected" "must-not-appear")
            threadDelay 33000000
            confirm (rejectRequestsImpl cfg prov tok genesisAddr)
            readIORef seenOps >>= (`shouldBe` Set.fromList $(constructorSet ''OnChainOperation))
            readIORef seenActions >>= (`shouldBe` Set.fromList $(constructorSet ''RequestAction))
  where
    hex = T.pack . BC.unpack . B16.encode

refusesPreserving :: FilePath -> T.Text -> IO a -> IO ()
refusesPreserving manifest reason action = do
    before <- BS.readFile (mirrorPathFor manifest)
    action `shouldThrow` (\e -> reason `T.isInfixOf` T.pack (show (e :: IOError)))
    after <- BS.readFile (mirrorPathFor manifest)
    after `shouldBe` before
    putStrLn ("refused-preserving-mirror: " <> T.unpack reason)
