{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.Entry
Description : @open-datum insert|update|terminate@ over an attached open-datum registry
License     : Apache-2.0

Each write attaches first ("Singular.CLI.Attached"): the registry is
resolved from its state token and the release, with the reference outputs
its transactions run found by hash; the journal is reconciled
("Singular.CLI.Reconcile") and must then hold no unresolved submission;
the state output is read, and the public replay must commit to exactly
the root the ledger holds. The command then calls the production builders —
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
module Singular.Application.OpenDatum.Entry
    ( runInsert
    , runUpdate
    , runTerminate
    ) where

import Control.Exception (throwIO)
import Control.Monad (unless, when)
import Data.Aeson (Value (Null), object, toJSON, (.=))
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as T

import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Ledger (Coin (..), ConwayEra)

import Singular.Application.OpenDatum.Command
    ( OpenDatumCommand (..)
    , neededRoles
    )
import Singular.Application.OpenDatum.Envelope
    ( Control (..)
    , Envelope (..)
    , dataFromJson
    , dataToJson
    , envelopeFromData
    , envelopeHash
    , envelopeToJson
    )
import Singular.Application.OpenDatum.Plan
import Singular.Application.OpenDatum.Preview (Kind (..), runPreview)
import Singular.Application.OpenDatum.Value (openDatumApplication)
import Singular.CLI.Attached
import Singular.CLI.Booking
    ( BookingVerb (..)
    , precheckBooking
    , refuseBooking
    )
import Singular.CLI.Command
    ( EntryArgs (..)
    , EntryMode (..)
    , Key (..)
    , ProviderSettings (..)
    , RegistryAccess (..)
    , WriteSettings (..)
    )
import Singular.CLI.Fold
    ( Deadline (..)
    , Delivery (..)
    , FoldOrigin (..)
    , FoldSpec (..)
    , Folded (..)
    , SettledEntry (..)
    , deadlineJson
    , foldPending
    , registrationDeadline
    , settledEntryFor
    )
import Singular.CLI.FoldRules
    ( FoldRequestsRefusal (..)
    , SettledForReceipt (..)
    , foldReceiptLists
    , renderFoldRequestsRefusal
    )
import Singular.CLI.Live
import Singular.CLI.ManagedState (resolveSignerDir)
import Singular.CLI.Outlay
    ( outlayTotal
    , updateOutlay
    )
import Singular.CLI.Prepare
    ( PrepareRefusal (..)
    , preparationFields
    , prepareFunding
    )
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Registry (hexT, keyFields)
import Singular.CLI.Session
import Singular.CLI.Trace
    ( EdgeAction (..)
    , Scope (..)
    , What (EdgeStarted, RootSeen, Updated)
    )
import Singular.CLI.Trace qualified as Trace
import Singular.Registry.Application (DecodedHolding (..))
import Singular.Registry.Evidence qualified as Cage
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.Lifecycle (protocolFeeReserve)
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.TxBuilder.Edges (selectFunding)
import Singular.Registry.TxBuilder.Internal
    ( BookedRequest (..)
    , bookedRequestOf
    , extractCageDatum
    , pendingByTag
    )
import Singular.Registry.TxBuilder.Prepare
    ( Preparation (..)
    , spendableOuts
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainTokenState
    , edgeName
    )
import Singular.Registry.Wallet (bech32Address)

-- | The state a registration's deadline is read under, and the booked request it names.
requestAndState
    :: Cage.Session Cage.NoWitness IO
    -> Saved
    -> TxIn
    -> IO (Maybe (BookedRequest, OnChainTokenState))
requestAndState v s request = do
    pending <- pendingByTag (savedCfg s) v (savedToken s)
    live <- attachLive v s
    pure $ case ( lookup request pending >>= bookedRequestOf (savedCfg s) (savedToken s)
                , extractCageDatum (snd (liveState live))
                ) of
        (Just booked, Just (StateDatum st)) -> Just (booked, st)
        _ -> Nothing

{- | Book one edge through the application, then read the request back
live at the request address before journalling it observed, and place its
processing deadline in that same view.

The booking is built from one view: what it books is decided there, from
the registry's state and outputs as that view holds them; its units are
measured, its fee and collateral balanced and its outlay judged against the
approved allowance under that view's parameters, before anything is signed.
An insertion's envelope travels in its request, so nothing of it is kept in
your state directory.
-}
book
    :: Attached
    -> EntryArgs
    -> ByteString
    -> BookingVerb
    {- ^ The verb booking this key: refused first when the key's current
    entry rules it out, before anything is placed, built or signed
    -}
    -> (Cage.Session Cage.NoWitness IO -> Live -> IO (Booked, r))
    -- ^ What is booked, decided from the booking's own view
    -> IO (ConfirmedSubmission, r, Maybe Deadline, Maybe Preparation)
book at a key verb plan = do
    let s = savedOf at
        cfg = savedCfg s
        wc = atWrite at
    (booking, (decided, mPrep)) <-
        submitBuiltIn
            wc
            "book"
            ["state", "key outputs"]
            (const (Expectation (Just key) "request" Nothing Nothing Nothing))
            ( \building v -> do
                live <- attachLive v s
                refuseBooking (atTrie at) key verb
                (b, decided) <- plan v live
                let edge = T.pack (edgeName (bookedEdge b))
                    payerAddr = wcCaller wc
                walletUtxos <- Cage.outputsAt v payerAddr
                -- Empty wallet (nothing spendable at all) keeps the friendly refusal
                -- with the retained faucet sentence (no self-payment); a token-only
                -- wallet with spendable outputs goes to the seam to prepare.
                -- Before the fold-reserve floor, so an empty wallet names the faucet.
                case (selectFunding (entryFund a) walletUtxos, spendableOuts walletUtxos) of
                    (Left msg, []) ->
                        failWithFields
                            ClientRefusal
                            ( msg
                                <> " for wallet "
                                <> bech32Address payerAddr
                                <> " (client policy). "
                                <> retainedFaucetStep
                            )
                            (emptyFields payerAddr walletUtxos)
                    _ -> pure ()
                pp <- Cage.parameters v
                let Coin reserve =
                        protocolFeeReserve pp (liveRefs live)
                refuseUnderfunded
                    payerAddr
                    walletUtxos
                    reserve
                    "fold reserve"
                place
                    building
                    [InKey key, InEdge (Booking edge)]
                    (EdgeStarted (Booking edge))
                let refs = liveRefs live
                    measure = bookedOutlay b pp refs
                    build funded = bookedBuild b funded payerAddr
                prepared <-
                    prepareFunding
                        wc
                        "book"
                        payerAddr
                        (entryFund a)
                        (entryMaxOutlay a)
                        measure
                        build
                        v
                case prepared of
                    Left (ExplicitFundingRefusal why) ->
                        failWithFields
                            ClientRefusal
                            ( why
                                <> " for wallet "
                                <> bech32Address payerAddr
                                <> " (client policy)"
                            )
                            (emptyFields payerAddr walletUtxos)
                    Left (OriginalFailure e) -> throwIO e
                    Left (PreparationShortfall text fields) ->
                        failWithFields ClientRefusal text fields
                    Left (AllowanceExceeded text fields) ->
                        failWithFields ClientRefusal text fields
                    Right (_, mPrep, realTx) -> do
                        let outlay = bookedOutlay b pp refs realTx
                        refuseOver (entryMaxOutlay a) outlay
                        refuseUnderfunded
                            payerAddr
                            walletUtxos
                            (outlayTotal outlay)
                            "measured outlay"
                        pure (realTx, (decided, mPrep))
            )
    let request = TxIn (txIdTx (confirmedTx booking)) (TxIx 0)
    deadline <-
        readingBack at "book" booking ["requests", "state"] $ \v -> do
            reqs <- pendingByTag cfg v (savedToken s)
            unless (any ((== request) . fst) reqs) $
                failWith
                    Partial
                    "the booking confirmed but its request output is not live"
            requestAndState v s request >>= \case
                Just (BookedRegistration r, st) -> Just <$> registrationDeadline v r st
                Just (BookedTermination _, _) -> pure Nothing
                Nothing ->
                    failWith
                        Partial
                        "the booking's request output or the registry's state carries no readable datum"
    journalObserved
        wc
        "book"
        booking
        ("request " <> txInText request <> " live")
    reportSeen
        wc
        [InRequest (txInText request)]
        (Trace.Booked (txInText request) (deadlineMs <$> deadline))
    pure (booking, decided, deadline, mPrep)

-- | What a booking-only command's receipt names of its pending request.
pendingFields
    :: ByteString -> ConfirmedSubmission -> Maybe Deadline -> [(Text, Value)]
pendingFields requester booking deadline =
    [ ("booking", toJSON (txIdHex (confirmedTx booking)))
    , ("requester", toJSON (hexT requester))
    ,
        ( "request"
        , toJSON (txInText (TxIn (txIdTx (confirmedTx booking)) (TxIx 0)))
        )
    , ("transfer", toJSON (transferOf (confirmedTx booking)))
    , ("foldDeadline", maybe Null deadlineJson deadline)
    ]

{- | The fold preparation of a combined command, under a distinct key so a
booking preparation (`preparationFields`) and a fold preparation never share
one member: present only when the fold made one, same shape otherwise.
-}
foldPrepFields :: Maybe Preparation -> [(Text, Value)]
foldPrepFields =
    maybe
        []
        ( \p ->
            [
                ( "foldPreparation"
                , object
                    [ "transaction" .= txIdHex (prepTx p)
                    , "output" .= txInText (prepFunding p)
                    , "lovelace" .= prepFundingCoin p
                    , "fee" .= prepFee p
                    ]
                )
            ]
        )

-- | A holding view as the envelope the entry commands still print (B shim).
toEnvelopeHolding
    :: ((TxIn, TxOut ConwayEra), DecodedHolding)
    -> Either String ((TxIn, TxOut ConwayEra), Envelope)
toEnvelopeHolding (u, dh) = case envelopeFromData (dhDatumData dh) of
    Left why -> Left why
    Right e -> Right (u, e)

-- | The fold a combined command runs after its own booking.
foldAfter :: Attached -> EntryArgs -> ConwayTx -> IO Folded
foldAfter at a booking =
    foldPending
        openDatumApplication
        at
        FoldSpec
            { fsOrigin = Combined booking
            , fsRequest = Nothing
            , fsFund = Nothing
            , fsAllowance = entryMaxOutlay a
            }

{- | The managed journal for an entry write: resolved from the state root
override, the provider network, the registry token and the caller's
wallet, before any lock or journal use.
-}
managedEntryDir :: EntryArgs -> WriteSettings -> IO FilePath
managedEntryDir a ws =
    resolveSignerDir
        (entryStateDir a)
        (providerMagic (writeProvider ws))
        (accessToken (entryAccess a))
        (writeSigner ws)

-- ---------------------------------------------------------
-- insert
-- ---------------------------------------------------------

runInsert :: Env -> EntryArgs -> IO Value
runInsert env a = case entryMode a of
    Preview node addr -> runPreview openDatumApplication env KInsert a node addr
    Submit ws -> do
        let Key key = entryKey a
        payload <- readInsertPayload a
        precheckBooking
            openDatumApplication
            env
            (writeProvider ws)
            (entryBlueprint a)
            (entryAccess a)
            (neededRoles (OpenInsert a))
            key
            BookInsert
        dir <- managedEntryDir a ws
        attached
            openDatumApplication
            env
            dir
            (entryBlueprint a)
            (entryAccess a)
            (neededRoles (OpenInsert a))
            ws
            "insert"
            $ \at -> do
                let s = savedOf at
                    envelope = insertionOf s a (callerKey at) payload
                -- The approval is decided in the booking's own view, from the
                -- state it holds.
                (booking, (), deadline, mPrepBook) <-
                    book at a key BookInsert $ \v live -> do
                        b <- planInsert v live envelope
                        pure (b, ())
                if entryFold a
                    then do
                        folded <- foldAfter at a (confirmedTx booking)
                        let bookingRef = TxIn (txIdTx (confirmedTx booking)) (TxIx 0)
                        entry <- case settledEntryFor folded bookingRef of
                            Just e -> pure e
                            Nothing ->
                                failWithFields
                                    Partial
                                    ( "the booking is confirmed and its request "
                                        <> T.unpack (txInText bookingRef)
                                        <> " stays pending; "
                                        <> renderFoldRequestsRefusal (FoldNamedNotPending bookingRef)
                                    )
                                    [("pendingRequest", toJSON (txInText bookingRef))]
                        pure $ case seDelivery entry of
                            Delivered liveIn holding -> case envelopeFromData (dhDatumData holding) of
                                Right _ ->
                                    receipt
                                        "insert"
                                        Success
                                        ( keyFields key
                                            <> [ ("booking", toJSON (txIdHex (confirmedTx booking)))
                                               , ("transfer", toJSON (transferOf (confirmedTx booking)))
                                               , ("fold", toJSON (txIdHex (fdTx folded)))
                                               , ("root", toJSON (hexT (fdRoot folded)))
                                               , ("donation", toJSON (fdDonation folded))
                                               ]
                                            <> preparationFields mPrepBook
                                            <> foldPrepFields (fdPreparation folded)
                                            <> foldReceiptLists
                                                [ SettledForReceipt
                                                    (seRequest entry)
                                                    (hexT (seKey entry))
                                                    (T.pack (edgeName (seEdge entry)))
                                                    (seOwner entry)
                                                    ( object
                                                        [ "liveOutput" .= txInText liveIn
                                                        , "envelope" .= dhDatumJson holding
                                                        ]
                                                    )
                                                    (maybe Null deadlineJson (seDeadline entry))
                                                ]
                                                (fdExcluded folded)
                                                (fdCapacityBound folded)
                                                (fdCapacityProvenance folded)
                                        )
                                Left why -> error ("Entry: folded holding is not an envelope: " <> why)
                            DeliveredDatum{} ->
                                receipt
                                    "insert"
                                    Success
                                    (preparationFields mPrepBook <> foldPrepFields (fdPreparation folded))
                            Terminated{} ->
                                receipt
                                    "insert"
                                    Success
                                    (preparationFields mPrepBook <> foldPrepFields (fdPreparation folded))
                    else
                        pure $
                            receipt
                                "insert"
                                Success
                                ( keyFields key
                                    <> pendingFields (callerKey at) booking deadline
                                    <> preparationFields mPrepBook
                                    <> [ ("envelope", envelopeToJson envelope)
                                       , ("envelopeHash", toJSON (hexT (envelopeHash envelope)))
                                       ]
                                )

-- update
-- ---------------------------------------------------------

runUpdate :: Env -> EntryArgs -> IO Value
runUpdate env a = case entryMode a of
    Preview node addr -> runPreview openDatumApplication env KUpdate a node addr
    Submit ws -> do
        let Key key = entryKey a
        path <-
            maybe
                (failWith ClientRefusal "update needs --payload")
                pure
                (entryDocument a)
        payload <-
            readJson path >>= either (failWith ClientRefusal) pure . dataFromJson
        precheckBooking
            openDatumApplication
            env
            (writeProvider ws)
            (entryBlueprint a)
            (entryAccess a)
            (neededRoles (OpenUpdate a))
            key
            BookUpdate
        dir <- managedEntryDir a ws
        attached
            openDatumApplication
            env
            dir
            (entryBlueprint a)
            (entryAccess a)
            (neededRoles (OpenUpdate a))
            ws
            "update"
            $ \at -> do
                let s = savedOf at
                    wc = atWrite at
                    addr = wcCaller wc
                rootBefore <- selectedTrieRoot (atTrie at)
                -- The live output, its controller, the funding output, the
                -- parameters, the script evaluation and the outlay judged against
                -- the allowance all come from the update's one view.
                let placed = [InKey key, InEdge Updating]
                (signed, envelope) <-
                    submitBuiltIn
                        wc
                        "update"
                        ["state", "key outputs"]
                        ( \envelope ->
                            Expectation
                                (Just key)
                                ("payload:" <> hexT (envelopeHash envelope{envPayload = payload}))
                                Nothing
                                Nothing
                                Nothing
                        )
                        ( \building v -> do
                            live <- attachLive v s
                            outs <- liveOutputs openDatumApplication v s
                            refuseBooking (atTrie at) key BookUpdate
                            (holding, dh) <- planUpdate live (callerKey at) key outs
                            envelope <-
                                either
                                    (failWith ClientRefusal)
                                    pure
                                    (envelopeFromData (dhDatumData dh))
                            walletUtxos <- Cage.outputsAt v addr
                            _ <- resolveFunding addr walletUtxos (entryFund a)
                            place building placed (EdgeStarted Updating)
                            unsigned <-
                                buildUpdate v live addr (entryFund a) holding payload
                            refuseOver (entryMaxOutlay a) (updateOutlay unsigned)
                            pure (unsigned, envelope)
                        )
                after <-
                    readingBack
                        at
                        "update"
                        signed
                        ["key outputs"]
                        (\v -> liveOutputs openDatumApplication v s)
                decodedAfter <-
                    either
                        (failWith Partial)
                        pure
                        (liveOutputFor openDatumApplication s key after)
                ((liveIn, _), seen) <-
                    either (failWith Partial) pure (toEnvelopeHolding decodedAfter)
                unless (seen == envelope{envPayload = payload}) $
                    failWith
                        Partial
                        "the updated output carries another envelope than the one sent"
                state <- readingBack at "update" signed ["state"] (`attachLive` s)
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
                reportSeen wc placed (Updated key (txInText liveIn))
                reportSeen wc [] (RootSeen (hexT rootBefore) (hexT rootAfter))
                pure $
                    receipt
                        "update"
                        Success
                        ( keyFields key
                            <> [ ("update", toJSON (txIdHex (confirmedTx signed)))
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
    Preview node addr -> runPreview openDatumApplication env KTerminate a node addr
    Submit ws -> do
        let Key key = entryKey a
        precheckBooking
            openDatumApplication
            env
            (writeProvider ws)
            (entryBlueprint a)
            (entryAccess a)
            (neededRoles (OpenTerminate a))
            key
            BookTerminate
        dir <- managedEntryDir a ws
        attached
            openDatumApplication
            env
            dir
            (entryBlueprint a)
            (entryAccess a)
            (neededRoles (OpenTerminate a))
            ws
            "terminate"
            $ \at -> do
                let s = savedOf at
                -- The live output the booking releases is resolved in the
                -- booking's own view, with the state the approval binds.
                (booking, ((liveIn, _), envelope), deadline, mPrepBook) <-
                    book at a key BookTerminate $ \v live -> do
                        outs <- liveOutputs openDatumApplication v s
                        (b, holding, dh) <- planTerminate live (callerKey at) key outs
                        envelope <-
                            either
                                (failWith ClientRefusal)
                                pure
                                (envelopeFromData (dhDatumData dh))
                        pure (b, (holding, envelope))
                let c = envControl envelope
                if entryFold a
                    then do
                        folded <- foldAfter at a (confirmedTx booking)
                        let bookingRef = TxIn (txIdTx (confirmedTx booking)) (TxIx 0)
                        entry <- case settledEntryFor folded bookingRef of
                            Just e -> pure e
                            Nothing ->
                                failWithFields
                                    Partial
                                    ( "the booking is confirmed and its request "
                                        <> T.unpack (txInText bookingRef)
                                        <> " stays pending; "
                                        <> renderFoldRequestsRefusal (FoldNamedNotPending bookingRef)
                                    )
                                    [("pendingRequest", toJSON (txInText bookingRef))]
                        pure $ case seDelivery entry of
                            Terminated terminatedBy ->
                                receipt
                                    "terminate"
                                    Success
                                    ( keyFields key
                                        <> [ ("booking", toJSON (txIdHex (confirmedTx booking)))
                                           , ("transfer", toJSON (transferOf (confirmedTx booking)))
                                           , ("fold", toJSON (txIdHex (fdTx folded)))
                                           , ("root", toJSON (hexT (fdRoot folded)))
                                           , ("donation", toJSON (fdDonation folded))
                                           ]
                                        <> preparationFields mPrepBook
                                        <> foldPrepFields (fdPreparation folded)
                                        <> foldReceiptLists
                                            [ SettledForReceipt
                                                (seRequest entry)
                                                (hexT (seKey entry))
                                                (T.pack (edgeName (seEdge entry)))
                                                (seOwner entry)
                                                ( object
                                                    [ "terminated" .= txInText terminatedBy
                                                    , "custody" .= txInText liveIn
                                                    , "deposit" .= ctlDeposit c
                                                    ]
                                                )
                                                (maybe Null deadlineJson (seDeadline entry))
                                            ]
                                            (fdExcluded folded)
                                            (fdCapacityBound folded)
                                            (fdCapacityProvenance folded)
                                    )
                            Delivered{} ->
                                receipt
                                    "terminate"
                                    Success
                                    (preparationFields mPrepBook <> foldPrepFields (fdPreparation folded))
                            DeliveredDatum{} ->
                                receipt
                                    "terminate"
                                    Success
                                    (preparationFields mPrepBook <> foldPrepFields (fdPreparation folded))
                    else
                        pure $
                            receipt
                                "terminate"
                                Success
                                ( keyFields key
                                    <> pendingFields (callerKey at) booking deadline
                                    <> preparationFields mPrepBook
                                    <> [ ("custody", toJSON (txInText liveIn))
                                       , ("deposit", toJSON (ctlDeposit c))
                                       ]
                                )
