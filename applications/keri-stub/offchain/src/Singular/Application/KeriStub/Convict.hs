{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.KeriStub.Convict
Description : @keri-stub convict@ books one termination under the stub's own policy
License     : Apache-2.0

Convict attaches first, exactly as every write of the registry does, then
books one termination through the registry's own termination booking: the
key's holding, the custody, is spent under the stub's always-succeeding script
with a redeemer that carries the evidence hash the command line names, and the
whole of it enters the termination request together with the requester's
declared addition. The booking mints the request policy's trie-ready tag alone,
so the registry's fold takes the custody in, burns the key's singular tag and
makes the key terminal; nothing is released to the controller at the fold.
Only the holding's controller may convict it, and the controller signs the
booking. Nothing here decides a validator or a fold rule: the builder, the
measurement and the fold all come from the registry packages.

The ordinary verb refuses early: @precheckBooking@ decides, from a fresh
read view before any signing key is read, whether the key's current entry
rules the termination out, and the booking itself re-checks the same refusal
inside its own view. A convict of a key that is not active stops at the named
client-policy reason with nothing submitted; the booking primitive and the
fold stay permissive.

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
import Data.Text qualified as T
import Lens.Micro ((^.))
import PlutusCore.Data qualified as PLC

import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.Api.Tx.Out (coinTxOutL)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Application.KeriStub.Book
    ( Booked (..)
    , book
    , foldAfter
    , managedEntryDir
    , pendingFields
    , transferOf
    )
import Singular.Application.KeriStub.Command
    ( ConvictArgs (..)
    , KeriStubCommand (..)
    , neededRoles
    )
import Singular.Application.KeriStub.Script (keriStubScriptBytes)
import Singular.Application.KeriStub.Value (keriStubApplication)
import Singular.CLI.Attached
import Singular.CLI.Booking
    ( BookingVerb (..)
    , precheckBooking
    )
import Singular.CLI.Command
    ( EntryArgs (..)
    , EntryMode (..)
    , Key (..)
    , WriteSettings (..)
    )
import Singular.CLI.Fold
    ( Delivery (..)
    , Folded (..)
    , SettledEntry (..)
    , settledEntryFor
    )
import Singular.CLI.FoldRules
    ( FoldRequestsRefusal (..)
    , SettledForReceipt (..)
    , foldReceiptLists
    , renderFoldRequestsRefusal
    )
import Singular.CLI.Live
import Singular.CLI.Outlay (terminationOutlay)
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Registry (hexT, keyFields)
import Singular.CLI.Session
import Singular.Registry.Application
    ( DecodedHolding (..)
    )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (Coin (..))
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.TxBuilder.TerminationBooking
    ( CustodyAuthority (..)
    , TerminationBooking (..)
    , bookTerminationImpl
    )
import Singular.Registry.Types
    ( Edge
    , edgeName
    , edgeUpdateTerminal
    )

{- | What one convict books: the edge, the redeemer the custody is spent with
(it carries the evidence) and the payment key hashes that must sign. Pure over
its inputs, so the command and its tests decide from the same code.
-}
data ConvictBooking = ConvictBooking
    { cbEdge :: Edge
    -- ^ The edge booked: always @updateTerminal@
    , cbRedeemer :: PLC.Data
    -- ^ What the stub's script is spent with: the evidence hash
    , cbSigners :: [ByteString]
    -- ^ The holding's controller, who must sign the booking
    }

{- | One termination of the stub's holding: the custody is spent with the
evidence hash as its redeemer, the controller signs, and the whole custody
enters the request. The stub's script accepts the spend; no claim of consent
or protection follows from it.
-}
planConvict
    :: ByteString
    -- ^ The holding's controller: the payment key hash that signs
    -> ByteString
    -- ^ The evidence hash the redeemer carries
    -> ConvictBooking
planConvict controller evidence =
    ConvictBooking
        { cbEdge = edgeUpdateTerminal
        , cbRedeemer = PLC.Constr 0 [PLC.B evidence]
        , cbSigners = [controller]
        }

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
                    cfg = savedCfg s
                -- The live holding the booking spends is resolved in the
                -- booking's own view, with the state the booking reads.
                (booking, (liveIn, held), _, spent) <-
                    book at a key BookTerminate $ \v live -> do
                        outs <- liveOutputs keriStubApplication v s
                        decoded <-
                            either
                                (failWith ClientRefusal)
                                pure
                                (liveOutputFor keriStubApplication s key outs)
                        let holding = fst decoded
                            holdingView = snd decoded
                            plan = planConvict (dhController holdingView) evidence
                            Coin custody = snd holding ^. coinTxOutL
                            Coin tip = defaultTip cfg
                        controllerCheck (callerKey at) (dhController holdingView)
                        pure
                            ( Booked
                                { bookedEdge = cbEdge plan
                                , bookedBuild = \view payer -> do
                                    observed <- Cage.tip view
                                    bookTerminationImpl
                                        cfg
                                        view
                                        (savedToken s)
                                        (fst (liveState live))
                                        TerminationBooking
                                            { tbKey = key
                                            , tbDeclaredTip = Coin tip
                                            , tbCarrier = Coin (custody - tip)
                                            , tbNonce = toInteger (unSlotNo (Cage.observedSlot observed))
                                            , tbCustody = holding
                                            , tbOrdinaryAdded = Coin 0
                                            , tbCustodyAuthority =
                                                ScriptGuarded keriStubScriptBytes (cbRedeemer plan)
                                            , tbRequiredSigners = cbSigners plan
                                            }
                                        payer
                                , bookedOutlay = \pp refs -> terminationOutlay pp refs custody
                                }
                            , (fst holding, custody)
                            )
                if entryFold a
                    then do
                        folded <- foldAfter at a booking spent
                        settledReceipt key booking evidence held folded
                    else
                        pure $
                            receipt
                                "convict"
                                Success
                                ( keyFields key
                                    <> pendingFields (callerKey at) booking Nothing
                                    <> [ ("transfer", toJSON (transferOf booking))
                                       , ("evidence", toJSON (hexT evidence))
                                       , ("custody", toJSON (txInText liveIn))
                                       , ("held", toJSON held)
                                       ]
                                )

{- | The receipt of a convict that folded its own booking: what the fold
settled, with the request whose custody it took in, read back from the
delivery.
-}
settledReceipt
    :: ByteString -> ConwayTx -> ByteString -> Integer -> Folded -> IO Value
settledReceipt key booking evidence held folded = do
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
        Terminated request ->
            receipt
                "convict"
                Success
                ( keyFields key
                    <> [ ("booking", toJSON (txIdHex booking))
                       , ("fold", toJSON (txIdHex (fdTx folded)))
                       , ("terminated", toJSON (txInText request))
                       , ("evidence", toJSON (hexT evidence))
                       , ("held", toJSON held)
                       , ("root", toJSON (hexT (fdRoot folded)))
                       ]
                    <> foldReceiptLists
                        [ SettledForReceipt
                            (seRequest entry)
                            (hexT (seKey entry))
                            (T.pack (edgeName (seEdge entry)))
                            (seOwner entry)
                            (object ["terminated" .= txInText request])
                            (toJSON (Nothing :: Maybe Int))
                        ]
                        (fdExcluded folded)
                        (fdCapacityBound folded)
                        (fdCapacityProvenance folded)
                )
        -- A termination is taken in; the other deliveries belong to other
        -- edges, and this verb books only terminations.
        _ ->
            error
                "Convict: the folded delivery is not the termination its booking asks"
