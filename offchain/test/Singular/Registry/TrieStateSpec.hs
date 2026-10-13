{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Snapshot preservation against the unchanged mutable MPF producer.
These component witnesses establish roots, proofs, leaves and compatibility
boundaries; ledger coverage comes from the packaged connected journeys.
-}
module Singular.Registry.TrieStateSpec (spec, produced, edgeCases) where

import Cardano.Ledger.TxIn (TxId, TxIn (..))
import Control.Exception
    ( SomeException
    , displayException
    , evaluate
    , try
    )
import Control.Monad (forM_, void)
import Control.Monad.State.Strict (runState)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef (newIORef)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Map.Strict qualified as Map
import MPF.Backend.Pure (MPFInMemoryDB (..), emptyMPFInMemoryDB)
import PlutusTx.Builtins.Internal (BuiltinByteString (..))
import Singular.CLI.Proof
    ( AuthError (..)
    , Leaf (..)
    , authenticatedLeaf
    , authenticatedLeafPure
    , rootOfDb
    , rootOfDbPure
    )
import Singular.Registry.Deployment
    ( loadMirror
    , parseOutRef
    , saveMirror
    )
import Singular.Registry.Ledger
    ( AssetName (..)
    , Root (..)
    , TokenId (..)
    )
import Singular.Registry.Replay
    ( Replayed (..)
    , appliedKeys
    , replayedLineage
    )
import Singular.Registry.Trie (Trie (..), TrieManager (..))
import Singular.Registry.Trie.Pure
    ( membershipFromDb
    , mkPureTrieFromRef
    , provesAbsent
    , provesMember
    , rootFromDb
    , stateTrie
    )
import Singular.Registry.Trie.PureManager (mkPureTrieManagerFrom)
import Singular.Registry.TrieState hiding (Leaf (..))
import Singular.Registry.TrieState.Fixture
    ( fixtureSnapshot
    , fixtureStore
    )
import Singular.Registry.TxBuilder.Internal (walkEdge)
import Singular.Registry.Types
    ( OnChainRequest (..)
    , OnChainTokenId (..)
    , ProofStep
    , RequestAction (..)
    )
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldReturn
    )
import Test.QuickCheck
    ( Gen
    , chooseInt
    , elements
    , forAll
    , ioProperty
    , vectorOf
    )

