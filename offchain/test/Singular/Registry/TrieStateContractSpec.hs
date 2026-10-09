{-# LANGUAGE OverloadedStrings #-}

{- | The capability contract, written before its implementation. Expected
roots/proofs/nodes come from TrieStateSpec's current MPF edge producer.
Fixture output references are identities in a pure fixture, never ledger
acceptance evidence. The real-command and private-ledger legs are in the
existing packaged journey and recovery carriers.
-}
module Singular.Registry.TrieStateContractSpec (spec) where

import Control.Monad (foldM, forM_)
import Control.Monad.State.Strict (evalState, runState)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import MPF.Backend.Pure (MPFInMemoryDB (..), emptyMPFInMemoryDB)
import MPF.Verify (verifyAikenInclusionProof)
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger
    ( AssetName (..)
    , Root (..)
    , TokenId (..)
    )
import Singular.Registry.TrieState
import Singular.Registry.TrieState.Fixture
import Singular.Registry.TrieStateSpec (edgeCases, produced)
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )

identity :: RegistryIdentity
identity =
    RegistryIdentity
        (StatePolicyId (BS.replicate 28 1))
        (AssetName "registry-a")

otherIdentity :: RegistryIdentity
otherIdentity =
    RegistryIdentity
        (StatePolicyId (BS.replicate 28 2))
        (AssetName "registry-b")

token :: TokenId
token = TokenId (AssetName "registry-a")

point :: Int -> StatePoint
point n = StatePoint (SessionId "fixture-session") Unbound output
  where
    output = case parseOutRef (T.replicate 64 "a" <> "#" <> T.pack (show n)) of
        Right p -> p
        Left why -> error why

selection :: RegistryIdentity -> Int -> Root -> TrieSelection
selection who n = TrieSelection who (point n)

{- | A create followed by actual MPF walks. Every root comes from the old
producer. Changing the journal/coverage is a controlled fixture fault.
-}
history
    :: RegistryIdentity
    -> [(ByteString, Integer)]
    -> IO (TrieSelection, CreateRecord, [ObservedFold], MPFInMemoryDB)
