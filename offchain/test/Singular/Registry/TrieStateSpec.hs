{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Preservation witnesses from the current MPF producer, before the
capability exists. These are not evidence of the new interface or coverage.
-}
module Singular.Registry.TrieStateSpec (spec, produced, edgeCases) where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import MPF.Backend.Pure (MPFInMemoryDB (..))
import Singular.CLI.Proof (Leaf (..), authenticatedLeaf, rootOfDb)
import Singular.Registry.Deployment (loadMirror, saveMirror)
import Singular.Registry.Ledger
    ( AssetName (..)
    , Root (..)
    , TokenId (..)
    )
import Singular.Registry.Trie (Trie (..), TrieManager (..))
import Singular.Registry.Trie.Pure (provesAbsent, provesMember)
import Singular.Registry.Trie.PureManager (mkPureTrieManagerFrom)
import Singular.Registry.TxBuilder.Internal (walkEdge)
import Singular.Registry.Types (ProofStep)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn)

-- The seven admitted moves, in the frozen model's leaf vocabulary.
edgeCases :: [(String, Integer, [Integer], Leaf)]
edgeCases =
    [ ("insert absent", 0, [], Absent)
    , ("insert active", 1, [], Active)
    , ("update active", 2, [0], Active)
    , ("update terminal", 3, [1], Terminal)
    , ("delete absent", 4, [0], Unknown)
    , ("delete active", 5, [1], Unknown)
    , ("witness terminal", 6, [1, 3], Terminal)
    ]

walkReport
    :: (Monad m)
    => Trie m -> [(ByteString, Integer)] -> m (Root, [[ProofStep]])
walkReport trie moves = do
    proofs <- mapM (uncurry (walkEdge trie)) moves
    r <- getRoot trie
    pure (r, proofs)

{- | Both the nodes and comparisons come from the existing edge/proof
producer. No root or proof is entered as a fixture constant.
-}
produced
    :: TokenId
    -> [(ByteString, Integer)]
    -> IO (MPFInMemoryDB, Root, [[ProofStep]])
produced token moves = do
    (manager, dump) <- mkPureTrieManagerFrom Map.empty
    createTrie manager token
    (r, proofs) <- withTrie manager token (`walkReport` moves)
    nodes <- dump
    case Map.lookup token nodes of
        Nothing -> fail "the actual producer lost its registry"
        Just db -> pure (db, r, proofs)

leafBytes :: Leaf -> ByteString
leafBytes Absent = BS.singleton 0
leafBytes Active = BS.singleton 1
leafBytes Terminal = BS.singleton 2
leafBytes Unknown = ""

spec :: Spec
spec = describe "TrieState preservation oracle (existing IO producer)" $ do
    forM_
        [TokenId (AssetName "registry-a"), TokenId (AssetName "registry-b")]
        $ \token ->
            forM_ ["key-a", "key-b"] $ \key ->
                forM_ edgeCases $ \(name, edge, setup, want) -> do
                    let moves = ("neighbour", 1) : [(key, e) | e <- setup] <> [(key, edge)]
                        label = show token <> "/" <> show key <> "/" <> name
                    it
                        ( label
                            <> ": authenticates the resulting leaf and excludes an unbound key"
                        )
                        $ do
                            fault <- lookupEnv "SINGULAR_TRIESTATE_CONTROL"
                            let actualMoves = if fault == Just "omit-edge" then init moves else moves
                            (db, Root root, proofs) <- produced token actualMoves
                            length proofs `shouldBe` length moves
                            queried <- case fault of
                                Just "swap-key" -> pure "neighbour"
                                _ -> pure key
                            selected <- case fault of
                                Just "swap-root" -> do
                                    (_, Root other, _) <- produced token [("other-root", 1)]
                                    pure other
                                _ -> pure root
                            authenticatedLeaf db queried selected `shouldReturn` Right want
                            if want == Unknown
                                then provesAbsent db root key `shouldBe` True
                                else provesMember db root key (leafBytes want) `shouldBe` True
                            provesAbsent db root "never-bound" `shouldBe` True
                            provesMember db root key "wrong-leaf" `shouldBe` False
                            provesMember db root "never-bound" (leafBytes want) `shouldBe` False
                            rootOfDb db{mpfInMemoryKV = Map.empty} `shouldReturn` root
                            authenticatedLeaf db{mpfInMemoryKV = Map.empty} key root
                                `shouldReturn` Right want
                    it
                        ( label
                            <> ": returns ordered production proofs and discards speculation"
                        )
                        $ do
                            let beforeMoves = init moves
                            (before, beforeRoot, _) <- produced token beforeMoves
                            (_, expectedRoot, expectedProofs) <- produced token moves
                            (manager, dump) <- mkPureTrieManagerFrom (Map.singleton token before)
                            fault <- lookupEnv "SINGULAR_TRIESTATE_CONTROL"
                            (seenRoot, seenProofs) <-
                                if fault == Just "commit-speculation"
                                    then withTrie manager token (\t -> walkReport t [(key, edge)])
                                    else
                                        withSpeculativeTrie manager token (\t -> walkReport t [(key, edge)])
                            seenRoot `shouldBe` expectedRoot
                            seenProofs `shouldBe` [last expectedProofs]
                            withTrie manager token getRoot `shouldReturn` beforeRoot
                            dump `shouldReturn` Map.singleton token before
    it
        "round trips two actual registries without changing saved mirror bytes"
        $ withSystemTempDirectory "trie-state-mirror"
        $ \dir -> do
            let a = TokenId (AssetName "registry-a")
                b = TokenId (AssetName "registry-b")
                path = dir </> "deployment.json"
            (one, _, _) <- produced a [("first", 1), ("second", 0)]
            (two, _, _) <- produced b [("first", 1), ("first", 3), ("second", 1)]
            let nodes = Map.fromList [(a, one), (b, two)]
            saveMirror path nodes
            -- mirrorPathFor is beside the manifest and does not need a
            -- fabricated deployment/configuration or ledger acceptance.
            bytes <- BS.readFile (dir </> "deployment.mirror.json")
            back <- loadMirror path
            back `shouldBe` nodes
            saveMirror path back
            BS.readFile (dir </> "deployment.mirror.json") `shouldReturn` bytes
