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
output commits to ("Singular.CLI.Proof"); it reads the key's live output
at the application and reports its envelope, payload, deposit and
assets; and it labels everything with the chain point it was read at.

A leaf is printed only from a proof verified against that fresh root:
@unknown@ means a verified exclusion proof. Every other case prints no
leaf and ends in its own outcome — the node unusable
(@node-unavailable@), the mirror or the registry's trie missing
(@proof-missing@), the mirror committing to another root
(@stale-state@), no leaf proving itself (@proof-inconsistent@), or an
unresolved journalled submission (@partial@).

Inspect is also the journal's only resolver. An unresolved transaction
is resolved positively when its first output is live on the ledger — the
transaction was included — and journalled @confirmed@ and @observed@
from that readback. Nothing else resolves it: a spent output, a passed
validity window or an absent input shows nothing about whether the
transaction was ever included, so the entry stays uncertain and writes
stay refused. Negative resolution (an exclusion proven by a competing
transaction) needs the chain followed from the journalled point, which
this command does not do.
-}
module Singular.CLI.Inspect (runInspect) where

import Control.Monad (forM)
import Data.Aeson (Value, object, toJSON, (.=))

import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((^.))

import Cardano.Crypto.Hash.Blake2b (Blake2b_256)
import Cardano.Crypto.Hash.Class (hashToBytes, hashWith)
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body (outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (addrTxOutL, coinTxOutL)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Binary (decCBOR, decodeFullAnnotator)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (eraProtVerHigh)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Char (isSpace)

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
import Singular.CLI.Proof
    ( AuthError (RootMismatch)
    , authenticatedLeaf
    , leafName
    , renderAuthError
    )
import Singular.CLI.Receipt
    ( JournalEntry (..)
    , OutcomeClass (..)
    , appendJournal
    , readJournal
    , unresolved
    )
import Singular.CLI.Registry (checkNetwork, hexT, renderIdentityError)
import Singular.CLI.Session (CommandFailure (..), failWith)
import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.Node (NodeReads (..), withNodeReads)
import Singular.Registry.Provider qualified as Cage

import Control.Exception
    ( IOException
    , SomeException
    , fromException
    , throwIO
    , try
    )
import Data.List (nub)

runInspect :: InspectArgs -> IO Value
runInspect a = do
    let dir = inspectRegistry a
        Key key = inspectKey a
        NodeSettings sock magic = inspectNode a
    saved <- loadSaved dir (inspectBlueprint a)
    either
        (failWith ClientRefusal . renderIdentityError)
        pure
        (checkNetwork (savedConfig saved) magic)
    mirror <- openMirror saved
    reached <-
        try $ withNodeReads magic sock $ \nr -> do
            let prov = nrProvider nr
            point <- nrChainPoint nr
            recovered <- recoverInclusion dir prov
            live <- attachLive prov saved
            root <- either (failWith Partial) pure (observedRoot live)
            tries <- mirrorDump mirror
            db <-
                maybe
                    (failWith ProofMissing "the mirror holds no trie for this registry")
                    pure
                    (Map.lookup (savedToken saved) tries)
            leaf <- authenticatedLeaf db key root
            outs <- liveOutputs prov saved
            let chainPoint = case point of
                    Nothing -> "genesis" :: Text
                    Just (slot, h) -> T.pack (show slot) <> "." <> hexT h
                application = case liveOutputFor key outs of
                    Right ((i, o), e) ->
                        object
                            [ "output" .= txInText i
                            , "envelope" .= envelopeToJson e
                            , "payload" .= dataToJson (envPayload e)
                            , "deposit" .= ctlDeposit (envControl e)
                            , "controller" .= hexT (ctlController (envControl e))
                            , "lovelace" .= let Coin c = o ^. coinTxOutL in c
                            ]
                    Left why -> object ["absent" .= T.pack why]
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
                    ,
                        ( "recovery"
                        , toJSON
                            [ object
                                [ "tx" .= recTx r
                                , "step" .= recStep r
                                , "included" .= recIncluded r
                                , "note" .= recNote r
                                ]
                            | r <- recovered
                            ]
                        )
                    ]
            -- A recovered transaction is observed only now, after this
            -- run's fresh root and proof: the mirror commits to exactly
            -- the ledger's root, so what it made is read back.
            entriesNow <- readJournal dir
            let lastLine r = take 1 (reverse [e | e <- entriesNow, journalTxId e == recTx r])
            case leaf of
                Right _ ->
                    sequence_
                        [ appendJournal
                            dir
                            ( recoveryLine
                                e
                                "observed"
                                ( "inspect: included, and the mirror proves against the fresh root 0x"
                                    <> hexT root
                                )
                            )
                        | r <- recovered
                        , recIncluded r
                        , e <- lastLine r
                        ]
                Left _ -> pure ()
            pending <- unresolved <$> readJournal dir
            case (pending, leaf) of
                (Just e, _) ->
                    pure $
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
                                            , "status" .= ("uncertain" :: Text)
                                            ]
                                       )
                                   ]
                            )
                (Nothing, Left err@(RootMismatch _ _)) ->
                    pure
                        ( receipt
                            "inspect"
                            StaleState
                            (labels <> [("refusal", toJSON (renderAuthError err))])
                        )
                (Nothing, Left err) ->
                    pure
                        ( receipt
                            "inspect"
                            ProofInconsistent
                            (labels <> [("refusal", toJSON (renderAuthError err))])
                        )
                (Nothing, Right l) ->
                    pure
                        (receipt "inspect" Success (labels <> [("leaf", toJSON (leafName l))]))
    case reached of
        Right v -> pure v
        Left (e :: SomeException) -> case fromException e of
            Just (failure :: CommandFailure) -> throwIO failure
            Nothing ->
                failWith
                    NodeUnavailable
                    ("the node at " <> sock <> " could not be read: " <> show e)

