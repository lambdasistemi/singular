{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Application.KeriStub.Register
Description : @keri-stub register@ books one insertion under the stub's own policy
License     : Apache-2.0

Register attaches first, exactly as every write of the registry does, then
books one @insertActive@ edge through the library's own request building:
the approval asset is minted under the stub's always-succeeding script (it
is both the minting policy and the spending script of the holdings), the
destination is that script's enterprise address, and the request carries
the holding datum — the key, the controller's payment key hash, the
protected deposit and the opaque identifier prefix as payload — so the
registry's fold delivers the key's active token to an output carrying the
holding inline. Nothing here decides a validator or a fold rule: the
builders, the measurement and the fold all come from the registry
packages.

The ordinary verb refuses early: @precheckBooking@ decides, from a fresh
read view before any signing key is read, whether the key's current entry
rules the insertion out, and the booking itself re-checks the same refusal
inside its own view. A second register of an active key stops at the named
client-policy reason with nothing submitted; the booking primitive and the
fold stay permissive.

With @--fold@ the same command folds its own booking once it confirms, by
the routine @keri-stub fold@ runs.
-}
module Singular.Application.KeriStub.Register
    ( -- * The verb
      runRegister

      -- * What a register books
    , RegisterBooking (..)
    , planRegister
    , defaultDeposit
    ) where

import Control.Monad (unless)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

import Cardano.Ledger.Address (Addr (..), serialiseAddr)
import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.BaseTypes (Network (Testnet), TxIx (..))
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import PlutusCore.Data qualified as PLC

import Singular.Application.KeriStub.Command
    ( KeriStubCommand (..)
    , neededRoles
    )
import Singular.Application.KeriStub.Datum
    ( Holding (..)
    , holdingFromData
    , holdingToData
    )
import Singular.Application.KeriStub.Script (keriStubScript)
import Singular.Application.KeriStub.Value (keriStubApplication)
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
    , deadlineOf
    , foldPending
    , settledEntryFor
    )
import Singular.CLI.FoldRules
    ( FoldRequestsRefusal (..)
    , SettledForReceipt (..)
    , foldReceiptLists
    , renderFoldRequestsRefusal
    )
import Singular.CLI.Live
import Singular.CLI.ManagedState (resolveWalletDir)
import Singular.CLI.Outlay (bookingOutlay)
import Singular.CLI.Plan (readJson, refuseOver)
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Registry (hexT, keyFields)
import Singular.CLI.Session
import Singular.CLI.Trace
    ( EdgeAction (..)
    , Scope (..)
    , What (Booked, EdgeStarted)
    , report
    )
import Singular.Registry.Application
    ( DecodedHolding (..)
    , datumFromJson
    , datumToJson
    )
import Singular.Registry.Evidence qualified as Cage
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.TxBuilder.Edges
    ( BookingApproval (..)
    , bookEdgeMeasured
    , edgeDeposit
    )
import Singular.Registry.TxBuilder.Internal
    ( approvalDestination
    , approvalName
    , extractCageDatum
    , requestAddrFromCfg
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , Edge
    , OnChainRequest
    , OnChainTokenState
    , edgeInsertActive
    , edgeName
    )
import Singular.Registry.Wallet (Wallet (..))

{- | The deposit a register rides with when the command line names none:
the library's own booking deposit, the least an insertion protects.
-}
defaultDeposit :: Integer
defaultDeposit = edgeDeposit

{- | The payload a register carries when the command line names none: the
empty prefix, no bytes.
-}
defaultPayload :: PLC.Data
defaultPayload = PLC.B BS.empty

{- | What one register books: the edge, where the fold delivers and the
datum the request carries for it, the deposit it protects, and the
certification the mint requires. Pure over its inputs, so the command and
its tests decide from the same code.
-}
data RegisterBooking = RegisterBooking
    { rbEdge :: Edge
    -- ^ The edge booked: always @insertActive@
    , rbDestination :: (ByteString, Maybe PLC.Data)
    {- ^ The stub script's address, and the holding the delivered output
    carries inline
    -}
    , rbDeposit :: Integer
    -- ^ The protected deposit, in lovelace
    , rbApproval :: BookingApproval
    -- ^ The approval asset, redeemer, script and references of the mint
    }