-- The two admitted moves and five raw refused encodings, in the frozen model's leaf vocabulary.
edgeCases :: [(String, Integer, [Integer], Leaf)]
edgeCases =
    [ ("insert active", 1, [], Active)
    , ("update terminal", 3, [1], Terminal)
    , ("excluded insert absent", 0, [], Unknown)
    , ("excluded update active", 2, [], Unknown)
    , ("excluded delete absent", 4, [], Unknown)
    , ("excluded delete active", 5, [1], Active)
    , ("excluded witness terminal", 6, [1, 3], Terminal)
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
    it
        "preserves rootOfDb snapshot failures inside IO and leaves malformed roots lazy"
        $ do
            let token = TokenId (AssetName "root-boundary")
            (db, Root root, _) <- produced token [("key", 1), ("other", 1)]
            let damaged = db{mpfInMemoryMPF = Map.map (const BS.empty) (mpfInMemoryMPF db)}
                unavailable = error "root snapshot unavailable" :: MPFInMemoryDB
            forM_ [db, damaged, unavailable] $ \snapshot -> do
                oldDiscarded <- outcome (void (frozenRootOfDb snapshot))
                newDiscarded <- outcome (void (rootOfDb snapshot))
                newDiscarded `shouldBe` oldDiscarded
                oldForced <- outcome (frozenRootOfDb snapshot >>= evaluate)
                newForced <- outcome (rootOfDb snapshot >>= evaluate)
                newForced `shouldBe` oldForced
            outcome (void (rootOfDb unavailable))
                `shouldReturn` Left "root snapshot unavailable"
            outcome (void (rootOfDb damaged)) `shouldReturn` Right ()
            -- Forcing the returned root, rather than merely running IO, must
            -- still expose malformed nodes. This rejects an over-strict repair.
            malformed <- outcome (rootOfDb damaged >>= evaluate)
            case malformed of
                Left _ -> pure ()
                Right _ -> fail "the damaged authenticated nodes unexpectedly decoded"
            rootOfDb db `shouldReturn` root
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
                            authenticatedLeafPure db queried selected `shouldBe` Right want
                            authenticatedLeaf db queried selected `shouldReturn` Right want
                            if want == Unknown
                                then provesAbsent db root key `shouldBe` True
                                else provesMember db root key (leafBytes want) `shouldBe` True
                            provesAbsent db root "never-bound" `shouldBe` True
                            provesMember db root key "wrong-leaf" `shouldBe` False
                            provesMember db root "never-bound" (leafBytes want) `shouldBe` False
                            rootOfDbPure db{mpfInMemoryKV = Map.empty} `shouldBe` root
                            rootOfDb db{mpfInMemoryKV = Map.empty} `shouldReturn` root
                            authenticatedLeafPure db{mpfInMemoryKV = Map.empty} key root
                                `shouldBe` Right want
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
            (one, _, _) <- produced a [("first", 1), ("second", 1)]
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

    it
        "preserves generated lifecycle roots, ordered proofs and snapshot leaves against the unchanged IO producer"
        $ forAll genLifecycle
        $ \moves -> ioProperty $ do
            let token = TokenId (AssetName "generated-registry")
                ((pureRoot, pureProofs), pureDb) =
                    runState (walkReport stateTrie moves) emptyMPFInMemoryDB
                keys = Map.keys (Map.fromList moves)
                leaves = foldl applyLeaf Map.empty moves
                applyLeaf current (key, edge)
                    | edge == 1 = Map.insert key Active current
                    | edge == 3 = Map.insert key Terminal current
                    | otherwise = current
            (db, root, proofs) <- produced token moves
            pureRoot `shouldBe` root
            pureProofs `shouldBe` proofs
            pureDb `shouldBe` db
            forM_ ("never-bound" : keys) $ \key -> do
                let wanted = Right (Map.findWithDefault Unknown key leaves)
                    observed = unRoot root
                    withoutIndex = db{mpfInMemoryKV = Map.empty}
                    alteredIndex = db{mpfInMemoryKV = Map.map (const "foreign") (mpfInMemoryKV db)}
                authenticatedLeafPure db key observed `shouldBe` wanted
                frozenAuthenticatedLeaf db key observed `shouldReturn` wanted
                authenticatedLeaf db key observed `shouldReturn` wanted
                authenticatedLeafPure withoutIndex key observed `shouldBe` wanted
                authenticatedLeafPure alteredIndex key observed `shouldBe` wanted
                membershipFromDb pureDb key `shouldBe` membershipFromDb db key
                -- A foreign observed root must refuse even a proven leaf.
                authenticatedLeafPure db key (BS.replicate 32 255)
                    `shouldBe` Left (RootMismatch observed (BS.replicate 32 255))
            pure True
    it
        "preserves legacy snapshot leaf bytes and inconsistent-leaf refusal"
        $ do
            let token = TokenId (AssetName "legacy-snapshot")
            forM_ [Absent, Active, Terminal, Unknown] $ \leaf -> do
                (manager, dump) <- mkPureTrieManagerFrom Map.empty
                createTrie manager token
                Root root <- withTrie manager token $ \trie -> do
                    _ <-
                        insert
                            trie
                            "key"
                            (if leaf == Unknown then "foreign-leaf" else leafBytes leaf)
                    getRoot trie
                nodes <- dump
                let db = nodes Map.! token
                    wanted =
                        if leaf == Unknown then Left (ProofInconsistent "key") else Right leaf
                authenticatedLeafPure db "key" root `shouldBe` wanted
                frozenAuthenticatedLeaf db "key" root `shouldReturn` wanted
                authenticatedLeaf db "key" root `shouldReturn` wanted
    it
        "preserves the old IO root-failure boundary, including malformed snapshots"
        $ do
            let token = TokenId (AssetName "failure-registry")
            (db, Root root, _) <- produced token [("key", 1), ("other", 1)]
            let damaged = db{mpfInMemoryMPF = Map.map (const BS.empty) (mpfInMemoryMPF db)}
                refusedDb = error "snapshot read failed" :: MPFInMemoryDB
            forM_ [db, damaged, refusedDb] $ \snapshot -> do
                before <-
                    outcome (void (frozenAuthenticatedLeaf snapshot "key" root))
                after <- outcome (void (authenticatedLeaf snapshot "key" root))
                after `shouldBe` before
                forcedBefore <-
                    outcome (frozenAuthenticatedLeaf snapshot "key" root >>= evaluate)
                forcedAfter <-
                    outcome (authenticatedLeaf snapshot "key" root >>= evaluate)
                forcedAfter `shouldBe` forcedBefore
            outcome (authenticatedLeaf refusedDb "key" root)
                `shouldReturn` Left "snapshot read failed"
    it
        "retains missing and hidden manager exceptions and restores visibility without changing nodes"
        $ do
            let token = TokenId (AssetName "visibility-registry")
            (manager, dump) <- mkPureTrieManagerFrom Map.empty
            outcome (withTrie manager token getRoot)
                `shouldReturn` Left ("Trie not found: " <> show token)
            outcome (withSpeculativeTrie manager token getRoot)
                `shouldReturn` Left ("Trie not found: " <> show token)
            createTrie manager token
            _ <-
                withTrie manager token (\trie -> insert trie "key" (leafBytes Active))
            nodes <- dump
            hideTrie manager token
            outcome (withTrie manager token getRoot)
                `shouldReturn` Left ("Trie is hidden: " <> show token)
            outcome (withSpeculativeTrie manager token getRoot)
                `shouldReturn` Left ("Trie is hidden: " <> show token)
            dump `shouldReturn` nodes
            unhideTrie manager token
            withTrie manager token getRoot
                `shouldReturn` Root (rootOfDbPure (nodes Map.! token))
    it
        "preserves speculative action failure timing, lazy answers and state discard against the frozen IO callback"
        $ do
            let token = TokenId (AssetName "speculation-boundary")
            (before, _, _) <- produced token [("held", 1)]
            let check :: (forall m. (Monad m) => Trie m -> m ()) -> IO ()
                check action = do
                    (manager, dump) <- mkPureTrieManagerFrom (Map.singleton token before)
                    oldStage <- outcome (void (frozenSpeculation before action))
                    newStage <- outcome (void (withSpeculativeTrie manager token action))
                    newStage `shouldBe` oldStage
                    oldForced <- outcome (frozenSpeculation before action >>= evaluate)
                    newForced <-
                        outcome (withSpeculativeTrie manager token action >>= evaluate)
                    newForced `shouldBe` oldForced
                    dump `shouldReturn` Map.singleton token before
            check (\trie -> void (insert trie "new" (leafBytes Active)))
            check (\_ -> error "speculative action failed")
            check (\_ -> pure (error "lazy speculative answer"))
            check
                ( \trie ->
                    void (insert trie (error "speculative key failed") (leafBytes Active))
                )
            check
                (\trie -> void (insert trie "new" (error "speculative value failed")))
            check
                (\trie -> void (delete trie (error "speculative deletion failed")))
            check $ \trie -> do
                _ <- insert trie (error "first mutation failed") (leafBytes Active)
                error "later action failed"
            check $ \trie -> do
                _ <- insert trie "new" (leafBytes Active)
                error "action failed after mutation"
    it "reports the distinct keys applied updates named, ascending" $ do
        let updates =
                [ request "b" 1 (Update [])
                , request "a" 1 (Update [])
                , request "b" 3 (Update [])
                , request "c" 1 Rejected
                , request "a" 3 (Update [])
                , request "b" 1 (Update [])
                , request "b" 1 Rejected
                ]
        appliedKeys updates `shouldBe` ["a", "b"]
    it "reports no public lineage for a fixture snapshot" $ do
        let token = TokenId (AssetName "lineage-fixture")
            identity =
                RegistryIdentity
                    (StatePolicyId (BS.replicate 28 9))
                    (AssetName "lineage-fixture")
        (nodes, Root root, _) <- produced token [("a", 1)]
        output <-
            either fail pure $
                parseOutRef
                    "1111111111111111111111111111111111111111111111111111111111111111#0"
        let point = StatePoint (SessionId "lineage-fixture") Unbound output
            from = TrieSelection identity point (rootFromDb emptyMPFInMemoryDB)
            to = TrieSelection identity point (Root root)
            folds = [ObservedFold from to (("a", 1) :| [])]
            store =
                fixtureStore [(to, Just (CreateRecord identity output), folds, nodes)]
        case fixtureSnapshot store to :: Either TrieFailure (TrieSnapshot IO) of
            Left failure ->
                expectationFailure ("no fixture snapshot: " <> show failure)
            Right snapshot -> trieLineage snapshot `shouldBe` Nothing
    it "reports a replayed lineage as its create, folds in order and keys" $ do
        let replayed = Replayed (txOf 1) [txOf 2, txOf 3] ["a", "b"]
        replayedLineage replayed
            `shouldBe` PublicLineage
                { lineageCreate = txOf 1
                , lineageFolds = [txOf 2, txOf 3]
                , lineageKeys = ["a", "b"]
                }

-- Distinct byte keys and generated multi-key registration/retirement
-- lifecycles, with refused raw encodings inserted between admitted moves.
genLifecycle :: Gen [(ByteString, Integer)]
genLifecycle = do
    count <- chooseInt (1, 12)
    bytes <-
        vectorOf
            count
            (BS.pack <$> vectorOf 16 (fromIntegral <$> chooseInt (0, 255)))
    retirements <- vectorOf count (elements [False, True])
    excluded <- vectorOf count (elements [0, 2, 4, 5, 6])
    let keys =
            zipWith
                (BS.cons . fromIntegral)
                [0 :: Int ..]
                bytes
    pure $
        map (,1) keys
            <> zip keys excluded
            <> [(key, 3) | (key, True) <- zip keys retirements]

-- The exact b55053a2 CLI.Proof root/leaf computation, kept test-only as an
-- independent frozen-base IO boundary. It must not call the new pure API.
frozenRootOfDb :: MPFInMemoryDB -> IO ByteString
frozenRootOfDb db = do
    let token = TokenId (AssetName "")
    (manager, _) <- mkPureTrieManagerFrom (Map.singleton token db)
    Root root <- withTrie manager token getRoot
    pure root

frozenAuthenticatedLeaf
    :: MPFInMemoryDB
    -> ByteString
    -> ByteString
    -> IO (Either AuthError Leaf)
frozenAuthenticatedLeaf db key observed = do
    let token = TokenId (AssetName "")
    (manager, _) <- mkPureTrieManagerFrom (Map.singleton token db)
    Root local <- withTrie manager token getRoot
    if local /= observed
        then pure (Left (RootMismatch local observed))
        else pure $
            case [ leaf
                 | leaf <- [Absent, Active, Terminal]
                 , provesMember db observed key (leafBytes leaf)
                 ] of
                [leaf] -> Right leaf
                [] | provesAbsent db observed key -> Right Unknown
                _ -> Left (ProofInconsistent key)

-- Compare the stage at which an exception occurs as well as successful values.
-- Discard call-stack locations, which differ between base and candidate sites.
outcome :: IO a -> IO (Either String a)
outcome action = do
    result <- try action
    pure $ case result of
        Left (exception :: SomeException) -> Left (takeWhile (/= '\n') (displayException exception))
        Right value -> Right value

-- The b55053a2 successful-lookup speculation implementation. The original
-- mutable adapter and its strict insertion/deletion remain unchanged.
frozenSpeculation
    :: MPFInMemoryDB
    -> (forall m. (Monad m) => Trie m -> m a)
    -> IO a
frozenSpeculation db action = do
    copyRef <- newIORef db
    action (mkPureTrieFromRef copyRef)

-- | One applied or rejected update naming a key, for the lineage projection.
request
    :: ByteString
    -> Integer
    -> RequestAction
    -> (OnChainRequest, RequestAction)
request key edge action =
    ( OnChainRequest
        { requestToken = OnChainTokenId (BuiltinByteString "lineage-token")
        , requestOwner = BuiltinByteString (BS.replicate 28 0)
        , requestKey = key
        , requestEdge = edge
        , requestDeposit = 0
        , requestSubmittedAt = 0
        , requestDestination = (BS.empty, Nothing)
        }
    , action
    )

-- | A transaction identifier by position: three identifiers differing in one digit.
txOf :: Int -> TxId
txOf n =
    let refs =
            [ "1111111111111111111111111111111111111111111111111111111111111111#0"
            , "2222222222222222222222222222222222222222222222222222222222222222#0"
            , "3333333333333333333333333333333333333333333333333333333333333333#0"
            ]
    in  case parseOutRef (refs !! (n - 1)) of
            Right (TxIn tid _) -> tid
            Left why -> error why