-- | What recovery found for one unresolved transaction.
data Recovery = Recovery
    { recTx :: Text
    , recStep :: Text
    , recIncluded :: Bool
    -- ^ Its first output is live: the transaction was included
    , recNote :: Text
    }

{- | Look for positive inclusion evidence for each unresolved transaction.
The saved body must be the one its @prepared@ line names — the same
BLAKE2b-256 of its bytes and the same derived transaction id — or it is
not used, and the entry stays unresolved with that reason. A body that
passes, whose first output is live, was included: this journals
@confirmed@ (when missing). It does not journal @observed@; the caller
does that only after its own fresh root and proof readback. A spent
first output, or no body, shows nothing either way.
-}
recoverInclusion :: FilePath -> Cage.Provider IO -> IO [Recovery]
recoverInclusion dir prov = do
    entries <- readJournal dir
    let lastOf t = last [e | e <- entries, journalTxId e == t]
        settled = ["observed", "rejected", "excluded"]
        open =
            [ lastOf t
            | t <- nub (map journalTxId entries)
            , journalEvent (lastOf t) `notElem` settled
            ]
    forM open $ \e -> do
        let txid = journalTxId e
            prepared =
                [ p | p <- entries, journalTxId p == txid, journalEvent p == "prepared"
                ]
            miss why = pure (Recovery txid (journalStep e) False why)
        case prepared of
            (p : _)
                | Just path <- journalBody p
                , Just wantHash <- journalBodyHash p -> do
                    read' <- try (BS.readFile path)
                    case read' of
                        Left (_ :: IOException) -> miss "the saved body is missing"
                        Right hexBytes -> case B16.decode (BC.filter (not . isSpace) hexBytes) of
                            Left _ -> miss "the saved body is not hex"
                            Right raw
                                | hexT (hashToBytes (hashWith @Blake2b_256 id raw)) /= wantHash ->
                                    miss "the saved body's hash differs from its prepared line"
                                | otherwise -> case decodeFullAnnotator
                                    (eraProtVerHigh @ConwayEra)
                                    "transaction"
                                    decCBOR
                                    (BL.fromStrict raw) of
                                    Left _ -> miss "the saved body does not decode"
                                    Right (tx :: ConwayTx)
                                        | txIdHexOf tx /= txid ->
                                            miss "the saved body is another transaction"
                                        | otherwise -> case toList (tx ^. bodyTxL . outputsTxBodyL) of
                                            [] -> miss "the saved body has no outputs"
                                            (out0 : _) -> do
                                                live <- Cage.queryUTxOs prov (out0 ^. addrTxOutL)
                                                if any ((== TxIn (txIdTx tx) (TxIx 0)) . fst) live
                                                    then do
                                                        if journalEvent e == "confirmed"
                                                            then pure ()
                                                            else
                                                                appendJournal
                                                                    dir
                                                                    (recoveryLine e "confirmed" "its first output is live on the ledger")
                                                        pure
                                                            (Recovery txid (journalStep e) True "included: first output live")
                                                    else miss "its first output is not live; inclusion is unknown"
            _ -> miss "no prepared line names a saved body"

-- | A journal line inspect appends for a recovered transaction.
recoveryLine :: JournalEntry -> Text -> Text -> JournalEntry
recoveryLine e event detail =
    e
        { journalCommand = "inspect"
        , journalEvent = event
        , journalDetail = Just detail
        , journalInputs = Nothing
        , journalTipSlot = Nothing
        , journalBody = Nothing
        , journalBodyHash = Nothing
        , journalChainPoint = Nothing
        }

txIdHexOf :: ConwayTx -> Text
txIdHexOf tx = let TxId h = txIdTx tx in hexT (hashToBytes (extractHash h))
