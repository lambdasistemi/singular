{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Singular.Registry.E2E.ReplaySpec
Description : A registry's trie rebuilt from its public history, checked against the chain
License     : Apache-2.0

One registry is made on a devnet ("Singular.Registry.E2E.ReplayHistory"):
@create@, an @insertActive@ and an @updateTerminal@ fold of one key, a fold
that rejects its request and a fold that applies one request and rejects
the others. Every
expected value below comes from that chain: the roots are the state datums
the chain holds after each fold, the transactions and their identifiers
are the ones it accepted. Nothing is typed in.

The replay must rebuild, at every state output of that history, the trie
whose root the chain holds there; refuse by name a history that does not
chain from @create@ to the selection; leave out every transaction whose
bytes say it failed its scripts (@isValid = false@), which spent only its
collateral; and give, at every fold, proofs for
every key of the history that verify against the chain's root under a
verifier that never sees the trie.
-}
module Singular.Registry.E2E.ReplaySpec (spec) where

import Control.Monad (forM, forM_, unless, when)
import Control.Tracer (nullTracer)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (elemIndex, nub)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Lens.Micro ((%~), (&), (.~), (^.))
import Test.Hspec hiding (after, before)

import Cardano.Ledger.Address (getNetwork)
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Alonzo.Tx (IsValid (..))
import Cardano.Ledger.Alonzo.TxWits (Redeemers (..))
import Cardano.Ledger.Api.Scripts.Data (Data (..), getPlutusData)
import Cardano.Ledger.Api.Tx (bodyTxL, isValidTxL, txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , mintTxBodyL
    , outputsTxBodyL
    , referenceInputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , coinTxOutL
    , datumTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits (rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Binary (decCBOR, decodeFullAnnotator, serialize)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (eraProtVerHigh)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.ExUnits (ExUnits)
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import MPF.Backend.Pure (MPFInMemoryDB, emptyMPFInMemoryDB)
import MPF.Verify
    ( verifyAikenExclusionProof
    , verifyAikenInclusionProof
    )
import PlutusTx (fromBuiltinData, toBuiltinData)
import PlutusTx.Builtins (serialiseData)
import PlutusTx.Builtins.Internal
    ( BuiltinByteString (..)
    , BuiltinData (..)
    )

import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint (Blueprint, extractCompiledCode)
import Singular.Registry.Evidence qualified as Evidence
import Singular.Registry.Ledger (ConwayEra, Root (..))
import Singular.Registry.LedgerProvider qualified as LP
import Singular.Registry.Replay (Replayed (..), replayLineage)
import Singular.Registry.Trie (Trie (..))
import Singular.Registry.Trie.Pure (mkPureTrieFromRef)
import Singular.Registry.TrieState
    ( Incomplete (..)
    , Mismatch (..)
    , Parting (..)
    , RegistryIdentity (..)
    , Staleness (..)
    , StatePolicyId (..)
    , TrieFailure (..)
    , Undecodable (..)
    , failureTransaction
    )
import Singular.Registry.TrieState qualified as TS
import Singular.Registry.TrieState.Lineage (lineageTrieState)
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , extractCageDatum
    , leafAbsent
    , leafActive
    , leafTerminal
    , mkInlineDatum
    , scriptHashBytes
    , toPlcData
    , txInToRef
    , walkEdge
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , MintRedeemer (..)
    , Neighbor (..)
    , OnChainRequest (..)
    , OnChainTokenId (..)
    , ProofStep (..)
    , RequestAction (..)
    , UpdateRedeemer (..)
    , edgeInsertAbsent
    , edgeInsertActive
    )

import Singular.Registry.E2E.ReplayHistory
    ( History (..)
    , MixedFold (..)
    , StatePoint (..)
    , recordHistory
    )

spec :: Blueprint -> Spec
spec bp =
    describe "Rebuilding a registry's trie from its public history" $
        case ( extractCompiledCode "state.state" bp
             , extractCompiledCode "request.request" bp
             ) of
            (Just stateBytes, Just requestBytes) ->
                beforeAll (recordHistory stateBytes requestBytes) replaySpec
            _ ->
                it "no compiled code" $
                    expectationFailure "state or request script not found"

replaySpec :: SpecWith History
replaySpec = do
    describe
        "Commands select the trie from their acquired session history"
        $ do
            it
                "serves the chain root, coverage and proofs from create through every fold"
                $ \h -> do
                    blocks <- newIORef (lineageBlocks h)
                    let session = lineageSession blocks
                        backend = lineageTrieState session
                    forM_ (zip [0 ..] (points h)) $ \(count, p) -> do
                        answer <- TS.withTrieState backend (lineageSelection session h p) $ \snap -> do
                            TS.trieRoot snap `shouldBe` pointRoot p
                            TS.coverageTransitions (TS.trieCoverage snap) `shouldBe` count
                            missing <- TS.nonMembership snap "never-booked-backend-key"
                            case missing of
                                Right proof ->
                                    TS.verifyNonMembership proof (pointRoot p) "never-booked-backend-key"
                                        `shouldBe` True
                                Left why -> expectationFailure (show why)
                            forM_ (historyKeys h) $ \key -> do
                                leaf <- TS.leafAt snap key >>= either (fail . show) pure
                                case leaf of
                                    TS.Unknown -> pure ()
                                    present -> do
                                        proof <- TS.membership snap key present >>= either (fail . show) pure
                                        verifyAikenInclusionProof
                                            (unRoot (pointRoot p))
                                            key
                                            ( case present of
                                                TS.Absent -> BS.singleton 0
                                                TS.Active -> BS.singleton 1
                                                TS.Terminal -> BS.singleton 2
                                            )
                                            (TS.membershipBytes proof)
                                            `shouldBe` True
                        answer `shouldBe` Right ()
            it
                "withholding a fold refuses the selection rather than using a previous snapshot"
                $ \h -> do
                    blocks <- newIORef (lineageBlocks h)
                    let session = lineageSession blocks
                        backend = lineageTrieState session
                        selected = lineageSelection session h (lastPoint h)
                    TS.withTrieState backend selected (pure . TS.trieRoot)
                        `shouldReturn` Right (pointRoot (lastPoint h))
                    writeIORef blocks (init (lineageBlocks h))
                    answer <- TS.withTrieState backend selected (pure . TS.trieRoot)
                    case answer of
                        Left TS.HistoryIncomplete{} -> pure ()
                        other -> expectationFailure ("withheld fold served a trie: " <> show other)
            it
                "a speculative walk changes neither the snapshot root nor its leaves"
                $ \h -> do
                    blocks <- newIORef (lineageBlocks h)
                    let session = lineageSession blocks
                        selected = lineageSelection session h (lastPoint h)
                    answer <- TS.withTrieState (lineageTrieState session) selected $ \snap -> do
                        before <- TS.leafAt snap "speculative-backend-key"
                        walked <-
                            TS.speculateEdges snap (("speculative-backend-key", 1) NE.:| [])
                        case walked of
                            Right walk -> TS.walkRoot walk `shouldNotBe` TS.trieRoot snap
                            Left why -> expectationFailure (show why)
                        TS.trieRoot snap `shouldBe` pointRoot (lastPoint h)
                        TS.leafAt snap "speculative-backend-key" `shouldReturn` before
                    answer `shouldBe` Right ()
            it
                "accepted folds persist nothing: the next selection requests public history again"
                $ \h -> do
                    blocks <- newIORef (take 1 (lineageBlocks h))
                    let session = lineageSession blocks
                        backend = lineageTrieState session
                        before = lineageSelection session h (historyCreate h)
                        after = lineageSelection session h (foldAt 0 h)
                    pairs <- foldPairs h (pointTx (foldAt 0 h))
                    let moves =
                            NE.fromList [(requestKey r, requestEdge r) | (r, Update _) <- pairs]
                    TS.withTrieState backend before (pure . TS.trieRoot)
                        `shouldReturn` Right (pointRoot (historyCreate h))
                    TS.acceptObservedFold backend (TS.ObservedFold before after moves)
                        `shouldReturn` Right ()
                    withheld <- TS.withTrieState backend after (pure . TS.trieRoot)
                    case withheld of
                        Left TS.HistoryIncomplete{} -> pure ()
                        other ->
                            expectationFailure
                                ("acceptObservedFold cached a trie: " <> show other)
                    writeIORef blocks (lineageBlocks h)
                    TS.withTrieState backend after (pure . TS.trieRoot)
                        `shouldReturn` Right (pointRoot (foldAt 0 h))
            it
                "refuses a provider script-valid flag that disagrees with its transaction CBOR"
                $ \h -> do
                    let altered = case lineageBlocks h of
                            LP.HistoryBlock height (tx NE.:| rest) : later ->
                                LP.HistoryBlock
                                    height
                                    (tx{LP.scriptValid = not (LP.scriptValid tx)} NE.:| rest)
                                    : later
                            [] -> error "the chain history has no create"
                    blocks <- newIORef altered
                    let session = lineageSession blocks
                    answer <-
                        TS.withTrieState
                            (lineageTrieState session)
                            (lineageSelection session h (lastPoint h))
                            (pure . TS.trieRoot)
                    case answer of
                        Left TS.HistoryIncomplete{} -> pure ()
                        other ->
                            expectationFailure
                                ("contradictory script validity served a trie: " <> show other)
            it
                "refuses descending whole-block history by name"
                $ \h -> do
                    let descending = reverse (lineageBlocks h)
                        heights = map LP.blockHeight descending
                    blocks <- newIORef descending
                    let session = lineageSession blocks
                    answer <-
                        TS.withTrieState
                            (lineageTrieState session)
                            (lineageSelection session h (lastPoint h))
                            (pure . TS.trieRoot)
                    case answer of
                        Left
                            (TS.HistoryIncomplete _ Nothing (TS.ProviderHistoryFailure failure)) ->
                                case heights of
                                    first : second : _ -> failure `shouldBe` LP.HistoryOrderMismatch first second
                                    _ ->
                                        expectationFailure "the chain history supplies fewer than two heights"
                        other ->
                            expectationFailure
                                ("descending history lost its provider refusal: " <> show other)
            it
                "consumes one complete block with creators before their asset spenders"
                $ \h -> do
                    let transactions = concatMap (NE.toList . LP.blockTransactions) (lineageBlocks h)
                    blocks <- newIORef [LP.HistoryBlock 1 (NE.fromList transactions)]
                    let session = lineageSession blocks
                    TS.withTrieState
                        (lineageTrieState session)
                        (lineageSelection session h (lastPoint h))
                        (pure . TS.trieRoot)
                        `shouldReturn` Right (pointRoot (lastPoint h))
                    writeIORef
                        blocks
                        [LP.HistoryBlock 1 (NE.fromList (reverse transactions))]
                    answer <-
                        TS.withTrieState
                            (lineageTrieState session)
                            (lineageSelection session h (lastPoint h))
                            (pure . TS.trieRoot)
                    case answer of
                        Left
                            (TS.HistoryIncomplete _ transaction (TS.ProviderHistoryFailure failure)) -> do
                                let spender = txIdTx (pointTx (lastPoint h))
                                    creator = txIdTx (pointTx (last (init (points h))))
                                transaction `shouldBe` Just spender
                                failure `shouldBe` LP.MissingInBlockParent spender creator
                        other ->
                            expectationFailure
                                ("asset ordering lost its provider refusal: " <> show other)
            it
                "uses transaction CBOR as its single source of transaction identity and body"
                $ \h -> do
                    let original = lineageBlocks h
                        replaced = case original of
                            LP.HistoryBlock height (tx NE.:| rest) : later ->
                                LP.HistoryBlock
                                    height
                                    (tx{LP.historicalTx = pointTx (lastPoint h)} NE.:| rest)
                                    : later
                            [] -> error "the chain history has no create"
                    blocks <- newIORef replaced
                    let session = lineageSession blocks
                    answer <-
                        TS.withTrieState
                            (lineageTrieState session)
                            (lineageSelection session h (lastPoint h))
                            (pure . TS.trieRoot)
                    case answer of
                        Left TS.HistoryIncomplete{} -> pure ()
                        other ->
                            expectationFailure
                                ("a body different from its CBOR served a trie: " <> show other)
    describe "the rebuilt root is the chain's root" $ do
        it "has a fold rejecting all its requests and one mixing both" $ \h -> do
            folds <- mapM (foldPairs h . pointTx) (historyFolds h)
            unless (any (all (isRejected . snd)) folds) $
                expectationFailure "no fold of the history rejects all its requests"
            unless
                ( any
                    (\f -> any (isRejected . snd) f && any (isApplied . snd) f)
                    folds
                )
                $ expectationFailure
                    "no fold of the history mixes applied and rejected requests"

        it "replays to the chain's root at create and after every fold" $ \h -> do
            -- One verdict per state output, compared as one list: a failure
            -- shows where the replay first parts from the chain and that
            -- every state output before it still rebuilds the chain's root.
            observed <- forM (zip [0 ..] (points h)) $ \(k, p) -> do
                (result, db) <-
                    replayAt h (historyResolved h) (historyTxs h) (historyToken h) p
                rebuilt <- rootOf db
                let lineage =
                        Replayed
                            (txIdTx (pointTx (historyCreate h)))
                            (map (txIdTx . pointTx) (take k (historyFolds h)))
                pure (pointLabel p, verdict h lineage (pointRoot p) result rebuilt)
            observed `shouldBe` [(pointLabel p, rebuiltChainRoot) | p <- points h]

        it "refuses, naming the fold, a request served with an altered edge" $ \h -> do
            let target = firstFold "insertActive" h
                fid = txIdTx (pointTx target)
            pairs <- foldPairs h (pointTx target)
            (reqIn, req) <- case pairs of
                [(r, _)] -> case requestInputs h (pointTx target) of
                    [(i, _)] -> pure (i, r)
                    _ -> fail "the insertActive fold spends other than one request"
                _ -> fail "the insertActive fold carries other than one request"
            let altered =
                    Map.adjust
                        (setRequest req{requestEdge = edgeInsertAbsent})
                        reqIn
                        (historyResolved h)
            (result, _) <-
                replayAt h altered (historyTxs h) (historyToken h) (lastPoint h)
            case result of
                Left (RootDoesNotChain tok (Just tx) (RootsPart _ recorded)) -> do
                    tok `shouldBe` historyToken h
                    tx `shouldBe` fid
                    recorded `shouldBe` pointRoot target
                other ->
                    expectationFailure ("expected RootDoesNotChain, got " <> show other)

    describe "a mixed fold changes the trie by its applied requests only" $ do
        it "applies one request and rejects the others, all of this registry" $ \h -> do
            pairs <- foldPairs h (pointTx (mixedPoint h))
            length pairs `shouldSatisfy` (> 1)
            [r | (r, Update _) <- pairs] `shouldSatisfy` ((== 1) . length)
            map fst (requestInputs h (pointTx (mixedPoint h)))
                `shouldSatisfy` elem (mixedApplied (historyMixed h))

        it "differs from what applying every request would give" $ \h -> do
            pairs <- foldPairs h (pointTx (mixedPoint h))
            root <- applyOnTop h (beforeMixed h) [r | (r, _) <- pairs]
            root `shouldNotBe` pointRoot (mixedPoint h)

    describe
        "actions pair with this registry's requests in ledger input order"
        $ do
            it
                "books the mixed fold's requests in an order that is not the ledger's"
                $ \h -> do
                    let booked = mixedBooked (historyMixed h)
                    length booked `shouldSatisfy` (> 1)
                    Set.toAscList (Set.fromList booked) `shouldNotBe` booked

            it "differs from what pairing in booking order would give" $ \h -> do
                let tx = pointTx (mixedPoint h)
                actions <- map snd <$> foldPairs h tx
                let requests = Map.fromList (requestInputs h tx)
                    byBooking =
                        [ r
                        | (b, a) <- zip (mixedBooked (historyMixed h)) actions
                        , isApplied a
                        , Just r <- [Map.lookup b requests]
                        ]
                length byBooking `shouldBe` 1
                root <- applyOnTop h (beforeMixed h) byBooking
                root `shouldNotBe` pointRoot (mixedPoint h)

            it
                "reads the actions from the fold's own redeemer: reordered there, the fold is refused by name"
                $ \h -> do
                    let target = mixedPoint h
                        tid = txIdTx (pointTx target)
                    purpose <- stateSpendPurpose h (pointTx target)
                    actions <- map snd <$> foldPairs h (pointTx target)
                    let reordered = rotate 1 actions
                    map isApplied reordered `shouldNotBe` map isApplied actions
                    let tx =
                            withRedeemers
                                ( Map.adjust
                                    (\(_, units) -> (Data (toPlcData (Modify reordered)), units))
                                    purpose
                                )
                                (pointTx target)
                    txIdTx tx `shouldBe` tid
                    (result, _) <-
                        replayAt
                            h
                            (historyResolved h)
                            (swapTx tx (historyTxs h))
                            (historyToken h)
                            (lastPoint h)
                    case result of
                        Left
                            (RootDoesNotChain tok (Just named) (RootsPart _ recorded)) -> do
                                tok `shouldBe` historyToken h
                                named `shouldBe` tid
                                recorded `shouldBe` pointRoot target
                        other ->
                            expectationFailure ("expected RootDoesNotChain, got " <> show other)

            it "spends another registry's request and references one of its own" $ \h -> do
                let body = pointTx (mixedPoint h) ^. bodyTxL
                    m = historyMixed h
                Set.member (mixedDecoySpent m) (body ^. inputsTxBodyL) `shouldBe` True
                Set.member (mixedDecoyReferenced m) (body ^. referenceInputsTxBodyL)
                    `shouldBe` True
                requestTokenAt h (mixedDecoySpent m)
                    `shouldSatisfy` maybe False (/= tokenBytes h)
                requestTokenAt h (mixedDecoyReferenced m)
                    `shouldBe` Just (tokenBytes h)

    describe
        "a history that does not chain from create is refused by name"
        $ do
            it
                "rebuilds the same trie from the history newest first, as the provider lists it, and in other orders"
                $ \h -> do
                    let txs = historyTxs h
                    (inOrder, db0) <-
                        replayAt h (historyResolved h) txs (historyToken h) (lastPoint h)
                    r0 <- rootOf db0
                    inOrder
                        `shouldBe` Right
                            ( Replayed
                                (txIdTx (pointTx (historyCreate h)))
                                (map (txIdTx . pointTx) (historyFolds h))
                            )
                    r0 `shouldBe` pointRoot (lastPoint h)
                    forM_ [reverse txs, rotate 3 txs, rotate 7 (reverse txs)] $ \shuffled -> do
                        (result, db) <-
                            replayAt h (historyResolved h) shuffled (historyToken h) (lastPoint h)
                        result `shouldBe` inOrder
                        rootOf db >>= (`shouldBe` r0)

            it "refuses a history with one fold dropped, naming it" $ \h -> do
                let dropped = foldAt 1 h
                    txs = filter ((/= txIdTx (pointTx dropped)) . txIdTx) (historyTxs h)
                (result, _) <-
                    replayAt h (historyResolved h) txs (historyToken h) (lastPoint h)
                result
                    `shouldBe` Left
                        ( HistoryIncomplete
                            (historyToken h)
                            (Just (txIdTx (pointTx dropped)))
                            MissingTransaction
                        )

            it "refuses a history without create, naming it" $ \h -> do
                let createId = txIdTx (pointTx (historyCreate h))
                    txs = filter ((/= createId) . txIdTx) (historyTxs h)
                (result, _) <-
                    replayAt h (historyResolved h) txs (historyToken h) (lastPoint h)
                result
                    `shouldBe` Left
                        ( HistoryIncomplete
                            (historyToken h)
                            (Just createId)
                            MissingTransaction
                        )

            it
                "refuses a state output spent by two transactions, naming the second"
                $ \h -> do
                    let spentFrom = foldAt 0 h
                        forkedFrom = foldAt 1 h
                        fork = bumpFee (pointTx forkedFrom)
                    txIdTx fork `shouldNotBe` txIdTx (pointTx forkedFrom)
                    (result, _) <-
                        replayAt
                            h
                            (historyResolved h)
                            (historyTxs h <> [fork])
                            (historyToken h)
                            (lastPoint h)
                    result
                        `shouldBe` Left
                            ( HistoryIncomplete
                                (historyToken h)
                                (Just (txIdTx fork))
                                (ForkedStateOutput (pointOutput spentFrom))
                            )

            it
                "refuses a state output past the selection spent by two transactions"
                $ \h -> do
                    let selection = foldAt 0 h
                        spentFrom = foldAt 1 h
                        forkedFrom = foldAt 2 h
                        fork = bumpFee (pointTx forkedFrom)
                        -- Past the selection neither spender is on the
                        -- lineage: the refusal names the larger identifier.
                        named = max (txIdTx fork) (txIdTx (pointTx forkedFrom))
                    (result, _) <-
                        replayAt
                            h
                            (historyResolved h)
                            (historyTxs h <> [fork])
                            (historyToken h)
                            selection
                    result
                        `shouldBe` Left
                            ( HistoryIncomplete
                                (historyToken h)
                                (Just named)
                                (ForkedStateOutput (pointOutput spentFrom))
                            )

            it "refuses a transaction that touches the token outside the lineage" $ \h -> do
                let stray = bumpFee (pointTx (historyCreate h))
                (result, _) <-
                    replayAt
                        h
                        (historyResolved h)
                        (stray : historyTxs h)
                        (historyToken h)
                        (lastPoint h)
                result
                    `shouldBe` Left
                        ( HistoryIncomplete
                            (historyToken h)
                            (Just (txIdTx stray))
                            OutsideLineage
                        )

            it
                "rebuilds the same trie from every transaction served twice, as overlapping pages serve it"
                $ \h -> do
                    let txs = historyTxs h
                    twice <- mapM viaCbor (txs <> reverse txs)
                    (once, db0) <-
                        replayAt h (historyResolved h) txs (historyToken h) (lastPoint h)
                    (repeated, db) <-
                        replayAt h (historyResolved h) twice (historyToken h) (lastPoint h)
                    once `shouldSatisfy` isRight'
                    repeated `shouldBe` once
                    r0 <- rootOf db0
                    rootOf db >>= (`shouldBe` r0)

    describe
        "a transaction that failed its scripts is not in the lineage"
        $ do
            it
                "reads every transaction the chain accepted as valid, from its bytes"
                $ \h -> do
                    decoded <- mapM viaCbor (historyTxs h)
                    [ (pointLabel p, tx ^. isValidTxL)
                      | (p, tx) <- zip (points h) decoded
                      ]
                        `shouldBe` [(pointLabel p, IsValid True) | p <- points h]

            it
                "rebuilds, at every state output, the lineage and trie of the history without a failed copy of any of its transactions"
                $ \h -> do
                    -- One verdict per (selection, failed copy) pair: the
                    -- failed copy of create and of each fold spends what
                    -- the transaction it copies spends, under another
                    -- identifier, and must change nothing. The expected
                    -- lineage and root are the chain's.
                    observed <- forM (zip [0 ..] (points h)) $ \(k, selected) -> do
                        let lineage =
                                Replayed
                                    (txIdTx (pointTx (historyCreate h)))
                                    (map (txIdTx . pointTx) (take k (historyFolds h)))
                        forM (points h) $ \copied -> do
                            bad <- failedCopy (pointTx copied)
                            (result, db) <-
                                replayAt
                                    h
                                    (historyResolved h)
                                    (historyTxs h <> [bad])
                                    (historyToken h)
                                    selected
                            rebuilt <- rootOf db
                            pure
                                ( pointLabel selected
                                , "failed copy of " <> pointLabel copied
                                , verdict h lineage (pointRoot selected) result rebuilt
                                )
                    concat observed
                        `shouldBe` [ (pointLabel s, "failed copy of " <> pointLabel c, rebuiltChainRoot)
                                   | s <- points h
                                   , c <- points h
                                   ]

            it
                "reads the same transaction as a second spend when it is marked valid"
                $ \h -> do
                    let spentFrom = foldAt 0 h
                        copied = pointTx (foldAt 1 h)
                    bad <- failedCopy copied
                    good <- viaCbor (bad & isValidTxL .~ IsValid True)
                    txIdTx good `shouldBe` txIdTx bad
                    (without, _) <-
                        replayAt
                            h
                            (historyResolved h)
                            (historyTxs h)
                            (historyToken h)
                            (lastPoint h)
                    outcomes <- forM [good, bad] $ \tx -> do
                        (result, _) <-
                            replayAt
                                h
                                (historyResolved h)
                                (historyTxs h <> [tx])
                                (historyToken h)
                                (lastPoint h)
                        pure (tx ^. isValidTxL, result)
                    outcomes
                        `shouldBe` [
                                       ( IsValid True
                                       , Left
                                            ( HistoryIncomplete
                                                (historyToken h)
                                                (Just (txIdTx good))
                                                (ForkedStateOutput (pointOutput spentFrom))
                                            )
                                       )
                                   , (IsValid False, without)
                                   ]

            it
                "never serves a failed transaction as the fold that made the selected state output"
                $ \h -> do
                    let newest = lastPoint h
                    bad <- failedCopy (pointTx newest)
                    let txs = bad : filter ((/= txIdTx (pointTx newest)) . txIdTx) (historyTxs h)
                    (result, _) <-
                        replayAt
                            h
                            (historyResolved h)
                            txs
                            (historyToken h)
                            newest
                                { pointTx = bad
                                , pointOutput = TxIn (txIdTx bad) (TxIx 0)
                                }
                    result
                        `shouldBe` Left
                            ( HistoryIncomplete
                                (historyToken h)
                                (Just (txIdTx bad))
                                MissingTransaction
                            )

    describe
        "material the replay cannot read is refused by name, never guessed"
        $ do
            it
                "refuses a fold whose request input is not resolved, naming the fold"
                $ \h -> do
                    let target = firstFold "insertActive" h
                    reqIn <- case requestInputs h (pointTx target) of
                        [(i, _)] -> pure i
                        _ -> fail "the insertActive fold spends other than one request"
                    (result, _) <-
                        replayAt
                            h
                            (Map.delete reqIn (historyResolved h))
                            (historyTxs h)
                            (historyToken h)
                            (lastPoint h)
                    result
                        `shouldBe` Left
                            ( HistoryIncomplete
                                (historyToken h)
                                (Just (txIdTx (pointTx target)))
                                (UnresolvedInput reqIn)
                            )

            it
                "refuses a resolution that contradicts the transaction that made the output"
                $ \h -> do
                    let target = firstFold "insertActive" h
                    stateIn <- stateInputOf h (pointTx target)
                    let altered = Map.adjust (coinTxOutL .~ Coin 1) stateIn (historyResolved h)
                    (result, _) <-
                        replayAt h altered (historyTxs h) (historyToken h) (lastPoint h)
                    result
                        `shouldBe` Left
                            ( HistoryIncomplete
                                (historyToken h)
                                (Just (txIdTx (pointTx target)))
                                (ConflictingResolution stateIn)
                            )

            it "refuses two different transactions under one identifier" $ \h -> do
                let create = pointTx (historyCreate h)
                    copy = withMintRedeemer (Minting (txInToRef (historyStranger h))) create
                (result, _) <-
                    replayAt
                        h
                        (historyResolved h)
                        (historyTxs h <> [copy])
                        (historyToken h)
                        (lastPoint h)
                result
                    `shouldBe` Left
                        ( HistoryIncomplete
                            (historyToken h)
                            (Just (txIdTx create))
                            ConflictingCopies
                        )

            it
                "refuses a fold whose state spend is not Modify, or carries no redeemer"
                $ \h -> do
                    let target = firstFold "insertActive" h
                        tid = txIdTx (pointTx target)
                    purpose <- stateSpendPurpose h (pointTx target)
                    let refusedWith edit expected = do
                            let tx = withRedeemers edit (pointTx target)
                            txIdTx tx `shouldBe` tid
                            (result, _) <-
                                replayAt
                                    h
                                    (historyResolved h)
                                    (swapTx tx (historyTxs h))
                                    (historyToken h)
                                    (lastPoint h)
                            result
                                `shouldBe` Left
                                    (UndecodableRequest (historyToken h) (Just tid) expected)
                    refusedWith
                        ( Map.adjust
                            ( \(_, units) ->
                                (Data (toPlcData (Contribute (txInToRef (historyStranger h)))), units)
                            )
                            purpose
                        )
                        NotModify
                    refusedWith (Map.delete purpose) MissingRedeemer

            it "refuses a fold with one action fewer than its requests" $ \h -> do
                let target = firstFold "insertActive" h
                    tid = txIdTx (pointTx target)
                purpose <- stateSpendPurpose h (pointTx target)
                let tx =
                        withRedeemers
                            ( Map.adjust
                                (\(_, units) -> (Data (toPlcData (Modify [])), units))
                                purpose
                            )
                            (pointTx target)
                (result, _) <-
                    replayAt
                        h
                        (historyResolved h)
                        (swapTx tx (historyTxs h))
                        (historyToken h)
                        (lastPoint h)
                result
                    `shouldBe` Left
                        ( UndecodableRequest
                            (historyToken h)
                            (Just tid)
                            (ActionCount 0 1)
                        )

            it "refuses a fold with one action more than its requests" $ \h -> do
                let target = firstFold "insertActive" h
                    tid = txIdTx (pointTx target)
                purpose <- stateSpendPurpose h (pointTx target)
                actions <- map snd <$> foldPairs h (pointTx target)
                let tx =
                        withRedeemers
                            ( Map.adjust
                                ( \(_, units) ->
                                    (Data (toPlcData (Modify (actions <> [Rejected]))), units)
                                )
                                purpose
                            )
                            (pointTx target)
                (result, _) <-
                    replayAt
                        h
                        (historyResolved h)
                        (swapTx tx (historyTxs h))
                        (historyToken h)
                        (lastPoint h)
                result
                    `shouldBe` Left
                        ( UndecodableRequest
                            (historyToken h)
                            (Just tid)
                            (ActionCount 2 1)
                        )

            it "refuses a fold whose first output carries no state datum" $ \h -> do
                let newest = pointTx (lastPoint h)
                    edited =
                        withOutputs
                            (\case o : rest -> setRequest decoyRequest o : rest; [] -> [])
                            newest
                (result, _) <- replayEdited h newest edited
                result
                    `shouldBe` Left
                        ( UndecodableRequest
                            (historyToken h)
                            (Just (txIdTx edited))
                            UndecodableStateOutput
                        )

            it "refuses a fold that spends no state output" $ \h -> do
                let newest = pointTx (lastPoint h)
                stateIn <- stateInputOf h newest
                let edited = newest & bodyTxL . inputsTxBodyL %~ Set.delete stateIn
                (result, _) <- replayEdited h newest edited
                result
                    `shouldBe` Left
                        ( HistoryIncomplete
                            (historyToken h)
                            (Just (txIdTx edited))
                            NoStateInput
                        )

            it "refuses a create whose seed does not name the token" $ \h -> do
                let create = pointTx (historyCreate h)
                    stranger = historyStranger h
                    edited =
                        withMintRedeemer
                            (Minting (txInToRef stranger))
                            (create & bodyTxL . inputsTxBodyL %~ Set.insert stranger)
                (result, _) <- replayCreate h edited
                result
                    `shouldBe` Left
                        ( WrongRegistry
                            (historyToken h)
                            (Just (txIdTx edited))
                            SeedName
                        )

            it "refuses a create whose first output is not the state address" $ \h -> do
                let create = pointTx (historyCreate h)
                    toKey o =
                        o
                            & addrTxOutL
                                .~ addrFromKeyHashBytes
                                    (getNetwork (o ^. addrTxOutL))
                                    (BS.replicate 28 0xcd)
                    edited =
                        withOutputs (\case o : rest -> toKey o : rest; [] -> []) create
                (result, _) <- replayCreate h edited
                result
                    `shouldBe` Left
                        ( WrongRegistry
                            (historyToken h)
                            (Just (txIdTx edited))
                            CreateOutput
                        )

            it "refuses a create whose mint redeemer is not Minting" $ \h -> do
                let create = pointTx (historyCreate h)
                    burning =
                        withMintRedeemer
                            (Burning (OnChainTokenId (BuiltinByteString (tokenBytes h))))
                            create
                (result, _) <-
                    replayAt
                        h
                        (historyResolved h)
                        (swapTx burning (historyTxs h))
                        (historyToken h)
                        (lastPoint h)
                result
                    `shouldBe` Left
                        ( WrongRegistry
                            (historyToken h)
                            (Just (txIdTx create))
                            CreateMint
                        )

            it "refuses a trie that is not empty at create, naming create" $ \h -> do
                ref <- newIORef emptyMPFInMemoryDB
                let trie = mkPureTrieFromRef ref
                _ <- insert trie "replay-not-empty" leafActive
                stale <- getRoot trie
                result <-
                    replayLineage
                        trie
                        (historyToken h)
                        (pointOutput (lastPoint h))
                        (pointRoot (lastPoint h))
                        (historyResolved h)
                        (historyTxs h)
                result
                    `shouldBe` Left
                        ( RootDoesNotChain
                            (historyToken h)
                            (Just (txIdTx (pointTx (historyCreate h))))
                            (RootsPart stale (pointRoot (historyCreate h)))
                        )

    describe
        "a selection the history does not reach is never an empty trie"
        $ it "refuses a selection newer than the history as incomplete"
        $ \h -> do
            let newest = lastPoint h
                txs = filter ((/= txIdTx (pointTx newest)) . txIdTx) (historyTxs h)
            (result, _) <-
                replayAt h (historyResolved h) txs (historyToken h) newest
            result
                `shouldBe` Left
                    ( HistoryIncomplete
                        (historyToken h)
                        (Just (txIdTx (pointTx newest)))
                        MissingTransaction
                    )

    describe "the registry's identity comes from create" $ do
        it "refuses a selection naming another registry's token" $ \h -> do
            let other =
                    AssetName
                        (SBS.toShort (deriveAssetName (txInToRef (historyStranger h))))
                RegistryIdentity policy _ = historyToken h
                tok = RegistryIdentity policy other
            (result, _) <-
                replayAt h (historyResolved h) (historyTxs h) tok (lastPoint h)
            result
                `shouldBe` Left
                    ( WrongRegistry
                        tok
                        (Just (txIdTx (pointTx (lastPoint h))))
                        SelectionNotState
                    )

        it "refuses a selection naming another policy" $ \h -> do
            let RegistryIdentity _ name = historyToken h
                tok = RegistryIdentity (otherPolicy h) name
            (result, _) <-
                replayAt h (historyResolved h) (historyTxs h) tok (lastPoint h)
            result
                `shouldBe` Left
                    ( WrongRegistry
                        tok
                        (Just (txIdTx (pointTx (lastPoint h))))
                        SelectionNotState
                    )

        it "refuses a create minting under another seed" $ \h -> do
            let create = pointTx (historyCreate h)
                reseeded = withMintRedeemer (Minting (txInToRef (historyStranger h))) create
            txIdTx reseeded `shouldBe` txIdTx create
            let txs = reseeded : filter ((/= txIdTx create) . txIdTx) (historyTxs h)
            (result, _) <-
                replayAt h (historyResolved h) txs (historyToken h) (lastPoint h)
            result
                `shouldBe` Left
                    ( WrongRegistry
                        (historyToken h)
                        (Just (txIdTx create))
                        SeedNotSpent
                    )

    describe "a stale selection is refused"
        $ it
            "refuses a selected root that is not the root at the selected output"
        $ \h -> do
            let newest = lastPoint h
                previous = last (init (points h))
            pointRoot previous `shouldNotBe` pointRoot newest
            (result, _) <-
                replayAt
                    h
                    (historyResolved h)
                    (historyTxs h)
                    (historyToken h)
                    newest{pointRoot = pointRoot previous}
            result
                `shouldBe` Left
                    ( StaleState
                        (historyToken h)
                        (Just (txIdTx (pointTx newest)))
                        (StaleRoot (pointRoot previous) (pointRoot newest))
                    )

    describe
        "proofs from the rebuilt trie verify against the chain's root"
        $ do
            it "proves every key of the history at create and after every fold" $ \h ->
                forM_ (points h) $ \p -> do
                    (result, db) <-
                        replayAt h (historyResolved h) (historyTxs h) (historyToken h) p
                    result `shouldSatisfy` isRight'
                    forM_ (historyKeys h) $ \key -> do
                        verdicts <- proofVerdicts db (pointRoot p) key
                        (pointLabel p, key, length (filter id verdicts))
                            `shouldBe` (pointLabel p, key, 1)

            it "does not prove a fold's root from the previous fold's trie" $ \h ->
                forM_ (zip (points h) (drop 1 (points h))) $ \(earlier, later) ->
                    when (pointRoot earlier /= pointRoot later) $ do
                        (_, db) <-
                            replayAt h (historyResolved h) (historyTxs h) (historyToken h) earlier
                        own <- forM (historyKeys h) (verifiedCount db (pointRoot earlier))
                        (pointLabel earlier, all (== 1) own)
                            `shouldBe` (pointLabel earlier, True)
                        counts <- forM (historyKeys h) (verifiedCount db (pointRoot later))
                        (pointLabel later, all (== 1) counts)
                            `shouldBe` (pointLabel later, False)

            it "does not verify a proof with one step corrupted" $ \h -> do
                let p = lastPoint h
                (_, db) <-
                    replayAt h (historyResolved h) (historyTxs h) (historyToken h) p
                trie <- trieOf db
                present <- fmap concat $ forM (historyKeys h) $ \key -> do
                    steps <- getProofSteps trie key
                    pure [(key, s) | Just s@(_ : _) <- [steps]]
                case present of
                    [] -> expectationFailure "no key of the history has a non-empty proof"
                    (key, steps) : _ -> do
                        leaf <- leafOf db (pointRoot p) key
                        verifyAikenInclusionProof
                            (unRoot (pointRoot p))
                            key
                            leaf
                            (proofBytes steps)
                            `shouldBe` True
                        verifyAikenInclusionProof
                            (unRoot (pointRoot p))
                            key
                            leaf
                            (proofBytes (corruptFirst steps))
                            `shouldBe` False

-- ---------------------------------------------------------
-- The history's shape
-- ---------------------------------------------------------

-- The chain supplied every transaction and resolution. Block heights here
-- exercise the stream contract; these component rows claim no chain height.
lineageBlocks :: History -> [LP.HistoryBlock]
lineageBlocks h =
    [ LP.HistoryBlock height (material tx NE.:| [])
    | (height, tx) <- zip [1 ..] (historyTxs h)
    ]
  where
    material tx =
        LP.HistoricalTransaction
            { LP.historicalId = txIdTx tx
            , LP.historicalCbor =
                LBS.toStrict (serialize (eraProtVerHigh @ConwayEra) tx)
            , LP.historicalTx = tx
            , LP.spentOutputs =
                resolved (Set.toAscList (tx ^. bodyTxL . inputsTxBodyL))
            , LP.referenceOutputs =
                resolved (Set.toAscList (tx ^. bodyTxL . referenceInputsTxBodyL))
            , LP.createdOutputs =
                [ (TxIn (txIdTx tx) (TxIx ix), out)
                | (ix, out) <- zip [0 ..] (toList (tx ^. bodyTxL . outputsTxBodyL))
                ]
            , LP.scriptValid = tx ^. isValidTxL == IsValid True
            }
    resolved ins =
        [(i, out) | i <- ins, Just out <- [Map.lookup i (historyResolved h)]]

lineageSession
    :: IORef [LP.HistoryBlock] -> LP.Session Evidence.NoWitness IO
lineageSession blocks =
    LP.Session
        { LP.sessionNetwork = LP.Network 42
        , LP.sessionId = Evidence.SessionId "chain-replay-component"
        , LP.sessionBinding = Evidence.Unbound
        , LP.outputs = const (pure (Left unused))
        , LP.protocolParameters = pure (Left unused)
        , LP.tipObservation = pure (Left unused)
        , LP.networkTime = pure (Left unused)
        , LP.scriptRegistered = const (pure (Left unused))
        , LP.sessionTracer = nullTracer
        , LP.history = \_ range -> do
            range `shouldBe` LP.HistoryRange Nothing Nothing
            Right . stream <$> readIORef blocks
        }
  where
    unused = LP.BackendReadFailure "this row provides only chain history"
    stream [] = LP.HistoryStream (pure (Right Nothing))
    stream (b : bs) = LP.HistoryStream (pure (Right (Just (b, stream bs))))

lineageSelection
    :: LP.Session w m -> History -> StatePoint -> TS.TrieSelection
lineageSelection session h p =
    TS.TrieSelection
        (historyToken h)
        ( TS.StatePoint
            (LP.sessionId session)
            (LP.sessionBinding session)
            (pointOutput p)
        )
        (pointRoot p)

points :: History -> [StatePoint]
points h = historyCreate h : historyFolds h

lastPoint :: History -> StatePoint
lastPoint = last . points

mixedPoint :: History -> StatePoint
mixedPoint = lastPoint

beforeMixed :: History -> StatePoint
beforeMixed = last . init . points

rebuiltChainRoot :: String
rebuiltChainRoot = "rebuilt the chain's root"

-- | What a replay to one state output did, in the words a failure report needs.
verdict
    :: History
    -> Replayed
    -> Root
    -> Either TrieFailure Replayed
    -> Root
    -> String
verdict h lineage chainRoot result rebuilt = case result of
    Right replayed
        | replayed /= lineage -> "replayed another lineage"
        | rebuilt /= chainRoot -> "rebuilt another root"
        | otherwise -> rebuiltChainRoot
    Left refusal ->
        "refused at "
            <> maybe
                "a transaction outside the history"
                pointLabel
                (failureTransaction refusal >>= pointOf)
            <> ": "
            <> show refusal
  where
    pointOf tid = case filter ((== tid) . txIdTx . pointTx) (points h) of
        p : _ -> Just p
        [] -> Nothing

-- | The fold at a position of the history, in the order it was submitted.
foldAt :: Int -> History -> StatePoint
foldAt i h = case drop i (historyFolds h) of
    p : _ -> p
    [] -> error ("the history has no fold at " <> show i)

firstFold :: String -> History -> StatePoint
firstFold label h = case filter ((== label) . pointLabel) (historyFolds h) of
    p : _ -> p
    [] -> error ("the history has no " <> label <> " fold")

-- | The state token's history, as the provider serves it.
historyTxs :: History -> [ConwayTx]
historyTxs = map pointTx . points

tokenBytes :: History -> ByteString
tokenBytes h =
    let RegistryIdentity _ (AssetName n) = historyToken h
    in  SBS.fromShort n

-- | A real policy that is not the state policy: the one the decoy's spent input pays no heed to.
otherPolicy :: History -> StatePolicyId
otherPolicy h =
    case [ p
         | PolicyID s <- Map.keys (mintOf (pointTx (firstFold "insertActive" h)))
         , let p = StatePolicyId (scriptHashBytes s)
         , let RegistryIdentity own _ = historyToken h
         , p /= own
         ] of
        p : _ -> p
        [] -> error "the insertActive fold mints under no other policy"
  where
    mintOf tx = let MultiAsset m = tx ^. bodyTxL . mintTxBodyL in m

-- | Every request key the history's resolved outputs name for this registry.
historyKeys :: History -> [ByteString]
historyKeys h =
    nub
        [ requestKey r
        | o <- Map.elems (historyResolved h)
        , Just (RequestDatum r) <- [extractCageDatum o]
        , tokenOf r == tokenBytes h
        ]

-- ---------------------------------------------------------
-- Reading a fold, independently of the replay
-- ---------------------------------------------------------

{- | A fold's own-token requests in ledger order, each with the action the
fold's @Modify@ redeemer gives it. Read here from the transaction and the
resolutions, so the coverage and the controls do not rest on the replay; a
missing or unreadable redeemer, or actions and requests in different
numbers, fail the check rather than pair short.
-}
foldPairs
    :: History -> ConwayTx -> IO [(OnChainRequest, RequestAction)]
foldPairs h tx = do
    let requests = map snd (requestInputs h tx)
    actions <- either fail pure (modifyActions h tx)
    unless (length requests == length actions) $
        fail
            ( "the fold pairs "
                <> show (length actions)
                <> " actions with "
                <> show (length requests)
                <> " requests"
            )
    pure (zip requests actions)

requestInputs :: History -> ConwayTx -> [(TxIn, OnChainRequest)]
requestInputs h tx =
    [ (i, r)
    | i <- Set.toAscList (tx ^. bodyTxL . inputsTxBodyL)
    , Just o <- [Map.lookup i (historyResolved h)]
    , Just (RequestDatum r) <- [extractCageDatum o]
    , tokenOf r == tokenBytes h
    ]

{- | The actions of the state input's @Modify@ redeemer: the spend of the
input holding the registry's token, at its position among the inputs.
-}
modifyActions :: History -> ConwayTx -> Either String [RequestAction]
modifyActions h tx =
    case [ ix
         | (ix, i) <- zip [0 ..] (Set.toAscList (tx ^. bodyTxL . inputsTxBodyL))
         , Just o <- [Map.lookup i (historyResolved h)]
         , holdsToken h o
         ] of
        [ix] -> case Map.lookup (ConwaySpending (AsIx ix)) rdmrs of
            Nothing -> Left "the state spend carries no redeemer"
            Just (d, _) -> case fromBuiltinData (BuiltinData (getPlutusData d)) of
                Just (Modify as) -> Right as
                _ -> Left "the state spend's redeemer is not Modify"
        _ -> Left "the fold spends other than one state input"
  where
    Redeemers rdmrs = tx ^. witsTxL . rdmrsTxWitsL

holdsToken :: History -> TxOut ConwayEra -> Bool
holdsToken h o =
    let MaryValue _ (MultiAsset m) = o ^. valueTxOutL
        RegistryIdentity (StatePolicyId policy) name = historyToken h
    in  sum
            [ Map.findWithDefault 0 name names
            | (PolicyID s, names) <- Map.toList m
            , scriptHashBytes s == policy
            ]
            == 1

requestTokenAt :: History -> TxIn -> Maybe ByteString
requestTokenAt h i = case Map.lookup i (historyResolved h) >>= extractCageDatum of
    Just (RequestDatum r) -> Just (tokenOf r)
    _ -> Nothing

tokenOf :: OnChainRequest -> ByteString
tokenOf r = let OnChainTokenId (BuiltinByteString b) = requestToken r in b

isRejected :: RequestAction -> Bool
isRejected Rejected = True
isRejected _ = False

isApplied :: RequestAction -> Bool
isApplied = not . isRejected

isRight' :: Either a b -> Bool
isRight' = either (const False) (const True)

-- ---------------------------------------------------------
-- Faults built from the chain's own transactions
-- ---------------------------------------------------------

setRequest :: OnChainRequest -> TxOut ConwayEra -> TxOut ConwayEra
setRequest r o = o & datumTxOutL .~ mkInlineDatum (toPlcData (RequestDatum r))

{- | A transaction as a provider serves it: written to its CBOR and read
back, so the replay sees what the bytes carry, the validity flag included.
-}
viaCbor :: ConwayTx -> IO ConwayTx
viaCbor tx =
    either (fail . ("the transaction does not decode: " <>) . show) pure $
        decodeFullAnnotator
            (eraProtVerHigh @ConwayEra)
            "transaction"
            decCBOR
            (serialize (eraProtVerHigh @ConwayEra) tx)

{- | A failed copy of a transaction, from its bytes: another identifier, the
same inputs, and @isValid = false@, so only its collateral was spent.
-}
failedCopy :: ConwayTx -> IO ConwayTx
failedCopy tx = do
    copy <- viaCbor (bumpFee tx & isValidTxL .~ IsValid False)
    unless (copy ^. isValidTxL == IsValid False) $
        fail "the failed copy does not read back as failed"
    when (txIdTx copy == txIdTx tx) $
        fail
            "the failed copy kept the identifier of the transaction it copies"
    pure copy

-- | The same transaction with a different body: same inputs, another identifier.
bumpFee :: ConwayTx -> ConwayTx
bumpFee tx = tx & bodyTxL . feeTxBodyL .~ (fee <> Coin 1)
  where
    fee = tx ^. bodyTxL . feeTxBodyL

-- | Replace every mint redeemer; the body, and so the identifier, is unchanged.
withMintRedeemer :: MintRedeemer -> ConwayTx -> ConwayTx
withMintRedeemer m tx =
    tx & witsTxL . rdmrsTxWitsL .~ Redeemers (Map.mapWithKey swap rdmrs)
  where
    Redeemers rdmrs = tx ^. witsTxL . rdmrsTxWitsL
    swap _ (d, units) = case fromBuiltinData (BuiltinData (getPlutusData d)) of
        Just (Minting _) -> (Data (toPlcData m), units)
        _ -> (d, units)

-- | Edit a transaction's outputs; its identifier changes with its body.
withOutputs
    :: ([TxOut ConwayEra] -> [TxOut ConwayEra]) -> ConwayTx -> ConwayTx
withOutputs edit tx =
    tx
        & bodyTxL . outputsTxBodyL
            .~ StrictSeq.fromList (edit (toList (tx ^. bodyTxL . outputsTxBodyL)))

{- | Replay to an edited copy of the newest fold, which replaces it in the
history and is selected at its first output with the chain's root there.
-}
replayEdited
    :: History
    -> ConwayTx
    -> ConwayTx
    -> IO (Either TrieFailure Replayed, IORef MPFInMemoryDB)
replayEdited h original edited =
    replayAt
        h
        (historyResolved h)
        (edited : filter ((/= txIdTx original) . txIdTx) (historyTxs h))
        (historyToken h)
        (lastPoint h)
            { pointTx = edited
            , pointOutput = TxIn (txIdTx edited) (TxIx 0)
            }

-- | Replay a history of one edited create, selected at its first output.
replayCreate
    :: History
    -> ConwayTx
    -> IO (Either TrieFailure Replayed, IORef MPFInMemoryDB)
replayCreate h edited =
    replayAt
        h
        (historyResolved h)
        [edited]
        (historyToken h)
        (historyCreate h)
            { pointTx = edited
            , pointOutput = TxIn (txIdTx edited) (TxIx 0)
            }

-- | A request datum, for an output that must not carry one.
decoyRequest :: OnChainRequest
decoyRequest =
    OnChainRequest
        { requestToken = OnChainTokenId (BuiltinByteString BS.empty)
        , requestOwner = BuiltinByteString (BS.replicate 28 0x11)
        , requestKey = "replay-not-a-state"
        , requestEdge = edgeInsertActive
        , requestDeposit = 0
        , requestSubmittedAt = 0
        , requestDestination = (BS.empty, Nothing)
        }

-- | Edit a transaction's redeemers; the body, and so the identifier, is unchanged.
withRedeemers
    :: ( Map (ConwayPlutusPurpose AsIx ConwayEra) (Data ConwayEra, ExUnits)
         -> Map (ConwayPlutusPurpose AsIx ConwayEra) (Data ConwayEra, ExUnits)
       )
    -> ConwayTx
    -> ConwayTx
withRedeemers edit tx = tx & witsTxL . rdmrsTxWitsL .~ Redeemers (edit rdmrs)
  where
    Redeemers rdmrs = tx ^. witsTxL . rdmrsTxWitsL

-- | The history with one transaction replaced by another under the same identifier.
swapTx :: ConwayTx -> [ConwayTx] -> [ConwayTx]
swapTx tx = map (\t -> if txIdTx t == txIdTx tx then tx else t)

-- | The input of a fold that holds the registry's token.
stateInputOf :: History -> ConwayTx -> IO TxIn
stateInputOf h tx =
    case [ i
         | i <- Set.toAscList (tx ^. bodyTxL . inputsTxBodyL)
         , Just o <- [Map.lookup i (historyResolved h)]
         , holdsToken h o
         ] of
        [i] -> pure i
        _ -> fail "the fold spends other than one state input"

-- | The redeemer purpose of a fold's state spend: its input's position among the inputs.
stateSpendPurpose
    :: History -> ConwayTx -> IO (ConwayPlutusPurpose AsIx ConwayEra)
stateSpendPurpose h tx = do
    stateIn <- stateInputOf h tx
    case elemIndex stateIn (Set.toAscList (tx ^. bodyTxL . inputsTxBodyL)) of
        Just ix -> pure (ConwaySpending (AsIx (fromIntegral ix)))
        Nothing -> fail "the state input is not among the fold's inputs"

rotate :: Int -> [a] -> [a]
rotate n xs = let k = n `mod` max 1 (length xs) in drop k xs <> take k xs

-- ---------------------------------------------------------
-- Running the replay
-- ---------------------------------------------------------

replayAt
    :: History
    -> Map TxIn (TxOut ConwayEra)
    -> [ConwayTx]
    -> RegistryIdentity
    -> StatePoint
    -> IO (Either TrieFailure Replayed, IORef MPFInMemoryDB)
replayAt _ resolved txs tok p = do
    ref <- newIORef emptyMPFInMemoryDB
    result <-
        replayLineage
            (mkPureTrieFromRef ref)
            tok
            (pointOutput p)
            (pointRoot p)
            resolved
            txs
    pure (result, ref)

trieOf :: IORef MPFInMemoryDB -> IO (Trie IO)
trieOf = pure . mkPureTrieFromRef

rootOf :: IORef MPFInMemoryDB -> IO Root
rootOf ref = trieOf ref >>= getRoot

{- | The root a fault would reach: the trie at a state output, with the given
requests' edges walked on top of it.
-}
applyOnTop :: History -> StatePoint -> [OnChainRequest] -> IO Root
applyOnTop h p rs = do
    (result, ref) <-
        replayAt h (historyResolved h) (historyTxs h) (historyToken h) p
    unless (isRight' result) $ fail ("no replay at " <> pointLabel p)
    reached <- rootOf ref
    unless (reached == pointRoot p) $
        fail
            ( "the replay at "
                <> pointLabel p
                <> " does not reach the chain's root there"
            )
    trie <- trieOf ref
    forM_ rs $ \r -> walkEdge trie (requestKey r) (requestEdge r)
    getRoot trie

-- ---------------------------------------------------------
-- Proofs, verified without the trie
-- ---------------------------------------------------------

{- | For one key, whether each answer verifies against the root: not a
member, a member with the absent leaf, the active leaf, the terminal leaf.
The proofs come from the trie; the verifier sees only bytes and the root.
-}
proofVerdicts
    :: IORef MPFInMemoryDB -> Root -> ByteString -> IO [Bool]
proofVerdicts ref (Root root) key = do
    trie <- trieOf ref
    member <- getProofSteps trie key
    excluded <- exclusionSteps ref key
    let asMember leaf =
            maybe
                False
                (verifyAikenInclusionProof root key leaf . proofBytes)
                member
    pure
        [ verifyAikenExclusionProof root key (proofBytes excluded)
        , asMember leafAbsent
        , asMember leafActive
        , asMember leafTerminal
        ]

-- | How many of a key's answers verify against the root.
verifiedCount :: IORef MPFInMemoryDB -> Root -> ByteString -> IO Int
verifiedCount ref root key = length . filter id <$> proofVerdicts ref root key

{- | The proof that a key is not in a trie: its proof in a copy of the trie
with the key inserted, which is how a proof of absence reads on chain.
-}
exclusionSteps :: IORef MPFInMemoryDB -> ByteString -> IO [ProofStep]
exclusionSteps ref key = do
    db <- readIORef ref
    copy <- mkPureTrieFromRef <$> newIORef db
    _ <- insert copy key leafActive
    fromMaybe [] <$> getProofSteps copy key

leafOf :: IORef MPFInMemoryDB -> Root -> ByteString -> IO ByteString
leafOf ref root key = do
    verdicts <- proofVerdicts ref root key
    case [ l
         | (True, l) <-
            zip (drop 1 verdicts) [leafAbsent, leafActive, leafTerminal]
         ] of
        [l] -> pure l
        _ -> fail "the key is not a member under one leaf"

{- | A proof in the encoding the verifier reads: the steps as plutus data, in
which a non-empty list is indefinite-length. The empty proof is written the
same way, as an indefinite list closed at once, where plutus data would
write a definite empty list the verifier's exact parser does not read.
-}
proofBytes :: [ProofStep] -> ByteString
proofBytes [] = BS.pack [0x9f, 0xff]
proofBytes steps = let BuiltinByteString b = serialiseData (toBuiltinData steps) in b

-- | The first step with one hash byte flipped.
corruptFirst :: [ProofStep] -> [ProofStep]
corruptFirst [] = []
corruptFirst (s : rest) = flipStep s : rest
  where
    flipStep (Branch skip ns) = Branch skip (flipByte ns)
    flipStep (Fork skip n) = Fork skip n{neighborRoot = flipByte (neighborRoot n)}
    flipStep (Leaf skip k v) = Leaf skip k (flipByte v)
    flipByte b = case BS.uncons b of
        Just (w, t) -> BS.cons (w + 1) t
        Nothing -> b
