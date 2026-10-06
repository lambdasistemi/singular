{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.Entry
Description : @singular registry insert|update|terminate@ over an attached open-datum registry
License     : Apache-2.0

Each write attaches first ("Singular.CLI.Attached"): the saved identity
is re-derived and checked, the network must be the saved one, the journal
is reconciled ("Singular.CLI.Reconcile") and must then hold no
unresolved submission, the reference outputs and the state
output are resolved, and the public replay must commit to exactly the
root the ledger holds. The command then calls the production builders —
it decides no validator or fold rule itself — journals every submission,
and reads back what each made before journalling it @observed@.

Authority over a key is its envelope's controller, never the wallet that
created the registry: any wallet may insert an envelope naming itself as
controller, and only that controller may update or terminate it.

* __insert__: the caller's envelope must name this registry, its active
  policy, the key and the caller's own payment key as controller. The
  booking certifies it through the application and leaves its request
  pending; the registry's fold ("Singular.CLI.Fold") later delivers the
  key's active token to an output at the application carrying the
  envelope inline, and the replay then proves the key @Active@. The request
  carries the envelope itself, so any wallet can fold it from the chain.
* __update__: the caller must be the live envelope's controller. The live
  output is spent with @Update@ and recreated with the new payload. The
  registry does not move.
* __terminate__: the caller must be the live envelope's controller. The
  booking reads the live output by reference and leaves its request
  pending; the fold spends the output with @Release@, burns its token, and
  pays the deposit back with the booking's. The replay then proves the key
  @Terminal@.

An insert or a terminate submits the booking and nothing else: the trie,
the root do not move, and the receipt names the pending
request and the deadline by which it must be folded. With @--fold@ the
same command then runs that fold, by the routine @registry fold@ runs,
once the booking has confirmed.
-}
module Singular.CLI.Entry
    ( runInsert
    , runUpdate
    , runTerminate
    ) where

import Control.Monad (unless, when)
import Data.Aeson (Value, toJSON)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as T

