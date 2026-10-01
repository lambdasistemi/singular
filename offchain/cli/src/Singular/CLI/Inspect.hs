{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Singular.CLI.Inspect
Description : @singular registry inspect@: a key read back, key-free, against the ledger's root
License     : Apache-2.0

Inspect takes a node socket and magic and nothing else: no signing key,
no funding, no submission. It reads the registry's state output fresh
and proves the key's leaf from the saved mirror against the root that
output commits to ("Singular.CLI.Proof"); it reads the key's holding at
the application — bound to this registry's state asset, pinned active
policy and key — and reports its envelope, payload, deposit and value;
and it labels everything with the chain point it was read at.

A leaf is printed only from a proof verified against that fresh root,
and only when the holdings agree with it: @active@ with exactly one
holding, any other leaf with none. @unknown@ means a verified exclusion
proof. Every other case prints no leaf and ends in its own outcome — the
node unusable (@node-unavailable@), the mirror or the registry's trie
missing (@proof-missing@), the mirror committing to another root
(@stale-state@), no leaf proving itself or a leaf the holdings
contradict (@proof-inconsistent@), or an unresolved journalled
submission (@partial@).

Before reading, inspect reconciles the journal from the same view, as
every write does ("Singular.CLI.Reconcile"): an interrupted local commit
the chain evidences is applied at most once and observed, for whichever
key it concerns. It does so only while holding the registry's lock; when
another process holds it, inspect reads without reconciling and says so.
-}
module Singular.CLI.Inspect (runInspect) where

import Control.Exception
    ( SomeException
    , fromException
    , throwIO
    , try
    )
import Data.Aeson (Value, object, toJSON, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word32)
import Lens.Micro ((^.))
import System.Directory (doesFileExist)

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Api.Scripts.Data
    ( Datum (..)
    , binaryDataToData
    , hashBinaryData
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, coinTxOutL, datumTxOutL)
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (eraProtVerHigh)
import Cardano.Ledger.Hashes (extractHash)

import Singular.Application.OpenDatum.Envelope
    ( Control (..)
    , Envelope (..)
    , dataToJson
    , envelopeToJson
    )
import Singular.CLI.Command
    ( InspectArgs (..)
    , Key (..)
    , NodeSettings (..)
    )
import Singular.CLI.Live
import Singular.CLI.Node (withReads)
import Singular.CLI.Proof
    ( AuthError (RootMismatch)
    , Leaf (..)
    , authenticatedLeaf
    , leafName
    , renderAuthError
    )
import Singular.CLI.Receipt
    ( JournalEntry (..)
    , OutcomeClass (..)
    , caseName
    , readJournal
    , submissionCase
    , unresolved
    )
import Singular.CLI.Reconcile
    ( Reconciliation (..)
    , reconcile
    , reconcileIncomplete
    , recoveryJson
    , renderPoint
    )
import Singular.CLI.Registry
    ( checkNetwork
    , configPath
    , hexT
    , pendingPath
    , renderIdentityError
    )
import Singular.CLI.Session
    ( CommandFailure (..)
    , failWith
    , withTargetLockOr
    )
import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.Provider qualified as Cage

runInspect :: InspectArgs -> IO Value
runInspect a = do
    let dir = inspectRegistry a
        Key key = inspectKey a
        NodeSettings sock magic = inspectNode a
    complete <- doesFileExist (configPath dir)
    pending <- doesFileExist (pendingPath dir)
    if not complete && pending
        then inspectIncompleteCreate dir sock magic
        else inspectSaved dir key sock magic a

{- | Reconcile under the registry's lock, or not at all when another
process holds it.
-}
reconcileLocked
    :: FilePath -> IO Reconciliation -> IO (Maybe Reconciliation)
reconcileLocked dir act = withTargetLockOr dir (Just <$> act) (pure Nothing)

-- | The receipt fields of a reconciliation, or why none ran.
reconciledFields :: Maybe Reconciliation -> [(Text, Value)]
reconciledFields = \case
    Just r ->
        [ ("rolledBack", toJSON (rcRolledBack r))
        , ("recovery", recoveryJson (rcRecovered r))
        , ("excluded", toJSON (rcExcluded r))
        , ("mirrorRewound", toJSON (rcRewound r))
        , ("mirrorAdvanced", toJSON (rcApplied r))
        , ("stateFollowed", toJSON (rcStateFollowed r))
        , ("observed", toJSON (rcObserved r))
        ]
    Nothing ->
        [ ("rolledBack", toJSON ([] :: [Text]))
        , ("recovery", toJSON ([] :: [Value]))
        , ("excluded", toJSON ([] :: [Text]))
        , ("mirrorAdvanced", toJSON ([] :: [Text]))
        , ("observed", toJSON ([] :: [Text]))
        ,
            ( "reconciliation"
            , toJSON
                ("skipped: another singular process holds the registry's lock" :: Text)
            )
        ]

