-- | The backend's premise reads a key's leaf only from proven tree nodes.
module Conformance.Support.CliProof (spec) where

import Conformance.Cli.Proof (Leaf (..), provenLeaf)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import MPF.Backend.Pure (MPFInMemoryDB (..))
import Singular.Registry.Ledger
    ( AssetName (..)
    , Root (..)
    , TokenId (..)
    )
import Singular.Registry.Trie (Trie (..), TrieManager (..))
import Singular.Registry.Trie.PureManager (mkPureTrieManagerFrom)
import Singular.Registry.TxBuilder.Internal (leafActive, leafTerminal)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

token :: TokenId
token = TokenId (AssetName "registry")

-- | A saved trie holding one Active and one Terminal key, and its root.
savedTrie :: IO (MPFInMemoryDB, ByteString)
savedTrie = do
    (tm, dump) <- mkPureTrieManagerFrom Map.empty
    createTrie tm token
    Root root <- withTrie tm token $ \t -> do
        _ <- insert t (BC.pack "held") leafActive
        _ <- insert t (BC.pack "other") leafActive
        _ <- insert t (BC.pack "gone") leafTerminal
        getRoot t
    saved <- dump
    case Map.lookup token saved of
        Just db -> pure (db, root)
        Nothing -> fail "the saved trie holds no tree for the token"

-- | Change one byte of a value.
flipped :: ByteString -> ByteString
flipped bs = case BS.uncons bs of
    Just (b, rest) -> BS.cons (b + 1) rest
    Nothing -> BS.singleton 1

spec :: Spec
spec = describe
    "The backend's premise reads a key's leaf only from proven tree nodes"
    $ do
        it
            "proves Active, Terminal, and a key bound to nothing, against the chain's root"
            $ do
                (db, root) <- savedTrie
                provenLeaf db (BC.pack "held") root >>= (`shouldBe` Right Active)
                provenLeaf db (BC.pack "gone") root >>= (`shouldBe` Right Terminal)
                provenLeaf db (BC.pack "nobody") root >>= (`shouldBe` Right Unknown)
        it "answers the same whatever the key index beside the nodes says" $ do
            (db, root) <- savedTrie
            let emptied = db{mpfInMemoryKV = Map.empty}
                altered = db{mpfInMemoryKV = Map.map flipped (mpfInMemoryKV db)}
            provenLeaf emptied (BC.pack "held") root >>= (`shouldBe` Right Active)
            provenLeaf altered (BC.pack "held") root >>= (`shouldBe` Right Active)
            provenLeaf emptied (BC.pack "nobody") root
                >>= (`shouldBe` Right Unknown)
        it "answers nothing against another root" $ do
            (db, root) <- savedTrie
            provenLeaf db (BC.pack "held") (flipped root)
                >>= (`shouldSatisfy` isLeft)
        it
            "never proves another leaf from missing or altered tree nodes, and some damage leaves no answer"
            $ do
                (db, root) <- savedTrie
                let nodes = Map.keys (mpfInMemoryMPF db)
                    without k = db{mpfInMemoryMPF = Map.delete k (mpfInMemoryMPF db)}
                    altered k = db{mpfInMemoryMPF = Map.adjust flipped k (mpfInMemoryMPF db)}
                missing <-
                    mapM (\k -> provenLeaf (without k) (BC.pack "held") root) nodes
                changed <-
                    mapM (\k -> provenLeaf (altered k) (BC.pack "held") root) nodes
                nodes `shouldSatisfy` (not . null)
                missing `shouldSatisfy` all (\r -> r == Right Active || isLeft r)
                changed `shouldSatisfy` all (\r -> r == Right Active || isLeft r)
                missing `shouldSatisfy` any isLeft
                changed `shouldSatisfy` any isLeft
