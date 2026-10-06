{- | Component evidence for rebuilding the mutable fold trie from a checked
snapshot. Public history and ledger refusal are exercised by the attach demo.
-}
module Conformance.Support.FoldHistory (spec) where

import Cardano.Ledger.Api.Tx (mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body (feeTxBodyL, mkBasicTxBody)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import Conformance.Cli.FoldHistory
    ( materializeFoldTrie
    , publicFoldTrie
    )
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Lens.Micro ((&), (.~))
import Singular.Registry.Ledger
    ( AssetName (..)
    , Coin (..)
    , TokenId (..)
    )
import Singular.Registry.LedgerProvider qualified as LP
import Singular.Registry.Trie (TrieManager (..))
import Singular.Registry.Trie qualified as Trie
import Singular.Registry.Trie.PureManager (mkPureTrieManagerFrom)
import Singular.Registry.TrieState qualified as TS
import Singular.Registry.TrieState.Fixture
    ( fixtureSnapshot
    , fixtureStore
    )
import Singular.Registry.TxBuilder.Internal (walkEdge)
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldReturn
    )

token :: TokenId
token = TokenId (AssetName "registry")

-- | Fixture references are actual ledger transaction identifiers, not roots.
named :: Integer -> TxIn
named n =
    TxIn
        (txIdTx (mkBasicTx (mkBasicTxBody & feeTxBodyL .~ Coin n) :: ConwayTx))
        (TxIx 0)

{- | The roots and nodes are produced by the unchanged MPF edge engine.
The fixture adapter checks the entire recorded walk from an empty trie.
-}
snapshotFor :: [(ByteString, Integer)] -> IO (TS.TrieSnapshot IO)
snapshotFor moves = do
    (manager, dump) <- mkPureTrieManagerFrom Map.empty
    createTrie manager token
    start <- withTrie manager token Trie.getRoot
    end <- withTrie manager token $ \trie -> do
        mapM_ (uncurry (walkEdge trie)) moves
        Trie.getRoot trie
    nodes <- dump
    let TokenId name = token
        who = TS.RegistryIdentity (TS.StatePolicyId (BS.replicate 28 7)) name
        selection output =
            TS.TrieSelection
                who
                (TS.StatePoint (TS.SessionId "component") TS.Unbound output)
        before = selection (named 1) start
        after = selection (named 2) end
        folds = case NE.nonEmpty moves of
            Nothing -> []
            Just edges -> [TS.ObservedFold before after edges]
    db <-
        maybe
            (fail "the MPF producer lost its trie")
            pure
            (Map.lookup token nodes)
    either (fail . show) pure $
        fixtureSnapshot
            ( fixtureStore
                [(after, Just (TS.CreateRecord who (named 1)), folds, db)]
            )
            after

setup :: [(ByteString, Integer)]
setup =
    [ ("absent", 0)
    , ("held", 1)
    , ("gone", 1)
    , ("gone", 3)
    , ("deleted", 1)
    , ("deleted", 5)
    ]

keys :: Set.Set ByteString
keys = Set.fromList ["absent", "held", "gone", "deleted", "never"]

rebuilt :: TS.TrieSnapshot IO -> IO (TrieManager IO)
rebuilt snapshot = either (fail . show) pure =<< materializeFoldTrie snapshot keys

-- | Only history may be read; any unrelated read has a named failure.
refusingSession :: IORef Int -> LP.Session () IO
refusingSession calls =
    LP.Session
        { LP.sessionNetwork = LP.Network 42
        , LP.sessionId = TS.SessionId "component"
        , LP.sessionBinding = TS.Unbound
        , LP.sessionTracer = mempty
        , LP.sessionEvaluated = \_ -> pure ()
        , LP.outputs = const unread
        , LP.protocolParameters = unread
        , LP.tipObservation = unread
        , LP.networkTime = unread
        , LP.scriptRegistered = const unread
        , LP.history = \_ _ -> do
            modifyIORef' calls (+ 1)
            pure (Left (LP.HistoryOrderMismatch 1 0))
        }
  where
    unread :: IO (Either LP.ReadFailure a)
    unread =
        pure
            (Left (LP.BackendReadFailure "this component supplies only history"))

