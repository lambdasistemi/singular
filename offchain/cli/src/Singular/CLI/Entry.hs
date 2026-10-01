{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.Entry
Description : @singular registry insert|update|terminate@ over an attached open-datum registry
License     : Apache-2.0

Each write attaches first ("Singular.CLI.Live"): the saved identity is
re-derived and checked, the network must be the saved one, the journal
must hold no unresolved submission, the reference outputs and the state
output are resolved, and the local mirror must commit to exactly the
root the ledger holds. The command then calls the production builders —
it decides no validator or fold rule itself — journals every submission,
and reads back what each made before journalling it @observed@.

Authority over a key is its envelope's controller, never the wallet that
created the registry: any wallet may insert an envelope naming itself as
controller, and only that controller may update or terminate it.

* __insert__: the caller's envelope must name this registry, its active
  policy, the key and the caller's own payment key as controller. The
  booking certifies it through the application; the fold delivers the
  key's active token to an output at the application carrying the
  envelope inline. The mirror then binds the key @Active@.
* __update__: the caller must be the live envelope's controller. The live
  output is spent with @Update@ and recreated with the new payload. The
  registry does not move.
* __terminate__: the caller must be the live envelope's controller. The
  booking reads the live output by reference; the fold spends it with
  @Release@, burns its token, and pays the deposit back with the
  booking's. The mirror then binds the key @Terminal@.
-}
module Singular.CLI.Entry
    ( runInsert
    , runUpdate
    , runTerminate
    ) where

import Control.Exception
    ( SomeAsyncException
    , SomeException
    , fromException
    , throwIO
    , try
    )
import Control.Monad (unless, void, when)
import Data.Aeson (Value, toJSON)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS
import Data.List (isPrefixOf, sortOn)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((^.))