{- | One insertion under the stub's own always-succeeding policy: the
approval asset is one token under the stub's script hash, named by the
library's binding formula over the edge, the key, the controller and the
destination; the redeemer spells the same tuple the registry's own
approvals spell; the mint is witnessed by the script itself, attached
(the stub's pin is a hash, so a create publishes no application reference
to read it from), and the mint reads the registry state by reference.
-}
planRegister
    :: TxIn
    -- ^ The registry state output the mint reads by reference
    -> ByteString
    -- ^ The key
    -> ByteString
    -- ^ The controller's payment key hash
    -> Integer
    -- ^ The protected deposit, in lovelace
    -> PLC.Data
    -- ^ The opaque identifier prefix as payload
    -> RegisterBooking
planRegister state key controller deposit payload =
    RegisterBooking
        { rbEdge = edgeInsertActive
        , rbDestination = destination
        , rbDeposit = deposit
        , rbApproval = approval
        }
  where
    destination =
        ( serialiseAddr stubAddress
        , Just
            ( holdingToData
                Holding
                    { hdKey = key
                    , hdController = controller
                    , hdDeposit = deposit
                    , hdPayload = payload
                    }
            )
        )
    stubAddress =
        Addr Testnet (ScriptHashObj (hashScript keriStubScript)) StakeRefNull
    (destAddr, destHash) = approvalDestination destination
    approval =
        BookingApproval
            { baAsset =
                MultiAsset
                    ( Map.singleton
                        (PolicyID (hashScript keriStubScript))
                        (Map.singleton (AssetName (SBS.toShort name)) 1)
                    )
            , baRedeemer =
                PLC.Constr
                    0
                    [ PLC.I edgeInsertActive
                    , PLC.B key
                    , PLC.B controller
                    , PLC.List [PLC.B destAddr, PLC.B destHash]
                    ]
            , baScript = keriStubScript
            , baScriptReference = Nothing
            , baReferenceInputs = Set.singleton state
            }
    name = approvalName edgeInsertActive key controller (destAddr, destHash)

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

{- | Book one edge, then read the request back live at the request address
before journalling it observed, and place its processing deadline in that
same view. The booking is built from one view: what it books is decided
there, its units measured and its outlay judged against the approved
allowance, before anything is signed. The refusal every ordinary verb
makes is decided inside the booking's own view as well, so a key whose
entry moved between the pre-check and the build is still refused by name.
-}
book
    :: Attached
    -> EntryArgs
    -> ByteString
    -> BookingVerb
    -> (Cage.Session Cage.NoWitness IO -> Live -> IO (RegisterBooking, r))
    -> IO (ConwayTx, r, Deadline)
book at a key verb plan = do
    let s = savedOf at
        cfg = savedCfg s
        wc = atWrite at
    (booking, decided) <-
        submitBuiltIn
            wc
            "book"
            ["state", "key outputs"]
            (const (Expectation (Just key) "request" Nothing Nothing Nothing))
            ( \building v -> do
                live <- attachLive v s
                refuseBooking (atTrie at) key verb
                (b, decided) <- plan v live
                let edge = T.pack (edgeName (rbEdge b))
                place
                    building
                    [InKey key, InEdge (Booking edge)]
                    (EdgeStarted (Booking edge))
                tx <-
                    bookEdgeMeasured
                        cfg
                        v
                        (walletAddr (wcWallet wc))
                        (savedToken s)
                        key
                        (rbEdge b)
                        (rbDestination b)
                        (rbDeposit b)
                        (rbApproval b)
                        (liveRefs live)
                        (entryFund a)
                pp <- Cage.parameters v
                refuseOver
                    (entryMaxOutlay a)
                    (bookingOutlay pp (liveRefs live) tx)
                pure (tx, decided)
            )
    let request = TxIn (txIdTx (confirmedTx booking)) (TxIx 0)
    deadline <-
        readingBack at "book" booking ["requests", "state"] $ \v -> do
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
        (Booked (txInText request) (Just (deadlineMs deadline)))
    pure (confirmedTx booking, decided, deadline)

-- | What a booking-only register's receipt names of its pending request.
pendingFields :: ByteString -> ConwayTx -> Deadline -> [(Text, Value)]
pendingFields requester bookingTx deadline =
    [ ("booking", toJSON (txIdHex bookingTx))
    , ("requester", toJSON (hexT requester))
    , ("request", toJSON (txInText (TxIn (txIdTx bookingTx) (TxIx 0))))
    , ("foldDeadline", deadlineJson deadline)
    ]

{- | The fold a register runs after its own booking, by the routine
@keri-stub fold@ runs.
-}
foldAfter :: Attached -> EntryArgs -> ConwayTx -> IO Folded
foldAfter at a booking =
    foldPending
        keriStubApplication
        at
        FoldSpec
            { fsOrigin = Combined booking
            , fsRequest = Nothing
            , fsFund = Nothing
            , fsAllowance = entryMaxOutlay a
            }