import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.BaseTypes (Network (Testnet), TxIx (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Application.OpenDatum.Envelope
    ( Control (..)
    , Envelope (..)
    , dataFromJson
    , dataToJson
    , envelopeHash
    , envelopeToJson
    )
import Singular.CLI.Attached
import Singular.CLI.Command
    ( EntryArgs (..)
    , EntryMode (..)
    , Key (..)
    )
import Singular.CLI.Fold
    ( Deadline (..)
    , Delivery (..)
    , FoldOrigin (..)
    , FoldSpec (..)
    , Folded (..)
    , deadlineJson
    , deadlineOf
    , foldPending
    )
import Singular.CLI.Live
import Singular.CLI.Outlay
    ( bookingOutlay
    , updateOutlay
    )
import Singular.CLI.Plan
import Singular.CLI.Preview (Kind (..), runPreview)
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Registry (hexT, keyFields)
import Singular.CLI.Session
import Singular.CLI.Trace
    ( EdgeAction (..)
    , Scope (..)
    , What (EdgeStarted, RootSeen, Updated)
    , report
    )
import Singular.CLI.Trace qualified as Trace
import Singular.Registry.Evidence qualified as Cage
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.TxBuilder.Edges (bookEdgeMeasured)
import Singular.Registry.TxBuilder.Internal
    ( extractCageDatum
    , requestAddrFromCfg
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRequest
    , OnChainTokenState
    , edgeName
    )
import Singular.Registry.Wallet (Wallet (..))

-- | The state a request's deadline is read under, and the request it names.
requestAndState
    :: Cage.Session Cage.NoWitness IO
    -> Saved
    -> TxIn
    -> IO (Maybe (OnChainRequest, OnChainTokenState))
requestAndState v s request = do
    reqs <-
        Cage.outputsAt
            v
            (requestAddrFromCfg (savedCfg s) (savedToken s) Testnet)
    live <- attachLive v s
    pure $ case ( lookup request reqs >>= extractCageDatum
                , extractCageDatum (snd (liveState live))
                ) of
        (Just (RequestDatum r), Just (StateDatum st)) -> Just (r, st)
        _ -> Nothing

{- | Book one edge through the application, then read the request back
live at the request address before journalling it observed, and place its
processing deadline in that same view.

The booking is built from one view: what it books is decided there, from
the registry's state and outputs as that view holds them; its units are
measured, its fee and collateral balanced and its outlay judged against the
approved allowance under that view's parameters, before anything is signed.
An insertion's envelope travels in its request, so nothing of it is kept in
the registry directory.
-}
book
    :: Attached
    -> EntryArgs
    -> ByteString
    -> (Cage.Session Cage.NoWitness IO -> Live -> IO (Booked, r))
    -- ^ What is booked, decided from the booking's own view
    -> IO (ConwayTx, r, Deadline)
book at a key plan = do
    let s = savedOf at
        cfg = savedCfg s
        wc = atWrite at
    (booking, (decided, _)) <-
        submitBuiltIn
            wc
            "book"
            (\(_, edge) -> [InKey key, InEdge (Booking edge)])
            (const (Expectation (Just key) "request" Nothing Nothing Nothing))
            ( \v -> do
                live <- attachLive v s
                (b, decided) <- plan v live
                let edge = T.pack (edgeName (bookedEdge b))
                report
                    (wcTracer wc)
                    [InKey key, InEdge (Booking edge)]
                    (EdgeStarted (Booking edge))
                tx <-
                    bookEdgeMeasured
                        cfg
                        v
                        (walletAddr (wcWallet wc))
                        (savedToken s)
                        key
                        (bookedEdge b)
                        (bookedDestination b)
                        (bookedDeposit b)
                        (bookedApproval b)
                        (liveRefs live)
                        (entryFund a)
                pp <- Cage.parameters v
                refuseOver
                    (entryMaxOutlay a)
                    (bookingOutlay pp (liveRefs live) tx)
                pure (tx, (decided, edge))
            )
    let request = TxIn (txIdTx booking) (TxIx 0)
    deadline <-
        reading at $ \v -> do
            reqs <-
                Cage.outputsAt v (requestAddrFromCfg cfg (savedToken s) Testnet)
            unless (any ((== request) . fst) reqs) $
                failWith
                    Partial
                    "the booking confirmed but its request output is not live"
            requestAndState v s request >>= \case
                Just (r, st) -> deadlineOf v r st
                Nothing ->
                    failWith
                        Partial
                        "the booking's request output or the registry's state carries no readable datum"
    journalObserved
        wc
        "book"
        booking
        ("request " <> txInText request <> " live")
    report
        (wcTracer wc)
        [InRequest (txInText request)]
        (Trace.Booked (txInText request) (Just (deadlineMs deadline)))
    pure (booking, decided, deadline)

-- | What a booking-only command's receipt names of its pending request.
pendingFields :: ByteString -> ConwayTx -> Deadline -> [(Text, Value)]
pendingFields requester booking deadline =
    [ ("booking", toJSON (txIdHex booking))
    , ("requester", toJSON (hexT requester))
    , ("request", toJSON (txInText (TxIn (txIdTx booking) (TxIx 0))))
    , ("foldDeadline", deadlineJson deadline)
    ]

-- | The fold a combined command runs after its own booking.
foldAfter :: Attached -> EntryArgs -> ConwayTx -> IO Folded
foldAfter at a booking =
    foldPending
        at
        FoldSpec
            { fsOrigin = Combined booking
            , fsRequest = Nothing
            , fsFund = Nothing
            , fsAllowance = entryMaxOutlay a
            }

-- ---------------------------------------------------------
-- insert
-- ---------------------------------------------------------

runInsert :: Env -> EntryArgs -> IO Value
runInsert env a = case entryMode a of
    Preview node addr -> runPreview env KInsert a node addr
    Submit ws -> do
        let Key key = entryKey a
        payload <- readInsertPayload a
        attached env (entryRegistry a) (entryBlueprint a) ws "insert" $ \at -> do
            let s = savedOf at
                envelope = insertionOf s a (callerKey at) payload
            -- The approval is decided in the booking's own view, from the
            -- state it holds.
            (booking, (), deadline) <-
                book at a key $ \_ live -> do
                    b <- planInsert live envelope
                    pure (b, ())
            if entryFold a
                then do
                    folded <- foldAfter at a booking
                    pure $ case fdDelivery folded of
                        Delivered liveIn seen ->
                            receipt
                                "insert"
                                Success
                                ( keyFields key
                                    <> [ ("booking", toJSON (txIdHex booking))
                                       , ("fold", toJSON (txIdHex (fdTx folded)))
                                       , ("liveOutput", toJSON (txInText liveIn))
                                       , ("envelope", envelopeToJson seen)
                                       , ("root", toJSON (hexT (fdRoot folded)))
                                       ]
                                )
                        Released{} -> receipt "insert" Success []
                else
                    pure $
                        receipt
                            "insert"
                            Success
                            ( keyFields key
                                <> pendingFields (callerKey at) booking deadline
                                <> [ ("envelope", envelopeToJson envelope)
                                   , ("envelopeHash", toJSON (hexT (envelopeHash envelope)))
                                   ]
                            )

-- update
-- ---------------------------------------------------------

runUpdate :: Env -> EntryArgs -> IO Value
runUpdate env a = case entryMode a of
    Preview node addr -> runPreview env KUpdate a node addr
    Submit ws -> do
        let Key key = entryKey a
        path <-
            maybe
                (failWith ClientRefusal "update needs --payload")
                pure
                (entryDocument a)
        payload <-
            readJson path >>= either (failWith ClientRefusal) pure . dataFromJson
        attached env (entryRegistry a) (entryBlueprint a) ws "update" $ \at -> do
            let s = savedOf at
                wc = atWrite at
                addr = walletAddr (wcWallet wc)
            rootBefore <- selectedTrieRoot (atTrie at)
            -- The live output, its controller, the funding output, the
            -- parameters, the script evaluation and the outlay judged against
            -- the allowance all come from the update's one view.
            let placed = [InKey key, InEdge Updating]
            report (wcTracer wc) placed (EdgeStarted Updating)
            (signed, envelope) <-
                submitBuiltIn
                    wc
                    "update"
                    (const placed)
                    ( \envelope ->
                        Expectation
                            (Just key)
                            ("payload:" <> hexT (envelopeHash envelope{envPayload = payload}))
                            Nothing
                            Nothing
                            Nothing
                    )
                    ( \v -> do
                        live <- attachLive v s
                        outs <- liveOutputs v s
                        (holding, envelope) <- planUpdate live (callerKey at) key outs
                        unsigned <-
                            buildUpdate v live addr (entryFund a) holding payload
                        refuseOver (entryMaxOutlay a) (updateOutlay unsigned)
                        pure (unsigned, envelope)
                    )
            after <- reading at (`liveOutputs` s)
            ((liveIn, _), seen) <-
                either (failWith Partial) pure (liveOutputFor s key after)
            unless (seen == envelope{envPayload = payload}) $
                failWith
                    Partial
                    "the updated output carries another envelope than the one sent"
            state <- reading at (`attachLive` s)
            rootAfter <- either (failWith Partial) pure (observedRoot state)
            when (rootAfter /= rootBefore) $
                failWith StaleState "the registry root moved during an update"
            journalObserved
                wc
                "update"
                signed
                ( "key live at "
                    <> txInText liveIn
                    <> " with the new payload; root unchanged"
                )
            report (wcTracer wc) placed (Updated key (txInText liveIn))
            report (wcTracer wc) [] (RootSeen (hexT rootBefore) (hexT rootAfter))
            pure $
                receipt
                    "update"
                    Success
                    ( keyFields key
                        <> [ ("update", toJSON (txIdHex signed))
                           , ("liveOutput", toJSON (txInText liveIn))
                           , ("payload", dataToJson (envPayload seen))
                           , ("root", toJSON (hexT rootAfter))
                           ]
                    )

-- ---------------------------------------------------------
-- terminate
-- ---------------------------------------------------------

runTerminate :: Env -> EntryArgs -> IO Value
runTerminate env a = case entryMode a of
    Preview node addr -> runPreview env KTerminate a node addr
    Submit ws -> do
        let Key key = entryKey a
        attached env (entryRegistry a) (entryBlueprint a) ws "terminate" $ \at -> do
            let s = savedOf at
            -- The live output the booking releases is resolved in the
            -- booking's own view, with the state the approval binds.
            (booking, ((liveIn, _), envelope), deadline) <-
                book at a key $ \v live -> do
                    outs <- liveOutputs v s
                    (b, holding, envelope) <- planTerminate live (callerKey at) key outs
                    pure (b, (holding, envelope))
            let c = envControl envelope
            if entryFold a
                then do
                    folded <- foldAfter at a booking
                    pure $ case fdDelivery folded of
                        Released released deposit ->
                            receipt
                                "terminate"
                                Success
                                ( keyFields key
                                    <> [ ("booking", toJSON (txIdHex booking))
                                       , ("fold", toJSON (txIdHex (fdTx folded)))
                                       , ("released", toJSON (txInText released))
                                       , ("deposit", toJSON deposit)
                                       , ("root", toJSON (hexT (fdRoot folded)))
                                       ]
                                )
                        Delivered{} -> receipt "terminate" Success []
                else
                    pure $
                        receipt
                            "terminate"
                            Success
                            ( keyFields key
                                <> pendingFields (callerKey at) booking deadline
                                <> [ ("released", toJSON (txInText liveIn))
                                   , ("deposit", toJSON (ctlDeposit c))
                                   ]
                            )
