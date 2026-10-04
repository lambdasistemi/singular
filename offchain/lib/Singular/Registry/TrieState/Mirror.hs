{-# LANGUAGE RankNTypes #-}

{- | The current durable mirror behind TrieState. Selection and accepted
history are caller-session observations; this adapter adds application
proofs, never ledger authentication. Mirror serialization stays unchanged.
-}
module Singular.Registry.TrieState.Mirror
    ( MirrorStore
    , openStoredMirror
    , storedRoot
    , mirrorTrieState
    , createStoredMirror
    , replaceFromHistory
    , TrieObservation (..)
    , checkedCreateRecord
    , checkedFoldRecord
    ) where

import Control.Monad (foldM, when)
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Lens.Micro ((^.))
import MPF.Backend.Pure (MPFInMemoryDB, emptyMPFInMemoryDB)
import System.Directory (doesFileExist)

import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( inputsTxBodyL
    , mintTxBodyL
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, valueTxOutL)
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.Data (getPlutusData)
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import PlutusTx.Builtins.Internal (BuiltinData (..))
import PlutusTx.IsData.Class (FromData (..))

import Singular.Registry.Deployment
    ( loadMirror
    , mirrorPathFor
    , saveMirror
    )
import Singular.Registry.Ledger
    ( AssetName
    , ConwayEra
    , Root (..)
    , TokenId (..)
    )
import Singular.Registry.Trie.Pure (rootFromDb)
import Singular.Registry.TrieState
import Singular.Registry.TrieState.Core
    ( TrieEntry (..)
    , capabilityObserved
    , checkedCoverage
    , walkNodes
    )
import Singular.Registry.TrieState.Types (TrieObservation (..))
import Singular.Registry.TxBuilder.Internal.Identity
    ( extractCageDatum
    , scriptHashBytes
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRoot (..)
    , OnChainTokenState (..)
    , RequestAction (..)
    , UpdateRedeemer (..)
    )

data MirrorStore
    = MirrorStore
        FilePath
        RegistryIdentity
        (IORef (Map.Map TokenId MPFInMemoryDB))

tokenOf :: RegistryIdentity -> TokenId
tokenOf (RegistryIdentity _ name) = TokenId name

openStoredMirror
    :: FilePath -> RegistryIdentity -> IO (Either TrieFailure MirrorStore)
openStoredMirror path who = do
    there <- doesFileExist (mirrorPathFor path)
    if not there
        then pure (Left MissingProof)
        else do
            nodes <- loadMirror path
            if Map.member (tokenOf who) nodes
                then Right . MirrorStore path who <$> newIORef nodes
                else pure (Left MissingProof)

storedRoot :: MirrorStore -> IO (Either TrieFailure Root)
storedRoot (MirrorStore _ who ref) = do
    nodes <- readIORef ref
    pure
        ( maybe
            (Left MissingProof)
            (Right . rootFromDb)
            (Map.lookup (tokenOf who) nodes)
        )

{- | Capture independently observed selection with checked local history.
All reads subsequently pass through the common capability validation.
-}
mirrorTrieState
    :: MirrorStore
    -> TrieSelection
    -> CreateRecord
    -> [ObservedFold]
    -> (TrieObservation -> IO ())
    -> IO (TrieState IO)
mirrorTrieState (MirrorStore path who ref) chosen create events observe = do
    context <- newIORef (chosen, events)
    let fetch wanted
            | wanted /= who = pure (Left WrongRegistry)
            | otherwise = do
                nodes <- readIORef ref
                (current, history) <- readIORef context
                pure $ case Map.lookup (tokenOf who) nodes of
                    Nothing -> Left MissingProof
                    Just db -> Right (TrieEntry current (Just create) history db)
        persist entry = do
            nodes <- readIORef ref
            let changed = Map.insert (tokenOf who) (entryNodes entry) nodes
            -- Same whole-file durable replacement and map ordering as before.
            saveMirror path changed
            writeIORef ref changed
            writeIORef context (entrySelection entry, entryFolds entry)
    pure (capabilityObserved fetch persist observe)

createStoredMirror
    :: FilePath
    -> TrieSelection
    -> ConwayTx
    -> (TrieObservation -> IO ())
    -> IO (Either TrieFailure ())
createStoredMirror path chosen tx observe = case checkedCreateRecord (trieSelectionIdentity chosen) tx of
    Left why -> pure (Left why)
    Right create@(CreateRecord _ output)
        | pointOutput (trieSelectionPoint chosen) /= output ->
            pure (Left StaleState)
        | otherwise -> case checkedCoverage (TrieEntry chosen (Just create) [] emptyMPFInMemoryDB) of
            Left why -> pure (Left why)
            Right _ -> do
                saveMirror
                    path
                    ( Map.singleton
                        (tokenOf (trieSelectionIdentity chosen))
                        emptyMPFInMemoryDB
                    )
                observe (Created chosen)
                pure (Right ())

{- | Rewind only through reproduced recorded folds, then use the unchanged
durable writer. The caller retains its existing rollback/hold-point order.
-}
replaceFromHistory
    :: MirrorStore
    -> TrieSelection
    -> CreateRecord
    -> [ObservedFold]
    -> IO (Either TrieFailure ())
replaceFromHistory (MirrorStore path who ref) chosen create events
    | trieSelectionIdentity chosen /= who = pure (Left WrongRegistry)
    | otherwise = case foldM replay emptyMPFInMemoryDB events of
        Left why -> pure (Left why)
        Right db -> case checkedCoverage (TrieEntry chosen (Just create) events db) of
            Left why -> pure (Left why)
            Right _ -> do
                nodes <- readIORef ref
                let changed = Map.insert (tokenOf who) db nodes
                saveMirror path changed
                writeIORef ref changed
                pure (Right ())
  where
    replay db (ObservedFold from to moves)
        | trieSelectionRoot from == trieSelectionRoot to = Right db
        | trieSelectionRoot from /= rootFromDb db = Left RootDoesNotChain
        | otherwise = do
            (changed, walked) <- walkNodes db moves
            if walkRoot walked == trieSelectionRoot to
                then Right changed
                else Left RootDoesNotChain

{- | A checked create comes from the actual accepted boot's state output and
mint, not a caller-supplied empty-root assertion.
-}
checkedCreateRecord
    :: RegistryIdentity -> ConwayTx -> Either TrieFailure CreateRecord
checkedCreateRecord who tx = do
    (_, root) <- stateOutput who tx
    when (root /= rootFromDb emptyMPFInMemoryDB) (Left RootDoesNotChain)
    let MultiAsset minted = tx ^. bodyTxL . mintTxBodyL
    if quantity who minted /= 1
        then Left WrongRegistry
        else Right (CreateRecord who (TxIn (txIdTx tx) (TxIx 0)))

{- | Bind the recorded after-root and old state input to the real signed body.
It is an application observation; inclusion remains the caller's protocol.
-}
checkedFoldRecord
    :: SessionId
    -> RegistryIdentity
    -> Root
    -> Root
    -> NonEmpty (ByteString, Integer)
    -> ConwayTx
    -> Either TrieFailure ObservedFold
checkedFoldRecord sid who before after moves tx = do
    (output, root) <- stateOutput who tx
    when (root /= after) (Left RootDoesNotChain)
    let Redeemers redeemers = tx ^. witsTxL . rdmrsTxWitsL
        inputs = Set.toAscList (tx ^. bodyTxL . inputsTxBodyL)
        candidates =
            [ input
            | (ConwaySpending (AsIx index), (datum, _)) <- Map.toList redeemers
            , Just (Modify actions) <-
                [fromBuiltinData (BuiltinData (getPlutusData datum))]
            , length actions == length moves
            , all isUpdate actions
            , input : _ <- [drop (fromIntegral index) inputs]
            ]
    input <- case candidates of
        [one] -> Right one
        _ -> Left UndecodableRequest
    pure
        ( ObservedFold
            (TrieSelection who (StatePoint sid Unbound input) before)
            (TrieSelection who (StatePoint sid Unbound output) after)
            moves
        )
  where
    isUpdate (Update _) = True
    isUpdate _ = False

stateOutput
    :: RegistryIdentity -> ConwayTx -> Either TrieFailure (TxIn, Root)
stateOutput who tx = case toList (tx ^. bodyTxL . outputsTxBodyL) of
    first : _
        | holdsIdentity who first
        , Just (StateDatum st) <- extractCageDatum first ->
            Right (TxIn (txIdTx tx) (TxIx 0), Root (unOnChainRoot (stateRoot st)))
    _ -> Left WrongRegistry

holdsIdentity :: RegistryIdentity -> TxOut ConwayEra -> Bool
holdsIdentity who out =
    let MaryValue _ (MultiAsset assets) = out ^. valueTxOutL
    in  quantity who assets == 1
quantity
    :: RegistryIdentity
    -> Map.Map PolicyID (Map.Map AssetName Integer)
    -> Integer
quantity (RegistryIdentity (StatePolicyId policy) name) assets =
    sum
        [ Map.findWithDefault 0 name names
        | (PolicyID actual, names) <- Map.toList assets
        , scriptHashBytes actual == policy
        ]