{- | The managed journal for a register: resolved from the state root
override, the provider network, the registry token and the caller's
wallet, before any lock or journal use.
-}
managedEntryDir :: EntryArgs -> WriteSettings -> IO FilePath
managedEntryDir a ws =
    resolveWalletDir
        (entryStateDir a)
        (providerMagic (writeProvider ws))
        (accessToken (entryAccess a))
        (writeWalletKey ws)

{- | The payload a register carries: the file its @--payload@ names as
Plutus data, or the empty prefix when none is named.
-}
readPayload :: EntryArgs -> IO PLC.Data
readPayload a = case entryDocument a of
    Nothing -> pure defaultPayload
    Just path ->
        readJson path
            >>= either (failWith ClientRefusal . refused path) pure . datumFromJson
  where
    refused path why = path <> ": --payload is not Plutus data: " <> why

-- | A holding as the datum the receipts print.
holdingDatum :: Holding -> Value
holdingDatum h = datumToJson (holdingToData h)

{- | Run @keri-stub register@: refuse early, book one insertion under the
stub's policy, and fold it in the same command when asked.
-}
runRegister :: Env -> EntryArgs -> IO Value
runRegister env a = case entryMode a of
    Submit ws -> registerWith ws
    -- Unreachable through the parser, which refuses --preview by name.
    Preview{} ->
        failWith
            ClientRefusal
            "register previews nothing: it books and submits"
  where
    registerWith ws = do
        let Key key = entryKey a
        payload <- readPayload a
        precheckBooking
            keriStubApplication
            env
            (writeProvider ws)
            (entryBlueprint a)
            (entryAccess a)
            (neededRoles (KeriRegister a))
            key
            BookInsert
        dir <- managedEntryDir a ws
        attached
            keriStubApplication
            env
            dir
            (entryBlueprint a)
            (entryAccess a)
            (neededRoles (KeriRegister a))
            ws
            "register"
            $ \at -> do
                let deposit = fromMaybe defaultDeposit (entryDeposit a)
                    holding =
                        Holding
                            { hdKey = key
                            , hdController = callerKey at
                            , hdDeposit = deposit
                            , hdPayload = payload
                            }
                (booking, (), deadline) <-
                    book at a key BookInsert $ \_ live ->
                        pure
                            ( planRegister
                                (fst (liveState live))
                                key
                                (callerKey at)
                                deposit
                                payload
                            , ()
                            )
                if entryFold a
                    then do
                        folded <- foldAfter at a booking
                        settledReceipt key booking folded
                    else
                        pure $
                            receipt
                                "register"
                                Success
                                ( keyFields key
                                    <> pendingFields (callerKey at) booking deadline
                                    <> [ ("deposit", toJSON deposit)
                                       , ("holding", holdingDatum holding)
                                       ]
                                )

{- | The receipt of a register that folded its own booking: what the fold
settled, with the holding it delivered, read back from the delivery.
-}
settledReceipt :: ByteString -> ConwayTx -> Folded -> IO Value
settledReceipt key booking folded = do
    let bookingRef = TxIn (txIdTx booking) (TxIx 0)
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
        Delivered liveIn delivered
            | Right _ <- holdingFromData (dhDatumData delivered) ->
                receipt
                    "register"
                    Success
                    ( keyFields key
                        <> [ ("booking", toJSON (txIdHex booking))
                           , ("fold", toJSON (txIdHex (fdTx folded)))
                           , ("liveOutput", toJSON (txInText liveIn))
                           , ("holding", dhDatumJson delivered)
                           , ("root", toJSON (hexT (fdRoot folded)))
                           ]
                        <> foldReceiptLists
                            [ SettledForReceipt
                                (seRequest entry)
                                (hexT (seKey entry))
                                (T.pack (edgeName (seEdge entry)))
                                (seOwner entry)
                                ( object
                                    [ "liveOutput" .= txInText liveIn
                                    , "holding" .= dhDatumJson delivered
                                    ]
                                )
                                (deadlineJson (seDeadline entry))
                            ]
                            (fdExcluded folded)
                            (fdCapacityBound folded)
                            (fdCapacityProvenance folded)
                    )
            | otherwise ->
                error
                    ( "Register: the folded delivery carries a holding that does not read: "
                        <> show (holdingFromData (dhDatumData delivered))
                    )
        -- An insertion delivers a holding; the other deliveries belong to
        -- other edges, and this verb books only insertions.
        _ -> receipt "register" Success (keyFields key)