{- | A create that stopped before saving its identity: its pending identity
and journal are read, its journalled transactions are looked for on the
ledger (confirmed, and observed where their own after-state reads back),
and the outcome is @partial@ with no leaf. Create refuses the directory;
nothing is booted again or resubmitted.
-}
inspectIncompleteCreate :: FilePath -> FilePath -> Word32 -> IO Value
inspectIncompleteCreate dir sock magic = do
    identity <-
        Aeson.eitherDecodeFileStrict' (pendingPath dir)
            >>= either (failWith ClientRefusal) (pure :: Value -> IO Value)
    reached <-
        try $ withReads magic sock $ \prov -> Cage.withView prov $ \v -> do
            let point = Cage.viewPoint v
            reconciled <-
                reconcileLocked dir (reconcileIncomplete "inspect" dir v)
            pending <- unresolved <$> readJournal dir
            pure $
                receipt
                    "inspect"
                    Partial
                    ( [ ("incompleteCreate", identity)
                      ,
                          ( "chainPoint"
                          , toJSON (renderPoint point)
                          )
                      ]
                        <> reconciledFields reconciled
                        <> [ ("unresolved", toJSON (journalTxId <$> pending))
                           ,
                               ( "reason"
                               , toJSON
                                    ( "create did not finish: its identity is recorded but \
                                      \its registry was not saved; create refuses this \
                                      \directory and nothing is resubmitted"
                                        :: Text
                                    )
                               )
                           ]
                    )
    case reached of
        Right v -> pure v
        Left (e :: SomeException) -> case fromException e of
            Just (failure :: CommandFailure) -> throwIO failure
            Nothing ->
                failWith
                    NodeUnavailable
                    ("the node at " <> sock <> " could not be read: " <> show e)

{- | The inline datum an output carries, as the ledger holds it: its bytes,
and their BLAKE2b-256 hash, both hex. A public indexer's copy of the same
output is compared against these.
-}
inlineDatum :: TxOut ConwayEra -> Maybe (Text, Text)
inlineDatum o = case o ^. datumTxOutL of
    Datum binary ->
        Just
            ( hexT
                (serialize' (eraProtVerHigh @ConwayEra) (binaryDataToData binary))
            , hexT (hashToBytes (extractHash (hashBinaryData binary)))
            )
    _ -> Nothing

inspectSaved
    :: FilePath
    -> ByteString
    -> FilePath
    -> Word32
    -> InspectArgs
    -> IO Value
inspectSaved dir key sock magic a = do
    saved <- loadSaved dir (inspectBlueprint a)
    either
        (failWith ClientRefusal . renderIdentityError)
        pure
        (checkNetwork (savedConfig saved) magic)
    -- Missing proof material is refused before the node is contacted.
    _ <- openMirror saved
    reached <-
        try $ withReads magic sock $ \prov -> Cage.withView prov $ \v -> do
            let point = Cage.viewPoint v
            reconciled <- reconcileLocked dir (reconcile "inspect" dir saved v)
            live <- attachLive v saved
            root <- either (failWith Partial) pure (observedRoot live)
            mirror <- openMirror saved
            tries <- mirrorDump mirror
            db <-
                maybe
                    (failWith ProofMissing "the mirror holds no trie for this registry")
                    pure
                    (Map.lookup (savedToken saved) tries)
            leaf <- authenticatedLeaf db key root
            outs <- liveOutputs v saved
            let holdings = holdingsFor saved key outs
                keyOutput = liveOutputFor saved key outs
            entries <- readJournal dir
            let pending = unresolved entries
            let chainPoint = renderPoint point
                application = case keyOutput of
                    Right ((i, o), e) ->
                        object
                            [ "output" .= txInText i
                            , "envelope" .= envelopeToJson e
                            , "payload" .= dataToJson (envPayload e)
                            , "deposit" .= ctlDeposit (envControl e)
                            , "controller" .= hexT (ctlController (envControl e))
                            , "lovelace" .= let Coin c = o ^. coinTxOutL in c
                            , "datumCbor" .= fmap fst (inlineDatum o)
                            , "datumHash" .= fmap snd (inlineDatum o)
                            ]
                    Left why ->
                        object
                            [ "absent" .= T.pack why
                            , "holdings" .= map (txInText . fst . fst) holdings
                            ]
                labels =
                    [ ("key", toJSON (hexT key))
                    , ("chainPoint", toJSON chainPoint)
                    , ("mechanism", toJSON ("node-to-client local state query" :: Text))
                    ,
                        ( "freshness"
                        , toJSON ("read at the chain point above, in this process" :: Text)
                        )
                    , ("root", toJSON (hexT root))
                    , ("applicationOutput", application)
                    ]
                        <> reconciledFields reconciled
                agrees = \case
                    Active -> length holdings == 1
                    _ -> null holdings
            pure $ case (pending, leaf) of
                (Just e, _) ->
                    receipt
                        "inspect"
                        Partial
                        ( labels
                            <> [
                                   ( "unresolved"
                                   , object
                                        [ "tx" .= journalTxId e
                                        , "step" .= journalStep e
                                        , "lastPhase" .= journalEvent e
                                        , "case" .= (caseName <$> submissionCase entries (journalTxId e))
                                        , "status" .= ("uncertain" :: Text)
                                        ]
                                   )
                               ]
                        )
                (Nothing, Left err@(RootMismatch _ _)) ->
                    receipt
                        "inspect"
                        StaleState
                        (labels <> [("refusal", toJSON (renderAuthError err))])
                (Nothing, Left err) ->
                    receipt
                        "inspect"
                        ProofInconsistent
                        (labels <> [("refusal", toJSON (renderAuthError err))])
                (Nothing, Right l)
                    | agrees l ->
                        receipt "inspect" Success (labels <> [("leaf", toJSON (leafName l))])
                    | otherwise ->
                        receipt
                            "inspect"
                            ProofInconsistent
                            ( labels
                                <> [
                                       ( "refusal"
                                       , toJSON
                                            ( "the proven leaf and this registry's holdings of the key disagree: "
                                                <> leafName l
                                                <> " with "
                                                <> T.pack (show (length holdings))
                                                <> " holding(s)"
                                            )
                                       )
                                   ]
                            )
    case reached of
        Right v -> pure v
        Left (e :: SomeException) -> case fromException e of
            Just (failure :: CommandFailure) -> throwIO failure
            Nothing ->
                failWith
                    NodeUnavailable
                    ("the node at " <> sock <> " could not be read: " <> show e)