import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body (inputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (TxOut, coinTxOutL)
import Cardano.Ledger.BaseTypes (Network (Testnet), TxIx (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import Data.Set qualified as Set

import Singular.Application.OpenDatum.Book
    ( insertApproval
    , insertDestination
    , terminateApproval
    , terminateDestination
    )
import Singular.Application.OpenDatum.Envelope
    ( Control (..)
    , Envelope (..)
    , dataFromJson
    , dataToJson
    , envelopeFromJson
    , envelopeHash
    , envelopeToJson
    , envelopeVersion
    , registryBytes
    )
import Singular.Application.OpenDatum.Release (withApplication)
import Singular.Application.OpenDatum.Update
    ( UpdateArgs (..)
    , updatePayloadTx
    )
import Singular.CLI.Command
    ( EntryArgs (..)
    , Key (..)
    , NodeSettings (..)
    , WriteSettings (..)
    )
import Singular.CLI.Live
import Singular.CLI.Node (Capabilities (..))
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Registry
    ( LocalState (..)
    , checkNetwork
    , hexT
    , renderIdentityError
    , writeLocalState
    )
import Singular.CLI.Session
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger
    ( AssetName (..)
    , ConwayEra
    , Root (..)
    , TokenId (..)
    )
import Singular.Registry.Node (Wallet (..))
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Trie (Trie (..), TrieManager (..))
import Singular.Registry.TxBuilder.Edges
    ( BookingApproval (..)
    , adaOnlyOut
    , bookEdgeTx
    , edgeDeposit
    , registryContextFor
    )
import Singular.Registry.TxBuilder.Internal
    ( addrKeyHashBytes
    , requestAddrFromCfg
    , scriptHashBytes
    , walkEdge
    )
import Singular.Registry.TxBuilder.Update (updateTokenWithDuties)
import Singular.Registry.Types
    ( Edge
    , edgeInsertActive
    , edgeUpdateTerminal
    )

-- | Everything a write holds once attached.
data Attached = Attached
    { atWrite :: WriteContext
    , atLive :: Live
    , atMirror :: Mirror
    }

{- | Attach a write to its registry: saved identity and pins, network,
unresolved journal, live references and state, and the mirror's root
against the ledger's, all read from one view. The caller's wallet is
NOT compared with the wallet that created the registry; authority is the
envelope's. Every transaction the write then builds reads the chain
again, from a view of its own.
-}
attached
    :: FilePath
    -> FilePath
    -> WriteSettings
    -> Text
    -> (Attached -> IO a)
    -> IO a
attached dir blueprint ws command body = do
    saved <- loadSaved dir blueprint
    withWrite dir command ws $ \wc -> do
        refuseUnresolved dir
        let NodeSettings _ magic = writeNode ws
        either
            (failWith ClientRefusal . renderIdentityError)
            pure
            (checkNetwork (savedConfig saved) magic)
        mirror <- openMirror saved
        live <-
            Cage.withView (capReads (wcCapabilities wc)) $ \v -> attachLive v saved
        observed <- either (failWith StaleState) pure (observedRoot live)
        local <- mirrorRoot saved mirror
        when (local /= observed) $
            failWith
                StaleState
                ( "the saved mirror commits to 0x"
                    <> T.unpack (hexT local)
                    <> " but the ledger holds 0x"
                    <> T.unpack (hexT observed)
                    <> ": stale, concurrent or altered local state is refused, \
                       \never repaired"
                )
        body Attached{atWrite = wc, atLive = live, atMirror = mirror}

callerKey :: Attached -> ByteString
callerKey = addrKeyHashBytes . walletAddr . wcWallet . atWrite

provider :: Attached -> Cage.Provider IO
provider = capReads . wcCapabilities . atWrite

-- | One read operation: acquire a view and read through it.
reading :: Attached -> (Cage.View IO -> IO a) -> IO a
reading at = Cage.withView (provider at)

savedOf :: Attached -> Saved
savedOf = liveSaved . atLive

tokenName :: Saved -> ByteString
tokenName s = let TokenId (AssetName n) = savedToken s in SBS.fromShort n

-- | The caller must be the envelope's controller.
requireController :: Attached -> Control -> IO ()
requireController at c =
    unless (ctlController c == callerKey at) $
        failWith
            ClientRefusal
            ( "the envelope's controller is 0x"
                <> T.unpack (hexT (ctlController c))
                <> " but this command signs as 0x"
                <> T.unpack (hexT (callerKey at))
            )

-- | The application's published reference output, required by every write.
appReference :: Attached -> IO TxIn
appReference at =
    maybe
        ( failWith
            Partial
            "the deployment records no published application reference"
        )
        (pure . fst)
        (applicationReference (atLive at))

{- | Book one edge through the application, then read the request back
live at the request address before journalling it observed.

The booking is built from one view: the approval is decided there, from
the registry's state and outputs as that view holds them, and the
payer's wallet and the parameters are that view's.
-}
book
    :: Attached
    -> ByteString
    -> Edge
    -> (ByteString, ByteString)
    -> Integer
    -> (Cage.View IO -> Live -> IO (BookingApproval, r))
    -- ^ The approval, decided from the booking's own view
    -> IO (ConwayTx, r)
book at key edge dest deposit approve = do
    let s = savedOf at
        cfg = savedCfg s
        wc = atWrite at
    (booking, decided) <-
        submitBuilt
            wc
            "book"
            (const (Expectation (Just key) "request" Nothing Nothing Nothing))
            ( \v -> do
                live <- attachLive v s
                (approval, decided) <- approve v live
                tx <-
                    bookEdgeTx
                        cfg
                        v
                        (walletAddr (wcWallet wc))
                        (savedToken s)
                        key
                        edge
                        dest
                        deposit
                        (Just approval)
                pure (tx, decided)
            )
    let request = TxIn (txIdTx booking) (TxIx 0)
    reqs <-
        reading at $ \v ->
            Cage.viewUTxOsAt v (requestAddrFromCfg cfg (savedToken s) Testnet)
    unless (any ((== request) . fst) reqs) $
        failWith
            Partial
            "the booking confirmed but its request output is not live"
    journalObserved
        wc
        "book"
        booking
        ("request " <> txInText request <> " live")
    pure (booking, decided)

{- | Fold exactly this command's request with the application's context,
commit its edge to the mirror, and read the new root back.

The production fold takes every request pending for the registry, so the
fold is bound to the one request this command booked: any other pending
request is refused before anything is built, and a built fold spending
any request input but this one is refused before it is submitted. The
mirror walk and the journalled after-root are that one edge. The pending
set, the context and the fold are read from one view.
-}
foldAndCommit
    :: Attached
    -> TxIn
    -- ^ The request this command booked
    -> ByteString
    -> Edge
    -> Text
    -- ^ The after-state the readback must find
    -> [Envelope]
    -> [(TxIn, TxOut ConwayEra)]
    -> IO (ConwayTx, ByteString)
foldAndCommit at request key edge after envelopes live = do
    let s = savedOf at
        cfg = savedCfg s
        wc = atWrite at
        tm = mirrorTries (atMirror at)
        others = filter (/= request)
    rootBefore <- mirrorRoot s (atMirror at)
    Root rootAfter <-
        withSpeculativeTrie tm (savedToken s) $ \t -> walkEdge t key edge >> getRoot t
    (fold, ()) <-
        submitBuilt
            wc
            "fold"
            ( const
                ( Expectation
                    (Just key)
                    after
                    (Just edge)
                    (Just rootBefore)
                    (Just rootAfter)
                )
            )
            ( \v -> do
                pending <-
                    map fst
                        <$> Cage.viewUTxOsAt v (requestAddrFromCfg cfg (savedToken s) Testnet)
                unless (request `elem` pending) $
                    failWith
                        Partial
                        "the booked request is no longer pending; nothing is folded"
                unless (null (others pending)) $
                    failWithFields
                        ConcurrentWriter
                        ( "another request is pending for this registry ("
                            <> T.unpack (T.intercalate ", " (map txInText (others pending)))
                            <> "); folding only this command's request is not possible, and nothing is folded"
                        )
                        [("pendingRequest", toJSON (txInText request))]
                ctx0 <-
                    registryContextFor cfg (savedCodes s) v (liveRefs (atLive at))
                ctx <-
                    either
                        (failWith ClientRefusal)
                        pure
                        (withApplication (applied s) Nothing envelopes live ctx0)
                -- The booking is confirmed and its deposit is locked in the
                -- request. A fold that cannot be built — the registry will
                -- not take the edge, or a script refuses it at evaluation —
                -- leaves exactly that behind, so the command stops partial
                -- and names the pending request, never as a refusal that
                -- submitted nothing.
                built <-
                    try
                        ( updateTokenWithDuties
                            cfg
                            v
                            tm
                            (savedToken s)
                            (walletAddr (wcWallet wc))
                            ctx
                        )
                unsigned <- case built of
                    Right tx -> pure tx
                    Left (e :: SomeException)
                        | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
                        | otherwise ->
                            failWithFields
                                Partial
                                ( "the booking is confirmed and its request "
                                    <> T.unpack (txInText request)
                                    <> " stays pending; its fold could not be built, so nothing is folded: "
                                    <> briefly (show e)
                                )
                                [("pendingRequest", toJSON (txInText request))]
                let spent = Set.toList (unsigned ^. bodyTxL . inputsTxBodyL)
                    strays = [i | i <- spent, i `elem` pending, i /= request]
                unless (request `elem` spent && null strays) $
                    failWithFields
                        ConcurrentWriter
                        ( "the built fold spends request inputs other than this command's ("
                            <> T.unpack (T.intercalate ", " (map txInText strays))
                            <> "); the fold is not submitted"
                        )
                        [("pendingRequest", toJSON (txInText request))]
                pure (unsigned, ())
            )
    withTrie tm (savedToken s) $ \t -> void (walkEdge t key edge)
    saveOpenMirror s (atMirror at)
    afterFold <- reading at (`attachLive` s)
    onChain <- either (failWith Partial) pure (observedRoot afterFold)
    local <- mirrorRoot s (atMirror at)
    when (onChain /= local) $
        failWith
            StaleState
            ( "after the fold the ledger holds root 0x"
                <> T.unpack (hexT onChain)
                <> " but the mirror commits to 0x"
                <> T.unpack (hexT local)
            )
    pure (fold, local)

commitLocal :: Attached -> ConwayTx -> ByteString -> IO ()
commitLocal at tx root =
    writeLocalState
        (savedDir (savedOf at))
        LocalState
            { localVersion = 1
            , localToken = hexT (tokenName (savedOf at))
            , localRoot = hexT root
            , localLastTx = Just (txIdHex tx)
            , localLastSlot = Nothing
            }

readJson :: FilePath -> IO Aeson.Value
readJson path =
    Aeson.eitherDecodeFileStrict' path
        >>= either (failWith ClientRefusal . ((path <> ": ") <>)) pure

-- ---------------------------------------------------------
-- insert
-- ---------------------------------------------------------

runInsert :: EntryArgs -> IO Value
runInsert a = do
    let Key key = entryKey a
    path <-
        maybe
            (failWith ClientRefusal "insert needs --envelope")
            pure
            (entryDocument a)
    envelope <-
        readJson path
            >>= either (failWith ClientRefusal) pure . envelopeFromJson
    attached (entryRegistry a) (entryBlueprint a) (entryWrite a) "insert" $ \at -> do
        let s = savedOf at
            cfg = savedCfg s
            c = envControl envelope
            identity = scriptHashBytes (cfgScriptHash cfg) <> tokenName s
            refuseIf bad why = when bad (failWith ClientRefusal why)
        refuseIf
            (ctlVersion c /= envelopeVersion)
            "the envelope's version is not 1"
        refuseIf
            (registryBytes (ctlRegistry c) /= identity)
            "the envelope names another registry's state asset"
        refuseIf
            (ctlActivePolicy c /= SBS.fromShort (cfgActivePolicy cfg))
            "the envelope names another active policy"
        refuseIf (ctlKey c /= key) "the envelope names another key than --key"
        refuseIf
            (ctlDeposit c <= 0)
            "the envelope's protected deposit is not positive"
        requireController at c
        appRef <- appReference at
        let dest = insertDestination Testnet (applied s) envelope
            approve _ live =
                pure
                    ( (insertApproval Testnet (applied s) (fst (liveState live)) envelope)
                        { baScriptReference = Just appRef
                        }
                    , ()
                    )
        (booking, ()) <-
            book at key edgeInsertActive dest (ctlDeposit c) approve
        (fold, root) <-
            foldAndCommit
                at
                (TxIn (txIdTx booking) (TxIx 0))
                key
                edgeInsertActive
                ("active:" <> hexT (envelopeHash envelope))
                [envelope]
                []
        outs <- reading at (`liveOutputs` s)
        ((liveIn, _), seen) <-
            either (failWith Partial) pure (liveOutputFor s key outs)
        unless (seen == envelope) $
            failWith Partial "the delivered output carries another envelope"
        journalObserved
            (atWrite at)
            "fold"
            fold
            ( "key live at "
                <> txInText liveIn
                <> " under its envelope; root 0x"
                <> hexT root
            )
        commitLocal at fold root
        pure $
            receipt
                "insert"
                Success
                [ ("key", toJSON (hexT key))
                , ("booking", toJSON (txIdHex booking))
                , ("fold", toJSON (txIdHex fold))
                , ("liveOutput", toJSON (txInText liveIn))
                , ("envelope", envelopeToJson seen)
                , ("root", toJSON (hexT root))
                ]

-- ---------------------------------------------------------
-- update
-- ---------------------------------------------------------

runUpdate :: EntryArgs -> IO Value
runUpdate a = do
    let Key key = entryKey a
    path <-
        maybe
            (failWith ClientRefusal "update needs --payload")
            pure
            (entryDocument a)
    payload <-
        readJson path >>= either (failWith ClientRefusal) pure . dataFromJson
    attached (entryRegistry a) (entryBlueprint a) (entryWrite a) "update" $ \at -> do
        let s = savedOf at
            wc = atWrite at
            addr = walletAddr (wcWallet wc)
        appRef <- appReference at
        let refOut = [u | u@(i, _) <- liveRefs (atLive at), i == appRef]
        rootBefore <- mirrorRoot s (atMirror at)
        -- The live output, its controller, the fee input, the parameters
        -- and the script evaluation all come from the update's one view.
        (signed, envelope) <-
            submitBuilt
                wc
                "update"
                ( \envelope ->
                    Expectation
                        (Just key)
                        ("payload:" <> hexT (envelopeHash envelope{envPayload = payload}))
                        Nothing
                        Nothing
                        Nothing
                )
                ( \v -> do
                    outs <- liveOutputs v s
                    (holding, envelope) <-
                        either (failWith ClientRefusal) pure (liveOutputFor s key outs)
                    requireController at (envControl envelope)
                    wallet <- Cage.viewUTxOsAt v addr
                    fee <- case sortOn
                        (Down . (^. coinTxOutL) . snd)
                        (filter (adaOnlyOut . snd) wallet) of
                        (u : _) -> pure u
                        [] ->
                            failWith
                                ClientRefusal
                                "the wallet holds no ada-only output to pay the fee"
                    unsigned <-
                        updatePayloadTx
                            UpdateArgs
                                { uaView = v
                                , uaApplied = applied s
                                , uaHolding = holding
                                , uaPayload = payload
                                , uaFee = fee
                                , uaChange = addr
                                , uaReference = case refOut of
                                    (u : _) -> Just u
                                    [] -> Nothing
                                }
                            >>= either (failWith ClientRefusal) pure
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
        pure $
            receipt
                "update"
                Success
                [ ("key", toJSON (hexT key))
                , ("update", toJSON (txIdHex signed))
                , ("liveOutput", toJSON (txInText liveIn))
                , ("payload", dataToJson (envPayload seen))
                , ("root", toJSON (hexT rootAfter))
                ]

-- ---------------------------------------------------------
-- terminate
-- ---------------------------------------------------------

runTerminate :: EntryArgs -> IO Value
runTerminate a = do
    let Key key = entryKey a
    attached
        (entryRegistry a)
        (entryBlueprint a)
        (entryWrite a)
        "terminate"
        $ \at -> do
            let s = savedOf at
            appRef <- appReference at
            -- The live output the booking releases is resolved in the
            -- booking's own view, with the state the approval binds.
            let approve v live = do
                    outs <- liveOutputs v s
                    (holding@(liveIn, _), envelope) <-
                        either (failWith ClientRefusal) pure (liveOutputFor s key outs)
                    let c = envControl envelope
                    requireController at c
                    pure
                        ( ( terminateApproval
                                (applied s)
                                (fst (liveState live))
                                liveIn
                                key
                                (ctlController c)
                          )
                            { baScriptReference = Just appRef
                            }
                        , (holding, c)
                        )
            (booking, (holding@(liveIn, _), c)) <-
                book
                    at
                    key
                    edgeUpdateTerminal
                    terminateDestination
                    edgeDeposit
                    approve
            (fold, root) <-
                foldAndCommit
                    at
                    (TxIn (txIdTx booking) (TxIx 0))
                    key
                    edgeUpdateTerminal
                    "terminal"
                    []
                    [holding]
            after <- reading at (`liveOutputs` s)
            when (any ((== liveIn) . fst) after) $
                failWith
                    Partial
                    "the fold confirmed but the live output is still unspent"
            journalObserved
                (atWrite at)
                "fold"
                fold
                ("live output " <> txInText liveIn <> " released; root 0x" <> hexT root)
            commitLocal at fold root
            pure $
                receipt
                    "terminate"
                    Success
                    [ ("key", toJSON (hexT key))
                    , ("booking", toJSON (txIdHex booking))
                    , ("fold", toJSON (txIdHex fold))
                    , ("released", toJSON (txInText liveIn))
                    , ("deposit", toJSON (ctlDeposit c))
                    , ("root", toJSON (hexT root))
                    ]

{- | A build failure's own words, without the script bytes and context a
Plutus failure carries after them.
-}
briefly :: String -> String
briefly = go
  where
    go s
        | "(PlutusWithContext" `isPrefixOf` s = "…"
        | otherwise = case s of
            [] -> []
            (c : rest) -> c : go rest
