{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.E2E.FollowerSpec
Description : A second machine rebuilds and folds through a real node
License     : Apache-2.0
-}
module Singular.Registry.E2E.FollowerSpec (spec) where

import Control.Monad (forM_, void)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import System.Directory (removeFile)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy, shouldThrow)

import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Node.Client.E2E.Setup (genesisAddr)
import PlutusTx.Builtins.Internal (BuiltinByteString (..))
import Singular.Registry.Blueprint (extractCompiledCode, loadBlueprint)
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Deployment
import Singular.Registry.E2E.CageSpec (submitInsertRequest, submitWithGenesis, withBootedCageAtSocket)
import Singular.Registry.Follower
import Singular.Registry.Ledger (AssetName (..), Root (..), TokenId (..))
import Singular.Registry.Provider qualified as Registry
import Singular.Registry.Trie (TrieManager (..))
import Singular.Registry.Trie qualified as Trie
import Singular.Registry.Trie.PureManager (mkPureTrieManagerFrom)
import Singular.Registry.TxBuilder.Internal (cageAddrFromCfg, cagePolicyIdFromCfg, extractCageDatum, findStateUtxo, scriptHashBytes)
import Singular.Registry.TxBuilder.Update (updateTokenImpl)
import Singular.Registry.Types

spec :: Spec
spec = describe "registry follower" $ it "rebuilds from bootstrap, resumes pending requests, refuses corruption and folds again" $ do
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
            foldKeys machineA ["pending"]
            resumed <- followDeployment manifest socket
            followedResumed resumed `shouldBe` True
            followedFolds resumed `shouldBe` 1
            expected <- chainRoot
            followedRoot resumed `shouldBe` expected
            atTip <- followDeployment manifest socket
            followedFolds atTip `shouldBe` 0
            followedResumed atTip `shouldBe` True
            -- Replace the trie while retaining the real checkpoint. The
            -- refusal must preserve these bytes, never publish a false root.
            checkpoint <- loadReplayCheckpoint manifest >>= maybe (fail "missing replay checkpoint") pure
            (empty, dumpEmpty) <- mkPureTrieManagerFrom Map.empty
            createTrie empty tok
            dumpEmpty >>= saveFollowedMirror manifest checkpoint
            badBytes <- BL.readFile (mirrorPathFor manifest)
            followDeployment manifest socket `shouldThrow` (\e -> "root-mismatch" `T.isInfixOf` T.pack (show (e :: IOError)))
            unchanged <- BL.readFile (mirrorPathFor manifest)
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
            rebuiltBytes <- BL.readFile (mirrorPathFor manifest)
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