history who moves = do
    (_, emptyRoot, _) <- produced token []
    let origin = selection who 0 emptyRoot
    (chosen, events, _) <- foldM next (origin, [], []) (zip [1 ..] moves)
    (nodes, _, _) <- produced token moves
    pure (chosen, CreateRecord who (pointOutput (point 0)), events, nodes)
  where
    next (before, events, prefix) (n, move) = do
        let prefix' = prefix <> [move]
        (_, afterRoot, _) <- produced token prefix'
        let after = selection who n afterRoot
            event = ObservedFold before after (move :| [])
        pure (after, events <> [event], prefix')

storeOf
    :: (TrieSelection, CreateRecord, [ObservedFold], MPFInMemoryDB)
    -> FixtureStore
storeOf (chosen, create, events, nodes) = fixtureStore [(chosen, Just create, events, nodes)]

right :: (Show e) => Either e a -> IO a
right =
    either
        (\e -> expectationFailure (show e) >> fail "expected success")
        pure

spec :: Spec
spec = describe "TrieState capability contract (pure State over MPF nodes)" $ do
    it
        "holds full policy/name identity, output, root and caller session together"
        $ do
            one@(chosen, _, _, _) <-
                history identity [("first", 1), ("second", 0)]
            two <- history otherIdentity [("first", 1), ("first", 3)]
            let entry (s, c, es, db) = (s, Just c, es, db)
                fixture = fixtureStore [entry one, entry two]
                readLeaf selected =
                    evalState
                        (withTrieState fixtureTrieState selected (`leafAt` "first"))
                        fixture
            readLeaf chosen `shouldBe` Right (Right Active)
            let (otherChosen, _, _, _) = two
            readLeaf otherChosen `shouldBe` Right (Right Terminal)
            let TrieSelection who (StatePoint sid binding out) root = chosen
            forM_
                [ TrieSelection
                    ( RegistryIdentity
                        (StatePolicyId (BS.replicate 28 9))
                        (AssetName "registry-a")
                    )
                    (point 2)
                    root
                , TrieSelection
                    ( RegistryIdentity
                        (StatePolicyId (BS.replicate 28 1))
                        (AssetName "registry-b")
                    )
                    (point 2)
                    root
                , TrieSelection who (point 99) root
                , TrieSelection
                    who
                    (StatePoint (SessionId "another-session") binding out)
                    root
                , TrieSelection
                    who
                    (StatePoint sid (Bound 42 "another-header") out)
                    root
                , TrieSelection
                    who
                    (StatePoint sid binding out)
                    (Root (BS.replicate 32 9))
                ]
                $ \fault -> readLeaf fault `shouldSatisfy` isLeft
    forM_ [identity, otherIdentity] $ \who ->
        forM_ ["first", "second"] $ \key ->
            forM_ edgeCases $ \(name, edge, setup, want) ->
                it
                    ( show who
                        <> "/"
                        <> show key
                        <> "/"
                        <> name
                        <> ": proves leaves and the exact ordered walk"
                    )
                    $ do
                        let beforeMoves = ("neighbour", 1) : [(key, e) | e <- setup]
                            afterMoves = beforeMoves <> [(key, edge)]
                        before@(chosen, _, _, _) <- history who beforeMoves
                        after@(afterChosen, _, _, _) <- history who afterMoves
                        (_, expectedRoot, expectedProofs) <- produced token afterMoves
                        let fixture = storeOf before
                            action = withTrieState fixtureTrieState chosen $ \snap ->
                                speculateEdges snap ((key, edge) :| [])
                            (walked, unchanged) = runState action fixture
                        if want == Unknown
                            then
                                walked
                                    `shouldBe` Right (Left (MissingProof who (NoProofFor key)))
                            else do
                                walk <- right walked >>= right
                                walkRoot walk `shouldBe` expectedRoot
                                walkProofs walk `shouldBe` [last expectedProofs]
                        fixtureNodes unchanged `shouldBe` fixtureNodes fixture
                        fixtureFolds unchanged `shouldBe` fixtureFolds fixture
                        let proofReads = withTrieState fixtureTrieState afterChosen $ \snap -> do
                                leaf <- leafAt snap key
                                missing <- nonMembership snap "never-bound"
                                member <- membership snap key want
                                pure (leaf, missing, member)
                            (answers, untouched) = runState proofReads (storeOf after)
                        (leaf, missing, member) <- right answers
                        leaf `shouldBe` Right want
                        proofOfAbsence <- right missing
                        (_, anotherRoot, _) <- produced token [("another-registry-root", 1)]
                        verifyNonMembership
                            proofOfAbsence
                            (trieSelectionRoot afterChosen)
                            "never-bound"
                            `shouldBe` True
                        verifyNonMembership proofOfAbsence (trieSelectionRoot afterChosen) key
                            `shouldBe` False
                        verifyNonMembership proofOfAbsence anotherRoot "never-bound"
                            `shouldBe` False
                        if want == Unknown
                            then member `shouldSatisfy` isLeft
                            else do
                                proof <- right member
                                verifyAikenInclusionProof
                                    (unRoot expectedRoot)
                                    key
                                    (leafBytes want)
                                    (membershipBytes proof)
                                    `shouldBe` True
                                verifyAikenInclusionProof
                                    (unRoot expectedRoot)
                                    "never-bound"
                                    (leafBytes want)
                                    (membershipBytes proof)
                                    `shouldBe` False
                                verifyAikenInclusionProof
                                    (unRoot expectedRoot)
                                    key
                                    (leafBytes want)
                                    (BS.cons 0xff (BS.drop 1 (membershipBytes proof)))
                                    `shouldBe` False
                                verifyAikenInclusionProof
                                    (unRoot expectedRoot)
                                    key
                                    "wrong-leaf"
                                    (membershipBytes proof)
                                    `shouldBe` False
                        fixtureNodes untouched `shouldBe` fixtureNodes (storeOf after)
    it
        "requires checked create and every trie-changing step, without requiring or counting equal-root records"
        $ do
            (chosen, create, events, nodes) <-
                history identity [("first", 1), ("first", 3), ("first", 6)]
            (_, emptyRoot, _) <- produced token []
            let query c es db =
                    evalState
                        ( withTrieState
                            fixtureTrieState
                            chosen
                            (pure . coverageTransitions . trieCoverage)
                        )
                        (fixtureStore [(chosen, c, es, db)])
            query (Just create) events nodes `shouldBe` Right 2
            query Nothing events nodes
                `shouldBe` Left (HistoryIncomplete identity Nothing MissingTransaction)
            query
                (Just (CreateRecord otherIdentity (pointOutput (point 0))))
                events
                nodes
                `shouldBe` Left (WrongRegistry identity Nothing (OtherRegistry otherIdentity))
            query (Just create) (init events) nodes
                `shouldBe` Right 2
            query (Just create) (take 1 events) nodes
                `shouldBe` Left (HistoryIncomplete identity Nothing MissingTransaction)
            secondFrom <- case drop 1 events of
                ObservedFold from _ _ : _ -> pure (trieSelectionRoot from)
                [] ->
                    expectationFailure "the producer emitted one transition"
                        >> fail "short history"
            query (Just create) (drop 1 events) nodes
                `shouldBe` Left
                    (RootDoesNotChain identity Nothing (RootsPart emptyRoot secondFrom))
            query (Just create) events emptyMPFInMemoryDB
                `shouldBe` Left
                    ( RootDoesNotChain
                        identity
                        Nothing
                        (RootsPart emptyRoot (trieSelectionRoot chosen))
                    )
            ObservedFold from to edges <- case events of
                first : _ -> pure first
                [] ->
                    expectationFailure "the producer emitted no coverage transitions"
                        >> fail "empty history"
            let
                broken =
                    ObservedFold
                        from
                        (to{trieSelectionRoot = Root (BS.replicate 32 9)})
                        edges
            query (Just create) (broken : drop 1 events) nodes
                `shouldBe` Left
                    ( RootDoesNotChain
                        identity
                        Nothing
                        (RootsPart (trieSelectionRoot to) (Root (BS.replicate 32 9)))
                    )
            let discontinuous =
                    ObservedFold
                        (from{trieSelectionRoot = trieSelectionRoot chosen})
                        to
                        edges
            query (Just create) (discontinuous : drop 1 events) nodes
                `shouldBe` Left
                    ( RootDoesNotChain
                        identity
                        Nothing
                        (RootsPart emptyRoot (trieSelectionRoot chosen))
                    )
            let undecodable = ObservedFold from to (("first", 99) :| [])
            query (Just create) (undecodable : drop 1 events) nodes
                `shouldBe` Left (UndecodableRequest identity Nothing (EdgeOutOfRange 99))
    it
        "reads authenticated nodes after the uncommitted key index is erased"
        $ do
            (chosen, create, events, nodes) <-
                history identity [("first", 1), ("second", 0)]
            let fixture =
                    fixtureStore
                        [(chosen, Just create, events, nodes{mpfInMemoryKV = Map.empty})]
            evalState
                (withTrieState fixtureTrieState chosen (`leafAt` "first"))
                fixture
                `shouldBe` Right (Right Active)
    it
        "keeps an immutable snapshot when an accepted fold advances the store inside its callback"
        $ do
            before@(chosen, _, _, _) <- history identity [("first", 1)]
            (_, _, events, _) <- history identity [("first", 1), ("first", 3)]
            let action = withTrieState fixtureTrieState chosen $ \snap -> do
                    accepted <- acceptObservedFold fixtureTrieState (last events)
                    leaf <- leafAt snap "first"
                    pure (accepted, leaf, trieRoot snap)
            evalState action (storeOf before)
                `shouldBe` Right (Right (), Right Active, trieSelectionRoot chosen)
    it
        "applies a confirmed fold once, refuses conflicting repeats and keeps the next selection current"
        $ do
            before@(chosen, _, _, _) <- history identity [("first", 1)]
            after@(afterChosen, _, events, _) <-
                history identity [("first", 1), ("first", 3)]
            let event = last events
                initial = storeOf before
                (accepted, updated) = runState (acceptObservedFold fixtureTrieState event) initial
                (repeated, repeatedStore) = runState (acceptObservedFold fixtureTrieState event) updated
            accepted `shouldBe` Right ()
            fixtureNodes updated `shouldBe` fixtureNodes (storeOf after)
            repeated `shouldBe` Right ()
            fixtureFolds repeatedStore `shouldBe` fixtureFolds updated
            fixtureNodes repeatedStore `shouldBe` fixtureNodes updated
            evalState
                (withTrieState fixtureTrieState chosen (`leafAt` "first"))
                updated
                `shouldSatisfy` isLeft
            evalState
                (withTrieState fixtureTrieState afterChosen (`leafAt` "first"))
                updated
                `shouldBe` Right (Right Terminal)
            let ObservedFold from to _ = event
                conflicting = ObservedFold from to (("first", 5) :| [])
            evalState (acceptObservedFold fixtureTrieState conflicting) updated
                `shouldSatisfy` isLeft
    it
        "refuses a missing source proof by name rather than returning an empty successful edge proof"
        $ do
            before@(chosen, _, _, _) <- history identity [("neighbour", 1)]
            let fixture = storeOf before
            forM_ [2 .. 6] $ \edge -> do
                let action = withTrieState fixtureTrieState chosen $ \snap ->
                        speculateEdges snap (("never-bound", edge) :| [])
                    (answer, unchanged) = runState action fixture
                answer
                    `shouldBe` Right (Left (MissingProof identity (NoProofFor "never-bound")))
                fixtureNodes unchanged `shouldBe` fixtureNodes fixture
                fixtureFolds unchanged `shouldBe` fixtureFolds fixture
    it
        "never treats an invalid trusted root as the empty root for an exclusion proof"
        $ do
            empty@(chosen, _, _, _) <- history identity []
            let answer =
                    evalState
                        ( withTrieState
                            fixtureTrieState
                            chosen
                            (`nonMembership` "never-bound")
                        )
                        (storeOf empty)
            proof <- right answer >>= right
            verifyNonMembership proof (trieSelectionRoot chosen) "never-bound"
                `shouldBe` True
            verifyNonMembership proof (Root "invalid width") "never-bound"
                `shouldBe` False
    it
        "uses the supplied edge order, returns every intermediate proof and refuses undecodable edges without mutation"
        $ do
            before@(chosen, _, _, _) <- history identity [("neighbour", 1)]
            (_, expectedRoot, proofs) <-
                produced token [("neighbour", 1), ("first", 1), ("first", 3)]
            let fixture = storeOf before
                action moves =
                    withTrieState fixtureTrieState chosen (`speculateEdges` moves)
                (ordered, unchanged) = runState (action (("first", 1) :| [("first", 3)])) fixture
            walk <- right ordered >>= right
            walkRoot walk `shouldBe` expectedRoot
            walkProofs walk `shouldBe` drop 1 proofs
            fixtureNodes unchanged `shouldBe` fixtureNodes fixture
            let (bad, afterBad) = runState (action (("first", 99) :| [])) fixture
            bad
                `shouldBe` Right (Left (UndecodableRequest identity Nothing (EdgeOutOfRange 99)))
            fixtureNodes afterBad `shouldBe` fixtureNodes fixture
            after@(afterChosen, _, _, _) <-
                history identity [("neighbour", 1), ("first", 1), ("first", 3)]
            let accepted = ObservedFold chosen afterChosen (("first", 1) :| [("first", 3)])
                (acceptedAnswer, committed) = runState (acceptObservedFold fixtureTrieState accepted) fixture
                (repeatAnswer, repeated) = runState (acceptObservedFold fixtureTrieState accepted) committed
            acceptedAnswer `shouldBe` Right ()
            fixtureNodes committed `shouldBe` fixtureNodes (storeOf after)
            repeatAnswer `shouldBe` Right ()
            fixtureNodes repeated `shouldBe` fixtureNodes committed
            fixtureFolds repeated `shouldBe` fixtureFolds committed
            let reordered = ObservedFold chosen afterChosen (("first", 3) :| [("first", 1)])
                (reorderedAnswer, refused) = runState (acceptObservedFold fixtureTrieState reordered) fixture
            reorderedAnswer
                `shouldBe` Left (MissingProof identity (NoProofFor "first"))
            fixtureNodes refused `shouldBe` fixtureNodes fixture
            fixtureFolds refused `shouldBe` fixtureFolds fixture

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False

leafBytes :: Leaf -> ByteString
leafBytes Unknown = ""
leafBytes Absent = BS.singleton 0
leafBytes Active = BS.singleton 1
leafBytes Terminal = BS.singleton 2
