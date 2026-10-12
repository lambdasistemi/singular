{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Application.KeriStub.Convict
Description : @keri-stub convict@ books one termination under the stub's own policy
License     : Apache-2.0

Convict attaches first, exactly as every write of the registry does, then
books one @updateTerminal@ edge through the library's own request building:
the approval asset is minted under the stub's always-succeeding script (it
is both the minting policy and the spending script of the holdings), the
booking reads the registry state and the key's live holding by reference
and releases nothing yet, and the approval's redeemer carries the evidence
hash the command line names — the same Approve tuple the registry's own
approvals spell, with the evidence as its last field — so the registry's
fold spends the holding with the stub's script and releases it to its
controller with the deposit back. Nothing here decides a validator or a
fold rule: the builders, the measurement and the fold all come from the
registry packages.

The ordinary verb refuses early: @precheckBooking@ decides, from a fresh
read view before any signing key is read, whether the key's current entry
rules the termination out, and the booking itself re-checks the same refusal
inside its own view. A convict of a key that is not active stops at the named
client-policy reason with nothing submitted; the booking primitive and the
fold stay permissive. Only the holding's controller may convict it.

With @--fold@ the same command folds its own booking once it confirms, by
the routine @keri-stub fold@ runs.
-}
module Singular.Application.KeriStub.Convict
    ( -- * The verb
      runConvict

      -- * What a convict books
    , ConvictBooking (..)
    , planConvict
    ) where

import Control.Monad (unless)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.BaseTypes (Network (Testnet), TxIx (..))
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import PlutusCore.Data qualified as PLC

import Singular.Application.KeriStub.Command
    ( ConvictArgs (..)
    , KeriStubCommand (..)
    , neededRoles
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
    , deadlineJson
    , deadlineOf
    , foldPending
    )
import Singular.CLI.FoldRules
    ( SettledForReceipt (..)
    , foldReceiptLists
    )
import Singular.CLI.Live
import Singular.CLI.ManagedState (resolveWalletDir)
import Singular.CLI.Outlay (bookingOutlay)
import Singular.CLI.Plan (refuseOver)
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
    , edgeName
    , edgeUpdateTerminal
    )
import Singular.Registry.Wallet (Wallet (..))

{- | What one convict books: the edge, where the fold delivers (nowhere:
a termination delivers nothing) and the evidence it carries, the deposit
it rides with, and the certification the mint requires. Pure over its
inputs, so the command and its tests decide from the same code.
-}
data ConvictBooking = ConvictBooking
    { cbEdge :: Edge
    -- ^ The edge booked: always @updateTerminal@
    , cbDestination :: (ByteString, Maybe PLC.Data)
    -- ^ Nowhere: a termination delivers nothing, the model's @r.output = 0@
    , cbDeposit :: Integer
    -- ^ The deposit the booking rides with, in lovelace
    , cbApproval :: BookingApproval
    -- ^ The approval asset, redeemer, script and references of the mint
    }

{- | One termination under the stub's own always-succeeding policy: the
approval asset is one token under the stub's script hash, named by the
library's binding formula over the edge, the key, the controller and the
destination; the redeemer spells the same tuple the registry's own
approvals spell, with the evidence hash as its last field; the mint is
witnessed by the script itself, attached (the stub's pin is a hash, so a
create publishes no application reference to read it from), and the mint
reads the registry state and the key's live holding by reference.
-}
planConvict
    :: TxIn
    -- ^ The registry state output the mint reads by reference
    -> TxIn
    -- ^ The key's live holding output the mint reads by reference
    -> ByteString
    -- ^ The key
    -> ByteString
    -- ^ The holding's controller: the payment key hash the fold releases to
    -> ByteString
    -- ^ The evidence hash the redeemer carries
    -> ConvictBooking
planConvict state holding key controller evidence =
    ConvictBooking
        { cbEdge = edgeUpdateTerminal
        , cbDestination = destination
        , cbDeposit = edgeDeposit
        , cbApproval = approval
        }
  where
    destination = (BS.empty, Nothing)
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
                    [ PLC.I edgeUpdateTerminal
                    , PLC.B key
                    , PLC.B controller
                    , PLC.List [PLC.B destAddr, PLC.B destHash]
                    , PLC.B evidence
                    ]
            , baScript = keriStubScript
            , baScriptReference = Nothing
            , baReferenceInputs = Set.fromList [state, holding]
            }
    name = approvalName edgeUpdateTerminal key controller (destAddr, destHash)

-- | The caller must be the holding's controller.
controllerCheck :: ByteString -> ByteString -> IO ()
controllerCheck caller controller =
    unless (controller == caller) $
        failWith
            ClientRefusal
            ( "the holding's controller is 0x"
                <> T.unpack (hexT controller)
                <> " but this command signs as 0x"
                <> T.unpack (hexT caller)
            )

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
    -> (Cage.Session Cage.NoWitness IO -> Live -> IO (ConvictBooking, r))
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
                let edge = T.pack (edgeName (cbEdge b))
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
                        (cbEdge b)
                        (cbDestination b)
                        (cbDeposit b)
                        (cbApproval b)
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

