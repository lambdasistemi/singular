{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.State.StateLineageSpec
Description : A registry's trie is rebuilt from its own folds on the chain
License     : Apache-2.0

As a reader of the chain who booked nothing I rebuild the trie of a registry
from the history of its state token: the transaction that created it, then each
fold that spent the state in turn. Every root I rebuild is checked against the
root the chain recorded, and a history that does not chain is refused by name.
-}
module Singular.State.StateLineageSpec
    ( spec
    ) where

import Control.Monad (join)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Lens.Micro ((&), (.~))
import Test.Hspec

import Cardano.Ledger.Alonzo.Tx (IsValid (..))
import Cardano.Ledger.Api.Tx (isValidTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Out (datumTxOutL)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.TxIn (TxId, TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import MPF.Backend.Pure (MPFInMemoryDB)

import Singular.Registry.Ledger (Root (..))
import Singular.Registry.LedgerProvider (Session (..))
import Singular.Registry.RawChainFixture (recordTransaction)
import Singular.Registry.Trie.Pure (rootFromDb)
import Singular.Registry.TrieState
    ( Leaf (..)
    , Mismatch (..)
    , Parting (..)
    , RegistryIdentity (..)
    , Staleness (..)
    , StatePoint (..)
    , TrieFailure (..)
    , TrieSelection (..)
    , TrieState (..)
    , leafAt
    )
import Singular.Registry.TxBuilder.Internal (mkInlineDatum)
import Singular.State.Fold (buildRegistrationFold)
import Singular.State.Lineage
    ( Replayed (..)
    , registryTrieState
    , replayRegistry
    )
import Singular.State.Records (stateDatum)
import Singular.State.Script (statePolicy)
import Singular.State.StateWorld

spec :: Spec
spec = do
    describe "a registry that no fold has touched" $ do
        it "has the empty trie, and names its seed and its genesis" $ do
            rg <- newRegistered
            result <- replayAt rg (rgState rg) zeroRoot
            (replayed, nodes) <- expectReplayed result
            replayedSeed replayed `shouldBe` seedOf
            replayedGenesis replayed `shouldBe` txIdOf (rgState rg)
            replayedFolds replayed `shouldBe` []
            rootFromDb nodes `shouldBe` Root zeroRoot

    describe "a registry that folds have changed" $ do
        it
            "has the keys they registered and the root the chain recorded, from the genesis on"
            $ do
                rg <- newRegistered
                (first, stateAfterFirst) <- foldAndApply rg 'p' ["key one", "key two"]
                (second, stateAfterSecond) <- foldAndApply rg 'q' ["key three"]
                result <-
                    replayAt
                        rg
                        stateAfterSecond
                        (oracleRoot ["key one", "key two", "key three"])
                (replayed, nodes) <- expectReplayed result
                replayedFolds replayed `shouldBe` [txIdTx first, txIdTx second]
                rootFromDb nodes
                    `shouldBe` Root (oracleRoot ["key one", "key two", "key three"])
                -- the trie of the first fold alone is a prefix of the history
                earlier <-
                    replayAt rg stateAfterFirst (oracleRoot ["key one", "key two"])
                fmap (replayedFolds . fst) earlier `shouldBe` Right [txIdTx first]

        it "serves a snapshot that knows its keys and not the others" $ do
            rg <- newRegistered
            (_, stateAfter) <- foldAndApply rg 'p' ["key one"]
            let root = oracleRoot ["key one"]
            known <- leafIn rg stateAfter root "key one"
            unknown <- leafIn rg stateAfter root "key two"
            known `shouldBe` Right Active
            unknown `shouldBe` Right Unknown

    describe "a history that does not chain" $ do
        it
            "is refused when the root a fold recorded is not the root its changes give"
            $ do
                rg <- newRegistered
                (fold, _) <- builtFold rg 'p' ["key one"]
                -- the same fold, with another root written into its state output
                let forgedRoot = oracleRoot ["somebody else"]
                    forged = rewriteRoot rg forgedRoot fold
                applyTx (rgWorld rg) forged
                let forgedState = stateRefOf rg forged
                result <- replayAt rg forgedState forgedRoot
                result `shouldSatisfy` \case
                    Left (RootDoesNotChain _ (Just fid) (RootsPart rebuilt recorded)) ->
                        fid == txIdTx forged
                            && rebuilt == Root (oracleRoot ["key one"])
                            && recorded == Root forgedRoot
                    _ -> False

        it "leaves out a fold whose bytes say it failed its scripts" $ do
            rg <- newRegistered
            -- built against the same state, recorded as a transaction that failed
            (poisoned, _) <- builtFold rg 'p' ["key one"]
            recordTransaction
                (worldChain (rgWorld rg))
                (poisoned & isValidTxL .~ IsValid False)
            (fold, state) <- foldAndApply rg 'q' ["key two"]
            result <- replayAt rg state (oracleRoot ["key two"])
            (replayed, _) <- expectReplayed result
            replayedFolds replayed `shouldBe` [txIdTx fold]

        it
            "is refused when the selection's root is not the root the chain recorded"
            $ do
                rg <- newRegistered
                (_, stateAfter) <- foldAndApply rg 'p' ["key one"]
                result <- replayAt rg stateAfter (oracleRoot ["key two"])
                result `shouldSatisfy` \case
                    Left (StaleState _ _ (StaleRoot _ _)) -> True
                    _ -> False

        it
            "is refused when the selection is not a state output of the registry"
            $ do
                rg <- newRegistered
                result <- replayAt rg (TxIn (txIdOf (rgState rg)) (TxIx 1)) zeroRoot
                result `shouldSatisfy` \case
                    Left (WrongRegistry _ _ SelectionNotState) -> True
                    _ -> False
  where
    zeroRoot = BS.replicate 32 0

-- | The selection of this output of the registry, with the root the chain is expected to record there.
selectionOf
    :: Registered -> Session w m -> TxIn -> ByteString -> TrieSelection
selectionOf rg session state root =
    TrieSelection
        { trieSelectionIdentity = rgRegistry rg
        , trieSelectionPoint =
            StatePoint (sessionId session) (sessionBinding session) state
        , trieSelectionRoot = Root root
        }

replayAt
    :: Registered
    -> TxIn
    -> ByteString
    -> IO (Either TrieFailure (Replayed, MPFInMemoryDB))
replayAt rg state root =
    withSession (rgWorld rg) $ \session ->
        replayRegistry session (selectionOf rg session state root)

expectReplayed :: Either TrieFailure a -> IO a
expectReplayed = \case
    Right replayed -> pure replayed
    Left failure -> do
        expectationFailure ("the history was refused: " <> show failure)
        fail "no replay"

-- | What the snapshot of a registry knows of a key.
leafIn
    :: Registered
    -> TxIn
    -> ByteString
    -> ByteString
    -> IO (Either TrieFailure Leaf)
leafIn rg state root key =
    withSession (rgWorld rg) $ \session -> do
        outcome <-
            withTrieState
                (registryTrieState session)
                (selectionOf rg session state root)
                (`leafAt` key)
        pure (join outcome)

-- | Book keys, build their fold, apply it, and name the state output it leaves.
foldAndApply
    :: Registered -> Char -> [ByteString] -> IO (ConwayTx, TxIn)
foldAndApply rg tag keys = do
    (tx, state) <- builtFold rg tag keys
    applyTx (rgWorld rg) tx
    pure (tx, state)

builtFold :: Registered -> Char -> [ByteString] -> IO (ConwayTx, TxIn)
builtFold rg tag keys = do
    refs <- book rg tag [bookedKey k processingDeadline | k <- keys]
    tx <-
        withSession (rgWorld rg) $ \session ->
            buildRegistrationFold
                session
                (rgScript rg)
                standInApplication
                (rgRegistry rg)
                refs
                (rgFolder rg)
                >>= expectBuilt
    pure (tx, stateRefOf rg tx)

-- | The state output a fold leaves.
stateRefOf :: Registered -> ConwayTx -> TxIn
stateRefOf rg tx =
    TxIn
        (txIdTx tx)
        ( TxIx
            ( fromIntegral
                ( holderIndex
                    (statePolicy (rgScript rg))
                    (nameOf (rgRegistry rg))
                    tx
                )
            )
        )
  where
    nameOf (RegistryIdentity _ name) = name

-- | The same transaction with another root in its state output.
rewriteRoot :: Registered -> ByteString -> ConwayTx -> ConwayTx
rewriteRoot rg root tx =
    let TxIn _ (TxIx ix) = stateRefOf rg tx
    in  mapOutput
            (fromIntegral ix)
            (\out -> out & datumTxOutL .~ mkInlineDatum (stateDatum root))
            tx

txIdOf :: TxIn -> TxId
txIdOf (TxIn txid _) = txid