spec :: Spec
spec = describe "A fold trie is rebuilt from authenticated current leaves" $ do
    it
        "preserves Absent, Active, Terminal and proven Unknown under the selected root"
        $ do
            snapshot <- snapshotFor setup
            manager <- rebuilt snapshot
            (producer, _) <- mkPureTrieManagerFrom Map.empty
            createTrie producer token
            _ <- withTrie producer token $ \trie -> mapM (uncurry (walkEdge trie)) setup
            forM_
                [ ("absent", TS.Absent)
                , ("held", TS.Active)
                , ("gone", TS.Terminal)
                , ("deleted", TS.Unknown)
                , ("never", TS.Unknown)
                ]
                $ \(key, leaf) -> do
                    TS.leafAt snapshot key `shouldReturn` Right leaf
                    expected <- withTrie producer token $ \trie -> Trie.getProofSteps trie key
                    withTrie manager token (`Trie.getProofSteps` key)
                        `shouldReturn` expected
            withTrie manager token Trie.getRoot
                `shouldReturn` TS.trieRoot snapshot
    it
        "returns the same ordered proofs and root for all seven edges, discarding speculation"
        $ do
            snapshot <- snapshotFor setup
            manager <- rebuilt snapshot
            let moves =
                    [ ("new-absent", 0)
                    , ("new-active", 1)
                    , ("absent", 2)
                    , ("held", 3)
                    , ("new-absent", 4)
                    , ("new-active", 5)
                    , ("gone", 6)
                    ]
            expected <-
                either (fail . show) pure
                    =<< TS.speculateEdges snapshot (NE.fromList moves)
            actual <- withSpeculativeTrie manager token $ \trie -> do
                proofs <- mapM (uncurry (walkEdge trie)) moves
                root <- Trie.getRoot trie
                pure (root, proofs)
            actual `shouldBe` (TS.walkRoot expected, TS.walkProofs expected)
            withTrie manager token Trie.getRoot
                `shouldReturn` TS.trieRoot snapshot
    it
        "refuses an incomplete key census with the rebuilt and selected roots"
        $ do
            snapshot <- snapshotFor setup
            answer <- materializeFoldTrie snapshot (Set.delete "held" keys)
            partial <- snapshotFor [(k, e) | (k, e) <- setup, k /= "held"]
            case answer of
                Left why ->
                    why
                        `shouldBe` TS.RootDoesNotChain
                            (TS.trieIdentity snapshot)
                            Nothing
                            (TS.RootsPart (TS.trieRoot partial) (TS.trieRoot snapshot))
                Right _ -> expectationFailure "an incomplete census exposed a mutable trie"
    it "materializes the empty create snapshot without inventing a leaf" $ do
        snapshot <- snapshotFor []
        manager <-
            either (fail . show) pure =<< materializeFoldTrie snapshot Set.empty
        withTrie manager token Trie.getRoot
            `shouldReturn` TS.trieRoot snapshot
    it "rebuilds fresh state after a previous mutable trie has changed" $ do
        snapshot <- snapshotFor setup
        first <- rebuilt snapshot
        _ <- withTrie first token $ \trie -> walkEdge trie "held" 3
        second <- rebuilt snapshot
        withTrie second token Trie.getRoot `shouldReturn` TS.trieRoot snapshot
    it
        "passes an incomplete public-history refusal through without exposing a trie"
        $ do
            snapshot <- snapshotFor setup
            calls <- newIORef 0
            let chosen =
                    TS.TrieSelection
                        (TS.trieIdentity snapshot)
                        (TS.triePoint snapshot)
                        (TS.trieRoot snapshot)
            answer <- publicFoldTrie (refusingSession calls) chosen
            case answer of
                Left why ->
                    why
                        `shouldBe` TS.HistoryIncomplete
                            (TS.trieIdentity snapshot)
                            Nothing
                            (TS.ProviderHistoryFailure (LP.HistoryOrderMismatch 1 0))
                Right _ -> expectationFailure "refused history exposed a mutable trie"
            readIORef calls `shouldReturn` 1
    it "refuses another session's selection before reading history" $ do
        snapshot <- snapshotFor setup
        calls <- newIORef 0
        let chosen =
                TS.TrieSelection
                    (TS.trieIdentity snapshot)
                    (TS.triePoint snapshot)
                    (TS.trieRoot snapshot)
            session = (refusingSession calls){LP.sessionId = TS.SessionId "other"}
        answer <- publicFoldTrie session chosen
        case answer of
            Left why ->
                why
                    `shouldBe` TS.StaleState (TS.trieIdentity snapshot) Nothing TS.NoSelection
            Right _ ->
                expectationFailure
                    "another session's selection exposed a mutable trie"
        readIORef calls `shouldReturn` 0