-- | What a booking-only convict's receipt names of its pending request.
pendingFields :: ByteString -> ConwayTx -> Deadline -> [(Text, Value)]
pendingFields requester bookingTx deadline =
    [ ("booking", toJSON (txIdHex bookingTx))
    , ("requester", toJSON (hexT requester))
    , ("request", toJSON (txInText (TxIn (txIdTx bookingTx) (TxIx 0))))
    , ("foldDeadline", deadlineJson deadline)
    ]

{- | The fold a convict runs after its own booking, by the routine
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

{- | The managed journal for a convict: resolved from the state root
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

{- | Run @keri-stub convict@: refuse early, book one termination under the
stub's policy, and fold it in the same command when asked.
-}
runConvict :: Env -> ConvictArgs -> IO Value
runConvict env c = case entryMode (convictEntry c) of
    Submit ws -> convictWith ws
    -- Unreachable through the parser, which refuses --preview by name.
    Preview{} ->
        failWith
            ClientRefusal
            "convict previews nothing: it books and submits"
  where
    a = convictEntry c
    evidence = convictEvidence c
    convictWith ws = do
        let Key key = entryKey a
        precheckBooking
            keriStubApplication
            env
            (writeProvider ws)
            (entryBlueprint a)
            (entryAccess a)
            (neededRoles (KeriConvict c))
            key
            BookTerminate
        dir <- managedEntryDir a ws
        attached
            keriStubApplication
            env
            dir
            (entryBlueprint a)
            (entryAccess a)
            (neededRoles (KeriConvict c))
            ws
            "convict"
            $ \at -> do
                let s = savedOf at
                -- The live holding the booking releases is resolved in the
                -- booking's own view, with the state the approval binds.
                (booking, (liveIn, dh, bookingDeposit), deadline) <-
                    book at a key BookTerminate $ \v live -> do
                        outs <- liveOutputs keriStubApplication v s
                        decoded <-
                            either
                                (failWith ClientRefusal)
                                pure
                                (liveOutputFor keriStubApplication s key outs)
                        let holding = fst decoded
                            holdingView = snd decoded
                        controllerCheck (callerKey at) (dhController holdingView)
                        let booked =
                                planConvict
                                    (fst (liveState live))
                                    (fst holding)
                                    key
                                    (dhController holdingView)
                                    evidence
                        pure
                            ( booked
                            , (fst holding, holdingView, cbDeposit booked)
                            )
                let deposit = dhDeposit dh
                if entryFold a
                    then do
                        folded <- foldAfter at a booking
                        settledReceipt key booking evidence bookingDeposit folded
                    else
                        pure $
                            receipt
                                "convict"
                                Success
                                ( keyFields key
                                    <> pendingFields (callerKey at) booking deadline
                                    <> [ ("evidence", toJSON (hexT evidence))
                                       , ("released", toJSON (txInText liveIn))
                                       , ("deposit", toJSON deposit)
                                       , ("bookingDeposit", toJSON bookingDeposit)
                                       ]
                                )

{- | The receipt of a convict that folded its own booking: what the fold
settled, with the output it released and the deposit it paid back, read
back from the delivery.
-}
settledReceipt
    :: ByteString -> ConwayTx -> ByteString -> Integer -> Folded -> IO Value
settledReceipt key booking evidence bookingDeposit folded =
    pure $ case fdDelivery folded of
        Released released deposit ->
            receipt
                "convict"
                Success
                ( keyFields key
                    <> [ ("booking", toJSON (txIdHex booking))
                       , ("fold", toJSON (txIdHex (fdTx folded)))
                       , ("released", toJSON (txInText released))
                       , ("deposit", toJSON deposit)
                       , ("evidence", toJSON (hexT evidence))
                       , ("bookingDeposit", toJSON bookingDeposit)
                       , ("root", toJSON (hexT (fdRoot folded)))
                       ]
                    <> foldReceiptLists
                        [ SettledForReceipt
                            (fdRequest folded)
                            (hexT (fdKey folded))
                            (T.pack (edgeName (fdEdge folded)))
                            (fdOwnerHex folded)
                            ( object
                                [ "released" .= txInText released
                                , "deposit" .= deposit
                                ]
                            )
                            (deadlineJson (fdDeadline folded))
                        ]
                        (fdExcluded folded)
                        (fdCapacityBound folded)
                        (fdCapacityProvenance folded)
                )
        -- A termination releases its holding; the other deliveries belong
        -- to other edges, and this verb books only terminations.
        _ ->
            error
                "Convict: the folded delivery is not the release its termination books"
