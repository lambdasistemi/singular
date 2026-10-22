{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.KeriStub.Register
Description : @keri-stub register@ books one registration under the stub's own policy
License     : Apache-2.0

Register attaches first, exactly as every write of the registry does, then
books one registration through the registry's own registration booking: the
request carries the holding datum (the key, the controller's payment key hash,
the protected deposit and the opaque identifier prefix as payload), names the
stub script's enterprise address as its destination, and holds the trie-ready
tag under the request policy and the application tag under the stub's policy,
so the registry's fold delivers the key's active token to an output carrying
the holding inline. The stub's script is an always-succeeding program: it
is both the minting policy of the application tag and the spending script of the
holdings. Nothing here decides a validator or a fold rule: the builder, the
measurement and the fold all come from the registry packages.

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

import Control.Monad (when)
import Data.Aeson (Value (Null), object, toJSON, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Lens.Micro ((&), (.~))
import PlutusCore.Data qualified as PLC

import Cardano.Ledger.Address (Addr (..), serialiseAddr)
import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.Api.Tx.Out
    ( datumTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    )
import Cardano.Ledger.BaseTypes (Network (Testnet), TxIx (..))
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    )
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
    ( KeriStubCommand (..)
    , neededRoles
    )
import Singular.Application.KeriStub.Datum
    ( Holding (..)
    , holdingFromData
    , holdingToData
    )
import Singular.Application.KeriStub.Script
    ( keriStubScript
    , keriStubScriptBytes
    )
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
    , deadlineJson
    , settledEntryFor
    )
import Singular.CLI.FoldRules
    ( FoldRequestsRefusal (..)
    , SettledForReceipt (..)
    , foldReceiptLists
    , renderFoldRequestsRefusal
    )
import Singular.CLI.Live
import Singular.CLI.Outlay (bookingOutlay)
import Singular.CLI.Plan (readJson)
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Registry (hexT, keyFields)
import Singular.CLI.Session
import Singular.Registry.Application
    ( DecodedHolding (..)
    , datumFromJson
    , datumToJson
    )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Evidence qualified as Cage
import Singular.Registry.Ledger (Coin (..))
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.TxBuilder.Edges (edgeDeposit)
import Singular.Registry.TxBuilder.Internal
    ( addrFromBytes
    , mkInlineDatum
    , policyIdFromPin
    )
import Singular.Registry.TxBuilder.RegistrationBooking
    ( RegistrationBooking (..)
    , bookRegistrationImpl
    , registrationWindow
    )
import Singular.Registry.Types
    ( Edge
    , edgeInsertActive
    , edgeName
    )

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

{- | What one register books: the edge, where the fold delivers and the datum
the request carries for it, and the deposit the delivered output protects.
Pure over its inputs, so the command and its tests decide from the same code.
-}
data RegisterBooking = RegisterBooking
    { registerEdge :: Edge
    -- ^ The edge booked: always @insertActive@
    , registerDestination :: (ByteString, Maybe PLC.Data)
    {- ^ The stub script's address, and the holding the delivered output
    carries inline
    -}
    , registerDeposit :: Integer
    -- ^ The protected deposit, in lovelace, which is the registration's carrier
    }

{- | One registration under the stub's own always-succeeding policy: the
holding is the datum of the delivered output, the stub script's enterprise
address the destination, the deposit the carrier. The application tag is
minted under the stub's script, which the booking attaches (the stub's pin is
a hash, so a create publishes no application reference to read it from).
-}
planRegister
    :: ByteString
    -- ^ The key
    -> ByteString
    -- ^ The controller's payment key hash
    -> Integer
    -- ^ The protected deposit, in lovelace
    -> PLC.Data
    -- ^ The opaque identifier prefix as payload
    -> RegisterBooking
planRegister key controller deposit payload =
    RegisterBooking
        { registerEdge = edgeInsertActive
        , registerDestination =
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
        , registerDeposit = deposit
        }
  where
    stubAddress =
        Addr Testnet (ScriptHashObj (hashScript keriStubScript)) StakeRefNull

{- | The booking a register asks of the registry: built from one view, paid and
refunded by an address. The custody the fold will make must be able to carry
the deposit: the ledger's minimum for that output is asked of the parameters
of the booking's own view and a deposit below it is refused, naming the
amount, before anything is built. The deposit is never topped up.
-}
bookedRegister
    :: Cage.Session Cage.NoWitness IO
    -> Live
    -> ByteString
    -> RegisterBooking
    -> IO Booked
bookedRegister v live key plan = do
    let s = liveSaved live
        cfg = savedCfg s
        (address, datum) = registerDestination plan
        deposit = registerDeposit plan
    pp <- Cage.parameters v
    custodyAddress <-
        maybe
            (failWith Partial "the stub's address does not decode")
            pure
            (addrFromBytes address)
    let custody =
            mkBasicTxOut
                custodyAddress
                ( MaryValue
                    (Coin deposit)
                    ( MultiAsset
                        ( Map.singleton
                            (policyIdFromPin (cfgActivePolicy cfg))
                            (Map.singleton (AssetName (SBS.toShort key)) 1)
                        )
                    )
                )
                & maybe id (\d -> datumTxOutL .~ mkInlineDatum d) datum
        Coin least = getMinCoinTxOut pp custody
    when (deposit < least) $
        failWith
            ClientRefusal
            ( "the output that will hold key 0x"
                <> T.unpack (hexT key)
                <> " needs at least "
                <> show least
                <> " lovelace to carry its holding under the ledger's minimum, and the deposit is "
                <> show deposit
                <> "; name a deposit of at least "
                <> show least
                <> " lovelace (client policy)"
            )
    pure
        Booked
            { bookedEdge = registerEdge plan
            , bookedBuild = \view payer -> do
                (lower, upper) <- registrationWindow cfg view
                bookRegistrationImpl
                    cfg
                    view
                    (savedToken s)
                    (fst (liveState live))
                    RegistrationBooking
                        { rbKey = key
                        , rbRefundAddress = payer
                        , rbDestination = address
                        , rbDatum = datum
                        , rbDeclaredTip = defaultTip cfg
                        , rbCarrier = Coin deposit
                        , rbNonce = toInteger (unSlotNo upper)
                        , rbLower = lower
                        , rbUpper = upper
                        , rbApplicationScript = keriStubScriptBytes
                        , rbApplicationRedeemer = Nothing
                        , rbRequiredSigners = []
                        }
                    payer
            , bookedOutlay = bookingOutlay
            }

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

{- | Run @keri-stub register@: refuse early, book one registration under the
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
                (booking, (), deadline, spent) <-
                    book at a key BookInsert $ \v live -> do
                        booked <-
                            bookedRegister
                                v
                                live
                                key
                                (planRegister key (callerKey at) deposit payload)
                        pure (booked, ())
                if entryFold a
                    then do
                        folded <- foldAfter at a booking spent
                        settledReceipt key booking folded
                    else
                        pure $
                            receipt
                                "register"
                                Success
                                ( keyFields key
                                    <> pendingFields (callerKey at) booking deadline
                                    <> [ ("transfer", toJSON (transferOf booking))
                                       , ("deposit", toJSON deposit)
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
                                (maybe Null deadlineJson (seDeadline entry))
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
        -- A registration delivers a holding; the other deliveries belong to
        -- other edges, and this verb books only registrations.
        _ -> receipt "register" Success (keyFields key)
